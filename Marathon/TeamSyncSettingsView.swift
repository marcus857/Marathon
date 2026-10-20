import SwiftUI

/// Controls the user's explicit consent for future team-feed posts.
/// The current feed uses CloudKit's public database, so this is intentionally
/// presented as sharing rather than as a private sync setting.
struct TeamSyncSettingsView: View {
    @EnvironmentObject private var store: WorkoutStore
    @State private var isSaving = false

    private var teamSyncBinding: Binding<Bool> {
        Binding(
            get: { store.isTeamSyncEnabled },
            set: { enabled in
                guard store.hasActiveProfile, !isSaving else { return }
                isSaving = true
                Task {
                    await store.setTeamSyncEnabled(enabled)
                    await MainActor.run { isSaving = false }
                }
            }
        )
    }

    var body: some View {
        Form {
            Section("Team feed") {
                Toggle("Share imported and manual workouts", isOn: teamSyncBinding)
                    .disabled(!store.hasActiveProfile || isSaving)

                if isSaving {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Saving preference…")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            Section("What this means") {
                Text("This toggle controls only automatic workout posts. When enabled, imported and manual workouts from the configured history window can be posted to the experimental CloudKit public team feed. Legacy records can include exact start/end times, distance, duration, pace, source, run type, manual flag, notes, average/resting heart rate, zone totals, and record/user identifiers. Route coordinates are not newly uploaded.")
                Text("Turning this off stops future automatic posts. It does not delete records shared earlier; teamId labels the feed and is not an access-control boundary.")
            }

            Section("Privacy") {
                Text("This is not a private-database or CKShare implementation. Do not enable it with sensitive health or location data.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Team Sync")
        .navigationBarTitleDisplayMode(.inline)
    }
}
