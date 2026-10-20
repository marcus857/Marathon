import SwiftUI

struct AppTabView: View {
    @EnvironmentObject var store: WorkoutStore
    @State private var selectedTab: Tab = .home

    private enum Tab: Hashable { case home, week, calendar, plan, team }
    private struct RefreshContext: Equatable {
        let tab: Tab
        let userID: String
    }

    private var needsOnboarding: Bool {
        store.needsOnboarding
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { HomeView() }
                .tag(Tab.home)
                .tabItem {
                    Image(systemName: "house.fill")
                    Text("Home")
                }

            NavigationStack { ThisWeekView() }
                .tag(Tab.week)
                .tabItem {
                    Image(systemName: "figure.run")
                    Text("This Week")
                }

            NavigationStack { CalendarView() }
                .tag(Tab.calendar)
                .tabItem {
                    Image(systemName: "calendar")
                    Text("Calendar")
                }

            NavigationStack { PlanPreviewView() }
                .tag(Tab.plan)
                .tabItem {
                    Image(systemName: "calendar.badge.clock")
                    Text("Plan")
                }

            NavigationStack { LeaderboardView() }
                .tag(Tab.team)
                .tabItem {
                    Image(systemName: "person.3.fill")
                    Text("Team")
                }
        }
        .tint(AthensTheme.goldAccent)
        .background(AthensTheme.backgroundGradient.ignoresSafeArea())
        .task(id: RefreshContext(tab: selectedTab, userID: store.me.id)) {
            await store.refreshFromCloud(force: false)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let error = store.teamSyncError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(AthensTheme.marbleWhite)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(AthensTheme.midnightBlue)
            }
        }
        // Show onboarding until a real user is set (store.setCurrentUser in OnboardingView).
        .sheet(
            isPresented: Binding(
                get: { needsOnboarding },
                set: { _ in }
            )
        ) {
            OnboardingView()
                .environmentObject(store)
                .interactiveDismissDisabled(true) // prevent skipping before creating a profile
        }
    }
}
