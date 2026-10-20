//
//  CalendarView.swift
//  Marathon
//
//  Created by Marcus Price on 11/12/25.
//

import SwiftUI

struct CalendarView: View {
    @EnvironmentObject var store: WorkoutStore
    @AppStorage("appColorScheme") private var appColorScheme: String = "dark"
    @Environment(\.openURL) private var openURL

    @State private var month: Date = Date()
    @State private var selectedDate: Date?
    @State private var manualDate: Date?

    // Toolbar background behavior
    @State private var isScrolled = false

    // Team dots + filter
    @State private var showTeamDots: Bool = false
    @State private var selectedUserIds: Set<String> = [] // other runners filter (excludes me)
    @State private var includesAllTeammates = true

    // Weekly rail toggle
    @State private var showWeeklyRail: Bool = true

    // Use a Monday-based calendar for this view
    private var mondayCal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = .autoupdatingCurrent
        c.timeZone = .autoupdatingCurrent
        c.firstWeekday = 2              // Monday
        c.minimumDaysInFirstWeek = 4    // ISO-like
        return c
    }

    // Sorted lists
    private var nonMeUsersSorted: [UserProfile] {
        store.allUsers
            .filter { $0.id != store.me.id }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // Keep "all" dynamic so newly synchronized teammates appear automatically.
    private var activeOtherIds: Set<String> {
        if includesAllTeammates {
            return Set(nonMeUsersSorted.map { $0.id })
        } else {
            return selectedUserIds
        }
    }

    // Consistent color for "me"
    private var myDotColor: Color {
        colorFromHex(store.me.colorHex)
    }

    var body: some View {
        ScrollView {
            // Invisible probe to track scroll offset
            GeometryReader { proxy in
                Color.clear
                    .preference(key: CalendarNavBarOffsetKey.self, value: proxy.frame(in: .named("calendarScroll")).minY)
            }
            .frame(height: 0)

            VStack(spacing: 12) {
                header
                weekdayHeader

                // Month laid out as rows (weeks), each with 7 day cells + optional right rail showing weekly ran/plan
                VStack(spacing: 10) {
                    ForEach(Array(weeksGrid(for: month).enumerated()), id: \.offset) { _, weekDays in
                        let wkStart = weekStartMonday(for: weekDays.first ?? Date())
                        let ran = weeklyMilesRan(forWeekStarting: wkStart)
                        let plan = weeklyPlanMiles(forWeekStarting: wkStart)

                        HStack(spacing: 6) {
                            ForEach(weekDays, id: \.self) { day in
                                let info = teamDotsInfo(on: day, limit: 5)
                                DayCell(
                                    date: day,
                                    miles: miles(on: day),
                                    myDotColor: myDotColor,
                                    teamDots: showTeamDots ? info.colors : [],
                                    extraDots: showTeamDots ? info.extra : 0,
                                    hasImportant: hasImportant(on: day),
                                    isCurrentMonth: isInCurrentMonth(day, month: month),
                                    onTap: { selectedDate = day },
                                    onLongPress: { manualDate = day }
                                )
                                .frame(maxWidth: .infinity)
                            }
                            if showWeeklyRail {
                                WeekRailCell(ran: ran, plan: plan)
                                    .frame(width: 86)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)

                if showTeamDots {
                    teamLegend
                        .padding(.horizontal)
                }

                Spacer(minLength: 0)
            }
            .padding(.top, 8)
        }
        .coordinateSpace(name: "calendarScroll")
        .onPreferenceChange(CalendarNavBarOffsetKey.self) { y in
            withAnimation(.easeInOut(duration: 0.2)) {
                isScrolled = y < -2
            }
        }
        .sheet(isPresented: Binding(get: { selectedDate != nil },
                                    set: { if !$0 { selectedDate = nil } })) {
            if let d = selectedDate { DayRunsSheet(date: d) }
        }
        .sheet(isPresented: Binding(get: { manualDate != nil },
                                    set: { if !$0 { manualDate = nil } })) {
            if let d = manualDate {
                NavigationStack { ManualRunForm(initialDate: d) }
            }
        }
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Team dots + people filter + weekly rail toggle
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: $showTeamDots) {
                        Label("Show Team Dots", systemImage: showTeamDots ? "person.3.fill" : "person.3")
                    }
                    Toggle(isOn: $showWeeklyRail) {
                        Label("Show Weekly Rail", systemImage: showWeeklyRail ? "chart.bar.fill" : "chart.bar")
                    }

                    if !nonMeUsersSorted.isEmpty {
                        Section("People") {
                            Button {
                                // Select All / Clear All for others
                                if activeOtherIds.count == nonMeUsersSorted.count {
                                    includesAllTeammates = false
                                    selectedUserIds.removeAll()
                                } else {
                                    includesAllTeammates = true
                                    selectedUserIds.removeAll()
                                }
                            } label: {
                                let allSelected = activeOtherIds.count == nonMeUsersSorted.count && !nonMeUsersSorted.isEmpty
                                Label(allSelected ? "Clear All" : "Select All",
                                      systemImage: allSelected ? "minus.circle" : "checkmark.circle")
                            }

                            ForEach(nonMeUsersSorted, id: \.id) { u in
                                Button {
                                    toggleUser(u.id)
                                } label: {
                                    Label(u.displayName,
                                          systemImage: activeOtherIds.contains(u.id) ? "checkmark.circle.fill" : "circle")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: showTeamDots || showWeeklyRail ? "line.3.horizontal.decrease.circle" : "slider.horizontal.3")
                }
                .tint(AthensTheme.goldAccent)
                .accessibilityLabel("Options")
            }

            // Existing Add Manual Run
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    manualDate = Calendar.current.startOfDay(for: Date())
                } label: {
                    Image(systemName: "plus")
                }
                .tint(AthensTheme.goldAccent)
                .accessibilityLabel("Add Manual Run")
            }
        }
        #if os(iOS)
        // Match Home: transparent at top, dynamic blue when scrolled
        .toolbarBackground(isScrolled ? AthensTheme.midnightBlue : .clear, for: .navigationBar)
        .toolbarBackgroundVisibility(isScrolled ? .visible : .hidden, for: .navigationBar)
        .toolbarColorScheme(appColorScheme == "light" ? .light : .dark, for: .navigationBar)
        #endif
        .background(AthensTheme.backgroundGradient.ignoresSafeArea())
        .refreshable { await store.refreshFromCloud() }
        .onReceive(store.$allUsers) { users in
            let allIds = Set(users.filter { $0.id != store.me.id }.map { $0.id })
            selectedUserIds = selectedUserIds.intersection(allIds)
        }
        .onChange(of: store.me.id) {
            includesAllTeammates = true
            selectedUserIds.removeAll()
        }
    }

    private var header: some View {
        HStack {
            Button { month = shiftMonth(month, by: -1) } label: { Image(systemName: "chevron.left") }
            .tint(AthensTheme.goldAccent)
            Spacer()
            Text(monthTitle(month)).font(.headline).foregroundColor(AthensTheme.marbleWhite)
            Spacer()
            Button { month = shiftMonth(month, by: 1) } label: { Image(systemName: "chevron.right") }
            .tint(AthensTheme.goldAccent)
        }
        .padding(.horizontal)
    }

    private var weekdayHeader: some View {
        let cal = mondayCal
        let syms = reorderedWeekdaySymbols(cal.shortWeekdaySymbols, first: cal.firstWeekday)
        return HStack(spacing: 6) {
            ForEach(syms, id: \.self) { s in
                Text(s)
                    .font(.caption)
                    .foregroundStyle(AthensTheme.marbleWhite.opacity(0.7))
                    .frame(maxWidth: .infinity)
            }
            if showWeeklyRail {
                Text("WK")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AthensTheme.marbleWhite.opacity(0.8))
                    .frame(width: 86)
            }
        }
        .padding(.horizontal, 6)
    }

    // Legend (color key) for selected other users
    private var teamLegend: some View {
        let users = nonMeUsersSorted.filter { activeOtherIds.contains($0.id) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.3.fill")
                    .foregroundStyle(AthensTheme.goldAccent)
                Text("Team Key")
                    .font(.headline)
                    .foregroundColor(AthensTheme.marbleWhite)
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(users, id: \.id) { u in
                        HStack(spacing: 6) {
                            Circle().fill(colorFromHex(u.colorHex)).frame(width: 8, height: 8)
                            Text(u.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(AthensTheme.marbleWhite)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 6)
    }

    // MARK: - Helpers

    private func monthTitle(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "LLLL yyyy"; return f.string(from: date)
    }
    private func shiftMonth(_ date: Date, by delta: Int) -> Date {
        Calendar.current.date(byAdding: .month, value: delta, to: date) ?? date
    }
    private func startOfMonth(_ date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps) ?? cal.startOfDay(for: date)
    }

    // Build days for the visible month including leading/trailing to fill whole weeks
    private func daysGrid(for date: Date) -> [Date] {
        let cal = mondayCal
        let start = startOfMonth(date)
        let range = cal.range(of: .day, in: .month, for: start) ?? 1..<31
        let firstWeekday = cal.component(.weekday, from: start)
        let lead = ((firstWeekday - cal.firstWeekday) + 7) % 7
        var grid: [Date] = []
        if lead > 0 {
            for i in stride(from: lead, to: 0, by: -1) {
                grid.append(cal.date(byAdding: .day, value: -i, to: start)!)
            }
        }
        for day in range { grid.append(cal.date(byAdding: .day, value: day - 1, to: start)!) }
        while grid.count % 7 != 0 { grid.append(cal.date(byAdding: .day, value: 1, to: grid.last!)!) }
        return grid
    }

    // Chunk the grid into week rows (7 days each)
    private func weeksGrid(for date: Date) -> [[Date]] {
        let days = daysGrid(for: date)
        var weeks: [[Date]] = []
        for i in stride(from: 0, to: days.count, by: 7) {
            weeks.append(Array(days[i..<min(i+7, days.count)]))
        }
        return weeks
    }

    private func reorderedWeekdaySymbols(_ syms: [String], first: Int) -> [String] {
        guard first > 1 else { return syms }
        let head = syms[(first-1)...]; let tail = syms[..<(first-1)]; return Array(head + tail)
    }
    private func isInCurrentMonth(_ day: Date, month: Date) -> Bool {
        let cal = Calendar.current
        let a = cal.dateComponents([.year, .month], from: day)
        let b = cal.dateComponents([.year, .month], from: month)
        return a.year == b.year && a.month == b.month
    }

    private func miles(on date: Date) -> Double {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let mine = store.workouts.filter { $0.userId == store.me.id && $0.start >= start && $0.start < end }
        return mine.reduce(0) { $0 + metersToMiles($1.distanceMeters) }
    }

    private func hasImportant(on date: Date) -> Bool {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        return store.importantDates.contains { item in
            guard let d = item.date else { return false }
            return d >= start && d < end
        }
    }

    // Compute other-runner dots for a given day (colors + overflow count)
    private func teamDotsInfo(on date: Date, limit: Int) -> (colors: [Color], extra: Int) {
        guard limit > 0 else { return ([], 0) }
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start)!

        // Unique other-user ids with a run on this day, filtered by selection
        var ids: Set<String> = []
        for w in store.workouts where w.userId != store.me.id && w.start >= start && w.start < end {
            if activeOtherIds.contains(w.userId) {
                ids.insert(w.userId)
            }
        }

        if ids.isEmpty { return ([], 0) }

        // Stable order: sort by display name
        let users = store.allUsers
            .filter { ids.contains($0.id) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        let colors = users.prefix(limit).map { colorFromHex($0.colorHex) }
        let extra = max(0, users.count - limit)
        return (colors, extra)
    }

    // MARK: - Weekly rail helpers

    private func weekStartMonday(for date: Date) -> Date {
        let cal = mondayCal
        if let wk = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)) {
            return wk
        }
        return cal.startOfDay(for: date)
    }

    private func weeklyMilesRan(forWeekStarting weekStart: Date) -> Double {
        let end = Calendar.current.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart.addingTimeInterval(7*24*3600)
        let mine = store.workouts.filter { $0.userId == store.me.id && $0.start >= weekStart && $0.start < end }
        return mine.reduce(0) { $0 + $1.miles }
    }

    private func weeklyPlanMiles(forWeekStarting weekStart: Date) -> Double {
        store.weeklyPlan(for: weekStart).requiredWeeklyMiles
    }

    @ViewBuilder
    private func DayRunsSheet(date: Date) -> some View {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start)!

        // Your runs
        let runs = store.workouts
            .filter { $0.userId == store.me.id && $0.start >= start && $0.start < end }
            .sorted { $0.start > $1.start }

        // Important items for this day
        let important = store.importantDates.filter { item in
            guard let d = item.date else { return false }
            return d >= start && d < end
        }

        NavigationStack {
            List {
                if !important.isEmpty {
                    Section("Important") {
                        ForEach(Array(important.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    Image(systemName: "calendar.badge.exclamationmark")
                                        .foregroundStyle(AthensTheme.goldAccent)
                                    Text(item.title.isEmpty ? "Untitled" : item.title)
                                        .font(.headline)
                                        .foregroundColor(AthensTheme.marbleWhite)
                                    Spacer()
                                }
                                if let d = item.date {
                                    Text(d.formatted(date: .omitted, time: .shortened))
                                        .font(.subheadline)
                                        .foregroundColor(AthensTheme.marbleWhite.opacity(0.85))
                                }
                                if let n = item.notes, !n.isEmpty {
                                    Text(n)
                                        .font(.footnote)
                                        .foregroundColor(AthensTheme.marbleWhite.opacity(0.8))
                                }
                            }
                            .padding(.vertical, 4)
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient)
                            )
                        }
                    }
                }

                Section("Your Runs") {
                    ForEach(runs) { w in
                        Group {
                            if w.source.lowercased() == "apple" || w.source.lowercased() == "strava" {
                                NavigationLink {
                                    WorkoutDetailView(workout: w)
                                } label: {
                                    runRowContent(w)
                                }
                                .buttonStyle(.plain)
                            } else {
                                runRowContent(w)
                            }
                        }
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient)
                        )
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let w = runs[index]
                            if w.isManual && w.userId == store.me.id {
                                store.deleteWorkout(id: w.id)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .navigationTitle(start.formatted(date: .abbreviated, time: .omitted))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        manualDate = start
                    } label: {
                        Label("Add Run", systemImage: "plus")
                    }
                    .tint(AthensTheme.goldAccent)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { selectedDate = nil }
                }
            }
            .background(AthensTheme.backgroundGradient.ignoresSafeArea())
            .tint(AthensTheme.goldAccent)
        }
        .presentationDetents([.medium, .large])
    }

    // Extracted row content so we can wrap conditionally in NavigationLink
    private func runRowContent(_ w: WorkoutEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(w.start.formatted(date: .omitted, time: .shortened))
                    .font(.headline)
                    .foregroundColor(AthensTheme.marbleWhite)
                Spacer()
                HStack(spacing: 6) {
                    Text(w.isManual ? "Sus Run" : w.source.capitalized)
                        .foregroundStyle(AthensTheme.marbleWhite.opacity(0.7))
                        .font(.subheadline)
                    // Only Strava shows an external deep link button
                    if w.source.lowercased() == "strava" {
                        Button {
                            openDeepLink(for: w)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .buttonStyle(.plain)
                        .tint(AthensTheme.goldAccent)
                        .accessibilityLabel("Open in Strava")
                    }
                }
            }
            HStack(spacing: 12) {
                Text(String(format: "%.2f mi", metersToMiles(w.distanceMeters)))
                Text("•")
                Text(secToHMS(w.durationSec))
                if let p = w.paceSecPerMile { Text("•"); Text(paceString(p)) }
                if let hr = w.avgHR { Text("•"); Text(String(format: "HR %.0f", hr)) }
                if let notes = w.notes, !notes.isEmpty {
                    Text("•")
                    Text(notes)
                        .font(.footnote)
                        .foregroundStyle(AthensTheme.marbleWhite.opacity(0.7))
                }
            }
            .font(.subheadline)
            .foregroundStyle(AthensTheme.marbleWhite.opacity(0.85))
        }
    }

    private func toggleUser(_ id: String) {
        if includesAllTeammates {
            selectedUserIds = Set(nonMeUsersSorted.map { $0.id })
            includesAllTeammates = false
        }
        if selectedUserIds.contains(id) {
            selectedUserIds.remove(id)
        } else {
            selectedUserIds.insert(id)
        }
        if selectedUserIds == Set(nonMeUsersSorted.map { $0.id }) {
            includesAllTeammates = true
            selectedUserIds.removeAll()
        }
    }

    private func paceString(_ sec: Double) -> String {
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%d:%02d /mi", m, s)
    }

    // MARK: - Deep link helpers

    private func openDeepLink(for w: WorkoutEntry) {
        // Match Raw Log / ThisWeek behavior: try strava activity, then web, then app home.
        guard w.source.lowercased() == "strava" else { return }
        if let id = w.stravaActivityId, let appURL = URL(string: "strava://activities/\(id)") {
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

    // MARK: - Color helpers

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

// PreferenceKey unique to this file to avoid redeclaration
private struct CalendarNavBarOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct DayCell: View {
    var date: Date
    var miles: Double
    var myDotColor: Color
    var teamDots: [Color]    // colored dots for other runners
    var extraDots: Int       // "+N" overflow
    var hasImportant: Bool
    var isCurrentMonth: Bool
    var onTap: () -> Void
    var onLongPress: () -> Void

    var body: some View {
        let cal = Calendar.current
        let day = cal.component(.day, from: date)
        VStack(spacing: 6) {
            Text("\(day)")
                .font(.body.weight(.semibold))
                .foregroundStyle(isCurrentMonth ? AthensTheme.marbleWhite : AthensTheme.marbleWhite.opacity(0.45))
                .frame(maxWidth: .infinity)

            if !teamDots.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(teamDots.enumerated()), id: \.offset) { _, c in
                        Circle().fill(c).frame(width: 5, height: 5)
                    }
                    if extraDots > 0 {
                        Text("+\(extraDots)")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(AthensTheme.marbleWhite.opacity(0.8))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.06)))
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                Spacer(minLength: 2)
            }

            if miles > 0 {
                Circle().fill(myDotColor).frame(width: 6, height: 6)
                Text(String(format: "%.1f", miles))
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(AthensTheme.marbleWhite)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(AthensTheme.goldAccent.opacity(0.18)))
            } else {
                Spacer(minLength: 4)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        // Important date indicator (terracotta diamond) top-right
        .overlay(alignment: .topTrailing) {
            if hasImportant {
                RoundedRectangle(cornerRadius: 2)
                    .fill(AthensTheme.terracotta)
                    .frame(width: 8, height: 8)
                    .rotationEffect(.degrees(45))
                    .padding(4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onLongPressGesture(minimumDuration: 0.5) { onLongPress() }
    }
}

// MARK: - Circular “pie” progress with check on completion

private struct WeekRailCell: View {
    let ran: Double
    let plan: Double

    var body: some View {
        let progress = plan > 0 ? max(0.0, min(1.0, ran / plan)) : 0.0
        let compliant = plan > 0 && ran + 0.0001 >= plan
        let fillColor = compliant ? AthensTheme.oliveGreen : AthensTheme.goldAccent

        return VStack(spacing: 8) {
            // Numeric chip
            Text("\(String(format: "%.1f", ran)) / \(String(format: "%.1f", plan))")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundColor(compliant ? AthensTheme.oliveGreen : AthensTheme.marbleWhite)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(compliant ? AthensTheme.oliveGreen.opacity(0.22) : Color.white.opacity(0.06))
                )

            // Pie progress circle (turns into green check on completion)
            ZStack {
                // Background disk and subtle border
                Circle().fill(Color.white.opacity(0.10))
                PieProgress(progress: progress)
                    .fill(fillColor.opacity(0.95))
                    .animation(.easeOut(duration: 0.3), value: progress)
                Circle().stroke(Color.white.opacity(0.18), lineWidth: 1)

                if compliant {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.white)
                        .shadow(radius: 1)
                }
            }
            .frame(width: 28, height: 28)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }
}

private struct PieProgress: Shape {
    var progress: Double // 0...1
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2.0
        let start = Angle.degrees(-90) // start at top
        let end = Angle.degrees(-90 + 360.0 * max(0.0, min(1.0, progress)))

        p.move(to: center)
        p.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        p.closeSubpath()
        return p
    }
}
