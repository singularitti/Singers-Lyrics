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
    static let minimumWorkspaceWidth = minimumEditorColumnWidth + minimumPlayerColumnWidth + 1
    static let metadataHeaderHorizontalInset: CGFloat = 16
    static let sidebarRestorationClearance: CGFloat = 48
    static let toolbarControlWidth: CGFloat = 40
    static let toolbarControlHeight: CGFloat = 36
    static let toolbarGroupSpacing: CGFloat = 12
    static let toolbarSearchWidth: CGFloat = 180
    static let minimumToolbarSearchWidth: CGFloat = 100
    static let toolbarActionsWithoutSearchWidth = 8 * toolbarControlWidth + 3 * toolbarGroupSpacing
    static let maximumToolbarActionsWidth = toolbarActionsWithoutSearchWidth + toolbarSearchWidth
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
    @State private var songBundleImportError: String?
    @State private var exportError: String?
    @State private var sidebarIsVisible = true
    @State private var manuallyCollapsedSidebar = false
    @State private var workspaceLayout = WorkspaceLayout.both
    @State private var windowWidth = CGFloat.infinity
    @State private var showsCompactSearch = false
    @State private var sidebarWidth = AppLayoutMetrics.idealSidebarWidth
    @State private var sidebarDragStartWidth: CGFloat?
    @State private var toolbarLayout = ColumnToolbarLayout()
    @State private var expandedSidebarSections: Set<SidebarSectionID> = []
    @State private var selectedTagKeys: Set<String> = []
    @State private var recentScope = RecentScope.today
    @AppStorage(PreferenceKey.sortMode) private var sortModeRaw = SongSortMode.title.rawValue

    private var sortMode: SongSortMode {
        get { SongSortMode(rawValue: sortModeRaw) ?? .title }
        nonmutating set { sortModeRaw = newValue.rawValue }
    }

    private var tagSummaries: [TagSummary] {
        var namesByKey: [String: String] = [:]
        var countsByKey: [String: Int] = [:]

        for song in model.library.songs {
            var songKeys: Set<String> = []
            for tag in song.tags {
                let key = TagAppearance.normalizedKey(tag)
                guard !key.isEmpty else { continue }
                namesByKey[key, default: tag] = namesByKey[key] ?? tag
                songKeys.insert(key)
            }
            for key in songKeys {
                countsByKey[key, default: 0] += 1
            }
        }

        return namesByKey.map { key, name in
            TagSummary(key: key, name: name, songCount: countsByKey[key, default: 0])
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var availableTagKeys: Set<String> {
        Set(tagSummaries.map(\.key))
    }

    private var songsSectionSongs: [Song] {
        let filteredByTags = model.library.songs.filter { song in
            selectedTagKeys.isEmpty || song.tags.contains {
                selectedTagKeys.contains(TagAppearance.normalizedKey($0))
            }
        }
        return sortMode.sorted(filteredByTags.filter(matchesSearch))
    }

    private var recentSongs: [Song] {
        model.library.songs
            .filter { song in
                guard let lastPlayedAt = song.lastPlayedAt else { return false }
                return recentScope.contains(lastPlayedAt)
            }
            .filter(matchesSearch)
            .sorted { lhs, rhs in
                let lhsDate = lhs.lastPlayedAt ?? .distantPast
                let rhsDate = rhs.lastPlayedAt ?? .distantPast
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    private var favoriteSongs: [Song] {
        sortMode.sorted(model.library.songs.filter { $0.isFavorite && matchesSearch($0) })
    }

    var body: some View {
        splitView
            .frame(
                minWidth: AppLayoutMetrics.minimumWindowWidth,
                minHeight: AppLayoutMetrics.minimumWindowHeight
            )
            .background(
                WindowWidthReader(width: $windowWidth)
            )
            .onChange(of: windowWidth) { _, width in
                updateResponsiveLayout(for: width)
            }
            .onChange(of: availableTagKeys) { _, availableKeys in
                selectedTagKeys.formIntersection(availableKeys)
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
                isPresented: Binding(
                    get: { model.isImportingSongBundle },
                    set: { model.isImportingSongBundle = $0 }
                ),
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
                SongDetailsSheet(
                    song: song,
                    availableTags: tagSummaries.map(\.name)
                ) { title, artist, album, tags in
                    var updated = song
                    updated.title = title
                    updated.artist = artist
                    updated.album = album
                    updated.tags = tags
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
        HStack(spacing: 0) {
            if sidebarIsVisible {
                sidebar
                    .frame(width: sidebarWidth)
                    .background(ColumnToolbarAnchor(layout: toolbarLayout, column: .sidebar))
                    .background {
                        Rectangle().fill(.bar).ignoresSafeArea()
                    }
                sidebarDivider
            }
            workspace
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ColumnToolbarAnchor(layout: toolbarLayout, column: .workspace))
        }
        .background {
            ColumnToolbarInstaller(
                layout: toolbarLayout,
                sidebarIsVisible: sidebarIsVisible,
                showsSidebarToggle: showsSidebarToggle,
                showsEditor: workspaceLayout.showsEditor,
                showsPlayer: workspaceLayout != .editorOnly,
                title: selectedSong?.title,
                artist: selectedSong?.artist,
                actions: AnyView(toolbarActions),
                onToggleSidebar: {
                    manuallyCollapsedSidebar = sidebarIsVisible
                    sidebarIsVisible.toggle()
                }
            )
        }
    }

    private var sidebarDivider: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(coordinateSpace: .global).onChanged { value in
                        if sidebarDragStartWidth == nil { sidebarDragStartWidth = sidebarWidth }
                        resizeSidebar(to: (sidebarDragStartWidth ?? sidebarWidth) + value.translation.width)
                    }.onEnded { _ in
                        sidebarDragStartWidth = nil
                    })
            }
            .accessibilityLabel("Sidebar width")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: resizeSidebar(to: sidebarWidth + 10)
                case .decrement: resizeSidebar(to: sidebarWidth - 10)
                @unknown default: break
                }
            }
    }

    private func resizeSidebar(to width: CGFloat) {
        sidebarWidth = min(
            AppLayoutMetrics.maximumSidebarWidth,
            max(
                AppLayoutMetrics.minimumSidebarWidth,
                min(width, windowWidth - AppLayoutMetrics.minimumWorkspaceWidth - 1)
            )
        )
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
                            idealWidth: AppLayoutMetrics.minimumEditorColumnWidth,
                            maxWidth: .infinity
                        )
                    playerColumn(song: song)
                        .frame(
                            minWidth: AppLayoutMetrics.minimumPlayerColumnWidth,
                            idealWidth: AppLayoutMetrics.minimumPlayerColumnWidth,
                            maxWidth: .infinity
                        )
                }
                .frame(
                    minWidth: AppLayoutMetrics.minimumWorkspaceWidth,
                    maxWidth: .infinity
                )
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
        List(selection: Binding(
            get: { model.selectedSongIDs },
            set: { model.selectSongs($0) }
        )) {
            SidebarMenuSectionHeader(
                title: "Songs",
                isExpanded: sidebarSectionBinding(.songs),
                headerIdentifier: "songsSectionHeader",
                menuLabel: "Songs Options",
                menuIdentifier: "songsSectionMenuButton"
            ) {
                Menu("Sort Songs By") {
                    songSortCommands
                }
            }
            .sidebarSectionHeaderRow()

            if expandedSidebarSections.contains(.songs) {
                if songsSectionSongs.isEmpty {
                    sidebarEmptyRow("No Songs", identifier: "emptySongsItem")
                } else {
                    ForEach(sidebarSongItems(songsSectionSongs, section: .songs)) { item in
                        sidebarSongRow(item.song, index: item.index, section: item.section)
                    }
                }
            }

            SidebarMenuSectionHeader(
                title: "Recent",
                isExpanded: sidebarSectionBinding(.recent),
                headerIdentifier: "recentSectionHeader",
                menuLabel: "Recent Options",
                menuIdentifier: "recentSectionMenuButton"
            ) {
                recentScopeCommands
            }
            .sidebarSectionHeaderRow()

            if expandedSidebarSections.contains(.recent) {
                if recentSongs.isEmpty {
                    sidebarEmptyRow("No Recent Songs", identifier: "emptyRecentSongsItem")
                } else {
                    ForEach(sidebarSongItems(recentSongs, section: .recent)) { item in
                        sidebarSongRow(item.song, index: item.index, section: item.section)
                    }
                }
            }

            SidebarSectionHeader(
                title: "Favorite",
                isExpanded: sidebarSectionBinding(.favorite),
                accessibilityIdentifier: "favoriteSectionHeader"
            )
            .sidebarSectionHeaderRow()

            if expandedSidebarSections.contains(.favorite) {
                if favoriteSongs.isEmpty {
                    sidebarEmptyRow("No Favorite Songs", identifier: "emptyFavoriteSongsItem")
                } else {
                    ForEach(sidebarSongItems(favoriteSongs, section: .favorite)) { item in
                        sidebarSongRow(item.song, index: item.index, section: item.section)
                    }
                }
            }

            SidebarSectionHeader(
                title: "Tags",
                isExpanded: sidebarSectionBinding(.tags),
                accessibilityIdentifier: "tagsSectionHeader"
            )
            .sidebarSectionHeaderRow()

            if expandedSidebarSections.contains(.tags) {
                if tagSummaries.isEmpty {
                    sidebarEmptyRow("No Tags", identifier: "emptyTagsItem")
                } else {
                    ForEach(Array(tagSummaries.enumerated()), id: \.element.id) { index, summary in
                        tagCategoryRow(summary, index: index)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: UUID.self) { songIDs in
            songContextMenu(for: songIDs)
        }
        .listStyle(.sidebar)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .scrollIndicators(.visible, axes: .vertical)
        .accessibilityIdentifier("songList")
    }

    @ViewBuilder
    private var songSortCommands: some View {
        ForEach(SongSortMode.allCases, id: \.rawValue) { mode in
            Button {
                sortMode = mode
            } label: {
                if sortMode == mode {
                    Label(mode.title, systemImage: "checkmark")
                } else {
                    Text(mode.title)
                }
            }
        }
    }

    @ViewBuilder
    private var recentScopeCommands: some View {
        ForEach(RecentScope.allCases) { scope in
            Button {
                recentScope = scope
            } label: {
                if recentScope == scope {
                    Label(scope.title, systemImage: "checkmark")
                } else {
                    Text(scope.title)
                }
            }
        }
    }

    private func sidebarSongRow(
        _ song: Song,
        index: Int,
        section: SidebarSectionID
    ) -> some View {
        let accessibilityComponents = [
            song.title.isEmpty ? "Untitled" : song.title,
            songArtistAndAlbum(song),
        ]

        return VStack(alignment: .leading, spacing: 3) {
            Text(song.title.isEmpty ? "Untitled" : song.title)
                .fontWeight(.medium)
                .lineLimit(1)
            Text(songArtistAndAlbum(song))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sidebarSectionItemRow()
        .tag(song.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            accessibilityComponents
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        )
        .accessibilityIdentifier(songRowIdentifier(section: section, index: index))
    }

    private func sidebarSongItems(
        _ songs: [Song],
        section: SidebarSectionID
    ) -> [SidebarSongItem] {
        songs.enumerated().map { index, song in
            SidebarSongItem(section: section, index: index, song: song)
        }
    }

    private func sidebarEmptyRow(_ title: String, identifier: String) -> some View {
        Text(title)
            .foregroundStyle(.tertiary)
            .sidebarSectionItemRow()
            .accessibilityIdentifier(identifier)
    }

    private func tagCategoryRow(_ summary: TagSummary, index: Int) -> some View {
        let isSelected = selectedTagKeys.contains(summary.key)
        return Button {
            toggleTagSelection(summary.key)
        } label: {
            HStack(spacing: 8) {
                TagChip(name: summary.name, size: .regular)
                Spacer(minLength: 4)
                Text(summary.songCount, format: .number)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .padding(.trailing, 5)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : .clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sidebarSectionItemRow()
        .accessibilityLabel("\(summary.name), \(summary.songCount) songs")
        .accessibilityValue(isSelected ? "Selected" : "Not Selected")
        .accessibilityIdentifier("tagItem-\(index)")
    }

    private func sidebarSectionBinding(_ section: SidebarSectionID) -> Binding<Bool> {
        Binding(
            get: { expandedSidebarSections.contains(section) },
            set: { isExpanded in
                if isExpanded {
                    expandedSidebarSections.insert(section)
                } else {
                    expandedSidebarSections.remove(section)
                }
            }
        )
    }

    private func toggleTagSelection(_ key: String) {
        if selectedTagKeys.contains(key) {
            selectedTagKeys.remove(key)
        } else {
            let selectsFirstTag = selectedTagKeys.isEmpty
            selectedTagKeys.insert(key)
            if selectsFirstTag {
                expandedSidebarSections.insert(.songs)
            }
        }
    }

    private func matchesSearch(_ song: Song) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return "\(song.title) \(song.artist) \(song.album) \(song.tags.joined(separator: " "))"
            .localizedCaseInsensitiveContains(query)
    }

    private func songRowIdentifier(section: SidebarSectionID, index: Int) -> String {
        switch section {
        case .songs: "songRow-\(index)"
        case .recent: "recentSongRow-\(index)"
        case .favorite: "favoriteSongRow-\(index)"
        case .tags: "tagSongRow-\(index)"
        }
    }

    private func songArtistAndAlbum(_ song: Song) -> String {
        let artist = song.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Unknown Singer"
            : song.artist
        let album = song.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Unknown Album"
            : song.album
        return "\(artist) | \(album)"
    }

    private func editorColumn(song: Binding<Song>) -> some View {
        LyricsEditorView(song: song)
            .id(song.wrappedValue.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
            .background(ColumnToolbarAnchor(layout: toolbarLayout, column: .editor))
    }

    private func playerColumn(song: Song) -> some View {
        PlayerView(song: song)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .backgroundExtensionEffect()
            .background(ColumnToolbarAnchor(layout: toolbarLayout, column: .player))
    }

    private var toolbarActions: some View {
        GeometryReader { geometry in
            let searchWidth = min(
                AppLayoutMetrics.toolbarSearchWidth,
                geometry.size.width - AppLayoutMetrics.toolbarActionsWithoutSearchWidth
            )
            let usesCompactSearch = searchWidth < AppLayoutMetrics.minimumToolbarSearchWidth

            HStack(spacing: AppLayoutMetrics.toolbarGroupSpacing) {
                workspaceToolbarButtons
                lyricsFileToolbarButtons
                songToolbarButtons

                if usesCompactSearch {
                    compactSearchButton
                        .buttonStyle(.borderless)
                        .frame(
                            width: AppLayoutMetrics.toolbarControlHeight,
                            height: AppLayoutMetrics.toolbarControlHeight
                        )
                        .glassEffect(.regular, in: .capsule)
                } else {
                    ToolbarSearchField(text: $searchText)
                        .frame(width: searchWidth, height: 24)
                        .frame(height: AppLayoutMetrics.toolbarControlHeight)
                        .glassEffect(.regular, in: .capsule)
                        .accessibilityIdentifier("songSearchField")
                }
            }
            .fixedSize()
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)
            .onChange(of: usesCompactSearch) { _, compact in
                if !compact { showsCompactSearch = false }
            }
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
        .labelStyle(.iconOnly)
        .frame(
            width: 2 * AppLayoutMetrics.toolbarControlWidth,
            height: AppLayoutMetrics.toolbarControlHeight
        )
        .fixedSize()
        .glassEffect(.regular, in: .capsule)
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
        .labelStyle(.iconOnly)
        .frame(
            width: 2 * AppLayoutMetrics.toolbarControlWidth,
            height: AppLayoutMetrics.toolbarControlHeight
        )
        .fixedSize()
        .glassEffect(.regular, in: .capsule)
    }

    private var songToolbarButtons: some View {
        ControlGroup {
            Button {
                songForDetails = selectedSong
            } label: {
                Label("Details", systemImage: "info.circle")
            }
            .help("Edit Song Details")
            .accessibilityLabel("Edit Song Details")
            .accessibilityIdentifier("editSongDetailsButton")
            .disabled(selectedSong == nil)

            Button {
                guard let songID = selectedSong?.id else { return }
                model.toggleFavorite(songID: songID)
            } label: {
                Label(
                    selectedSong?.isFavorite == true ? "Unfavorite" : "Favorite",
                    systemImage: selectedSong?.isFavorite == true ? "heart.fill" : "heart"
                )
                .foregroundStyle(selectedSong?.isFavorite == true ? .red : .primary)
            }
            .help(selectedSong?.isFavorite == true ? "Unfavorite" : "Favorite")
            .accessibilityLabel(selectedSong?.isFavorite == true ? "Unfavorite" : "Favorite")
            .accessibilityIdentifier("favoriteSongButton")
            .disabled(selectedSong == nil)

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
        .labelStyle(.iconOnly)
        .frame(
            width: 4 * AppLayoutMetrics.toolbarControlWidth,
            height: AppLayoutMetrics.toolbarControlHeight
        )
        .fixedSize()
        .glassEffect(.regular, in: .capsule)
    }

    private var selectedSong: Song? {
        guard let selectedSongID = model.selectedSongID else { return nil }
        return model.song(withID: selectedSongID)
    }

    private var showsSidebarToggle: Bool {
        sidebarIsVisible || (manuallyCollapsedSidebar && windowWidth >= sidebarRestoreWidth)
    }

    private var sidebarCollapseWidth: CGFloat {
        max(sidebarWidth, AppLayoutMetrics.idealSidebarWidth)
            + AppLayoutMetrics.minimumWorkspaceWidth + 1
    }

    private var sidebarRestoreWidth: CGFloat {
        sidebarCollapseWidth + AppLayoutMetrics.sidebarRestorationClearance
    }

    private var compactSearchButton: some View {
        Button {
            showsCompactSearch.toggle()
        } label: {
            Label("Search Songs", systemImage: "magnifyingglass")
        }
        .labelStyle(.iconOnly)
        .help("Search Songs")
        .accessibilityLabel("Search Songs")
        .accessibilityValue(searchText.isEmpty ? "No filter" : searchText)
        .accessibilityIdentifier("compactSongSearchButton")
        .popover(isPresented: $showsCompactSearch, arrowEdge: .bottom) {
            ToolbarSearchField(text: $searchText)
                .frame(width: 220, height: 24)
                .accessibilityIdentifier("songSearchField")
                .padding(12)
        }
    }

    private func updateResponsiveLayout(for width: CGFloat) {
        withTransaction(Transaction(animation: nil)) {
            if width < sidebarCollapseWidth {
                sidebarIsVisible = false
                sidebarDragStartWidth = nil
            } else if !manuallyCollapsedSidebar,
                      width >= sidebarRestoreWidth {
                sidebarIsVisible = true
            }
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
                    model.isImportingSongBundle = true
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

        Button("Edit Song Details…") {
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

        Button("Delete", role: .destructive) {
            prepareSongDeletion(songIDs)
        }
        .disabled(songIDs.isEmpty)
    }

    private func prepareSongDeletion(_ ids: Set<UUID>) {
        songIDsToDelete = ids.intersection(Set(model.library.songs.map(\.id)))
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

private struct WindowWidthReader: NSViewRepresentable {
    @Binding var width: CGFloat

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onWidthChange = { width = $0 }
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onWidthChange = { width = $0 }
        view.reportWidth()
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: Void) {
        view.stopObserving()
    }

    @MainActor
    final class ObserverView: NSView {
        var onWidthChange: ((CGFloat) -> Void)?
        private weak var observedWindow: NSWindow?
        private var lastReportedWidth: CGFloat?
        private var reportIsScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            startObservingCurrentWindow()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        private func startObservingCurrentWindow() {
            stopObserving()
            guard let window else { return }
            observedWindow = window
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResize),
                name: NSWindow.didResizeNotification,
                object: window
            )
            reportWidth()
        }

        func stopObserving() {
            NotificationCenter.default.removeObserver(self)
            observedWindow = nil
            lastReportedWidth = nil
        }

        @objc
        private func windowDidResize(_ notification: Notification) {
            reportWidth()
        }

        func reportWidth() {
            guard let window = observedWindow ?? self.window else { return }
            let minimumSize = NSSize(
                width: AppLayoutMetrics.minimumWindowWidth,
                height: AppLayoutMetrics.minimumWindowHeight
            )
            if window.contentMinSize != minimumSize {
                window.contentMinSize = minimumSize
            }
            if window.minSize != minimumSize {
                window.minSize = minimumSize
            }
            guard !reportIsScheduled else { return }
            reportIsScheduled = true
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self else { return }
                self.reportIsScheduled = false
                guard let window, self.window === window else { return }
                let nextWidth = window.frame.width
                guard nextWidth > 0, nextWidth != self.lastReportedWidth else { return }
                self.lastReportedWidth = nextWidth
                self.onWidthChange?(nextWidth)
            }
        }
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

private enum SidebarSectionID: String, Hashable {
    case songs
    case recent
    case favorite
    case tags
}

private struct SidebarSongItem: Identifiable {
    struct ID: Hashable {
        let section: SidebarSectionID
        let songID: UUID
    }

    let section: SidebarSectionID
    let index: Int
    let song: Song

    var id: ID {
        ID(section: section, songID: song.id)
    }
}

private enum RecentScope: String, CaseIterable, Identifiable {
    case today
    case yesterday
    case inLastWeek

    var id: Self { self }

    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .inLastWeek: "In Last Week"
        }
    }

    func contains(
        _ date: Date,
        relativeTo now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)
        else { return false }

        switch self {
        case .today:
            return date >= startOfToday && date < startOfTomorrow
        case .yesterday:
            guard let startOfYesterday = calendar.date(
                byAdding: .day,
                value: -1,
                to: startOfToday
            ) else { return false }
            return date >= startOfYesterday && date < startOfToday
        case .inLastWeek:
            guard let startOfWindow = calendar.date(
                byAdding: .day,
                value: -6,
                to: startOfToday
            ) else { return false }
            return date >= startOfWindow && date < startOfTomorrow
        }
    }
}

private struct TagSummary: Identifiable, Equatable {
    var key: String
    var name: String
    var songCount: Int

    var id: String { key }
}

private enum TagAppearance {
    private static let locale = Locale(identifier: "en_US_POSIX")
    private static let palette: [Color] = [
        .blue,
        .purple,
        .pink,
        .orange,
        .green,
        .teal,
        .indigo,
        .mint,
        .cyan,
        .red,
    ]

    static func normalizedKey(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCompatibilityMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: locale
            )
            .lowercased(with: locale)
    }

    static func color(for name: String) -> Color {
        let bytes = normalizedKey(name).utf8
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

private enum TagChipSize {
    case compact
    case regular

    var font: Font {
        switch self {
        case .compact: .caption2
        case .regular: .caption
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .compact: 5
        case .regular: 7
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .compact: 1
        case .regular: 3
        }
    }
}

private struct TagChip: View {
    let name: String
    var size = TagChipSize.compact

    var body: some View {
        let color = TagAppearance.color(for: name)
        Text(name)
            .font(size.font.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .overlay {
                Capsule()
                    .stroke(color.opacity(0.65), lineWidth: 0.75)
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
    }
}

private struct RemovableTagChip: View {
    let name: String
    let accessibilityIdentifier: String
    let onRemove: () -> Void

    var body: some View {
        let color = TagAppearance.color(for: name)
        HStack(spacing: 4) {
            Text(name)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(name)")
            .accessibilityIdentifier("\(accessibilityIdentifier)-remove")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.leading, 7)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .overlay {
            Capsule()
                .stroke(color.opacity(0.65), lineWidth: 0.75)
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct SidebarSectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool
    let accessibilityIdentifier: String

    var body: some View {
        HStack(spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                SidebarSectionToggleLabel(
                    title: title,
                    isExpanded: isExpanded
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(accessibilityIdentifier)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .textCase(nil)
    }
}

private struct SidebarMenuSectionHeader<MenuContent: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    let headerIdentifier: String
    let menuLabel: String
    let menuIdentifier: String
    @ViewBuilder let menuContent: () -> MenuContent

    @State private var isHovering = false
    @FocusState private var menuIsFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Button {
                isExpanded.toggle()
            } label: {
                SidebarSectionToggleLabel(
                    title: title,
                    isExpanded: isExpanded
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(headerIdentifier)

            Spacer(minLength: 0)

            Menu {
                menuContent()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .focused($menuIsFocused)
            .opacity(isHovering || menuIsFocused ? 1 : 0.001)
            .accessibilityLabel(menuLabel)
            .accessibilityIdentifier(menuIdentifier)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .textCase(nil)
    }
}

private enum SidebarLayoutMetrics {
    static let labelSpacing: CGFloat = 6
    static let itemIndent: CGFloat = 8
}

private extension View {
    func sidebarSectionHeaderRow() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 5, trailing: 8))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    func sidebarSectionItemRow() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(
                top: 0,
                leading: SidebarLayoutMetrics.itemIndent,
                bottom: 0,
                trailing: 8
            ))
    }
}

private struct SidebarSectionToggleLabel: View {
    let title: String
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: SidebarLayoutMetrics.labelSpacing) {
            Text(title)
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.regular))
        }
        .font(.body.weight(.regular))
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
    }
}

private struct TagFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let maximumWidth = proposedWidth ?? .greatestFiniteMagnitude
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maximumWidth {
                widestRow = max(widestRow, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }

        widestRow = max(widestRow, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: proposedWidth ?? widestRow, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct TagTokenEditor: View {
    @Binding var tags: [String]
    let availableTags: [String]

    @State private var input = ""
    @State private var selectedSuggestionIndex: Int?
    @FocusState private var inputIsFocused: Bool

    private var canonicalTags: [String] {
        Song.normalizedTags(availableTags)
    }

    private var suggestions: [String] {
        let prefix = TagAppearance.normalizedKey(input)
        guard !prefix.isEmpty else { return [] }
        let attachedKeys = Set(tags.map(TagAppearance.normalizedKey))
        return canonicalTags.filter { tag in
            let key = TagAppearance.normalizedKey(tag)
            return !attachedKeys.contains(key) && key.hasPrefix(prefix)
        }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.vertical) {
                TagFlowLayout(spacing: 6) {
                    ForEach(Array(tags.enumerated()), id: \.element) { index, tag in
                        RemovableTagChip(
                            name: tag,
                            accessibilityIdentifier: "songDetailsTag-\(index)"
                        ) {
                            removeTag(tag)
                        }
                    }

                    TextField("Add tag", text: $input)
                        .textFieldStyle(.plain)
                        .frame(minWidth: 120, idealWidth: 160, maxWidth: 200)
                        .focused($inputIsFocused)
                        .onSubmit(commitFromReturn)
                        .onChange(of: input) { _, newValue in
                            inputChanged(newValue)
                        }
                        .onKeyPress(.downArrow) {
                            moveSuggestionSelection(by: 1)
                        }
                        .onKeyPress(.upArrow) {
                            moveSuggestionSelection(by: -1)
                        }
                        .onKeyPress(.tab) {
                            acceptSuggestionFromTab()
                        }
                        .accessibilityLabel("Add Tag")
                        .accessibilityIdentifier("songDetailsTagsField")
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 48, maxHeight: 142)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.quaternary, lineWidth: 1)
            }

            if !suggestions.isEmpty {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(suggestions.enumerated()), id: \.element) { index, suggestion in
                            Button {
                                acceptSuggestion(suggestion)
                            } label: {
                                HStack {
                                    TagChip(name: suggestion, size: .regular)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .background(
                                    selectedSuggestionIndex == index
                                        ? Color.accentColor.opacity(0.16)
                                        : .clear,
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Use tag \(suggestion)")
                            .accessibilityIdentifier("tagSuggestion-\(index)")
                        }
                    }
                }
                .frame(maxHeight: 126)
                .padding(4)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary, lineWidth: 1)
                }
                .accessibilityIdentifier("tagSuggestions")
            }
        }
    }

    private func inputChanged(_ newValue: String) {
        selectedSuggestionIndex = nil
        guard newValue.contains(",") || newValue.contains("\n") else { return }

        let endsInSeparator = newValue.last == "," || newValue.last == "\n"
        let components = newValue.components(
            separatedBy: CharacterSet(charactersIn: ",\n")
        )
        let completed = endsInSeparator ? components.dropLast() : components.dropLast()
        let remainder = endsInSeparator ? "" : (components.last ?? "")
        input = remainder
        for component in completed {
            commitTag(component)
        }
    }

    private func commitFromReturn() {
        if let selectedSuggestionIndex,
           suggestions.indices.contains(selectedSuggestionIndex) {
            acceptSuggestion(suggestions[selectedSuggestionIndex])
        } else {
            commitTag(input)
            input = ""
        }
    }

    private func acceptSuggestionFromTab() -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        let index = selectedSuggestionIndex ?? 0
        acceptSuggestion(suggestions[index])
        return .handled
    }

    private func moveSuggestionSelection(by offset: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        if let selectedSuggestionIndex {
            self.selectedSuggestionIndex = min(
                max(0, selectedSuggestionIndex + offset),
                suggestions.count - 1
            )
        } else {
            selectedSuggestionIndex = offset > 0 ? 0 : suggestions.count - 1
        }
        return .handled
    }

    private func acceptSuggestion(_ suggestion: String) {
        commitTag(suggestion)
        input = ""
        selectedSuggestionIndex = nil
        inputIsFocused = true
    }

    private func commitTag(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = TagAppearance.normalizedKey(trimmed)
        let canonical = canonicalTags.first {
            TagAppearance.normalizedKey($0) == key
        } ?? trimmed
        tags = Song.normalizedTags(tags + [canonical])
    }

    private func removeTag(_ tag: String) {
        let key = TagAppearance.normalizedKey(tag)
        tags.removeAll { TagAppearance.normalizedKey($0) == key }
        inputIsFocused = true
    }
}

