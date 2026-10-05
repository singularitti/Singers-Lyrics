#if os(iOS)
import SwiftUI
import UIKit

private enum MobileSongMode {
    case editor
    case player
}

struct MobileSongWorkspace: View {
    @Binding var song: Song
    let metadataLookup: any TrackMetadataLookingUp

    @Environment(MusicPlaybackModel.self) private var playback
    @Environment(AppModel.self) private var model
    @State private var mode = MobileSongMode.editor
    @State private var pollingOwner = UUID()
    @State private var showsDetails = false
    @State private var showsLink = false
    @State private var showsImport = false
    @State private var showsBundleExport = false
    @State private var showsLRCExport = false
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            MobilePlaybackNotice()
            switch mode {
            case .editor:
                MobileLyricsEditorView(song: $song)
            case .player:
                MobilePlayerView(song: song)
            }
        }
        .navigationTitle(song.title.isEmpty ? "Untitled" : song.title)
        .navigationBarTitleDisplayMode(.inline)
        // As in the Mac header: a leading title and singer in the editor, and no bar
        // title over the player, which presents its own.
        .toolbar(removing: mode == .player ? .title : nil)
        .toolbar {
            if mode == .editor {
                ToolbarItem(placement: .principal) {
                    MobileSongTitle(song: song)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
                    )
                    mode = mode == .editor ? .player : .editor
                } label: {
                    Label(
                        mode == .editor ? "Player" : "Editor",
                        systemImage: mode == .editor ? "play.rectangle" : "square.and.pencil"
                    )
                    .labelStyle(.titleAndIcon)
                }
                .accessibilityHint(mode == .editor ? "Show the lyric player" : "Return to editing lyrics")
                .accessibilityIdentifier("switchSongModeButton")
            }
            if mode == .editor {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Song Details", systemImage: "info.circle") { showsDetails = true }
                        Button("Change Apple Music Link", systemImage: "link") { showsLink = true }
                        Divider()
                        Button("Import Lyrics", systemImage: "square.and.arrow.down") { showsImport = true }
                        Button("Export Song Bundle", systemImage: "square.and.arrow.up") {
                            // Include a running take in the exported document.
                            let voice = model.voiceRecordings
                            if voice.recordingSongID == song.id {
                                voice.finishRecording()
                                guard !voice.hasUncommittedRecording else { return }
                            }
                            showsBundleExport = true
                        }
                        Button("Export LRC", systemImage: "doc.text") { showsLRCExport = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Song options")
                }
            }
        }
        .sheet(isPresented: $showsDetails) { MobileSongDetailsSheet(song: $song) }
        .sheet(isPresented: $showsLink) {
            MobileMusicLinkSheet(metadataLookup: metadataLookup, existingURL: song.appleMusicURL) { url, metadata in
                song.appleMusicURL = url
                song.linkedTrackMetadata = metadata
                if song.album.isEmpty { song.album = metadata.album }
            }
        }
        .sheet(isPresented: $showsImport) {
            MobileLyricsImportSheet { lines in song.lines = lines }
        }
        .fileExporter(
            isPresented: $showsBundleExport,
            document: SongBundleFileDocument(bundle: SongBundle(songs: [song])),
            contentType: .singersLyricsSongBundle,
            defaultFilename: song.title.isEmpty ? "Song" : song.title
        ) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .fileExporter(
            isPresented: $showsLRCExport,
            document: LRCFileDocument(song: song),
            contentType: .lrcLyrics,
            defaultFilename: song.title.isEmpty ? "Lyrics" : song.title
        ) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
        .onAppear { updatePolling() }
        .onChange(of: song) { _, _ in updatePolling() }
        .onChange(of: mode) { _, _ in updatePolling() }
        .onDisappear { playback.stopPolling(owner: pollingOwner) }
    }

    private func updatePolling() {
        playback.startPolling(owner: pollingOwner, for: song, repeatsWhenFinished: mode == .player)
    }
}

/// The singer follows the title only when both fit, like the Mac editor header.
private struct MobileSongTitle: View {
    let song: Song

    private var title: String { song.title.isEmpty ? "Untitled" : song.title }
    private var singer: String { song.artist.isEmpty ? "Unknown Singer" : song.artist }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(title).font(.headline)
                Text(" | ").foregroundStyle(.tertiary)
                Text(singer).foregroundStyle(.secondary)
            }
            Text(title).font(.headline)
        }
        .lineLimit(1)
        // Leading toolbar items are kept narrow, so the title uses the centered slot. A large
        // ideal width makes the bar give it all the room between its buttons; aligning it
        // to the leading edge of that room keeps it beside the back button instead of centered.
        .frame(idealWidth: 10_000, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(singer)")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("mobileSongTitle")
    }
}

struct MobilePlaybackNotice: View {
    @Environment(MusicPlaybackModel.self) private var playback
    @Environment(\.openURL) private var openURL

    var body: some View {
        if playback.state.permissionDenied {
            VStack(alignment: .leading, spacing: 6) {
                Label("Allow Music Access", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text("Enable Media & Apple Music access for Singers Lyrics in Settings.")
                    .font(.subheadline)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .frame(minHeight: 44)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.orange.opacity(0.12))
        } else if let failure = playback.failure {
            VStack(alignment: .leading, spacing: 6) {
                Label(failure.title, systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(failure.message)
                    .font(.subheadline)
                DisclosureGroup("Technical Details") {
                    Text(failure.diagnostic)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.orange.opacity(0.12))
        } else if let issue = playback.issue {
            Label(issue.message, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.orange.opacity(0.12))
        }
    }
}
#endif
