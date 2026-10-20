import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct AthensTheme {

    // MARK: - Dynamic UIColor helpers
    #if canImport(UIKit)
    private static func uiColor(hex: Int, alpha: CGFloat = 1.0) -> UIColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        return UIColor(red: r, green: g, blue: b, alpha: alpha)
    }

    private static func dynamicColor(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { tc in
            tc.userInterfaceStyle == .dark ? dark : light
        })
    }
    #else
    private static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        // macOS fallback: use the light color; you can add NSAppearance checks if needed.
        return Color(light)
    }
    private static func uiColor(hex: Int, alpha: CGFloat = 1.0) -> NSColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: alpha)
    }
    #endif

    // MARK: - Core brand accents (same in both modes)
    static let aegeanBlue   = dynamicColor(light: uiColor(hex: 0x0A4D68), dark: uiColor(hex: 0x0A4D68))
    static let oliveGreen   = dynamicColor(light: uiColor(hex: 0x6B8E23), dark: uiColor(hex: 0x6B8E23))
    static let terracotta   = dynamicColor(light: uiColor(hex: 0xC96A3D), dark: uiColor(hex: 0xC96A3D))
    static let goldAccent   = dynamicColor(light: uiColor(hex: 0xC7A008), dark: uiColor(hex: 0xC7A008))

    // Text color: warm dark text in light mode, marble white in dark mode
    // Light: Greek stone text (#3E3A2F), Dark: soft white (#F7F7F5)
    static let marbleWhite  = dynamicColor(light: uiColor(hex: 0x3E3A2F), dark: uiColor(hex: 0xF7F7F5))

    // Background base: Greek beige in light mode, deep midnight in dark mode
    // Light: sand beige (#F5EFE6), Dark: deep blue (#0C2233)
    static let midnightBlue = dynamicColor(light: uiColor(hex: 0xF5EFE6), dark: uiColor(hex: 0x0C2233))

    // MARK: - Dynamic Gradients
    // Dark mode remains as before; light mode shifts to a Greek beige palette.

    // Hero
    // Light: soft cream to parchment; Dark: original Aegean to midnight
    static var heroGradient: LinearGradient {
        let top = dynamicColor(light: uiColor(hex: 0xFFF8EE),             // cream
                               dark:  uiColor(hex: 0x0A4D68))             // aegeanBlue
        let bottom = dynamicColor(light: uiColor(hex: 0xEADCC2, alpha: 0.60), // parchment tint
                                  dark:  uiColor(hex: 0x0C2233))              // midnight
        return LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // App background
    // Light: cream to parchment tint; Dark: midnight to aegean tint
    static var backgroundGradient: LinearGradient {
        let top = dynamicColor(light: uiColor(hex: 0xFAF5EE),               // soft cream
                               dark:  uiColor(hex: 0x0C2233))               // midnight
        let bottom = dynamicColor(light: uiColor(hex: 0xEADCC2, alpha: 0.35), // parchment wash
                                  dark:  uiColor(hex: 0x0A4D68, alpha: 0.96)) // aegeanBlue 96%
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    // Cards
    // Light: warm cream card with subtle parchment depth; Dark: original
    static var cardGradient: LinearGradient {
        let top = dynamicColor(light: uiColor(hex: 0xFFF8EE, alpha: 0.96),   // cream 96%
                               dark:  uiColor(hex: 0x0A4D68, alpha: 0.88))   // aegeanBlue 88%
        let bottom = dynamicColor(light: uiColor(hex: 0xEADCC2, alpha: 0.20), // parchment 20%
                                  dark:  uiColor(hex: 0x0C2233, alpha: 0.92)) // midnight 92%
        return LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // Dynamic border stroke for cards: warm hairline in light, subtle white in dark
    static var borderStroke: Color {
        dynamicColor(light: uiColor(hex: 0x7A6F5A, alpha: 0.18),            // warm stone hairline
                     dark:  uiColor(hex: 0xFFFFFF, alpha: 0.06))
    }

    // Shadow: soften in light mode
    static var shadowColor: Color {
        dynamicColor(light: uiColor(hex: 0x000000, alpha: 0.12), dark: uiColor(hex: 0x000000, alpha: 0.20))
    }

    // Corner radius
    static let cornerRadiusLarge: CGFloat = 20

    // Typography
    static let TitleFont = Font.system(.largeTitle, design: .rounded).weight(.bold)
    static let BodyFont  = Font.system(.body, design: .rounded)
}

// Reusable modifiers
extension View {
    func athensSoftShadow() -> some View {
        shadow(color: AthensTheme.shadowColor, radius: 10, x: 0, y: 6)
    }

    func athensBackground() -> some View {
        background(AthensTheme.backgroundGradient.ignoresSafeArea())
    }

    func athensCard(cornerRadius: CGFloat = AthensTheme.cornerRadiusLarge) -> some View {
        modifier(AthensCardModifier(cornerRadius: cornerRadius))
    }
}

private struct AthensCardModifier: ViewModifier {
    var cornerRadius: CGFloat
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(AthensTheme.cardGradient)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AthensTheme.borderStroke, lineWidth: 1)
            )
            .athensSoftShadow()
    }
}
