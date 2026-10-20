//
//  FunFact.swift
//  Marathon
//
//  Created by Marcus Price on 11/12/25.
//

import Foundation

struct FunFact: Identifiable, Codable, Hashable {
    let id: UUID
    var text: String
    var imageName: String?

    init(id: UUID = UUID(), text: String, imageName: String? = nil) {
        self.id = id
        self.text = text
        self.imageName = (imageName?.isEmpty == true) ? nil : imageName
    }

    static let seeded: [FunFact] = [
        // Existing cool facts
        FunFact(text: "The Athens Authentic Marathon follows the legendary route from Marathon to Athens, finishing at the Panathenaic Stadium.", imageName: "athens_hero_1"),
        FunFact(text: "The Panathenaic Stadium is built entirely of marble and hosted the first modern Olympics in 1896.", imageName: "athens_hero_2"),
        FunFact(text: "The term ‘marathon’ commemorates the run of Pheidippides after the Battle of Marathon in 490 BCE.", imageName: "athens_hero_3"),
        FunFact(text: "Average Athens Marathon temps are mild; early starts help beat midday warmth."),
        FunFact(text: "The course has a steady rise from Marathon to Pikermi, then a descent toward Athens."),
        FunFact(text: "Olive wreaths (kotinos) crowned ancient victors, symbolizing peace and honor."),
        FunFact(text: "The Acropolis hill has witnessed over 2,400 years of Athenian history."),
        FunFact(text: "Syntagma Square is a transport hub and a great meetup spot for race logistics."),
        FunFact(text: "Greek cuisine staples like souvlaki and feta are perfect for post-race refueling."),
        FunFact(text: "Hydration is crucial: the route features frequent aid stations—study their locations."),
        FunFact(text: "The Herod Atticus Odeon hosts performances under the Acropolis rock."),
        FunFact(text: "Train your downhill control—late race descents reward practiced quads."),
        FunFact(text: "Practice race nutrition during long runs: carbs every 30–40 min works for many."),
        FunFact(text: "Rotate 2–3 shoe pairs to reduce injury risk and keep foam fresh."),
        FunFact(text: "The word ‘athlete’ comes from Greek ἀθλητής (athlētḗs), meaning ‘contestant.’"),
        FunFact(text: "Ancient runners competed barefoot or with minimal sandals."),
        FunFact(text: "The Panathenaic Stadium seats are numbered from ancient times—still usable today."),
        FunFact(text: "Visit Plaka’s narrow streets for classic post-race meals and strolling."),
        FunFact(text: "Respect the 10% weekly mileage rule—steady beats spectacular."),
        FunFact(text: "Consolidation weeks (every 4th) lower load to cement gains and avoid overuse."),

        // New “cooler” Athens/Marthon facts
        FunFact(text: "Pheidippides reportedly ran from Marathon to Athens to announce victory—then collapsed—fueling the mythos of endurance."),
        FunFact(text: "The Tomb of the Athenians at Marathon commemorates the fallen from the 490 BCE battle—a solemn landmark near the start."),
        FunFact(text: "The Panathenaic Stadium’s marble glows at twilight—your finish line is literally carved in history."),
        FunFact(text: "The authentic course passes Rafina and Pikermi—modern towns tracing ancient roads."),
        FunFact(text: "The Greek word ‘kardia’ (heart) gives us cardiology—pace your ‘kardia’ over the Pikermi climbs."),
        FunFact(text: "Phidippides was also an ultrarunner: he ran from Athens to Sparta (over 150 miles) to seek help before the battle."),
        FunFact(text: "‘Nike’—goddess of victory—was said to inspire the message ‘Nenikēkamen’ (We have won)."),
        FunFact(text: "In 1896, Spyridon Louis won the first modern Olympic marathon—becoming a national hero."),
        FunFact(text: "The Acropolis’ Parthenon has precise optical refinements; even its steps subtly curve—Athenian design genius."),
        FunFact(text: "Runners once wore laurel crowns; in Athens, olive wreaths honor the ancient Panathenaic games."),
        FunFact(text: "Athens’ hills shape your stride—practice steady effort on climbs and controlled cadence on descents."),
        FunFact(text: "The authentic route’s last miles trend downhill—save your legs for a strong finish into the marble stadium."),
        FunFact(text: "Ancient messengers were trained to run for days—‘hemerodromoi’—the original endurance athletes."),
        FunFact(text: "The word ‘gymnasium’ comes from Greek ‘gymnós’ (naked)—ancient training was… minimalist."),
        FunFact(text: "Athens’ blue and white flags echo sea and marble—your hero gradient is a modern nod to timeless tones.", imageName: "athens_hero_2"),
        FunFact(text: "The Marathon plain is fertile and windswept—expect coastal breezes early before the city’s shelter."),
        FunFact(text: "The Panathenaic track is 333.33m—three laps equal ~1km; measure your pride in marble meters."),
        FunFact(text: "Pheidippides likely paced—fast starts fade; even legends respect even effort."),
        FunFact(text: "Modern fueling science turns olive oil and bread into gels and electrolytes—eat like a champion, fuel like a scientist.")
    ]

    static func daily(for date: Date = Date(), from facts: [FunFact] = FunFact.seeded) -> FunFact {
        guard !facts.isEmpty else { return FunFact(text: "Welcome to Athens!") }
        let cal = Calendar.current
        let day = cal.ordinality(of: .day, in: .year, for: date) ?? 1
        let idx = (day - 1) % facts.count
        return facts[idx]
    }
}
