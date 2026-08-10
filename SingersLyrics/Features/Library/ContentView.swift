import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    let metadataLookup: any TrackMetadataLookingUp
    @State private var searchText = ""
    @State private var songToDelete: Song?
    @State private var songForLink: Song?
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @AppStorage(PreferenceKey.sortMode) private var sortModeRaw = SongSortMode.manual.rawValue

    private var sortMode: SongSortMode {
        get { SongSortMode(rawValue: sortModeRaw) ?? .manual }
        nonmutating set { sortModeRaw = newValue.rawValue }
    }

    private var visibleSongs: [Song] {
        let sorted = sortMode.sorted(model.library.songs)
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter {
            "\($0.title) \($0.artist)".localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
        }
        .frame(minWidth: 820, minHeight: 560)
        .sheet(isPresented: Binding(
            get: { model.isCreatingSong },
            set: { model.isCreatingSong = $0 }
        )) {
            AppleMusicLinkSheet(song: nil, lookup: metadataLookup) { url, metadata in
                model.createSong(appleMusicURL: url, metadata: metadata)
            }
        }
        .sheet(item: $songForLink) { song in
            AppleMusicLinkSheet(song: song, lookup: metadataLookup) { url, metadata in
                var updated = song
                updated.appleMusicURL = url
                updated.title = metadata.title
                updated.artist = metadata.artist
                model.replaceSong(updated)
            }
        }
        .alert("Delete This Song?", isPresented: Binding(
            get: { songToDelete != nil },
            set: { if !$0 { songToDelete = nil } }
        ), presenting: songToDelete) { song in
            Button("Delete", role: .destructive) {
                model.deleteSong(song.id)
                songToDelete = nil
            }
            Button("Cancel", role: .cancel) { songToDelete = nil }
        } message: { song in
            Text("“\(song.title.isEmpty ? "Untitled" : song.title)” and its lyrics will be permanently removed.")
        }
        .alert("Library Error", isPresented: Binding(
            get: { model.storageIssue != nil },
            set: { if !$0 { model.storageIssue = nil } }
        )) {
            Button("Reveal Library in Finder") { model.revealLibrary() }
            Button("Dismiss", role: .cancel) { model.storageIssue = nil }
        } message: {
            Text(model.storageIssue?.message ?? "The library is unavailable.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { model.selectedSongID },
                set: { model.selectSong($0) }
            )) {
                ForEach(Array(visibleSongs.enumerated()), id: \.element.id) { index, song in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(song.title.isEmpty ? "Untitled" : song.title, systemImage: "music.note")
                            .lineLimit(1)
                        if !song.artist.isEmpty {
                            Text(song.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .padding(.leading, 23)
                        }
                    }
                    .tag(song.id)
                    .contextMenu {
                        Button("Change Apple Music Link…") { songForLink = song }
                        Divider()
                        Button("Move Up") {
                            sortMode = .manual
                            model.moveSong(song.id, offset: -1)
                        }
                        Button("Move Down") {
                            sortMode = .manual
                            model.moveSong(song.id, offset: 1)
                        }
                        Divider()
                        Button("Delete", role: .destructive) { songToDelete = song }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        [song.title.isEmpty ? "Untitled" : song.title, song.artist]
                            .filter { !$0.isEmpty }
                            .joined(separator: ", ")
                    )
                    .accessibilityIdentifier("songRow-\(index)")
                }
            }
            .overlay {
                if visibleSongs.isEmpty, !model.library.songs.isEmpty {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "music.note.list",
                        description: Text("Try another search.")
                    )
                }
            }
            .searchable(text: $searchText, prompt: "Search songs")
            .accessibilityIdentifier("songList")

            if !model.library.songs.isEmpty {
                Divider()
                HStack {
                    Text("Sort")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Sort", selection: $sortModeRaw) {
                        ForEach(SongSortMode.allCases, id: \.rawValue) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("songSortPicker")
                }
                .padding(8)
            }
        }
        .navigationTitle("Singers Lyrics")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.isCreatingSong = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("New Song from Apple Music")
                .accessibilityIdentifier("newSongButton")

            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if !model.isLoaded {
            ProgressView("Opening Library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let binding = model.bindingForSelectedSong() {
            SongWorkspaceView(
                song: binding,
                libraryPanelVisible: columnVisibility != .detailOnly
            ) {
                songForLink = binding.wrappedValue
            } onToggleLibrary: {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            } onDelete: {
                songToDelete = binding.wrappedValue
            }
        } else {
            ContentUnavailableView {
                Label("No Song Selected", systemImage: "music.note")
            } description: {
                Text("Add a song from Apple Music or select one from the sidebar.")
            } actions: {
                Button("New Song from Apple Music") { model.isCreatingSong = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("emptyNewSongButton")
            }
        }
    }
}

private struct SongWorkspaceView: View {
    @Binding var song: Song
    let libraryPanelVisible: Bool
    let onEditLink: () -> Void
    let onToggleLibrary: () -> Void
    let onDelete: () -> Void

    @AppStorage(PreferenceKey.editorPanelVisible) private var editorPanelVisible = true
    @AppStorage(PreferenceKey.previewPanelVisible) private var previewPanelVisible = true
    @State private var showsImport = false
    @State private var showsExport = false
    @State private var exportError: String?

