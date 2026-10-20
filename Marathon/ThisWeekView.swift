//
//  ThisWeekView.swift
//  Marathon
//
//  Created by Marcus Price on 11/12/25.
//

import SwiftUI
import HealthKit

struct ThisWeekView: View {
    @EnvironmentObject var store: WorkoutStore
    @AppStorage("appColorScheme") private var appColorScheme: String = "dark"
    @Environment(\.openURL) private var openURL
    @State private var zoneConfig: HRZoneConfig = .appleDefault

    // Week browsing: 0 = current week, 1 = previous, etc.
    @State private var weekOffset: Int = 0

    // HR zones state
    @State private var runZones: [String: ZoneBreakdown] = [:] // workoutId -> breakdown
    @State private var weeklyZ2Seconds: TimeInterval = 0
    @State private var weeklyTotalHRSeconds: TimeInterval = 0
    @State private var hrError: String?

    // Aggregated per-week zone durations for the HR sheet
    @State private var weeklyZoneDurations: [TimeInterval] = Array(repeating: 0, count: 5)

    // Toolbar background behavior
    @State private var isScrolled = false

    // HR sheet
    @State private var showHRSheet = false

    private var currentWeekStart: Date { mondayOfWeek(for: Date()) }

    private var earliestWeekStart: Date {
        var c = DateComponents(); c.year = 2025; c.month = 11; c.day = 1
        let base = Calendar.current.date(from: c) ?? Date()
        return mondayOfWeek(for: base)
    }

    private var maxOffset: Int {
        weeksBetween(earliestWeekStart, currentWeekStart)
    }

    private var selectedWeekStart: Date {
        Calendar.current.date(byAdding: .day, value: -7 * weekOffset, to: currentWeekStart) ?? currentWeekStart
    }
    private var selectedWeekEnd: Date {
        Calendar.current.date(byAdding: .day, value: 7, to: selectedWeekStart) ?? selectedWeekStart.addingTimeInterval(7*24*3600)
    }

    private var weekRows: [WorkoutEntry] {
        runsForSelectedWeek().sorted { $0.start > $1.start }
    }

    private struct ZoneLoadKey: Equatable {
        let userID: String
        let weekStart: Date
        let config: HRZoneConfig
        let runs: [WorkoutEntry]
    }

    private var zoneLoadKey: ZoneLoadKey {
        ZoneLoadKey(userID: store.me.id, weekStart: selectedWeekStart,
                    config: zoneConfig.normalized(), runs: weekRows)
    }

    // Bindings into store.weekBreaks for selected week
    private var breakReasonBinding: Binding<BreakReason> {
        Binding<BreakReason>(
            get: { store.weekBreaks[selectedWeekStart]?.reason ?? .none },
            set: { newReason in
                let notes = store.weekBreaks[selectedWeekStart]?.notes ?? ""
                store.setBreak(reason: newReason, notes: notes, forWeekStart: selectedWeekStart)
            }
        )
    }
    private var breakNotesBinding: Binding<String> {
        Binding<String>(
            get: { store.weekBreaks[selectedWeekStart]?.notes ?? "" },
            set: { newNotes in
                let reason = store.weekBreaks[selectedWeekStart]?.reason ?? .none
                store.setBreak(reason: reason, notes: newNotes, forWeekStart: selectedWeekStart)
            }
        )
    }

    // Miles completed by run type for selected week
    private var milesByType: [RunType: Double] {
        let runs = store.workouts.filter { $0.userId == store.me.id && $0.start >= selectedWeekStart && $0.start < selectedWeekEnd }
        return runs.reduce(into: [:] as [RunType: Double]) { acc, w in
            acc[w.runType, default: 0] += metersToMiles(w.distanceMeters)
        }
    }

    // MARK: - Derived UI state

    private var weekPlan: (requiredWeeklyMiles: Double, suggested: PlanSplit) {
        store.weeklyPlan(for: selectedWeekStart)
    }
    private var planSplit: PlanSplit { weekPlan.suggested }
    private var planTitle: String { weekOffset == 0 ? "This Week Plan" : "Week Plan" }
    private var selectedWeekSummary: WeekSummary { store.weekSummary(for: selectedWeekStart) }
    private var canGoOlder: Bool { weekOffset < maxOffset }
    private var canGoNewer: Bool { weekOffset > 0 }
    private var weeklyZ2Percent: Double {
        weeklyTotalHRSeconds > 0 ? weeklyZ2Seconds / weeklyTotalHRSeconds : 0
    }

