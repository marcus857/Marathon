import Foundation

/// Feature gate for the privacy-preserving CloudKit migration.
///
/// V2 is deliberately disabled until the CloudKit Dashboard schema, roles, and
/// two-account device tests have been completed. Legacy public records must not
/// be silently repurposed as V2 data.
enum CloudSyncV2 {
    static let schemaVersion = 2
    static let isEnabled = false
}

/// Private-only metadata that links a full personal workout to an optional,
/// intentionally minimized team-feed projection. This type never belongs in a
/// public CloudKit record.
enum TeamProjectionOutboxState: String, Codable, Sendable {
    case none
    case pendingUpsert
    case published
    case pendingDeletion
}

struct PersonalWorkoutProjectionLink: Codable, Equatable, Sendable {
    /// The private workout identifier. It may contain HealthKit/Strava-derived
    /// material and must never be used as a public record name.
    var workoutID: String
    /// A random public identifier generated only after explicit sharing consent.
    var projectionID: String?
    var state: TeamProjectionOutboxState
}

/// Private profile data for the future `PersonalProfile` record type.
/// `memberID` is a separately generated public alias; it is never inferred from
/// the Sign in with Apple subject or the CloudKit user-record name.
struct PersonalProfileV2: Codable, Equatable, Sendable {
    var signInWithAppleSubject: String
    var displayName: String
    var initials: String
    var colorHex: String
    var memberID: String
    var activeTeamID: String?
    var schemaVersion: Int = CloudSyncV2.schemaVersion
}

/// The only profile data intended for a future public team-feed record.
struct TeamMemberProjection: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var teamID: String
    var displayAlias: String
    var initials: String
    var colorHex: String
    var schemaVersion: Int = CloudSyncV2.schemaVersion

    enum CodingKeys: String, CodingKey {
        case id = "member_id"
        case teamID = "team_id"
        case displayAlias = "display_alias"
        case initials
        case colorHex = "color_hex"
        case schemaVersion = "schema_version"
    }
}

/// A deliberately small public summary of an explicitly shared workout.
///
/// It contains no personal workout ID, user/profile ID, HealthKit/Strava ID,
/// note, source, route, heart-rate value, zone data, or exact timestamp.
struct TeamWorkoutProjection: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var teamID: String
    var memberID: String
    /// Start of the local activity day, rather than the exact workout time.
    var activityDay: Date
    /// Rounded to the nearest tenth of a mile before it leaves the device.
    var distanceMiles: Double
    /// Rounded to the nearest five minutes; omitted when duration is invalid.
    var durationMinutes: Int?
    var runType: RunType
    var schemaVersion: Int = CloudSyncV2.schemaVersion

    enum CodingKeys: String, CodingKey {
        case id = "projection_id"
        case teamID = "team_id"
        case memberID = "member_id"
        case activityDay = "activity_day"
        case distanceMiles = "distance_miles"
        case durationMinutes = "duration_minutes"
        case runType = "run_type"
        case schemaVersion = "schema_version"
    }
}

/// The allowlist boundary between a personal `WorkoutEntry` and a team feed.
/// Keep this mapper pure and covered by tests: it is the only path V2 should use
/// to construct a public workout projection.
enum TeamProjectionMapper {
    static func member(from profile: UserProfile,
                       teamID: String,
                       memberID: String) -> TeamMemberProjection? {
        let alias = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let initials = profile.initials.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !teamID.isEmpty, !memberID.isEmpty, !alias.isEmpty, !initials.isEmpty else {
            return nil
        }

        return TeamMemberProjection(
            id: memberID,
            teamID: teamID,
            displayAlias: String(alias.prefix(40)),
            initials: String(initials.prefix(8)),
            colorHex: profile.colorHex,
            schemaVersion: CloudSyncV2.schemaVersion
        )
    }

    static func workout(from workout: WorkoutEntry,
                        teamID: String,
                        memberID: String,
                        projectionID: String = UUID().uuidString.lowercased(),
                        calendar: Calendar = .current) -> TeamWorkoutProjection? {
        guard !teamID.isEmpty, !memberID.isEmpty, !projectionID.isEmpty else { return nil }

        let miles = workout.miles
        guard miles.isFinite, miles > 0, miles <= 200 else { return nil }

        let roundedMiles = (miles * 10).rounded() / 10
        let durationMinutes: Int?
        if workout.durationSec.isFinite, workout.durationSec > 0, workout.durationSec <= 86_400 {
            let rawMinutes = workout.durationSec / 60
            durationMinutes = Int((rawMinutes / 5).rounded() * 5)
        } else {
            durationMinutes = nil
        }

        return TeamWorkoutProjection(
            id: projectionID,
            teamID: teamID,
            memberID: memberID,
            activityDay: calendar.startOfDay(for: workout.start),
            distanceMiles: roundedMiles,
            durationMinutes: durationMinutes,
            runType: workout.runType,
            schemaVersion: CloudSyncV2.schemaVersion
        )
    }
}
