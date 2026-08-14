import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    let metadataLookup: any TrackMetadataLookingUp
    @State private var searchText = ""
    @State private var songIDsToDelete: Set<UUID> = []
    @State private var songForDetails: Song?
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
                    model.updateAppleMusicLink(
                        for: song.id,
                        appleMusicURL: url,
                        metadata: metadata
                    )
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
            .sheet(item: $songForDetails) { song in
                SongDetailsSheet(song: song) { title, artist in
                    var updated = song
                    updated.title = title
                    updated.artist = artist
                    model.replaceSong(updated)
                }
            }
            .alert(deleteConfirmationTitle, isPresented: Binding(
                get: { !songIDsToDelete.isEmpty },
                set: { if !$0 { songIDsToDelete = [] } }
            )) {
                Button("Delete", role: .destructive) {
                    model.deleteSongs(songIDsToDelete)
                    songIDsToDelete = []
                }
                Button("Cancel", role: .cancel) { songIDsToDelete = [] }
            } message: {
                Text(deleteConfirmationMessage)
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
                .toolbar {
                    sidebarToolbar
                }
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
        if model.isLoaded, model.library.songs.isEmpty {
            emptyLibraryView
        } else {
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
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Table(
                visibleSongs,
                selection: Binding(
                    get: { model.selectedSongIDs },
                    set: { model.selectSongs($0) }
                )
            ) {
                TableColumn("Songs") { song in
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
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        [song.title.isEmpty ? "Untitled" : song.title, song.artist]
                            .filter { !$0.isEmpty }
                            .joined(separator: ", ")
                    )
                    .accessibilityIdentifier("songRow-\(visibleSongIndex(for: song))")
                }
            }
            .contextMenu(forSelectionType: UUID.self) { songIDs in
                songContextMenu(for: songIDs)
            }
            .tableColumnHeaders(.hidden)
            .tableStyle(.inset(alternatesRowBackgrounds: false))
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
        }
        .navigationTitle("Singers Lyrics")
    }

    @ViewBuilder
    private var editorColumn: some View {
        if !model.isLoaded {
            ProgressView("Opening Library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let binding = model.bindingForSelectedSong() {
            LyricsEditorView(song: binding)
                .id(binding.wrappedValue.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
        } else {
            emptySelectionPlaceholder
        }
    }

    private var playerColumn: some View {
        Group {
            if !model.isLoaded {
                ProgressView("Opening Library…")
            } else if let song = selectedSong {
                PlayerView(song: song)
            } else {
                emptySelectionPlaceholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .backgroundExtensionEffect()
    }

    @ToolbarContentBuilder
    private var sidebarToolbar: some ToolbarContent {
        if !model.library.songs.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                songSortMenu
            }
        }
    }

    private var songSortMenu: some View {
        Menu {
            ForEach(SongSortMode.allCases, id: \.rawValue) { mode in
                Toggle(
                    mode.title,
                    isOn: Binding(
                        get: { sortMode == mode },
                        set: { isSelected in
                            if isSelected {
                                sortMode = mode
                            }
                        }
                    )
                )
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .fixedSize()
        .help("Sort Songs")
        .accessibilityLabel("Sort Songs")
        .accessibilityValue(sortMode.title)
        .accessibilityIdentifier("songSortPicker")
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        if let song = selectedSong, workspaceLayout.showsEditor {
            ToolbarItem(placement: .navigation) {
                songMetadataHeader(for: song)
                    .padding(.leading, 4)
            }
            .sharedBackgroundVisibility(.hidden)
        }

        ToolbarSpacer(.flexible, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            workspaceToolbarButtons
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            lyricsFileToolbarButtons
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            songToolbarButtons
        }
    }

    private var workspaceToolbarButtons: some View {
        ControlGroup {
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
        .controlGroupStyle(.navigation)
    }

    private var lyricsFileToolbarButtons: some View {
        ControlGroup {
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
        .controlGroupStyle(.navigation)
    }

    private var songToolbarButtons: some View {
        ControlGroup {
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
                prepareSongDeletion(model.selectedSongIDs)
            } label: {
                Image(systemName: "trash")
            }
            .help(deleteButtonLabel)
            .accessibilityLabel(deleteButtonLabel)
            .accessibilityIdentifier("deleteSongButton")
            .disabled(model.selectedSongIDs.isEmpty)
        }
        .controlGroupStyle(.navigation)
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
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            Text("|")
                .foregroundStyle(.tertiary)
            Text(song.artist.isEmpty ? "Unknown Singer" : song.artist)
                .font(.title2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(song.title.isEmpty ? "Untitled" : song.title) | \(song.artist.isEmpty ? "Unknown Singer" : song.artist)")
        .accessibilityIdentifier("songMetadataHeader")
    }

    @ViewBuilder
    private var emptyLibraryView: some View {
        ContentUnavailableView {
            Label("No Songs Yet", systemImage: "music.note.list")
        } description: {
            Text("Add a song from Apple Music to begin.")
        } actions: {
            Button("New Song from Apple Music") {
                model.isCreatingSong = true
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("emptyNewSongButton")
        }
    }

    private var emptySelectionPlaceholder: some View {
        ContentUnavailableView(
            "Select One Song",
            systemImage: "music.note",
            description: Text("Select one song to edit lyrics or open the player.")
        )
    }

    private var deleteButtonLabel: String {
        model.selectedSongIDs.count > 1
            ? "Delete Selected Songs"
            : "Delete Selected Song"
    }

    private var deleteConfirmationTitle: String {
        songIDsToDelete.count > 1 ? "Delete Selected Songs?" : "Delete This Song?"
    }

    private var deleteConfirmationMessage: String {
        if songIDsToDelete.count > 1 {
            return "\(songIDsToDelete.count) songs and their lyrics will be permanently removed."
        }
        let title = songIDsToDelete.first
            .flatMap { model.song(withID: $0)?.title }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "Untitled"
        return "“\(title)” and its lyrics will be permanently removed."
    }

    @ViewBuilder
    private func songContextMenu(for requestedIDs: Set<UUID>) -> some View {
        let songIDs = requestedIDs.intersection(Set(model.library.songs.map(\.id)))
        let song = songIDs.count == 1
            ? songIDs.first.flatMap { model.song(withID: $0) }
            : nil

        Button("Edit Title and Singer…") {
            songForDetails = song
        }
        .disabled(song == nil)

        Button("Duplicate") {
            model.duplicateSongs(songIDs)
        }
        .disabled(songIDs.isEmpty)

        Button("Change Apple Music Link…") {
            songForLink = song
        }
        .disabled(song == nil)

        Divider()

        Button("Move Up") {
            guard let song else { return }
            sortMode = .manual
            model.moveSong(song.id, offset: -1)
        }
        .disabled(song == nil)

        Button("Move Down") {
            guard let song else { return }
            sortMode = .manual
            model.moveSong(song.id, offset: 1)
        }
        .disabled(song == nil)

        Divider()

        Button("Delete", role: .destructive) {
            prepareSongDeletion(songIDs)
        }
        .disabled(songIDs.isEmpty)
    }

    private func prepareSongDeletion(_ ids: Set<UUID>) {
        songIDsToDelete = ids.intersection(Set(model.library.songs.map(\.id)))
    }

    private func visibleSongIndex(for song: Song) -> Int {
        visibleSongs.firstIndex { $0.id == song.id } ?? 0
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

    var showsEditor: Bool {
        self != .playerOnly
    }

    var accessibilityValue: String {
        switch self {
        case .both: "Editor and Player"
        case .editorOnly: "Editor Only"
        case .playerOnly: "Player Only"
        }
    }
}

private struct SongDetailsSheet: View {
    let song: Song
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var artist: String
    @FocusState private var titleFocused: Bool

    init(song: Song, onSave: @escaping (String, String) -> Void) {
        self.song = song
        self.onSave = onSave
        _title = State(initialValue: song.title)
        _artist = State(initialValue: song.artist)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Song Details")
                .font(.title2.bold())
            TextField("Title", text: $title)
                .focused($titleFocused)
                .accessibilityIdentifier("songDetailsTitleField")
            TextField("Singer", text: $artist)
                .accessibilityIdentifier("songDetailsArtistField")

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    onSave(
                        title.trimmingCharacters(in: .whitespacesAndNewlines),
                        artist.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("saveSongDetailsButton")
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { titleFocused = true }
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
            Text(linkDescription)
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

    private var linkDescription: String {
        if song == nil {
            return "Paste the song’s Apple Music link. The title and singer will come from Apple Music metadata."
        }
        return "Paste the song’s Apple Music link. Its Music metadata will be refreshed without changing the title and singer shown in this app."
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
