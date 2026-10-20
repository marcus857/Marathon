//
//  HomeView.swift
//  Marathon
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: WorkoutStore
    @State private var isRefreshing = false
    @State private var lastError: String?
    @State private var showFunFactHistory = false
    @AppStorage("appColorScheme") private var appColorScheme: String = "dark"
    @AppStorage("teamFeedIncludeMineDebug") private var teamFeedIncludeMineDebug: Bool = true

    // Track scroll to toggle toolbar background
    @State private var isScrolled = false

    // Auto-refresh guard
    @State private var didAutoRefresh = false

    private let funFactStore = FunFactStore()

    private var weekStart: Date { mondayOfWeek(for: Date()) }
    private var funFact: FunFact { funFactStore.dailyFact() }

    // Next upcoming dated important item; if none, most recent past dated item
    private var nextUpcomingImportantDate: ImportantDate? {
        let now = Date()
        return store.importantDates
            .filter { $0.date != nil }
            .sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
            .first(where: { ($0.date ?? .distantFuture) >= now })
    }
    private var mostRecentPastImportantDate: ImportantDate? {
        let now = Date()
        return store.importantDates
            .filter { ($0.date ?? .distantPast) < now }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            .first
    }

    // Cloud-backed feed preview (source: shared DB). For testing, can include my latest shared run.
    private var teamFeedItems: [WorkoutEntry] {
        let sorted = store.cloudTeamFeed.sorted(by: { $0.start > $1.start })
        var items: [WorkoutEntry] = []
        items.reserveCapacity(6)

        if teamFeedIncludeMineDebug,
           let mine = sorted.first(where: { $0.userId == store.me.id }) {
            items.append(mine)
        }

        let others = sorted.filter { $0.userId != store.me.id }

        var seen = Set<String>()
        for w in others {
            if !seen.contains(w.userId) {
                items.append(w)
                seen.insert(w.userId)
                if items.count >= 6 { break }
            }
        }
        return Array(items.prefix(6))
    }

    var body: some View {
        let summary = store.weekSummary(for: Date())

        ScrollView {
            VStack(spacing: 16) {
                HeroHeader(
                    title: "Athens Tracker",
                    subtitle: "Week of \(weekStart.formatted(date: .abbreviated, time: .omitted))",
                    imageName: "Lycabettus", // swapped: use Lycabettus on Home
                    vo2Max: summary.latestVO2Max
                )

                // Fun Fact card
                funFactCard

                // Weekly summary
                weeklySummarySection

                // Team Feed (like others' runs)
                teamFeedCard

                // Next Long Run preview
                nextLongRunCard

                // Actions (contains Important Dates preview)
                actionsSection

                if let err = lastError {
                    Text(err)
                        .foregroundStyle(AthensTheme.terracotta)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }

                Spacer(minLength: 12)
            }
            .padding()
            // Probe lives in background so it never takes layout space
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: NavBarOffsetKey.self, value: proxy.frame(in: .named("homeScroll")).minY)
                }
            )
        }
        .coordinateSpace(name: "homeScroll")
        .onPreferenceChange(NavBarOffsetKey.self) { y in
            // When content scrolls up, minY becomes negative — consider scrolled if below a small threshold
            withAnimation(.easeInOut(duration: 0.2)) {
                isScrolled = y < -2
            }
        }
        .refreshable { await refreshFromHealth() }
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline) // compact, icon-height nav bar with title visible
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ThemeToggleButton()
            }

            // Raw Log icon (to the left of Refresh)
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    RawLogView()
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
                .tint(AthensTheme.goldAccent)
                .accessibilityLabel("Raw Log")
            }

            // Refresh icon (rightmost)
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refreshFromHealth() }
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .tint(AthensTheme.goldAccent)
                .accessibilityLabel("Refresh Health")
                .disabled(isRefreshing)
            }
        }
        .sheet(isPresented: $showFunFactHistory) {
            FunFactHistoryView(history: funFactStore.historySinceNov1())
        }
        #if os(iOS)
        // Keep scroll behavior: transparent at top so the gradient shows through,
        // switch to our dynamic Athens blue when scrolled.
        .toolbarBackground(isScrolled ? AthensTheme.midnightBlue : .clear, for: .navigationBar)
        .toolbarBackgroundVisibility(isScrolled ? .visible : .hidden, for: .navigationBar)
        .toolbarColorScheme(appColorScheme == "light" ? .light : .dark, for: .navigationBar)
        #endif
        .background(AthensTheme.backgroundGradient.ignoresSafeArea())
        // Auto-refresh Health data once when Home first appears
        .task(id: store.me.id) {
            guard !didAutoRefresh else { return }
            guard store.hasActiveProfile else { return }
            didAutoRefresh = true
            await refreshFromHealth()

        }
    }

    // MARK: - Sections broken out to help the type-checker

    private var funFactCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(AthensTheme.goldAccent)
                Text("Fun Fact")
                    .font(.headline)
                    .foregroundColor(AthensTheme.marbleWhite)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            Text(funFact.text)
                .font(AthensTheme.BodyFont)
                .foregroundColor(AthensTheme.marbleWhite)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AthensTheme.cardGradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 6)
        .contentShape(Rectangle())
        .onTapGesture { showFunFactHistory = true }
    }

    private var weeklySummarySection: some View {
        let summary = store.weekSummary(for: Date())
        let bonusRuns = max(0, summary.actualRuns - summary.requiredRuns)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("This Week")
                    .font(.title2.weight(.bold))
                    .foregroundColor(AthensTheme.marbleWhite)
                Spacer()
                NavigationLink(destination: PlanPreviewView()) {
                    Label("Plan", systemImage: "calendar.badge.clock")
                        .font(.subheadline.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                }
                .tint(AthensTheme.goldAccent)
            }

            HStack(spacing: 8) {
                Label("\(summary.actualRuns)/\(summary.requiredRuns) runs", systemImage: "figure.run")
                    .foregroundStyle(AthensTheme.marbleWhite)
                if bonusRuns > 0 {
                    Text("Bonus +\(bonusRuns)")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(AthensTheme.marbleWhite)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(AthensTheme.goldAccent.opacity(0.25)))
                }
                Spacer()
                Text(String(format: "%.1f / %.1f mi", summary.actualMiles, summary.requiredWeeklyMiles))
                    .font(.headline)
                    .foregroundColor(AthensTheme.marbleWhite)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AthensTheme.cardGradient)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 6)

            if summary.breakReason != .none || (summary.breakNotes?.isEmpty == false) {
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle")
                        .foregroundStyle(AthensTheme.goldAccent)
                    Text("Break: \(summary.breakReason.rawValue.capitalized)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(AthensTheme.marbleWhite)
                    if let n = summary.breakNotes, !n.isEmpty {
                        Text("• \(n)")
                            .font(.footnote)
                            .foregroundColor(AthensTheme.marbleWhite.opacity(0.85))
                    }
                    Spacer()
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12).fill(AthensTheme.cardGradient)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Team Feed card with like button
    private var teamFeedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Team Feed", systemImage: "person.3.sequence")
                    .foregroundStyle(AthensTheme.goldAccent)
                Spacer()
                HStack(spacing: 10) {
                    if !teamFeedItems.isEmpty {
                        Text("Latest")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(AthensTheme.marbleWhite.opacity(0.8))
                    }
                    NavigationLink {
                        TeamFeedView()
                    } label: {
                        HStack(spacing: 4) {
                            Text("Open Feed")
                            Image(systemName: "chevron.right")
                        }
                        .font(.footnote.weight(.semibold))
                    }
                    .tint(AthensTheme.goldAccent)
                    .accessibilityLabel("Open Team Feed")

                    Button {
                        Task { await store.refreshFromCloud() }
                    } label: {
                        if store.isTeamFeedLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.plain)
                    .tint(AthensTheme.goldAccent)
                    .accessibilityLabel("Refresh Team Feed")
                    .disabled(store.isTeamFeedLoading)
                }
            }

            if store.isTeamFeedLoading && teamFeedItems.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Syncing team feed...")
                        .foregroundStyle(AthensTheme.marbleWhite.opacity(0.9))
                    Spacer()
                }
                .font(.subheadline)
                .padding(.vertical, 4)
            } else if teamFeedItems.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "tray")
                            .foregroundStyle(AthensTheme.goldAccent)
                        Text("No recent team runs yet")
                            .foregroundStyle(AthensTheme.marbleWhite.opacity(0.9))
                        Spacer()
                    }
                    NavigationLink {
                        TeamFeedView()
                    } label: {
                        Label("Post A Local Run To Cloud", systemImage: "icloud.and.arrow.up")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AthensTheme.goldAccent)
                    .accessibilityLabel("Open Team Feed and post a local run")
                }
                .font(.subheadline)
                .padding(.vertical, 4)
            } else {
                VStack(spacing: 10) {
                    ForEach(teamFeedItems) { w in
                        let user = store.allUsers.first(where: { $0.id == w.userId })
                        if let user {
                            TeamFeedRow(workout: w, user: user, meId: store.me.id)
                                .id(w.id)
                        } else {
                            TeamFeedFallbackRow(
                                workout: w,
                                state: store.allUsers.isEmpty ? .resolvingProfile : .missingProfile
                            )
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AthensTheme.cardGradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 6)
    }

    // Preview card for the next soonest important date, links to full list
    private var importantDatesPreviewCard: some View {
        NavigationLink {
            ImportantDatesView()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.clock")
                        .foregroundStyle(AthensTheme.goldAccent)
                    Text("Next Important Date")
                        .font(.headline)
                        .foregroundColor(AthensTheme.marbleWhite)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }

                if let item = nextUpcomingImportantDate ?? mostRecentPastImportantDate {
                    Text(item.title.isEmpty ? "Untitled" : item.title)
                        .font(.title3.weight(.semibold))
                        .foregroundColor(AthensTheme.marbleWhite)

                    if let d = item.date {
                        HStack(spacing: 8) {
                            Text(d.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(AthensTheme.marbleWhite.opacity(0.9))
                            if d >= Date() {
                                Text("•")
                                    .foregroundColor(AthensTheme.marbleWhite.opacity(0.6))
                                Text(relativeString(to: d))
                                    .foregroundStyle(AthensTheme.marbleWhite.opacity(0.85))
                            }
                            Spacer()
                        }
                        .font(.subheadline)
                    }

                    if let n = item.notes, !n.isEmpty {
                        Text(n)
                            .font(.footnote)
                            .foregroundColor(AthensTheme.marbleWhite.opacity(0.85))
                            .lineLimit(2)
                    }
                } else {
                    Text("No dated items yet")
                        .font(.subheadline)
                        .foregroundColor(AthensTheme.marbleWhite.opacity(0.9))
                    Text("Tap to add or edit your list.")
                        .font(.footnote)
                        .foregroundColor(AthensTheme.marbleWhite.opacity(0.7))
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AthensTheme.cardGradient)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 6)
        }
        .buttonStyle(.plain)
    }

    private var actionsSection: some View {
        VStack(spacing: 12) {
            // Keep the Important Dates preview card here (single occurrence).
            importantDatesPreviewCard
        }
    }

    // MARK: - Next Long Run (now based on master plan via store.weeklyPlan)

    private var nextLongRunCard: some View {
        let nextWeek = mondayOfWeek(for: Date().addingTimeInterval(7 * 24 * 3600))
        let plan = store.weeklyPlan(for: nextWeek)          // master plan preferred
        let split = plan.suggested                           // recovery/tempo/long from master plan

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Next Long Run", systemImage: "figure.run.circle")
                    .foregroundStyle(AthensTheme.goldAccent)
                Spacer()
                Text(nextWeek.formatted(date: .abbreviated, time: .omitted))
                    .foregroundColor(AthensTheme.marbleWhite.opacity(0.9))
            }
            HStack {
                Text(String(format: "%.1f miles", split.long))
                    .font(.title3.weight(.semibold))
                    .foregroundColor(AthensTheme.marbleWhite)
                Spacer()
                Text(String(format: "wk total %.1f", plan.requiredWeeklyMiles))
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(AthensTheme.marbleWhite.opacity(0.85))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16).fill(AthensTheme.cardGradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 6)
    }

    // MARK: - Health

    private func heroImageFallback() -> String? {
        let options = ["athens_hero_1", "athens_hero_2", "athens_hero_3"]
        let week = Calendar.current.component(.weekOfYear, from: Date())
        return options[(week - 1) % options.count]
    }

    private func refreshFromHealth() async {
        guard !isRefreshing else { return }
        guard store.hasActiveProfile else {
            await MainActor.run {
                lastError = "Create a profile before importing Health workouts."
            }
            return
        }
        let refreshedUserID = store.me.id
        await MainActor.run { isRefreshing = true; lastError = nil }
        // Cloud refresh must still finish if Health access fails or is unavailable.
        async let cloudRefresh: Void = store.refreshFromCloud()
        do {
            try await HealthKitManager.shared.requestAuthorization()
            try Task.checkCancellation()
            guard store.me.id == refreshedUserID else { throw CancellationError() }

            // VO2max lookback: from Monday of the later of plan start or one year ago
            let now = Date()
            let cal = Calendar.current
            let oneYearAgo = cal.date(byAdding: .year, value: -1, to: now) ?? now
            let base = max(store.settings.startDate, oneYearAgo)
            let since = mondayOfWeek(for: base)

            async let vo2Task = HealthKitManager.shared.fetchVO2MaxByWeek(since: since)
            // Store handles one-time backfill from Oct 2025 + incremental new-run sync.
            await store.syncMyRecentHealthRuns()

            let vo2ByWeek = try await vo2Task
            await MainActor.run {
                guard store.me.id == refreshedUserID, !Task.isCancelled else { return }
                store.upsertVO2(byWeek: vo2ByWeek)
            }
        } catch {
            await MainActor.run {
                guard store.me.id == refreshedUserID, !(error is CancellationError) else { return }
                lastError = error.localizedDescription
            }
        }
        await cloudRefresh
        await MainActor.run { isRefreshing = false }
    }

    private func relativeString(to date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    // Local helper to map brand color hex
    private func colorFromHex(_ hex: String) -> Color {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return AthensTheme.goldAccent }
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >> 8) & 0xFF) / 255.0
        let b = Double(v & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}

