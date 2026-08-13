import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    let metadataLookup: any TrackMetadataLookingUp
    @State private var searchText = ""
    @State private var songToDelete: Song?
    @State private var songForLink: Song?
    @State private var importSongID: UUID?
    @State private var exportSong: Song?
    @State private var exportError: String?
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var workspaceLayout = WorkspaceLayout.both
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
        splitView
            .navigationSplitViewStyle(.prominentDetail)
            .frame(minWidth: 1_180, minHeight: 560)
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
            .sheet(isPresented: Binding(
                get: { importSongID != nil },
                set: { if !$0 { importSongID = nil } }
            )) {
                ImportLyricsSheet { lines in
                    guard let importSongID,
                          var song = model.song(withID: importSongID) else { return }
                    song.lines = lines.isEmpty ? [.blank()] : lines
                    model.replaceSong(song)
                    self.importSongID = nil
                }
            }
            .fileExporter(
                isPresented: Binding(
                    get: { exportSong != nil },
                    set: { if !$0 { exportSong = nil } }
                ),
                document: exportSong.map { LRCFileDocument(song: $0) },
                contentType: .lrcLyrics,
                defaultFilename: exportSong.map { exportFilename(for: $0) }
            ) { result in
                if case let .failure(error) = result {
                    exportError = error.localizedDescription
                }
                exportSong = nil
            }
            .alert("Lyrics Could Not Be Exported", isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )) {
                Button("OK", role: .cancel) { exportError = nil }
            } message: {
                Text(exportError ?? "Unknown error")
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

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } detail: {
            workspace
                .toolbar {
                    detailToolbar
                }
                .searchable(text: $searchText, placement: .toolbar, prompt: "Search songs")
                .searchPresentationToolbarBehavior(.avoidHidingContent)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
    }

    @ViewBuilder
    private var workspace: some View {
        switch workspaceLayout {
        case .both:
            HSplitView {
                editorColumn
                    .frame(minWidth: 420, idealWidth: 520, maxWidth: .infinity)
                playerColumn
                    .frame(minWidth: 420, idealWidth: 620, maxWidth: .infinity)
            }
        case .editorOnly:
            editorColumn
        case .playerOnly:
            playerColumn
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
    }

    @ViewBuilder
    private var editorColumn: some View {
        if !model.isLoaded {
            ProgressView("Opening Library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let binding = model.bindingForSelectedSong() {
            VStack(spacing: 0) {
                songMetadataHeader(for: binding.wrappedValue)

                LyricsEditorView(song: binding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(.background)
        } else {
            ContentUnavailableView(
                "No Song Selected",
                systemImage: "text.quote",
                description: Text("Select a song to edit its lyrics.")
            )
        }
    }

    private var playerColumn: some View {
        Group {
            if !model.isLoaded {
                ProgressView("Opening Library…")
            } else if let song = selectedSong {
                PlayerView(song: song)
            } else {
                ContentUnavailableView {
                    Label("No Song Selected", systemImage: "music.note")
                } description: {
                    Text("Add a song from Apple Music or select one from the library.")
                } actions: {
                    Button("New Song from Apple Music") {
                        model.isCreatingSong = true
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("emptyNewSongButton")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .backgroundExtensionEffect()
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarSpacer(.flexible, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 16) {
                workspaceToolbarButtons
                lyricsFileToolbarButtons
                songToolbarButtons
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var workspaceToolbarButtons: some View {
        HStack(spacing: 0) {
            Button {
                toggleWorkspaceColumn(.editor)
            } label: {
                Image(systemName: "rectangle.leadinghalf.inset.filled")
            }
            .help(workspaceToggleLabel(for: .editor))
            .accessibilityLabel(workspaceToggleLabel(for: .editor))
            .accessibilityIdentifier("toggleEditorPanelButton")
            .accessibilityValue(workspaceLayout.accessibilityValue)

            Button {
                toggleWorkspaceColumn(.player)
            } label: {
                Image(systemName: "rectangle.trailinghalf.inset.filled")
            }
            .help(workspaceToggleLabel(for: .player))
            .accessibilityLabel(workspaceToggleLabel(for: .player))
            .accessibilityIdentifier("togglePreviewPanelButton")
            .accessibilityValue(workspaceLayout.accessibilityValue)
        }
    }

    private var lyricsFileToolbarButtons: some View {
        HStack(spacing: 0) {
            Button {
                importSongID = selectedSong?.id
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .help("Import Lyrics")
            .accessibilityLabel("Import Lyrics")
            .accessibilityIdentifier("importLyricsButton")
            .disabled(selectedSong == nil)

            Button {
                exportSong = selectedSong
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Export LRC")
            .accessibilityLabel("Export LRC")
            .accessibilityIdentifier("exportLyricsButton")
            .disabled(selectedSong == nil)
        }
    }

    private var songToolbarButtons: some View {
        HStack(spacing: 0) {
            Button {
                model.isCreatingSong = true
            } label: {
                Image(systemName: "plus")
            }
            .help("New Song from Apple Music")
            .accessibilityIdentifier("newSongButton")

            Button {
                songForLink = selectedSong
            } label: {
                Image(systemName: selectedSong?.appleMusicURL == nil ? "link.badge.plus" : "link")
            }
            .help("Apple Music Link")
            .accessibilityIdentifier("appleMusicLinkButton")
            .accessibilityValue(selectedSong?.appleMusicURL == nil ? "No link" : "Linked")
            .disabled(selectedSong == nil)

            Button(role: .destructive) {
                songToDelete = selectedSong
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete Selected Song")
            .accessibilityLabel("Delete Selected Song")
            .accessibilityIdentifier("deleteSongButton")
            .disabled(selectedSong == nil)
        }
    }

    private var selectedSong: Song? {
        guard let selectedSongID = model.selectedSongID else { return nil }
        return model.song(withID: selectedSongID)
    }

    private func toggleWorkspaceColumn(_ column: WorkspaceColumn) {
        let focusedLayout: WorkspaceLayout = switch column {
        case .editor: .editorOnly
        case .player: .playerOnly
        }
        workspaceLayout = workspaceLayout == focusedLayout ? .both : focusedLayout
    }

    private func workspaceToggleLabel(for column: WorkspaceColumn) -> String {
        let focusedLayout: WorkspaceLayout = column == .editor ? .editorOnly : .playerOnly
        if workspaceLayout == focusedLayout {
            return "Show Editor and Player Columns"
        }
        return column == .editor ? "Show Only Editor Column" : "Show Only Player Column"
    }

    private func songMetadataHeader(for song: Song) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(song.title.isEmpty ? "Untitled" : song.title)
                .font(.headline)
                .lineLimit(1)

            if !song.artist.isEmpty {
                Text("|")
                    .foregroundStyle(.tertiary)
                Text(song.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 2)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [song.title.isEmpty ? "Untitled" : song.title, song.artist]
                .filter { !$0.isEmpty }
                .joined(separator: " | ")
        )
        .accessibilityIdentifier("songMetadataHeader")
    }

    private func exportFilename(for song: Song) -> String {
        let source = song.title.isEmpty ? "Lyrics" : song.title
        let forbidden = CharacterSet(charactersIn: "/:")
        let safe = source
            .components(separatedBy: forbidden)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (safe.isEmpty ? "Lyrics" : safe) + ".lrc"
    }
}

private enum WorkspaceColumn: Equatable {
    case editor
    case player
}

private enum WorkspaceLayout: Equatable {
    case both
    case editorOnly
    case playerOnly

    var accessibilityValue: String {
        switch self {
        case .both: "Editor and Player"
        case .editorOnly: "Editor Only"
        case .playerOnly: "Player Only"
        }
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
