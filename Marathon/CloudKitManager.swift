//
//  CKTypes.swift
//  Marathon
//
//  Created by Marcus Price on 11/12/25.
//

import Foundation
import CloudKit

// Clear, local errors for ownership failures (no UI here).
enum CloudKitOwnershipError: LocalizedError {
    case unclaimedProfile(userId: String)
    case accountUnavailable
    case accountMismatch(userId: String, expectedOwner: String, currentAccount: String)
    case recordSubjectMismatch(recordID: String, existingUserID: String, requestedUserID: String)

    var errorDescription: String? {
        switch self {
        case .unclaimedProfile(let userId):
            return "Profile '\(userId)' has not been claimed by any iCloud account. Select this profile on a device signed into the intended iCloud account to claim it before making changes."
        case .accountUnavailable:
            return "Unable to confirm the current iCloud account. Please try again when iCloud is available."
        case .accountMismatch(let userId, let expected, let current):
            return "You are signed into iCloud as '\(current)', but profile '\(userId)' is owned by '\(expected)'. Switch iCloud accounts or select your own profile to make changes."
        case .recordSubjectMismatch(let recordID, let existing, let requested):
            return "Cloud record '\(recordID)' belongs to profile '\(existing)', not '\(requested)'."
        }
    }
}

enum CloudKitReadError: LocalizedError {
    case unavailable
    case invalidRecord

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "iCloud is unavailable. Showing the last successfully synced data."
        case .invalidRecord:
            return "Some cloud records could not be read. Keeping the last successfully synced data."
        }
    }
}

// MARK: - CloudKit Record Keys

private enum CKTypes {
    nonisolated static let userProfile = "UserProfile"
    nonisolated static let workoutEntry = "WorkoutEntry"
    nonisolated static let planOverride = "PlanOverride"
    // New: Workout likes (kudos)
    nonisolated static let workoutLike = "WorkoutLike"
    // New: Workout comments
    nonisolated static let workoutComment = "WorkoutComment"
    // New: Notification preferences
    nonisolated static let notificationPrefs = "NotificationPrefs"
}

private enum CKUserKeys {
    nonisolated static let displayName = "displayName"
    nonisolated static let initials = "initials"
    nonisolated static let colorHex = "colorHex"
    // New: profile owner linkage to the device's iCloud account (CloudKit user record name)
    nonisolated static let ownerUserRecordName = "ownerUserRecordName"
}

private enum CKWorkoutKeys {
    nonisolated static let userId = "userId"
    nonisolated static let start = "start"
    nonisolated static let end = "end"
    nonisolated static let distanceMeters = "distanceMeters"
    nonisolated static let durationSec = "durationSec"
    nonisolated static let avgHR = "avgHR"
    nonisolated static let source = "source"
    nonisolated static let runType = "runType"
    nonisolated static let isManual = "isManual"
    nonisolated static let notes = "notes"
    // New: heart-rate zones
    nonisolated static let zoneDurations = "zoneDurations" // [Double] count 5
    nonisolated static let zoneTotal = "zoneTotal"         // Double
    nonisolated static let restingHR = "restingHR"         // Int
    // New: team feed sharing
    nonisolated static let isShared = "isShared"           // historically Bool OR Int64(0/1)
    nonisolated static let teamId = "teamId"               // String
    nonisolated static let sharedRoutePoints = "sharedRoutePoints" // [Double] flattened lat/lon pairs
}

private enum CKPlanOverrideKeys {
    nonisolated static let weekStart = "weekStart"
    nonisolated static let recovery = "recovery"
    nonisolated static let tempo = "tempo"
    nonisolated static let long = "long"
    nonisolated static let note = "note"
}

// New: Workout Like keys
private enum CKLikeKeys {
    nonisolated static let workoutId = "workoutId"
    nonisolated static let fromUserId = "fromUserId"
    nonisolated static let toUserId = "toUserId"
    nonisolated static let createdAt = "createdAt"
}

// New: Workout Comment keys
private enum CKCommentKeys {
    nonisolated static let workoutId = "workoutId"
    nonisolated static let fromUserId = "fromUserId"
    nonisolated static let toUserId = "toUserId"
    nonisolated static let text = "text"
    nonisolated static let mentionedUserIds = "mentionedUserIds"
    nonisolated static let createdAt = "createdAt"
}

// New: Notification Prefs keys
private enum CKNotifKeys {
    nonisolated static let userId = "userId"
    nonisolated static let pushNewWorkouts = "pushNewWorkouts"
    nonisolated static let pushLikes = "pushLikes"
    nonisolated static let pushComments = "pushComments"
    nonisolated static let localCongrats = "localCongrats"
    nonisolated static let shareByDefault = "shareByDefault"
    nonisolated static let teamId = "teamId"
}

// Simple model to return likes with user ids for display.
struct WorkoutLike: Identifiable, Codable, Hashable {
    let id: String            // CK recordName
    let workoutId: String
    let fromUserId: String
    let toUserId: String
    let createdAt: Date
}

final class CloudKitManager {
    static let shared = CloudKitManager()
    nonisolated static var teamSharedHistoryStartDate: Date {
        var comps = DateComponents()
        comps.year = 2025
        comps.month = 10
        comps.day = 1
        comps.hour = 0
        comps.minute = 0
        comps.second = 0
        return Calendar.current.date(from: comps) ?? Date(timeIntervalSince1970: 1_759_276_800)
    }

    // ENABLE CloudKit for production use.
    private let cloudKitTemporarilyDisabled = false

    // Must exactly match the container enabled in Signing & Capabilities.
    private let containerId = "iCloud.com.Marcus.Marathon"

    private var container: CKContainer?
    private var db: CKDatabase?

    private enum Availability {
        case unknown
        case enabled
        case disabled(String)
    }
    private var availability: Availability = .unknown
    private var hasLoggedAvailability = false

    private let wantsExplicitContainer: Bool

    private init() {
        wantsExplicitContainer = !containerId.contains("yourbundle")

        let runningInPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        let runningUnitTests = ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil

        if cloudKitTemporarilyDisabled {
            container = nil
            db = nil
            availability = .disabled("CloudKit temporarily disabled in this build.")
            logAvailabilityOnce("CloudKit disabled: temporarily disabled in this build.")
        } else if runningUnitTests {
            // Unit tests exercise synthetic data, never a live account. Unsigned
            // simulator hosts cannot construct CKContainer without trapping.
            container = nil
            db = nil
            availability = .disabled("Live CloudKit is disabled during unit tests.")
        } else if runningInPreview {
            container = nil
            db = nil
            availability = .disabled("Running in SwiftUI Previews (no CloudKit entitlements).")
            logAvailabilityOnce("CloudKit disabled: SwiftUI Previews host has no CloudKit entitlements.")
        } else if !Self.hasCloudKitEntitlement() {
            container = nil
            db = nil
            availability = .disabled("Missing iCloud/CloudKit entitlements. Enable iCloud → CloudKit in Signing & Capabilities.")
            logAvailabilityOnce("CloudKit disabled: missing iCloud/CloudKit entitlements.")
        } else {
            if wantsExplicitContainer {
                container = CKContainer(identifier: containerId)
            } else {
                container = CKContainer.`default`()
            }
            db = container?.publicCloudDatabase

            Task { _ = await isCloudKitEnabled() }
        }
    }

    // MARK: - Public helper (optional for callers)

    func refreshAvailability() {
        availability = .unknown
    }

