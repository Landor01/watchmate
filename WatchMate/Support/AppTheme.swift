import SwiftUI
import UIKit

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case ocean
    case forest
    case sunset
    case lavender

    var id: Self { self }

    var name: LocalizedStringResource {
        switch self {
        case .system: "System"
        case .ocean: "Ocean"
        case .forest: "Forest"
        case .sunset: "Sunset"
        case .lavender: "Lavender"
        }
    }

    func backgroundColor(for colorScheme: ColorScheme) -> Color {
        switch (self, colorScheme) {
        case (.system, _):
            Color(uiColor: .systemGroupedBackground)
        case (.ocean, .light):
            Color(red: 0.94, green: 0.97, blue: 0.98)
        case (.ocean, .dark):
            Color(red: 0.03, green: 0.09, blue: 0.11)
        case (.forest, .light):
            Color(red: 0.95, green: 0.97, blue: 0.94)
        case (.forest, .dark):
            Color(red: 0.04, green: 0.09, blue: 0.05)
        case (.sunset, .light):
            Color(red: 1.00, green: 0.96, blue: 0.93)
        case (.sunset, .dark):
            Color(red: 0.11, green: 0.06, blue: 0.04)
        case (.lavender, .light):
            Color(red: 0.97, green: 0.95, blue: 0.98)
        case (.lavender, .dark):
            Color(red: 0.08, green: 0.05, blue: 0.11)
        @unknown default:
            Color(uiColor: .systemGroupedBackground)
        }
    }

    func tileColor(for colorScheme: ColorScheme) -> Color {
        switch (self, colorScheme) {
        case (.system, .light):
            Color(uiColor: .systemGray5)
        case (.system, .dark):
            Color(uiColor: .secondarySystemGroupedBackground)
        case (.ocean, .light):
            Color(red: 0.85, green: 0.93, blue: 0.95)
        case (.ocean, .dark):
            Color(red: 0.07, green: 0.16, blue: 0.20)
        case (.forest, .light):
            Color(red: 0.86, green: 0.93, blue: 0.86)
        case (.forest, .dark):
            Color(red: 0.09, green: 0.18, blue: 0.11)
        case (.sunset, .light):
            Color(red: 0.98, green: 0.87, blue: 0.82)
        case (.sunset, .dark):
            Color(red: 0.22, green: 0.12, blue: 0.09)
        case (.lavender, .light):
            Color(red: 0.91, green: 0.86, blue: 0.95)
        case (.lavender, .dark):
            Color(red: 0.17, green: 0.11, blue: 0.22)
        @unknown default:
            Color(uiColor: .secondarySystemGroupedBackground)
        }
    }

    func chartSurfaceColor(for colorScheme: ColorScheme) -> Color {
        switch (self, colorScheme) {
        case (_, .light):
            .white
        case (.system, .dark):
            Color(uiColor: .tertiarySystemGroupedBackground)
        case (.ocean, .dark):
            Color(red: 0.10, green: 0.22, blue: 0.27)
        case (.forest, .dark):
            Color(red: 0.12, green: 0.23, blue: 0.14)
        case (.sunset, .dark):
            Color(red: 0.28, green: 0.16, blue: 0.12)
        case (.lavender, .dark):
            Color(red: 0.22, green: 0.15, blue: 0.29)
        @unknown default:
            Color(uiColor: .tertiarySystemGroupedBackground)
        }
    }

    func progressColor(for colorScheme: ColorScheme) -> Color {
        switch (self, colorScheme) {
        case (.system, _), (.ocean, _):
            .blue
        case (.forest, .light):
            Color(red: 0.16, green: 0.52, blue: 0.25)
        case (.forest, .dark):
            Color(red: 0.38, green: 0.78, blue: 0.43)
        case (.sunset, .light):
            Color(red: 0.10, green: 0.52, blue: 0.42)
        case (.sunset, .dark):
            Color(red: 0.34, green: 0.78, blue: 0.65)
        case (.lavender, .light):
            Color(red: 0.53, green: 0.32, blue: 0.70)
        case (.lavender, .dark):
            Color(red: 0.72, green: 0.55, blue: 0.88)
        @unknown default:
            .blue
        }
    }
}


enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var name: LocalizedStringResource {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension EnvironmentValues {
    @Entry var themeAccent: Color = .blue
}

struct AppAppearanceModifier: ViewModifier {
    @AppStorage("appTheme") private var themeValue = AppTheme.system.rawValue
    @AppStorage("appAppearance") private var appearanceValue = AppAppearance.system.rawValue
    @Environment(\.colorScheme) private var systemScheme

    func body(content: Content) -> some View {
        let appearance = AppAppearance(rawValue: appearanceValue) ?? .system
        let theme = AppTheme(rawValue: themeValue) ?? .system
        let scheme = appearance.colorScheme ?? systemScheme
        let accent = theme.progressColor(for: scheme)
        content
            .background {
                WindowAppearanceUpdater(appearance: appearance)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            .tint(accent)
            .environment(\.themeAccent, accent)
    }
}

// Apply appearance to this window so open sheets update too. Unspecified restores
// automatic system appearance without retaining a previous sheet preference.
private struct WindowAppearanceUpdater: UIViewRepresentable {
    let appearance: AppAppearance

    func makeUIView(context: Context) -> AppearanceView {
        AppearanceView()
    }

    func updateUIView(_ uiView: AppearanceView, context: Context) {
        switch appearance {
        case .system: uiView.interfaceStyle = .unspecified
        case .light: uiView.interfaceStyle = .light
        case .dark: uiView.interfaceStyle = .dark
        }
        uiView.applyAppearance()
    }

    final class AppearanceView: UIView {
        var interfaceStyle: UIUserInterfaceStyle = .unspecified

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyAppearance()
        }

        func applyAppearance() {
            guard let window, window.overrideUserInterfaceStyle != interfaceStyle else { return }
            window.overrideUserInterfaceStyle = interfaceStyle
        }
    }
}

struct ThemedList<Content: View>: View {
    @AppStorage("appTheme") private var themeValue = AppTheme.system.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: Content

    var body: some View {
        let theme = AppTheme(rawValue: themeValue) ?? .system
        List {
            content.listRowBackground(theme == .system
                ? Color(uiColor: .secondarySystemGroupedBackground)
                : theme.tileColor(for: colorScheme))
        }
        .scrollContentBackground(.hidden)
        .background(theme.backgroundColor(for: colorScheme))
    }
}

struct ThemedForm<Content: View>: View {
    @AppStorage("appTheme") private var themeValue = AppTheme.system.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: Content

    var body: some View {
        let theme = AppTheme(rawValue: themeValue) ?? .system
        Form {
            content.listRowBackground(theme == .system
                ? Color(uiColor: .secondarySystemGroupedBackground)
                : theme.tileColor(for: colorScheme))
        }
        .scrollContentBackground(.hidden)
        .background(theme.backgroundColor(for: colorScheme))
    }
}

struct AppearanceSettingsSection: View {
    @Environment(\.themeAccent) private var themeAccent
    @AppStorage("appTheme") private var themeValue = AppTheme.system.rawValue
    @AppStorage("appAppearance") private var appearanceValue = AppAppearance.system.rawValue

    var body: some View {
        Section("Appearance") {
            Picker("Appearance", selection: $appearanceValue) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.name).tag(appearance.rawValue)
                }
            }
            .pickerStyle(.segmented)
            LabeledContent("Theme") {
                Menu {
                    Picker("Theme", selection: $themeValue) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.name).tag(theme.rawValue)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text((AppTheme(rawValue: themeValue) ?? .system).name)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(themeAccent)
                }
            }
        }
    }
}
