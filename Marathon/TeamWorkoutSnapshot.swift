import Foundation

/// Reconciles a complete CloudKit result, not a page or a delta. Teammate
/// workouts absent from the snapshot must disappear from every tab, including
/// when their owner deleted them, stopped sharing them, or changed teams.
enum TeamWorkoutSnapshot {
    /// Retain the selected alias when it still belongs to this iCloud account.
    /// An already-matching profile is a successful lookup, not a sign-out.
    static func linkedProfile(
        in users: [UserProfile],
        ownerRecordName: String,
        currentUserID: String
    ) -> UserProfile? {
        guard !ownerRecordName.isEmpty else { return nil }
        return users.first {
            $0.id == currentUserID && $0.ownerUserRecordName == ownerRecordName
        } ?? users.first {
            $0.ownerUserRecordName == ownerRecordName
        }
    }

    static func reconcile(
        local: [WorkoutEntry],
        remote: [WorkoutEntry],
        currentUserID: String,
        teamID: String,
        since: Date,
        preservingLocalIDs: Set<String> = [],
        deletedIDs: Set<String> = []
    ) -> [WorkoutEntry] {
        // Personal history may include private and not-yet-uploaded workouts.
        // Do not use a team snapshot to delete it, even outside its date window.
        var entries: [String: WorkoutEntry] = [:]
        for workout in local where workout.userId == currentUserID && !deletedIDs.contains(workout.id) {
            entries[workout.id] = workout
        }

        for workout in remote where workout.start >= since && !deletedIDs.contains(workout.id) {
            let isMine = workout.userId == currentUserID
            guard isMine || (workout.isShared && workout.teamId == teamID) else { continue }

            if let personal = entries[workout.id], personal.userId == currentUserID {
                // A colliding remote identifier must never replace personal data
                // with another member's data. Unshared local entries also win:
                // they may contain edits that have not been uploaded yet.
                guard isMine, personal.isShared, !preservingLocalIDs.contains(workout.id) else { continue }
                var updated = workout
                updated.healthKitUUID = workout.healthKitUUID ?? personal.healthKitUUID
                updated.stravaActivityId = workout.stravaActivityId ?? personal.stravaActivityId
                entries[workout.id] = updated
            } else {
                // Replace the entire teammate entry so removed optional fields
                // do not survive as stale notes, heart rate, or zone values.
                entries[workout.id] = workout
            }
        }

        return entries.values.sorted {
            $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start
        }
    }
}
