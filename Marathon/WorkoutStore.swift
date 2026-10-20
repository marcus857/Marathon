//
//  WorkoutStore.swift
//  Marathon
//

import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

struct PlanSplit: Codable, Equatable {
    var recovery: Double
    var tempo: Double
    var long: Double
    var note: String? = nil
}

final class WorkoutStore: ObservableObject {
    @Published var me: UserProfile = .mePlaceholder()
    @Published var allUsers: [UserProfile] = []
    @Published var workouts: [WorkoutEntry] = []
    // Team feed fetched directly from CloudKit shared records (source of truth for feed screens)
    @Published var cloudTeamFeed: [WorkoutEntry] = []
    @Published var isTeamFeedLoading: Bool = false
    @Published var teamFeedLastRefreshAt: Date?
    @Published private(set) var teamSyncError: String?
    @Published private(set) var isPreparingWeeklyReviewData = false
    @Published private(set) var weeklyReviewImport: WeeklyReviewImportRecord?
    @Published var teamFeedPostingLookbackDays: Int = WorkoutStore.defaultTeamFeedPostingLookbackDays
    @Published var settings: PlanRuleSettings = .defaultForAthens()
    // Latest VO2max per week keyed by Monday 00:00 (current user convenience mirror)
    @Published var vo2MaxByWeek: [Date: Double] = [:]
    // Per-user VO2max series (Monday -> value)
    @Published var vo2MaxByWeekByUser: [String: [Date: Double]] = [:]
    // Cached heart-rate zones per workout id (so zones can be shown for any user when known)
    @Published var zonesByWorkout: [String: ZoneBreakdown] = [:]
    // Resting HR per user (estimated for current user via HealthKit; default 60 otherwise)
    @Published var restingHRByUser: [String: Int] = [:]
    // Break reason + notes keyed by Monday 00:00 (weekStart)
    @Published var weekBreaks: [Date: (reason: BreakReason, notes: String)] = [:]

    // Important Dates (persisted)
    @Published var importantDates: [ImportantDate] = []

    // Master plan (seeded baseline) keyed by Monday-of-week (persisted)
    @Published var masterPlan: [Date: PlanSplit] = [:]

    // Team‑wide plan overrides keyed by Monday-of-week (persisted locally; synced via CloudKit)
    @Published var userPlanOverrides: [Date: PlanSplit] = [:] {
        didSet {
            // Keep legacy alias in sync when userPlanOverrides changes programmatically
            if userPlanOverrides != planOverrides {
                planOverrides = userPlanOverrides
            }
        }
    }

    // Legacy alias so existing bindings like $store.planOverrides keep working.
    // This mirrors userPlanOverrides and persists via saveUserPlanOverrides().
    @Published var planOverrides: [Date: PlanSplit] = [:] {
        didSet {
            // Propagate edits coming from legacy bindings into the real source of truth
            if planOverrides != userPlanOverrides {
                userPlanOverrides = planOverrides
                saveUserPlanOverrides()
            }
        }
    }

    // Per‑workout run type overrides keyed by workout id (persisted)
    @Published var runTypeOverrides: [String: RunType] = [:]

    // Likes (hearts) state
    @Published var likeCountByWorkout: [String: Int] = [:]
    @Published var didILikeByWorkout: [String: Bool] = [:]
    @Published var likeToggleInFlight: Set<String> = []

    // Ownership flags keyed by user id: claimed (has owner) and mine (owned by my iCloud account)
    @Published var ownershipFlagsByUser: [String: (claimed: Bool, mine: Bool)] = [:]
    @Published private(set) var isTeamSyncEnabled: Bool = false

    /// A real profile is required before imported HealthKit data becomes app data.
    /// This prevents a first launch from importing workouts under the placeholder id.
    var needsOnboarding: Bool {
        me.id.isEmpty || me.id == legacyMeUserId
    }

    var hasActiveProfile: Bool {
        !needsOnboarding
    }

    // Only these user ids can edit the team-wide overrides.
    // Hard-code: disable edits for everyone so the seed is what shows.
    private let allowedPlanEditors: Set<String> = []
    var canEditTeamPlan: Bool { allowedPlanEditors.contains(me.id) }

    let plan = PlanEngine()
    let compliance = ComplianceEngine()

    private let breaksStorageKey = "weekBreaks_v1"
    private let importantDatesKey = "importantDates_v1"
    // Legacy (pre-split) key that stored a single map mixing seed + user edits
    private let planOverridesKey = "planOverrides_v1"
    private let currentUserIdKey = "currentUserId_v1"
    private let runTypeOverridesKey = "runTypeOverrides_v1"

    // New persistence keys after splitting master vs user overrides
    private let masterPlanKey = "masterPlan_v1"
    private let userPlanOverridesKey = "userPlanOverrides_v1"

    // Versioning for the seeded master plan. Bump this when you change seedPlanOverridesAthens().
    private let masterPlanSeedVersionKey = "masterPlanSeedVersion_v1"
    private let currentMasterPlanSeedVersion = 2

    // Local demo persistence keys (for 4‑user testing without CloudKit)
    private let demoUsersKey = "demoUsers_v1"
    private let demoWorkoutsKey = "demoWorkouts_v1"
    // Debug/testing: when false, local upserts do not auto-push to CloudKit.
    private let autoUploadRunsToCloudKey = "autoUploadRunsToCloud_v1"
    private static let notificationPrefsCacheKeyPrefix = "notificationPrefsCache_v1_"
    private let teamFeedCacheKey = "teamFeedCache_v1"
    private let teamFeedPostingLookbackDaysKey = "teamFeedPostingLookbackDays_v1"

    // Sensible rolling window for CloudKit workouts (e.g., last 540 days)
    private let recentWorkoutsWindowDays: Int = 540
    // One-time Health backfill starts at the beginning of Oct 2025.
    private let healthBackfillStateKeyPrefix = "didHealthBackfillFrom2025Oct_v1"
    private let healthPostingLookbackAppliedKeyPrefix = "healthPostingLookbackAppliedDays_v1"
    // One-time alias migration for profiles owned by the same iCloud account.
    private let ownedAliasMigrationKeyPrefix = "didMigrateOwnedAliasesToCurrent_v1"

    // MARK: - Legacy userId migration ("me" -> real profile id)
    private let legacyMeUserId = "me"
    private let userIdMigrationKey = "didMigrateWorkoutUserId_me_to_current"

    #if canImport(UIKit)
    private var foregroundObserver: NSObjectProtocol?
    #endif
    private var pushObserver: NSObjectProtocol?

    // Prevent concurrent Health sync passes from minting duplicate local entries.
    private actor HealthSyncGate {
        private var inFlight = false
        func tryBegin() -> Bool {
            if inFlight { return false }
            inFlight = true
            return true
        }
        func end() { inFlight = false }
    }
    private let healthSyncGate = HealthSyncGate()

    // All tabs share one refresh; pushes during a fetch schedule a follow-up pass.
    private var cloudRefreshTask: Task<Void, Never>?
    private var cloudRefreshRequested = false
    private var identityRevision = 0
    private var workoutEditRevision = 0
    private var localEditRevisions: [String: Int] = [:]
    private var pendingWorkoutUploads: Set<String> = []
    private var deletedWorkoutIDs: Set<String> = []
    private var retainedPersonalWorkouts: [String: [WorkoutEntry]] = [:]
    private let teamFeedMinRefreshInterval: TimeInterval = 15

    private static let defaultTeamFeedPostingLookbackDays = 0
    private static let teamFeedPostingLookbackOptionsInternal: [Int] = [0]
    private static let teamSharedHistoryStartDateLabel = "Oct 1, 2025"

    static var teamFeedPostingLookbackOptions: [Int] {
        teamFeedPostingLookbackOptionsInternal
    }

    private struct TeamFeedCachePayload: Codable {
        var updatedAt: Date
        var userId: String
        var teamId: String?
        var rows: [WorkoutEntry]
    }

