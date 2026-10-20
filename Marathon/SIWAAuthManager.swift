import Foundation
import AuthenticationServices
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

enum SIWAError: Error {
    case cancelled
    case failed
    case noAnchor
}

final class SIWAAuthManager: NSObject {
    static let shared = SIWAAuthManager()

    private var continuation: CheckedContinuation<(String, String?, String?), Error>?

    func signIn() async throws -> (userId: String, displayName: String?, initials: String?) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(String, String?, String?), Error>) in
            self.continuation = continuation

            // Ensure we create/present the controller on the main thread
            DispatchQueue.main.async {
                let provider = ASAuthorizationAppleIDProvider()
                let request = provider.createRequest()
                request.requestedScopes = [.fullName, .email]

                let controller = ASAuthorizationController(authorizationRequests: [request])
                controller.delegate = self
                controller.presentationContextProvider = self
                controller.performRequests()
            }
        }
    }
}

extension SIWAAuthManager: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let cont = continuation else { return }

        if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
            let userId = credential.user
            let name = credential.fullName

            let displayName: String? = {
                guard let n = name else { return nil }
                let formatter = PersonNameComponentsFormatter()
                let str = formatter.string(from: n).trimmingCharacters(in: .whitespacesAndNewlines)
                return str.isEmpty ? nil : str
            }()

            let initials: String? = {
                guard let n = name else { return nil }
                let first = n.givenName?.first.map(String.init) ?? ""
                let last = n.familyName?.first.map(String.init) ?? ""
                let combined = (first + last)
                return combined.isEmpty ? nil : combined.uppercased()
            }()

            cont.resume(returning: (userId, displayName, initials))
        } else {
            cont.resume(throwing: SIWAError.failed)
        }
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard let cont = continuation else { return }
        let nsError = error as NSError
        if nsError.code == ASAuthorizationError.canceled.rawValue {
            cont.resume(throwing: SIWAError.cancelled)
        } else {
            cont.resume(throwing: error)
        }
        continuation = nil
    }
}

extension SIWAAuthManager: ASAuthorizationControllerPresentationContextProviding {
    #if os(macOS)
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // Use the frontmost window if possible
        if let win = NSApplication.shared.windows.first(where: { $0.isVisible }) {
            return win
        }
        return NSWindow()
    }
    #else
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // Prefer the key window of the foreground active scene
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: { $0.isKeyWindow }) {
            return window
        }
        // Fallback: any window we can find
        if let any = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first {
            return any
        }
        // Last resort (shouldn't happen in practice): create a window from any available scene.
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            return UIWindow(windowScene: scene)
        }
        preconditionFailure("No UIWindowScene available for SIWA presentation anchor.")
    }
    #endif
}
