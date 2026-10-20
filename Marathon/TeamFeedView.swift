import SwiftUI

struct TeamFeedView: View {
    @EnvironmentObject var store: WorkoutStore
    @AppStorage("appColorScheme") private var appColorScheme: String = "dark"
    @AppStorage("teamFeedIncludeMineDebug") private var teamFeedIncludeMineDebug: Bool = true

    @State private var isScrolled = false
    // nil = All teammates; otherwise filter to a single teammate id
    @State private var selectedUserId: String? = nil

    // Teammates (exclude me), sorted by name
    private var teammates: [UserProfile] {
        store.allUsers
            .filter { $0.id != store.me.id }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // FEED: Cloud-backed shared feed; optional "include mine" testing mode + teammate filter.
    private var filteredWorkouts: [WorkoutEntry] {
        let shared = store.cloudTeamFeed
        let base = teamFeedIncludeMineDebug ? shared : shared.filter { $0.userId != store.me.id }
        if let id = selectedUserId {
            return base.filter { $0.userId == id }.sorted { $0.start > $1.start }
        }
        return latestPerUser(base)
    }

    private var filterTitle: String {
        if let id = selectedUserId, let u = teammates.first(where: { $0.id == id }) {
            return "\(u.displayName) - All Runs"
        }
        return "Latest Per Teammate"
    }

    private func latestPerUser(_ rows: [WorkoutEntry]) -> [WorkoutEntry] {
        var latestByUser: [String: WorkoutEntry] = [:]
        latestByUser.reserveCapacity(rows.count)
        for row in rows {
            if let existing = latestByUser[row.userId] {
                if row.start > existing.start {
                    latestByUser[row.userId] = row
                }
            } else {
                latestByUser[row.userId] = row
            }
        }
        return latestByUser.values.sorted { $0.start > $1.start }
    }

    var body: some View {
        List {
            if let refreshedAt = store.teamFeedLastRefreshAt {
                Section {
                    HStack {
                        if store.isTeamFeedLoading { ProgressView() }
                        Text("Last synced \(refreshedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // Invisible probe to track scroll offset
            Section {
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: TFNavBarOffsetKey.self, value: proxy.frame(in: .named("teamFeedScroll")).minY)
                }
                .frame(height: 0)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            if filteredWorkouts.isEmpty && store.isTeamFeedLoading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Syncing Cloud team feed...")
                            .font(.footnote)
                            .foregroundStyle(AthensTheme.marbleWhite.opacity(0.85))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                }
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient)
                )
            } else if filteredWorkouts.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Text("No runs")
                            .font(.headline)
                            .foregroundColor(AthensTheme.marbleWhite)
                        Text("No shared runs in CloudKit yet.")
                            .font(.footnote)
                            .foregroundStyle(AthensTheme.marbleWhite.opacity(0.8))

                        #if DEBUG
                        NavigationLink {
                            TeamDebugRawLogView()
                        } label: {
                            Label("Open Raw Team Log", systemImage: "list.bullet.rectangle")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AthensTheme.goldAccent)
                        .accessibilityLabel("Open Raw Team Log")
                        .padding(.top, 6)
                        #endif
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
                }
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient)
                )
            } else {
                Section(header: Text(filterTitle)) {
                    if selectedUserId != nil && store.isTeamFeedLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading full run history...")
                                .font(.footnote)
                                .foregroundStyle(AthensTheme.marbleWhite.opacity(0.85))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                    }

                    ForEach(filteredWorkouts) { w in
                        if let user = store.allUsers.first(where: { $0.id == w.userId }) {
                            NavigationLink {
                                WorkoutDetailView(workout: w)
                            } label: {
                                TeamFeedRow(workout: w, user: user, meId: store.me.id)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient)
                            )
                        } else {
                            NavigationLink {
                                WorkoutDetailView(workout: w)
                            } label: {
                                TeamFeedFallbackRow(
                                    workout: w,
                                    state: store.allUsers.isEmpty ? .resolvingProfile : .missingProfile
                                )
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient)
                            )
                        }
                    }
                }
            }
        }
        .coordinateSpace(name: "teamFeedScroll")
        .onPreferenceChange(TFNavBarOffsetKey.self) { y in
            withAnimation(.easeInOut(duration: 0.2)) { isScrolled = y < -2 }
        }
        .task { await store.refreshFromCloud(force: false) }
        .refreshable { await store.refreshFromCloud() }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        #else
        .listStyle(.inset)
        #endif
        .navigationTitle("Team Feed")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    TeamSyncSettingsView()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .tint(AthensTheme.goldAccent)
                .accessibilityLabel("Team Sync Settings")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await store.refreshFromCloud() }
                } label: {
                    if store.isTeamFeedLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .tint(AthensTheme.goldAccent)
                .accessibilityLabel("Refresh Team Feed")
                .disabled(store.isTeamFeedLoading)
            }

            // Filter menu (others only)
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        selectedUserId = nil
                    } label: {
                        Label("All Teammates", systemImage: selectedUserId == nil ? "checkmark.circle.fill" : "circle")
                    }
                    if !teammates.isEmpty {
                        Section("Teammate") {
                            ForEach(teammates, id: \.id) { u in
                                Button {
                                    selectedUserId = u.id
                                } label: {
                                    Label(u.displayName,
                                          systemImage: selectedUserId == u.id ? "checkmark.circle.fill" : "circle")
                                }
                            }
                        }
                    }
                    #if DEBUG
                    Section("Testing") {
                        Button {
                            teamFeedIncludeMineDebug.toggle()
                        } label: {
                            Label("Include My Shared Run",
                                  systemImage: teamFeedIncludeMineDebug ? "checkmark.circle.fill" : "circle")
                        }
                        Button("Refresh Cloud Feed") {
                            Task { await store.refreshFromCloud() }
                        }
                    }
                    #endif
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .tint(AthensTheme.goldAccent)
                .accessibilityLabel("Filter Teammate")
            }

            #if DEBUG
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    TeamDebugRawLogView()
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                }
                .tint(AthensTheme.goldAccent)
                .accessibilityLabel("Raw Log (Debug)")
            }
            #endif
        }
        #if os(iOS)
        .toolbarBackground(isScrolled ? AthensTheme.midnightBlue : .clear, for: .navigationBar)
        .toolbarBackgroundVisibility(isScrolled ? .visible : .hidden, for: .navigationBar)
        .toolbarColorScheme(appColorScheme == "light" ? .light : .dark, for: .navigationBar)
        #endif
        .background(AthensTheme.backgroundGradient.ignoresSafeArea())
        .onReceive(store.$allUsers) { users in
            // Keep selection valid if team changes
            if let sel = selectedUserId, !users.contains(where: { $0.id == sel && $0.id != store.me.id }) {
                selectedUserId = nil
            }
        }
        .onChange(of: store.me.id) { selectedUserId = nil }
    }
}

private struct TFNavBarOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
