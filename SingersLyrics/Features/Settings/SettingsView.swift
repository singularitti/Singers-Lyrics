import SwiftUI

enum Appearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Auto"
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

struct SettingsView: View {
    @AppStorage(PreferenceKey.appearance) private var appearance = Appearance.system.rawValue
    @AppStorage(PreferenceKey.defaultLyricsFontFamily) private var defaultLyricsFontFamily = ""

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("appearancePicker")
            .accessibilityValue(Appearance(rawValue: appearance)?.title ?? Appearance.system.title)

            Picker("Default lyrics font", selection: $defaultLyricsFontFamily) {
                Text("System Default").tag("")
                Divider()
                ForEach(FontCatalog.availableFamilies, id: \.self) { family in
                    Text(family).tag(family)
                }
            }
            .accessibilityIdentifier("defaultLyricsFontPicker")

            Text("Used whenever a lyric run does not specify its own font. Existing explicitly formatted text is unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
