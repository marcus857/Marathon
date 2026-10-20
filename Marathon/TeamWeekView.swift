// TeamWeekView.swift
import SwiftUI
import Combine

struct TeamWeekView: View {
    @EnvironmentObject var store: WorkoutStore
    @AppStorage("appColorScheme") private var appColorScheme: String = "dark"

    @State private var weekOffset: Int = 0
    @State private var isScrolled = false

    // People filter (multi-select); default to all users when view appears/updates
    @State private var selectedUserIds: Set<String> = []
    @State private var includesAllMembers = true

    private var currentWeekStart: Date { mondayOfWeek(for: Date()) }
    private var selectedWeekStart: Date {
        Calendar.current.date(byAdding: .day, value: -7 * weekOffset, to: currentWeekStart) ?? currentWeekStart
    }

    private var allUsersSorted: [UserProfile] {
        store.allUsers.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var filteredUsers: [UserProfile] {
        guard !includesAllMembers else { return allUsersSorted }
        return allUsersSorted.filter { selectedUserIds.contains($0.id) }
    }

    // Precompute rows to simplify ForEach and help the type-checker
    private var progressRows: [ProgressRow] {
        filteredUsers.map { user in
            ProgressRow(
                user: user,
                summary: store.weekSummary(forWeekStart: selectedWeekStart, userId: user.id)
            )
        }
    }

    var body: some View {
        List {
            // Invisible probe row to track scroll offset (takes no visible space)
            Section {
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: TWNavBarOffsetKey.self, value: proxy.frame(in: .named("twScroll")).minY)
                }
                .frame(height: 0)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            Section {
                weekNavBar
            }
            .listRowBackground(RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient))

            Section("Progress") {
                if progressRows.isEmpty {
                    Text("No people selected")
                        .font(.footnote)
                        .foregroundStyle(AthensTheme.marbleWhite.opacity(0.8))
                        .listRowBackground(RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient))
                } else {
                    ForEach(progressRows) { row in
                        userRow(user: row.user, summary: row.summary)
                            .listRowBackground(RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient))
                    }
                }
            }
        }
        .coordinateSpace(name: "twScroll")
        .onPreferenceChange(TWNavBarOffsetKey.self) { y in
            withAnimation(.easeInOut(duration: 0.2)) { isScrolled = y < -2 }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Team Week")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // People filter menu (sleek, compact)
            ToolbarItem(placement: .topBarTrailing) {
                peopleFilterMenu
            }
        }
        #if os(iOS)
        .toolbarBackground(isScrolled ? AthensTheme.midnightBlue : .clear, for: .navigationBar)
        .toolbarBackgroundVisibility(isScrolled ? .visible : .hidden, for: .navigationBar)
        .toolbarColorScheme(appColorScheme == "light" ? .light : .dark, for: .navigationBar)
        #endif
        .background(AthensTheme.backgroundGradient.ignoresSafeArea())
        .task { await store.refreshFromCloud(force: false) }
        .refreshable { await store.refreshFromCloud() }
        // Keep selection in sync when the team changes (no Equatable required)
        .onReceive(store.$allUsers) { users in
            let currentAll = Set(users.map { $0.id })
            selectedUserIds = selectedUserIds.intersection(currentAll)
        }
        .onChange(of: store.me.id) {
            includesAllMembers = true
            selectedUserIds.removeAll()
        }
    }

    // Extracted to help the type-checker
    private var peopleFilterMenu: some View {
        let allSelected = includesAllMembers && !allUsersSorted.isEmpty
        let hasMe = allUsersSorted.contains(where: { $0.id == store.me.id })

        return Menu {
            Section("People") {
                // Select All / Clear All
                Button {
                    if allSelected {
                        includesAllMembers = false
                        selectedUserIds.removeAll()
                    } else {
                        includesAllMembers = true
                        selectedUserIds.removeAll()
                    }
                } label: {
                    SwiftUI.Label(allSelected ? "Clear All" : "Select All",
                                  systemImage: allSelected ? "minus.circle" : "checkmark.circle")
                }

                // Per-user toggles
                ForEach(allUsersSorted, id: \.id) { u in
                    Button {
                        toggleUser(u.id)
                    } label: {
                        SwiftUI.Label(u.displayName,
                                      systemImage: includesAllMembers || selectedUserIds.contains(u.id) ? "checkmark.circle.fill" : "circle")
                    }
                }
            }

            // Quick scope: Only Me (only if I'm on the team list)
            if hasMe {
                Section {
                    Button {
                        includesAllMembers = false
                        selectedUserIds = [store.me.id]
                    } label: {
                        SwiftUI.Label("Only Me", systemImage: "person.fill.checkmark")
                    }
                }
            }
        } label: {
            Image(systemName: includesAllMembers ? "person.3" : "line.3.horizontal.decrease.circle")
        }
        .tint(AthensTheme.goldAccent)
        .accessibilityLabel("Filter People")
    }

    private func toggleUser(_ id: String) {
        if includesAllMembers {
            selectedUserIds = Set(allUsersSorted.map { $0.id })
            includesAllMembers = false
        }
        if selectedUserIds.contains(id) {
            selectedUserIds.remove(id)
        } else {
            selectedUserIds.insert(id)
        }
        if selectedUserIds == Set(allUsersSorted.map { $0.id }) {
            includesAllMembers = true
            selectedUserIds.removeAll()
        }
    }

    private var weekNavBar: some View {
        HStack {
            Button { weekOffset += 1 } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .tint(AthensTheme.goldAccent)

            Text("Week of \(selectedWeekStart.formatted(date: .abbreviated, time: .omitted))")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(AthensTheme.marbleWhite)
                .frame(maxWidth: .infinity)
                .onTapGesture { withAnimation { weekOffset = 0 } }

            Button {
                if weekOffset > 0 { weekOffset -= 1 }
            } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .tint(AthensTheme.goldAccent)
            .disabled(weekOffset == 0)
            .opacity(weekOffset == 0 ? 0.4 : 1.0)
        }
    }

    private func userRow(user: UserProfile, summary: WeekSummary) -> some View {
        let target = summary.requiredWeeklyMiles
        let done = summary.actualMiles
        let progress = target > 0 ? max(0.0, min(1.0, done / target)) : 0
        let detail = "\(summary.actualRuns)/\(summary.requiredRuns) runs • \(String(format: "%.1f / %.1f mi", done, target))"

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                avatar(for: user)
                VStack(alignment: .leading, spacing: 2) {
                    Text(user.displayName)
                        .font(.headline)
                        .foregroundColor(AthensTheme.marbleWhite)
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AthensTheme.marbleWhite.opacity(0.85))
                }
                Spacer()
                if summary.compliant {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AthensTheme.goldAccent)
                }
            }
            ProgressCapsule(progress: progress, fill: AthensTheme.goldAccent.opacity(0.9))
                .frame(height: 6)
        }
        .padding(.vertical, 8)
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
}

// Light wrapper to help type-checker in ForEach
private struct ProgressRow: Identifiable {
    let user: UserProfile
    let summary: WeekSummary
    var id: String { user.id }
}

private struct ProgressCapsule: View {
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

private struct TWNavBarOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
