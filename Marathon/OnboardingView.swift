// OnboardingView.swift

import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var store: WorkoutStore
    @Environment(\.dismiss) private var dismiss

    enum Step { case signIn, details }
    @State private var step: Step = .signIn

    @State private var userId: String?
    @State private var displayName: String = ""
    @State private var initials: String = ""
    @State private var colorHex: String = "#1E90FF"
    @State private var teamSyncEnabled = false

    @State private var isWorking = false
    @State private var errorMessage: String?

    private let colorOptions: [String] = [
        "#FF7F50", "#1E90FF", "#32CD32", "#DA70D6", "#FFD700", "#FF4500", "#00CED1", "#8A2BE2", "#2E8B57"
    ]

    var body: some View {
        NavigationStack {
            Form {
                switch step {
                case .signIn:
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Create your profile")
                                .font(.headline)
                            Text("Creating a profile stores your display name, initials, color tag, and account-link record in the experimental CloudKit public database. Team workout sharing is optional and explained before you turn it on.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            Task { await signIn() }
                        } label: {
                            HStack {
                                if isWorking { ProgressView().padding(.trailing, 6) }
                                Text("Sign in with Apple")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking)
                        if let err = errorMessage {
                            Text(err).foregroundStyle(.red).font(.footnote)
                        }
                    }

                case .details:
                    Section("Profile") {
                        TextField("Display Name", text: $displayName)
                        TextField("Initials", text: $initials)
                        if displayName.isEmpty || initials.isEmpty {
                            Text("Please fill both name and initials.")
                                .font(.footnote).foregroundStyle(.red)
                        }
                    }

                    Section("Color Tag") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(colorOptions, id: \.self) { hex in
                                    ZStack {
                                        Circle()
                                            .fill(colorFromHex(hex))
                                            .frame(width: 32, height: 32)
                                            .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                                        if hex == colorHex {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.white)
                                                .shadow(radius: 2)
                                        }
                                    }
                                    .onTapGesture { colorHex = hex }
                                }
                            }
                        }
                    }

                    Section("Optional team sync") {
                        Toggle("Share imported and manual workouts", isOn: $teamSyncEnabled)
                        Text("This toggle controls only automatic workout posts. When enabled, imported and manual workouts from the configured history window may be posted to the experimental CloudKit public team feed. Legacy records can include exact start/end times, distance, duration, pace, source, run type, manual flag, notes, average/resting heart rate, zone totals, and record/user identifiers. Route coordinates are not newly uploaded. You can turn this off later; it does not delete records already shared.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let err = errorMessage {
                        Section { Text(err).foregroundStyle(.red).font(.footnote) }
                    }
                }
            }
            .navigationTitle("Welcome")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if step == .details {
                        Button("Continue") {
                            Task { await finalizeProfile() }
                        }
                        .disabled(isWorking || displayName.trimmingCharacters(in: .whitespaces).isEmpty || initials.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func signIn() async {
        await MainActor.run {
            isWorking = true
            errorMessage = nil
        }
        do {
            let (uid, nameOpt, initialsOpt) = try await SIWAAuthManager.shared.signIn()
            await MainActor.run {
                self.userId = uid
                if let name = nameOpt, !name.isEmpty {
                    self.displayName = name
                }
                if let ini = initialsOpt, !ini.isEmpty {
                    self.initials = ini
                } else if !self.displayName.isEmpty {
                    self.initials = defaultInitials(from: self.displayName)
                }
                self.step = .details
                self.isWorking = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isWorking = false
            }
        }
    }

    private func finalizeProfile() async {
        guard let uid = userId else { return }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let ini = initials.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !name.isEmpty, !ini.isEmpty else { return }

        let profile = UserProfile(id: uid, displayName: name, initials: ini, colorHex: colorHex)

        await MainActor.run {
            isWorking = true
            errorMessage = nil
        }
        do {
            try await CloudKitManager.shared.upsertUser(profile)

            // Set as current user immediately
            await MainActor.run {
                store.setCurrentUser(profile)
            }

            // Keep team sharing opt-in. Local HealthKit import still runs below,
            // while CloudKit posting is enabled only when this choice is on.
            await store.setTeamSyncEnabled(teamSyncEnabled)

            // Kick off initial Health sync in the background so their runs (with avg HR)
            // are saved locally; opted-in team sync posts them to CloudKit.
            Task.detached {
                await store.syncMyHealthRunsAfterLogin()
            }

            await MainActor.run {
                isWorking = false
                dismiss()
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isWorking = false
            }
        }
    }

    private func defaultInitials(from name: String) -> String {
        let comps = name.split(separator: " ")
        if comps.count >= 2 {
            let a = comps[0].first.map(String.init) ?? ""
            let b = comps[1].first.map(String.init) ?? ""
            return (a + b).uppercased()
        } else {
            return String(name.prefix(2)).uppercased()
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