// Team feed row with avatar, details, and like button
struct TeamFeedRow: View {
    @EnvironmentObject var store: WorkoutStore
    let workout: WorkoutEntry
    let user: UserProfile
    let meId: String

    private var likeCount: Int {
        max(0, store.likeCountByWorkout[workout.id] ?? 0)
    }

    private var didLike: Bool {
        store.didILikeByWorkout[workout.id] ?? false
    }

    private var loading: Bool {
        store.likeToggleInFlight.contains(workout.id)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack {
                Circle()
                    .fill(colorFromHex(user.colorHex))
                    .frame(width: 32, height: 32)
                Text(user.initials)
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.white)
            }
            .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))

            // Details
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(user.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(AthensTheme.marbleWhite)
                    Spacer()
                    Text(workout.start.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(AthensTheme.marbleWhite.opacity(0.7))
                }

                HStack(spacing: 8) {
                    Text(String(format: "%.1f mi", workout.miles))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(AthensTheme.marbleWhite.opacity(0.95))
                    Text("•").foregroundStyle(.secondary)
                    Text(workout.durationSec.asHMS)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(AthensTheme.marbleWhite.opacity(0.85))
                    if let pace = workout.paceSecPerMile {
                        Text("•").foregroundStyle(.secondary)
                        Text((pace / 60.0).asPaceMinPerMile)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(AthensTheme.marbleWhite.opacity(0.8))
                    }
                }
            }

            Spacer(minLength: 8)

            // Like button
            Button {
                Task { await store.toggleLike(for: workout) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: didLike ? "heart.fill" : "heart")
                        .foregroundStyle(didLike ? AthensTheme.terracotta : AthensTheme.marbleWhite)
                    Text("\(likeCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AthensTheme.marbleWhite.opacity(0.9))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(Color.white.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .disabled(loading || meId.isEmpty)
        }
        .task(id: meId) {
            guard !workout.id.isEmpty else { return }
            if store.likeCountByWorkout[workout.id] == nil || store.didILikeByWorkout[workout.id] == nil {
                await store.refreshLikes(for: workout.id)
            }
        }
    }

    private func colorFromHex(_ hex: String) -> Color {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return AthensTheme.goldAccent }
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >> 8) & 0xFF) / 255.0
        let b = Double(v & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}

