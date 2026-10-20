//
//  ImportantDate.swift
//  Marathon
//
//  Created by Marcus Price on 11/12/25.
//


import Foundation

struct ImportantDate: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var date: Date?
    var notes: String?

    init(id: UUID = UUID(), title: String, date: Date? = nil, notes: String? = nil) {
        self.id = id
        self.title = title
        self.date = date
        self.notes = notes
    }

    static let seeded: [ImportantDate] = {
        var items: [ImportantDate] = []
        let cal = Calendar.current

        func makeDate(_ y: Int, _ m: Int, _ d: Int, hour: Int? = nil, minute: Int? = nil) -> Date? {
            var comps = DateComponents()
            comps.year = y; comps.month = m; comps.day = d
            comps.hour = hour; comps.minute = minute
            return cal.date(from: comps)
        }

        items.append(ImportantDate(title: "Training Start", date: makeDate(2025, 11, 1), notes: "Kickoff—set baselines, plan logistics."))
        items.append(ImportantDate(title: "Race Day", date: makeDate(2026, 11, 8, hour: 9, minute: 0), notes: "Start ~09:00—arrive early, warm up, hydrate."))
        items.append(ImportantDate(title: "Registration Opens", date: nil, notes: "TBD—monitor official site."))
        items.append(ImportantDate(title: "Expo", date: nil, notes: "Wed–Sat (confirm hours)."))
        items.append(ImportantDate(title: "Flights", date: nil, notes: "Target booking 4–6 months prior."))
        items.append(ImportantDate(title: "Lodging", date: nil, notes: "Near Syntagma or Panathenaic Stadium."))
        items.append(ImportantDate(title: "Medical Clearance", date: nil, notes: "Schedule check-up and any required forms."))
        items.append(ImportantDate(title: "Shoe Rotation", date: nil, notes: "Maintain 2–3 pairs; track mileage."))
        items.append(ImportantDate(title: "Race Nutrition Plan", date: nil, notes: "Dial during long runs; carry gels."))
        items.append(ImportantDate(title: "Spectator Plan", date: nil, notes: "Meetup points, transit options."))
        items.append(ImportantDate(title: "Post-race Meal", date: nil, notes: "Reserve classic spot near Plaka."))
        items.append(ImportantDate(title: "Backup Half", date: nil, notes: "Schedule 6–10 weeks out as contingency."))

        return items
    }()

    static func empty() -> ImportantDate {
        ImportantDate(title: "", date: nil, notes: nil)
    }
}
