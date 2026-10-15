#if os(macOS)
import AppKit
import SwiftUI

/// The library is one browsable list. Its search and filters belong to this
/// column, while selecting a song opens the existing editor/player workspace.
struct SongLibrarySidebar<SongMenu: View>: View {
    @Environment(AppModel.self) private var model
    let onDeleteSongs: (Set<UUID>) -> Void
    @ViewBuilder let songContextMenu: (Set<UUID>) -> SongMenu

    @Binding var browser: LibraryBrowserState
    @AppStorage(PreferenceKey.sortMode) private var sortModeRaw = SongSortMode.title.rawValue
    @AppStorage(PreferenceKey.showsLibraryArtwork) private var showsArtwork = true
    @AppStorage(PreferenceKey.libraryArtworkSize) private var artworkSizeRaw = LibraryArtworkSize.medium.rawValue
    @FocusState private var listHasFocus: Bool
    @State private var keyboardSelectionID: UUID?
    @State private var selectionAnchorID: UUID?

    private var artworkSize: LibraryArtworkSize {
        LibraryArtworkSize(rawValue: artworkSizeRaw) ?? .medium
    }

    private let searchHeaderHeight: CGFloat = 58

    private var sortMode: SongSortMode {
        SongSortMode(rawValue: sortModeRaw) ?? .title
    }

    private var tagSummaries: [TagSummary] {
        TagSummary.summaries(for: model.library.songs)
    }

    private var availableTagKeys: Set<String> { Set(tagSummaries.map(\.key)) }

    private var songs: [Song] {
        browser.filteredSongs(in: model.library.songs, sortedBy: sortMode)
    }

    private var visibleSongIDs: Set<UUID> { Set(songs.map(\.id)) }
    private var hasFilters: Bool { browser.hasFilters }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                // The viewport continues beneath the opaque header. Reserve
                // the titlebar and search area only at the start of the list.
                songList(topInset: geometry.safeAreaInsets.top + searchHeaderHeight + 4)
                    .ignoresSafeArea(.container, edges: .top)

