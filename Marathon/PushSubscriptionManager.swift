// PushSubscriptionManager.swift
import Foundation
import CloudKit
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// Central place to manage APNs registration and CloudKit query subscriptions.
final class PushSubscriptionManager: NSObject {
    static let shared = PushSubscriptionManager()
    private override init() {}

    // MARK: - APNs Registration

    /// Request notification authorization (alerts, badges, sounds) and register with APNs.
    /// Safe to call multiple times; it will no-op if already authorized/registered.
    func registerForRemoteNotifications() {
        #if canImport(UIKit)
        Task {
            let center = UNUserNotificationCenter.current()

            // Set ourselves as delegate so we can present banners when app is foreground.
            await MainActor.run {
                center.delegate = self
            }

            do {
                _ = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            } catch {
                print("Notification authorization request failed: \(error)")
            }

            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
        #else
        // Non-UIKit platforms can ignore APNs registration here.
        #endif
    }

    /// Optional helper for AppDelegate/SceneDelegate to forward the device token (for debugging/logging).
    func didRegisterForRemoteNotifications(withDeviceToken token: Data) {
        #if DEBUG
        print("APNs device token registered (redacted).")
        #endif
    }

    /// Optional helper for AppDelegate/SceneDelegate to log registration failures.
    func didFailToRegisterForRemoteNotifications(error: Error) {
        print("Failed to register for remote notifications: \(error)")
    }

    // MARK: - Subscriptions

    /// Rebuild (create/update/delete) all CloudKit subscriptions for the given user and prefs.
    /// Idempotent: safe to call any time (e.g., on login or when prefs change).
    func rebuildAllSubscriptions(for userId: String, prefs: NotificationPrefs) {
        Task {
            // A pruning failure must not prevent installing the current sync subscriptions.
            do {
                try await pruneStaleSubscriptions(keepingUserId: userId,
                                                  teamId: prefs.teamId,
                                                  enableLikes: prefs.pushLikes,
                                                  enableComments: prefs.pushComments)
            } catch {
                print("Prune subscriptions failed: \(error)")
            }
            do {
                // Silent data synchronization is independent of alert preferences.
                try await CloudKitManager.shared.ensureTeamFeedPushSubscription(forTeamId: prefs.teamId)
                try await CloudKitManager.shared.ensureLikeSyncSubscription(forUserId: userId)

                // Likes
                if prefs.pushLikes {
                    try await CloudKitManager.shared.ensureLikePushSubscription(forUserId: userId)
                } else {
                    try await CloudKitManager.shared.removeLikePushSubscription(forUserId: userId)
                }

                // Comments (owner + mentions)
                if prefs.pushComments {
                    try await CloudKitManager.shared.ensureCommentPushSubscriptions(forUserId: userId)
                } else {
                    try await CloudKitManager.shared.removeCommentPushSubscriptions(forUserId: userId)
                }
            } catch {
                print("Rebuild subscriptions failed: \(error)")
            }
        }
    }

    /// Remove or keep existing subscriptions so that toggling prefs or switching users reflects immediately.
    private func pruneStaleSubscriptions(keepingUserId userId: String,
                                         teamId: String,
                                         enableLikes: Bool,
                                         enableComments: Bool) async throws {
        let db = try await CloudKitManager.shared.subscriptionDatabase()

        let existing: [CKSubscription] = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[CKSubscription], Error>) in
            db.fetchAllSubscriptions { subs, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: subs ?? [])
                }
            }
        }

        let keepTeamId = "teamfeed_\(teamId)"
        let keepLikeId = enableLikes ? "likes_to_\(userId)" : nil
        let keepLikeSyncId = "likes_sync_\(userId)"
        let keepCommentOwnerId = enableComments ? "comments_to_\(userId)" : nil
        let keepCommentMentionId = enableComments ? "comments_mentions_\(userId)" : nil

        var toDelete: [String] = []
        for s in existing {
            let id = s.subscriptionID

            if id.hasPrefix("teamfeed_") {
                if id != keepTeamId {
                    toDelete.append(id)
                }
                continue
            }
            if id.hasPrefix("likes_to_") {
                if id != keepLikeId {
                    toDelete.append(id)
                }
                continue
            }
            if id.hasPrefix("likes_sync_") {
                if id != keepLikeSyncId {
                    toDelete.append(id)
                }
                continue
            }
            if id.hasPrefix("comments_to_") {
                if id != keepCommentOwnerId {
                    toDelete.append(id)
                }
                continue
            }
            if id.hasPrefix("comments_mentions_") {
                if id != keepCommentMentionId {
                    toDelete.append(id)
                }
                continue
            }
        }

        guard !toDelete.isEmpty else { return }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let op = CKModifySubscriptionsOperation(subscriptionsToSave: [], subscriptionIDsToDelete: toDelete)
            op.modifySubscriptionsResultBlock = { result in
                switch result {
                case .success:
                    cont.resume(returning: ())
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
            db.add(op)
        }
    }

    // MARK: - Push payload handling (stubs)

    /// Handle a remote notification payload. Returns true if it looks like a CloudKit push.
    /// Route to feed/workout detail later (stubbed here).
    @discardableResult
    func handleRemoteNotification(userInfo: [AnyHashable: Any]) -> Bool {
        guard let ckNote = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            return false
        }

        switch ckNote.notificationType {
        case .query:
            if let q = ckNote as? CKQueryNotification {
                let subID = q.subscriptionID ?? "(unknown)"
                let recID = q.recordID?.recordName ?? "(no record)"
                let reason = q.queryNotificationReason
                print("CK push (query): sub=\(subID), record=\(recID), reason=\(reason.rawValue)")

                NotificationCenter.default.post(name: .didReceiveCloudKitPush,
                                                object: nil,
                                                userInfo: ["subscriptionID": subID,
                                                           "recordID": recID,
                                                           "reason": reason.rawValue])
            } else {
                print("CK push (non-query type) received.")
            }
            return true

        default:
            print("CK push (type \(ckNote.notificationType.rawValue)) received.")
            return true
        }
    }
}

// Simple notification to let view models refresh when a CK push arrives (optional).
extension Notification.Name {
    static let didReceiveCloudKitPush = Notification.Name("didReceiveCloudKitPush")
}

extension PushSubscriptionManager: UNUserNotificationCenterDelegate {
    // Present banners/sounds when app is in foreground so likes are visible immediately.
    @MainActor
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    // Optional: handle taps if you want to route to a screen later.
    @MainActor
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
