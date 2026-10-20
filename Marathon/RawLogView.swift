//
//  RawLogView.swift
//  Marathon
//
//  Created by Marcus Price on 11/12/25.
//

import SwiftUI

struct RawLogView: View {
    @EnvironmentObject var store: WorkoutStore
    @AppStorage("appColorScheme") private var appColorScheme: String = "dark"
    @Environment(\.openURL) private var openURL

    // Toolbar background behavior
    @State private var isScrolled = false

    // Search state
    @State private var showingSearch = false
    @State private var searchStart: Date = Date()
    @State private var searchEnd: Date = Date()
    @State private var activeSearchRange: (start: Date, end: Date)? = nil

    // Add manual run sheet
    @State private var showingAddManual = false

    // iCloud account identifier (CloudKit user record name)
    @State private var iCloudRecordName: String = ""

    // Only active user's runs
    private var rows: [WorkoutEntry] {
        store.workouts
            .filter { $0.userId == store.me.id }
            .sorted { $0.start > $1.start }
    }

    private var filteredRows: [WorkoutEntry] {
        guard let range = activeSearchRange else { return rows }
        let cal = Calendar.current
        let startDay = cal.startOfDay(for: range.start)
        let endNextDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: range.end)) ?? range.end.addingTimeInterval(24*3600)
        return rows.filter { $0.start >= startDay && $0.start < endNextDay }
    }

    var body: some View {
        List {
            // Active user header
            Section {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(colorFromHex(store.me.colorHex))
                            .frame(width: 28, height: 28)
                        Text(store.me.initials)
                            .font(.caption2.weight(.bold))
                            .foregroundColor(.white)
                    }
                    .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Active User")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AthensTheme.marbleWhite.opacity(0.75))
                        Text(store.me.displayName)
                            .font(.headline)
                            .foregroundColor(AthensTheme.marbleWhite)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "icloud")
                            .foregroundStyle(AthensTheme.goldAccent)
                        Text(iCloudRecordName.isEmpty ? "iCloud: Not signed in" : iCloudRecordName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AthensTheme.marbleWhite.opacity(0.85))
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 2)
            }
            .listRowBackground(
                RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient)
            )

            if let range = activeSearchRange {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Text(range.start.formatted(date: .abbreviated, time: .omitted))
                            .font(.headline)
                            .foregroundColor(AthensTheme.marbleWhite)
                        Text("–")
                            .foregroundColor(AthensTheme.marbleWhite.opacity(0.8))
                        Text(range.end.formatted(date: .abbreviated, time: .omitted))
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
                    .padding(.vertical, 2)
                }
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient)
                )
            }

            ForEach(filteredRows.indices, id: \.self) { i in
                let w = filteredRows[i]

                Group {
                    if w.source.lowercased() == "apple" {
                        NavigationLink {
                            WorkoutDetailView(workout: w)
                        } label: {
                            rowContent(w, showStravaButton: false)
                        }
                        .buttonStyle(.plain)
                    } else if w.source.lowercased() == "strava" {
                        NavigationLink {
                            WorkoutDetailView(workout: w)
                        } label: {
                            rowContent(w, showStravaButton: true)
                        }
                        .buttonStyle(.plain)
                    } else {
                        rowContent(w, showStravaButton: false)
                    }
                }
                // Attach probe to the first real row so it doesn't occupy space
                .background(
                    i == 0 ?
                    AnyView(
                        GeometryReader { proxy in
                            Color.clear
                                .preference(key: RawLogNavBarOffsetKey.self, value: proxy.frame(in: .named("rawLogScroll")).minY)
                        }
                    ) : AnyView(EmptyView())
                )
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient)
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

            if filteredRows.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Text("No runs for \(store.me.displayName)")
                            .font(.headline)
                            .foregroundColor(AthensTheme.marbleWhite)
                        Text("Adjust the date range or add a manual run.")
                            .font(.footnote)
                            .foregroundStyle(AthensTheme.marbleWhite.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
                }
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient)
                )
            }
        }
        .coordinateSpace(name: "rawLogScroll")
        .onPreferenceChange(RawLogNavBarOffsetKey.self) { y in
            withAnimation(.easeInOut(duration: 0.2)) {
                isScrolled = y < -2
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        #else
        .listStyle(.inset) // macOS-supported
        #endif
        .navigationTitle("Raw Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    let cal = Calendar.current
                    let today = cal.startOfDay(for: Date())
                    // Default to last 30 days
                    searchStart = cal.date(byAdding: .day, value: -29, to: today) ?? today
                    searchEnd = today
                    showingSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .tint(AthensTheme.goldAccent)
                .accessibilityLabel("Search by Date Range")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddManual = true
                } label: {
                    Image(systemName: "plus")
                }
                .tint(AthensTheme.goldAccent)
                .accessibilityLabel("Add Manual Run")
            }
        }
        #if os(iOS)
        // Transparent at top, dynamic blue when scrolled
        .toolbarBackground(isScrolled ? AthensTheme.midnightBlue : .clear, for: .navigationBar)
        .toolbarBackgroundVisibility(isScrolled ? .visible : .hidden, for: .navigationBar)
        .toolbarColorScheme(appColorScheme == "light" ? .light : .dark, for: .navigationBar)
        #endif
        .background(AthensTheme.backgroundGradient.ignoresSafeArea())
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
                        Button("Last 7 Days") {
                            let cal = Calendar.current
                            let today = cal.startOfDay(for: Date())
                            searchStart = cal.date(byAdding: .day, value: -6, to: today) ?? today
                            searchEnd = today
                        }
                        Button("Last 30 Days") {
                            let cal = Calendar.current
                            let today = cal.startOfDay(for: Date())
                            searchStart = cal.date(byAdding: .day, value: -29, to: today) ?? today
                            searchEnd = today
                        }
                        Button("This Month") {
                            let cal = Calendar.current
                            let today = cal.startOfDay(for: Date())
                            let comps = cal.dateComponents([.year, .month], from: today)
                            let startOfMonth = cal.date(from: comps) ?? today
                            searchStart = startOfMonth
                            searchEnd = today
                        }
                        Button("Season (since Nov 1)") {
                            let cal = Calendar.current
                            let today = cal.startOfDay(for: Date())
                            var comps = cal.dateComponents([.year], from: today)
                            comps.month = 11; comps.day = 1
                            let nov1ThisYear = cal.date(from: comps) ?? today
                            if today >= nov1ThisYear {
                                searchStart = nov1ThisYear
                            } else {
                                searchStart = cal.date(byAdding: .year, value: -1, to: nov1ThisYear) ?? nov1ThisYear
                            }
                            searchEnd = today
                        }
                        Button("All Logged Runs") {
                            if let minDate = rows.map(\.start).min(),
                               let maxDate = rows.map(\.start).max() {
                                let cal = Calendar.current
                                searchStart = cal.startOfDay(for: minDate)
                                searchEnd = cal.startOfDay(for: maxDate)
                            }
                        }
                    }
                }
                .navigationTitle("Search Raw Log")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showingSearch = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Show") {
                            // Normalize to start-of-day bounds
                            let cal = Calendar.current
                            let s = cal.startOfDay(for: searchStart)
                            let e = cal.startOfDay(for: searchEnd)
                            if s <= e {
                                activeSearchRange = (start: s, end: e)
                            }
                            showingSearch = false
                        }
                        .disabled(Calendar.current.startOfDay(for: $searchStart.wrappedValue) > Calendar.current.startOfDay(for: $searchEnd.wrappedValue))
                    }
                }
            }
        }
        .sheet(isPresented: $showingAddManual) {
            NavigationStack {
                ManualRunForm(initialDate: Date())
            }
        }
        .task {
            // Fetch and show the unique iCloud user record name (if available)
            let id = await CloudKitManager.shared.currentUserRecordName()
            await MainActor.run {
                self.iCloudRecordName = id ?? ""
            }
        }
    }

    // Extracted row content so we can reuse for Apple/Strava/Other
    private func rowContent(_ w: WorkoutEntry, showStravaButton: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(w.start.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                    .foregroundColor(AthensTheme.marbleWhite)
                Spacer()
                HStack(spacing: 8) {
                    Text(w.isManual ? "Sus Run" : w.source.capitalized)
                        .font(.subheadline)
                        .foregroundStyle(AthensTheme.marbleWhite.opacity(0.7))

                    if showStravaButton {
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
                if let pace = w.paceSecPerMile {
                    Text("•"); Text(paceString(pace))
                }
                if let hr = w.avgHR {
                    Text("•"); Text(String(format: "HR %.0f", hr))
                }
                Text("•")
                Text(w.runType.rawValue.capitalized)
            }
            .font(.subheadline)
            .foregroundStyle(AthensTheme.marbleWhite.opacity(0.85))

            if let notes = w.notes, !notes.isEmpty {
                Text(notes)
                    .font(.footnote)
                    .foregroundStyle(AthensTheme.marbleWhite.opacity(0.7))
            }
        }
    }

    private func paceString(_ sec: Double) -> String {
        let m = Int(sec) / 60
        let s = Int(sec) % 60
        return String(format: "%d:%02d /mi", m, s)
    }

    // MARK: - Deep link helpers (Strava only)
    private func openDeepLink(for w: WorkoutEntry) {
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

    // Color helper for avatar
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
private struct RawLogNavBarOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

