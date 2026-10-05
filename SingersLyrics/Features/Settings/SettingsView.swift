import SwiftUI
#if os(macOS)
import AppKit
#endif

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

    #if os(macOS)
    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
    #endif

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

            #if os(macOS)
            LogicProSettingsSection()
            #endif
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #if os(iOS)
        .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
        #endif
    }
}

#if os(macOS)
private struct LogicProSettingsSection: View {
    @Environment(LogicProRecordingModel.self) private var logicProRecording

    var body: some View {
        Section("Logic Pro") {
            Toggle("Record in Logic Pro", isOn: Binding(
                get: { logicProRecording.isArmed },
                set: { logicProRecording.setArmed($0) }
            ))
            .accessibilityIdentifier("logicProRecordingToggle")

            Text("While this is on, Logic Pro records on its selected track whenever you press Play in the player. Pausing the song stops the recording.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Set up Logic Pro once:")
                Text("1. In Logic Pro, choose Logic Pro › Key Commands › Edit Assignments.")
                Text("2. Select the Record command, click Learn New Assignment, then click Send Record.")
                Text("3. Select the Stop command, click Learn New Assignment, then click Send Stop.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Send Record") { logicProRecording.send(.record) }
                    .accessibilityIdentifier("sendLogicProRecordButton")
                Button("Send Stop") { logicProRecording.send(.stop) }
                    .accessibilityIdentifier("sendLogicProStopButton")
            }

            if logicProRecording.isUnavailable {
                Label(
                    "Singers Lyrics couldn’t create its MIDI source, so it can’t control Logic Pro.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }
        }
        // Retry a MIDI source that couldn't be published at launch.
        .onAppear { logicProRecording.prepare() }
    }
}
#endif