    init(startBackgroundSync: Bool = true) {
        // If we have a saved user id (and it's not the old legacy "me"), set a temporary me
        if let savedId = loadCurrentUserId(), savedId != legacyMeUserId {
            // Do not show "Me/ME" — keep name/initials empty until cloud resolves the real profile.
            me = UserProfile(id: savedId, displayName: "", initials: "", colorHex: "#34C759")
        }

        loadWeekBreaks()
        loadImportantDates()

        // Load master plan (reseed if version bumped)
        loadMasterPlan()
        syncLegacyPlanAlias()

        loadRunTypeOverrides()
        teamFeedPostingLookbackDays = loadTeamFeedPostingLookbackDays()
        loadTeamFeedCache()

        // Load locally persisted demo data immediately (if available) so the app isn't empty on launch.
        #if DEBUG
        loadDemoIfAvailable()
        #endif

        guard startBackgroundSync,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        // Bootstrap CloudKit data (users, workouts). Skip plan overrides.
        Task { await cloudBootstrap() }

        // Auto-refresh cloud data when app returns to foreground so others see latest runs without relaunch.
        #if canImport(UIKit)
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshFromCloud()
                if self.teamSyncError == nil { await self.syncMyRecentHealthRuns() }
            }
        }
        #endif

        // Refresh local state when a CloudKit push arrives.
        pushObserver = NotificationCenter.default.addObserver(
            forName: .didReceiveCloudKitPush,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            guard let subID = note.userInfo?["subscriptionID"] as? String else { return }

            if subID.hasPrefix("likes_to_") || subID.hasPrefix("likes_sync_") {
                // Likes: refresh like state for that workout (or all visible if parsing fails).
                let recName = note.userInfo?["recordID"] as? String ?? ""
                if let wid = self.workoutIdFromLikeRecordName(recName) {
                    Task { await self.refreshLikes(for: wid) }
                } else {
                    Task { await self.preloadLikes(for: self.workouts.map { $0.id }) }
                }
            } else if subID.hasPrefix("teamfeed_") {
                // Team feed: new/updated/deleted shared workout — refresh workouts immediately.
                Task { await self.refreshFromCloud(force: false) }
            } else {
                // Other push types can be handled here in the future (e.g., comments).
            }
        }
    }

    deinit {
        #if canImport(UIKit)
        if let token = foregroundObserver {
            NotificationCenter.default.removeObserver(token)
        }
        #endif
        if let token = pushObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // Upsert and de-duplicate by id; keep list sorted by start time (ascending for stable range ops).
    // New entries stay local until their opt-in CloudKit post succeeds. That makes a
    // failed or revoked sharing preference fail closed rather than merely look shared.
    func upsert(entries: [WorkoutEntry]) {
        var dict: [String: WorkoutEntry] = [:]
        dict.reserveCapacity(workouts.count + entries.count)
        for workout in workouts {
            dict[workout.id] = workout
        }
        for e in entries where !deletedWorkoutIDs.contains(e.id) {
            dict[e.id] = e
            if e.userId == me.id { recordLocalWorkoutEdit(e.id) }
        }
        workouts = Array(dict.values).sorted { $0.start < $1.start }

        // Prime zone cache if entries carry embedded zones
        for e in entries {
            if let z = e.zones {
                zonesByWorkout[e.id] = z
            }
        }

        // Apply any saved run type overrides to newly merged/inserted items
        applyRunTypeOverrides()

        // Auto-assign default types for my runs per week:
        // 1st Recovery, 2nd Tempo, 3rd Long, then Recovery for any extras.
        assignDefaultRunTypesForCurrentUser()
        updateVisibleFeedFromWorkouts()

        // Persist demo workouts if we are using local demo data
        saveDemoWorkoutsIfDemoActive()

        // Preload likes for inserted/updated items
        Task { await preloadLikes(for: entries.map { $0.id }) }

        // Push only my entries to the public team feed after an explicit opt-in.
        // Keep the legacy flag as a second safety switch for debug tooling.
        guard isTeamSyncEnabled, isAutoUploadRunsToCloudEnabled() else { return }
        let myId = me.id
        guard hasActiveProfile else { return }
        Task { [myId, entries] in
            let prefs = await Self.fetchNotificationPrefsWithTimeout(userId: myId, seconds: 6)
            guard prefs.shareByDefault else { return }
            for e in entries where e.userId == myId {
                guard let current = await MainActor.run(body: { () -> WorkoutEntry? in
                    // Re-check at the last possible moment. This prevents an
                    // in-flight preference fetch from posting after opt-out.
                    guard self.isTeamSyncEnabled, self.hasActiveProfile, self.me.id == myId else {
                        return nil
                    }
                    return self.workouts.first(where: { $0.id == e.id && $0.userId == myId })
                }) else {
                    continue
                }
                do {
                    var upload = current
                    // Team posting is an explicit opt-in. Only records posted after
                    // that choice are marked shared and assigned to the active team.
                    upload.isShared = true
                    upload.teamId = prefs.teamId
                    try await CloudKitManager.shared.upsertWorkout(upload)
                    await MainActor.run {
                        self.markWorkoutShared(uploaded: current, teamId: prefs.teamId)
                    }
                } catch {
                    print("Cloud push workout failed for \(e.id): \(error)")
                }
            }
        }
    }

    private func recordLocalWorkoutEdit(_ id: String) {
        workoutEditRevision += 1
        localEditRevisions[id] = workoutEditRevision
        pendingWorkoutUploads.insert(id)
    }

    private func updateVisibleFeedFromWorkouts() {
        let byID = Dictionary(workouts.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        cloudTeamFeed = cloudTeamFeed.compactMap { row in
            guard let current = byID[row.id], current.isShared, current.teamId == row.teamId else { return nil }
            return current
        }.sorted { $0.start > $1.start }
    }

    @MainActor
    private func finishCloudWorkoutWrite(_ uploaded: WorkoutEntry) {
        guard me.id == uploaded.userId else { return }
        if workouts.first(where: { $0.id == uploaded.id }) == uploaded {
            pendingWorkoutUploads.remove(uploaded.id)
        }
        // A snapshot may have started before this write. Request a follow-up pass.
        Task { await self.refreshFromCloud() }
    }

    @MainActor
    private func markWorkoutShared(uploaded: WorkoutEntry, teamId: String) {
        guard let index = workouts.firstIndex(where: {
            $0.id == uploaded.id && $0.userId == uploaded.userId && $0.userId == me.id
        }) else { return }
        workouts[index].isShared = true
        workouts[index].teamId = teamId
        var acknowledged = uploaded
        acknowledged.isShared = true
        acknowledged.teamId = teamId
        updateVisibleFeedFromWorkouts()
        saveDemoWorkoutsIfDemoActive()
        finishCloudWorkoutWrite(acknowledged)
    }

    func isAutoUploadRunsToCloudEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: autoUploadRunsToCloudKey) == nil {
            // Default OFF so testing can explicitly post selected runs.
            return false
        }
        return UserDefaults.standard.bool(forKey: autoUploadRunsToCloudKey)
    }

    func setAutoUploadRunsToCloudEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: autoUploadRunsToCloudKey)
    }

    /// Controls future HealthKit and manual-workout posts to the experimental
    /// CloudKit team feed. Disabling this does not delete records shared earlier.
    func setTeamSyncEnabled(_ enabled: Bool) async {
        let currentUser = await MainActor.run { self.me }
        guard !currentUser.id.isEmpty, currentUser.id != legacyMeUserId else { return }

        let previousPrefs = await Self.fetchNotificationPrefsWithTimeout(userId: currentUser.id, seconds: 6)
        var prefs = previousPrefs
        prefs.shareByDefault = enabled
        Self.saveCachedNotificationPrefs(prefs)

        await MainActor.run {
            self.isTeamSyncEnabled = enabled
            self.setAutoUploadRunsToCloudEnabled(enabled)
        }

        do {
            try await CloudKitManager.shared.upsertNotificationPrefs(prefs)
        } catch {
            print("Saving team sync preference failed: \(error)")
            // An opt-in that failed to persist must never become active. For
            // opt-out, keep this device fail-closed even if the legacy public
            // preference record could not be updated remotely.
            if enabled {
                Self.saveCachedNotificationPrefs(previousPrefs)
                await MainActor.run {
                    guard self.me.id == currentUser.id else { return }
                    self.isTeamSyncEnabled = previousPrefs.shareByDefault
                    self.setAutoUploadRunsToCloudEnabled(previousPrefs.shareByDefault)
                }
                prefs = previousPrefs
            }
        }
        PushSubscriptionManager.shared.rebuildAllSubscriptions(for: currentUser.id, prefs: prefs)
    }

    // Delete a workout by id (local, then CloudKit if mine)
    func deleteWorkout(id: String) {
        guard let idx = workouts.firstIndex(where: { $0.id == id }) else { return }
        let entry = workouts[idx]
        guard entry.userId == me.id else { return }
        recordLocalWorkoutEdit(id)
        deletedWorkoutIDs.insert(id)
        pendingWorkoutUploads.remove(id)
        workouts.remove(at: idx)
        updateVisibleFeedFromWorkouts()

        // Clean any run type override for this id
        runTypeOverrides.removeValue(forKey: id)
        saveRunTypeOverrides()

        // Also clear cached zones
        zonesByWorkout.removeValue(forKey: id)

        // Clear likes state for this id
        likeCountByWorkout.removeValue(forKey: id)
        didILikeByWorkout.removeValue(forKey: id)

        // Persist demo workouts if we are using local demo data
        saveDemoWorkoutsIfDemoActive()

        // Push deletion only for my entries
        if entry.userId == me.id {
            Task.detached {
                do {
                    try await CloudKitManager.shared.deleteWorkout(id: id)
                    await self.refreshFromCloud()
                } catch {
                    print("Cloud delete workout failed for \(id): \(error)")
                }
            }
        }
    }

    // Change a run's type everywhere, persist it, and push to CloudKit for my runs.
    func setRunType(_ type: RunType, forWorkoutId id: String) {
        guard workouts.contains(where: { $0.id == id && $0.userId == me.id }) else { return }
        recordLocalWorkoutEdit(id)
        // Update in-memory array
        if let idx = workouts.firstIndex(where: { $0.id == id }) {
            workouts[idx].runType = type
        }
        updateVisibleFeedFromWorkouts()
        // Save override
        runTypeOverrides[id] = type
        saveRunTypeOverrides()

        // Persist demo workouts if we are using local demo data
        saveDemoWorkoutsIfDemoActive()

        // Only update the public copy while team sync remains enabled. A local
        // run-type edit must not recreate or update a feed record after opt-out.
        let myId = me.id
        if isTeamSyncEnabled,
           let updated = workouts.first(where: { $0.id == id && $0.userId == myId && $0.isShared }) {
            Task.detached {
                do {
                    try await CloudKitManager.shared.upsertWorkout(updated)
                    await self.finishCloudWorkoutWrite(updated)
                } catch {
                    print("Cloud push workout (type change) failed for \(updated.id): \(error)")
                }
            }
        }
    }

    // MARK: - Likes (Hearts)

    // Toggle like for a workout; persists via CloudKit and refreshes local state.
    @MainActor
    func toggleLike(for workout: WorkoutEntry) async {
        let wid = workout.id
        let owner = workout.userId
        let liker = me.id
        guard !wid.isEmpty, !liker.isEmpty else { return }
        if likeToggleInFlight.contains(wid) { return }
        likeToggleInFlight.insert(wid)
        defer { likeToggleInFlight.remove(wid) }

        // Optimistic UI update: flip local flag & adjust count
        let currentDidLike = didILikeByWorkout[wid] ?? false
        let currentCount = likeCountByWorkout[wid] ?? 0
        didILikeByWorkout[wid] = !currentDidLike
        likeCountByWorkout[wid] = max(0, currentCount + (currentDidLike ? -1 : +1))

        do {
            try await CloudKitManager.shared.toggleLike(workoutId: wid, ownerUserId: owner, fromUserId: liker)
            // After server success, re-fetch to ensure consistency
            await refreshLikes(for: wid)
        } catch {
            print("Toggle like failed: \(error)")
            // Rollback only in the identity that started the request.
            guard me.id == liker else { return }
            didILikeByWorkout[wid] = currentDidLike
            likeCountByWorkout[wid] = currentCount
        }
    }

    // Fetch and update the like count and my-like flag for a single workout.
    @MainActor
    func refreshLikes(for workoutId: String) async {
        let uid = me.id
        do {
            let likes = try await CloudKitManager.shared.fetchLikes(workoutId: workoutId)
            guard me.id == uid, workouts.contains(where: { $0.id == workoutId }) else { return }
            likeCountByWorkout[workoutId] = likes.count
            didILikeByWorkout[workoutId] = likes.contains(where: { $0.fromUserId == me.id })
        } catch {
            print("Refresh likes failed for \(workoutId): \(error)")
        }
    }

    // Preload likes for a set of workouts (e.g., visible rows)
    func preloadLikes(for workoutIds: [String]) async {
        guard !workoutIds.isEmpty else { return }
        for wid in workoutIds {
            await refreshLikes(for: wid)
        }
    }

    // Upsert VO2 values by Monday-of-week for the current user (kept for compatibility)
    func upsertVO2(byWeek newValues: [Date: Double]) {
        upsertVO2(for: me.id, byWeek: newValues)
    }

    // New: upsert VO2 values for a given user id
    func upsertVO2(for userId: String, byWeek newValues: [Date: Double]) {
        var merged = vo2MaxByWeekByUser[userId] ?? [:]
        for (k, v) in newValues { merged[k] = v }
        vo2MaxByWeekByUser[userId] = merged
        if userId == me.id {
            vo2MaxByWeek = merged
        }
    }

    func vo2Max(forWeekContaining date: Date) -> Double? {
        vo2Max(forWeekContaining: date, userId: me.id)
    }

    func vo2Max(forWeekContaining date: Date, userId: String) -> Double? {
        vo2MaxByWeekByUser[userId]?[mondayOfWeek(for: date)]
    }

    // Convenience: VO2 series for a user within an optional interval (nil = all)
    func vo2Values(for userId: String, in interval: DateInterval?) -> [(Date, Double)] {
        let base = vo2MaxByWeekByUser[userId] ?? [:]
        let s = interval?.start
        let e = interval?.end
        return base
            .filter { wk, _ in
                if let s = s, wk < s { return false }
                if let e = e, wk >= e { return false }
                return true
            }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    // Update break reason/notes for a given week and persist
    func setBreak(reason: BreakReason, notes: String, forWeekStart weekStart: Date) {
        weekBreaks[weekStart] = (reason, notes)
        saveWeekBreaks()
    }

    // Compute summary for the current user for a given week
    func weekSummary(for date: Date) -> WeekSummary {
        let weekStart = mondayOfWeek(for: date)
        let target = weeklyPlan(for: weekStart)
        let mine = workouts.filter { $0.userId == me.id }
        let latestVO2 = vo2Max(forWeekContaining: date, userId: me.id)

        let reqRuns = requiredRunsForMasterPlan(weekStart: weekStart)

        var summary = compliance.summarize(weekStart: weekStart,
                                           workouts: mine,
                                           requiredWeeklyMiles: target.requiredWeeklyMiles,
                                           latestVO2Max: latestVO2,
                                           requiredRuns: reqRuns)
        if summary.userId == "unknown" {
            summary.userId = me.id
            summary.id = "\(me.id)_\(isoDate(weekStart))"
        }
        if let br = weekBreaks[weekStart] {
            summary.breakReason = br.reason
            summary.breakNotes = br.notes.isEmpty ? nil : br.notes
        }
        return summary
    }

    // Compute summary for any user for a specific week (for Team Week view)
    func weekSummary(forWeekStart weekStart: Date, userId: String) -> WeekSummary {
        let wk = mondayOfWeek(for: weekStart)
        let target = weeklyPlan(for: wk)
        let theirs = workouts.filter { $0.userId == userId }
        let latestVO2 = vo2Max(forWeekContaining: wk, userId: userId)

        let reqRuns = requiredRunsForMasterPlan(weekStart: wk)

        var summary = compliance.summarize(weekStart: wk,
                                           workouts: theirs,
                                           requiredWeeklyMiles: target.requiredWeeklyMiles,
                                           latestVO2Max: latestVO2,
                                           requiredRuns: reqRuns)
        if summary.userId == "unknown" {
            summary.userId = userId
            summary.id = "\(userId)_\(isoDate(wk))"
        }
        if userId == me.id, let br = weekBreaks[wk] {
            summary.breakReason = br.reason
            summary.breakNotes = br.notes.isEmpty ? nil : br.notes
        }
        return summary
    }

    // MARK: - Helper to determine required runs from master plan note

    private func requiredRunsForMasterPlan(weekStart: Date) -> Int {
        let wk = mondayOfWeek(for: weekStart)
        if let note = masterPlan[wk]?.note,
           note.localizedCaseInsensitiveContains("two rec runs") {
            return 4
        }
        return 3
    }

    // MARK: - Heart Rate Zones aggregation

    // Approximate zone index for a single HR value using HRR thresholds
    private func zoneIndex(for bpm: Double, maxHR: Double, restingHR: Double) -> Int {
        let reserve = max(1.0, maxHR - restingHR)
        let pct = (bpm - restingHR) / reserve
        if pct < 0.60 { return 0 }
        if pct < 0.70 { return 1 }
        if pct < 0.80 { return 2 }
        if pct < 0.90 { return 3 }
        return 4
    }

    // Aggregate zones for a set of runs for a given user.
    // For the current user, compute/cached via HealthKit. For others, use stored zones if available,
    // otherwise approximate from avgHR (all time in one zone). Resting HR: estimated for current user or default 60.
    func aggregateZones(for runs: [WorkoutEntry], userId: String) async -> (ZoneBreakdown, Int) {
        let viewerID = me.id
        var durations = Array(repeating: 0.0, count: 5)
        var total: TimeInterval = 0

        // Resting HR
        var rhr = restingHRByUser[userId] ?? 60
        if userId == me.id {
            // Try to estimate/cached RHR via HealthKit
            let est = await HealthKitManager.shared.estimateRestingHR()
            guard me.id == viewerID, !Task.isCancelled else { return (ZoneBreakdown(), rhr) }
            rhr = est
            restingHRByUser[userId] = est
        }

        // For current user, try to authorize once up-front
        if userId == me.id {
            try? await HealthKitManager.shared.requestAuthorization()
        }

        for w in runs {
            guard me.id == viewerID, !Task.isCancelled else { return (ZoneBreakdown(), rhr) }
            guard workouts.first(where: { $0.id == w.id }) == w else { continue }
            // 1) Use cached/stored zonesByWorkout first
            if let z = zonesByWorkout[w.id] {
                for i in 0..<min(5, z.durations.count) { durations[i] += z.durations[i] }
                total += z.total
                continue
            }
            // 2) Use embedded zones on the workout if present (from CloudKit or local compute)
            if let z = w.zones {
                zonesByWorkout[w.id] = z
                for i in 0..<min(5, z.durations.count) { durations[i] += z.durations[i] }
                total += z.total
                continue
            }
            // 3) If current user, compute from HealthKit and cache
            if userId == me.id {
                if let z = try? await HealthKitManager.shared.zoneBreakdown(forRun: w.start, end: w.end) {
                    guard me.id == viewerID, !Task.isCancelled,
                          workouts.first(where: { $0.id == w.id }) == w else { continue }
                    zonesByWorkout[w.id] = z
                    for i in 0..<min(5, z.durations.count) { durations[i] += z.durations[i] }
                    total += z.total
                    continue
                }
            }
            // 4) Fallback: approximate from avgHR if present (assign full duration to one zone)
            if let avg = w.avgHR {
                let idx = zoneIndex(for: avg, maxHR: Double(HealthKitManager.shared.estimateMaxHR()), restingHR: Double(rhr))
                if idx >= 0 && idx < 5 {
                    durations[idx] += w.durationSec
                    total += w.durationSec
                }
            }
        }

        return (ZoneBreakdown(durations: durations, total: total), rhr)
    }

    // MARK: - Merged plan (team override > master plan > engine base)

    func weeklyPlan(for weekStart: Date) -> (requiredWeeklyMiles: Double, suggested: PlanSplit) {
        let wk = mondayOfWeek(for: weekStart)

        // Hard-coded for everyone: prefer the seeded master plan; ignore per-user/team overrides.
        if let master = masterPlan[wk] {
            let total = master.recovery + master.tempo + master.long
            return (requiredWeeklyMiles: total, suggested: master)
        }

        // Fallback to engine if a week is not in the seed.
        let base = plan.weeklyTarget(for: wk, settings: settings)
        let split = PlanSplit(recovery: base.suggested.recovery,
                              tempo: base.suggested.tempo,
                              long: base.suggested.long,
                              note: nil)
        return (requiredWeeklyMiles: base.requiredWeeklyMiles, suggested: split)
    }

    // Set/clear a team-wide override (disabled via allowedPlanEditors = [])
    func setPlanOverride(for weekStart: Date, split: PlanSplit?) {
        // Enforce editor permission: only allow specific user(s).
        guard canEditTeamPlan else {
            print("Ignoring plan override change: user \(me.id) is not allowed to edit team plan.")
            return
        }

        let wk = mondayOfWeek(for: weekStart)
        if let split {
            userPlanOverrides[wk] = split
        } else {
            userPlanOverrides.removeValue(forKey: wk)
        }
        saveUserPlanOverrides()

        // Push to CloudKit so all users see this override
        Task.detached {
            do {
                if let split {
                    try await CloudKitManager.shared.upsertPlanOverride(forWeekStart: wk, split: split)
                } else {
                    try await CloudKitManager.shared.deletePlanOverride(weekStart: wk)
                }
            } catch {
                print("Cloud plan override sync failed: \(error)")
            }
        }
    }

    // MARK: - Persistence for weekBreaks

    private struct WeekBreakRecord: Codable {
        var weekStart: Date
        var reason: BreakReason
        var notes: String
    }

    private func saveWeekBreaks() {
        let records = weekBreaks.map { WeekBreakRecord(weekStart: $0.key, reason: $0.value.reason, notes: $0.value.notes) }
        do {
            let data = try JSONEncoder().encode(records)
            UserDefaults.standard.set(data, forKey: breaksStorageKey)
        } catch {
            print("Failed to save weekBreaks: \(error)")
        }
    }

    private func loadWeekBreaks() {
        guard let data = UserDefaults.standard.data(forKey: breaksStorageKey) else { return }
        do {
            let records = try JSONDecoder().decode([WeekBreakRecord].self, from: data)
            var dict: [Date: (BreakReason, String)] = [:]
            for r in records {
                dict[r.weekStart] = (r.reason, r.notes)
            }
            weekBreaks = dict
        } catch {
            print("Failed to load weekBreaks: \(error)")
        }
    }

    // MARK: - Persistence for Important Dates

    func saveImportantDates() {
        do {
            let data = try JSONEncoder().encode(importantDates)
            UserDefaults.standard.set(data, forKey: importantDatesKey)
        } catch {
            print("Failed to save importantDates: \(error)")
        }
    }

    private func loadImportantDates() {
        if let data = UserDefaults.standard.data(forKey: importantDatesKey) {
            do {
                importantDates = try JSONDecoder().decode([ImportantDate].self, from: data)
                return
            } catch {
                print("Failed to decode importantDates: \(error)")
            }
        }
        importantDates = ImportantDate.seeded
        saveImportantDates()
    }

    // MARK: - Persistence for Master Plan + User Overrides

    private struct PlanOverrideRecord: Codable {
        var weekStart: Date
        var split: PlanSplit
    }

    private func saveMasterPlan() {
        do {
            let records = masterPlan.map { PlanOverrideRecord(weekStart: $0.key, split: $0.value) }
            let data = try JSONEncoder().encode(records)
            UserDefaults.standard.set(data, forKey: masterPlanKey)
        } catch {
            print("Failed to save masterPlan: \(error)")
        }
    }

    private func loadMasterPlan() {
        // Hardcode the master plan to the seeded values; ignore persistence/versioning.
        masterPlan = seedPlanOverridesAthens()
        syncLegacyPlanAlias()
    }

    private func saveUserPlanOverrides() {
        do {
            let records = userPlanOverrides.map { PlanOverrideRecord(weekStart: $0.key, split: $0.value) }
            let data = try JSONEncoder().encode(records)
            UserDefaults.standard.set(data, forKey: userPlanOverridesKey)
        } catch {
            print("Failed to save userPlanOverrides: \(error)")
        }
    }

    private func loadUserPlanOverrides() {
        guard let data = UserDefaults.standard.data(forKey: userPlanOverridesKey) else {
            userPlanOverrides = [:]
            return
        }
        do {
            let records = try JSONDecoder().decode([PlanOverrideRecord].self, from: data)
            var dict: [Date: PlanSplit] = [:]
            for r in records { dict[r.weekStart] = r.split }
            userPlanOverrides = dict // will sync planOverrides via didSet
        } catch {
            print("Failed to decode userPlanOverrides: \(error)")
            userPlanOverrides = [:]
        }
    }

    // Force replace persisted master plan with the current seed list.
    func forceReseedMasterPlanFromSeed() {
        masterPlan = seedPlanOverridesAthens()
        saveMasterPlan()
        UserDefaults.standard.set(currentMasterPlanSeedVersion, forKey: masterPlanSeedVersionKey)
        syncLegacyPlanAlias()
    }

    private func seedPlanOverridesAthens() -> [Date: PlanSplit] {
        let rows: [(String, Double, Double, Double, String?)] = [
            ("2025-10-27", 0, 0, 2, nil),
            ("2025-11-03", 2.3, 2.3, 3.1, nil),
            ("2025-11-10", 2.3, 2.3, 3.1, nil),
            ("2025-11-17", 2.3, 2.3, 4.0, nil),
            ("2025-11-24", 2.2, 2.3, 5.0, nil),
            ("2025-12-01", 2.0, 2.0, 3.0, "Consolidation"),
            ("2025-12-08", 2.5, 2.5, 5.0, nil),
            ("2025-12-15", 2.4, 3.1, 5.5, nil),
            ("2025-12-22", 2.3, 3.1, 6.2, nil),
            ("2025-12-29", 2.0, 2.0, 5.0, "Consolidation"),
            ("2026-01-05", 3.1, 3.1, 6.0, nil),
            ("2026-01-12", 3.1, 3.1, 6.7, nil),
            ("2026-01-19", 3.1, 3.5, 7.0, nil),

            ("2026-01-26", 2.5, 2.5, 4.5, "Consolidation"),
            ("2026-02-02", 2.7, 2.7, 7.3, nil),
            ("2026-02-09", 2.8, 2.9, 7.7, nil),
            ("2026-02-16", 3.0, 3.0, 8.1, nil),
            ("2026-02-23", 2.7, 2.8, 6.0, "Consolidation"),
            ("2026-03-02", 3.0, 3.1, 8.5, nil),
            ("2026-03-09", 3.1, 3.1, 9.0, nil),
            ("2026-03-16", 3.1, 3.2, 9.5, nil),
            ("2026-03-23", 2.8, 2.9, 7.0, "Consolidation"),
            ("2026-03-30", 3.1, 3.4, 10.0, nil),

            ("2026-04-06", 3.1, 3.5, 11.0, nil),
            ("2026-04-13", 3.1, 3.7, 12.0, nil),

            ("2026-04-20", 1.8 + 1.4, 3.1, 7.0, "Consolidation • Two Rec Runs"),
            ("2026-04-27", 2.5 + 1.0, 3.5, 10.0, "Two Rec Runs"),
            ("2026-05-04", 2.5 + 1.5, 4.0, 11.0, "Two Rec Runs"),
            ("2026-05-11", 3.0 + 1.4, 4.4, 12.0, "Two Rec Runs"),

            ("2026-05-18", 3.0, 3.0, 9.0, "Consolidation"),

            ("2026-05-25", 3.2 + 1.6, 4.9, 13.0, "Two Rec Runs"),
            ("2026-06-01", 3.5 + 1.8, 5.3, 14.0, "Two Rec Runs"),
            ("2026-06-08", 3.8 + 2.0, 5.8, 15.0, "Two Rec Runs"),

            ("2026-06-15", 4.0, 4.0, 11.0, "Consolidation"),

            ("2026-06-22", 3.8 + 2.0, 5.8, 15.0, "Two Rec Runs"),
            ("2026-06-29", 4.0 + 2.2, 6.2, 16.0, "Two Rec Runs"),
            ("2026-07-06", 4.0 + 2.2, 6.2, 16.0, "Two Rec Runs"),
            ("2026-07-13", 2.4 + 2.0, 4.4, 12.0, "Consolidation • Two Rec Runs"),

            ("2026-07-20", 4.0 + 2.2, 6.2, 16.0, "Two Rec Runs"),
            ("2026-07-27", 4.2 + 2.4, 6.7, 17.0, "Two Rec Runs"),
            ("2026-08-03", 4.5 + 2.6, 7.1, 18.0, "Two Rec Runs"),
            ("2026-08-10", 3.2 + 1.6, 4.9, 13.0, "Consolidation • Two Rec Runs"),
            ("2026-08-17", 4.0 + 2.2, 6.2, 16.0, "Two Rec Runs"),

            ("2026-08-24", 4.5 + 2.6, 7.1, 18.0, "Two Rec Runs"),
            ("2026-08-31", 4.8 + 2.8, 7.6, 19.0, "Two Rec Runs"),
            ("2026-09-07", 3.5 + 1.8, 5.3, 14.0, "Consolidation • Two Rec Runs"),
            ("2026-09-14", 4.5 + 2.6, 7.1, 18.0, "Two Rec Runs"),
            ("2026-09-21", 5.0 + 3.0, 8.0, 20.0, "Two Rec Runs"),
            ("2026-09-28", 3.8 + 2.0, 5.8, 15.0, "Two Rec Runs"),
            ("2026-10-05", 4.5 + 2.6, 7.1, 18.0, "Consolidation • Two Rec Runs"),
            ("2026-10-12", 3.5 + 1.8, 5.3, 14.0, "Two Rec Runs"),

            ("2026-10-19", 3.5, 3.5, 10.0, nil),
            ("2026-10-26", 1.7, 1.7, 6.0, nil),
            ("2026-11-02", 3.0, 2.0, 0.0, "Consolidation")
        ]

        var dict: [Date: PlanSplit] = [:]
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        // Important: parse in the device's time zone so week keys align with local Monday-of-week.
        f.timeZone = Calendar.current.timeZone
        f.dateFormat = "yyyy-MM-dd"
        for (ds, rec, tmp, lng, note) in rows {
            if let d = f.date(from: ds) {
                let wk = mondayOfWeek(for: d)
                dict[wk] = PlanSplit(recovery: rec, tempo: tmp, long: lng, note: note)
            }
        }
        return dict
    }

    // MARK: - CloudKit bootstrap and current user persistence

    /// Updates the active profile after onboarding or verified CloudKit account
    /// resolution. Arbitrary profile switching is debug-only; production code
    /// must not use this to act as a teammate.
    func setCurrentUser(_ user: UserProfile) {
        let oldId = me.id
        let didChangeIdentity = oldId != user.id
        me = user
        saveCurrentUserId(user.id)

        if didChangeIdentity {
            identityRevision += 1
            weeklyReviewImport = nil
            if oldId != legacyMeUserId {
                retainedPersonalWorkouts[oldId] = workouts.filter { $0.userId == oldId }
                workouts = retainedPersonalWorkouts[user.id] ?? workouts.filter { $0.userId == user.id }
                zonesByWorkout.removeAll()
                likeCountByWorkout.removeAll()
                didILikeByWorkout.removeAll()
            }
            // Do not let a prior profile's cached preference post a workout
            // while the new profile's CloudKit preference is still loading.
            isTeamSyncEnabled = false
            setAutoUploadRunsToCloudEnabled(false)
            clearLegacyTeamFeedCacheForIdentityChange()
        }

        // The old unowned placeholder is the only identifier that may be
        // reattributed synchronously. A real profile change must go through
        // the verified same-owner alias migration below, never an arbitrary
        // local or public-record rewrite.
        if oldId == legacyMeUserId, oldId != user.id {
            workouts = workouts.map { w in
                guard w.userId == oldId else { return w }
                var copy = w
                copy.userId = user.id
                return copy
            }
            // Persist demo workouts if we are using local demo data
            saveDemoWorkoutsIfDemoActive()
        }

        if let idx = allUsers.firstIndex(where: { $0.id == user.id }) {
            allUsers[idx] = user
        } else {
            allUsers.append(user)
        }
        allUsers.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        // Mirror per-user VO2 to current-user convenience map
        vo2MaxByWeek = vo2MaxByWeekByUser[user.id] ?? [:]

        Task {
            try? await CloudKitManager.shared.upsertUser(user)
            await bindCurrentUserToCurrentOwnerIfNeeded()
            await migrateOwnedAliasWorkoutsToCurrentUserIfNeeded()
        }
        // Ensure push notifications + subscriptions reflect this user’s prefs
        Task {
            await applyNotificationPrefsForCurrentUser()
            await refreshTeamFeedFromCloud(force: true)
        }

        // Persist demo users if applicable
        saveDemoUsersIfDemoActive()

        // Refresh likes for visible workouts under the new identity
        Task { await preloadLikes(for: workouts.map { $0.id }) }

        // Refresh ownership flags so the menu shows which profile is "Yours"
        Task { await refreshOwnershipFlags() }

        // One-time migration for legacy "me" workouts to current profile id
        Task { @MainActor in
            self.migrateLegacyMeWorkoutsIfNeeded()
        }
    }

    private func loadCurrentUserId() -> String? {
        UserDefaults.standard.string(forKey: currentUserIdKey)
    }

    private func saveCurrentUserId(_ id: String) {
        UserDefaults.standard.set(id, forKey: currentUserIdKey)
    }

    private func bindCurrentUserToCurrentOwnerIfNeeded() async {
        let snapshot = await MainActor.run { self.me }
        guard !snapshot.id.isEmpty else { return }
        guard let owner = await CloudKitManager.shared.currentUserRecordName(), !owner.isEmpty else { return }
        guard snapshot.ownerUserRecordName != owner else { return }

        var updated = snapshot
        updated.ownerUserRecordName = owner

        do {
            try await CloudKitManager.shared.upsertUser(updated)
        } catch {
            print("CloudKit profile ownership update failed: \(error)")
            return
        }

        await MainActor.run {
            guard self.me.id == updated.id else { return }
            self.me = updated
            if let idx = self.allUsers.firstIndex(where: { $0.id == updated.id }) {
                self.allUsers[idx] = updated
            } else {
                self.allUsers.append(updated)
            }
            self.allUsers.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            self.saveDemoUsersIfDemoActive()
        }
    }

    private func ownedAliasMigrationKey(ownerRecordName: String, userId: String) -> String {
        "\(ownedAliasMigrationKeyPrefix)_\(ownerRecordName)_\(userId)"
    }

    private func migrateOwnedAliasWorkoutsToCurrentUserIfNeeded() async {
        let snapshot = await MainActor.run { () -> (UserProfile, [UserProfile]) in
            (self.me, self.allUsers)
        }
        guard !snapshot.0.id.isEmpty else { return }
        guard let owner = snapshot.0.ownerUserRecordName, !owner.isEmpty else { return }

        let migrationKey = ownedAliasMigrationKey(ownerRecordName: owner, userId: snapshot.0.id)
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        let aliasIds = snapshot.1
            .filter { $0.id != snapshot.0.id && $0.ownerUserRecordName == owner }
            .map { $0.id }

        guard !aliasIds.isEmpty else {
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }

        await MainActor.run {
            guard self.me.id == snapshot.0.id else { return }
            var changed = false
            for i in self.workouts.indices where aliasIds.contains(self.workouts[i].userId) {
                self.workouts[i].userId = snapshot.0.id
                changed = true
            }
            if changed {
                self.saveDemoWorkoutsIfDemoActive()
            }
        }

        let stillCurrent = await MainActor.run { self.me.id == snapshot.0.id }
        guard stillCurrent else { return }

        let canUpdatePublicFeed = await MainActor.run { self.isTeamSyncEnabled }
        if canUpdatePublicFeed {
            for alias in aliasIds {
                try? await CloudKitManager.shared.migrateWorkoutsUserId(from: alias, to: snapshot.0.id)
            }
        }

        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    private func isoDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withFullDate]
        return f.string(from: date)
    }

    private var recentWorkoutsStartDate: Date {
        Calendar.current.date(byAdding: .day, value: -recentWorkoutsWindowDays, to: Date())
        ?? Date().addingTimeInterval(-Double(recentWorkoutsWindowDays) * 24 * 3600)
    }

    @MainActor
    private func applyCloudWorkoutSnapshot(_ rows: [WorkoutEntry], teamID: String,
                                           since: Date, startedAtRevision: Int) {
        let editsDuringFetch = Set(localEditRevisions.compactMap { id, revision in
            revision > startedAtRevision ? id : nil
        })
        let reconciled = TeamWorkoutSnapshot.reconcile(
            local: workouts, remote: rows, currentUserID: me.id, teamID: teamID, since: since,
            preservingLocalIDs: pendingWorkoutUploads.union(editsDuringFetch),
            deletedIDs: deletedWorkoutIDs
        )
        let liveIDs = Set(reconciled.map(\.id))
        // Rebuild derived caches so removed HR data does not outlive its record.
        zonesByWorkout = Dictionary(reconciled.compactMap { row in
            row.zones.map { (row.id, $0) }
        }, uniquingKeysWith: { _, latest in latest })
        likeCountByWorkout = likeCountByWorkout.filter { liveIDs.contains($0.key) }
        didILikeByWorkout = didILikeByWorkout.filter { liveIDs.contains($0.key) }
        workouts = reconciled
        let confirmedSharedIDs = Set(rows.filter {
            $0.isShared && $0.teamId == teamID && $0.start >= teamSharedHistoryStartDate()
        }.map(\.id))
        cloudTeamFeed = reconciled.filter {
            confirmedSharedIDs.contains($0.id) && $0.isShared && $0.teamId == teamID
        }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start > $1.start }
        saveDemoWorkoutsIfDemoActive()
        saveTeamFeedCache(rows: cloudTeamFeed, teamId: teamID)
    }

    private func setAllUsers(_ users: [UserProfile]) {
        allUsers = users.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func cloudBootstrap() async {
        await refreshFromCloud()
        guard teamSyncError == nil, hasActiveProfile else { return }
        await applyNotificationPrefsForCurrentUser()
        await syncMyRecentHealthRuns()
        await backfillZonesForCurrentUserIfNeeded()
    }

    /// Refresh the roster, workouts and feed together. Explicit refreshes arriving
    /// during a fetch request one follow-up pass instead of being dropped.
    @MainActor
    func refreshFromCloud(force: Bool = true) async {
        if let task = cloudRefreshTask {
            if force { cloudRefreshRequested = true }
            await task.value
            return
        }
        if !force, let last = teamFeedLastRefreshAt,
           Date().timeIntervalSince(last) < teamFeedMinRefreshInterval { return }
        isTeamFeedLoading = true
        let task = Task { @MainActor in
            repeat {
                cloudRefreshRequested = false
                await performCloudRefresh()
            } while cloudRefreshRequested && !Task.isCancelled
            isTeamFeedLoading = false
            cloudRefreshTask = nil
        }
        cloudRefreshTask = task
        await task.value
    }

    @MainActor
    private func performCloudRefresh() async {
        let startingIdentity = identityRevision
        var expectedIdentity = startingIdentity
        let startingEditRevision = workoutEditRevision
        // Load the complete supported season, not a latest-200 preview.
        let since = min(recentWorkoutsStartDate, teamSharedHistoryStartDate())
        CloudKitManager.shared.refreshAvailability()
        do {
            async let usersTask = CloudKitManager.shared.fetchAllUsers()
            async let workoutsTask = CloudKitManager.shared.fetchWorkouts(since: since)
            let users = try await usersTask
            let currentOwner = await CloudKitManager.shared.currentUserRecordName()
            guard identityRevision == startingIdentity else { return }
            guard let currentOwner else {
                teamSyncError = "Could not verify iCloud. Showing previously loaded data."
                return
            }
            setAllUsers(users)
            // Keep the current profile when an owner has multiple legacy aliases.
            let mine = TeamWorkoutSnapshot.linkedProfile(in: users, ownerRecordName: currentOwner,
                                                          currentUserID: me.id)
            guard let mine else {
                clearActiveProfileForUnresolvedCloudAccount()
                teamSyncError = "Link your profile to iCloud to refresh team data."
                return
            }
            if me.id != mine.id {
                setCurrentUser(mine)
            } else {
                // A valid same-profile match updates details; it must not log out.
                me = mine
            }
            let resolvedIdentity = identityRevision
            expectedIdentity = resolvedIdentity
            let uid = me.id
            let prefs = try await CloudKitManager.shared.fetchNotificationPrefs(userId: uid)
            let rows = try await workoutsTask
            guard identityRevision == resolvedIdentity, me.id == uid else { return }
            Self.saveCachedNotificationPrefs(prefs)
            applyCloudWorkoutSnapshot(rows, teamID: prefs.teamId, since: since,
                                      startedAtRevision: startingEditRevision)
            teamFeedLastRefreshAt = Date()
            teamSyncError = nil
            // Supplementary requests must not hold the full-refresh spinner open.
            Task {
                await self.preloadLikes(for: self.cloudTeamFeed.map(\.id))
                await self.refreshOwnershipFlags()
            }
        } catch {
            guard identityRevision == expectedIdentity else { return }
            teamSyncError = "Team refresh failed. Showing previously loaded data; pull to retry."
            print("Cloud refresh failed: \(error)")
        }
    }

    // Compatibility entry points use the same complete snapshot as every tab.
    func refreshTeamFeedFromCloud(limit: Int? = nil, force: Bool = false) async {
        await refreshFromCloud(force: force)
    }

    func fetchTeamFeedRunsForUser(userId: String, limit: Int? = nil) async -> [WorkoutEntry] {
        await refreshFromCloud()
        let rows = cloudTeamFeed.filter { $0.userId == userId }
        if let limit, limit > 0 { return Array(rows.prefix(limit)) }
        return rows
    }

    func setTeamFeedPostingLookbackDays(_ days: Int) {
        let normalized = normalizedTeamFeedPostingLookbackDays(days)
        teamFeedPostingLookbackDays = normalized
        UserDefaults.standard.set(normalized, forKey: teamFeedPostingLookbackDaysKey)
    }

    func teamFeedPostingLookbackLabel(days: Int? = nil) -> String {
        let _ = days
        return "Since \(Self.teamSharedHistoryStartDateLabel)"
    }

    func teamSharedHistoryStartDate() -> Date {
        CloudKitManager.teamSharedHistoryStartDate
    }

    private func normalizedTeamFeedPostingLookbackDays(_ days: Int) -> Int {
        let normalized = max(0, days)
        if Self.teamFeedPostingLookbackOptionsInternal.contains(normalized) {
            return normalized
        }
        return Self.defaultTeamFeedPostingLookbackDays
    }

    private func loadTeamFeedPostingLookbackDays() -> Int {
        if UserDefaults.standard.object(forKey: teamFeedPostingLookbackDaysKey) == nil {
            return Self.defaultTeamFeedPostingLookbackDays
        }
        return normalizedTeamFeedPostingLookbackDays(
            UserDefaults.standard.integer(forKey: teamFeedPostingLookbackDaysKey)
        )
    }

    private func configuredHealthPostingStartDate(relativeTo now: Date = Date(),
                                                  lookbackDays: Int? = nil) -> Date {
        let _ = now
        let _ = lookbackDays
        return teamSharedHistoryStartDate()
    }

    private func saveTeamFeedCache(rows: [WorkoutEntry], teamId: String? = nil) {
        let payload = TeamFeedCachePayload(updatedAt: Date(),
                                           userId: me.id,
                                           teamId: teamId,
                                           rows: rows)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: teamFeedCacheKey)
    }

    private func loadTeamFeedCache() {
        guard hasActiveProfile else { return }
        guard let data = UserDefaults.standard.data(forKey: teamFeedCacheKey),
              let payload = try? JSONDecoder().decode(TeamFeedCachePayload.self, from: data) else {
            return
        }
        if !payload.userId.isEmpty,
           !me.id.isEmpty,
           payload.userId != me.id {
            return
        }
        guard payload.userId == me.id, let teamID = payload.teamId,
              let prefs = Self.loadCachedNotificationPrefs(userId: me.id), prefs.teamId == teamID else { return }
        let sorted = payload.rows.filter { $0.isShared && $0.teamId == teamID }.sorted { $0.start > $1.start }
        workouts = TeamWorkoutSnapshot.reconcile(local: workouts, remote: sorted, currentUserID: me.id,
                                                  teamID: teamID, since: teamSharedHistoryStartDate())
        cloudTeamFeed = sorted
        teamFeedLastRefreshAt = payload.updatedAt
        // Prime zones cache from cached feed so summaries/detail cards have immediate data.
        for row in sorted {
            if let z = row.zones {
                zonesByWorkout[row.id] = z
            }
        }
    }

    /// The V1 feed cache contains full legacy workout records. It is not a
    /// cross-account cache and must not survive an identity transition.
    private func clearLegacyTeamFeedCacheForIdentityChange() {
        cloudTeamFeed.removeAll()
        teamFeedLastRefreshAt = nil
        teamSyncError = nil
        UserDefaults.standard.removeObject(forKey: teamFeedCacheKey)
    }

    /// A live iCloud account that does not map to a claimed profile is an
    /// onboarding state, not permission to retain the last device user's
    /// identity or sharing preference.
    private func clearActiveProfileForUnresolvedCloudAccount() {
        identityRevision += 1
        retainedPersonalWorkouts[me.id] = workouts.filter { $0.userId == me.id }
        workouts.removeAll()
        zonesByWorkout.removeAll()
        likeCountByWorkout.removeAll()
        didILikeByWorkout.removeAll()
        me = .mePlaceholder()
        UserDefaults.standard.removeObject(forKey: currentUserIdKey)
        isTeamSyncEnabled = false
        setAutoUploadRunsToCloudEnabled(false)
        vo2MaxByWeek.removeAll()
        clearLegacyTeamFeedCacheForIdentityChange()
    }

    private static func fetchNotificationPrefsWithTimeout(userId: String, seconds: Double) async -> NotificationPrefs {
        let fallback = loadCachedNotificationPrefs(userId: userId) ?? NotificationPrefs.defaults(for: userId)
        let result = await withTaskGroup(of: NotificationPrefs.self, returning: NotificationPrefs.self) { group in
            group.addTask {
                do {
                    return try await CloudKitManager.shared.fetchNotificationPrefs(userId: userId)
                } catch {
                    return fallback
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return fallback
            }
            let result = await group.next() ?? fallback
            group.cancelAll()
            return result
        }
        saveCachedNotificationPrefs(result)
        return result
    }

    private static func notificationPrefsCacheKey(for userId: String) -> String {
        "\(notificationPrefsCacheKeyPrefix)\(userId)"
    }

    private static func loadCachedNotificationPrefs(userId: String) -> NotificationPrefs? {
        guard let data = UserDefaults.standard.data(forKey: notificationPrefsCacheKey(for: userId)) else {
            return nil
        }
        return try? JSONDecoder().decode(NotificationPrefs.self, from: data)
    }

    private static func saveCachedNotificationPrefs(_ prefs: NotificationPrefs) {
        if let data = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(data, forKey: notificationPrefsCacheKey(for: prefs.userId))
        }
    }

    // MARK: - Run type overrides persistence

    private func saveRunTypeOverrides() {
        let rawMap = runTypeOverrides.mapValues { $0.rawValue }
        do {
            let data = try JSONEncoder().encode(rawMap)
            UserDefaults.standard.set(data, forKey: runTypeOverridesKey)
        } catch {
            print("Failed to save runTypeOverrides: \(error)")
        }
    }

    private func loadRunTypeOverrides() {
        guard let data = UserDefaults.standard.data(forKey: runTypeOverridesKey) else { return }
        do {
            let rawMap = try JSONDecoder().decode([String: String].self, from: data)
            var map: [String: RunType] = [:]
            for (k, v) in rawMap {
                if let t = RunType(rawValue: v) {
                    map[k] = t
                }
            }
            runTypeOverrides = map
        } catch {
            print("Failed to load runTypeOverrides: \(error)")
        }
    }

    private func applyRunTypeOverrides() {
        guard !runTypeOverrides.isEmpty else { return }
        for i in workouts.indices where workouts[i].userId == me.id {
            if let t = runTypeOverrides[workouts[i].id] {
                workouts[i].runType = t
            }
        }
    }

    // Auto-assign default run types for the current user per week:
    // First Recovery, then Tempo, then Long; any additional runs that week default to Recovery.
    private func assignDefaultRunTypesForCurrentUser() {
        let uid = me.id
        guard !uid.isEmpty else { return }

        // Collect and sort my runs
        let myRuns = workouts.filter { $0.userId == uid }.sorted { $0.start < $1.start }
        guard !myRuns.isEmpty else { return }

        // Group by Monday-of-week
        var byWeek: [Date: [WorkoutEntry]] = [:]
        for w in myRuns {
            let wk = mondayOfWeek(for: w.start)
            byWeek[wk, default: []].append(w)
        }

        for (_, runs) in byWeek {
            // Track which slots are already filled by existing typed runs
            var recFilled = runs.contains { $0.runType == .recovery }
            var tempoFilled = runs.contains { $0.runType == .tempo }
            var longFilled = runs.contains { $0.runType == .long }

            // Prepare assignments in chronological order, but only for runs still typed as .other
            var toAssign: [(String, RunType)] = []
            for w in runs.sorted(by: { $0.start < $1.start }) where w.runType == .other && runTypeOverrides[w.id] == nil {
                if !recFilled {
                    toAssign.append((w.id, .recovery)); recFilled = true
                } else if !tempoFilled {
                    toAssign.append((w.id, .tempo)); tempoFilled = true
                } else if !longFilled {
                    toAssign.append((w.id, .long)); longFilled = true
                } else {
                    toAssign.append((w.id, .recovery))
                }
            }

            // Apply via the existing setter so overrides are persisted and CloudKit is updated for my runs
            for (id, t) in toAssign {
                setRunType(t, forWorkoutId: id)
            }
        }
    }

    // MARK: - Legacy userId migration ("me" -> real profile id)

    @MainActor
    func migrateLegacyMeWorkoutsIfNeeded() {
        let newId = me.id
        guard newId != legacyMeUserId else { return } // still placeholder from very old builds
        guard !UserDefaults.standard.bool(forKey: userIdMigrationKey) else { return }

        // Find any legacy "me" workouts
        let legacy = workouts.filter { $0.userId == legacyMeUserId }
        guard !legacy.isEmpty else {
            UserDefaults.standard.set(true, forKey: userIdMigrationKey)
            return
        }

        // Update local store
        for i in workouts.indices where workouts[i].userId == legacyMeUserId {
            workouts[i].userId = newId
        }

        // Persist if demo/local storage is active
        saveDemoWorkoutsIfDemoActive()

        // Re-attribute only records that were already public and only while the
        // user has team sync enabled. Local migration remains safe either way.
        if isTeamSyncEnabled {
            let alreadyShared = legacy.filter(\.isShared)
            Task.detached {
                for w in alreadyShared {
                    var fixed = w
                    fixed.userId = newId
                    do { try await CloudKitManager.shared.upsertWorkout(fixed) }
                    catch { print("Migration upsert failed for \(fixed.id): \(error)") }
                }
            }
        }

        UserDefaults.standard.set(true, forKey: userIdMigrationKey)
    }

    // MARK: - Local demo seeding (no CloudKit required)

    // Load saved demo data immediately at app launch (if present)
    private func loadDemoIfAvailable() {
        guard allUsers.isEmpty && workouts.isEmpty else { return }
        if let users = loadDemoUsers(), let runs = loadDemoWorkouts(), !users.isEmpty {
            allUsers = users.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            workouts = runs.sorted { $0.start < $1.start }
            if let savedId = loadCurrentUserId(),
               savedId != legacyMeUserId,
               let found = allUsers.first(where: { $0.id == savedId }) {
                me = found
            } else if me.id.isEmpty, let first = allUsers.first {
                me = first
                saveCurrentUserId(first.id)
            }
        }
    }

    // If cloud returned nothing, seed (or load) local demo users + workouts so you can test multi-user features.
    fileprivate func seedLocalDemoIfNeeded() {
        guard allUsers.isEmpty && workouts.isEmpty else { return }

        // If we have previously saved demo, load it
        if let users = loadDemoUsers(), let runs = loadDemoWorkouts(), !users.isEmpty {
            allUsers = users.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            workouts = runs.sorted { $0.start < $1.start }
            if let savedId = loadCurrentUserId(),
               savedId != legacyMeUserId,
               let found = allUsers.first(where: { $0.id == savedId }) {
                me = found
            } else if me.id.isEmpty, let first = allUsers.first {
                me = first
                saveCurrentUserId(first.id)
            }
            // Preload likes for demo
            Task { await preloadLikes(for: workouts.map { $0.id }) }
            return
        }

        // Fresh seed
        let users = generateDemoUsers()
        let runs = generateDemoWorkouts(for: users)

        allUsers = users.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        workouts = runs.sorted { $0.start < $1.start }

        if let savedId = loadCurrentUserId(),
           savedId != legacyMeUserId,
           let found = allUsers.first(where: { $0.id == savedId }) {
            me = found
        } else {
            me = allUsers.first ?? me
            saveCurrentUserId(me.id)
        }

        saveDemoUsersIfDemoActive()
        saveDemoWorkoutsIfDemoActive()

        // Preload likes for demo
        Task { await preloadLikes(for: workouts.map { $0.id }) }
    }

    func resetDemoData() {
        UserDefaults.standard.removeObject(forKey: demoUsersKey)
        UserDefaults.standard.removeObject(forKey: demoWorkoutsKey)
        allUsers.removeAll()
        workouts.removeAll()
        likeCountByWorkout.removeAll()
        didILikeByWorkout.removeAll()
        seedLocalDemoIfNeeded()
    }

    private func saveDemoUsersIfDemoActive() {
        guard !allUsers.isEmpty else { return }
        saveDemoUsers(allUsers)
    }

    private func saveDemoWorkoutsIfDemoActive() {
        guard !workouts.isEmpty else { return }
        saveDemoWorkouts(workouts)
    }

    private func saveDemoUsers(_ users: [UserProfile]) {
        do {
            let data = try JSONEncoder().encode(users)
            UserDefaults.standard.set(data, forKey: demoUsersKey)
        } catch {
            print("Failed to save demo users: \(error)")
        }
    }

    private func loadDemoUsers() -> [UserProfile]? {
        guard let data = UserDefaults.standard.data(forKey: demoUsersKey) else { return nil }
        do {
            return try JSONDecoder().decode([UserProfile].self, from: data)
        } catch {
            print("Failed to load demo users: \(error)")
            return nil
        }
    }

    private func saveDemoWorkouts(_ entries: [WorkoutEntry]) {
        do {
            let data = try JSONEncoder().encode(entries)
            UserDefaults.standard.set(data, forKey: demoWorkoutsKey)
        } catch {
            print("Failed to save demo workouts: \(error)")
        }
    }

    private func loadDemoWorkouts() -> [WorkoutEntry]? {
        guard let data = UserDefaults.standard.data(forKey: demoWorkoutsKey) else { return nil }
        do {
            return try JSONDecoder().decode([WorkoutEntry].self, from: data)
        } catch {
            print("Failed to load demo workouts: \(error)")
            return nil
        }
    }

    private func generateDemoUsers() -> [UserProfile] {
        return [
            .init(id: "richard", displayName: "Richard",   initials: "R",   colorHex: "#FF7F50"),
            .init(id: "marcus",  displayName: "Marcus",    initials: "M",   colorHex: "#1E90FF"),
            .init(id: "katie",   displayName: "Katie",     initials: "K",   colorHex: "#DA70D6"),
            .init(id: "richard2",displayName: "Richard II",initials: "RII", colorHex: "#32CD32")
        ]
    }

    private func generateDemoWorkouts(for users: [UserProfile]) -> [WorkoutEntry] {
        var result: [WorkoutEntry] = []
        let cal = Calendar.current
        let today = Date()
        let weeks = 8 // last 8 weeks including current

        func makeDate(weekStart: Date, dayOffset: Int, hour: Int, minute: Int) -> Date {
            var comps = DateComponents()
            comps.day = dayOffset; comps.hour = hour; comps.minute = minute
            return cal.date(byAdding: comps, to: weekStart) ?? weekStart.addingTimeInterval(Double(dayOffset) * 24*3600)
        }

        for (uIndex, user) in users.enumerated() {
            for w in 0..<weeks {
                let base = cal.date(byAdding: .day, value: -7 * w, to: today) ?? today
                let weekStart = mondayOfWeek(for: base)

                // Simple progression with some variation per user
                let recMi = max(2.0, 2.0 + Double(uIndex) * 0.2 + Double(weeks - w) * 0.05)
                let tmpMi = max(3.0, 3.1 + Double(uIndex) * 0.2 + Double(weeks - w) * 0.07)
                let lngMi = max(5.0, 6.0 + Double(uIndex) * 0.5 + Double(weeks - w) * 0.6)

                // Paces (min/mile)
                let recPace = 9.5
                let tmpPace = 8.0
                let lngPace = 10.0

                // Tue: Recovery
                let recStart = makeDate(weekStart: weekStart, dayOffset: 1, hour: 7, minute: 0)
                let recDur = recMi * recPace * 60.0
                result.append(WorkoutEntry(
                    id: "demo_\(user.id)_\(Int(recStart.timeIntervalSince1970))_rec",
                    userId: user.id,
                    start: recStart,
                    end: recStart.addingTimeInterval(recDur),
                    distanceMeters: milesToMeters(recMi),
                    durationSec: recDur,
                    avgHR: nil,
                    source: (w % 2 == 0 ? "apple" : "strava"),
                    runType: .recovery,
                    isManual: false,
                    notes: nil
                ))

                // Thu: Tempo
                let tmpStart = makeDate(weekStart: weekStart, dayOffset: 3, hour: 7, minute: 0)
                let tmpDur = tmpMi * tmpPace * 60.0
                result.append(WorkoutEntry(
                    id: "demo_\(user.id)_\(Int(tmpStart.timeIntervalSince1970))_tmp",
                    userId: user.id,
                    start: tmpStart,
                    end: tmpStart.addingTimeInterval(tmpDur),
                    distanceMeters: milesToMeters(tmpMi),
                    durationSec: tmpDur,
                    avgHR: nil,
                    source: (w % 3 == 0 ? "strava" : "apple"),
                    runType: .tempo,
                    isManual: false,
                    notes: nil
                ))

                // Sat: Long
                let lngStart = makeDate(weekStart: weekStart, dayOffset: 5, hour: 8, minute: 0)
                let lngDur = lngMi * lngPace * 60.0
                result.append(WorkoutEntry(
                    id: "demo_\(user.id)_\(Int(lngStart.timeIntervalSince1970))_lng",
                    userId: user.id,
                    start: lngStart,
                    end: lngStart.addingTimeInterval(lngDur),
                    distanceMeters: milesToMeters(lngMi),
                    durationSec: lngDur,
                    avgHR: nil,
                    source: (w % 4 == 0 ? "manual" : "apple"),
                    runType: .long,
                    isManual: (w % 4 == 0),
                    notes: nil
                ))
            }
        }
        return result
    }

    // Keep any legacy UI that reads planOverrides showing the seed master plan.
    private func syncLegacyPlanAlias() {
        planOverrides = masterPlan
    }

    // MARK: - Zones backfill for current user

    private func updateWorkoutZonesLocallyAndPush(_ id: String, zones z: ZoneBreakdown, restingHR rhr: Int?) {
        guard let idx = workouts.firstIndex(where: { $0.id == id }) else { return }
        guard workouts[idx].userId == me.id else { return }
        recordLocalWorkoutEdit(id)
        workouts[idx].zones = z
        workouts[idx].restingHR = rhr
        zonesByWorkout[id] = z
        updateVisibleFeedFromWorkouts()
        saveDemoWorkoutsIfDemoActive() // keep demo in sync too
        let w = workouts[idx]
        guard isTeamSyncEnabled, w.isShared else { return }
        Task.detached {
            do {
                try await CloudKitManager.shared.upsertWorkout(w)
                await self.finishCloudWorkoutWrite(w)
            } catch {
                print("Cloud push workout (zones) failed for \(w.id): \(error)")
            }
        }
    }

    // Compute and upload zones for my runs missing zones
    private func backfillZonesForCurrentUserIfNeeded() async {
        guard hasActiveProfile else { return }
        // Only for current user; requires HealthKit
        try? await HealthKitManager.shared.requestAuthorization()
        let uid = me.id
        let myRuns = workouts.filter { $0.userId == uid }
        guard !myRuns.isEmpty else { return }

        // Estimate resting HR once
        let rhr = await HealthKitManager.shared.estimateRestingHR()

        for w in myRuns {
            // Skip if we already have cached or embedded zones
            if zonesByWorkout[w.id] != nil { continue }
            if w.zones != nil { continue }

            if let z = try? await HealthKitManager.shared.zoneBreakdown(forRun: w.start, end: w.end) {
                await MainActor.run {
                    self.updateWorkoutZonesLocallyAndPush(w.id, zones: z, restingHR: rhr)
                }
            }
        }
    }

    // MARK: - Initial Health sync after login

    private struct HealthSyncContext {
        var ownerRecordName: String?
        var ownerKey: String
        var userId: String
        var allWorkouts: [WorkoutEntry]
        var ownedUserIds: Set<String>
        var knownUserIds: Set<String>
        var ownerByUserId: [String: String]
    }

    private var healthBackfillStartDate: Date {
        teamSharedHistoryStartDate()
    }

    private func healthBackfillStateKey(for context: HealthSyncContext) -> String {
        "\(healthBackfillStateKeyPrefix)_\(context.ownerKey)_\(context.userId)"
    }

    private func hasCompletedHealthBackfill(for context: HealthSyncContext) -> Bool {
        UserDefaults.standard.bool(forKey: healthBackfillStateKey(for: context))
    }

    private func markCompletedHealthBackfill(for context: HealthSyncContext) {
        UserDefaults.standard.set(true, forKey: healthBackfillStateKey(for: context))
    }

    private func healthPostingLookbackAppliedKey(for context: HealthSyncContext) -> String {
        "\(healthPostingLookbackAppliedKeyPrefix)_\(context.ownerKey)_\(context.userId)"
    }

    private func lastAppliedHealthPostingLookbackDays(for context: HealthSyncContext) -> Int? {
        let key = healthPostingLookbackAppliedKey(for: context)
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        return UserDefaults.standard.integer(forKey: key)
    }

    private func markAppliedHealthPostingLookbackDays(_ days: Int, for context: HealthSyncContext) {
        UserDefaults.standard.set(max(0, days), forKey: healthPostingLookbackAppliedKey(for: context))
    }

    private func ownedUserIds(for currentUser: UserProfile, allUsers: [UserProfile]) -> Set<String> {
        var ids: Set<String> = []
        if !currentUser.id.isEmpty {
            ids.insert(currentUser.id)
        }
        if let owner = currentUser.ownerUserRecordName, !owner.isEmpty {
            for u in allUsers where u.ownerUserRecordName == owner {
                ids.insert(u.id)
            }
        }
        return ids
    }

    private func makeHealthSyncContext() -> HealthSyncContext {
        let currentUser = me
        let owner = currentUser.ownerUserRecordName
        let ownerKey = (owner?.isEmpty == false ? owner! : currentUser.id)
        let ownerIds = ownedUserIds(for: currentUser, allUsers: allUsers)
        let known = Set(allUsers.map(\.id))
        var ownerMap: [String: String] = [:]
        for u in allUsers {
            if let owner = u.ownerUserRecordName, !owner.isEmpty {
                ownerMap[u.id] = owner
            }
        }
        return HealthSyncContext(ownerRecordName: owner,
                                 ownerKey: ownerKey,
                                 userId: currentUser.id,
                                 allWorkouts: workouts,
                                 ownedUserIds: ownerIds,
                                 knownUserIds: known,
                                 ownerByUserId: ownerMap)
    }

    private func incrementalHealthSyncStartDate(for context: HealthSyncContext) -> Date {
        let mine = context.allWorkouts.filter { context.ownedUserIds.contains($0.userId) }
        guard let latest = mine.map(\.start).max() else { return healthBackfillStartDate }
        let candidate = latest.addingTimeInterval(-36 * 3600)
        return max(healthBackfillStartDate, candidate)
    }

    // After a user signs in/creates a profile, backfill runs from Oct 2025 onward,
    // then all following syncs can be incremental.
    func syncMyHealthRunsAfterLogin() async {
        let context = await MainActor.run { self.makeHealthSyncContext() }
        guard !context.userId.isEmpty, context.userId != legacyMeUserId else { return }
        let lookbackDays = await MainActor.run { self.teamFeedPostingLookbackDays }
        await syncMyHealthRuns(from: configuredHealthPostingStartDate(lookbackDays: lookbackDays),
                               contextHint: context,
                               markBackfillComplete: true,
                               appliedLookbackDays: lookbackDays,
                               logPrefix: "Initial Health sync after login")
    }

    // Quick sync path:
    // - first run performs one-time backfill from Oct 2025
    // - subsequent runs fetch from latest-known workout minus a short overlap window
    func syncMyRecentHealthRuns() async {
        let context = await MainActor.run { self.makeHealthSyncContext() }
        guard !context.userId.isEmpty, context.userId != legacyMeUserId else { return }
        let shouldBackfill = !hasCompletedHealthBackfill(for: context)
        let lookbackDays = await MainActor.run { self.teamFeedPostingLookbackDays }
        let lookbackStart = configuredHealthPostingStartDate(lookbackDays: lookbackDays)
        let needsLookbackRescan: Bool = {
            guard !shouldBackfill else { return true }
            guard let lastApplied = lastAppliedHealthPostingLookbackDays(for: context) else { return true }
            if lookbackDays == 0 { return lastApplied != 0 }
            if lastApplied == 0 { return false }
            return lookbackDays > lastApplied
        }()
        let start: Date
        if shouldBackfill || needsLookbackRescan {
            start = lookbackStart
        } else {
            start = incrementalHealthSyncStartDate(for: context)
        }

        await syncMyHealthRuns(from: start,
                               contextHint: context,
                               markBackfillComplete: shouldBackfill,
                               appliedLookbackDays: lookbackDays,
                               logPrefix: "Recent Health sync")
    }

    /// Refresh only the selected week. A successful HealthKit query does not
    /// prove read access or completeness; the review UI separately asks the
    /// user to verify the visible workout list before enabling AI commentary.
    @MainActor
    func prepareWeeklyReviewData(for week: Date) async {
        guard hasActiveProfile, !isPreparingWeeklyReviewData else { return }
        let weekStart = mondayOfWeek(for: week)
        guard weekStart <= Date() else { return }
        let context = makeHealthSyncContext()
        let revision = identityRevision
        isPreparingWeeklyReviewData = true
        weeklyReviewImport = nil
        defer { isPreparingWeeklyReviewData = false }
        let end = Calendar.current.date(byAdding: .day, value: 7, to: weekStart) ?? Date()
        let succeeded = await syncMyHealthRuns(from: weekStart,
                                               through: end,
                                               contextHint: context,
                                               markBackfillComplete: false,
                                               appliedLookbackDays: nil,
                                               logPrefix: "Weekly review Health refresh")
        guard me.id == context.userId, identityRevision == revision, !Task.isCancelled else { return }
        weeklyReviewImport = WeeklyReviewImportRecord(userID: context.userId,
                                                     weekStart: weekStart,
                                                     completedAt: succeeded ? Date() : nil,
                                                     succeeded: succeeded)
    }

    @MainActor
    func makeWeeklyReviewRequest(for week: Date, userConfirmedData: Bool) throws -> WeeklyReviewRequestV1 {
        let weekStart = mondayOfWeek(for: week)
        let now = Date()
        let record = weeklyReviewImport.flatMap {
            $0.userID == me.id && $0.weekStart == weekStart ? $0 : nil
        }
        var syncState = record?.syncState(userID: me.id, weekStart: weekStart,
                                         userConfirmedData: userConfirmedData, now: now) ?? .unknown
        let breakInfo = weekBreaks[weekStart]
        // Legacy break storage is device-wide, not attributed to a profile.
        // Do not transmit possibly another account's category/note presence.
        // If context exists but its ownership is unknown, avoid AI commentary.
        if (breakInfo?.reason ?? .none) != .none || !(breakInfo?.notes ?? "").isEmpty {
            syncState = .unknown
        }
        return try WeeklyReviewRequestBuilder.build(WeeklyReviewBuildInput(
            userID: me.id, reviewedWeek: weekStart, workouts: workouts,
            plan: weeklyPlan(for: weekStart).suggested,
            requiredRuns: requiredRunsForMasterPlan(weekStart: weekStart),
            healthKitSyncState: syncState, lastSuccessfulImportAt: record?.completedAt,
            // The store has weekly VO2 buckets, not actual sample dates. Do not
            // invent an observation date or include a later sample in an old review.
            latestVO2Max: nil, latestVO2MaxObservedOn: nil,
            breakReason: .none, hasBreakNote: false,
            generatedAt: now
        ))
    }

    @discardableResult
    private func syncMyHealthRuns(from requestedStart: Date,
                                  through requestedEnd: Date? = nil,
                                  contextHint: HealthSyncContext? = nil,
                                  markBackfillComplete: Bool,
                                  appliedLookbackDays: Int?,
                                  logPrefix: String) async -> Bool {
        let gate = healthSyncGate
        guard await gate.tryBegin() else {
            print("\(logPrefix) skipped: sync already in flight.")
            return false
        }
        defer { Task { await gate.end() } }

        do {
            try await HealthKitManager.shared.requestAuthorization()

            let now = Date()
            let start = min(requestedStart, now)
            let end = min(requestedEnd ?? now, now)
            guard start < end, !Task.isCancelled else { return false }
            let interval = DateInterval(start: start, end: end)

            let runs = try await HealthKitManager.shared.fetchRuns(in: interval,
                                                                   minDurationMinutes: 8.0,
                                                                   maxPaceMinutesPerMile: 15.0)

            // Avoid await on the right-hand side of ??
            let context: HealthSyncContext
            if let hint = contextHint {
                context = hint
            } else {
                context = await MainActor.run { self.makeHealthSyncContext() }
            }
            guard !context.userId.isEmpty, !Task.isCancelled else { return false }

            let mine = context.allWorkouts.filter { context.ownedUserIds.contains($0.userId) }
            var existingHK: Set<String> = []
            var existingStrava: Set<String> = []
            addExistingIdentifiers(from: mine, existingHK: &existingHK, existingStrava: &existingStrava)

            var entries: [WorkoutEntry] = []
            entries.reserveCapacity(runs.count)
            var seenEntryIds: Set<String> = []

            let rhr = await HealthKitManager.shared.estimateRestingHR()
            for r in runs {
                try Task.checkCancellation()
                let src = sourceKey(name: r.sourceName, bundle: r.sourceBundleIdentifier)
                let hkLower = r.workoutUUID?.uuidString.lowercased()
                let stravaLower = (src == "strava" ? r.externalId : nil)?.lowercased()

                // Skip if already present under any known owned identifier.
                if let h = hkLower, existingHK.contains(h) { continue }
                if let s = stravaLower, existingStrava.contains(s) { continue }

                let avgHR: Double?
                if let wkUUID = r.workoutUUID {
                    avgHR = try? await HealthKitManager.shared.averageHR(forWorkoutUUID: wkUUID,
                                                                         start: r.startDate,
                                                                         end: r.endDate)
                } else {
                    avgHR = try? await HealthKitManager.shared.averageHR(in: DateInterval(start: r.startDate, end: r.endDate))
                }

                let zones = try? await HealthKitManager.shared.zoneBreakdown(forRun: r.startDate, end: r.endDate)
                let distanceMeters = milesToMeters(r.distanceMiles)
                // Prefer existing record ids when timestamps match:
                // this re-attributes legacy/orphan rows to the current profile id.
                let wid = matchedExistingWorkoutId(for: r,
                                                   source: src,
                                                   distanceMeters: distanceMeters,
                                                   context: context)
                          ?? canonicalWorkoutId(ownerKey: context.ownerKey,
                                                src: src,
                                                start: r.startDate,
                                                end: r.endDate,
                                                hkUUID: r.workoutUUID,
                                                stravaId: (src == "strava" ? r.externalId : nil))

                if seenEntryIds.contains(wid) { continue }

                entries.append(
                    WorkoutEntry(
                        id: wid,
                        userId: context.userId,
                        start: r.startDate,
                        end: r.endDate,
                        distanceMeters: distanceMeters,
                        durationSec: r.duration,
                        avgHR: avgHR,
                        source: src,
                        runType: .other,
                        isManual: false,
                        notes: nil,
                        healthKitUUID: r.workoutUUID,
                        stravaActivityId: (src == "strava" ? r.externalId : nil),
                        zones: zones,
                        restingHR: rhr,
                        sharedRoutePoints: nil
                    )
                )

                seenEntryIds.insert(wid)
                if let h = hkLower { existingHK.insert(h) }
                if let s = stravaLower { existingStrava.insert(s) }
            }

            guard !Task.isCancelled,
                  await MainActor.run(body: { self.me.id == context.userId }) else { return false }
            if !entries.isEmpty {
                await MainActor.run {
                    guard self.me.id == context.userId else { return }
                    self.workouts.removeAll { $0.userId == self.me.id && $0.id.hasPrefix("demo_") }
                    self.upsert(entries: entries)
                }
            }

            // Also cleanup any already-duplicated owned runs from prior races/older ids.
            await MainActor.run {
                guard self.me.id == context.userId else { return }
                self.deduplicateOwnedWorkouts(using: context)
            }

            if let appliedLookbackDays {
                markAppliedHealthPostingLookbackDays(appliedLookbackDays, for: context)
            }

            if markBackfillComplete {
                markCompletedHealthBackfill(for: context)
            }
            return true
        } catch {
            print("\(logPrefix) failed: \(error)")
            return false
        }
    }

    @MainActor
    private func deduplicateOwnedWorkouts(using context: HealthSyncContext) {
        guard !workouts.isEmpty else { return }

        let startToleranceSec = 2.5
        let endToleranceSec = 2.5
        let distanceToleranceMeters = 120.0

        func hasHealthIdentity(_ w: WorkoutEntry) -> Bool {
            if w.healthKitUUID != nil { return true }
            return healthKitUUIDFromWorkoutId(w.id) != nil
        }
        func hasStravaIdentity(_ w: WorkoutEntry) -> Bool {
            if let id = w.stravaActivityId, !id.isEmpty { return true }
            return stravaIdFromWorkoutId(w.id) != nil
        }
        func better(_ lhs: WorkoutEntry, than rhs: WorkoutEntry) -> Bool {
            if hasHealthIdentity(lhs) != hasHealthIdentity(rhs) {
                return hasHealthIdentity(lhs)
            }
            if hasStravaIdentity(lhs) != hasStravaIdentity(rhs) {
                return hasStravaIdentity(lhs)
            }
            if (lhs.zones != nil) != (rhs.zones != nil) {
                return lhs.zones != nil
            }
            if (lhs.avgHR != nil) != (rhs.avgHR != nil) {
                return lhs.avgHR != nil
            }
            // Deterministic tie-breaker to keep behavior stable across runs.
            return lhs.id < rhs.id
        }

        var keep: [WorkoutEntry] = []
        keep.reserveCapacity(workouts.count)
        var removedIds = Set<String>()

        for w in workouts.sorted(by: { $0.start < $1.start }) {
            guard context.ownedUserIds.contains(w.userId) else {
                keep.append(w)
                continue
            }

            if let idx = keep.firstIndex(where: { existing in
                context.ownedUserIds.contains(existing.userId) &&
                normalizedSource(existing.source) == normalizedSource(w.source) &&
                abs(existing.start.timeIntervalSince(w.start)) <= startToleranceSec &&
                abs(existing.end.timeIntervalSince(w.end)) <= endToleranceSec &&
                abs(existing.distanceMeters - w.distanceMeters) <= distanceToleranceMeters
            }) {
                let existing = keep[idx]
                if better(w, than: existing) {
                    removedIds.insert(existing.id)
                    keep[idx] = w
                } else {
                    removedIds.insert(w.id)
                }
            } else {
                keep.append(w)
            }
        }

        guard !removedIds.isEmpty else { return }

        workouts = keep.sorted(by: { $0.start < $1.start })
        for id in removedIds {
            zonesByWorkout.removeValue(forKey: id)
            runTypeOverrides.removeValue(forKey: id)
            likeCountByWorkout.removeValue(forKey: id)
            didILikeByWorkout.removeValue(forKey: id)
        }
        saveRunTypeOverrides()
        saveDemoWorkoutsIfDemoActive()
    }

    private func addExistingIdentifiers(from runs: [WorkoutEntry],
                                        existingHK: inout Set<String>,
                                        existingStrava: inout Set<String>) {
        for w in runs {
            if let h = w.healthKitUUID?.uuidString.lowercased() {
                existingHK.insert(h)
            }
            if let parsedHK = healthKitUUIDFromWorkoutId(w.id) {
                existingHK.insert(parsedHK)
            }
            if let s = w.stravaActivityId?.lowercased() {
                existingStrava.insert(s)
            }
            if let parsedStrava = stravaIdFromWorkoutId(w.id) {
                existingStrava.insert(parsedStrava)
            }
        }
    }

    private func healthKitUUIDFromWorkoutId(_ id: String) -> String? {
        guard let marker = id.range(of: "_hk_") else { return nil }
        let raw = String(id[marker.upperBound...])
        guard let uuid = UUID(uuidString: raw) else { return nil }
        return uuid.uuidString.lowercased()
    }

    private func stravaIdFromWorkoutId(_ id: String) -> String? {
        guard let marker = id.range(of: "_strava_") else { return nil }
        let raw = String(id[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw.lowercased()
    }

    private func attributionPriority(for workout: WorkoutEntry, context: HealthSyncContext) -> Int? {
        if context.ownedUserIds.contains(workout.userId) {
            return 0
        }
        if let owner = context.ownerRecordName, context.ownerByUserId[workout.userId] == owner {
            return 1
        }
        if !context.knownUserIds.contains(workout.userId) {
            // Orphan userId (profile missing): allow adopting when a Health run matches exactly.
            return 2
        }
        // Never claim a known teammate's run.
        return nil
    }

    private func matchedExistingWorkoutId(for run: RunSummary,
                                          source src: String,
                                          distanceMeters: Double,
                                          context: HealthSyncContext) -> String? {
        // Prefer exact legacy id match first (old schema used src+timestamps).
        let legacyId = stableId(start: run.startDate, end: run.endDate, src: src)
        if let exactLegacy = context.allWorkouts.first(where: { $0.id == legacyId }),
           attributionPriority(for: exactLegacy, context: context) != nil {
            return exactLegacy.id
        }

        let startToleranceSec = 2.5
        let endToleranceSec = 2.5
        let distanceToleranceMeters = 120.0

        var bestId: String?
        var bestPriority = Int.max
        var bestDistanceDelta = Double.greatestFiniteMagnitude

        for w in context.allWorkouts {
            guard abs(w.start.timeIntervalSince(run.startDate)) <= startToleranceSec else { continue }
            guard abs(w.end.timeIntervalSince(run.endDate)) <= endToleranceSec else { continue }
            guard normalizedSource(w.source) == src else { continue }
            let distanceDelta = abs(w.distanceMeters - distanceMeters)
            guard distanceDelta <= distanceToleranceMeters else { continue }
            guard let priority = attributionPriority(for: w, context: context) else { continue }

            if priority < bestPriority || (priority == bestPriority && distanceDelta < bestDistanceDelta) {
                bestId = w.id
                bestPriority = priority
                bestDistanceDelta = distanceDelta
            }
        }

        return bestId
    }

    private func sourceKey(name: String, bundle: String) -> String {
        let n = name.lowercased()
        let b = bundle.lowercased()
        if b.contains("com.strava") || n.contains("strava") { return "strava" }
        return "apple"
    }

    private func normalizedSource(_ source: String) -> String {
        let s = source.lowercased()
        if s.contains("strava") { return "strava" }
        return "apple"
    }

    // Fix B: Canonical globally-unique workout ID builder
    // Prefer ownerUserRecordName + HealthKit UUID, else owner + Strava id, else owner + time-based fallback.
    private func canonicalWorkoutId(ownerKey: String,
                                    src: String,
                                    start: Date,
                                    end: Date,
                                    hkUUID: UUID?,
                                    stravaId: String?) -> String {
        if let u = hkUUID {
            return "\(ownerKey)_hk_\(u.uuidString.lowercased())"
        }
        if let sid = stravaId, !sid.isEmpty {
            return "\(ownerKey)_strava_\(sanitizeIdComponent(sid))"
        }
        let s = Int(start.timeIntervalSince1970)
        let e = Int(end.timeIntervalSince1970)
        return "\(ownerKey)_\(src)_\(s)_\(e)"
    }

    private func sanitizeIdComponent(_ s: String) -> String {
        // Keep it simple: replace spaces and slashes to stay record-name friendly
        return s.replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "-")
    }

    // Legacy fallback (unused after Fix B; kept for clarity)
    private func stableId(start: Date, end: Date, src: String) -> String {
        let s = Int(start.timeIntervalSince1970)
        let e = Int(end.timeIntervalSince1970)
        return "\(src)_\(s)_\(e)"
    }

    // MARK: - Notifications (Likes/Comments/Feed)

    // Fetch prefs, register with APNs, and rebuild CK subscriptions so likes notify the owner.
    private func applyNotificationPrefsForCurrentUser() async {
        // Snapshot on main to avoid races
        let currentUser = await MainActor.run { self.me }
        let userId = currentUser.id
        guard !userId.isEmpty, userId != legacyMeUserId else { return }

        // Ensure a UserProfile exists and is claimed by this iCloud account so runs/prefs link to it.
        // Guard against uploading an empty placeholder.
        let isPlaceholder = currentUser.id.isEmpty || currentUser.displayName.isEmpty
        if !isPlaceholder {
            try? await CloudKitManager.shared.upsertUser(currentUser)
        }

        // Always register; iOS will coalesce duplicate requests.
        PushSubscriptionManager.shared.registerForRemoteNotifications()

        // Pull prefs from CloudKit (or defaults if CK disabled), then rebuild subs.
        let prefs = await Self.fetchNotificationPrefsWithTimeout(userId: userId, seconds: 6)
        let stillCurrent = await MainActor.run { () -> Bool in
            guard self.me.id == userId else { return false }
            // Preference is stored per profile in CloudKit so a second device
            // inherits an explicit opt-in. The legacy local flag mirrors it;
            // requiring both would silently turn sync off on a new device.
            self.isTeamSyncEnabled = prefs.shareByDefault
            self.setAutoUploadRunsToCloudEnabled(prefs.shareByDefault)
            return true
        }
        guard stillCurrent else { return }
        PushSubscriptionManager.shared.rebuildAllSubscriptions(for: userId, prefs: prefs)
    }

    // MARK: - Helpers (Likes)

    // Parse "like_<workoutId>_<fromUserId>" -> workoutId
    private func workoutIdFromLikeRecordName(_ recordName: String) -> String? {
        guard recordName.hasPrefix("like_") else { return nil }
        let remainder = String(recordName.dropFirst("like_".count))
        guard let lastUnderscore = remainder.lastIndex(of: "_") else { return nil }
        let workoutId = String(remainder[..<lastUnderscore])
        return workoutId.isEmpty ? nil : workoutId
    }

    // MARK: - Ownership flags

    // Refresh ownership flags map so UI can show "Yours", "Claimed", "Unclaimed"
    func refreshOwnershipFlags() async {
        let users = self.allUsers
        let flags = await CloudKitManager.shared.ownershipFlags(for: users)
        await MainActor.run {
            self.ownershipFlagsByUser = flags
        }
    }
}
