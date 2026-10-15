import SwiftUI

/// Both library layouts use the same scopes, tag matching and sorting controls.
struct LibraryFilterMenu: View {
    @Environment(AppModel.self) private var model
    @Binding var browser: LibraryBrowserState
    var onFilterChange: () -> Void = {}
    let onOpenTrash: () -> Void
    @AppStorage(PreferenceKey.sortMode) private var sortModeRaw = SongSortMode.title.rawValue

    private var tags: [TagSummary] { TagSummary.summaries(for: model.library.songs) }

    private var summary: String {
        let songs = browser.filteredSongs(
            in: model.library.songs, sortedBy: SongSortMode(rawValue: sortModeRaw) ?? .title
        )
        return browser.summary(songCount: songs.count, tags: tags)
    }

    var body: some View {
        Menu {
            Section("Show") {
                ForEach(LibraryScope.allCases) { option in
                    Button {
                        browser.scope = option
                        if option == .all { browser.selectedTagKeys = [] }
                        onFilterChange()
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
                        onFilterChange()
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
                if tags.isEmpty {
                    Text("No Tags")
                } else {
                    ForEach(tags) { tag in
                        Toggle("\(tag.name) (\(tag.songCount))", isOn: Binding(
                            get: { browser.selectedTagKeys.contains(tag.key) },
                            set: { selected in
                                if selected { browser.selectedTagKeys.insert(tag.key) }
                                else { browser.selectedTagKeys.remove(tag.key) }
                                onFilterChange()
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

            if browser.hasFilters {
                Button("Clear Filters", systemImage: "line.3.horizontal.decrease.circle") {
                    browser.clearFilters()
                    onFilterChange()
                }
            }

            Divider()

            Button("Trash (\(model.trashedItemCount))", systemImage: "trash", action: onOpenTrash)
                .accessibilityIdentifier("libraryTrashMenuItem")
        } label: {
            Image(systemName: browser.hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                .foregroundStyle(browser.hasFilters ? Color.accentColor : Color.secondary)
                #if os(macOS)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 30)
                #endif
                .contentShape(Rectangle())
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter and Sort Songs")
        #endif
        .accessibilityLabel("Filter and Sort Songs")
        .accessibilityValue(browser.hasFilters ? summary : "All Songs")
        .accessibilityIdentifier("libraryFilterButton")
    }
}