enum TeamFeedFallbackState {
    case resolvingProfile
    case missingProfile

    var title: String {
        switch self {
        case .resolvingProfile:
            return "Loading athlete..."
        case .missingProfile:
            return "Athlete unavailable"
        }
    }

    var caption: String {
        switch self {
        case .resolvingProfile:
            return "Syncing profiles"
        case .missingProfile:
            return "Profile missing from team directory"
        }
    }

    var iconName: String {
        switch self {
        case .resolvingProfile:
            return "ellipsis"
        case .missingProfile:
            return "questionmark"
        }
    }

    var titleColor: Color {
        switch self {
        case .resolvingProfile:
            return AthensTheme.marbleWhite.opacity(0.92)
        case .missingProfile:
            return AthensTheme.goldAccent
        }
    }
}

struct TeamFeedFallbackRow: View {
    let workout: WorkoutEntry
    let state: TeamFeedFallbackState

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.gray.opacity(0.6))
                    .frame(width: 32, height: 32)
                Image(systemName: state.iconName)
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.white)
            }
            .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(state.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(state.titleColor)
                    if case .resolvingProfile = state {
                        ProgressView()
                            .controlSize(.small)
                            .tint(AthensTheme.marbleWhite.opacity(0.75))
                    }
                }
                HStack(spacing: 8) {
                    Text(String(format: "%.1f mi", workout.miles))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(AthensTheme.marbleWhite.opacity(0.95))
                    Text("•").foregroundStyle(.secondary)
                    Text(workout.durationSec.asHMS)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(AthensTheme.marbleWhite.opacity(0.85))
                }
                Text(state.caption)
                    .font(.caption2)
                    .foregroundStyle(AthensTheme.marbleWhite.opacity(0.65))
            }

            Spacer(minLength: 8)

            Text(workout.start.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(AthensTheme.marbleWhite.opacity(0.7))
        }
    }
}

// PreferenceKey to track scroll offset
private struct NavBarOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
