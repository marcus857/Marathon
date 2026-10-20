//
//  PlanPreviewView.swift
//  Marathon
//
//  Created by Marcus Price on 11/12/25.
//

import SwiftUI

struct PlanPreviewView: View {
    @EnvironmentObject var store: WorkoutStore
    @AppStorage("appColorScheme") private var appColorScheme: String = "dark"
    @State private var scope: Scope = .nextWeek

    // Track scroll to toggle toolbar background (on list-based content)
    @State private var isScrolled = false

    // Search state
    @State private var showingSearch = false
    @State private var searchStart: Date = Date()
    @State private var searchEnd: Date = Date()
    @State private var activeSearchRange: (start: Date, end: Date)? = nil

    enum Scope: String, CaseIterable, Identifiable {
        case nextWeek = "Next Week"
        case nextRuns = "Master Plan" // renamed from "Next Runs"
        var id: String { rawValue }
    }

    private var isSearchActive: Bool { activeSearchRange != nil }

    var body: some View {
        VStack(spacing: 0) {
            // Segmented control (visible always)
            HStack {
                Picker("Scope", selection: $scope) {
                    ForEach(Scope.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .tint(AthensTheme.goldAccent)
            }
            .padding(.horizontal)
            .padding(.top)

            // Content switches: Search Results > scope content
            if let range = activeSearchRange {
                // Search Results
                ScrollView {
                    GeometryReader { proxy in
                        Color.clear
                            .preference(key: NavBarOffsetKey.self, value: proxy.frame(in: .named("planScroll")).minY)
                    }
                    .frame(height: 0)

                    VStack(spacing: 16) {
                        searchHeader(range: range)
                        ForEach(weeksInRange(start: range.start, end: range.end), id: \.self) { weekStart in
                            monthCard(for: weekStart)
                        }
                    }
                    .padding()
                }
                .coordinateSpace(name: "planScroll")
                .onPreferenceChange(NavBarOffsetKey.self) { y in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isScrolled = y < -2
                    }
                }
            } else {
                // Normal segmented content
                if scope == .nextRuns {
                    // Show the full Master Plan page instead
                    MasterPlanView()
                } else {
                    // Next Week: only show the next 4 weeks of runs
                    ScrollView {
                        // Invisible probe to track scroll offset
                        GeometryReader { proxy in
                            Color.clear
                                .preference(key: NavBarOffsetKey.self, value: proxy.frame(in: .named("planScroll")).minY)
                        }
                        .frame(height: 0)

                        VStack(spacing: 16) {
                            nextMonthList
                        }
                        .padding()
                    }
                    .coordinateSpace(name: "planScroll")
                    .onPreferenceChange(NavBarOffsetKey.self) { y in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isScrolled = y < -2
                        }
                    }
                }
            }
        }
        .navigationTitle(isSearchActive ? "Search Results" : (scope == .nextRuns ? "Master Plan" : "Plan Preview"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Search icon
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    // Initialize defaults for search
                    searchStart = nextMonday(from: Date())
                    searchEnd = nextMonday(from: Date(), plusWeeks: 3) // Next 4 weeks by default
                    showingSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .tint(AthensTheme.goldAccent)
                .accessibilityLabel("Search by Date Range")
            }

            // Gear: opens 3-Runs/Week Framework info (kept as before)
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    PlanFrameworkInfoView()
                } label: {
                    Image(systemName: "gearshape")
                }
                .tint(AthensTheme.goldAccent)
                .accessibilityLabel("3-Runs/Week Framework")
            }
        }
        #if os(iOS)
        // Use the same toolbar styling for all list-based content (transparent at top, blue when scrolled)
        .toolbarBackground(isScrolled ? AthensTheme.midnightBlue : .clear, for: .navigationBar)
        .toolbarBackgroundVisibility(isScrolled ? .visible : .hidden, for: .navigationBar)
        .toolbarColorScheme(appColorScheme == "light" ? .light : .dark, for: .navigationBar)
        #endif
        .background(AthensTheme.backgroundGradient.ignoresSafeArea())
        .onChange(of: scope) {
            if scope == .nextRuns {
                // When swapping to embedded Master Plan, reset scroll state
                isScrolled = false
            }
        }
        .sheet(isPresented: $showingSearch) {
            NavigationStack {
                Form {
                    Section("Range") {
                        DatePicker("Start", selection: $searchStart, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                        DatePicker("End", selection: $searchEnd, in: searchStart..., displayedComponents: .date)
                            .datePickerStyle(.graphical)
                    }

                    Section("Quick Picks") {
                        Button("Next 4 Weeks") {
                            searchStart = nextMonday(from: Date())
                            searchEnd = nextMonday(from: Date(), plusWeeks: 3)
                        }
                        Button("Next 12 Weeks") {
                            searchStart = nextMonday(from: Date())
                            searchEnd = nextMonday(from: Date(), plusWeeks: 11)
                        }
                        Button("Full Plan") {
                            if let bounds = planBounds() {
                                searchStart = bounds.start
                                searchEnd = bounds.end
                            } else {
                                searchStart = nextMonday(from: Date())
                                searchEnd = nextMonday(from: Date(), plusWeeks: 11)
                            }
                        }
                    }
                }
                .navigationTitle("Search Plan")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingSearch = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Show") {
                            let s = mondayOfWeek(for: searchStart)
                            let e = mondayOfWeek(for: searchEnd)
                            if s <= e {
                                activeSearchRange = (start: s, end: e)
                            }
                            showingSearch = false
                        }
                        .disabled(mondayOfWeek(for: searchStart) > mondayOfWeek(for: searchEnd))
                    }
                }
            }
        }
    }

    // MARK: - Sections

    private var nextMonthList: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(0..<4, id: \.self) { i in
                let weekStart = nextMonday(from: Date(), plusWeeks: i)
                monthCard(for: weekStart)
            }
        }
    }

    @ViewBuilder
    private func searchHeader(range: (start: Date, end: Date)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(range.start.formatted(date: .abbreviated, time: .omitted))")
                    .font(.headline)
                    .foregroundColor(AthensTheme.marbleWhite)
                Text("–")
                    .foregroundColor(AthensTheme.marbleWhite.opacity(0.8))
                Text("\(range.end.formatted(date: .abbreviated, time: .omitted))")
                    .font(.headline)
                    .foregroundColor(AthensTheme.marbleWhite)
                Spacer()
                Button {
                    activeSearchRange = nil
                    isScrolled = false
                } label: {
                    Label("Clear Search", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                }
                .tint(AthensTheme.goldAccent)
                .accessibilityLabel("Clear Search")
            }
            let count = weeksInRange(start: range.start, end: range.end).count
            Text("\(count) week\(count == 1 ? "" : "s")")
                .font(.subheadline)
                .foregroundColor(AthensTheme.marbleWhite.opacity(0.85))
        }
    }

    private func monthCard(for weekStart: Date) -> some View {
        let plan = store.weeklyPlan(for: weekStart)
        let split = plan.suggested

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(weekStart.formatted(date: .abbreviated, time: .omitted))
                    .font(.headline)
                    .foregroundColor(AthensTheme.marbleWhite)
                Spacer()
                Text(String(format: "%.1f mi", plan.requiredWeeklyMiles))
                    .font(.headline.monospacedDigit())
                    .foregroundColor(AthensTheme.marbleWhite)
            }

            goldDivider()

            HStack(spacing: 10) {
                pill(label: "Rec", miles: split.recovery, color: AthensTheme.oliveGreen)
                pill(label: "Tmp", miles: split.tempo, color: AthensTheme.terracotta)
                pill(label: "Long", miles: split.long, color: AthensTheme.goldAccent)
            }
            if let note = split.note, !note.isEmpty {
                Text(note)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AthensTheme.marbleWhite.opacity(0.9))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AthensTheme.cardGradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 6)
    }

    // MARK: - Helpers

    private func nextMonday(from date: Date, plusWeeks: Int = 1) -> Date {
        let base = date.addingTimeInterval(Double(plusWeeks) * 7 * 24 * 3600)
        return mondayOfWeek(for: base)
    }

    private func planBounds() -> (start: Date, end: Date)? {
        let keys = Array(store.masterPlan.keys)
        guard let minD = keys.min(), let maxD = keys.max() else { return nil }
        return (start: mondayOfWeek(for: minD), end: mondayOfWeek(for: maxD))
    }

    private func weeksInRange(start: Date, end: Date) -> [Date] {
        let cal = Calendar.current
        let s = mondayOfWeek(for: start)
        let e = mondayOfWeek(for: end)
        guard s <= e else { return [] }
        var weeks: [Date] = []
        var cur = s
        while cur <= e {
            weeks.append(cur)
            cur = cal.date(byAdding: .day, value: 7, to: cur) ?? cur.addingTimeInterval(7 * 24 * 3600)
        }
        return weeks
    }

    @ViewBuilder
    private func pill(label: String, miles: Double, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption.weight(.semibold)).foregroundColor(AthensTheme.marbleWhite)
            Text(String(format: "%.1f mi", miles))
                .font(.caption.monospacedDigit())
                .foregroundColor(AthensTheme.marbleWhite.opacity(0.95))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(Color.white.opacity(0.06))
        )
    }

    private func goldDivider() -> some View {
        Rectangle()
            .fill(AthensTheme.goldAccent.opacity(0.35))
            .frame(height: 1)
            .cornerRadius(0.5)
    }
}

