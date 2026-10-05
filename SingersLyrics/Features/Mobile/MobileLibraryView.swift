#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A split view collapses to a library-first navigation stack on iPhone and in
/// narrow iPad windows. The song's editor/player and Trash are detail destinations.
struct MobileLibraryView: View {
    let metadataLookup: any TrackMetadataLookingUp

    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openURL) private var openURL
    @State private var selection: MobileLibraryDestination?
    @State private var visibility = NavigationSplitViewVisibility.all
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    @State private var search = ""
    @State private var favoritesOnly = false
    @AppStorage(PreferenceKey.sortMode) private var sortMode = SongSortMode.dateAdded.rawValue
    @State private var showsNewSong = false
    @State private var showsSettings = false
    @State private var showsImporter = false
    @State private var showsExporter = false
    @State private var exportDocument: SongBundleFileDocument?
    @State private var pendingDeletion: Song?
    @State private var fileError: String?

    private var songs: [Song] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = model.library.songs.filter { song in
            (!favoritesOnly || song.isFavorite) && (query.isEmpty ||
                [song.title, song.artist, song.album, song.tags.joined(separator: " ")]
                    .contains { $0.localizedStandardContains(query) })
        }
        return (SongSortMode(rawValue: sortMode) ?? .dateAdded).sorted(filtered)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility, preferredCompactColumn: $compactColumn) {
            library
                .navigationTitle("Music")
                .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 400)
                .searchable(text: $search, prompt: "Songs, singers, albums, tags")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Picker("Sort by", selection: $sortMode) {
                                ForEach(SongSortMode.allCases, id: \.rawValue) { mode in
                                    Text(mode.title).tag(mode.rawValue)
                                }
                            }
                            Toggle("Favorites only", isOn: $favoritesOnly)
                            Divider()
                            Button("Export Library", systemImage: "square.and.arrow.up") {
                                export(model.library.songs)
                            }
                            .disabled(model.library.songs.isEmpty)
                            Button("Settings", systemImage: "gearshape") { showsSettings = true }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("Library options")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("New Song from Apple Music", systemImage: "music.note") {
                                showsNewSong = true
                            }
                            Button("Import Song Bundle", systemImage: "square.and.arrow.down") {
                                showsImporter = true
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add music")
                        .accessibilityIdentifier("addMusicButton")
                        .disabled(!model.isLoaded)
                    }
                }
        } detail: {
            switch selection {
            case .song(let id):
                if let song = binding(for: id) {
                    MobileSongWorkspace(song: song, metadataLookup: metadataLookup)
                        .id(id)
                } else {
                    songPlaceholder
                }
            case .trash:
                MobileTrashView()
            case nil:
                songPlaceholder
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: selection) { _, destination in
            if destination == .trash {
                model.showRecordingTrash()
            } else {
                model.selectSong(destination?.songID)
            }
        }
        .onChange(of: model.library.songs.map(\.id)) { _, ids in
            if let songID = selection?.songID, !ids.contains(songID) {
                self.selection = nil
                compactColumn = .sidebar
            }
        }
        .sheet(isPresented: $showsNewSong) {
            MobileMusicLinkSheet(metadataLookup: metadataLookup) { url, metadata in
                let song = model.createSong(appleMusicURL: url, metadata: metadata)
                open(song.id)
            }
        }
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsSettings = false }
                        }
                    }
            }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.singersLyricsSongBundle]) {
            result in
            do { try importBundle(at: result.get()) }
            catch { fileError = error.localizedDescription }
        }
        .fileExporter(
            isPresented: $showsExporter,
            document: exportDocument,
            contentType: .singersLyricsSongBundle,
            defaultFilename: "Singers Lyrics Library"
        ) { result in
            if case .failure(let error) = result { fileError = error.localizedDescription }
        }
        .onOpenURL { url in
            Task {
                // File opening can precede the initial library load.
                await model.load()
                do { try importBundle(at: url) }
                catch { fileError = error.localizedDescription }
            }
        }
        .confirmationDialog(
            "Move this song and its lyrics to Trash?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            if let song = pendingDeletion {
                Button("Delete \(song.title)", role: .destructive) {
                    model.deleteSong(song.id)
                    pendingDeletion = nil
                }
            }
        }
        .alert("File Could Not Be Opened or Saved", isPresented: Binding(
            get: { fileError != nil }, set: { if !$0 { fileError = nil } }
        )) {
            Button("OK", role: .cancel) { fileError = nil }
        } message: { Text(fileError ?? "") }
        .alert(model.storageIssue?.title ?? "Library Issue", isPresented: Binding(
            get: { model.storageIssue != nil }, set: { if !$0 { model.storageIssue = nil } }
        )) {
            if !model.library.songs.isEmpty {
                Button("Export Library") { export(model.library.songs) }
            }
            Button("OK", role: .cancel) { model.storageIssue = nil }
        } message: { Text(model.storageIssue?.message ?? "") }
        .alert("Voice Recording", isPresented: Binding(
            get: { model.voiceRecordings.errorMessage != nil },
            set: { if !$0 { model.voiceRecordings.errorMessage = nil } }
        )) {
            if model.voiceRecordings.hasUncommittedRecording {
                Button("Retry Saving") {
                    Task { @MainActor in
                        model.voiceRecordings.errorMessage = nil
                        await Task.yield()
                        model.voiceRecordings.finishRecording()
                    }
                }
                Button("Discard Recording", role: .destructive) {
                    model.voiceRecordings.cancelRecording()
                    model.voiceRecordings.errorMessage = nil
                }
                Button("Keep for Later", role: .cancel) {
                    model.voiceRecordings.errorMessage = nil
                }
            } else if model.voiceRecordings.microphoneAccessDenied {
                Button("Open Settings") {
                    model.voiceRecordings.errorMessage = nil
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Button("Cancel", role: .cancel) { model.voiceRecordings.errorMessage = nil }
            } else {
                Button("OK", role: .cancel) { model.voiceRecordings.errorMessage = nil }
            }
        } message: {
            Text(model.voiceRecordings.errorMessage ?? "")
        }
    }

    private var songPlaceholder: some View {
        ContentUnavailableView(
            "Choose a Song",
            systemImage: "music.note.list",
            description: Text("Select music from your library to edit or play its lyrics.")
        )
    }

    private var showsTrashItem: Bool {
        // The empty-library overlay offers Trash instead of covering this row.
        model.isLoaded && !model.library.songs.isEmpty
            && search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var library: some View {
        List(selection: $selection) {
            if favoritesOnly {
                Section {
                    Button("Show All Songs", systemImage: "line.3.horizontal.decrease.circle") {
                        favoritesOnly = false
                    }
                }
            }
            ForEach(songs) { song in
                NavigationLink(value: MobileLibraryDestination.song(song.id)) {
                    HStack(spacing: 12) {
                        Image(systemName: song.isFavorite ? "heart.fill" : "music.note")
                            .font(.title3)
                            .foregroundStyle(song.isFavorite ? Color.pink : Color.accentColor)
                            .frame(width: 38, height: 44)
                            .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(song.title.isEmpty ? "Untitled" : song.title)
                                .font(.headline)
                                .lineLimit(2)
                            if !song.artist.isEmpty {
                                Text(song.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if !song.album.isEmpty {
                                Text(song.album).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .contextMenu {
                    Button(song.isFavorite ? "Remove Favorite" : "Favorite", systemImage: "heart") {
                        model.toggleFavorite(songID: song.id)
                    }
                    Button("Duplicate", systemImage: "plus.square.on.square") {
                        if let id = model.duplicateSongs([song.id]).first { open(id) }
                    }
                    Button("Export Song", systemImage: "square.and.arrow.up") { export([song]) }
                    Button("Delete", systemImage: "trash", role: .destructive) { pendingDeletion = song }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Delete", systemImage: "trash", role: .destructive) { pendingDeletion = song }
                }
                .swipeActions(edge: .leading) {
                    Button(song.isFavorite ? "Unfavorite" : "Favorite", systemImage: "heart") {
                        model.toggleFavorite(songID: song.id)
                    }
                    .tint(.pink)
                }
            }

            if showsTrashItem {
                Section {
                    NavigationLink(value: MobileLibraryDestination.trash) {
                        Label("Trash", systemImage: "trash")
                    }
                    .badge(model.trashedItemCount)
                    .accessibilityLabel("Trash, \(model.library.trashedSongs.count) songs, \(model.recordingsInTrash.count) recordings")
                    .accessibilityIdentifier("mobileTrashItem")
                }
            }
        }
        .onKeyPress(keys: [.delete, .deleteForward], phases: .down) { press in
            // Caps Lock and keypad state do not change the meaning of Delete.
            let modifiers = press.modifiers.subtracting([.capsLock, .numericPad])
            // A search can hide the selected song; never delete what isn't listed.
            guard modifiers.isEmpty || modifiers == .command,
                  let songID = selection?.songID,
                  songs.contains(where: { $0.id == songID }) else { return .ignored }
            moveSongToTrash(songID)
            return .handled
        }
        .overlay {
            if !model.isLoaded {
                ProgressView("Opening library…")
            } else if model.library.songs.isEmpty {
                ContentUnavailableView {
                    Label("Your Music, Your Lyrics", systemImage: "music.note.list")
                } description: {
                    Text("Add an Apple Music song, or import a song bundle from your Mac.")
                } actions: {
                    Button("Add Music", systemImage: "plus") { showsNewSong = true }
                        .buttonStyle(.borderedProminent)
                    Button("Import Song Bundle") { showsImporter = true }
                    if model.trashedItemCount > 0 {
                        Button("Open Trash", systemImage: "trash") { showTrash() }
                            .accessibilityIdentifier("mobileEmptyLibraryTrashButton")
                    }
                }
            } else if songs.isEmpty {
                ContentUnavailableView(
                    favoritesOnly ? "No Matching Favorites" : "No Matching Songs",
                    systemImage: "magnifyingglass",
                    description: Text("Try another search or change the library filter.")
                )
                .allowsHitTesting(false)
            }
        }
        .accessibilityIdentifier("mobileLibrary")
    }

    private func binding(for id: UUID) -> Binding<Song>? {
        guard let original = model.song(withID: id) else { return nil }
        return Binding(
            get: { model.song(withID: id) ?? original },
            set: { model.replaceSong($0) }
        )
    }

    private func open(_ id: UUID) {
        selection = .song(id)
        model.selectSong(id)
        compactColumn = .detail
    }

    private func showTrash() {
        selection = .trash
        compactColumn = .detail
    }

    /// The hardware Delete key moves the selected song to Trash without the
    /// swipe confirmation, like the Mac sidebar. On iPad the adjacent visible
    /// song becomes selected so repeated presses keep working from the keyboard.
    private func moveSongToTrash(_ id: UUID) {
        let visibleIDs = songs.map(\.id)
        model.deleteSong(id)
        // Deletion is refused while Trash is purging or a take cannot be saved.
        guard model.song(withID: id) == nil,
              horizontalSizeClass == .regular,
              let index = visibleIDs.firstIndex(of: id) else { return }
        let remainingIDs = visibleIDs.filter { $0 != id }
        guard !remainingIDs.isEmpty else { return }
        selection = .song(remainingIDs[min(index, remainingIDs.count - 1)])
    }

    private func export(_ songs: [Song]) {
        let ids = Set(songs.map(\.id))
        // Include a running take in the exported document.
        let voice = model.voiceRecordings
        if voice.recordingSongID.map(ids.contains) == true {
            voice.finishRecording()
            guard !voice.hasUncommittedRecording else { return }
        }
        let currentSongs = model.library.songs.filter { ids.contains($0.id) }
        guard !currentSongs.isEmpty else { return }
        exportDocument = SongBundleFileDocument(bundle: SongBundle(songs: currentSongs))
        showsExporter = true
    }

    private func importBundle(at url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let bundle = try SongBundleCodec.decode(contentsOf: url)
        if let id = model.importSongs(bundle.songs).first {
            search = ""
            favoritesOnly = false
            open(id)
        }
    }
}

private enum MobileLibraryDestination: Hashable {
    case song(UUID)
    case trash

    var songID: UUID? {
        guard case .song(let id) = self else { return nil }
        return id
    }
}
#endif
