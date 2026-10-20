//
//  MasterPlanView.swift
//  Marathon
//
//  Created by Marcus Price on 11/12/25.
//

import SwiftUI

struct MasterPlanView: View {
    @EnvironmentObject var store: WorkoutStore
    @AppStorage("appColorScheme") private var appColorScheme: String = "dark"
    @State private var editingWeek: Date? = nil
    @State private var draft: PlanSplit = PlanSplit(recovery: 2, tempo: 3.1, long: 3.1, note: nil)

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                progressCard

                ForEach(weeksUntilRace(), id: \.self) { weekStart in
                    weekCard(for: weekStart)
                }
            }
            .padding()
        }
        .navigationTitle("Master Plan")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding<Bool>(
            get: { editingWeek != nil },
            set: { if !$0 { editingWeek = nil } }
        )) {
            if let week = editingWeek {
                PlanEditorSheet(weekStart: week,
                                split: Binding(get: { store.weeklyPlan(for: week).suggested },
                                               set: { _ in }),
                                initial: store.planOverrides[week] ?? store.weeklyPlan(for: week).suggested,
                                onSave: { newSplit in
                                    store.setPlanOverride(for: week, split: newSplit)
                                },
                                onReset: {
                                    store.setPlanOverride(for: week, split: nil)
                                })
                .presentationDetents([.medium])
            }
        }
        .background(AthensTheme.backgroundGradient.ignoresSafeArea())
    }

    // MARK: - Cards

    private var progressCard: some View {
        let today = Date()
        let start = mondayOfWeek(for: store.settings.startDate)
        let race = raceDate()
        let total = max(1, race.timeIntervalSince(start))
        let done = max(0, min(total, today.timeIntervalSince(start)))
        let pct = done / total

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Road to Race Day")
                    .font(.headline)
                    .foregroundColor(AthensTheme.marbleWhite)
                Spacer()
                Text(race.formatted(date: .abbreviated, time: .omitted))
                    .foregroundColor(AthensTheme.marbleWhite.opacity(0.9))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 8).fill(AthensTheme.goldAccent.opacity(0.9))
                        .frame(width: CGFloat(pct) * geo.size.width)
                }
            }
            .frame(height: 10)
            HStack {
                Text(String(format: "%.0f%% complete", pct * 100))
                    .font(.caption)
                    .foregroundColor(AthensTheme.marbleWhite.opacity(0.9))
                Spacer()
                Text("Start: \(start.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundColor(AthensTheme.marbleWhite.opacity(0.7))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(AthensTheme.cardGradient))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 6)
    }

    private func weekCard(for weekStart: Date) -> some View {
        let plan = store.weeklyPlan(for: weekStart)
        let split = plan.suggested
        let totalMiles = plan.requiredWeeklyMiles
        let canEdit = store.canEditTeamPlan

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(weekStart.formatted(date: .abbreviated, time: .omitted))
                    .font(.headline)
                    .foregroundColor(AthensTheme.marbleWhite)
                Spacer()
                // Plain total miles text in the top-right (replacing the badge)
                Text(String(format: "%.1f mi", totalMiles))
                    .font(.headline.monospacedDigit())
                    .foregroundColor(AthensTheme.marbleWhite)

                if canEdit {
                    Button {
                        let wk = mondayOfWeek(for: weekStart)
                        editingWeek = wk
                        draft = split
                    } label: {
                        Image(systemName: "pencil").foregroundStyle(AthensTheme.goldAccent)
                    }
                    .buttonStyle(.plain)
                }
            }

            Rectangle().fill(AthensTheme.goldAccent.opacity(0.35)).frame(height: 1)

            HStack(spacing: 10) {
                pill(label: "Rec", miles: split.recovery, color: AthensTheme.oliveGreen)
                pill(label: "Tmp", miles: split.tempo, color: AthensTheme.terracotta)
                pill(label: "Long", miles: split.long, color: AthensTheme.goldAccent)
            }

            if let note = split.note, !note.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(AthensTheme.goldAccent)
                    Text(note)
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(AthensTheme.marbleWhite.opacity(0.9))
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(AthensTheme.cardGradient))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 6)
    }

    // MARK: - Helpers

    private func raceDate() -> Date {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 9
        return Calendar.current.date(from: c) ?? Date()
    }

    private func weeksBetween(_ a: Date, _ b: Date) -> Int {
        max(0, Int((b.timeIntervalSince(a) / (7 * 24 * 3600)).rounded(.down)))
    }

    private func weeksUntilRace() -> [Date] {
        let cal = Calendar.current
        let start = mondayOfWeek(for: Date().addingTimeInterval(7 * 24 * 3600)) // next Monday
        let end = mondayOfWeek(for: raceDate())
        var weeks: [Date] = []
        var cur = start
        while cur <= end {
            weeks.append(cur)
            cur = cal.date(byAdding: .day, value: 7, to: cur) ?? cur.addingTimeInterval(7 * 24 * 3600)
        }
        return weeks
    }

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
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }
}

private struct PlanEditorSheet: View {
    let weekStart: Date
    @Binding var split: PlanSplit // unused live binding; kept for parity
    @State var draft: PlanSplit
    var onSave: (PlanSplit) -> Void
    var onReset: () -> Void

    init(weekStart: Date,
         split: Binding<PlanSplit>,
         initial: PlanSplit,
         onSave: @escaping (PlanSplit) -> Void,
         onReset: @escaping () -> Void) {
        self.weekStart = weekStart
        self._split = split
        self._draft = State(initialValue: initial)
        self.onSave = onSave
        self.onReset = onReset
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Week") {
                    Text(weekStart.formatted(date: .abbreviated, time: .omitted))
                        .foregroundStyle(.secondary)
                }
                Section("Miles") {
                    Stepper(value: $draft.recovery, in: 0...50, step: 0.1) {
                        HStack {
                            Text("Recovery")
                            Spacer()
                            Text(String(format: "%.1f", draft.recovery)).monospacedDigit()
                        }
                    }
                    Stepper(value: $draft.tempo, in: 0...50, step: 0.1) {
                        HStack {
                            Text("Tempo")
                            Spacer()
                            Text(String(format: "%.1f", draft.tempo)).monospacedDigit()
                        }
                    }
                    Stepper(value: $draft.long, in: 0...50, step: 0.1) {
                        HStack {
                            Text("Long")
                            Spacer()
                            Text(String(format: "%.1f", draft.long)).monospacedDigit()
                        }
                    }
                    HStack {
                        Text("Total")
                        Spacer()
                        Text(String(format: "%.1f", draft.recovery + draft.tempo + draft.long))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Note (optional)") {
                    TextField("e.g., Consolidation, Taper 1, Specific...", text: Binding(
                        get: { draft.note ?? "" },
                        set: { draft.note = $0.isEmpty ? nil : $0 }
                    ))
                }
                if draft.recovery + draft.tempo + draft.long <= 0 {
                    Text("Total must be > 0").foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("Edit Week")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Reset") { onReset(); dismiss() }
                        .foregroundStyle(.red)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft)
                        dismiss()
                    }.disabled(draft.recovery + draft.tempo + draft.long <= 0)
                }
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
}
