import AuthenticationServices
import UIKit

enum WeeklyReviewAuthorizationError: LocalizedError, Equatable {
    case cancelled, alreadyInProgress, unavailable, failed

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Weekly review sign-in was cancelled."
        case .alreadyInProgress: return "Apple sign-in is already in progress."
        case .unavailable: return "Apple sign-in needs an active app window."
        case .failed: return "Apple sign-in could not authorize this review. Please try again."
        }
    }
}

/// Separate from profile onboarding: authenticates this one API request only.
/// No token, name, email, or Apple identifier is stored in app persistence.
@MainActor
final class WeeklyReviewAuthorization: NSObject, WeeklyReviewTokenProviding {
    static let shared = WeeklyReviewAuthorization()

    private var continuation: CheckedContinuation<String, Error>?
    private var controller: ASAuthorizationController?
    private var anchor: ASPresentationAnchor?
    private var operationID: UUID?

    func freshIdentityToken() async throws -> String {
        try Task.checkCancellation()
        guard continuation == nil else { throw WeeklyReviewAuthorizationError.alreadyInProgress }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard let window = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .filter({ $0.activationState == .foregroundActive })
                    .flatMap(\.windows)
                    .first(where: \.isKeyWindow) else {
                    continuation.resume(throwing: WeeklyReviewAuthorizationError.unavailable)
                    return
                }
                self.continuation = continuation
                self.operationID = id
                self.anchor = window
                let request = ASAuthorizationAppleIDProvider().createRequest()
                request.requestedScopes = []
                let controller = ASAuthorizationController(authorizationRequests: [request])
                self.controller = controller
                controller.delegate = self
                controller.presentationContextProvider = self
                controller.performRequests()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.operationID == id else { return }
                let controller = self.controller
                self.finish(.failure(CancellationError()))
                controller?.cancel()
            }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        let pending = continuation
        continuation = nil
        controller = nil
        anchor = nil
        operationID = nil
        pending?.resume(with: result)
    }
}

extension WeeklyReviewAuthorization: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard controller === self.controller else { return }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.identityToken,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            finish(.failure(WeeklyReviewClientError.invalidCredential))
            return
        }
        finish(.success(token))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard controller === self.controller else { return }
        let cancelled = (error as? ASAuthorizationError)?.code == .canceled
        finish(.failure(cancelled ? WeeklyReviewAuthorizationError.cancelled : WeeklyReviewAuthorizationError.failed))
    }
}

extension WeeklyReviewAuthorization: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // An active window is retained before performRequests and throughout
        // authorization; no dummy window or fatal assertion is needed.
        anchor ?? ASPresentationAnchor()
    }
}
