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
    private var songs: [Song] {
        browser.filteredSongs(in: model.library.songs, sortedBy: SongSortMode(rawValue: sortModeRaw) ?? .title)
    }

    private var subtitle: String {
        browser.summary(songCount: songs.count, tags: tagSummaries)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(browser.title)
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
        LibraryFilterMenu(browser: $browser, onFilterChange: leaveTrash) {
            model.showRecordingTrash()
        }
    }

    private func leaveTrash() {
        if model.isShowingRecordingTrash { model.selectSong(nil) }
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


#endif