                LibrarySearchField(text: $browser.searchText)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .contentShape(Rectangle())
                    .background {
                        // Match the native sidebar titlebar background so the
                        // title and search read as one continuous header.
                        Color(nsColor: .windowBackgroundColor)
                            .contentShape(Rectangle())
                            .onTapGesture { }
                            .accessibilityHidden(true)
                    }
                    .overlay(alignment: .bottom) {
                        Divider()
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: availableTagKeys, initial: true) { _, keys in
            browser.selectedTagKeys.formIntersection(keys)
        }
    }

    private var selection: Binding<Set<UUID>> {
        Binding(
            get: { model.selectedSongIDs.intersection(visibleSongIDs) },
            set: {
                model.selectSongs($0.intersection(visibleSongIDs))
                keyboardSelectionID = model.selectedSongID
                selectionAnchorID = model.selectedSongID
                listHasFocus = true
            }
        )
    }

    private func songList(topInset: CGFloat) -> some View {
        ScrollViewReader { proxy in
            List(selection: selection) {
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    LibrarySongRow(song: song, showsArtwork: showsArtwork, artworkSize: artworkSize)
                        .tag(song.id)
                        .listRowInsets(EdgeInsets(top: artworkSize.rowVerticalPadding, leading: 10,
                                                 bottom: artworkSize.rowVerticalPadding, trailing: 10))
                        .alignmentGuide(.listRowSeparatorLeading) { [inset = showsArtwork ? artworkSize.dimension + 12 : 0] _ in inset }
                        .listRowSeparator(.visible)
                        .accessibilityIdentifier("songRow-\(index)")
                }
            }
            .listStyle(.sidebar)
            .focusable()
            .focused($listHasFocus)
            .focusEffectDisabled()
            .simultaneousGesture(TapGesture().onEnded { listHasFocus = true })
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                guard listHasFocus else { return .ignored }
                moveSelection(by: press.key == .downArrow ? 1 : -1,
                              extending: press.modifiers.contains(.shift))
                return .handled
            }
            .onChange(of: keyboardSelectionID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .scrollContentBackground(.hidden)
            .safeAreaPadding(.top, topInset)
            .scrollEdgeEffectHidden(true, for: .top)
            .contextMenu(forSelectionType: UUID.self) { ids in
                songContextMenu(ids.intersection(visibleSongIDs))
            }
            .onDeleteCommand {
                let ids = model.selectedSongIDs.intersection(visibleSongIDs)
                if !ids.isEmpty { onDeleteSongs(ids) }
            }
            .overlay {
                if !model.isLoaded {
                    ProgressView("Opening Library…")
                } else if songs.isEmpty {
                    emptyState
                }
            }
            .accessibilityIdentifier("songList")
        }
    }

    private func moveSelection(by delta: Int, extending: Bool) {
        let visibleSongs = songs
        guard !visibleSongs.isEmpty else { return }
        let cursorID = keyboardSelectionID ?? model.selectedSongID
        let currentIndex = visibleSongs.firstIndex { $0.id == cursorID }
        let nextIndex = min(max((currentIndex ?? (delta > 0 ? -1 : visibleSongs.count)) + delta, 0),
                            visibleSongs.count - 1)
        let nextID = visibleSongs[nextIndex].id
        if extending {
            let anchorID = selectionAnchorID ?? cursorID ?? nextID
            let anchorIndex = visibleSongs.firstIndex { $0.id == anchorID } ?? nextIndex
            selectionAnchorID = visibleSongs[anchorIndex].id
            let range = min(anchorIndex, nextIndex)...max(anchorIndex, nextIndex)
            model.selectSongs(Set(visibleSongs[range].map(\.id)))
        } else {
            selectionAnchorID = nextID
            model.selectSongs([nextID])
        }
        keyboardSelectionID = nextID
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: model.library.songs.isEmpty ? "music.note.list" : "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(model.library.songs.isEmpty ? "No Songs Yet" : "No Matching Songs")
                .font(.headline)
            Text(model.library.songs.isEmpty
                 ? "Add an Apple Music song to start your library."
                 : "Try another search or change your filters.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if model.library.songs.isEmpty {
                Button("Add Song") { model.isCreatingSong = true }
            } else if hasFilters || !browser.searchText.isEmpty {
                Button("Show All Songs") {
                    browser.searchText = ""
                    clearFilters()
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func clearFilters() {
        browser.scope = .all
        browser.selectedTagKeys = []
        leaveTrash()
    }

    private func leaveTrash() {
        if model.isShowingRecordingTrash { model.selectSong(nil) }
    }
}

/// Compact list controls share the native titlebar with the sidebar toggle.
struct SongLibraryHeader: View {
    @Environment(AppModel.self) private var model
    @Binding var browser: LibraryBrowserState
    @AppStorage(PreferenceKey.sortMode) private var sortModeRaw = SongSortMode.title.rawValue

    private var tagSummaries: [TagSummary] { TagSummary.summaries(for: model.library.songs) }
    private var hasFilters: Bool { browser.hasFilters }
    private var songs: [Song] {
        browser.filteredSongs(in: model.library.songs, sortedBy: SongSortMode(rawValue: sortModeRaw) ?? .title)
    }

    private var title: String {
        browser.scope == .all && !browser.selectedTagKeys.isEmpty ? "Filtered Songs" : browser.scope.title
    }

    private var subtitle: String {
        let count = songs.count
        var parts = [count == 1 ? "1 song" : "\(count) songs"]
        if browser.scope == .recent { parts.append(browser.recentScope.title) }
        let names = tagSummaries.filter { browser.selectedTagKeys.contains($0.key) }.map(\.name)
        if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(subtitle)
                    .accessibilityIdentifier("songListSummary")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            filterMenu
        }
    }

    private var filterMenu: some View {
        Menu {
            Section("Show") {
                ForEach(LibraryScope.allCases) { option in
                    Button {
                        browser.scope = option
                        if option == .all { browser.selectedTagKeys = [] }
                        leaveTrash()
                    } label: {
                        if browser.scope == option && (option != .all || browser.selectedTagKeys.isEmpty) {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            }

            Menu("Recent Time Range") {
                ForEach(RecentScope.allCases) { option in
                    Button {
                        browser.recentScope = option
                        browser.scope = .recent
                        leaveTrash()
                    } label: {
                        if browser.scope == .recent && browser.recentScope == option {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            }

            Menu("Tags") {
                if tagSummaries.isEmpty {
                    Text("No Tags")
                } else {
                    ForEach(tagSummaries) { tag in
                        Toggle("\(tag.name) (\(tag.songCount))", isOn: Binding(
                            get: { browser.selectedTagKeys.contains(tag.key) },
                            set: { selected in
                                if selected { browser.selectedTagKeys.insert(tag.key) }
                                else { browser.selectedTagKeys.remove(tag.key) }
                                leaveTrash()
                            }
                        ))
                    }
                }
            }

            Divider()

            Menu("Sort By") {
                Picker("Sort By", selection: $sortModeRaw) {
                    ForEach(SongSortMode.allCases, id: \.rawValue) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.inline)
            }
            .disabled(browser.scope == .recent)

            if hasFilters {
                Button("Clear Filters", systemImage: "line.3.horizontal.decrease.circle") {
                    clearFilters()
                }
            }

            Divider()

            Button("Trash (\(model.trashedItemCount))", systemImage: "trash") {
                model.showRecordingTrash()
            }
            .accessibilityIdentifier("libraryTrashMenuItem")
        } label: {
            Image(systemName: hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(hasFilters ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter and Sort Songs")
        .accessibilityLabel("Filter and Sort Songs")
        .accessibilityValue(hasFilters ? subtitle : "All Songs")
        .accessibilityIdentifier("libraryFilterButton")
    }

    private func clearFilters() {
        browser.scope = .all
        browser.selectedTagKeys = []
        leaveTrash()
    }

    private func leaveTrash() {
        if model.isShowingRecordingTrash { model.selectSong(nil) }
    }
}

private struct LibrarySongRow: View {
    let song: Song
    let showsArtwork: Bool
    let artworkSize: LibraryArtworkSize

    private var album: String { song.album.isEmpty ? "Unknown Album" : song.album }
    private var title: String { song.title.isEmpty ? "Untitled" : song.title }
    private var artist: String { song.artist.isEmpty ? "Unknown Singer" : song.artist }

    var body: some View {
        LibraryRowScrollView {
            HStack(alignment: artworkSize == .medium ? .top : .center, spacing: 12) {
                if showsArtwork {
                    SongArtworkView(appleMusicURL: song.appleMusicURL, size: artworkSize.dimension)
                }

                VStack(alignment: .leading, spacing: artworkSize == .small ? 3 : 5) {
                    HStack(spacing: 5) {
                        Text(album)
                            .font(.system(size: 11, weight: .medium))
                        if song.isFavorite {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 9))
                                .accessibilityLabel("Favorite")
                        }
                    }
                    .foregroundStyle(.secondary)

                    Text(title)
                        .font(.system(size: 17, weight: .semibold))

                    HStack(spacing: 4) {
                        Text(artist)
                        SongReleaseYearView(appleMusicURL: song.appleMusicURL)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                    if artworkSize == .large && !song.tags.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(song.tags, id: \.self) { tag in
                                TagChip(name: tag)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Tags: \(song.tags.joined(separator: ", "))")
                    }
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
            }
            .frame(minHeight: showsArtwork ? artworkSize.dimension : 0, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

private struct LibrarySearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search songs and lyrics", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .accessibilityLabel("Search Songs")
                .accessibilityHint("Search titles, singers, albums, lyrics, annotations, and tags")
                .accessibilityIdentifier("songSearchField")
                .help("Search titles, singers, albums, lyrics, annotations, and tags")
                .onExitCommand { text = "" }

            if !text.isEmpty {
                Button {
                    text = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear Search")
                .accessibilityLabel("Clear Search")
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 14)
        .frame(height: 38)
        .glassEffect(.regular, in: .rect(cornerRadius: 19))
        .overlay {
            RoundedRectangle(cornerRadius: 19)
                .strokeBorder(isFocused ? Color.accentColor.opacity(0.8) : .clear, lineWidth: 1.5)
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
    }
}

/// Owned by ContentView so hiding the sidebar preserves the current search and filters.
struct LibraryBrowserState {
    var searchText = ""
    var scope = LibraryScope.all
    var recentScope = RecentScope.today
    var selectedTagKeys: Set<String> = []

    var hasFilters: Bool { scope != .all || !selectedTagKeys.isEmpty }

    func filteredSongs(in librarySongs: [Song], sortedBy sortMode: SongSortMode) -> [Song] {
        let filtered = librarySongs.filter { song in
            switch scope {
            case .all: break
            case .favorites:
                guard song.isFavorite else { return false }
            case .recent:
                guard let date = song.lastPlayedAt, recentScope.contains(date) else { return false }
            }
            guard selectedTagKeys.isEmpty || song.tags.contains(where: {
                selectedTagKeys.contains(TagAppearance.normalizedKey($0))
            }) else { return false }
            return song.matchesSearch(searchText)
        }
        if scope == .recent {
            return filtered.sorted {
                if $0.lastPlayedAt != $1.lastPlayedAt {
                    return ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast)
                }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
        return sortMode.sorted(filtered)
    }
}

enum LibraryScope: String, CaseIterable, Identifiable {
    case all, recent, favorites
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "All Songs"
        case .recent: "Recent"
        case .favorites: "Favorites"
        }
    }
}

enum RecentScope: String, CaseIterable, Identifiable {
    case today, yesterday, inLastWeek
    var id: Self { self }
    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .inLastWeek: "In Last Week"
        }
    }

    func contains(_ date: Date, relativeTo now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> Bool {
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return false }
        switch self {
        case .today:
            return date >= today && date < tomorrow
        case .yesterday:
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return false }
            return date >= yesterday && date < today
        case .inLastWeek:
            guard let start = calendar.date(byAdding: .day, value: -6, to: today) else { return false }
            return date >= start && date < tomorrow
        }
    }
}
#endif
