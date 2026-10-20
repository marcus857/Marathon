// LeaderboardView.swift
import SwiftUI

struct LeaderboardView: View {
    @EnvironmentObject var store: WorkoutStore
    @AppStorage("appColorScheme") private var appColorScheme: String = "dark"
    @State private var scope: Scope = .thisWeek
    @State private var isScrolled = false
    @State private var sortMode: SortMode = .miles
    // NEW: present onboarding to create/sign in with your own profile
    @State private var showOnboarding = false

    enum Scope: String, CaseIterable, Identifiable {
        case thisWeek = "This Week"
        case thisMonth = "This Month"
        case season = "Season"
        case allTime = "All Time"
        var id: String { rawValue }
    }

    enum SortMode: String, CaseIterable, Identifiable {
        case miles, runs, pace, completion, consistency
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .miles: return "Miles"
            case .runs: return "Runs"
            case .pace: return "Pace"
            case .completion: return "Completion"
            case .consistency: return "Consistency"
            }
        }
    }

    private struct Row: Identifiable {
        let id: String // userId
        let user: UserProfile
        let miles: Double
        let runs: Int
        let totalSeconds: Double

        // Average HR across runs in range (if any)
        let avgHR: Double?

        // Weekly rollups across the selected range (kept for sorting)
        let weeklyMiles: [Double]
        let weeklyCompletionRatios: [Double] // 0...1 per week
        let bonusMiles: Double

        var avgPaceSecPerMile: Double? {
            miles > 0 ? (totalSeconds / miles) : nil
        }
        var completionPct: Double {
            guard !weeklyCompletionRatios.isEmpty else { return 0 }
            return weeklyCompletionRatios.reduce(0, +) / Double(weeklyCompletionRatios.count)
        }
        var consistencyStdDev: Double {
            let xs = weeklyMiles
            guard xs.count > 1 else { return .infinity }
            let mean = xs.reduce(0, +) / Double(xs.count)
            let variance = xs.reduce(0) { $0 + pow($1 - mean, 2) } / Double(xs.count)
            return sqrt(variance)
        }
    }

    private var selectedInterval: DateInterval? {
        dateRange(for: scope)
    }

    private var rows: [Row] {
        // Precompute once
        let interval = selectedInterval

        // Build rows per user
        var built: [Row] = []
        for u in store.allUsers {
            let runsForUser = store.workouts.filter { w in
                guard w.userId == u.id else { return false }
                if let s = interval?.start, w.start < s { return false }
                if let e = interval?.end, w.start >= e { return false }
                return true
            }

            let miles = runsForUser.reduce(0.0) { $0 + metersToMiles($1.distanceMeters) }
            let runsCount = runsForUser.count
            let totalSec = runsForUser.reduce(0.0) { $0 + $1.durationSec }

            // Avg HR across available runs
            let hrs: [Double] = runsForUser.compactMap { $0.avgHR }
            let avgHR = hrs.isEmpty ? nil : (hrs.reduce(0, +) / Double(hrs.count))

            // Weekly rollups
            let weekly = weeklyBreakdown(for: u.id, runs: runsForUser, within: interval)
            let row = Row(
                id: u.id,
                user: u,
                miles: miles,
                runs: runsCount,
                totalSeconds: totalSec,
                avgHR: avgHR,
                weeklyMiles: weekly.miles,
                weeklyCompletionRatios: weekly.completions,
                bonusMiles: weekly.bonusMiles
            )
            built.append(row)
        }

        // Sort by chosen mode
        switch sortMode {
        case .miles:
            return built.sorted {
                if $0.miles != $1.miles { return $0.miles > $1.miles }
                if $0.runs != $1.runs { return $0.runs > $1.runs }
                return $0.user.displayName.localizedCaseInsensitiveCompare($1.user.displayName) == .orderedAscending
            }
        case .runs:
            return built.sorted {
                if $0.runs != $1.runs { return $0.runs > $1.runs }
                if $0.miles != $1.miles { return $0.miles > $1.miles }
                return $0.user.displayName.localizedCaseInsensitiveCompare($1.user.displayName) == .orderedAscending
            }
        case .pace:
            // Faster first: lower pace is better. Missing pace -> bottom.
            return built.sorted {
                let a = $0.avgPaceSecPerMile ?? .infinity
                let b = $1.avgPaceSecPerMile ?? .infinity
                if a != b { return a < b }
                if $0.miles != $1.miles { return $0.miles > $1.miles }
                return $0.user.displayName.localizedCaseInsensitiveCompare($1.user.displayName) == .orderedAscending
            }
        case .completion:
            return built.sorted {
                if $0.completionPct != $1.completionPct { return $0.completionPct > $1.completionPct }
                if $0.miles != $1.miles { return $0.miles > $1.miles }
                return $0.user.displayName.localizedCaseInsensitiveCompare($1.user.displayName) == .orderedAscending
            }
        case .consistency:
            // Lower std dev is better (steadier).
            return built.sorted {
                if $0.consistencyStdDev != $1.consistencyStdDev { return $0.consistencyStdDev < $1.consistencyStdDev }
                if $0.miles != $1.miles { return $0.miles > $1.miles }
                return $0.user.displayName.localizedCaseInsensitiveCompare($1.user.displayName) == .orderedAscending
            }
        }
    }

    var body: some View {
        List {
            // If no team exists yet, show a helper section to load the demo team
            if store.allUsers.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No team yet")
                            .font(.headline)
                            .foregroundColor(AthensTheme.marbleWhite)
                        Text("Load the 4‑person demo team to try Leaderboard and Team Week.")
                            .font(.footnote)
                            .foregroundStyle(AthensTheme.marbleWhite.opacity(0.85))
                        Button {
                            store.resetDemoData()
                        } label: {
                            Label("Load Demo Team", systemImage: "arrow.down.circle")
                                .font(.subheadline.weight(.semibold))
                        }
                        .tint(AthensTheme.goldAccent)
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient))
            }

            // Range picker
            Section {
                Picker("Range", selection: $scope) {
                    ForEach(Scope.allCases) { s in Text(s.rawValue).tag(s) }
                }
                .pickerStyle(.segmented)
                .tint(AthensTheme.goldAccent)
            }
            .listRowBackground(RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient))

            // Rows
            Section {
                ForEach(rows) { r in
                    NavigationLink {
                        UserRangeStatsView(
                            user: r.user,
                            interval: selectedInterval,
                            rangeTitle: headerTitle(for: scope)
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 12) {
                                avatar(for: r.user)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.user.displayName)
                                        .font(.headline)
                                        .foregroundColor(AthensTheme.marbleWhite)
                                    // Secondary line: You/initials • Avg HR
                                    HStack(spacing: 6) {
                                        Text(r.user.id == store.me.id ? "You" : r.user.initials)
                                            .font(.caption)
                                            .foregroundStyle(AthensTheme.marbleWhite.opacity(0.7))
                                        Text("•")
                                            .foregroundStyle(AthensTheme.marbleWhite.opacity(0.5))
                                        let avgHRString = r.avgHR.map { String(format: "%.0f", $0) } ?? "—"
                                        Text("Avg HR \(avgHRString)")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(AthensTheme.marbleWhite.opacity(0.8))
                                    }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(String(format: "%.1f mi", r.miles))
                                        .font(.headline.monospacedDigit())
                                        .foregroundColor(AthensTheme.marbleWhite)
                                    HStack(spacing: 6) {
                                        Text("\(r.runs) run\(r.runs == 1 ? "" : "s")")
                                        if let p = r.avgPaceSecPerMile {
                                            Text("•")
                                            Text(paceString(p))
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(AthensTheme.marbleWhite.opacity(0.8))
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient))
                }
            } header: {
                Text("\(headerTitle(for: scope)) • Sort: \(sortMode.displayName)")
            }
        }
        .coordinateSpace(name: "lbScroll")
        // Invisible background probe to track scroll offset without occupying a row
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: LBNavBarOffsetKey.self, value: proxy.frame(in: .named("lbScroll")).minY)
            }
        )
        .onPreferenceChange(LBNavBarOffsetKey.self) { y in
            withAnimation(.easeInOut(duration: 0.2)) { isScrolled = y < -2 }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Leaderboard")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refreshFromCloud() }
        .toolbar {
            // Sort menu
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(SortMode.allCases) { mode in
                        Button {
                            sortMode = mode
                        } label: {
                            Label(mode.displayName, systemImage: mode == sortMode ? "checkmark.circle.fill" : "circle")
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down.circle")
                }
                .tint(AthensTheme.goldAccent)
                .accessibilityLabel("Sort")
            }

            // Team Week page
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    TeamWeekView()
                } label: {
                    Image(systemName: "calendar.badge.clock")
                }
                .tint(AthensTheme.goldAccent)
                .accessibilityLabel("Team Week")
            }
            // Switch user + profile + reset demo
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // NEW: Entry point to create/sign in with your own profile
                    Section("Profile") {
                        Button {
                            showOnboarding = true
                        } label: {
                            Label("Sign in / Create Profile", systemImage: "person.crop.circle.badge.plus")
                        }
                    }

                    #if DEBUG
                    // Multi-profile switching exists only to exercise demo data.
                    // A production build must never let a user act as a public
                    // teammate profile.
                    Section("Switch Demo User") {
                        ForEach(store.allUsers, id: \.id) { u in
                            Button {
                                store.setCurrentUser(u)
                            } label: {
                                Label(u.displayName, systemImage: u.id == store.me.id ? "checkmark.circle.fill" : "person.circle")
                            }
                        }
                    }
                    Section {
                        Button(role: .destructive) {
                            store.resetDemoData()
                        } label: {
                            Label("Reset Demo Data", systemImage: "arrow.counterclockwise")
                        }
                    }
                    #endif
                } label: {
                    Image(systemName: "person.crop.circle.badge")
                }
                .tint(AthensTheme.goldAccent)
                .accessibilityLabel("Team Menu")
            }
        }
        #if os(iOS)
        .toolbarBackground(isScrolled ? AthensTheme.midnightBlue : .clear, for: .navigationBar)
        .toolbarBackgroundVisibility(isScrolled ? .visible : .hidden, for: .navigationBar)
        .toolbarColorScheme(appColorScheme == "light" ? .light : .dark, for: .navigationBar)
        #endif
        .background(AthensTheme.backgroundGradient.ignoresSafeArea())
        // NEW: Present onboarding sheet
        .sheet(isPresented: $showOnboarding) {
            OnboardingView()
                .environmentObject(store)
        }
    }

    // MARK: - Helpers

    private func headerTitle(for scope: Scope) -> String {
        switch scope {
        case .thisWeek:
            let s = mondayOfWeek(for: Date())
            return "Week of \(s.formatted(date: .abbreviated, time: .omitted))"
        case .thisMonth:
            let f = DateFormatter(); f.dateFormat = "LLLL yyyy"
            return f.string(from: Date())
        case .season:
            let (start, _) = seasonBounds()
            return "Since \(start.formatted(date: .abbreviated, time: .omitted))"
        case .allTime:
            return "All Time"
        }
    }

    private func dateRange(for scope: Scope) -> DateInterval? {
        let cal = Calendar.current
        switch scope {
        case .thisWeek:
            let s = mondayOfWeek(for: Date())
            let e = cal.date(byAdding: .day, value: 7, to: s) ?? s.addingTimeInterval(7*24*3600)
            return DateInterval(start: s, end: e)
        case .thisMonth:
            let comps = cal.dateComponents([.year, .month], from: Date())
            let s = cal.date(from: comps) ?? cal.startOfDay(for: Date())
            let e = cal.date(byAdding: .month, value: 1, to: s) ?? s.addingTimeInterval(30*24*3600)
            return DateInterval(start: s, end: e)
        case .season:
            let (s, e) = seasonBounds()
            return DateInterval(start: s, end: e)
        case .allTime:
            return nil
        }
    }

    private func seasonBounds() -> (start: Date, end: Date) {
        let cal = Calendar.current
        let end = cal.startOfDay(for: Date())
        var comps = cal.dateComponents([.year], from: end)
        comps.month = 11; comps.day = 1
        let nov1ThisYear = cal.date(from: comps) ?? end
        let start: Date = (end >= nov1ThisYear) ? nov1ThisYear : cal.date(byAdding: .year, value: -1, to: nov1ThisYear) ?? nov1ThisYear
        return (start: start, end: end.addingTimeInterval(24*3600))
    }

    private func weeklyBreakdown(for userId: String, runs: [WorkoutEntry], within interval: DateInterval?) -> (miles: [Double], completions: [Double], bonusMiles: Double) {
        // Determine week span
        let cal = Calendar.current

        let startBase: Date?
        let endBase: Date?

        if let interval {
            startBase = interval.start
            endBase = interval.end
        } else {
            let mins = runs.map(\.start).min()
            let maxs = runs.map(\.start).max()
            startBase = mins
            endBase = maxs.map { $0.addingTimeInterval(1) } // make end exclusive
        }

        guard let startB = startBase, let endB = endBase else {
            return ([], [], 0)
        }

        let firstWeek = mondayOfWeek(for: startB)
        let lastWeek = mondayOfWeek(for: endB.addingTimeInterval(-1))

        var weekStarts: [Date] = []
        var cur = firstWeek
        while cur <= lastWeek {
            weekStarts.append(cur)
            cur = cal.date(byAdding: .day, value: 7, to: cur) ?? cur.addingTimeInterval(7*24*3600)
        }

        var weeklyMiles: [Double] = []
        var weeklyCompletion: [Double] = []
        var bonus: Double = 0

        for ws in weekStarts {
            let we = cal.date(byAdding: .day, value: 7, to: ws) ?? ws.addingTimeInterval(7*24*3600)
            let inWeek = runs.filter { $0.start >= ws && $0.start < we }
            let miles = inWeek.reduce(0.0) { $0 + metersToMiles($1.distanceMeters) }
            let required = store.weeklyPlan(for: ws).requiredWeeklyMiles
            weeklyMiles.append(miles)
            if required > 0 {
                let ratio = min(1.0, max(0.0, miles / required))
                weeklyCompletion.append(ratio)
                if miles > required { bonus += (miles - required) }
            } else {
                weeklyCompletion.append(0)
            }
        }
        return (weeklyMiles, weeklyCompletion, bonus)
    }

    private func avatar(for user: UserProfile) -> some View {
        ZStack {
            Circle()
                .fill(colorFromHex(user.colorHex))
                .frame(width: 28, height: 28)
            Text(user.initials)
                .font(.caption2.weight(.bold))
                .foregroundColor(.white)
        }
        .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
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

    private func paceString(_ sec: Double) -> String {
        guard sec.isFinite && sec > 0 else { return "—" }
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%d:%02d /mi", m, s)
    }

    private func formatHMS(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 {
            return String(format: "%d:%02d", h, m)
        } else {
            return String(format: "%d min", m)
        }
    }
}

