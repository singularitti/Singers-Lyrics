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
        .toolbar {
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