    // Button action helpers
    private func goOlderIfAllowed() {
        guard canGoOlder else { return }
        weekOffset += 1
    }
    private func goNewerIfAllowed() {
        guard canGoNewer else { return }
        weekOffset -= 1
    }
    private func resetToThisWeek() {
        withAnimation { weekOffset = 0 }
    }

    var body: some View {
        // Precompute values to help the compiler type-check quickly.
        let wp = weekPlan
        let split = planSplit
        let milesMap = milesByType
        let summary = selectedWeekSummary
        let z2 = weeklyZ2Seconds
        let z2Pct = weeklyZ2Percent
        let hrErr = hrError
        let navLabel = "Week of \(selectedWeekStart.formatted(date: .abbreviated, time: .omitted))"
        let nav = WeekNavBar(
            weekLabel: navLabel,
            canGoOlder: canGoOlder,
            canGoNewer: canGoNewer,
            goOlder: goOlderIfAllowed,
            goNewer: goNewerIfAllowed,
            onTapCenter: resetToThisWeek
        )
        let navAny = AnyView(nav)

        return List {
            Section {
                PlanCard(
                    planTitle: planTitle,
                    requiredMiles: wp.requiredWeeklyMiles,
                    split: split,
                    milesByType: milesMap,
                    summary: summary,
                    weeklyZ2Seconds: z2,
                    z2Percent: z2Pct,
                    hrError: hrErr,
                    weekNav: navAny
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(AthensTheme.cardGradient)
                )
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .preference(key: ThisWeekNavBarOffsetKey.self, value: proxy.frame(in: .named("thisWeekScroll")).minY)
                    }
                )
            }

            Section {
                NavigationLink {
                    WeeklyReviewView(week: selectedWeekStart)
                } label: {
                    Label("Weekly AI Review", systemImage: "sparkles")
                }
                .listRowBackground(AthensTheme.cardGradient)
            }

