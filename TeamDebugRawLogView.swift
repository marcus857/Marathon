#if DEBUG
import SwiftUI

struct TeamDebugRawLogView: View {
    @EnvironmentObject var store: WorkoutStore
    @AppStorage("appColorScheme") private var appColorScheme: String = "dark"

    @State private var isScrolled = false
    @State private var rawText: String = ""
    @State private var isPreparingLocalSnapshot: Bool = false
    @State private var isRefreshingCloudDebugInfo: Bool = false
    @State private var hasLoadedCloudRunIds: Bool = false
    @State private var allRunsNewestFirst: [WorkoutEntry] = []
    @State private var myRunsNewestFirst: [WorkoutEntry] = []

    // Post progress + result
    @State private var isPosting: Bool = false
    @State private var postedDone: Int = 0
    @State private var postedTotal: Int = 0
    @State private var postingStartedAt: Date?
    @State private var busyRunId: String? = nil
    @State private var isBulkDeleting: Bool = false
    @State private var autoPostEnabled: Bool = false
    @State private var cloudAccount: String = "Unknown"
    @State private var cloudTeamId: String = "default"
    @State private var myCloudRunIds: Set<String> = []
    @State private var resultMessage: String?
    @State private var showResult: Bool = false

    // 14‑day quick counts to sanity‑check visibility
    private var cutoff: Date {
        Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date().addingTimeInterval(-14*24*3600)
    }
    private var othersRecentCount: Int {
        store.workouts.filter { $0.userId != store.me.id && $0.start >= cutoff }.count
    }
    private var myRecentCount: Int {
        store.workouts.filter { $0.userId == store.me.id && $0.start >= cutoff }.count
    }

    private var postingRateRunsPerMinute: Double? {
        guard isPosting, let start = postingStartedAt else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed >= 3, postedDone > 0 else { return nil }
        let runsPerSecond = Double(postedDone) / elapsed
        guard runsPerSecond.isFinite, runsPerSecond > 0 else { return nil }
        return runsPerSecond * 60
    }

    private var postingETA: String? {
        guard isPosting,
              let start = postingStartedAt,
              postedTotal > 0,
              postedDone > 0,
              postedDone < postedTotal else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed >= 3 else { return nil }
        let runsPerSecond = Double(postedDone) / elapsed
        guard runsPerSecond.isFinite, runsPerSecond > 0 else { return nil }
        let remaining = Double(postedTotal - postedDone) / runsPerSecond
        guard remaining.isFinite, remaining > 0 else { return nil }
        return formatETA(remaining)
    }

    var body: some View {
        ScrollView {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: TeamDebugOffsetKey.self, value: proxy.frame(in: .named("teamDebugScroll")).minY)
            }
            .frame(height: 0)

