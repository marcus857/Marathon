// FunFactHistoryView.swift

import SwiftUI

struct FunFactHistoryView: View {
    let history: [DatedFunFact]
    @Environment(\.dismiss) private var dismiss

    private func dateLabel(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        NavigationStack {
            List {
                // Show latest first
                ForEach(history.sorted(by: { $0.date > $1.date })) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(dateLabel(item.date))
                            .font(.headline)
                            .foregroundColor(AthensTheme.marbleWhite)
                        Text(item.fact.text)
                            .font(AthensTheme.BodyFont)
                            .foregroundColor(AthensTheme.marbleWhite.opacity(0.95))
                    }
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(AthensTheme.cardGradient)
                    )
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .navigationTitle("Fun Facts")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .tint(AthensTheme.goldAccent)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(AthensTheme.midnightBlue, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .background(AthensTheme.backgroundGradient.ignoresSafeArea())
        }
    }
}