private struct LBNavBarOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// Minimal user range stats view to fix missing type and keep type-checking fast
private struct UserRangeStatsView: View {
    @EnvironmentObject var store: WorkoutStore

    let user: UserProfile
    let interval: DateInterval? // nil = all time
    let rangeTitle: String

    @State private var zone = ZoneBreakdown()
    @State private var isZoneLoading = false
    @State private var zoneError: String?
    @State private var restingHR: Int = 60

    // Toggle to reveal details when donut is tapped
    @State private var showHRDetails = false

    private var displayedUser: UserProfile {
        store.allUsers.first(where: { $0.id == user.id }) ?? user
    }

    private struct ZoneLoadKey: Equatable {
        let userID: String
        let viewerID: String
        let runs: [WorkoutEntry]
    }

    private var zoneLoadKey: ZoneLoadKey {
        ZoneLoadKey(userID: user.id, viewerID: store.me.id, runs: runs)
    }

    private var runs: [WorkoutEntry] {
        let s = interval?.start
        let e = interval?.end
        return store.workouts
            .filter { w in
                guard w.userId == user.id else { return false }
                if let s = s, w.start < s { return false }
                if let e = e, w.start >= e { return false }
                return true
            }
            .sorted { $0.start > $1.start }
    }

    private var totalMiles: Double {
        runs.reduce(0) { $0 + metersToMiles($1.distanceMeters) }
    }
    private var totalSeconds: Double {
        runs.reduce(0) { $0 + $1.durationSec }
    }
    private var avgPaceSecPerMile: Double? {
        totalMiles > 0 ? (totalSeconds / totalMiles) : nil
    }
    private var avgHR: Double? {
        let hrs = runs.compactMap { $0.avgHR }
        guard !hrs.isEmpty else { return nil }
        return hrs.reduce(0, +) / Double(hrs.count)
    }