            Section("Runs") {
                ForEach(weekRows) { w in
                    Group {
                        if w.source.lowercased() == "apple" || w.source.lowercased() == "strava" {
                            NavigationLink {
                                WorkoutDetailView(workout: w)
                            } label: {
                                runRowContent(w: w)
                            }
                            .buttonStyle(.plain)
                        } else {
                            runRowContent(w: w)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(AthensTheme.cardGradient)
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if w.isManual && w.userId == store.me.id {
                            Button(role: .destructive) {
                                store.deleteWorkout(id: w.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .headerProminence(.increased)

            Section("Break / Notes") {
                Picker("Reason", selection: breakReasonBinding) {
                    ForEach(BreakReason.allCases, id: \.self) { r in
                        Text(r.rawValue.capitalized).tag(r)
                    }
                }
                .tint(AthensTheme.goldAccent)
                TextField("Notes (optional)", text: breakNotesBinding)
                    .foregroundColor(AthensTheme.marbleWhite)
            }
            .listRowBackground(
                RoundedRectangle(cornerRadius: 14)
                    .fill(AthensTheme.cardGradient)
            )
        }
        .coordinateSpace(name: "thisWeekScroll")
        .onPreferenceChange(ThisWeekNavBarOffsetKey.self) { y in
            withAnimation(.easeInOut(duration: 0.2)) {
                isScrolled = y < -2
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("This Weeks Runs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showHRSheet = true
                } label: {
                    Image(systemName: "heart.fill")
                }
                .tint(AthensTheme.goldAccent)
                .accessibilityLabel("Heart Rate Zones")
            }

            if weekOffset > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("This Week") { resetToThisWeek() }
                        .tint(AthensTheme.goldAccent)
                }
            }
        }
        #if os(iOS)
        .toolbarBackground(isScrolled ? AthensTheme.midnightBlue : .clear, for: .navigationBar)
        .toolbarBackgroundVisibility(isScrolled ? .visible : .hidden, for: .navigationBar)
        .toolbarColorScheme(appColorScheme == "light" ? .light : .dark, for: .navigationBar)
        #endif
        .background(AthensTheme.backgroundGradient.ignoresSafeArea())
        .tint(AthensTheme.goldAccent)
        .refreshable { await store.refreshFromCloud() }
        .onAppear {
            refreshZoneConfigForCurrentUser()
        }
        .task(id: zoneLoadKey) {
            await loadWeekZones(for: zoneLoadKey)
        }
        // Recompute weekly zones when the config changes (sheet edits).
        .onChange(of: zoneConfig) {
            persistZoneConfig(zoneConfig, for: store.me.id)
        }
        // Keep config scoped to the selected in-app user.
        .onChange(of: store.me.id) {
            refreshZoneConfigForCurrentUser()
        }
        .sheet(isPresented: $showHRSheet) {
            HRZonesSheet(
                weekStart: selectedWeekStart,
                durations: weeklyZoneDurations,
                zoneConfig: $zoneConfig
            )
        }
    }

    // Extracted row content so we can wrap conditionally in NavigationLink
    private func runRowContent(w: WorkoutEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(w.start.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                    .foregroundColor(AthensTheme.marbleWhite)
                Spacer()
                HStack(spacing: 6) {
                    Text(w.isManual ? "Sus Run" : w.source.capitalized)
                        .font(.subheadline)
                        .foregroundStyle(AthensTheme.marbleWhite.opacity(0.7))
                    if w.source.lowercased() == "strava" {
                        Button {
                            openDeepLinkToStrava(for: w)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .buttonStyle(.plain)
                        .tint(AthensTheme.goldAccent)
                        .accessibilityLabel("Open in Strava")
                    }
                }
            }
            HStack(spacing: 10) {
                Text(String(format: "%.2f mi", metersToMiles(w.distanceMeters)))
                Text("•")
                Text(secToHMS(w.durationSec))
                if let pace = w.paceSecPerMile {
                    Text("•"); Text(paceString(pace))
                }
                if let hr = w.avgHR {
                    Text("•"); Text(String(format: "HR %.0f", hr))
                }
            }
            .font(.subheadline)
            .foregroundStyle(AthensTheme.marbleWhite.opacity(0.85))

            if let breakdown = runZones[w.id], breakdown.total > 0 {
                ZoneMiniBar(percentages: breakdown.percentages)
                    .frame(height: 5)
                    .padding(.top, 2)
            }

            if let notes = w.notes, !notes.isEmpty {
                Text(notes)
                    .font(.footnote)
                    .foregroundStyle(AthensTheme.marbleWhite.opacity(0.7))
            }

            Picker("Run Type", selection: Binding<RunType>(
                get: { store.workouts.first(where: { $0.id == w.id })?.runType ?? w.runType },
                set: { store.setRunType($0, forWorkoutId: w.id) }
            )) {
                ForEach(RunType.allCases, id: \.self) { t in
                    Text(t.rawValue.capitalized).tag(t)
                }
            }
            .pickerStyle(.menu)
            .tint(AthensTheme.goldAccent)
        }
        .padding(.vertical, 8)
    }

    private func paceString(_ sec: Double) -> String {
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%d:%02d /mi", m, s)
    }

    private func weeksBetween(_ a: Date, _ b: Date) -> Int {
        max(0, Int((b.timeIntervalSince(a) / (7 * 24 * 3600)).rounded(.down)))
    }

    private func formatHMS(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 {
            return String(format: "%d:%02d", h, m)
        } else {
            return String(format: "%d min", m)
        }
    }

    private func runsForSelectedWeek() -> [WorkoutEntry] {
        store.workouts.filter {
            $0.userId == store.me.id && $0.start >= selectedWeekStart && $0.start < selectedWeekEnd
        }
    }

    @MainActor
    private func loadWeekZones(for input: ZoneLoadKey) async {
        weeklyZ2Seconds = 0
        weeklyTotalHRSeconds = 0
        weeklyZoneDurations = Array(repeating: 0, count: 5)
        hrError = nil
        runZones.removeAll()
        guard store.hasActiveProfile, !input.runs.isEmpty else { return }
        do {
            try? await HealthKitManager.shared.requestAuthorization()
            try Task.checkCancellation()
            var z2: TimeInterval = 0
            var total: TimeInterval = 0
            var weekDur: [TimeInterval] = Array(repeating: 0, count: 5)
            var zones: [String: ZoneBreakdown] = [:]
            for w in input.runs {
                let bd = try await HealthKitManager.shared.zoneBreakdown(forRun: w.start, end: w.end, config: input.config)
                try Task.checkCancellation()
                z2 += (bd.durations.count > 1 ? bd.durations[1] : 0)
                total += bd.total
                for i in 0..<min(5, bd.durations.count) {
                    weekDur[i] += bd.durations[i]
                }
                zones[w.id] = bd
            }
            guard zoneLoadKey == input, !Task.isCancelled else { return }
            runZones = zones
            weeklyZ2Seconds = z2
            weeklyTotalHRSeconds = total
            weeklyZoneDurations = weekDur
        } catch {
            guard zoneLoadKey == input, !Task.isCancelled else { return }
            hrError = error.localizedDescription
        }
    }

    private func zoneConfigStorageKey(for userId: String) -> String {
        "hrZoneConfigJSON_v1_\(userId)"
    }

    private func loadZoneConfig(for userId: String) -> HRZoneConfig {
        guard !userId.isEmpty else { return .appleDefault }
        let key = zoneConfigStorageKey(for: userId)
        if let data = UserDefaults.standard.string(forKey: key)?.data(using: .utf8),
           let cfg = try? JSONDecoder().decode(HRZoneConfig.self, from: data) {
            return cfg
        }
        return .appleDefault
    }

    private func persistZoneConfig(_ config: HRZoneConfig, for userId: String) {
        guard !userId.isEmpty else { return }
        let normalized = config.normalized()
        if let data = try? JSONEncoder().encode(normalized),
           let s = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(s, forKey: zoneConfigStorageKey(for: userId))
        }
    }

    private func refreshZoneConfigForCurrentUser() {
        let userId = store.me.id
        let loaded = loadZoneConfig(for: userId).normalized()
        if zoneConfig != loaded {
            zoneConfig = loaded
        }
    }

    // MARK: - Strava deep link

    private func openDeepLinkToStrava(for w: WorkoutEntry) {
        guard w.source.lowercased() == "strava" else { return }
        if let id = w.stravaActivityId,
           let appURL = URL(string: "strava://activities/\(id)") {
            openURL(appURL) { accepted in
                if !accepted, let web = URL(string: "https://www.strava.com/activities/\(id)") {
                    openURL(web) { ok in
                        if !ok, let appHome = URL(string: "strava://") {
                            openURL(appHome)
                        }
                    }
                }
            }
        } else if let appHome = URL(string: "strava://") {
            openURL(appHome)
        }
    }
}

// PreferenceKey unique to this file to avoid redeclaration
private struct ThisWeekNavBarOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// Small subviews (unchanged)
private struct WeekNavBar: View { /* ... unchanged ... */ 
    let weekLabel: String
    let canGoOlder: Bool
    let canGoNewer: Bool
    let goOlder: () -> Void
    let goNewer: () -> Void
    let onTapCenter: () -> Void

    var body: some View {
        HStack {
            Button(action: goOlder) {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .tint(AthensTheme.goldAccent)
            .disabled(!canGoOlder)
            .opacity(canGoOlder ? 1.0 : 0.4)

            Text(weekLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AthensTheme.marbleWhite)
                .frame(maxWidth: .infinity)
                .onTapGesture { onTapCenter() }

            Button(action: goNewer) {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .tint(AthensTheme.goldAccent)
            .disabled(!canGoNewer)
            .opacity(canGoNewer ? 1.0 : 0.4)
        }
    }
}

private struct PlanCard<WeekNav: View>: View {
    let planTitle: String
    let requiredMiles: Double
    let split: PlanSplit
    let milesByType: [RunType: Double]
    let summary: WeekSummary
    let weeklyZ2Seconds: TimeInterval
    let z2Percent: Double
    let hrError: String?
    let weekNav: WeekNav

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image("Athens")
                .resizable()
                .scaledToFill()
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            weekNav

            HStack {
                Text(planTitle)
                    .font(.headline)
                    .foregroundColor(AthensTheme.marbleWhite)
                Spacer()
                // Show actual/plan total miles, e.g., "7.0 / 4.0 mi total"
                Text("\(String(format: "%.1f", milesByType.values.reduce(0, +))) / \(String(format: "%.1f", requiredMiles)) mi total")
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(AthensTheme.marbleWhite.opacity(0.9))
            }

            PlanRow(icon: "leaf", title: "Recovery", target: split.recovery, done: milesByType[.recovery] ?? 0, color: AthensTheme.oliveGreen)
            PlanRow(icon: "flame", title: "Tempo", target: split.tempo, done: milesByType[.tempo] ?? 0, color: AthensTheme.terracotta)
            PlanRow(icon: "figure.run.circle", title: "Long", target: split.long, done: milesByType[.long] ?? 0, color: AthensTheme.goldAccent)

            if summary.breakReason != .none || (summary.breakNotes?.isEmpty == false) {
                HStack(spacing: 6) {
                    Image(systemName: "pause.circle.fill").foregroundStyle(AthensTheme.goldAccent)
                    Text("Break: \(summary.breakReason.rawValue.capitalized)")
                        .font(.footnote.weight(.semibold))
                    if let n = summary.breakNotes, !n.isEmpty {
                        Text("• \(n)").font(.footnote)
                    }
                    Spacer()
                }
                .foregroundColor(AthensTheme.marbleWhite)
            }

            Text("Tip: assign each run a type (Recovery/Tempo/Long) to track completion.")
                .font(.footnote)
                .foregroundColor(AthensTheme.marbleWhite.opacity(0.8))

            HStack(spacing: 6) {
                Image(systemName: "heart.circle.fill")
                    .foregroundStyle(AthensTheme.goldAccent)
                Text("Zone 2 this week:")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(AthensTheme.marbleWhite)
                Text(formatHMS(weeklyZ2Seconds))
                    .font(.footnote.monospacedDigit())
                    .foregroundColor(AthensTheme.marbleWhite.opacity(0.95))
                Text(String(format: "(%.0f%%)", z2Percent * 100))
                    .font(.footnote.monospacedDigit())
                    .foregroundColor(AthensTheme.marbleWhite.opacity(0.9))
                Spacer()
            }

            if let err = hrError {
                Text(err)
                    .font(.footnote)
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 10)
    }

    private func formatHMS(_ seconds: TimeInterval) -> String {
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

private struct PlanRow: View { /* unchanged */ 
    let icon: String
    let title: String
    let target: Double
    let done: Double
    let color: Color

    var body: some View {
        let clampedTarget = max(0.1, target)
        let progress = max(0.0, min(1.0, done / clampedTarget))
        let complete = progress >= 1.0 - 0.001

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(color)
                Text(title).foregroundColor(AthensTheme.marbleWhite)
                Spacer()
                Text(String(format: "%.1f / %.1f mi", done, target))
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(AthensTheme.marbleWhite)
                if complete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(color)
                        .imageScale(.medium)
                }
            }
            ProgressBarCapsule(progress: progress, fill: color.opacity(0.9))
                .frame(height: 5)
        }
    }
}

private struct ProgressBarCapsule: View { /* unchanged */ 
    let progress: Double
    let fill: Color

    var body: some View {
        GeometryReader { geo in
            let clamped = max(0.0, min(1.0, progress))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule().fill(fill)
                    .frame(width: CGFloat(clamped) * geo.size.width)
                    .animation(.easeOut(duration: 0.3), value: clamped)
            }
        }
    }
}

// Reusable mini bar for 5 HR zones
private struct ZoneMiniBar: View { /* unchanged */ 
    let percentages: [Double]

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let clamped = percentages.prefix(5).map { max(0.0, min(1.0, $0)) }
            let sum = clamped.reduce(0, +)
            let normalized = sum > 0 ? clamped.map { $0 / sum } : Array(repeating: 0.0, count: clamped.count)
            let segmentWidths = normalized.map { CGFloat($0) * width }