    var body: some View {
        HSplitView {
            if editorPanelVisible {
                LyricsEditorView(song: $song)
                    .frame(minWidth: 420, idealWidth: 620)
            }
            if previewPanelVisible {
                PlayerView(song: song)
                    .frame(minWidth: 340, idealWidth: 520)
            }
        }
        .sheet(isPresented: $showsImport) {
            ImportLyricsSheet { lines in
                song.lines = lines.isEmpty ? [.blank()] : lines
            }
        }
        .fileExporter(
            isPresented: $showsExport,
            document: LRCFileDocument(song: song),
            contentType: .lrcLyrics,
            defaultFilename: exportFilename
        ) { result in
            if case let .failure(error) = result {
                exportError = error.localizedDescription
            }
        }
        .alert("Lyrics Could Not Be Exported", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "Unknown error")
        }
        .navigationTitle(metadataTitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showsImport = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Import Lyrics")
                .accessibilityLabel("Import Lyrics")
                .accessibilityIdentifier("importLyricsButton")

                Button {
                    showsExport = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Export LRC")
                .accessibilityLabel("Export LRC")
                .accessibilityIdentifier("exportLyricsButton")

                Button(action: onToggleLibrary) {
                    Image(systemName: "sidebar.left")
                }
                .help(libraryPanelVisible ? "Hide Song Library" : "Show Song Library")
                .accessibilityLabel(libraryPanelVisible ? "Hide Song Library" : "Show Song Library")
                .accessibilityIdentifier("toggleLibraryPanelButton")

                Button {
                    editorPanelVisible.toggle()
                } label: {
                    Image(systemName: "rectangle.leadinghalf.inset.filled")
                }
                .help(editorPanelVisible ? "Hide Editor Panel" : "Show Editor Panel")
                .disabled(editorPanelVisible && !previewPanelVisible)
                .accessibilityLabel(editorPanelVisible ? "Hide Editor Panel" : "Show Editor Panel")
                .accessibilityIdentifier("toggleEditorPanelButton")

                Button {
                    previewPanelVisible.toggle()
                } label: {
                    Image(systemName: "rectangle.trailinghalf.inset.filled")
                }
                .help(previewPanelVisible ? "Hide Preview Panel" : "Show Preview Panel")
                .disabled(previewPanelVisible && !editorPanelVisible)
                .accessibilityLabel(previewPanelVisible ? "Hide Preview Panel" : "Show Preview Panel")
                .accessibilityIdentifier("togglePreviewPanelButton")

                Button(action: onEditLink) {
                    Image(systemName: song.appleMusicURL == nil ? "link.badge.plus" : "link")
                }
                .help("Apple Music Link")
                .accessibilityIdentifier("appleMusicLinkButton")
                .accessibilityValue(song.appleMusicURL == nil ? "No link" : "Linked")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .help("Delete Selected Song")
                .accessibilityLabel("Delete Selected Song")
                .accessibilityIdentifier("deleteSongButton")
            }
        }
    }

    private var metadataTitle: String {
        [song.title.isEmpty ? "Untitled" : song.title, song.artist]
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }

    private var exportFilename: String {
        let source = song.title.isEmpty ? "Lyrics" : song.title
        let forbidden = CharacterSet(charactersIn: "/:")
        let safe = source
            .components(separatedBy: forbidden)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (safe.isEmpty ? "Lyrics" : safe) + ".lrc"
    }
}

private struct AppleMusicLinkSheet: View {
    let song: Song?
    let lookup: any TrackMetadataLookingUp
    let onSave: (URL, TrackMetadata) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var linkText: String
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var linkFieldFocused: Bool

    init(
        song: Song?,
        lookup: any TrackMetadataLookingUp,
        onSave: @escaping (URL, TrackMetadata) -> Void
    ) {
        self.song = song
        self.lookup = lookup
        self.onSave = onSave
        _linkText = State(initialValue: song?.appleMusicURL?.absoluteString ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(song == nil ? "New Song from Apple Music" : "Change Apple Music Link")
                .font(.title2.bold())
            Text("Paste the song’s Apple Music link. The title and singer will come from Apple Music metadata.")
                .foregroundStyle(.secondary)
            TextField("https://music.apple.com/…", text: $linkText)
                .textFieldStyle(.roundedBorder)
                .focused($linkFieldFocused)
                .onSubmit { Task { await save() } }
                .accessibilityIdentifier("appleMusicURLField")

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("appleMusicLinkError")
            }

            HStack {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button(song == nil ? "Create Song" : "Save") {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)
                .accessibilityIdentifier("saveAppleMusicLinkButton")
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { linkFieldFocused = true }
    }

    @MainActor
    private func save() async {
        linkFieldFocused = false
        await Task.yield()
        let trimmed = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ITunesTrackMetadataService.trackID(from: url) != nil else {
            errorMessage = TrackMetadataError.unsupportedURL.localizedDescription
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            guard let metadata = try await lookup.lookup(url: url),
                  !metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TrackMetadataError.trackNotFound
            }
            onSave(url, metadata)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
