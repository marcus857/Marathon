//
//  HeroHeader.swift
//  Marathon
//
//  Created by Marcus Price on 11/12/25.
//

import SwiftUI

struct HeroHeader: View {
    let title: String
    let subtitle: String
    let imageName: String?
    let vo2Max: Double?

    @Environment(\.colorScheme) private var colorScheme

    // Replace the specific "Athens Tracker" title with "Athens Marathoners"
    private var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == "athens tracker" {
            return "Athens Marathoners"
        }
        return title
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            backgroundView
                .frame(height: 130) // compact height: just enough for title + trailing button area
                .clipped()
                .mask(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 6)

            // Bottom-left titles + VO2 pill
            VStack(alignment: .leading, spacing: 6) {
                Text(displayTitle)
                    .font(AthensTheme.TitleFont)
                    .foregroundColor(.white) // force white in both light/dark
                    .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 2)

                Text(subtitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white.opacity(0.95)) // force white in both light/dark
                    .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)

                if let vo2 = vo2Max {
                    HStack(spacing: 6) {
                        Image(systemName: "lungs.fill")
                            .foregroundColor(AthensTheme.goldAccent)
                        Text(String(format: "VO2max %.1f mL/kg/min", vo2))
                            .font(.footnote.weight(.semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.45)) // stronger scrim for readability
                            .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))
                    )
                    .foregroundColor(.white)
                }
            }
            .padding(12)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(displayTitle), \(subtitle)"))
    }

    // MARK: - Background

    @ViewBuilder
    private var backgroundView: some View {
        // Always fill with theme gradient first to avoid any black edges
        ZStack {
            AthensTheme.heroGradient

            if let img = firstAvailableHeroImage() {
                img
                    .resizable()
                    .scaledToFill()
            } else {
                // Fallback: keep gradient only (no icons), stays clean and edge-safe
                Color.clear
            }
        }
        .overlay(overlayGradient) // high-contrast overlay for readability in both light/dark
    }

    private var overlayGradient: some View {
        // Use black scrim in light mode; themed deep blue in dark mode
        let top = colorScheme == .dark ? AthensTheme.midnightBlue.opacity(0.10) : Color.black.opacity(0.05)
        let mid = colorScheme == .dark ? AthensTheme.midnightBlue.opacity(0.35) : Color.black.opacity(0.25)
        let bottom = colorScheme == .dark ? AthensTheme.midnightBlue.opacity(0.85) : Color.black.opacity(0.55)
        return LinearGradient(colors: [top, mid, bottom], startPoint: .top, endPoint: .bottom)
    }

    private func firstAvailableHeroImage() -> Image? {
        if let name = imageName, let img = resolveImage(named: name) { return img }
        // If no image provided, don't auto-pick others; keep the gradient clean.
        return nil
    }

    private func resolveImage(named: String) -> Image? {
        #if canImport(UIKit)
        if let ui = UIImage(named: named) { return Image(uiImage: ui) }
        #endif
        return nil
    }
}