            let offsets: [CGFloat] = segmentWidths.indices.map { i in
                i == 0 ? 0 : segmentWidths[0..<i].reduce(0, +)
            }

            let colors: [Color] = [
                Color.blue.opacity(0.70),
                Color.green.opacity(0.75),
                AthensTheme.goldAccent.opacity(0.85),
                AthensTheme.terracotta.opacity(0.90),
                Color.red.opacity(0.90)
            ]

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                ForEach(segmentWidths.indices, id: \.self) { i in
                    Capsule()
                        .fill(colors[i])
                        .frame(width: segmentWidths[i])
                        .offset(x: offsets[i])
                        .animation(.easeOut(duration: 0.25), value: segmentWidths[i])
                }
            }
        }
    }
}

// A bar to visualize zone ranges by % of Heart Rate Reserve (HRR) from 50% to 100%
private struct ZoneRangeBar: View {
    let bands: [ClosedRange<Double>] // e.g., 0.50...0.60, ..., 0.90...1.00

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let domainStart: Double = 0.50
            let domainEnd: Double = 1.00
            let domain = domainEnd - domainStart

            let colors: [Color] = [
                Color.blue.opacity(0.70),
                Color.green.opacity(0.75),
                AthensTheme.goldAccent.opacity(0.85),
                AthensTheme.terracotta.opacity(0.90),
                Color.red.opacity(0.90)
            ]

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                ForEach(bands.indices, id: \.self) { i in
                    let b = bands[i]
                    let startX = CGFloat((b.lowerBound - domainStart) / domain) * width
                    let segW = CGFloat((b.upperBound - b.lowerBound) / domain) * width
                    Capsule()
                        .fill(colors[i])
                        .frame(width: max(segW, 0))
                        .offset(x: max(startX, 0))
                        .animation(.easeOut(duration: 0.25), value: segW)
                }
            }
        }
    }
}

