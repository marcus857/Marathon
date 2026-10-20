import XCTest
@testable import Marathon

@MainActor
final class WeeklyReviewClientTests: XCTestCase {
    func testSuccessUsesBearerPostAndDecodesMetricKinds() async throws {
        let input = request()
        let payload = try responseData(for: input)
        ReviewURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://reviews.marathon.test/v1/weekly-reviews")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test.identity.token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Weekly-Review-Provider"), "azure")
            return (200, payload, ["Content-Type": "application/json"])
        }
        let provider = TestReviewTokenProvider()
        let response = try await client().generate(input, tokenProvider: provider)
        XCTAssertEqual(provider.calls, 1)
        XCTAssertEqual(response.status, .complete)
        XCTAssertEqual(response.metrics.map(\.value), [.number(4), .boolean(true), .text("complete"), .null])
        XCTAssertFalse(response.fallbackUsed)
    }

    func testOpenAIConfigurationSendsExactProviderHeader() async throws {
        let input = request()
        let payload = try responseData(for: input)
        ReviewURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Weekly-Review-Provider"), "openai")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test.identity.token")
            return (200, payload, ["Content-Type": "application/json"])
        }
        let response = try await client(provider: .openai).generate(input, tokenProvider: TestReviewTokenProvider())
        XCTAssertEqual(response.requestID, input.requestID)
        XCTAssertEqual(WeeklyReviewAIProvider.azure.displayName, "Microsoft Azure OpenAI")
        XCTAssertEqual(WeeklyReviewAIProvider.openai.displayName, "OpenAI")
    }

    func testServiceFallbackIsReturnedWithoutPretendingItIsAnAIReview() async throws {
        let input = request()
        let payload = try responseData(for: input) {
            $0["status"] = "unavailable"
            $0["fallback_used"] = true
            $0["data_quality_codes"] = ["provider_unavailable"]
        }
        stub(status: 200, data: payload)
        let response = try await client().generate(input, tokenProvider: TestReviewTokenProvider())
        XCTAssertEqual(response.status, .unavailable)
        XCTAssertTrue(response.fallbackUsed)
        XCTAssertEqual(response.dataQualityCodes, ["provider_unavailable"])
    }

    func testUnauthorizedResponseIsSafeAndDoesNotUseServerErrorText() async throws {
        stub(status: 401, data: Data("private error body never shown".utf8))
        await assertClientError(.unauthorized)
    }

    func testRateLimitIsNotAutomaticallyRetried() async throws {
        var calls = 0
        ReviewURLProtocol.handler = { _ in
            calls += 1
            return (429, Data(), ["Content-Type": "application/json"])
        }
        await assertClientError(.rateLimited)
        XCTAssertEqual(calls, 1)
    }

    func testProviderMismatchIsSanitizedAndNotRetried() async throws {
        var calls = 0
        ReviewURLProtocol.handler = { _ in
            calls += 1
            return (409, Data("private provider error body never shown".utf8), ["Content-Type": "application/json"])
        }
        await assertClientError(.providerChanged)
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(WeeklyReviewClientError.providerChanged.localizedDescription.contains("private provider error"))
    }

    func testServiceUnavailable() async throws {
        stub(status: 503, data: Data())
        await assertClientError(.serviceUnavailable)
    }

    func testInvalidJSONIsRejected() async throws {
        stub(status: 200, data: Data("{broken".utf8))
        await assertClientError(.invalidResponse)
    }

    func testWrongRequestIDIsRejected() async throws {
        stub(status: 200, data: try responseData(for: request()) { $0["request_id"] = UUID().uuidString })
        await assertClientError(.invalidResponse)
    }

    func testUnknownSchemaIsRejected() async throws {
        stub(status: 200, data: try responseData(for: request()) { $0["schema_version"] = "weekly-review-response/v9" })
        await assertClientError(.invalidResponse)
    }

    func testInventedNarrativeEvidenceIsRejected() async throws {
        stub(status: 200, data: try responseData(for: request()) {
            $0["review"] = self.narrative(evidenceID: "m.invented")
        })
        await assertClientError(.invalidResponse)
    }

    func testOtherWorkoutsCannotBeUsedAsMetricEvidence() async throws {
        stub(status: 200, data: try responseData(for: request()) {
            $0["metrics"] = [["id": "m.current.actual_miles", "value": 4, "unit": "mi",
                              "quality": "derived", "source_evidence_ids": ["w-other-person"]]]
        })
        await assertClientError(.invalidResponse)
    }

    func testOversizedResponseIsRejected() async throws {
        stub(status: 200, data: Data(repeating: 32, count: 128 * 1024 + 1))
        await assertClientError(.responseTooLarge)
    }

    func testNonJSONContentTypeIsRejected() async throws {
        ReviewURLProtocol.handler = { _ in (200, Data(), ["Content-Type": "text/html"]) }
        await assertClientError(.invalidResponse)
    }

    func testRedirectStatusIsRejected() async throws {
        stub(status: 307, data: Data())
        await assertClientError(.redirectRejected)
    }

    func testRedirectDelegateDoesNotFollowEvenSameHostRedirects() throws {
        let url = try XCTUnwrap(URL(string: "https://reviews.marathon.test/v1/weekly-reviews"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil,
                                                   headerFields: ["Location": "https://reviews.marathon.test/other"]))
        var called = false
        WeeklyReviewRedirectDelegate().urlSession(session, task: task, willPerformHTTPRedirection: response,
                                                 newRequest: URLRequest(url: url)) { next in
            called = true
            XCTAssertNil(next)
        }
        XCTAssertTrue(called)
    }

    func testConfigurationRejectsUnsetPlaceholderInsecureOrCredentialURLs() throws {
        for value in ["", "$(WEEKLY_REVIEW_API_BASE_URL)", "https://example.com", "https://example.invalid",
                      "http://reviews.marathon.test", "https://user:password@reviews.marathon.test",
                      "https://reviews.marathon.test?token=secret", "https://reviews.marathon.test#secret"] {
            XCTAssertThrowsError(try WeeklyReviewConfiguration(baseURL: value, provider: .azure), value)
        }
        let configuration = try WeeklyReviewConfiguration(baseURL: "https://reviews.marathon.test/api/", provider: .azure)
        XCTAssertEqual(configuration.endpoint.absoluteString, "https://reviews.marathon.test/api/v1/weekly-reviews")
    }

    func testProviderIsPartOfConfigurationIdentityEvenAtSameEndpoint() throws {
        let azure = try WeeklyReviewConfiguration(baseURL: "https://reviews.marathon.test", provider: .azure)
        let openai = try WeeklyReviewConfiguration(baseURL: "https://reviews.marathon.test", provider: .openai)
        XCTAssertEqual(azure.endpoint, openai.endpoint)
        XCTAssertNotEqual(azure, openai)
    }

    func testProviderConfigurationHasNoImplicitDefault() throws {
        for value in [nil, "", " ", "disabled", "$(WEEKLY_REVIEW_PROVIDER)"] as [String?] {
            XCTAssertThrowsError(try WeeklyReviewAIProvider(configuredValue: value)) { error in
                XCTAssertEqual(error as? WeeklyReviewClientError, .providerNotConfigured)
            }
        }
        for value in ["unknown", "chatgpt", "Azure", "azure,openai"] {
            XCTAssertThrowsError(try WeeklyReviewAIProvider(configuredValue: value)) { error in
                XCTAssertEqual(error as? WeeklyReviewClientError, .invalidProvider)
            }
        }
        XCTAssertEqual(try WeeklyReviewAIProvider(configuredValue: "azure"), .azure)
        XCTAssertEqual(try WeeklyReviewAIProvider(configuredValue: "openai"), .openai)
    }

    #if DEBUG
    func testDebugConfigurationLoadsExplicitURLAndProviderEnvironment() throws {
        for provider in ["azure", "openai"] {
            let configuration = try WeeklyReviewConfiguration.load(
                bundle: Bundle(for: WeeklyReviewClientTests.self),
                environment: ["WEEKLY_REVIEW_API_BASE_URL": "https://reviews.marathon.test/api",
                              "WEEKLY_REVIEW_PROVIDER": provider]
            )
            XCTAssertEqual(configuration.endpoint.absoluteString, "https://reviews.marathon.test/api/v1/weekly-reviews")
            XCTAssertEqual(configuration.provider.rawValue, provider)
        }
    }

    func testMissingDisabledOrUnknownProviderPreventsAuthenticationAndTransmission() async throws {
        ReviewURLProtocol.handler = { _ in
            XCTFail("Unconfigured AI provider must not transmit workout data")
            return (500, Data(), [:])
        }
        let tokenProvider = TestReviewTokenProvider()
        for value in [nil, "", "disabled", "unknown", "chatgpt", "$(WEEKLY_REVIEW_PROVIDER)"] as [String?] {
            var environment = ["WEEKLY_REVIEW_API_BASE_URL": "https://reviews.marathon.test"]
            environment["WEEKLY_REVIEW_PROVIDER"] = value
            do {
                let configuration = try WeeklyReviewConfiguration.load(
                    bundle: Bundle(for: WeeklyReviewClientTests.self), environment: environment
                )
                _ = try await WeeklyReviewClient(configuration: configuration, protocolClasses: [ReviewURLProtocol.self])
                    .generate(request(), tokenProvider: tokenProvider)
                XCTFail("Expected provider configuration failure")
            } catch {
                let expected: WeeklyReviewClientError = ["unknown", "chatgpt"].contains(value ?? "")
                    ? .invalidProvider : .providerNotConfigured
                XCTAssertEqual(error as? WeeklyReviewClientError, expected)
            }
        }
        XCTAssertEqual(tokenProvider.calls, 0)
    }

    func testDebugEmptyURLOverrideDoesNotReuseBundledDestination() throws {
        XCTAssertThrowsError(try WeeklyReviewConfiguration.load(
            bundle: Bundle(for: WeeklyReviewClientTests.self),
            environment: ["WEEKLY_REVIEW_API_BASE_URL": "", "WEEKLY_REVIEW_PROVIDER": "azure"]
        )) { error in
            XCTAssertEqual(error as? WeeklyReviewClientError, .notConfigured)
        }
    }
    #endif

    func testCancelledAuthorizationSendsNoRequest() async throws {
        ReviewURLProtocol.handler = { _ in
            XCTFail("Cancelled authorization must not transmit workout data")
            return (500, Data(), [:])
        }
        let provider = TestReviewTokenProvider()
        provider.failure = CancellationError()
        do {
            _ = try await client().generate(request(), tokenProvider: provider)
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRevokedConsentAfterAuthorizationSendsNoRequest() async throws {
        ReviewURLProtocol.handler = { _ in
            XCTFail("Revoked consent must prevent transmission even after successful Apple auth")
            return (500, Data(), [:])
        }
        let provider = TestReviewTokenProvider()
        do {
            _ = try await client().generate(request(), tokenProvider: provider, authorizeTransmission: {
                throw CancellationError()
            })
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(provider.calls, 1)
    }

    func testMalformedTokenSendsNoRequest() async throws {
        ReviewURLProtocol.handler = { _ in
            XCTFail("Invalid authorization must not transmit workout data")
            return (500, Data(), [:])
        }
        let provider = TestReviewTokenProvider()
        provider.token = "invalid\r\nheader"
        do {
            _ = try await client().generate(request(), tokenProvider: provider)
            XCTFail("Expected invalid credential")
        } catch { XCTAssertEqual(error as? WeeklyReviewClientError, .invalidCredential) }
    }

    private func assertClientError(_ expected: WeeklyReviewClientError,
                                   file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await client().generate(request(), tokenProvider: TestReviewTokenProvider())
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch { XCTAssertEqual(error as? WeeklyReviewClientError, expected, file: file, line: line) }
    }

    private func client(provider: WeeklyReviewAIProvider = .azure) throws -> WeeklyReviewClient {
        WeeklyReviewClient(configuration: try WeeklyReviewConfiguration(baseURL: "https://reviews.marathon.test", provider: provider),
                           protocolClasses: [ReviewURLProtocol.self])
    }

    private func stub(status: Int, data: Data) {
        ReviewURLProtocol.handler = { _ in (status, data, ["Content-Type": "application/json"]) }
    }

    private func request() -> WeeklyReviewRequestV1 {
        WeeklyReviewRequestV1(requestID: UUID(uuidString: "471EC7BE-3972-4F85-BD59-14FD08845517")!,
                             reviewedWeekStart: "2026-10-05", generatedAt: "2026-10-12T12:00:00Z",
                             timezone: "America/Denver", weekState: .complete,
                             dataFreshness: .init(healthKitSyncState: .complete, lastSuccessfulImportAt: "2026-10-12T11:00:00Z"),
                             plans: [.init(weekStart: "2026-10-05", requiredMiles: 12, requiredRuns: 3,
                                           plannedMilesByType: .init(recovery: 3, tempo: 4, long: 5))],
                             workouts: [.init(evidenceID: "w-test", weekStart: "2026-10-05", startedOn: "2026-10-07",
                                              runType: .tempo, distanceMiles: 4, durationSeconds: 2400,
                                              averageHeartRateBPM: nil, zoneSeconds: nil, source: .healthKit)],
                             physiology: nil, breakContext: .init(reason: .none, hasNote: false))
    }

    private func narrative(evidenceID: String = "m.current.actual_miles") -> [String: Any] {
        let item: [String: Any] = ["claim_code": "data_limited", "text": "Review the recorded training metrics.",
                                   "evidence_ids": [evidenceID]]
        return ["headline": item, "items": [], "next_focus": item]
    }

    private func responseData(for request: WeeklyReviewRequestV1,
                              transform: ((inout [String: Any]) -> Void)? = nil) throws -> Data {
        var value: [String: Any] = [
            "schema_version": "weekly-review-response/v1", "request_id": request.requestID.uuidString,
            "status": "complete", "data_quality_codes": [], "fallback_used": false,
            "review": narrative(),
            "metrics": [
                ["id": "m.current.actual_miles", "value": 4, "unit": "mi", "quality": "derived", "source_evidence_ids": ["w-test"]],
                ["id": "m.data.plan_available", "value": true, "unit": "boolean", "quality": "derived", "source_evidence_ids": []],
                ["id": "m.data.healthkit_sync_state", "value": "complete", "unit": "state", "quality": "measured", "source_evidence_ids": []],
                ["id": "m.vo2.latest", "value": NSNull(), "unit": "ml/kg/min", "quality": "missing", "source_evidence_ids": []]
            ]
        ]
        transform?(&value)
        return try JSONSerialization.data(withJSONObject: value)
    }
}

@MainActor
private final class TestReviewTokenProvider: WeeklyReviewTokenProviding {
    var token = "test.identity.token"
    var calls = 0
    var failure: Error?

    func freshIdentityToken() async throws -> String {
        calls += 1
        if let failure { throw failure }
        return token
    }
}

private final class ReviewURLProtocol: URLProtocol, @unchecked Sendable {
    @MainActor static var handler: ((URLRequest) throws -> (Int, Data, [String: String]))?

    nonisolated override class func canInit(with request: URLRequest) -> Bool { true }
    nonisolated override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    nonisolated override func startLoading() {
        Task { @MainActor in
            do {
                guard let handler = Self.handler, let url = request.url else { throw URLError(.badURL) }
                let (status, data, headers) = try handler(request)
                guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
                else { throw URLError(.badServerResponse) }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }

    nonisolated override func stopLoading() { }
}