    /// Subscription maintenance must use the same explicit container as data reads.
    func subscriptionDatabase() async throws -> CKDatabase {
        guard await isCloudKitEnabled(), let db else { throw CloudKitReadError.unavailable }
        return db
    }

    // MARK: - Users

    func fetchAllUsers() async throws -> [UserProfile] {
        guard await isCloudKitEnabled(), db != nil else { throw CloudKitReadError.unavailable }
        let query = CKQuery(recordType: CKTypes.userProfile, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: CKUserKeys.displayName, ascending: true)]
        let records = try await fetchAllRecords(query: query, requireCompleteResults: true)
        return try records.map {
            guard let user = Self.user(from: $0) else { throw CloudKitReadError.invalidRecord }
            return user
        }
    }

    func upsertUser(_ user: UserProfile) async throws {
        guard await isCloudKitEnabled() else { return }
        let recordId = CKRecord.ID(recordName: user.id)
        let record = try await fetchOrCreateRecord(id: recordId, type: CKTypes.userProfile)

        // Never overwrite a profile claimed by another iCloud account. This
        // remains a client-side guard in V1, but it prevents accidental edits
        // through the app while the public-database design is being retired.
        if let currentOwner = await currentUserRecordName() {
            let existing = record[CKUserKeys.ownerUserRecordName] as? String
            if let existing, !existing.isEmpty, existing != currentOwner {
                throw CloudKitOwnershipError.accountMismatch(userId: user.id,
                                                             expectedOwner: existing,
                                                             currentAccount: currentOwner)
            }
            if existing == nil || existing?.isEmpty == true || existing == currentOwner {
                record[CKUserKeys.ownerUserRecordName] = currentOwner as CKRecordValue
            }
        }

        record[CKUserKeys.displayName] = user.displayName as CKRecordValue
        record[CKUserKeys.initials] = user.initials as CKRecordValue
        record[CKUserKeys.colorHex] = user.colorHex as CKRecordValue

        // Save, but if Production schema doesn't have ownerUserRecordName yet,
        // retry without that field so onboarding isn't blocked.
        do {
            _ = try await save(record)
        } catch {
            if Self.isProdSchemaMissingOwnerField(error) {
                print("CloudKit: ownerUserRecordName not in Production schema yet. Saving without it.")
                record[CKUserKeys.ownerUserRecordName] = nil
                _ = try await save(record)
            } else {
                throw error
            }
        }
    }

    // Resolve the signed-in iCloud account (CloudKit user record) to the linked UserProfile via ownerUserRecordName.
    // Falls back to fetching all users and filtering locally if the field/index isn't queryable yet.
    func fetchCurrentOwnedUserProfile() async throws -> UserProfile? {
        guard await isCloudKitEnabled() else { return nil }
        guard let current = await currentUserRecordName(), !current.isEmpty else { return nil }

        // Try direct query first (requires ownerUserRecordName to be queryable/indexed in the schema)
        do {
            let predicate = NSPredicate(format: "%K == %@", CKUserKeys.ownerUserRecordName, current)
            let query = CKQuery(recordType: CKTypes.userProfile, predicate: predicate)
            query.sortDescriptors = [NSSortDescriptor(key: CKUserKeys.displayName, ascending: true)]
            let records = try await fetchAllRecords(query: query)
            let users = records.compactMap { Self.user(from: $0) }
            if let first = users.first { return first }
        } catch {
            if let ck = error as? CKError {
                let msg = ck.localizedDescription.lowercased()
                // Tolerate missing index/field in Production schema
                if ck.code != .invalidArguments && !msg.contains("not queryable") && !msg.contains("unknown field") {
                    throw error
                }
            } else {
                throw error
            }
        }

        // Fallback: fetch all users and filter locally
        let all = try await fetchAllUsers()
        return all.first(where: { $0.ownerUserRecordName == current })
    }

    // MARK: - Workouts

    // New: Fetch workouts in a rolling window (start >= since), sorted ascending by start.
    func fetchWorkouts(since startDate: Date) async throws -> [WorkoutEntry] {
        guard await isCloudKitEnabled(), db != nil else { throw CloudKitReadError.unavailable }
        let predicate = NSPredicate(format: "%K >= %@", CKWorkoutKeys.start, startDate as NSDate)
        let query = CKQuery(recordType: CKTypes.workoutEntry, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: CKWorkoutKeys.start, ascending: true)]
        let records = try await fetchAllRecords(query: query, requireCompleteResults: true)
        return try records.map {
            guard let workout = Self.workout(from: $0) else { throw CloudKitReadError.invalidRecord }
            return workout
        }
    }

    // Newest-first fast path: fetch only the newest N workouts, optionally filtered by start >= since.
    func fetchLatestWorkouts(limit: Int, since: Date? = nil) async throws -> [WorkoutEntry] {
        guard await isCloudKitEnabled() else { return [] }
        guard let db = db else { return [] }

        let predicate: NSPredicate = {
            if let s = since {
                return NSPredicate(format: "%K >= %@", CKWorkoutKeys.start, s as NSDate)
            } else {
                return NSPredicate(value: true)
            }
        }()

        let query = CKQuery(recordType: CKTypes.workoutEntry, predicate: predicate)
        // Newest first
        query.sortDescriptors = [NSSortDescriptor(key: CKWorkoutKeys.start, ascending: false)]

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[WorkoutEntry], Error>) in
            var results: [WorkoutEntry] = []
            let op = CKQueryOperation(query: query)
            op.resultsLimit = limit
            op.recordMatchedBlock = { _, result in
                switch result {
                case .success(let record):
                    if let w = Self.workout(from: record) {
                        results.append(w)
                    }
                case .failure(let error):
                    print("CK latest workouts record match error: \(error)")
                }
            }
            op.queryResultBlock = { finalResult in
                switch finalResult {
                case .success:
                    continuation.resume(returning: results)
                case .failure(let error):
                    if let ckError = error as? CKError {
                        if ckError.code == .unknownItem {
                            continuation.resume(returning: [])
                            return
                        }
                        if ckError.code == .invalidArguments || ckError.code == .serverRejectedRequest {
                            let msg = ckError.localizedDescription.lowercased()
                            if msg.contains("recordname") && msg.contains("queryable") {
                                print("CK latest workouts query skipped (Record Name not queryable yet). Treating as empty for bootstrap.")
                                continuation.resume(returning: [])
                                return
                            }
                        }
                    }
                    continuation.resume(throwing: error)
                }
            }
            db.add(op)
        }
    }

    func upsertWorkout(_ w: WorkoutEntry) async throws {
        guard await isCloudKitEnabled(), db != nil else { throw CloudKitReadError.unavailable }
        // Ownership guard: only the iCloud account that owns w.userId may mutate it.
        try await assertCurrentAccountOwns(userId: w.userId)

        let recordId = CKRecord.ID(recordName: w.id)
        let record = try await fetchOrCreateRecord(id: recordId, type: CKTypes.workoutEntry)

        if let existingUserID = record[CKWorkoutKeys.userId] as? String,
           !existingUserID.isEmpty,
           existingUserID != w.userId {
            throw CloudKitOwnershipError.recordSubjectMismatch(recordID: w.id,
                                                               existingUserID: existingUserID,
                                                               requestedUserID: w.userId)
        }

        record[CKWorkoutKeys.userId] = w.userId as CKRecordValue
        record[CKWorkoutKeys.start] = w.start as CKRecordValue
        record[CKWorkoutKeys.end] = w.end as CKRecordValue
        record[CKWorkoutKeys.distanceMeters] = w.distanceMeters as CKRecordValue
        record[CKWorkoutKeys.durationSec] = w.durationSec as CKRecordValue
        if let hr = w.avgHR { record[CKWorkoutKeys.avgHR] = hr as CKRecordValue } else { record[CKWorkoutKeys.avgHR] = nil }
        record[CKWorkoutKeys.source] = w.source as CKRecordValue
        record[CKWorkoutKeys.runType] = w.runType.rawValue as CKRecordValue

        // Write ints (0/1) for booleans to match schema
        record[CKWorkoutKeys.isManual] = NSNumber(value: w.isManual ? 1 : 0)

        if let notes = w.notes { record[CKWorkoutKeys.notes] = notes as CKRecordValue } else { record[CKWorkoutKeys.notes] = nil }

        // New: team feed fields
        record[CKWorkoutKeys.isShared] = NSNumber(value: w.isShared ? 1 : 0)
        record[CKWorkoutKeys.teamId] = w.teamId as CKRecordValue

        // New: zones & restingHR
        if let z = w.zones, z.durations.count >= 5 {
            let top5: [NSNumber] = Array(z.durations.prefix(5)).map { NSNumber(value: $0) }
            record[CKWorkoutKeys.zoneDurations] = top5 as CKRecordValue
            record[CKWorkoutKeys.zoneTotal] = z.total as CKRecordValue
        } else {
            record[CKWorkoutKeys.zoneDurations] = nil
            record[CKWorkoutKeys.zoneTotal] = nil
        }
        if let rhr = w.restingHR {
            record[CKWorkoutKeys.restingHR] = rhr as CKRecordValue
        } else {
            record[CKWorkoutKeys.restingHR] = nil
        }

        // Route coordinates are never a public V1 team-feed field. Explicitly
        // clear a legacy payload on every write so a cached old route cannot be
        // reposted after the route-sharing path was removed.
        record[CKWorkoutKeys.sharedRoutePoints] = nil

        // Save with progressive fallbacks so optional schema drift never blocks workout posting.
        do {
            _ = try await save(record)
            return
        } catch {
            // Pass 1: drop zone fields (new optional metadata).
            if record[CKWorkoutKeys.zoneDurations] != nil ||
                record[CKWorkoutKeys.zoneTotal] != nil ||
                record[CKWorkoutKeys.restingHR] != nil ||
                record[CKWorkoutKeys.sharedRoutePoints] != nil {
                record[CKWorkoutKeys.zoneDurations] = nil
                record[CKWorkoutKeys.zoneTotal] = nil
                record[CKWorkoutKeys.restingHR] = nil
                record[CKWorkoutKeys.sharedRoutePoints] = nil
                do {
                    _ = try await save(record)
                    return
                } catch {
                    // Continue to next fallback.
                }
            }

            // `isShared` and `teamId` are consent and routing fields. Never strip
            // them to make a write succeed: a missing schema must fail visibly.
            throw error
        }
    }

    func deleteWorkout(id: String) async throws {
        guard await isCloudKitEnabled() else { throw CloudKitReadError.unavailable }
        let recordId = CKRecord.ID(recordName: id)

        // Fetch to determine owner (userId) and enforce ownership before deletion.
        guard let db = self.db else { throw CloudKitReadError.unavailable }
        do {
            let rec = try await db.record(for: recordId)
            if let uid = rec[CKWorkoutKeys.userId] as? String, !uid.isEmpty {
                try await assertCurrentAccountOwns(userId: uid)
            } else {
                let current = await currentUserRecordName() ?? "unknown"
                throw CloudKitOwnershipError.accountMismatch(userId: id, expectedOwner: "unknown", currentAccount: current)
            }
        } catch {
            if let ck = error as? CKError, ck.code == .unknownItem {
                // Already gone; nothing to do.
                return
            }
            throw error
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            db.delete(withRecordID: recordId) { _, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }

    // MARK: - Plan Overrides (team-wide)

    func upsertPlanOverride(forWeekStart weekStart: Date, split: PlanSplit) async throws {
        guard await isCloudKitEnabled() else { return }
        let name = "plan_\(Self.isoDate(weekStart))"
        let recordId = CKRecord.ID(recordName: name)
        let record = try await fetchOrCreateRecord(id: recordId, type: CKTypes.planOverride)

        record[CKPlanOverrideKeys.weekStart] = weekStart as CKRecordValue
        record[CKPlanOverrideKeys.recovery] = split.recovery as CKRecordValue
        record[CKPlanOverrideKeys.tempo] = split.tempo as CKRecordValue
        record[CKPlanOverrideKeys.long] = split.long as CKRecordValue
        if let note = split.note { record[CKPlanOverrideKeys.note] = note as CKRecordValue } else { record[CKPlanOverrideKeys.note] = nil }

        _ = try await save(record)
    }

    func deletePlanOverride(weekStart: Date) async throws {
        guard await isCloudKitEnabled() else { return }
        let name = "plan_\(Self.isoDate(weekStart))"
        let recordId = CKRecord.ID(recordName: name)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            guard let db = self.db else {
                cont.resume(returning: ())
                return
            }
            db.delete(withRecordID: recordId) { _, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }

    // MARK: - Likes (Workout Kudos)

    func toggleLike(workoutId: String, ownerUserId: String, fromUserId: String) async throws {
        guard await isCloudKitEnabled() else { return }
        guard let db = db else { return }

        try await assertCurrentAccountOwns(userId: fromUserId)

        let likeRecordId = CKRecord.ID(recordName: Self.likeRecordName(workoutId: workoutId, fromUserId: fromUserId))

        // Fast path: if the deterministic record already exists, unlike by deleting it.
        do {
            _ = try await db.record(for: likeRecordId)
            try await deleteLikeRecords([likeRecordId], on: db)

            // Best-effort cleanup for any legacy duplicates (old record-name formats).
            let legacy = try await fetchLikesRaw(workoutId: workoutId, fromUserId: fromUserId)
                .filter { $0.id != likeRecordId.recordName }
            if !legacy.isEmpty {
                let legacyIds = legacy.map { CKRecord.ID(recordName: $0.id) }
                try? await deleteLikeRecords(legacyIds, on: db)
            }
            return
        } catch {
            if let ck = error as? CKError, ck.code == .unknownItem {
                // Not currently liked via deterministic id — continue.
            } else {
                throw error
            }
        }

        // Legacy path: if older like records exist for this user/workout, remove them as unlike.
        let legacyExisting = try await fetchLikesRaw(workoutId: workoutId, fromUserId: fromUserId)
        if !legacyExisting.isEmpty {
            let ids = legacyExisting.map { CKRecord.ID(recordName: $0.id) }
            try await deleteLikeRecords(ids, on: db)
            return
        }

        // Create the deterministic like record.
        let rec = CKRecord(recordType: CKTypes.workoutLike, recordID: likeRecordId)
        rec[CKLikeKeys.workoutId] = workoutId as CKRecordValue
        rec[CKLikeKeys.fromUserId] = fromUserId as CKRecordValue
        rec[CKLikeKeys.toUserId] = ownerUserId as CKRecordValue
        rec[CKLikeKeys.createdAt] = Date() as CKRecordValue

        try await saveLikeRecordWithFallback(rec)
    }

    func fetchLikeCount(workoutId: String) async throws -> Int {
        try await fetchLikes(workoutId: workoutId).count
    }

    func fetchDidLike(workoutId: String, fromUserId: String) async throws -> Bool {
        guard await isCloudKitEnabled() else { return false }
        guard let db = db else { return false }

        let id = CKRecord.ID(recordName: Self.likeRecordName(workoutId: workoutId, fromUserId: fromUserId))
        do {
            _ = try await db.record(for: id)
            return true
        } catch {
            if let ck = error as? CKError, ck.code == .unknownItem {
                // Fallback for legacy like ids from older builds.
                return try await !fetchLikesRaw(workoutId: workoutId, fromUserId: fromUserId).isEmpty
            }
            throw error
        }
    }

    func fetchLikes(workoutId: String) async throws -> [WorkoutLike] {
        let raw = try await fetchLikesRaw(workoutId: workoutId, fromUserId: nil)
        return Self.normalizedLikes(raw)
    }

    private func fetchLikesRaw(workoutId: String, fromUserId: String?) async throws -> [WorkoutLike] {
        guard await isCloudKitEnabled(), db != nil else { throw CloudKitReadError.unavailable }

        let predicate: NSPredicate
        if let fromUserId {
            predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "%K == %@", CKLikeKeys.workoutId, workoutId),
                NSPredicate(format: "%K == %@", CKLikeKeys.fromUserId, fromUserId)
            ])
        } else {
            predicate = NSPredicate(format: "%K == %@", CKLikeKeys.workoutId, workoutId)
        }
        let query = CKQuery(recordType: CKTypes.workoutLike, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: CKLikeKeys.createdAt, ascending: true)]

        do {
            let records = try await fetchAllRecords(query: query, requireCompleteResults: true)
            return try records.map {
                guard let like = Self.like(from: $0) else { throw CloudKitReadError.invalidRecord }
                return like
            }
        } catch {
            if let ckError = error as? CKError,
               ckError.code == .invalidArguments || ckError.code == .serverRejectedRequest {
                // Legacy schemas may lack the scoped query indexes. The fallback
                // also walks every cursor; partial counts must not look current.
                return try await fetchLikesBroad(workoutId: workoutId, fromUserId: fromUserId)
            }
            throw error
        }
    }

    private func fetchLikesBroad(workoutId: String, fromUserId: String?) async throws -> [WorkoutLike] {
        let query = CKQuery(recordType: CKTypes.workoutLike, predicate: NSPredicate(value: true))
        query.sortDescriptors = [NSSortDescriptor(key: CKLikeKeys.createdAt, ascending: true)]
        let records = try await fetchAllRecords(query: query, requireCompleteResults: true)
        let likes = try records.map {
            guard let like = Self.like(from: $0) else { throw CloudKitReadError.invalidRecord }
            return like
        }
        return likes.filter { $0.workoutId == workoutId && (fromUserId == nil || $0.fromUserId == fromUserId) }
    }

    private func deleteLikeRecords(_ ids: [CKRecord.ID], on db: CKDatabase) async throws {
        guard !ids.isEmpty else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let op = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: ids)
            op.modifyRecordsResultBlock = { result in
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

    private func saveLikeRecordWithFallback(_ record: CKRecord) async throws {
        do {
            _ = try await save(record)
            return
        } catch {
            // Already exists by id: treat as success (idempotent like).
            if let ck = error as? CKError, ck.code == .serverRecordChanged {
                return
            }

            var mutated = false
            if let missing = Self.missingLikeFieldsIfAny(error) {
                if missing.missingToUserId {
                    record[CKLikeKeys.toUserId] = nil
                    mutated = true
                }
                if missing.missingCreatedAt {
                    record[CKLikeKeys.createdAt] = nil
                    mutated = true
                }
            }

            if mutated {
                _ = try await save(record)
                return
            }
            throw error
        }
    }

    // MARK: - Comments (Workout Comments)

    func addComment(workoutId: String,
                    ownerUserId: String,
                    fromUserId: String,
                    text: String,
                    mentionedUserIds: [String]) async throws -> String {
        guard await isCloudKitEnabled() else { return "" }
        guard let _ = db else { return "" }

        // Ownership guard: only owner of fromUserId can comment as that user.
        try await assertCurrentAccountOwns(userId: fromUserId)

        // Enforce ≤ 500 characters by trimming
        let trimmed = String(text.prefix(500))

        let uuid = UUID().uuidString.lowercased()
        let recordName = "comment_\(workoutId)_\(uuid)"
        let recId = CKRecord.ID(recordName: recordName)

        let rec = CKRecord(recordType: CKTypes.workoutComment, recordID: recId)
        rec[CKCommentKeys.workoutId] = workoutId as CKRecordValue
        rec[CKCommentKeys.fromUserId] = fromUserId as CKRecordValue
        rec[CKCommentKeys.toUserId] = ownerUserId as CKRecordValue
        rec[CKCommentKeys.text] = trimmed as CKRecordValue
        rec[CKCommentKeys.mentionedUserIds] = mentionedUserIds as CKRecordValue
        rec[CKCommentKeys.createdAt] = Date() as CKRecordValue

        _ = try await save(rec)
        return recordName
    }

    func fetchComments(workoutId: String, limit: Int? = nil) async throws -> [CKRecord] {
        guard await isCloudKitEnabled() else { return [] }
        guard let db = db else { return [] }

        let predicate = NSPredicate(format: "%K == %@", CKCommentKeys.workoutId, workoutId)
        let query = CKQuery(recordType: CKTypes.workoutComment, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: CKCommentKeys.createdAt, ascending: true)]

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CKRecord], Error>) in
            var results: [CKRecord] = []
            let op = CKQueryOperation(query: query)
            if let limit = limit, limit > 0 {
                op.resultsLimit = limit
            }
            op.recordMatchedBlock = { _, result in
                switch result {
                case .success(let record):
                    results.append(record)
                case .failure(let error):
                    print("CK comment record match error: \(error)")
                }
            }
            op.queryResultBlock = { finalResult in
                switch finalResult {
                case .success:
                    continuation.resume(returning: results)
                case .failure(let error):
                    if let ckError = error as? CKError {
                        if ckError.code == .unknownItem {
                            continuation.resume(returning: [])
                            return
                        }
                        if ckError.code == .invalidArguments {
                            let msg = ckError.localizedDescription.lowercased()
                            if msg.contains("recordname") && msg.contains("queryable") {
                                print("CK comment query skipped (Record Name not queryable yet). Treating as empty for bootstrap.")
                                continuation.resume(returning: [])
                                return
                            }
                        }
                    }
                    continuation.resume(throwing: error)
                }
            }
            db.add(op)
        }
    }

    func deleteComment(recordName: String, requesterUserId: String) async throws {
        guard await isCloudKitEnabled() else { return }
        guard let db = db else { return }

        // Ownership guard: requester must own the profile they are acting as.
        try await assertCurrentAccountOwns(userId: requesterUserId)

        let recId = CKRecord.ID(recordName: recordName)
        let rec = try await db.record(for: recId)

        let from = rec[CKCommentKeys.fromUserId] as? String
        let to = rec[CKCommentKeys.toUserId] as? String

        guard from == requesterUserId || to == requesterUserId else {
            let err = NSError(domain: "CloudKitManager",
                              code: 403,
                              userInfo: [NSLocalizedDescriptionKey: "Not authorized to delete this comment."])
            throw err
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            db.delete(withRecordID: recId) { _, error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }

    func ensureCommentPushSubscriptions(forUserId userId: String) async throws {
        guard await isCloudKitEnabled() else { return }
        guard let db = db else { return }

        // Owner subscription
        let ownerSubId = "comments_to_\(userId)"
        let ownerPredicate = NSPredicate(format: "%K == %@", CKCommentKeys.toUserId, userId)
        let ownerSub = CKQuerySubscription(recordType: CKTypes.workoutComment,
                                           predicate: ownerPredicate,
                                           subscriptionID: ownerSubId,
                                           options: [.firesOnRecordCreation])
        let ownerInfo = CKSubscription.NotificationInfo()
        ownerInfo.alertBody = "New comment on your workout."
        ownerInfo.shouldSendContentAvailable = true
        ownerSub.notificationInfo = ownerInfo

        // Mentions subscription
        let mentionSubId = "comments_mentions_\(userId)"
        let mentionPredicate = NSPredicate(format: "ANY %K == %@", CKCommentKeys.mentionedUserIds, userId)
        let mentionSub = CKQuerySubscription(recordType: CKTypes.workoutComment,
                                             predicate: mentionPredicate,
                                             subscriptionID: mentionSubId,
                                             options: [.firesOnRecordCreation])
        let mentionInfo = CKSubscription.NotificationInfo()
        mentionInfo.alertBody = "You were mentioned in a comment."
        mentionInfo.shouldSendContentAvailable = true
        mentionSub.notificationInfo = mentionInfo

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let op = CKModifySubscriptionsOperation(subscriptionsToSave: [ownerSub, mentionSub],
                                                    subscriptionIDsToDelete: [])
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

    // MARK: - Team Feed (Shared workouts)

    /// Team feed fetch optimized for speed:
    /// - Primary path scopes server query by teamId + fixed team-history date floor.
    /// - Keeps local tolerant filtering for isShared mixed Bool/Int historical data.
    /// - Falls back to date-only query when teamId querying isn't available in schema.
    func fetchTeamFeed(teamId: String = "default",
                       limit: Int? = nil,
                       lookbackDays: Int = 365) async throws -> [WorkoutEntry] {
        guard await isCloudKitEnabled(), db != nil else { throw CloudKitReadError.unavailable }

        let _ = lookbackDays
        let cutoff = Self.teamSharedHistoryStartDate
        let normalizedLimit = limit.flatMap { $0 > 0 ? $0 : nil }
        let dateOnly = NSPredicate(format: "%K >= %@", CKWorkoutKeys.start, cutoff as NSDate)
        let teamScoped = NSCompoundPredicate(andPredicateWithSubpredicates: [
            dateOnly,
            NSPredicate(format: "%K == %@", CKWorkoutKeys.teamId, teamId)
        ])

        do {
            // The default team includes legacy records without an explicit teamId.
            // A single date query avoids duplicate pages hiding older shared rows.
            let rows = try await fetchTeamFeed(predicate: teamId == "default" ? dateOnly : teamScoped,
                                               teamId: teamId,
                                               limit: normalizedLimit)
            return Self.uniqueAndSortedTeamFeed(rows, limit: normalizedLimit)
        } catch {
            // Fallback for schemas where teamId isn't queryable yet.
            if Self.shouldFallbackToBroadTeamFeedQuery(error) {
                let broadRows = try await fetchTeamFeed(predicate: dateOnly,
                                                        teamId: teamId,
                                                        limit: normalizedLimit)
                return Self.uniqueAndSortedTeamFeed(broadRows, limit: normalizedLimit)
            }
            throw error
        }
    }

    /// Team feed drill-down for a single teammate.
    /// Keeps the same compatibility fallbacks as `fetchTeamFeed`, but narrows by userId first.
    func fetchTeamFeedForUser(teamId: String = "default",
                              userId: String,
                              limit: Int? = nil,
                              lookbackDays: Int = 730) async throws -> [WorkoutEntry] {
        guard await isCloudKitEnabled(), db != nil else { throw CloudKitReadError.unavailable }

        let _ = lookbackDays
        let cutoff = Self.teamSharedHistoryStartDate
        let normalizedLimit = limit.flatMap { $0 > 0 ? $0 : nil }

        let dateOnly = NSPredicate(format: "%K >= %@", CKWorkoutKeys.start, cutoff as NSDate)
        var predicates = [dateOnly, NSPredicate(format: "%K == %@", CKWorkoutKeys.userId, userId)]
        if teamId != "default" {
            predicates.append(NSPredicate(format: "%K == %@", CKWorkoutKeys.teamId, teamId))
        }
        let scoped = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)

        do {
            let rows = try await fetchTeamFeed(predicate: scoped,
                                               teamId: teamId,
                                               requiredUserId: userId,
                                               limit: normalizedLimit)
            return Self.uniqueAndSortedTeamFeed(rows, limit: normalizedLimit)
        } catch {
            // Fallback for schemas where teamId/userId querying isn't available yet.
            if Self.shouldFallbackToBroadTeamFeedQuery(error) {
                let broadRows = try await fetchTeamFeed(predicate: dateOnly,
                                                        teamId: teamId,
                                                        requiredUserId: userId,
                                                        limit: normalizedLimit)
                return Self.uniqueAndSortedTeamFeed(broadRows, limit: normalizedLimit)
            }
            throw error
        }
    }

    private func fetchTeamFeed(predicate: NSPredicate,
                               teamId: String,
                               requiredUserId: String? = nil,
                               limit: Int?) async throws -> [WorkoutEntry] {
        guard let db = db else { throw CloudKitReadError.unavailable }

        let query = CKQuery(recordType: CKTypes.workoutEntry, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: CKWorkoutKeys.start, ascending: false)]

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[WorkoutEntry], Error>) in
            var results: [WorkoutEntry] = []
            var seen = 0
            var recordError: Error?

            func run(with cursor: CKQueryOperation.Cursor?) {
                let op: CKQueryOperation = cursor.map(CKQueryOperation.init) ?? CKQueryOperation(query: query)

                if let limit, limit > 0 {
                    op.resultsLimit = max(1, min(400, limit - seen))
                }

                op.recordMatchedBlock = { _, result in
                    switch result {
                    case .success(let record):
                        guard let w = Self.workout(from: record) else {
                            recordError = recordError ?? CloudKitReadError.invalidRecord
                            return
                        }
                        if w.isShared,
                           w.teamId == teamId,
                           requiredUserId == nil || w.userId == requiredUserId {
                            results.append(w)
                            seen += 1
                        }
                    case .failure(let error):
                        recordError = recordError ?? error
                        print("CK team feed record match error: \(error)")
                    }
                }

                op.queryResultBlock = { finalResult in
                    switch finalResult {
                    case .success(let nextCursor):
                        if let recordError {
                            continuation.resume(throwing: recordError)
                            return
                        }
                        if let limit, limit > 0, seen >= limit {
                            continuation.resume(returning: results)
                            return
                        }
                        if let nextCursor {
                            run(with: nextCursor)
                        } else {
                            continuation.resume(returning: results)
                        }
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }

                db.add(op)
            }

            run(with: nil)
        }
    }

    private static func uniqueAndSortedTeamFeed(_ rows: [WorkoutEntry], limit: Int?) -> [WorkoutEntry] {
        var deduped: [String: WorkoutEntry] = [:]
        deduped.reserveCapacity(rows.count)
        for row in rows {
            deduped[row.id] = row
        }
        let sorted = deduped.values.sorted { $0.start > $1.start }
        if let limit, limit > 0 {
            return Array(sorted.prefix(limit))
        }
        return Array(sorted)
    }

    private static func shouldFallbackToBroadTeamFeedQuery(_ error: Error) -> Bool {
        guard let ck = error as? CKError else { return false }
        guard ck.code == .invalidArguments || ck.code == .serverRejectedRequest else { return false }
        let message = ck.localizedDescription.lowercased()
        return message.contains("teamid") || message.contains("queryable") || message.contains("index")
    }

    /// Team feed subscription: avoid server-side isShared predicates because historical records
    /// may store isShared as Bool vs Int, and CloudKit predicate typing is strict.
    ///
    /// To prevent incorrect user-facing alerts, we make this a *silent* push (content-available),
    /// then the app can decide whether to show a local notification (based on decoded isShared/teamId/prefs).
    func ensureTeamFeedPushSubscription(forTeamId teamId: String = "default") async throws {
        guard await isCloudKitEnabled() else { return }
        guard let db = db else { return }

        // Subscribe to the teamId only (teamId is a String and queryable/indexable).
        // NOTE: Records missing teamId won't trigger this push, but the app will still see them
        // on next refresh due to date-based fetchTeamFeed.
        let predicate = NSPredicate(format: "%K == %@", CKWorkoutKeys.teamId, teamId)

        let subId = "teamfeed_\(teamId)"
        let subscription = CKQuerySubscription(recordType: CKTypes.workoutEntry,
                                               predicate: predicate,
                                               subscriptionID: subId,
                                               options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion])

        let info = CKSubscription.NotificationInfo()
        // Silent push; app decides if/what to alert.
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let op = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription], subscriptionIDsToDelete: [])
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

    func ensureLikePushSubscription(forUserId userId: String) async throws {
        guard await isCloudKitEnabled() else { return }
        guard let db = db else { return }

        let subId = "likes_to_\(userId)"
        let predicate = NSPredicate(format: "%K == %@", CKLikeKeys.toUserId, userId)
        let subscription = CKQuerySubscription(recordType: CKTypes.workoutLike,
                                               predicate: predicate,
                                               subscriptionID: subId,
                                               options: [.firesOnRecordCreation])

        let info = CKSubscription.NotificationInfo()
        info.alertBody = "New like on your workout."
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let op = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription], subscriptionIDsToDelete: [])
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

    /// Likes/unlikes must refresh counts even when user-facing like alerts are off.
    func ensureLikeSyncSubscription(forUserId userId: String) async throws {
        let db = try await subscriptionDatabase()
        let subscription = CKQuerySubscription(
            recordType: CKTypes.workoutLike,
            predicate: NSPredicate(format: "%K == %@", CKLikeKeys.toUserId, userId),
            subscriptionID: "likes_sync_\(userId)",
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription], subscriptionIDsToDelete: [])
            operation.modifySubscriptionsResultBlock = { result in
                continuation.resume(with: result)
            }
            db.add(operation)
        }
    }

    func removeLikePushSubscription(forUserId userId: String) async throws {
        try await deleteSubscriptions(withIDs: ["likes_to_\(userId)"])
    }

    func removeCommentPushSubscriptions(forUserId userId: String) async throws {
        try await deleteSubscriptions(withIDs: ["comments_to_\(userId)", "comments_mentions_\(userId)"])
    }

    func removeTeamFeedPushSubscription(forTeamId teamId: String = "default") async throws {
        try await deleteSubscriptions(withIDs: ["teamfeed_\(teamId)"])
    }

    // MARK: - Notification Preferences

    func fetchNotificationPrefs(userId: String) async throws -> NotificationPrefs {
        guard await isCloudKitEnabled() else {
            return NotificationPrefs.defaults(for: userId)
        }
        guard let db = db else {
            return NotificationPrefs.defaults(for: userId)
        }
        let recordId = CKRecord.ID(recordName: Self.prefsRecordName(forUserId: userId))
        do {
            let rec = try await db.record(for: recordId)
            guard (rec[CKNotifKeys.userId] as? String) == userId,
                  let prefs = Self.prefs(from: rec),
                  prefs.userId == userId else {
                return NotificationPrefs.defaults(for: userId)
            }
            return prefs
        } catch {
            if let ck = error as? CKError, ck.code == .unknownItem {
                return NotificationPrefs.defaults(for: userId)
            }
            throw error
        }
    }

    func upsertNotificationPrefs(_ prefs: NotificationPrefs) async throws {
        guard await isCloudKitEnabled(), db != nil else { throw CloudKitReadError.unavailable }
        try await assertCurrentAccountOwns(userId: prefs.userId)
        let recordId = CKRecord.ID(recordName: Self.prefsRecordName(forUserId: prefs.userId))
        let record = try await fetchOrCreateRecord(id: recordId, type: CKTypes.notificationPrefs)

        if let existingUserID = record[CKNotifKeys.userId] as? String,
           !existingUserID.isEmpty,
           existingUserID != prefs.userId {
            throw CloudKitOwnershipError.recordSubjectMismatch(recordID: recordId.recordName,
                                                               existingUserID: existingUserID,
                                                               requestedUserID: prefs.userId)
        }

        record[CKNotifKeys.userId] = prefs.userId as CKRecordValue
        record[CKNotifKeys.pushNewWorkouts] = prefs.pushNewWorkouts as CKRecordValue
        record[CKNotifKeys.pushLikes] = prefs.pushLikes as CKRecordValue
        record[CKNotifKeys.pushComments] = prefs.pushComments as CKRecordValue
        record[CKNotifKeys.localCongrats] = prefs.localCongrats as CKRecordValue
        record[CKNotifKeys.shareByDefault] = prefs.shareByDefault as CKRecordValue
        record[CKNotifKeys.teamId] = prefs.teamId as CKRecordValue

        _ = try await save(record)
    }

    // MARK: - Seeding (Development)

    #if DEBUG
    func seedUsersIfNeeded() async throws {
        guard await isCloudKitEnabled() else { return }

        let seeds: [UserProfile] = [
            .init(id: "richard", displayName: "Richard",   initials: "R",   colorHex: "#FF7F50"),
            .init(id: "marcus",  displayName: "Marcus",    initials: "M",   colorHex: "#1E90FF"),
            .init(id: "richard2",displayName: "Richard II",initials: "RII", colorHex: "#32CD32"),
            .init(id: "katie",   displayName: "Katie",     initials: "K",   colorHex: "#DA70D6")
        ]
        for u in seeds {
            do {
                try await upsertUser(u)
            } catch {
                print("Seed upsert failed for user \(u.id): \(error)")
            }
        }
    }
    #endif

    // MARK: - Helpers

    // Updated to page through all results using the cursor so newer runs aren’t missed.
    private func fetchAllRecords(query: CKQuery, requireCompleteResults: Bool = false) async throws -> [CKRecord] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CKRecord], Error>) in
            guard let db = db else {
                if requireCompleteResults {
                    continuation.resume(throwing: CloudKitReadError.unavailable)
                } else {
                    continuation.resume(returning: [])
                }
                return
            }

            var results: [CKRecord] = []
            var recordError: Error?

            func run(with cursor: CKQueryOperation.Cursor?) {
                let op: CKQueryOperation = cursor.map(CKQueryOperation.init) ?? CKQueryOperation(query: query)

                op.recordMatchedBlock = { _, result in
                    if case .success(let record) = result {
                        results.append(record)
                    } else if case .failure(let error) = result {
                        recordError = recordError ?? error
                        print("CK record match error: \(error)")
                    }
                }

                op.queryResultBlock = { finalResult in
                    switch finalResult {
                    case .success(let nextCursor):
                        if requireCompleteResults, let recordError {
                            continuation.resume(throwing: recordError)
                            return
                        }
                        if let nextCursor { run(with: nextCursor) }
                        else { continuation.resume(returning: results) }
                    case .failure(let error):
                        if requireCompleteResults {
                            continuation.resume(throwing: error)
                            return
                        }
                        if let ckError = error as? CKError {
                            if ckError.code == .unknownItem {
                                continuation.resume(returning: results)
                                return
                            }
                            if ckError.code == .invalidArguments {
                                let msg = ckError.localizedDescription.lowercased()
                                if msg.contains("recordname") && msg.contains("queryable") {
                                    print("CK query skipped (Record Name not queryable yet). Treating as empty for bootstrap.")
                                    continuation.resume(returning: results)
                                    return
                                }
                            }
                        }
                        continuation.resume(throwing: error)
                    }
                }

                db.add(op)
            }

            run(with: nil)
        }
    }

    private func fetchOrCreateRecord(id: CKRecord.ID, type: String) async throws -> CKRecord {
        guard let db = db else {
            return CKRecord(recordType: type, recordID: id)
        }
        do {
            return try await db.record(for: id)
        } catch {
            if let ckError = error as? CKError, ckError.code == .unknownItem {
                return CKRecord(recordType: type, recordID: id)
            }
            throw error
        }
    }

    private func save(_ record: CKRecord) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKRecord, Error>) in
            guard let db = db else {
                continuation.resume(returning: record)
                return
            }
            db.save(record) { rec, err in
                if let err = err {
                    continuation.resume(throwing: err)
                } else {
                    continuation.resume(returning: rec ?? record)
                }
            }
        }
    }

    // MARK: - Tolerant decoding helpers (schema/type drift safe)

    nonisolated private static func ckBool(_ value: Any?, default d: Bool) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.intValue != 0 }
        if let i = value as? Int { return i != 0 }
        if let i = value as? Int64 { return i != 0 }
        return d
    }

    nonisolated private static func ckDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let i = value as? Int { return Double(i) }
        if let i = value as? Int64 { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    nonisolated private static func ckInt(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let i64 = value as? Int64 { return Int(i64) }
        if let d = value as? Double { return Int(d.rounded()) }
        if let s = value as? String, let i = Int(s) { return i }
        return nil
    }

    nonisolated private static func user(from record: CKRecord) -> UserProfile? {
        guard
            let displayName = record[CKUserKeys.displayName] as? String,
            let initials = record[CKUserKeys.initials] as? String,
            let colorHex = record[CKUserKeys.colorHex] as? String
        else { return nil }
        let owner = record[CKUserKeys.ownerUserRecordName] as? String
        return UserProfile(id: record.recordID.recordName,
                           displayName: displayName,
                           initials: initials,
                           colorHex: colorHex,
                           ownerUserRecordName: owner)
    }

    nonisolated private static func workout(from record: CKRecord) -> WorkoutEntry? {
        guard
            let userId = record[CKWorkoutKeys.userId] as? String,
            let start = record[CKWorkoutKeys.start] as? Date,
            let end = record[CKWorkoutKeys.end] as? Date,
            let distanceMeters = ckDouble(record[CKWorkoutKeys.distanceMeters]),
            let durationSec = ckDouble(record[CKWorkoutKeys.durationSec]),
            let source = record[CKWorkoutKeys.source] as? String,
            let runTypeRaw = record[CKWorkoutKeys.runType] as? String
        else { return nil }

        let avgHR = ckDouble(record[CKWorkoutKeys.avgHR])
        let notes = record[CKWorkoutKeys.notes] as? String
        let runType = RunType(rawValue: runTypeRaw) ?? .other

        // isManual may be Bool or Int64(0/1)
        let isManual = ckBool(record[CKWorkoutKeys.isManual], default: false)

        // New: zones & restingHR
        var zones: ZoneBreakdown? = nil
        if let arr = record[CKWorkoutKeys.zoneDurations] as? [Double],
           let total = ckDouble(record[CKWorkoutKeys.zoneTotal]),
           arr.count >= 5 {
            zones = ZoneBreakdown(durations: Array(arr.prefix(5)), total: total)
        } else if let nums = record[CKWorkoutKeys.zoneDurations] as? [NSNumber],
                  let total = ckDouble(record[CKWorkoutKeys.zoneTotal]),
                  nums.count >= 5 {
            let doubles = nums.map { $0.doubleValue }
            zones = ZoneBreakdown(durations: Array(doubles.prefix(5)), total: total)
        }
        let rhr = ckInt(record[CKWorkoutKeys.restingHR])
        // Ignore route coordinates from legacy public records. The current app
        // keeps routes in HealthKit for the owner only and never repersists them.
        let sharedRoutePoints: [Double]? = nil

        // New: team feed fields (defaults for backward compatibility)
        let isShared = ckBool(record[CKWorkoutKeys.isShared], default: false)
        let teamId = record[CKWorkoutKeys.teamId] as? String ?? "default"

        return WorkoutEntry(id: record.recordID.recordName,
                            userId: userId,
                            start: start,
                            end: end,
                            distanceMeters: distanceMeters,
                            durationSec: durationSec,
                            avgHR: avgHR,
                            source: source,
                            runType: runType,
                            isManual: isManual,
                            notes: notes,
                            healthKitUUID: nil,
                            stravaActivityId: nil,
                            zones: zones,
                            restingHR: rhr,
                            isShared: isShared,
                            teamId: teamId,
                            sharedRoutePoints: sharedRoutePoints)
    }

    nonisolated private static func like(from record: CKRecord) -> WorkoutLike? {
        guard
            let workoutId = record[CKLikeKeys.workoutId] as? String,
            let fromUserId = record[CKLikeKeys.fromUserId] as? String
        else { return nil }
        let toUserId = record[CKLikeKeys.toUserId] as? String ?? ""
        let createdAt = (record[CKLikeKeys.createdAt] as? Date) ?? record.creationDate ?? Date.distantPast
        return WorkoutLike(id: record.recordID.recordName,
                           workoutId: workoutId,
                           fromUserId: fromUserId,
                           toUserId: toUserId,
                           createdAt: createdAt)
    }

    nonisolated private static func prefs(from record: CKRecord) -> NotificationPrefs? {
        guard let userId = record[CKNotifKeys.userId] as? String else { return nil }
        let pushNew = record[CKNotifKeys.pushNewWorkouts] as? Bool ?? true
        let pushLikes = record[CKNotifKeys.pushLikes] as? Bool ?? true
        let pushComments = record[CKNotifKeys.pushComments] as? Bool ?? true
        let localCongrats = record[CKNotifKeys.localCongrats] as? Bool ?? true
        let shareDefault = record[CKNotifKeys.shareByDefault] as? Bool ?? false
        let teamId = record[CKNotifKeys.teamId] as? String ?? "default"
        return NotificationPrefs(userId: userId,
                                 pushNewWorkouts: pushNew,
                                 pushLikes: pushLikes,
                                 pushComments: pushComments,
                                 localCongrats: localCongrats,
                                 shareByDefault: shareDefault,
                                 teamId: teamId)
    }

    private static func isoDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withFullDate]
        return f.string(from: date)
    }

    // MARK: - Availability

    private func isCloudKitEnabled() async -> Bool {
        if cloudKitTemporarilyDisabled {
            availability = .disabled("CloudKit temporarily disabled in this build.")
            return false
        }

        switch availability {
        case .enabled:
            return true
        case .disabled:
            return false
        case .unknown:
            guard let container = container else {
                availability = .disabled("No container configured.")
                return false
            }

            let (status, error) = await accountStatus(for: container)
            if status == .available {
                availability = .enabled
                logAvailabilityOnce("CloudKit available. Container: \(container.containerIdentifier ?? "default")")
                return true
            }

            let reason: String
            switch status {
            case .available:
                reason = "iCloud account available."
            case .noAccount:
                reason = "No iCloud account on device."
            case .restricted:
                reason = "iCloud restricted (e.g., parental controls or MDM)."
            case .couldNotDetermine:
                reason = error?.localizedDescription ?? "Could not determine account status."
            case .temporarilyUnavailable:
                reason = "iCloud temporarily unavailable."
            @unknown default:
                reason = "Unknown account status."
            }
            availability = .disabled(reason)
            logAvailabilityOnce("CloudKit disabled: \(reason)")
            return false
        }
    }

    private func accountStatus(for container: CKContainer) async -> (CKAccountStatus, Error?) {
        await withCheckedContinuation { (cont: CheckedContinuation<(CKAccountStatus, Error?), Never>) in
            container.accountStatus { status, error in
                cont.resume(returning: (status, error))
            }
        }
    }

    private func logAvailabilityOnce(_ message: String) {
        if !hasLoggedAvailability {
            print(message)
            hasLoggedAvailability = true
        }
    }

    private static func hasCloudKitEntitlement() -> Bool {
        return true
    }

    // MARK: - Current iCloud account's CloudKit user record name

    func currentUserRecordName() async -> String? {
        guard await isCloudKitEnabled(), let container = container else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            container.fetchUserRecordID { id, _ in
                cont.resume(returning: id?.recordName)
            }
        }
    }

    // MARK: - Ownership guard

    func assertCurrentAccountOwns(profile: UserProfile) async throws {
        guard await isCloudKitEnabled(),
              let current = await currentUserRecordName(),
              !current.isEmpty else {
            throw CloudKitOwnershipError.accountUnavailable
        }

        if let owner = profile.ownerUserRecordName, !owner.isEmpty {
            guard owner == current else {
                throw CloudKitOwnershipError.accountMismatch(userId: profile.id, expectedOwner: owner, currentAccount: current)
            }
            return
        }

        throw CloudKitOwnershipError.unclaimedProfile(userId: profile.id)
    }

    func assertCurrentAccountOwns(userId: String) async throws {
        guard await isCloudKitEnabled() else {
            throw CloudKitOwnershipError.accountUnavailable
        }
        if let profile = try await fetchUserProfile(withId: userId) {
            try await assertCurrentAccountOwns(profile: profile)
            return
        }

        throw CloudKitOwnershipError.unclaimedProfile(userId: userId)
    }

    // MARK: - Error helpers

    private static func isProdSchemaMissingOwnerField(_ error: Error) -> Bool {
        guard let ck = error as? CKError else { return false }
        let msg = ck.localizedDescription.lowercased()
        if msg.contains("cannot create or modify field"),
           msg.contains(CKUserKeys.ownerUserRecordName.lowercased()) {
            return true
        }
        if msg.contains("production schema"),
           msg.contains(CKUserKeys.ownerUserRecordName.lowercased()) {
            return true
        }
        return false
    }

    private static func missingLikeFieldsIfAny(_ error: Error) -> (missingToUserId: Bool, missingCreatedAt: Bool)? {
        guard let ck = error as? CKError else { return nil }
        let msg = ck.localizedDescription.lowercased()
        let hits = msg.contains("cannot create or modify field") || msg.contains("production schema")
        let missingToUserId = hits && msg.contains(CKLikeKeys.toUserId.lowercased())
        let missingCreatedAt = hits && msg.contains(CKLikeKeys.createdAt.lowercased())
        if missingToUserId || missingCreatedAt {
            return (missingToUserId, missingCreatedAt)
        }
        return nil
    }

    // MARK: - Internal helpers (Likes, Prefs, Subs)

    private static func likeRecordName(workoutId: String, fromUserId: String) -> String {
        // Keep workoutId visible in recordName for push parsing/debug;
        // hash only the user component to avoid invalid-character issues.
        "like_\(workoutId)_\(stableHex(fromUserId))"
    }

    private static func stableHex(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private static func normalizedLikes(_ likes: [WorkoutLike]) -> [WorkoutLike] {
        // One like per user per workout; keep the most recent if duplicates exist.
        var latestByUser: [String: WorkoutLike] = [:]
        latestByUser.reserveCapacity(likes.count)
        for like in likes {
            if let existing = latestByUser[like.fromUserId] {
                if like.createdAt > existing.createdAt {
                    latestByUser[like.fromUserId] = like
                }
            } else {
                latestByUser[like.fromUserId] = like
            }
        }
        return latestByUser.values.sorted { $0.createdAt < $1.createdAt }
    }

    private static func prefsRecordName(forUserId userId: String) -> String {
        "prefs_\(userId)"
    }

    private func deleteSubscriptions(withIDs ids: [String]) async throws {
        guard await isCloudKitEnabled() else { return }
        guard let db = db, !ids.isEmpty else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let op = CKModifySubscriptionsOperation(subscriptionsToSave: [], subscriptionIDsToDelete: ids)
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

    private func fetchUserProfile(withId id: String) async throws -> UserProfile? {
        guard await isCloudKitEnabled() else { return nil }
        guard let db = db else { return nil }
        let recordId = CKRecord.ID(recordName: id)
        do {
            let rec = try await db.record(for: recordId)
            return Self.user(from: rec)
        } catch {
            if let ck = error as? CKError, ck.code == .unknownItem {
                return nil
            }
            throw error
        }
    }

    func ownershipFlags(for users: [UserProfile]) async -> [String: (claimed: Bool, mine: Bool)] {
        let current = await currentUserRecordName()
        var map: [String: (claimed: Bool, mine: Bool)] = [:]
        for u in users {
            let claimed = (u.ownerUserRecordName?.isEmpty == false)
            let mine = claimed && (u.ownerUserRecordName == current)
            map[u.id] = (claimed: claimed, mine: mine)
        }
        return map
    }

    // MARK: - Migration utilities

    func migrateWorkoutsUserId(from oldId: String, to newId: String) async throws {
        guard await isCloudKitEnabled() else { return }
        guard !oldId.isEmpty, !newId.isEmpty, oldId != newId else { return }

        try await assertCurrentAccountOwns(userId: oldId)
        try await assertCurrentAccountOwns(userId: newId)

        let predicate = NSPredicate(format: "%K == %@", CKWorkoutKeys.userId, oldId)
        let query = CKQuery(recordType: CKTypes.workoutEntry, predicate: predicate)
        let records = try await fetchAllRecords(query: query)
        guard !records.isEmpty else { return }

        var migrated = 0
        for rec in records {
            rec[CKWorkoutKeys.userId] = newId as CKRecordValue
            do {
                _ = try await save(rec)
                migrated += 1
            } catch {
                print("CloudKit migrateWorkoutsUserId failed for \(rec.recordID.recordName): \(error)")
            }
        }
        print("CloudKit: migrated \(migrated)/\(records.count) workouts from '\(oldId)' to '\(newId)'.")
    }
}
