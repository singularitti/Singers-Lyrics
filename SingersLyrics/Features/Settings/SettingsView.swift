import SwiftUI
import UniformTypeIdentifiers
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
    @Environment(AppModel.self) private var model
    @AppStorage(PreferenceKey.appearance) private var appearance = Appearance.system.rawValue
    @AppStorage(PreferenceKey.defaultLyricsFontFamily) private var defaultLyricsFontFamily = ""
    @State private var showsSyncFolderPicker = false
    @State private var confirmsReplacementFolder = false
    @State private var replacesSyncConnection = false

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

            LibraryAppearanceSettingsSection()

            Section("iCloud") {
                Toggle("Sync Library with iCloud", isOn: Binding(
                    get: { model.cloudSync.isEnabled },
                    set: { enabled in
                        if enabled && model.cloudSync.usesICloudDrive && !model.cloudSync.hasSyncFolder {
                            replacesSyncConnection = false
                            showsSyncFolderPicker = true
                        } else {
                            model.cloudSync.setEnabled(enabled)
                        }
                    }
                ))
                .disabled(!model.cloudSync.isAvailable || model.cloudSync.isSelectingFolder)
                .accessibilityIdentifier("icloudLibrarySyncToggle")

                if !model.cloudSync.isAvailable {
                    Text("Sync unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.cloudSync.usesICloudDrive {
                    if let folderName = model.cloudSync.syncFolderName {
                        Text("Connected folder: \(folderName)")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("icloudConnectedFolderName")
                    }

                    Button(hasSyncFolderConnection ? "Change Sync Folder…" : "Choose iCloud Drive Folder…") {
                        if hasSyncFolderConnection {
                            confirmsReplacementFolder = true
                        } else {
                            replacesSyncConnection = false
                            showsSyncFolderPicker = true
                        }
                    }
                    .disabled(model.cloudSync.isSyncing || model.cloudSync.isSelectingFolder)
                    .accessibilityIdentifier("icloudSyncFolderButton")

                    if model.cloudSync.isSelectingFolder {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Connecting to sync folder…")
                        }
                    }
                }

                if model.cloudSync.isAvailable && model.cloudSync.isEnabled {
                    HStack {
                        if model.cloudSync.isSyncing {
                            ProgressView().controlSize(.small)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.cloudSync.status)
                            if let date = model.cloudSync.lastSyncedAt {
                                Text(model.cloudSync.usesICloudDrive
                                     ? "Last folder check: \(date.formatted(date: .abbreviated, time: .shortened))"
                                     : "Last synced: \(date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("icloudSyncStatus")
                        Spacer()
                        Button("Sync Now") {
                            Task { await model.cloudSync.syncNow() }
                        }
                        .fixedSize()
                        .disabled(model.cloudSync.isSyncing)
                        .accessibilityIdentifier("icloudSyncNowButton")
                    }
                }

                if let notice = model.cloudSync.folderPermissionNotice {
                    Label(notice, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("icloudFolderPermissionNotice")
                }

                if let message = model.cloudSync.errorMessage {
                    Label(message, systemImage: "exclamationmark.icloud")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            #if os(macOS)
            LogicProSettingsSection()
            #endif
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .fileImporter(isPresented: $showsSyncFolderPicker, allowedContentTypes: [.folder]) { result in
            let replacing = replacesSyncConnection
            replacesSyncConnection = false
            guard case .success(let url) = result else { return }
            model.cloudSync.selectSyncFolder(url, replacingConnection: replacing)
        }
        .alert("Change the connected sync folder?", isPresented: $confirmsReplacementFolder) {
            Button("Choose Folder…") {
                replacesSyncConnection = true
                showsSyncFolderPicker = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose the same folder to restore access, or a different folder to change the connection. Your local songs and recordings will be kept and combined with the selected library. Existing files in the previous folder will be kept.")
        }
        #if os(iOS)
        .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
        #endif
    }

    private var hasSyncFolderConnection: Bool {
        model.cloudSync.hasSyncFolder || model.cloudSync.canReplaceSyncFolder
            || model.cloudSync.folderPermissionNotice != nil
    }
}

private struct LibraryAppearanceSettingsSection: View {
    @AppStorage(PreferenceKey.showsLibraryArtwork) private var showsArtwork = true
    @AppStorage(PreferenceKey.libraryArtworkSize) private var artworkSize = LibraryArtworkSize.medium.rawValue

    var body: some View {
        Section("Song List") {
            Toggle("Show album artwork", isOn: $showsArtwork)
                .accessibilityIdentifier("showLibraryArtworkToggle")

            Picker("Artwork size", selection: $artworkSize) {
                ForEach(LibraryArtworkSize.allCases) { size in
                    Text(size.title).tag(size.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!showsArtwork)
            .accessibilityIdentifier("libraryArtworkSizePicker")

            Text("Choose how album artwork appears in the song list.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
