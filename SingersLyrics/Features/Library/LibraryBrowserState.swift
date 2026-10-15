import Foundation

/// Shared library browsing behavior; each platform keeps its own navigation and selection.
struct LibraryBrowserState {
    var searchText = ""
    var scope = LibraryScope.all
    var recentScope = RecentScope.today
    var selectedTagKeys: Set<String> = []

    var hasFilters: Bool { scope != .all || !selectedTagKeys.isEmpty }

    var title: String {
        scope == .all && !selectedTagKeys.isEmpty ? "Filtered Songs" : scope.title
    }

    func summary(songCount: Int, tags: [TagSummary]) -> String {
        var parts = [songCount == 1 ? "1 song" : "\(songCount) songs"]
        if scope == .recent { parts.append(recentScope.title) }
        let names = tags.filter { selectedTagKeys.contains($0.key) }.map(\.name)
        if !names.isEmpty { parts.append(names.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    mutating func clearFilters() {
        scope = .all
        selectedTagKeys = []
    }

    mutating func showAllSongs() {
        searchText = ""
        clearFilters()
    }

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
