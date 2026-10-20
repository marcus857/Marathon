//
//  ManualRunForm.swift
//  Marathon
//
//  Created by Marcus Price on 11/12/25.
//


//
//  ManualRunForm.swift
//  Marathon
//

import SwiftUI

struct ManualRunForm: View {
    @EnvironmentObject var store: WorkoutStore
    @Environment(\.dismiss) private var dismiss

    var initialDate: Date

    @State private var date: Date
    @State private var distanceMiles: Double = 3.10
    @State private var hours: Int = 0
    @State private var minutes: Int = 30
    @State private var seconds: Int = 0
    @State private var avgHRString: String = ""
    @State private var runType: RunType = .other
    @State private var notes: String = ""

    init(initialDate: Date) {
        self.initialDate = initialDate
        _date = State(initialValue: initialDate)
    }

    var body: some View {
        Form {
            Section("When") {
                DatePicker("Date", selection: $date, displayedComponents: [.date, .hourAndMinute])
            }
            Section("Distance") {
                HStack {
                    Text("Miles")
                    Spacer()
                    TextField("Distance", value: $distanceMiles,
                              format: .number.precision(.fractionLength(1...2)))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .frame(maxWidth: 120)
                }
            }
            Section("Time") {
                HStack { Stepper("Hours: \(hours)", value: $hours, in: 0...23) }
                HStack { Stepper("Minutes: \(minutes)", value: $minutes, in: 0...59) }
                HStack { Stepper("Seconds: \(seconds)", value: $seconds, in: 0...59) }
                HStack {
                    Text("Total")
                    Spacer()
                    Text(totalTimeString).foregroundStyle(.secondary)
                }
            }
            Section("Details") {
                HStack {
                    Text("Avg HR")
                    Spacer()
                    TextField("optional", text: $avgHRString)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .frame(maxWidth: 120)
                }
                Picker("Run Type", selection: $runType) {
                    ForEach(RunType.allCases, id: \.self) { t in
                        Text(t.rawValue.capitalized).tag(t)
                    }
                }
                TextField("Notes (optional)", text: $notes)
            }
        }
        .navigationTitle("Add Manual Run")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(!canSave)
            }
        }
        .tint(AthensTheme.goldAccent)
        .scrollContentBackground(.hidden)
        .background(AthensTheme.backgroundGradient.ignoresSafeArea())
    }

    private var canSave: Bool {
        distanceMiles > 0 && totalSeconds > 0
    }

    private var totalSeconds: Int {
        hours * 3600 + minutes * 60 + seconds
    }

    private var totalTimeString: String {
        let h = hours
        let m = minutes
        let s = seconds
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    private func save() {
        let userId = store.me.id
        let duration = Double(totalSeconds)
        let end = date.addingTimeInterval(duration)
        let avgHR = Double(avgHRString).flatMap { $0.isFinite ? $0 : nil }

        let entry = WorkoutEntry(
            id: manualStableId(start: date, duration: duration, userId: userId),
            userId: userId,
            start: date,
            end: end,
            distanceMeters: milesToMeters(distanceMiles),
            durationSec: duration,
            avgHR: avgHR,
            source: "manual",
            runType: runType,
            isManual: true,
            notes: notes.isEmpty ? nil : notes
        )
        store.upsert(entries: [entry])
        dismiss()
    }

    private func manualStableId(start: Date, duration: Double, userId: String) -> String {
        let s = Int(start.timeIntervalSince1970)
        let d = Int(duration.rounded())
        return "manual_\(userId)_\(s)_\(d)"
    }
}