// Sheet showing HR zones info and weekly distribution
private struct HRZonesSheet: View {
    let weekStart: Date
    let durations: [TimeInterval]
    @Binding var zoneConfig: HRZoneConfig

    @Environment(\.dismiss) private var dismiss

    // For reference card: age and max HR estimate (from Health app DOB if available)
    @State private var userAge: Int?
    @State private var maxHREstimate: Int = 0
    @State private var restingHREstimate: Int = 60

    // Local draft while editing (normalized on commit)
    @State private var draftConfig: HRZoneConfig = .appleDefault

    private var total: TimeInterval {
        durations.prefix(5).reduce(0, +)
    }
    private var percentages: [Double] {
        guard total > 0 else { return Array(repeating: 0, count: min(5, durations.count)) }
        return durations.prefix(5).map { max(0.0, min(1.0, $0 / total)) }
    }

    // Use chosen config’s bands (normalized) instead of fixed Apple defaults
    private var referenceBands: [ClosedRange<Double>] {
        draftConfig.normalized().bands
    }

    private var maxHRForDisplay: Int {
        maxHREstimate > 0 ? maxHREstimate : HealthKitManager.shared.estimateMaxHR()
    }
    private var restingHRForDisplay: Int {
        restingHREstimate
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Header card
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(AthensTheme.goldAccent)
                            Text("Weekly HR Zones")
                                .font(.headline)
                                .foregroundColor(AthensTheme.marbleWhite)
                            Spacer()
                        }
                        Text("Week of \(weekStart.formatted(date: .abbreviated, time: .omitted))")
                            .font(.subheadline)
                            .foregroundColor(AthensTheme.marbleWhite.opacity(0.85))
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16).fill(AthensTheme.cardGradient))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06), lineWidth: 1))
                    .athensSoftShadow()

                    // Zones Reference card (bands + HRR formula)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "chart.bar.fill")
                                .foregroundStyle(AthensTheme.goldAccent)
                            Text("Zones Reference (HRR)")
                                .font(.headline)
                                .foregroundColor(AthensTheme.marbleWhite)
                            Spacer()
                        }

                        if let age = userAge {
                            Text("Max HR (estimate): 220 − \(age) = \(maxHRForDisplay) bpm")
                                .font(.footnote.weight(.semibold))
                                .foregroundColor(AthensTheme.marbleWhite.opacity(0.95))
                        } else {
                            Text("Max HR (estimate): \(maxHRForDisplay) bpm")
                                .font(.footnote.weight(.semibold))
                                .foregroundColor(AthensTheme.marbleWhite.opacity(0.95))
                        }
                        Text("Resting HR (latest): \(restingHRForDisplay) bpm • HRR = Max − Resting")
                            .font(.footnote)
                            .foregroundColor(AthensTheme.marbleWhite.opacity(0.85))

                        ZoneRangeBar(bands: referenceBands)
                            .frame(height: 10)

                        // Zone rows with percent and BPM ranges (Karvonen)
                        VStack(alignment: .leading, spacing: 8) {
                            referenceRow(label: "Z1", idx: 0, band: referenceBands[0], color: Color.blue.opacity(0.70))
                            referenceRow(label: "Z2", idx: 1, band: referenceBands[1], color: Color.green.opacity(0.75))
                            referenceRow(label: "Z3", idx: 2, band: referenceBands[2], color: AthensTheme.goldAccent.opacity(0.85))
                            referenceRow(label: "Z4", idx: 3, band: referenceBands[3], color: AthensTheme.terracotta.opacity(0.90))
                            referenceRow(label: "Z5", idx: 4, band: referenceBands[4], color: Color.red.opacity(0.90))
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16).fill(AthensTheme.cardGradient))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06), lineWidth: 1))
                    .athensSoftShadow()

                    // NEW: Adjust Zones (sliders)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundStyle(AthensTheme.goldAccent)
                            Text("Adjust Zones")
                                .font(.headline)
                                .foregroundColor(AthensTheme.marbleWhite)
                            Spacer()
                            Button {
                                draftConfig = .appleDefault
                                commitDraft()
                            } label: {
                                Text("Reset")
                            }
                            .buttonStyle(.bordered)
                            .tint(AthensTheme.goldAccent)
                        }

                        sliderRow(
                            title: "Z2 cutoff",
                            value: Binding(
                                get: { draftConfig.z2 },
                                set: { draftConfig.z2 = $0 }
                            ),
                            onEndEditing: commitDraft
                        )
                        sliderRow(
                            title: "Z3 cutoff",
                            value: Binding(
                                get: { draftConfig.z3 },
                                set: { draftConfig.z3 = $0 }
                            ),
                            onEndEditing: commitDraft
                        )
                        sliderRow(
                            title: "Z4 cutoff",
                            value: Binding(
                                get: { draftConfig.z4 },
                                set: { draftConfig.z4 = $0 }
                            ),
                            onEndEditing: commitDraft
                        )
                        sliderRow(
                            title: "Z5 cutoff",
                            value: Binding(
                                get: { draftConfig.z5 },
                                set: { draftConfig.z5 = $0 }
                            ),
                            onEndEditing: commitDraft
                        )

                        Text("Cutoffs are the upper bounds for Z1–Z4. Z5 is the remainder up to 100% HRR. Values are based on Heart Rate Reserve (HRR = Max − Resting).")
                            .font(.footnote)
                            .foregroundStyle(AthensTheme.marbleWhite.opacity(0.8))
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16).fill(AthensTheme.cardGradient))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06), lineWidth: 1))
                    .athensSoftShadow()

                    // Stacked zone bar (weekly distribution)
                    VStack(alignment: .leading, spacing: 10) {
                        ZoneMiniBar(percentages: percentages)
                            .frame(height: 10)
                        HStack {
                            Text("Total HR time:")
                                .font(.footnote.weight(.semibold))
                                .foregroundColor(AthensTheme.marbleWhite)
                            Spacer()
                            Text(formatHMS(total))
                                .font(.footnote.monospacedDigit())
                                .foregroundColor(AthensTheme.marbleWhite.opacity(0.95))
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16).fill(AthensTheme.cardGradient))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06), lineWidth: 1))
                    .athensSoftShadow()

                    // Zone rows (weekly distribution)
                    VStack(alignment: .leading, spacing: 8) {
                        zoneRow(label: "Z1", idx: 0, color: Color.blue.opacity(0.70))
                        zoneRow(label: "Z2", idx: 1, color: Color.green.opacity(0.75))
                        zoneRow(label: "Z3", idx: 2, color: AthensTheme.goldAccent.opacity(0.85))
                        zoneRow(label: "Z4", idx: 3, color: AthensTheme.terracotta.opacity(0.90))
                        zoneRow(label: "Z5", idx: 4, color: Color.red.opacity(0.90))
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16).fill(AthensTheme.cardGradient))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06), lineWidth: 1))
                    .athensSoftShadow()
                }
                .padding()
            }
            .navigationTitle("HR Zones")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .background(AthensTheme.backgroundGradient.ignoresSafeArea())
            .task {
                // Load persisted config into draft for editing
                draftConfig = zoneConfig.normalized()
                await computeAgeAndMaxHR()
            }
            // Keep reference bands in sync if parent config changes elsewhere.
            .onChange(of: zoneConfig) {
                draftConfig = zoneConfig.normalized()
            }
        }
    }

    // Compact slider row with percent + bpm readout; commits on end of editing to avoid recompute thrash.
    private func sliderRow(title: String, value: Binding<Double>, onEndEditing: @escaping () -> Void) -> some View {
        let maxHR = maxHRForDisplay
        let rhr = restingHRForDisplay
        let bound = value.wrappedValue
        let pct = Int((bound * 100).rounded())
        let bpm = Int((Double(rhr) + (Double(maxHR - rhr) * bound)).rounded())

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AthensTheme.marbleWhite)
                Spacer()
                Text("\(pct)% • \(bpm) bpm")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(AthensTheme.marbleWhite.opacity(0.9))
            }
            Slider(value: Binding(
                get: { value.wrappedValue },
                set: { newVal in
                    // Update draft immediately for visual feedback; normalize on commit
                    value.wrappedValue = min(max(newVal, 0.50), 1.00)
                }
            ), in: 0.50...1.00, onEditingChanged: { editing in
                if !editing {
                    commitDraft()
                }
            })
            .tint(AthensTheme.goldAccent)
        }
    }

    private func referenceRow(label: String, idx: Int, band: ClosedRange<Double>, color: Color) -> some View {
        let maxHR = maxHRForDisplay
        let rhr = restingHRForDisplay

        // Percent label (show explicit HRR)
        let percentText: String = {
            let lowPct = Int((band.lowerBound * 100).rounded())
            let highPct = Int((band.upperBound * 100).rounded())
            return "\(lowPct)–\(highPct)% HRR"
        }()

        // Karvonen BPM range: RHR + HRR% * (Max − RHR)
        let low = Int((Double(rhr) + (Double(maxHR - rhr) * band.lowerBound)).rounded())
        let high = Int((Double(rhr) + (Double(maxHR - rhr) * band.upperBound)).rounded())
        let bpmText = "\(low)–\(high) bpm"

        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AthensTheme.marbleWhite)
            Spacer()
            Text(percentText)
                .font(.subheadline.monospacedDigit())
                .foregroundColor(AthensTheme.marbleWhite)
            Text("•")
                .foregroundStyle(AthensTheme.marbleWhite.opacity(0.7))
            Text(bpmText)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(AthensTheme.marbleWhite.opacity(0.9))
        }
    }

    private func zoneRow(label: String, idx: Int, color: Color) -> some View {
        let dur = (idx < durations.count) ? durations[idx] : 0
        let pct = (idx < percentages.count) ? percentages[idx] : 0
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AthensTheme.marbleWhite)
            Spacer()
            Text(String(format: "%.0f%%", pct * 100))
                .font(.subheadline.monospacedDigit())
                .foregroundColor(AthensTheme.marbleWhite)
            Text("•")
                .foregroundStyle(AthensTheme.marbleWhite.opacity(0.7))
            Text(formatHMS(dur))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(AthensTheme.marbleWhite.opacity(0.9))
        }
    }

    private func formatHMS(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 {
            return String(format: "%d:%02d", h, m)
        } else {
            return String(format: "%d min", m)
        }
    }

    private func computeAgeAndMaxHR() async {
        // Ask for permissions (DOB & Resting HR are included in manager's request)
        try? await HealthKitManager.shared.requestAuthorization()

        // Try to read DOB directly (avoid manager's cached fallback)
        if let comps = try? HKHealthStore().dateOfBirthComponents(),
           let year = comps.year {
            let currentYear = Calendar.current.component(.year, from: Date())
            let age = max(0, currentYear - year)
            let est = max(120, min(210, 220 - age))
            await MainActor.run {
                self.userAge = age
                self.maxHREstimate = est
            }
        } else {
            // Fallback to manager estimate (may be default if DOB unavailable)
            let est = HealthKitManager.shared.estimateMaxHR()
            await MainActor.run {
                self.userAge = nil
                self.maxHREstimate = est
            }
        }

        // Fetch latest Resting HR (fallback to 60 bpm)
        let rhr = try? await HealthKitManager.shared.fetchLatestRestingHeartRate()
        await MainActor.run {
            self.restingHREstimate = max(30, min(100, Int((rhr ?? 60).rounded())))
        }
    }

    // Normalize and publish the draft; ThisWeekView persists and recomputes weekly zones.
    private func commitDraft() {
        let norm = draftConfig.normalized()
        zoneConfig = norm
        // Also update the draft so sliders show normalized bounds immediately.
        draftConfig = norm
    }
}