// PreferenceKey to track scroll offset (local to this file)
private struct NavBarOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// Lightweight page that shows the same "3-Runs/Week Framework" card content
private struct PlanFrameworkInfoView: View {
    @AppStorage("appColorScheme") private var appColorScheme: String = "dark"

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                frameworkCard
            }
            .padding()
        }
        .navigationTitle("3-Runs/Week")
        .navigationBarTitleDisplayMode(.inline)
        #if os(iOS)
        .toolbarBackground(.clear, for: .navigationBar)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbarColorScheme(appColorScheme == "light" ? .light : .dark, for: .navigationBar)
        #endif
        .background(AthensTheme.backgroundGradient.ignoresSafeArea())
    }

    private var frameworkCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("3-Runs/Week Framework")
                .font(.headline)
                .foregroundColor(AthensTheme.marbleWhite)

            Rectangle().fill(AthensTheme.goldAccent.opacity(0.35)).frame(height: 1)

            Text("• Recovery: easy conversational pace")
            Text("• Tempo: comfortably hard, steady effort")
            Text("• Long: steady, build resilience (progress to 18–20 mi before taper)")
            Text("Rules: +10% weekly cap, every 4th week consolidates (~25% drop), emphasize long-run growth pre‑Jan, practice fueling and pacing. Optionals: strides, mobility, cross‑train.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .foregroundColor(AthensTheme.marbleWhite.opacity(0.9))
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(AthensTheme.cardGradient))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 6)
    }
}
