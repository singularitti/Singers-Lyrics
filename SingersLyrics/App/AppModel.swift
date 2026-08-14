import AppKit
import Foundation
import Observation
import SwiftUI

struct StorageIssue: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

@MainActor
@Observable
final class AppModel {
    private let store: any LibraryStoring
    private var saveTask: Task<Void, Never>?
    private var isDirty = false

    var library = LibraryDocument()
    var selectedSongID: UUID?
    var selectedSongIDs: Set<UUID> = []
    var isCreatingSong = false
    private(set) var isLoaded = false
    private(set) var autosaveDisabled = false
    var storageIssue: StorageIssue?

    init(store: any LibraryStoring) {
        self.store = store
    }

    func load() async {
        guard !isLoaded else { return }
        do {
            library = try await store.load()
            if let saved = UserDefaults.standard.string(forKey: PreferenceKey.selectedSong),
               let id = UUID(uuidString: saved),
               library.songs.contains(where: { $0.id == id }) {
                selectedSongID = id
                selectedSongIDs = [id]
            }
        } catch {
            autosaveDisabled = true
            storageIssue = StorageIssue(
                title: "Library Could Not Be Opened",
                message: [error.localizedDescription, (error as? LocalizedError)?.recoverySuggestion]
                    .compactMap { $0 }
                    .joined(separator: "\n\n")
            )
        }
        isLoaded = true
    }

    func selectSong(_ id: UUID?) {
        selectedSongID = id
        selectedSongIDs = id.map { Set([$0]) } ?? []
        persistSelectedSong(id)
    }

    func selectSongs(_ ids: Set<UUID>) {
        let validIDs = ids.intersection(Set(library.songs.map(\.id)))
        let newlySelectedIDs = validIDs.subtracting(selectedSongIDs)
        selectedSongIDs = validIDs

        if validIDs.count == 1, let onlyID = validIDs.first {
            selectedSongID = onlyID
            persistSelectedSong(onlyID)
        } else if newlySelectedIDs.count == 1, let newID = newlySelectedIDs.first {
            selectedSongID = newID
            persistSelectedSong(newID)
        } else if let selectedSongID, validIDs.contains(selectedSongID) {
            persistSelectedSong(selectedSongID)
        } else if let firstVisibleID = library.songs.first(where: { validIDs.contains($0.id) })?.id {
            selectedSongID = firstVisibleID
            persistSelectedSong(firstVisibleID)
        } else {
            selectedSongID = nil
            persistSelectedSong(nil)
        }
    }

    func song(withID id: UUID) -> Song? {
        library.songs.first { $0.id == id }
    }

    func bindingForSelectedSong() -> Binding<Song>? {
        guard let id = selectedSongID, song(withID: id) != nil else { return nil }
        return Binding(
            get: { [weak self] in self?.song(withID: id) ?? .blank() },
            set: { [weak self] in self?.replaceSong($0) }
        )
    }

    @discardableResult
    func createSong(appleMusicURL: URL, metadata: TrackMetadata) -> Song {
        var song = Song.blank()
        song.title = metadata.title
        song.artist = metadata.artist
        song.appleMusicURL = appleMusicURL
        library.songs.insert(song, at: 0)
        selectSong(song.id)
        markChanged()
        return song
    }

    func replaceSong(_ song: Song) {
        guard let index = library.songs.firstIndex(where: { $0.id == song.id }) else { return }
        var updated = song
        updated.updatedAt = Date()
        library.songs[index] = updated
        markChanged()
    }

    @discardableResult
    func duplicateSongs(_ ids: Set<UUID>, now: Date = Date()) -> Set<UUID> {
        let validIDs = ids.intersection(Set(library.songs.map(\.id)))
        guard !validIDs.isEmpty else { return [] }

        var duplicateIDs: Set<UUID> = []
        library.songs = library.songs.flatMap { song -> [Song] in
            guard validIDs.contains(song.id) else { return [song] }

            var duplicate = song
            duplicate.id = UUID()
            duplicate.lines = song.lines.map { line in
                var duplicateLine = line
                duplicateLine.id = UUID()
                return duplicateLine
            }
            duplicate.createdAt = now
            duplicate.updatedAt = now
            duplicateIDs.insert(duplicate.id)
            return [song, duplicate]
        }

        selectSongs(duplicateIDs)
        markChanged()
        return duplicateIDs
    }

    func deleteSongs(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        library.songs.removeAll { ids.contains($0.id) }
        selectedSongIDs.subtract(ids)
        if let selectedSongID, ids.contains(selectedSongID) {
            self.selectedSongID = selectedSongIDs.first ?? library.songs.first?.id
        }
        if let selectedSongID {
            selectedSongIDs.insert(selectedSongID)
        }
        persistSelectedSong(selectedSongID)
        markChanged()
    }

    func deleteSong(_ id: UUID) {
        deleteSongs([id])
    }

    func moveSong(_ id: UUID, offset: Int) {
        guard let source = library.songs.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard library.songs.indices.contains(destination) else { return }
        let song = library.songs.remove(at: source)
        library.songs.insert(song, at: destination)
        markChanged()
    }

    func flush() async {
        saveTask?.cancel()
        saveTask = nil
        guard isDirty, !autosaveDisabled else { return }
        await persistCurrentDocument()
    }

    func revealLibrary() {
        NSWorkspace.shared.activateFileViewerSelecting([JSONLibraryStore.defaultLibraryURL()])
    }

    private func markChanged() {
        guard !autosaveDisabled else { return }
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await self?.persistCurrentDocument()
        }
    }

    private func persistSelectedSong(_ id: UUID?) {
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: PreferenceKey.selectedSong)
        } else {
            UserDefaults.standard.removeObject(forKey: PreferenceKey.selectedSong)
        }
    }

    private func persistCurrentDocument() async {
        let snapshot = library
        do {
            try await store.save(snapshot)
            isDirty = false
        } catch {
            autosaveDisabled = true
            storageIssue = StorageIssue(
                title: "Library Could Not Be Saved",
                message: "Your in-memory edits have not been discarded. Autosave is paused.\n\n\(error.localizedDescription)"
            )
        }
    }
}

enum PreferenceKey {
    static let selectedSong = "selectedSongID"
    static let sortMode = "sortMode"
    static let appearance = "appearance"
    static let lyricSize = "lyricSize"
    static let defaultLyricsFontFamily = "defaultLyricsFontFamily"
    static let editorPanelVisible = "editorPanelVisible"
    static let previewPanelVisible = "previewPanelVisible"

    static let all = [
        selectedSong,
        sortMode,
        appearance,
        lyricSize,
        defaultLyricsFontFamily,
        editorPanelVisible,
        previewPanelVisible,
    ]
}