            VStack(spacing: 14) {
                summaryCard
                myRunsCard
                jsonCard
            }
            .padding()
        }
        .coordinateSpace(name: "teamDebugScroll")
        .onPreferenceChange(TeamDebugOffsetKey.self) { y in
            withAnimation(.easeInOut(duration: 0.2)) { isScrolled = y < -2 }
        }
        .navigationTitle("Raw Log")
        .navigationBarTitleDisplayMode(.inline)
        #if os(iOS)
        .toolbarBackground(isScrolled ? AthensTheme.midnightBlue : .clear, for: .navigationBar)
        .toolbarBackgroundVisibility(isScrolled ? .visible : .hidden, for: .navigationBar)
        .toolbarColorScheme(appColorScheme == "light" ? .light : .dark, for: .navigationBar)
        #endif
        .background(AthensTheme.backgroundGradient.ignoresSafeArea())
        .onAppear {
            autoPostEnabled = store.isAutoUploadRunsToCloudEnabled()
            seedCloudDebugInfoFromCache()
            refreshLocalSnapshot()
            Task { await refreshCloudDebugInfo(limit: 80, refreshFeedIfEmpty: store.cloudTeamFeed.isEmpty) }
        }
        .onReceive(store.$workouts) { _ in
            refreshLocalSnapshot()
            seedCloudDebugInfoFromCache()
        }
        .onReceive(store.$cloudTeamFeed) { _ in
            seedCloudDebugInfoFromCache()
        }
        .alert("Result", isPresented: $showResult, actions: {
            Button("OK", role: .cancel) { }
        }, message: {
            Text(resultMessage ?? "")
        })
    }

    // MARK: - Cards

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .foregroundStyle(AthensTheme.goldAccent)
                Text("Debug Summary")
                    .font(.headline)
                    .foregroundColor(AthensTheme.marbleWhite)
                Spacer()
            }

            HStack {
                Text("Others (last 14d)")
                Spacer()
                Text("\(othersRecentCount)").monospacedDigit()
            }
            .foregroundColor(AthensTheme.marbleWhite)

            HStack {
                Text("Mine (last 14d)")
                Spacer()
                Text("\(myRecentCount)").monospacedDigit()
            }
            .foregroundColor(AthensTheme.marbleWhite)

            HStack {
                Text("Cloud shared feed rows")
                Spacer()
                Text("\(store.cloudTeamFeed.count)").monospacedDigit()
            }
            .foregroundColor(AthensTheme.marbleWhite)

            HStack {
                Text("Cloud account")
                Spacer()
                if isRefreshingCloudDebugInfo {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AthensTheme.goldAccent)
                } else {
                    Text(cloudAccount).monospacedDigit()
                }
            }
            .foregroundColor(AthensTheme.marbleWhite)

            HStack {
                Text("Team ID")
                Spacer()
                if isRefreshingCloudDebugInfo {
                    Text("Loading...")
                        .monospacedDigit()
                } else {
                    Text(cloudTeamId).monospacedDigit()
                }
            }
            .foregroundColor(AthensTheme.marbleWhite)

            HStack {
                Text("Auto-post local to cloud")
                Spacer()
                Text(autoPostEnabled ? "ON" : "OFF").monospacedDigit()
            }
            .foregroundColor(AthensTheme.marbleWhite)

            HStack {
                Text("Team history window")
                Spacer()
                Text(store.teamFeedPostingLookbackLabel()).monospacedDigit()
            }
            .foregroundColor(AthensTheme.marbleWhite)

            Rectangle().fill(AthensTheme.goldAccent.opacity(0.35)).frame(height: 1)

            HStack(spacing: 10) {
                Button {
                    Task {
                        await refreshCloudDebugInfo(limit: 80)
                        await store.refreshFromCloud()
                        await store.refreshTeamFeedFromCloud()
                        refreshLocalSnapshot()
                    }
                } label: {
                    Label("Refresh Cloud", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .tint(AthensTheme.goldAccent)

                Button {
                    Task { await postAllMissingRuns() }
                } label: {
                    if isPosting {
                        Label("Posting...", systemImage: "arrow.up.circle")
                    } else {
                        Label("Post All Missing", systemImage: "icloud.and.arrow.up")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AthensTheme.goldAccent)
                .disabled(isPosting)

                Button {
                    autoPostEnabled.toggle()
                    store.setAutoUploadRunsToCloudEnabled(autoPostEnabled)
                    resultMessage = autoPostEnabled
                        ? "Auto-post enabled. New local upserts will upload automatically."
                        : "Auto-post disabled. Use 'Post This Run' to upload manually."
                    showResult = true
                } label: {
                    Text(autoPostEnabled ? "Disable Auto" : "Enable Auto")
                }
                .buttonStyle(.bordered)
                .tint(AthensTheme.goldAccent)
            }

            if isPosting {
                let total = max(1, postedTotal)
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(postedDone), total: Double(total))
                        .progressViewStyle(.linear)
                        .tint(AthensTheme.goldAccent)
                    Text("\(postedDone) / \(postedTotal) posted")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(AthensTheme.marbleWhite.opacity(0.85))
                    if let eta = postingETA {
                        Text("ETA \(eta)")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(AthensTheme.marbleWhite.opacity(0.8))
                    }
                    if let rate = postingRateRunsPerMinute {
                        Text(String(format: "%.1f runs/min", rate))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(AthensTheme.marbleWhite.opacity(0.75))
                    }
                }
            }

            Button {
                Task { await deleteAllMyCloudRuns() }
            } label: {
                if isBulkDeleting {
                    HStack(spacing: 6) {
                        ProgressView()
                        Text("Deleting My Cloud Runs")
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Label("Delete All My Cloud Runs", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .tint(AthensTheme.terracotta)
            .disabled(isBulkDeleting || isPosting || busyRunId != nil)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    private var myRunsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "figure.run")
                    .foregroundStyle(AthensTheme.goldAccent)
                Text("My Local Runs")
                    .font(.headline)
                    .foregroundColor(AthensTheme.marbleWhite)
                Spacer()
                Text("\(myRunsNewestFirst.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(AthensTheme.marbleWhite.opacity(0.9))
            }

            Text(store.teamFeedPostingLookbackLabel())
                .font(.footnote)
                .foregroundStyle(AthensTheme.marbleWhite.opacity(0.75))

            if isPreparingLocalSnapshot && myRunsNewestFirst.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(AthensTheme.goldAccent)
                    Text("Preparing local run list...")
                        .font(.footnote)
                        .foregroundStyle(AthensTheme.marbleWhite.opacity(0.85))
                }
            } else if myRunsNewestFirst.isEmpty {
                Text("No local runs found for your profile.")
                    .font(.footnote)
                    .foregroundStyle(AthensTheme.marbleWhite.opacity(0.85))
            } else {
                ForEach(Array(myRunsNewestFirst.prefix(20))) { w in
                    let inCloud = isRunInCloud(w)
                    let cloudPresencePending = !hasLoadedCloudRunIds && isRefreshingCloudDebugInfo && myCloudRunIds.isEmpty
                    VStack(spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(w.start.formatted(date: .abbreviated, time: .shortened))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AthensTheme.marbleWhite)
                            Spacer()
                            Text(String(format: "%.1f mi", w.miles))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(AthensTheme.marbleWhite.opacity(0.9))
                            Text("•")
                                .foregroundStyle(.secondary)
                            Text(w.durationSec.asHMS)
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(AthensTheme.marbleWhite.opacity(0.85))
                        }

                        HStack(spacing: 8) {
                            Button {
                                Task { await postOneRun(w) }
                            } label: {
                                if busyRunId == w.id {
                                    ProgressView()
                                } else if cloudPresencePending {
                                    HStack(spacing: 6) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("Checking...")
                                    }
                                } else {
                                    Text(inCloud ? "In Cloud" : "Post This Run")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(AthensTheme.goldAccent)
                            .disabled(cloudPresencePending || inCloud || (busyRunId != nil && busyRunId != w.id) || isPosting || isBulkDeleting)

                            Button {
                                Task { await deleteOneRunFromCloud(w) }
                            } label: {
                                if cloudPresencePending {
                                    Text("Checking...")
                                } else {
                                    Text("Delete From Cloud")
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(AthensTheme.terracotta)
                            .disabled(cloudPresencePending || !inCloud || (busyRunId != nil && busyRunId != w.id) || isPosting || isBulkDeleting)

                            Spacer(minLength: 0)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    private var jsonCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(AthensTheme.goldAccent)
                Text("All Runs (Newest First)")
                    .font(.headline)
                    .foregroundColor(AthensTheme.marbleWhite)
                Spacer()
                Text("\(allRunsNewestFirst.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(AthensTheme.marbleWhite.opacity(0.9))
            }
            Text(store.teamFeedPostingLookbackLabel())
                .font(.footnote)
                .foregroundStyle(AthensTheme.marbleWhite.opacity(0.75))
            if isPreparingLocalSnapshot && rawText.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(AthensTheme.goldAccent)
                    Text("Preparing raw log...")
                        .font(.footnote)
                        .foregroundStyle(AthensTheme.marbleWhite.opacity(0.85))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if isPreparingLocalSnapshot {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(AthensTheme.goldAccent)
                            Text("Updating raw log...")
                                .font(.caption)
                                .foregroundStyle(AthensTheme.marbleWhite.opacity(0.75))
                        }
                    }
                    Text(rawText.isEmpty ? "No data" : rawText)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(AthensTheme.marbleWhite)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    // MARK: - Helpers

    private func refreshLocalSnapshot() {
        let workouts = store.workouts
        let meId = store.me.id
        let cutoff = store.teamSharedHistoryStartDate()
        let historyLabel = store.teamFeedPostingLookbackLabel()
        isPreparingLocalSnapshot = true

        Task.detached(priority: .utility) {
            let filtered = workouts
                .filter { $0.start >= cutoff }
                .sorted { $0.start > $1.start }
            let mine = filtered.filter { $0.userId == meId }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601

            let renderedText: String
            do {
                let maxRows = 220
                let rows = Array(filtered.prefix(maxRows))
                let data = try encoder.encode(rows)
                let json = String(data: data, encoding: .utf8) ?? ""
                let dropped = max(0, filtered.count - rows.count)
                let header = "Team/shared history window: \(historyLabel)"
                if dropped > 0 {
                    renderedText = "\(header)\nShowing newest \(rows.count) runs (\(dropped) older runs hidden)\n\n" + json
                } else {
                    renderedText = "\(header)\n\n" + json
                }
            } catch {
                renderedText = "Encoding error: \(error.localizedDescription)"
            }

            await MainActor.run {
                self.allRunsNewestFirst = filtered
                self.myRunsNewestFirst = mine
                self.rawText = renderedText
                self.isPreparingLocalSnapshot = false
            }
        }
    }

    private func seedCloudDebugInfoFromCache() {
        let uid = store.me.id
        guard !uid.isEmpty else { return }
        let cachedIds = Set(store.cloudTeamFeed.lazy.filter { $0.userId == uid }.map(\.id))
        if !cachedIds.isEmpty || !hasLoadedCloudRunIds {
            myCloudRunIds = cachedIds
        }
    }

    private func refreshCloudDebugInfo(limit: Int?, refreshFeedIfEmpty: Bool = false) async {
        let uid = store.me.id
        guard !uid.isEmpty else { return }

        await MainActor.run {
            isRefreshingCloudDebugInfo = true
        }

        if refreshFeedIfEmpty && store.cloudTeamFeed.isEmpty {
            await store.refreshTeamFeedFromCloud(limit: limit, force: true)
            await MainActor.run {
                seedCloudDebugInfoFromCache()
            }
        }

        async let accountTask = CloudKitManager.shared.currentUserRecordName()
        async let prefsTask: NotificationPrefs = {
            (try? await CloudKitManager.shared.fetchNotificationPrefs(userId: uid))
                ?? NotificationPrefs.defaults(for: uid)
        }()
        async let mineTask = store.fetchTeamFeedRunsForUser(userId: uid, limit: limit)

        let account = await accountTask ?? "Not available"
        let prefs = await prefsTask
        let mine = await mineTask
        let mineIds = Set(mine.map(\.id))

        await MainActor.run {
            cloudAccount = account
            cloudTeamId = prefs.teamId
            myCloudRunIds = mineIds
            hasLoadedCloudRunIds = true
            isRefreshingCloudDebugInfo = false
        }
    }

    private func isRunInCloud(_ w: WorkoutEntry) -> Bool {
        myCloudRunIds.contains(w.id)
    }

    private func postAllMissingRuns() async {
        guard !isPosting else { return }
        let cutoff = store.teamSharedHistoryStartDate()
        let cloudRunsForMe = await store.fetchTeamFeedRunsForUser(userId: store.me.id, limit: nil)
        let cloudIds = Set(cloudRunsForMe.map { $0.id })
        let myRuns = store.workouts
            .filter { $0.userId == store.me.id }
            .filter { $0.start >= cutoff }
            .filter { !cloudIds.contains($0.id) }
        await MainActor.run {
            isPosting = true
            postedDone = 0
            postedTotal = myRuns.count
            postingStartedAt = Date()
            resultMessage = nil
        }

        if myRuns.isEmpty {
            await MainActor.run {
                isPosting = false
                postingStartedAt = nil
                resultMessage = "No local runs to post for \(store.teamFeedPostingLookbackLabel())."
                showResult = true
            }
            return
        }

        var success = 0
        var failures = 0
        var firstError: String?
        let uid = store.me.id
        let prefs = (try? await CloudKitManager.shared.fetchNotificationPrefs(userId: uid))
            ?? NotificationPrefs.defaults(for: uid)
        let teamId = prefs.teamId

        // Post in small concurrent batches; per-run timeout so it never hangs
        let batchSize = 5
        for startIdx in stride(from: 0, to: myRuns.count, by: batchSize) {
            let endIdx = min(startIdx + batchSize, myRuns.count)
            let batch = Array(myRuns[startIdx..<endIdx])

            await withTaskGroup(of: Void.self) { group in
                for w in batch {
                    group.addTask {
                        do {
                            var copy = w
                            copy.isShared = true
                            copy.teamId = teamId
                            try await upsertWithTimeout(copy, seconds: 20)
                            await MainActor.run { success += 1 }
                        } catch {
                            await MainActor.run {
                                failures += 1
                                if firstError == nil { firstError = error.localizedDescription }
                            }
                        }
                        await MainActor.run { postedDone += 1 }
                    }
                }
                await group.waitForAll()
            }
        }

        let msg: String
        if failures == 0 {
            msg = "Posted \(success) runs successfully (\(store.teamFeedPostingLookbackLabel()))."
        } else {
            msg = "Posted \(success)/\(myRuns.count) runs. First error: \(firstError ?? "Unknown error")."
        }

        await MainActor.run {
            isPosting = false
            postingStartedAt = nil
            resultMessage = msg
            showResult = true
        }
        await refreshCloudDebugInfo(limit: 80)
        await store.refreshTeamFeedFromCloud(force: true)
        refreshLocalSnapshot()
    }

    private func formatETA(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%dh %02dm", h, m)
        }
        if m > 0 {
            return String(format: "%dm %02ds", m, s)
        }
        return String(format: "%ds", s)
    }

    private func postOneRun(_ w: WorkoutEntry) async {
        await MainActor.run {
            busyRunId = w.id
            resultMessage = nil
        }

        do {
            let uid = store.me.id
            let prefs = (try? await CloudKitManager.shared.fetchNotificationPrefs(userId: uid))
                ?? NotificationPrefs.defaults(for: uid)
            var copy = w
            copy.isShared = true
            copy.teamId = prefs.teamId

            try await upsertWithTimeout(copy, seconds: 20)
            await store.refreshTeamFeedFromCloud(force: true)
            let visible = await MainActor.run { store.cloudTeamFeed.contains(where: { $0.id == copy.id }) }

            await MainActor.run {
                refreshLocalSnapshot()
                if visible {
                    resultMessage = "Posted run \(w.id) and verified it appears in Cloud team feed."
                } else {
                    resultMessage = "Post completed for \(w.id), but it is not visible in team feed query yet. Check Team ID/schema."
                }
                showResult = true
                busyRunId = nil
            }
            await refreshCloudDebugInfo(limit: 80)
        } catch {
            await MainActor.run {
                resultMessage = "Post failed for \(w.id): \(error.localizedDescription)"
                showResult = true
                busyRunId = nil
            }
        }
    }

    private func deleteOneRunFromCloud(_ w: WorkoutEntry) async {
        await MainActor.run {
            busyRunId = w.id
            resultMessage = nil
        }

        do {
            try await CloudKitManager.shared.deleteWorkout(id: w.id)
            await store.refreshTeamFeedFromCloud(force: true)

            await MainActor.run {
                refreshLocalSnapshot()
                resultMessage = "Deleted run \(w.id) from Cloud."
                showResult = true
                busyRunId = nil
            }
            await refreshCloudDebugInfo(limit: 80)
        } catch {
            await MainActor.run {
                resultMessage = "Delete failed for \(w.id): \(error.localizedDescription)"
                showResult = true
                busyRunId = nil
            }
        }
    }

    private func deleteAllMyCloudRuns() async {
        guard !isBulkDeleting else { return }
        let myCloudRuns = await store.fetchTeamFeedRunsForUser(userId: store.me.id, limit: nil)
        guard !myCloudRuns.isEmpty else {
            await MainActor.run {
                resultMessage = "No cloud runs found for your user."
                showResult = true
            }
            return
        }

        await MainActor.run {
            isBulkDeleting = true
            resultMessage = nil
        }

        // Prevent immediate re-post during startup/health sync after this reset.
        if autoPostEnabled {
            await MainActor.run {
                autoPostEnabled = false
                store.setAutoUploadRunsToCloudEnabled(false)
            }
        }

        var deleted = 0
        var failed = 0
        var firstError: String?
        for run in myCloudRuns {
            do {
                try await deleteWithTimeout(id: run.id, seconds: 20)
                deleted += 1
            } catch {
                failed += 1
                if firstError == nil { firstError = error.localizedDescription }
            }
        }

        await store.refreshTeamFeedFromCloud()
        await store.refreshFromCloud()
        await refreshCloudDebugInfo(limit: 80)

        await MainActor.run {
            isBulkDeleting = false
            refreshLocalSnapshot()
            if failed == 0 {
                resultMessage = "Deleted \(deleted) cloud runs for your user."
            } else {
                resultMessage = "Deleted \(deleted)/\(myCloudRuns.count). First error: \(firstError ?? "Unknown error")."
            }
            showResult = true
        }
    }

    private func upsertWithTimeout(_ w: WorkoutEntry, seconds: Double) async throws {
        enum TimeoutError: LocalizedError {
            case timedOut
            var errorDescription: String? { "Timed out while posting." }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await CloudKitManager.shared.upsertWorkout(w)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError.timedOut
            }
            let _ = try await group.next()
            group.cancelAll()
        }
    }

    private func deleteWithTimeout(id: String, seconds: Double) async throws {
        enum TimeoutError: LocalizedError {
            case timedOut
            var errorDescription: String? { "Timed out while deleting." }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await CloudKitManager.shared.deleteWorkout(id: id)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError.timedOut
            }
            let _ = try await group.next()
            group.cancelAll()
        }
    }
}

private struct TeamDebugOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
#endif
