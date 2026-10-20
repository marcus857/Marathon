// ThemeToggleButton.swift

import SwiftUI

struct ThemeToggleButton: View {
    @AppStorage("appColorScheme") private var appColorScheme: String = "dark"

    var body: some View {
        Menu {
            Button {
                appColorScheme = "light"
            } label: {
                Label("Light", systemImage: "sun.max.fill")
            }
            Button {
                appColorScheme = "dark"
            } label: {
                Label("Dark", systemImage: "moon.fill")
            }
        } label: {
            Image(systemName: appColorScheme == "light" ? "sun.max.fill" : "moon.fill")
        }
        .tint(AthensTheme.goldAccent)
        .accessibilityLabel("Theme")
    }
}