private struct SongDetailsSheet: View {
    let song: Song
    let availableTags: [String]
    let onSave: (String, String, String, [String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var tags: [String]
    @FocusState private var titleFocused: Bool

    init(
        song: Song,
        availableTags: [String],
        onSave: @escaping (String, String, String, [String]) -> Void
    ) {
        self.song = song
        self.availableTags = availableTags
        self.onSave = onSave
        _title = State(initialValue: song.title)
        _artist = State(initialValue: song.artist)
        _album = State(initialValue: song.album)
        _tags = State(initialValue: song.tags)
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
            TextField("Album", text: $album)
                .accessibilityIdentifier("songDetailsAlbumField")

            VStack(alignment: .leading, spacing: 5) {
                Text("Tags")
                    .font(.headline)
                TagTokenEditor(tags: $tags, availableTags: availableTags)
                Text("Type to find existing tags. Use comma or Return to add another tag.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    onSave(
                        title.trimmingCharacters(in: .whitespacesAndNewlines),
                        artist.trimmingCharacters(in: .whitespacesAndNewlines),
                        album.trimmingCharacters(in: .whitespacesAndNewlines),
                        Song.normalizedTags(tags)
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("saveSongDetailsButton")
            }
        }
        .padding(20)
        .frame(width: 500)
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
            TextField(
                "https://music.apple.com/us/song/you-complete-me-theme-song-from-back-to-the-good-times/1342141668",
                text: $linkText
            )
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
            return "Paste the song’s Apple Music link. The title, singer, and album will come from Apple Music metadata."
        }
        return "Paste the song’s Apple Music link. Its Music metadata will be refreshed without changing the title, singer, or album already shown in this app."
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
