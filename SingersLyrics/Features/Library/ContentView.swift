import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum AppLayoutMetrics {
    static let minimumWindowWidth: CGFloat = 900
    static let minimumWindowHeight: CGFloat = 560
    static let minimumSidebarWidth: CGFloat = 160
    static let idealSidebarWidth: CGFloat = 220
    static let maximumSidebarWidth: CGFloat = 300
    static let minimumEditorColumnWidth: CGFloat = 360
    static let minimumPlayerColumnWidth: CGFloat = 500
    static let metadataHeaderHorizontalInset: CGFloat = 16
    static let maximumMetadataHeaderWidth: CGFloat = 360
    static let sidebarCollapseWidth: CGFloat = 1_020
    static let sidebarRestoreWidth: CGFloat = 1_080

    static func metadataHeaderWidth(forEditorWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return min(
            maximumMetadataHeaderWidth,
            max(0, width - 2 * metadataHeaderHorizontalInset)
        )
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    let metadataLookup: any TrackMetadataLookingUp
    @State private var searchText = ""
    @State private var songIDsToDelete: Set<UUID> = []
    @State private var songForDetails: Song?
    @State private var songForLink: Song?
    @State private var importSongID: UUID?
    @State private var pendingExport: PendingSongExport?
    @State private var showsSongBundleImporter = false
    @State private var songBundleImportError: String?
    @State private var exportError: String?
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var automaticallyCollapsedSidebar = false
    @State private var workspaceLayout = WorkspaceLayout.both
    @State private var editorColumnWidth: CGFloat = AppLayoutMetrics.minimumEditorColumnWidth
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
            .navigationSplitViewStyle(.balanced)
            .frame(
                minWidth: AppLayoutMetrics.minimumWindowWidth,
                minHeight: AppLayoutMetrics.minimumWindowHeight
            )
            .onGeometryChange(for: CGFloat.self, of: { proxy in
                proxy.size.width
            }) { width in
                updateSidebarVisibility(for: width)
            }
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
                    get: { pendingExport != nil },
                    set: { if !$0 { pendingExport = nil } }
                ),
                document: pendingExport?.document,
                contentType: pendingExport?.contentType ?? .singersLyricsSongBundle,
                defaultFilename: pendingExport?.defaultFilename
            ) { result in
                if case let .failure(error) = result {
                    exportError = error.localizedDescription
                }
                pendingExport = nil
            }
            .fileImporter(
                isPresented: $showsSongBundleImporter,
                allowedContentTypes: [.singersLyricsSongBundle]
            ) { result in
                do {
                    let url = try result.get()
                    try importSongBundle(from: url)
                } catch {
                    songBundleImportError = error.localizedDescription
                }
            }
            .alert("Export Could Not Be Completed", isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )) {
                Button("OK", role: .cancel) { exportError = nil }
            } message: {
                Text(exportError ?? "Unknown error")
            }
            .alert("Songs Could Not Be Imported", isPresented: Binding(
                get: { songBundleImportError != nil },
                set: { if !$0 { songBundleImportError = nil } }
            )) {
                Button("OK", role: .cancel) { songBundleImportError = nil }
            } message: {
                Text(songBundleImportError ?? "Unknown error")
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
                .navigationSplitViewColumnWidth(
                    min: AppLayoutMetrics.minimumSidebarWidth,
                    ideal: AppLayoutMetrics.idealSidebarWidth,
                    max: AppLayoutMetrics.maximumSidebarWidth
                )
        } detail: {
            workspace
                .toolbar {
                    detailToolbar
                }
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
    }

    @ViewBuilder
    private var workspace: some View {
        if !model.isLoaded {
            ProgressView("Opening Library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let song = selectedSong,
                  let songBinding = model.bindingForSelectedSong() {
            switch workspaceLayout {
            case .both:
                HSplitView {
                    editorColumn(song: songBinding)
                        .frame(
                            minWidth: AppLayoutMetrics.minimumEditorColumnWidth,
                            idealWidth: 520,
                            maxWidth: .infinity
                        )
                    playerColumn(song: song)
                        .frame(
                            minWidth: AppLayoutMetrics.minimumPlayerColumnWidth,
                            idealWidth: 620,
                            maxWidth: .infinity
                        )
                }
            case .editorOnly:
                editorColumn(song: songBinding)
            case .playerOnly:
                playerColumn(song: song)
            }
        } else {
            songEntryView
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if !model.library.songs.isEmpty {
                HStack {
                    Spacer(minLength: 0)
                    sidebarToolbarControls
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 32)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("inlineSidebarControls")

                Divider()
            }

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

    private func editorColumn(song: Binding<Song>) -> some View {
        LyricsEditorView(song: song)
            .id(song.wrappedValue.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
            .onGeometryChange(for: CGFloat.self, of: { proxy in
                proxy.size.width
            }) { width in
                editorColumnWidth = width
            }
    }

    private func playerColumn(song: Song) -> some View {
        PlayerView(song: song)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .backgroundExtensionEffect()
    }

    private var sidebarToolbarControls: some View {
        HStack(spacing: 6) {
            newSongButton
            songSortMenu
        }
        .labelStyle(.iconOnly)
        .fixedSize()
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
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .fixedSize()
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
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
                    .frame(width: metadataHeaderWidth, alignment: .leading)
                    .clipped()
            }
            .sharedBackgroundVisibility(.hidden)
        }

        ToolbarSpacer(.flexible, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            workspaceToolbarButtons
        } label: {
            Text("Workspace")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            lyricsFileToolbarButtons
        } label: {
            Text("Lyrics")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            songToolbarButtons
        } label: {
            Text("Song")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            ToolbarSearchField(text: $searchText)
                .frame(width: 180, height: 24)
                .accessibilityIdentifier("songSearchField")
        } label: {
            Text("Search")
        }
    }

    private var workspaceToolbarButtons: some View {
        ControlGroup {
            Button {
                toggleWorkspaceColumn(.editor)
            } label: {
                Label("Editor", systemImage: "rectangle.leadinghalf.inset.filled")
            }
            .help(workspaceToggleLabel(for: .editor))
            .accessibilityLabel(workspaceToggleLabel(for: .editor))
            .accessibilityIdentifier("toggleEditorPanelButton")
            .accessibilityValue(workspaceLayout.accessibilityValue)

            Button {
                toggleWorkspaceColumn(.player)
            } label: {
                Label("Player", systemImage: "rectangle.trailinghalf.inset.filled")
            }
            .help(workspaceToggleLabel(for: .player))
            .accessibilityLabel(workspaceToggleLabel(for: .player))
            .accessibilityIdentifier("togglePreviewPanelButton")
            .accessibilityValue(workspaceLayout.accessibilityValue)
        }
        .controlGroupStyle(.navigation)
        .fixedSize()
    }

    private var lyricsFileToolbarButtons: some View {
        ControlGroup {
            Button {
                importSongID = selectedSong?.id
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .help("Import Lyrics")
            .accessibilityLabel("Import Lyrics")
            .accessibilityIdentifier("importLyricsButton")
            .disabled(selectedSong == nil)

            Button {
                prepareSongBundleExport(model.selectedSongIDs)
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help(songBundleExportLabel)
            .accessibilityLabel(songBundleExportLabel)
            .accessibilityIdentifier("exportLyricsButton")
            .disabled(model.selectedSongIDs.isEmpty)
        }
        .controlGroupStyle(.navigation)
        .fixedSize()
    }

    private var songToolbarButtons: some View {
        ControlGroup {
            Button {
                songForLink = selectedSong
            } label: {
                Label(
                    "Music Link",
                    systemImage: selectedSong?.appleMusicURL == nil ? "link.badge.plus" : "link"
                )
            }
            .help("Apple Music Link")
            .accessibilityIdentifier("appleMusicLinkButton")
            .accessibilityValue(selectedSong?.appleMusicURL == nil ? "No link" : "Linked")
            .disabled(selectedSong == nil)

            Button(role: .destructive) {
                prepareSongDeletion(model.selectedSongIDs)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .help(deleteButtonLabel)
            .accessibilityLabel(deleteButtonLabel)
            .accessibilityIdentifier("deleteSongButton")
            .disabled(model.selectedSongIDs.isEmpty)
        }
        .controlGroupStyle(.navigation)
        .fixedSize()
    }

    private var newSongButton: some View {
        Menu {
            Button("New Song from Apple Music…") {
                model.isCreatingSong = true
            }
            .accessibilityIdentifier("newSongFromAppleMusicMenuItem")

            Button("Import Song Bundle…") {
                showsSongBundleImporter = true
            }
            .accessibilityIdentifier("importSongBundleMenuItem")
        } label: {
            Label("Add Songs", systemImage: "plus")
        }
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .help("Add or Import Songs")
        .accessibilityLabel("Add or Import Songs")
        .accessibilityIdentifier("newSongButton")
    }

    private var selectedSong: Song? {
        guard let selectedSongID = model.selectedSongID else { return nil }
        return model.song(withID: selectedSongID)
    }

    private var metadataHeaderWidth: CGFloat {
        AppLayoutMetrics.metadataHeaderWidth(forEditorWidth: editorColumnWidth)
    }

    private var sidebarIsVisible: Bool {
        columnVisibility != .detailOnly
    }

    private func updateSidebarVisibility(for width: CGFloat) {
        if width < AppLayoutMetrics.sidebarCollapseWidth {
            guard sidebarIsVisible else { return }
            automaticallyCollapsedSidebar = true
            columnVisibility = .detailOnly
        } else if width >= AppLayoutMetrics.sidebarRestoreWidth,
                  automaticallyCollapsedSidebar {
            automaticallyCollapsedSidebar = false
            columnVisibility = .all
        }
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
                .truncationMode(.tail)
            Text("|")
                .foregroundStyle(.tertiary)
                .fixedSize()
            Text(song.artist.isEmpty ? "Unknown Singer" : song.artist)
                .font(.title2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(song.title.isEmpty ? "Untitled" : song.title) | \(song.artist.isEmpty ? "Unknown Singer" : song.artist)")
        .accessibilityIdentifier("songMetadataHeader")
    }

    @ViewBuilder
    private var songEntryView: some View {
        ContentUnavailableView {
            Label(
                model.library.songs.isEmpty ? "No Songs Yet" : "No Song Selected",
                systemImage: "music.note.list"
            )
        } description: {
            if model.library.songs.isEmpty {
                Text("Add a song from Apple Music or import a Singers Lyrics song bundle.")
            } else {
                Text("Select a song, add one from Apple Music, or import a Singers Lyrics song bundle.")
            }
        } actions: {
            HStack {
                Button("New Song from Apple Music") {
                    model.isCreatingSong = true
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("emptyNewSongButton")

                Button("Import Song Bundle…") {
                    showsSongBundleImporter = true
                }
                .accessibilityIdentifier("emptyImportSongBundleButton")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("songEntryView")
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

        Button(songIDs.count == 1 ? "Export Selected Song…" : "Export Selected Songs…") {
            prepareSongBundleExport(songIDs)
        }
        .disabled(songIDs.isEmpty)

        Button("Export Lyrics as LRC…") {
            prepareLRCExport(song)
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

    private var songBundleExportLabel: String {
        model.selectedSongIDs.count > 1 ? "Export Selected Songs" : "Export Selected Song"
    }

    private func prepareSongBundleExport(_ ids: Set<UUID>) {
        let songs = model.library.songs.filter { ids.contains($0.id) }
        guard !songs.isEmpty else { return }
        do {
            pendingExport = PendingSongExport(
                document: SongExportFileDocument(
                    data: try SongBundleCodec.encode(SongBundle(songs: songs))
                ),
                contentType: .singersLyricsSongBundle,
                defaultFilename: songBundleFilename(for: songs)
            )
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func prepareLRCExport(_ song: Song?) {
        guard let song else { return }
        pendingExport = PendingSongExport(
            document: SongExportFileDocument(data: Data(LRCExporter.render(song: song).utf8)),
            contentType: .lrcLyrics,
            defaultFilename: lrcExportFilename(for: song)
        )
    }

    private func importSongBundle(from url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let bundle = try SongBundleCodec.decode(Data(contentsOf: url))
        model.importSongs(bundle.songs)
    }

    private func songBundleFilename(for songs: [Song]) -> String {
        let source = songs.count == 1
            ? (songs[0].title.isEmpty ? "Untitled" : songs[0].title)
            : "Singers Lyrics - \(songs.count) Songs"
        return safeFilenameStem(source, fallback: "Singers Lyrics") + ".singerslyrics"
    }

    private func lrcExportFilename(for song: Song) -> String {
        let source = song.title.isEmpty ? "Lyrics" : song.title
        return safeFilenameStem(source, fallback: "Lyrics") + ".lrc"
    }

    private func safeFilenameStem(_ source: String, fallback: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:")
        let safe = source
            .components(separatedBy: forbidden)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? fallback : safe
    }
}

private struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.placeholderString = "Search songs"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.delegate = context.coordinator
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        guard searchField.stringValue != text else { return }
        searchField.stringValue = text
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            text = searchField.stringValue
        }
    }
}

private struct PendingSongExport {
    var document: SongExportFileDocument
    var contentType: UTType
    var defaultFilename: String
}

private struct SongExportFileDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.singersLyricsSongBundle, .lrcLyrics]
    }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
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