    // VO2max summary for this user within the selected interval.
    // Data is only tracked for the current user in WorkoutStore.
    private var vo2Summary: (latest: Double?, avg: Double?, min: Double?, max: Double?) {
        guard user.id == store.me.id else { return (nil, nil, nil, nil) }
        let s = interval.map { mondayOfWeek(for: $0.start) }
        let e = interval?.end
        let pairs = store.vo2MaxByWeek
            .filter { kv in
                let wk = kv.key
                if let s = s, wk < s { return false }
                if let e = e, wk >= e { return false }
                return true
            }
            .sorted { $0.key < $1.key }

        guard !pairs.isEmpty else { return (nil, nil, nil, nil) }
        let values = pairs.map { $0.value }
        let latest = pairs.last?.value
        let avg = values.reduce(0, +) / Double(values.count)
        let minV = values.min()
        let maxV = values.max()
        return (latest, avg, minV, maxV)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    avatar(for: displayedUser)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayedUser.displayName)
                            .font(.headline)
                            .foregroundColor(AthensTheme.marbleWhite)
                        Text(rangeTitle)
                            .font(.subheadline)
                            .foregroundStyle(AthensTheme.marbleWhite.opacity(0.85))
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }
            .listRowBackground(RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient))

            Section("Totals") {
                statRow(label: "Miles", value: String(format: "%.1f", totalMiles))
                statRow(label: "Time", value: formatHMS(totalSeconds))
                statRow(label: "Runs", value: "\(runs.count)")
            }
            .listRowBackground(RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient))

            // Heart Rate Zones (donut + legend)
            Section("Heart Rate Zones") {
                if user.id != store.me.id {
                    Text("Only available for your runs on this device.")
                        .font(.footnote)
                        .foregroundStyle(AthensTheme.marbleWhite.opacity(0.8))
                } else if isZoneLoading {
                    HStack {
                        ProgressView()
                        Text("Loading…")
                            .foregroundStyle(AthensTheme.marbleWhite.opacity(0.9))
                    }
                } else if let err = zoneError {
                    Text(err)
                        .font(.footnote)
                        .foregroundColor(.red)
                } else if zone.total <= 0 {
                    Text("No heart rate samples in this range.")
                        .font(.footnote)
                        .foregroundStyle(AthensTheme.marbleWhite.opacity(0.8))
                } else {
                    let pct = zone.percentages
                    let maxHR = HealthKitManager.shared.estimateMaxHR()

                    VStack(alignment: .center, spacing: 10) {
                        Text("HRR-based zones using max \(maxHR) bpm and resting \(restingHR) bpm.")
                            .font(.footnote)
                            .foregroundStyle(AthensTheme.marbleWhite.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .center)

                        // Centered donut; size unchanged; no center overlay
                        ZStack {
                            ZoneDonutLabeled(
                                values: zone.durations.map { $0 },
                                colors: zoneColors(),
                                lineWidth: 22,
                                labels: ["Z1","Z2","Z3","Z4","Z5"]
                            )
                            .frame(height: 220) // keep the same visual size
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.25)) { showHRDetails.toggle() }
                        }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("Heart rate zones donut")
                        .accessibilityHint(showHRDetails ? "Hide details" : "Show details")

                        if !showHRDetails {
                            Text("Tap the ring for details")
                                .font(.footnote)
                                .foregroundStyle(AthensTheme.marbleWhite.opacity(0.7))
                                .frame(maxWidth: .infinity, alignment: .center)
                        }

                        if showHRDetails {
                            VStack(spacing: 6) {
                                ForEach(0..<5, id: \.self) { i in
                                    zoneLegendRow(index: i,
                                                  percent: (i < pct.count ? pct[i] : 0),
                                                  duration: (i < zone.durations.count ? zone.durations[i] : 0))
                                }
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
            }
            .listRowBackground(RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient))

            Section("Pace & HR") {
                statRow(label: "Avg Pace", value: avgPaceSecPerMile.map(paceString) ?? "—")
                statRow(label: "Avg HR", value: avgHR.map { String(format: "%.0f bpm", $0) } ?? "—")
            }
            .listRowBackground(RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient))

            Section("VO2max") {
                let v = vo2Summary
                statRow(label: "Latest", value: v.latest != nil ? String(format: "%.1f", v.latest!) : "—")
                statRow(label: "Average", value: v.avg != nil ? String(format: "%.1f", v.avg!) : "—")
            }
            .listRowBackground(RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient))

            if runs.isEmpty {
                Section {
                    Text("No runs in this range.")
                        .font(.footnote)
                        .foregroundStyle(AthensTheme.marbleWhite.opacity(0.8))
                }
                .listRowBackground(RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
        .background(AthensTheme.backgroundGradient.ignoresSafeArea())
        .refreshable { await store.refreshFromCloud() }
        .task(id: zoneLoadKey) {
            await loadZones(for: zoneLoadKey)
        }
    }

    // Small helpers (scoped to this view)
    private func statRow(label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundColor(AthensTheme.marbleWhite)
            Spacer()
            Text(value).foregroundColor(AthensTheme.marbleWhite).monospacedDigit()
        }
    }

    private func zoneLegendRow(index i: Int, percent: Double, duration: TimeInterval) -> some View {
        HStack(spacing: 8) {
            Circle().fill(zoneColors()[i]).frame(width: 8, height: 8)
            Text("Z\(i + 1)")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AthensTheme.marbleWhite)
            Spacer()
            Text(String(format: "%.0f%%", percent * 100))
                .font(.subheadline.monospacedDigit())
                .foregroundColor(AthensTheme.marbleWhite)
            Text("•")
                .foregroundStyle(AthensTheme.marbleWhite.opacity(0.7))
            Text(formatHMS(duration))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(AthensTheme.marbleWhite.opacity(0.9))
        }
    }

    private func avatar(for user: UserProfile) -> some View {
        ZStack {
            Circle()
                .fill(colorFromHex(user.colorHex))
            Text(user.initials)
                .font(.caption2.weight(.bold))
                .foregroundColor(.white)
        }
        .frame(width: 28, height: 28)
        .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
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

    private func paceString(_ sec: Double) -> String {
        guard sec.isFinite && sec > 0 else { return "—" }
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%d:%02d /mi", m, s)
    }

    private func formatHMS(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 {
            return String(format: "%d:%02d", h, m)
        } else {
            return String(format: "%d min", m)
        }
    }

    // Zones load (current user only; sums across runs in range)
    @MainActor
    private func loadZones(for input: ZoneLoadKey) async {
        zoneError = nil
        zone = ZoneBreakdown()
        isZoneLoading = false
        guard input.userID == input.viewerID, store.hasActiveProfile, !input.runs.isEmpty else { return }
        isZoneLoading = true
        do {
            try? await HealthKitManager.shared.requestAuthorization()
            try Task.checkCancellation()
            var durations = Array(repeating: 0.0, count: 5)
            var total: TimeInterval = 0

            // Fetch latest Resting HR in parallel with zone aggregation
            async let rhrTask = HealthKitManager.shared.fetchLatestRestingHeartRate()

            for w in input.runs {
                let bd = try await HealthKitManager.shared.zoneBreakdown(forRun: w.start, end: w.end)
                try Task.checkCancellation()
                for i in 0..<min(5, bd.durations.count) {
                    durations[i] += bd.durations[i]
                }
                total += bd.total
            }

            let rhrValue = try? await rhrTask
            let rhrInt = max(30, min(100, Int((rhrValue ?? 60).rounded())))

            guard zoneLoadKey == input, !Task.isCancelled else { return }
            zone = ZoneBreakdown(durations: durations, total: total)
            restingHR = rhrInt
            isZoneLoading = false
        } catch {
            guard zoneLoadKey == input, !Task.isCancelled else { return }
            zoneError = error.localizedDescription
            isZoneLoading = false
        }
    }

    // Colors for Z1...Z5
    private func zoneColors() -> [Color] {
        [
            Color.blue.opacity(0.70),
            Color.green.opacity(0.75),
            AthensTheme.goldAccent.opacity(0.85),
            AthensTheme.terracotta.opacity(0.90),
            Color.red.opacity(0.90)
        ]
    }

    // Donut with on-ring labels
    private struct ZoneDonutLabeled: View {
        let values: [Double]   // raw durations per zone
        let colors: [Color]    // Z1...Z5
        let lineWidth: CGFloat
        var labels: [String] = []

        var body: some View {
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                let center = CGPoint(x: side / 2, y: side / 2)
                let radius = side / 2
                let ringRadius = radius - lineWidth / 2

                let sum = max(0.0001, values.reduce(0, +))
                let percents = values.map { max(0.0, $0 / sum) }
                let starts = percents.scan(0.0) { $0 + $1 }

                ZStack {
                    // Segments
                    ForEach(values.indices, id: \.self) { i in
                        let start = starts[i]
                        let end = start + percents[i]
                        Circle()
                            .trim(from: CGFloat(start), to: CGFloat(end))
                            .stroke(colors[i], style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                            .rotationEffect(.degrees(-90))
                    }

                    // Labels on the ring (skip very small slices)
                    ForEach(values.indices, id: \.self) { i in
                        let pct = percents[i]
                        if pct > 0.08 { // threshold to avoid clutter on tiny slivers
                            let start = starts[i]
                            let end = start + pct
                            let mid = (start + end) / 2.0
                            // Convert fraction to angle (radians), accounting for -90° rotation
                            let angle = (mid * 2.0 * .pi) - (.pi / 2.0)
                            let x = center.x + CGFloat(cos(angle)) * ringRadius
                            let y = center.y + CGFloat(sin(angle)) * ringRadius
                            let text = (i < labels.count && !labels[i].isEmpty) ? labels[i] : "Z\(i + 1)"

                            Text(text)
                                .font(.caption2.weight(.bold))
                                .foregroundColor(Color.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(colors[i].opacity(0.95))
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                                )
                                .position(x: x, y: y)
                        }
                    }
                }
                .frame(width: side, height: side)
                // Center the donut within the available GeometryReader space
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
    }
}

// Simple scan helper for cumulative sums
private extension Array where Element == Double {
    func scan(_ initial: Double, _ next: (Double, Double) -> Double) -> [Double] {
        var result: [Double] = []
        result.reserveCapacity(count)
        var running = initial
        for x in self {
            result.append(running)
            running = next(running, x)
        }
        return result
    }
}
