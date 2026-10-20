import Foundation

struct NotificationPrefs: Codable, Equatable, Sendable {
    var userId: String
    var pushNewWorkouts: Bool = true
    var pushLikes: Bool = true
    var pushComments: Bool = true
    var localCongrats: Bool = true
    // Sharing team-feed workout data must be an explicit, revocable choice.
    var shareByDefault: Bool = false
    var teamId: String = "default"

    nonisolated static func defaults(for userId: String, teamId: String = "default") -> NotificationPrefs {
        NotificationPrefs(userId: userId,
                          pushNewWorkouts: true,
                          pushLikes: true,
                          pushComments: true,
                          localCongrats: true,
                          shareByDefault: false,
                          teamId: teamId)
    }
}
