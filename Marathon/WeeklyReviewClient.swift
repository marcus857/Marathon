import Foundation

enum WeeklyReviewStatus: String, Decodable, Equatable, Sendable {
    case complete
    case limitedData = "limited_data"
    case insufficientData = "insufficient_data"
    case unavailable
}

enum WeeklyReviewMetricQuality: String, Decodable, Equatable, Sendable {
    case measured, derived, missing
}

enum WeeklyReviewMetricValue: Decodable, Equatable, Sendable {
    case number(Double)
    case text(String)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Double.self), value.isFinite { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .text(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid metric value.") }
    }
}

struct WeeklyReviewMetric: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let value: WeeklyReviewMetricValue
    let unit: String
    let quality: WeeklyReviewMetricQuality
    let sourceEvidenceIDs: [String]

    enum CodingKeys: String, CodingKey {
        case id, value, unit, quality
        case sourceEvidenceIDs = "source_evidence_ids"
    }
}

enum WeeklyReviewClaimCode: String, Decodable, Equatable, Sendable {
    case mileageBelowPlan = "mileage_below_plan"
    case mileageMetPlan = "mileage_met_plan"
    case runsBelowPlan = "runs_below_plan"
    case runsMetPlan = "runs_met_plan"
    case currentWeekInProgress = "current_week_in_progress"
    case latestVO2Recorded = "latest_vo2_recorded"
    case dataLimited = "data_limited"
    case noRecordedWorkouts = "no_recorded_workouts"
}

struct WeeklyReviewItem: Decodable, Equatable, Sendable {
    let claimCode: WeeklyReviewClaimCode
    let text: String
    let evidenceIDs: [String]

    enum CodingKeys: String, CodingKey {
        case claimCode = "claim_code"
        case text
        case evidenceIDs = "evidence_ids"
    }
}

struct WeeklyReviewNarrative: Decodable, Equatable, Sendable {
    let headline: WeeklyReviewItem
    let items: [WeeklyReviewItem]
    let nextFocus: WeeklyReviewItem

    enum CodingKeys: String, CodingKey {
        case headline, items
        case nextFocus = "next_focus"
    }
}

struct WeeklyReviewResponseV1: Decodable, Equatable, Sendable {
    let schemaVersion: String
    let requestID: UUID
    let status: WeeklyReviewStatus
    let dataQualityCodes: [String]
    let metrics: [WeeklyReviewMetric]
    let review: WeeklyReviewNarrative
    let fallbackUsed: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case status
        case dataQualityCodes = "data_quality_codes"
        case metrics, review
        case fallbackUsed = "fallback_used"
    }

    /// Validate the service boundary before displaying any generated text.
    /// Claim semantics are additionally checked by the server against its metrics.
    func validate(for request: WeeklyReviewRequestV1) throws {
        guard schemaVersion == "weekly-review-response/v1", requestID == request.requestID,
              metrics.count <= 32, dataQualityCodes.count <= 12, review.items.count <= 3,
              dataQualityCodes.allSatisfy({ $0.range(of: "^[a-z0-9_]{1,80}$", options: .regularExpression) != nil })
        else { throw WeeklyReviewClientError.invalidResponse }

        let metricIDs = Set(metrics.map(\.id))
        let workoutIDs = Set(request.workouts.map(\.evidenceID))
        guard metricIDs.count == metrics.count else { throw WeeklyReviewClientError.invalidResponse }
        for metric in metrics {
            guard metric.id.range(of: "^m\\.[a-z0-9_.-]{1,80}$", options: .regularExpression) != nil,
                  metric.unit.count <= 40, metric.sourceEvidenceIDs.count <= 80,
                  Set(metric.sourceEvidenceIDs).isSubset(of: workoutIDs)
            else { throw WeeklyReviewClientError.invalidResponse }
            if case .text(let value) = metric.value, value.count > 280 {
                throw WeeklyReviewClientError.invalidResponse
            }
        }
        for item in [review.headline] + review.items + [review.nextFocus] {
            guard !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.text.count <= 280, (1...6).contains(item.evidenceIDs.count),
                  Set(item.evidenceIDs).isSubset(of: metricIDs)
            else { throw WeeklyReviewClientError.invalidResponse }
        }
    }
}

enum WeeklyReviewClientError: LocalizedError, Equatable {
    case notConfigured, invalidConfiguration, invalidCredential, unauthorized, rateLimited
    case providerNotConfigured, invalidProvider, providerChanged
    case serviceUnavailable, invalidRequest, invalidResponse, responseTooLarge, redirectRejected
    case networkUnavailable

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Weekly reviews need a configured review-service URL."
        case .invalidConfiguration: return "The review-service URL must be a valid HTTPS address."
        case .providerNotConfigured: return "Weekly reviews need an explicitly configured AI provider: azure or openai."
        case .invalidProvider: return "The review provider must be azure or openai. A ChatGPT subscription is not API configuration."
        case .providerChanged: return "The app and service AI providers do not match. Update their provider configuration before retrying. No AI review was generated."
        case .invalidCredential: return "Apple sign-in did not return a valid review credential. Try again."
        case .unauthorized: return "Your review authorization was not accepted. Sign in with Apple and try again."
        case .rateLimited: return "The review service is busy. Please wait before trying again."
        case .serviceUnavailable: return "The review service is unavailable. Please try again later."
        case .invalidRequest: return "This week's data could not be accepted by the review service. Refresh and try again."
        case .invalidResponse: return "The review service returned an invalid response. No review was displayed."
        case .responseTooLarge: return "The review response exceeded the safety limit. No review was displayed."
        case .redirectRejected: return "The review-service address redirected. Check the configured address before retrying."
        case .networkUnavailable: return "Could not reach the review service. Check your connection and try again."
        }
    }
}

