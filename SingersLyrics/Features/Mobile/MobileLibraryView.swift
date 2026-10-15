#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// iPhone and iPad share a single-column stack rooted in the searchable library.
/// Opening a song or Trash replaces the visible screen until the user goes back.
struct MobileLibraryView: View {
    let metadataLookup: any TrackMetadataLookingUp

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var navigationPath: [MobileLibraryDestination] = []
    @State private var selectedSongID: UUID?
    @State private var browser = LibraryBrowserState()
    @AppStorage(PreferenceKey.sortMode) private var sortModeRaw = SongSortMode.title.rawValue
    @AppStorage(PreferenceKey.showsLibraryArtwork) private var showsArtwork = true
    @AppStorage(PreferenceKey.libraryArtworkSize) private var artworkSizeRaw = LibraryArtworkSize.medium.rawValue
    @State private var showsNewSong = false
    @State private var showsSettings = false
    @State private var showsImporter = false
    @State private var showsExporter = false
    @State private var exportDocument: SongBundleFileDocument?
    @State private var fileError: String?

    private var songs: [Song] {
        browser.filteredSongs(in: model.library.songs, sortedBy: SongSortMode(rawValue: sortModeRaw) ?? .title)
    }

    private var artworkSize: LibraryArtworkSize {
        LibraryArtworkSize(rawValue: artworkSizeRaw) ?? .medium
    }

    private var tagSummaries: [TagSummary] { TagSummary.summaries(for: model.library.songs) }
    private var availableTagKeys: Set<String> { Set(tagSummaries.map(\.key)) }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            library
                .navigationTitle(browser.title)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(
                    text: $browser.searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search songs and lyrics"
                )
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        libraryTitle
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
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
                        LibraryFilterMenu(browser: $browser, onOpenTrash: showTrash)
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
                .navigationDestination(for: MobileLibraryDestination.self) { destination in
                    switch destination {
                    case .song(let id):
                        if let song = binding(for: id) {
                            MobileSongWorkspace(song: song, metadataLookup: metadataLookup)
                                .id(id)
                        } else {
                            ContentUnavailableView("Song Unavailable", systemImage: "music.note.list")
                        }
                    case .trash:
                        MobileTrashView()
                    }
                }
        }
        .onChange(of: availableTagKeys, initial: true) { _, keys in
            browser.selectedTagKeys.formIntersection(keys)
        }
        .onChange(of: navigationPath) { _, path in
            switch path.last {
            case .song(let id):
                selectedSongID = id
                model.selectSong(id)
            case .trash:
                selectedSongID = nil
                model.showRecordingTrash()
            case nil:
                model.selectSong(nil)
            }
        }
        .onChange(of: model.library.songs.map(\.id)) { _, ids in
            if let songID = navigationPath.last?.songID, !ids.contains(songID) {
                navigationPath = []
            }
            if let selectedSongID, !ids.contains(selectedSongID) {
                self.selectedSongID = nil
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

    private var libraryTitle: some View {
        VStack(spacing: 2) {
            Text(browser.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(browser.summary(songCount: songs.count, tags: tagSummaries))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("songListSummary")
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private var library: some View {
        List(selection: $selectedSongID) {
            ForEach(songs) { song in
                NavigationLink(value: MobileLibraryDestination.song(song.id)) {
                    LibrarySongRow(song: song, showsArtwork: showsArtwork, artworkSize: artworkSize)
                }
                .tag(song.id)
                .listRowInsets(EdgeInsets(top: artworkSize.rowVerticalPadding, leading: 16,
                                         bottom: artworkSize.rowVerticalPadding, trailing: 16))
                .alignmentGuide(.listRowSeparatorLeading) { [inset = showsArtwork ? artworkSize.dimension + 12 : 0] _ in inset }
                .listRowSeparator(.visible)
                .accessibilityIdentifier("songRow-\(song.id)")
                .contextMenu {
                    Button(song.isFavorite ? "Remove Favorite" : "Favorite", systemImage: "heart") {
                        model.toggleFavorite(songID: song.id)
                    }
                    Button("Duplicate", systemImage: "plus.square.on.square") {
                        if let id = model.duplicateSongs([song.id]).first { open(id) }
                    }
                    Button("Export Song", systemImage: "square.and.arrow.up") { export([song]) }
                    Button("Delete", systemImage: "trash", role: .destructive) { model.deleteSong(song.id) }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Delete", systemImage: "trash", role: .destructive) { model.deleteSong(song.id) }
                }
                .swipeActions(edge: .leading) {
                    Button(song.isFavorite ? "Unfavorite" : "Favorite", systemImage: "heart") {
                        model.toggleFavorite(songID: song.id)
                    }
                    .tint(.pink)
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
        .onKeyPress(keys: [.delete, .deleteForward], phases: .down) { press in
            // Caps Lock and keypad state do not change the meaning of Delete.
            let modifiers = press.modifiers.subtracting([.capsLock, .numericPad])
            // A search can hide the selected song; never delete what isn't listed.
            guard navigationPath.isEmpty,
                  modifiers.isEmpty || modifiers == .command,
                  let songID = selectedSongID,
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
                ContentUnavailableView {
                    Label("No Matching Songs", systemImage: "magnifyingglass")
                } description: {
                    Text("Try another search or change your filters.")
                } actions: {
                    Button("Show All Songs") {
                        browser.showAllSongs()
                    }
                }
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
        // Explicit add, import and duplicate actions reveal their result even
        // when it has never been played or doesn't match the previous filters.
        browser.showAllSongs()
        selectedSongID = id
        navigationPath = [.song(id)]
        model.selectSong(id)
    }

    private func showTrash() {
        navigationPath = [.trash]
    }

    /// Keyboard deletion stays in the library and selects the adjacent visible
    /// row, allowing repeated presses without navigating into the song.
    private func moveSongToTrash(_ id: UUID) {
        let visibleIDs = songs.map(\.id)
        model.deleteSong(id)
        // Deletion is refused while Trash is purging or a take cannot be saved.
        guard model.song(withID: id) == nil,
              let index = visibleIDs.firstIndex(of: id) else { return }
        let remainingIDs = visibleIDs.filter { $0 != id }
        selectedSongID = remainingIDs.isEmpty ? nil : remainingIDs[min(index, remainingIDs.count - 1)]
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