enum WeeklyReviewAIProvider: String, Equatable, Sendable {
    case azure
    case openai

    var displayName: String {
        switch self {
        case .azure: return "Microsoft Azure OpenAI"
        case .openai: return "OpenAI"
        }
    }

    init(configuredValue: String?) throws {
        let value = configuredValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty, !value.contains("$("), value != "disabled" else {
            throw WeeklyReviewClientError.providerNotConfigured
        }
        guard let provider = Self(rawValue: value) else { throw WeeklyReviewClientError.invalidProvider }
        self = provider
    }
}

struct WeeklyReviewConfiguration: Equatable, Sendable {
    let baseURL: URL
    let provider: WeeklyReviewAIProvider
    var endpoint: URL { baseURL.appendingPathComponent("v1/weekly-reviews") }

    init(baseURL value: String, provider: WeeklyReviewAIProvider) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { throw WeeklyReviewClientError.notConfigured }
        guard let parts = URLComponents(string: trimmed), parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              !trimmed.contains("<"), !trimmed.contains(">"),
              !trimmed.contains(where: \.isWhitespace),
              !["example.com", "example.org", "example.net"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              !host.hasSuffix(".example"), !host.hasSuffix(".invalid"),
              let url = parts.url
        else { throw WeeklyReviewClientError.invalidConfiguration }
        baseURL = url
        self.provider = provider
    }

    static func load(bundle: Bundle = .main,
                     environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        var urlValue = bundle.object(forInfoDictionaryKey: "WeeklyReviewAPIBaseURL") as? String ?? ""
        var providerValue = bundle.object(forInfoDictionaryKey: "WeeklyReviewAIProvider") as? String
        #if DEBUG
        // An explicit empty override also fails closed; it must not silently
        // reuse a bundled destination or provider the developer did not choose.
        if let value = environment["WEEKLY_REVIEW_API_BASE_URL"] { urlValue = value }
        if let value = environment["WEEKLY_REVIEW_PROVIDER"] { providerValue = value }
        #endif
        let provider = try WeeklyReviewAIProvider(configuredValue: providerValue)
        return try Self(baseURL: urlValue, provider: provider)
    }
}

@MainActor
protocol WeeklyReviewTokenProviding {
    func freshIdentityToken() async throws -> String
}

/// Every generation has its own non-persistent session. Credentials and health
/// data are never sent to redirect destinations, cached, logged, or saved here.
@MainActor
final class WeeklyReviewClient {
    private let configuration: WeeklyReviewConfiguration
    private let protocolClasses: [AnyClass]?
    private static let maximumResponseBytes = 128 * 1024

    init(configuration: WeeklyReviewConfiguration, protocolClasses: [AnyClass]? = nil) {
        self.configuration = configuration
        self.protocolClasses = protocolClasses
    }

    func generate(_ input: WeeklyReviewRequestV1,
                  tokenProvider: (any WeeklyReviewTokenProviding)? = nil,
                  authorizeTransmission: @MainActor () throws -> Void = {}) async throws -> WeeklyReviewResponseV1 {
        try Task.checkCancellation()
        let body: Data
        do { body = try JSONEncoder().encode(input) }
        catch { throw WeeklyReviewClientError.invalidRequest }
        guard body.count <= 128 * 1024 else { throw WeeklyReviewClientError.invalidRequest }

        let token = try await (tokenProvider ?? WeeklyReviewAuthorization.shared).freshIdentityToken()
        try Task.checkCancellation()
        guard !token.isEmpty, token.utf8.count <= 8_192,
              !token.contains(where: { $0.isWhitespace || $0.isNewline }),
              token.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.controlCharacters.contains($0) })
        else { throw WeeklyReviewClientError.invalidCredential }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.timeoutIntervalForRequest = 45
        sessionConfiguration.timeoutIntervalForResource = 60
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.protocolClasses = protocolClasses
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: configuration.endpoint, timeoutInterval: 45)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(configuration.provider.rawValue, forHTTPHeaderField: "X-Weekly-Review-Provider")

        // Recheck live UI consent/identity after the Apple prompt, immediately
        // before transmission; SwiftUI's deferred onChange alone is not enough.
        try Task.checkCancellation()
        try authorizeTransmission()
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: WeeklyReviewRedirectDelegate())
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw WeeklyReviewClientError.invalidResponse }
            switch response.statusCode {
            case 200: break
            case 300...399: throw WeeklyReviewClientError.redirectRejected
            case 401, 403: throw WeeklyReviewClientError.unauthorized
            case 409: throw WeeklyReviewClientError.providerChanged
            case 429: throw WeeklyReviewClientError.rateLimited
            case 400, 413, 422: throw WeeklyReviewClientError.invalidRequest
            default: throw WeeklyReviewClientError.serviceUnavailable
            }
            guard response.mimeType?.lowercased() == "application/json" else { throw WeeklyReviewClientError.invalidResponse }
            guard response.expectedContentLength <= Int64(Self.maximumResponseBytes) else { throw WeeklyReviewClientError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maximumResponseBytes else { throw WeeklyReviewClientError.responseTooLarge }
                data.append(byte)
            }
            let result: WeeklyReviewResponseV1
            do { result = try JSONDecoder().decode(WeeklyReviewResponseV1.self, from: data) }
            catch { throw WeeklyReviewClientError.invalidResponse }
            try result.validate(for: input)
            return result
        } catch is CancellationError { throw CancellationError() }
        catch let error as WeeklyReviewClientError { throw error }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw WeeklyReviewClientError.networkUnavailable
        }
    }
}

final class WeeklyReviewRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                               willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest,
                               completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
