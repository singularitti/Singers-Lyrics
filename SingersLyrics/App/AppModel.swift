#if os(macOS)
import AppKit
#endif
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
    private struct LinkedTrackCandidate: Sendable {
        var songID: UUID
        var url: URL
    }

    private struct LinkedTrackLookupResult: Sendable {
        var candidate: LinkedTrackCandidate
        var metadata: TrackMetadata?
    }

    private let store: any LibraryStoring
    private var loadTask: Task<LibraryDocument, Error>?
    private var saveTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var isDirty = false
    // Undo snapshots must never resurrect a take after explicit permanent deletion.
    private var permanentlyDeletedRecordingIDs: Set<UUID> = []

    var hasUnsavedChanges: Bool { isDirty }

    var library = LibraryDocument()
    var selectedSongID: UUID?
    var selectedSongIDs: Set<UUID> = []
    var isShowingRecordingTrash = false
    private(set) var isPermanentlyDeletingRecordings = false
    private(set) var isPermanentlyDeletingSongs = false
    var isPermanentlyDeletingTrash: Bool {
        isPermanentlyDeletingRecordings || isPermanentlyDeletingSongs
    }
    /// One recording list for both Trash tabs, without duplicating persisted ownership.
    var recordingsInTrash: [TrashedRecording] {
        library.trashedRecordings + library.trashedSongs.flatMap { entry in
            entry.song.lines.enumerated().flatMap { lineIndex, line in
                line.recordings.map { recording in
                    TrashedRecording(
                        recording: recording,
                        songID: entry.id,
                        lineID: line.id,
                        songTitle: entry.song.title,
                        songArtist: entry.song.artist,
                        lyricText: line.lyric.plainText,
                        annotation: line.annotation,
                        deletedAt: entry.deletedAt,
                        isPendingPermanentDeletion: entry.isPendingPermanentDeletion,
                        restorationContext: RecordingRestorationContext(
                            song: entry.song,
                            line: line,
                            lineIndex: lineIndex,
                            songIndex: entry.originalIndex,
                            lineOrder: entry.song.lines.map(\.id),
                            songOrder: entry.siblingOrder
                        )
                    )
                }
            }
        }
    }
    var trashedItemCount: Int { library.trashedSongs.count + recordingsInTrash.count }
    var isCreatingSong = false
    var isImportingSongBundle = false
    private(set) var isLoaded = false
    private(set) var autosaveDisabled = false
    var storageIssue: StorageIssue?
    let voiceRecordings = VoiceRecordingController()

    init(store: any LibraryStoring) {
        self.store = store
        voiceRecordings.onRecordingFinished = { [weak self] songID, lineID, recording in
            self?.appendRecording(recording, songID: songID, lineID: lineID)
        }
    }

    func load() async {
        guard !isLoaded else { return }
        // An iOS file-open event can arrive during the initial scene load.
        // Share that read so a second completion cannot overwrite an import.
        let task: Task<LibraryDocument, Error>
        if let loadTask {
            task = loadTask
        } else {
            let store = self.store
            task = Task { try await store.load() }
            loadTask = task
        }
        do {
            let document = try await task.value
            guard !isLoaded else { return }
            library = document
            permanentlyDeletedRecordingIDs = Set(document.trashedRecordings.filter(\.isPendingPermanentDeletion).map(\.id))
                .union(document.trashedSongs.filter(\.isPendingPermanentDeletion).flatMap { entry in
                    entry.song.lines.flatMap { $0.recordings.map(\.id) }
                })
            if let saved = UserDefaults.standard.string(forKey: PreferenceKey.selectedSong),
               let id = UUID(uuidString: saved),
               library.songs.contains(where: { $0.id == id }) {
                selectedSongID = id
                selectedSongIDs = [id]
            }
        } catch {
            guard !isLoaded else { return }
            autosaveDisabled = true
            storageIssue = StorageIssue(
                title: "Library Could Not Be Opened",
                message: [error.localizedDescription, (error as? LocalizedError)?.recoverySuggestion]
                    .compactMap { $0 }
                    .joined(separator: "\n\n")
            )
        }
        isLoaded = true
        loadTask = nil
    }

    func backfillLinkedTrackMetadata(using lookup: any TrackMetadataLookingUp) async {
        var changed = false
        for index in library.songs.indices where
            library.songs[index].album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            guard let album = library.songs[index].linkedTrackMetadata?.album,
                  !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            library.songs[index].album = album
            changed = true
        }

        let candidates = library.songs.compactMap { song -> LinkedTrackCandidate? in
            let linkedAlbum = song.linkedTrackMetadata?.album
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard (song.linkedTrackMetadata == nil || linkedAlbum.isEmpty),
                  let url = song.appleMusicURL else {
                return nil
            }
            return LinkedTrackCandidate(songID: song.id, url: url)
        }
        guard !candidates.isEmpty else {
            if changed {
                markChanged()
            }
            return
        }

        let resolve: @Sendable (LinkedTrackCandidate) async -> LinkedTrackLookupResult = {
            candidate in
            let metadata: TrackMetadata?
            do {
                metadata = try await lookup.lookup(url: candidate.url)
            } catch {
                metadata = nil
            }
            return LinkedTrackLookupResult(candidate: candidate, metadata: metadata)
        }

        let results = await withTaskGroup(
            of: LinkedTrackLookupResult.self,
            returning: [LinkedTrackLookupResult].self
        ) { group in
            let maximumConcurrentLookups = 4
            var nextCandidateIndex = 0
            var results: [LinkedTrackLookupResult] = []

            while nextCandidateIndex < min(maximumConcurrentLookups, candidates.count) {
                let candidate = candidates[nextCandidateIndex]
                nextCandidateIndex += 1
                group.addTask { await resolve(candidate) }
            }

            while let result = await group.next() {
                results.append(result)
                if nextCandidateIndex < candidates.count {
                    let candidate = candidates[nextCandidateIndex]
                    nextCandidateIndex += 1
                    group.addTask { await resolve(candidate) }
                }
            }
            return results
        }

        for result in results {
            guard let metadata = result.metadata,
                  !metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let index = library.songs.firstIndex(where: {
                      $0.id == result.candidate.songID
                  }),
                  library.songs[index].appleMusicURL == result.candidate.url else {
                continue
            }
            if library.songs[index].linkedTrackMetadata != metadata {
                library.songs[index].linkedTrackMetadata = metadata
                changed = true
            }
            if library.songs[index].album
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !metadata.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                library.songs[index].album = metadata.album
                changed = true
            }
        }

        if changed {
            markChanged()
        }
    }

    func selectSong(_ id: UUID?) {
        isShowingRecordingTrash = false
        if id != selectedSongID { voiceRecordings.stop() }
        selectedSongID = id
        selectedSongIDs = id.map { Set([$0]) } ?? []
        persistSelectedSong(id)
    }

    func selectSongs(_ ids: Set<UUID>) {
        isShowingRecordingTrash = false
        let validIDs = ids.intersection(Set(library.songs.map(\.id)))
        if validIDs != selectedSongIDs { voiceRecordings.stop() }
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

    func showRecordingTrash() {
        selectSong(nil)
        isShowingRecordingTrash = true
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
        song.album = metadata.album
        song.appleMusicURL = appleMusicURL
        song.linkedTrackMetadata = metadata
        library.songs.insert(song, at: 0)
        selectSong(song.id)
        markChanged()
        return song
    }

    func updateAppleMusicLink(
        for songID: UUID,
        appleMusicURL: URL,
        metadata: TrackMetadata
    ) {
        guard var song = song(withID: songID) else { return }
        song.appleMusicURL = appleMusicURL
        song.linkedTrackMetadata = metadata
        if song.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            song.album = metadata.album
        }
        replaceSong(song)
    }

    func replaceSong(_ song: Song) {
        guard let index = library.songs.firstIndex(where: { $0.id == song.id }) else { return }
        if voiceRecordings.recordingSongID == song.id,
           let recordingLineID = voiceRecordings.recordingLineID,
           !song.lines.contains(where: { $0.id == recordingLineID }) {
            voiceRecordings.finishRecording()
            guard !voiceRecordings.hasUncommittedRecording else { return }
        }
        let existing = library.songs[index]
        var updated = song
        updated.tags = Song.normalizedTags(updated.tags)
        for lineIndex in updated.lines.indices {
            updated.lines[lineIndex].recordings.removeAll {
                permanentlyDeletedRecordingIDs.contains($0.id)
            }
            if let selectedID = updated.lines[lineIndex].selectedRecordingID,
               !updated.lines[lineIndex].recordings.contains(where: { $0.id == selectedID }) {
                updated.lines[lineIndex].selectedRecordingID = nil
            }
        }

        if updated.appleMusicURL == existing.appleMusicURL,
           updated.linkedTrackMetadata == nil {
            if let linkedTrackMetadata = existing.linkedTrackMetadata {
                updated.linkedTrackMetadata = linkedTrackMetadata
            } else if existing.appleMusicURL != nil,
                      updated.title != existing.title
                        || updated.artist != existing.artist
                        || updated.album != existing.album {
                // Version-1 libraries originally used the display metadata for
                // Music matching. Preserve those pre-edit values the first time
                // a legacy song's visible title, singer, or album is customized.
                updated.linkedTrackMetadata = TrackMetadata(
                    title: existing.title,
                    artist: existing.artist,
                    album: existing.album
                )
            }
        }

        updated.updatedAt = Date()
        let remainingIDs = Set(updated.lines.flatMap { $0.recordings.map(\.id) })
        moveRecordingsToTrash(from: existing, excluding: remainingIDs)
        library.songs[index] = updated
        // Undoing a normal deletion restores ownership and takes the item out of Trash.
        library.trashedRecordings.removeAll { remainingIDs.contains($0.id) }
        voiceRecordings.reconcile(with: library.songs)
        markChanged()
    }

    private func appendRecording(_ recording: VoiceRecording, songID: UUID, lineID: UUID) {
        guard let songIndex = library.songs.firstIndex(where: { $0.id == songID }),
              let lineIndex = library.songs[songIndex].lines.firstIndex(where: { $0.id == lineID }) else {
            return
        }
        library.songs[songIndex].lines[lineIndex].recordings.append(recording)
        library.songs[songIndex].lines[lineIndex].selectedRecordingID = recording.id
        library.songs[songIndex].updatedAt = Date()
        markChanged()
    }

    func toggleFavorite(songID: UUID) {
        guard let index = library.songs.firstIndex(where: { $0.id == songID }) else { return }
        library.songs[index].isFavorite.toggle()
        library.songs[index].updatedAt = Date()
        markChanged()
    }

    func recordPlayback(songID: UUID, at date: Date) {
        guard let index = library.songs.firstIndex(where: { $0.id == songID }) else { return }
        library.songs[index].lastPlayedAt = date
        markChanged()
    }

    @discardableResult
    func duplicateSongs(_ ids: Set<UUID>, now: Date = Date()) -> Set<UUID> {
        let validIDs = ids.intersection(Set(library.songs.map(\.id)))
        guard !validIDs.isEmpty else { return [] }
        if voiceRecordings.recordingSongID.map(validIDs.contains) == true {
            voiceRecordings.finishRecording()
            guard !voiceRecordings.hasUncommittedRecording else { return [] }
        }

        var duplicateIDs: Set<UUID> = []
        library.songs = library.songs.flatMap { song -> [Song] in
            guard validIDs.contains(song.id) else { return [song] }

            var duplicate = song
            duplicate.id = UUID()
            duplicate.lines = song.lines.map { line in
                var duplicateLine = line
                duplicateLine.id = UUID()
                duplicateLine = Self.copyRecordingIdentities(in: duplicateLine)
                return duplicateLine
            }
            duplicate.createdAt = now
            duplicate.updatedAt = now
            duplicate.lastPlayedAt = nil
            duplicateIDs.insert(duplicate.id)
            return [song, duplicate]
        }

        selectSongs(duplicateIDs)
        markChanged()
        return duplicateIDs
    }

    @discardableResult
    func importSongs(_ songs: [Song]) -> [UUID] {
        guard !songs.isEmpty else { return [] }

        let retainedSongs = library.songs + library.trashedSongs.map(\.song)
        var occupiedSongIDs = Set(retainedSongs.map(\.id))
        var occupiedLineIDs = Set(retainedSongs.flatMap { $0.lines.map(\.id) })
        var occupiedRecordingIDs = Set(retainedSongs.flatMap { $0.lines.flatMap { $0.recordings.map(\.id) } })
            .union(library.trashedRecordings.map(\.id))
            .union(permanentlyDeletedRecordingIDs)
        var importedSongs: [Song] = []

        for sourceSong in songs {
            var song = sourceSong
            song.tags = Song.normalizedTags(song.tags)
            let songIdentityConflicts = occupiedSongIDs.contains(song.id)
            if songIdentityConflicts {
                song.id = UUID()
            }
            occupiedSongIDs.insert(song.id)

            song.lines = song.lines.map { sourceLine in
                var line = sourceLine
                if songIdentityConflicts || occupiedLineIDs.contains(line.id) {
                    line.id = UUID()
                }
                let selectedID = line.selectedRecordingID
                line.recordings = line.recordings.map { sourceRecording in
                    var recording = sourceRecording
                    if songIdentityConflicts || occupiedRecordingIDs.contains(recording.id) {
                        recording.id = UUID()
                    }
                    if sourceRecording.id == selectedID {
                        line.selectedRecordingID = recording.id
                    }
                    occupiedRecordingIDs.insert(recording.id)
                    return recording
                }
                occupiedLineIDs.insert(line.id)
                return line
            }
            importedSongs.append(song)
        }

        library.songs.append(contentsOf: importedSongs)
        selectSong(importedSongs.first?.id)
        markChanged()
        return importedSongs.map(\.id)
    }

    func deleteSongs(_ ids: Set<UUID>) {
        guard !isPermanentlyDeletingTrash else { return }
        let ids = ids.intersection(Set(library.songs.map(\.id)))
            .subtracting(library.trashedSongs.map(\.id))
        guard !ids.isEmpty else { return }
        if voiceRecordings.recordingSongID.map(ids.contains) == true {
            voiceRecordings.finishRecording()
            guard !voiceRecordings.hasUncommittedRecording else { return }
        }
        let deletedAt = Date()
        let siblingOrder = library.songs.map(\.id)
        for (index, song) in library.songs.enumerated() where ids.contains(song.id) {
            library.trashedSongs.append(TrashedSong(
                song: song,
                deletedAt: deletedAt,
                originalIndex: index,
                siblingOrder: siblingOrder
            ))
        }
        library.songs.removeAll { ids.contains($0.id) }
        voiceRecordings.reconcile(with: library.songs)
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

    @discardableResult
    func restoreSongs(_ ids: Set<UUID>) -> Set<UUID> {
        guard !isPermanentlyDeletingTrash, !ids.isEmpty else { return [] }
        let candidates = library.trashedSongs.filter {
            ids.contains($0.id) && !$0.isPendingPermanentDeletion
        }.sorted { lhs, rhs in
            if lhs.originalIndex != rhs.originalIndex { return lhs.originalIndex < rhs.originalIndex }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        var occupiedSongIDs = Set(library.songs.map(\.id))
        var occupiedLineIDs = Set(library.songs.flatMap { $0.lines.map(\.id) })
        var occupiedRecordingIDs = Set(library.songs.flatMap { $0.lines.flatMap { $0.recordings.map(\.id) } })
            .union(library.trashedRecordings.map(\.id))
            .union(permanentlyDeletedRecordingIDs)
        var restoredIDs: Set<UUID> = []
        for entry in candidates {
            let song = entry.song
            let lineIDs = Set(song.lines.map(\.id))
            let recordingIDs = Set(song.lines.flatMap { $0.recordings.map(\.id) })
            guard !occupiedSongIDs.contains(song.id),
                  occupiedLineIDs.isDisjoint(with: lineIDs),
                  occupiedRecordingIDs.isDisjoint(with: recordingIDs),
                  (try? RecordingAssetStorage.validate(songs: [song], requireAudio: true)) != nil else {
                continue
            }
            let index = Self.restoredInsertionIndex(
                for: song.id,
                siblingOrder: entry.siblingOrder,
                currentIDs: library.songs.map(\.id),
                fallbackIndex: entry.originalIndex
            )
            library.songs.insert(song, at: index)
            occupiedSongIDs.insert(song.id)
            occupiedLineIDs.formUnion(lineIDs)
            occupiedRecordingIDs.formUnion(recordingIDs)
            restoredIDs.insert(song.id)
        }
        guard !restoredIDs.isEmpty else { return [] }
        library.trashedSongs.removeAll { restoredIDs.contains($0.id) }
        markChanged()
        return restoredIDs
    }

    private func moveRecordingsToTrash(from song: Song, excluding keptIDs: Set<UUID> = []) {
        var trashedIDs = Set(library.trashedRecordings.map(\.id))
        let deletedAt = Date()
        let songIndex = library.songs.firstIndex(where: { $0.id == song.id })
        let songOrder = library.songs.map(\.id)
        let lineOrder = song.lines.map(\.id)
        for (lineIndex, line) in song.lines.enumerated() {
            for recording in line.recordings where
                !keptIDs.contains(recording.id) && !permanentlyDeletedRecordingIDs.contains(recording.id)
            {
                guard trashedIDs.insert(recording.id).inserted else { continue }
                library.trashedRecordings.append(TrashedRecording(
                    recording: recording,
                    songID: song.id,
                    lineID: line.id,
                    songTitle: song.title,
                    songArtist: song.artist,
                    lyricText: line.lyric.plainText,
                    annotation: line.annotation,
                    deletedAt: deletedAt,
                    restorationContext: RecordingRestorationContext(
                        song: song,
                        line: line,
                        lineIndex: lineIndex,
                        songIndex: songIndex,
                        lineOrder: lineOrder,
                        songOrder: songOrder
                    )
                ))
            }
        }
    }

    @discardableResult
    func restoreRecordings(_ ids: Set<UUID>) -> Set<UUID> {
        guard !isPermanentlyDeletingTrash, !ids.isEmpty else { return [] }
        let requested = recordingsInTrash.filter {
            ids.contains($0.id) && !$0.isPendingPermanentDeletion
                && !permanentlyDeletedRecordingIDs.contains($0.id) && !$0.recording.audioData.isEmpty
        }
        let parentIDs = Set(requested.map(\.songID))
        // Restore the complete owner before reattaching an independently deleted
        // take. Never replace a retained whole song with a partial reconstruction.
        let restoredSongIDs = restoreSongs(parentIDs)
        // Selected takes nested in those songs have already returned to the library.
        let restoredAttachedIDs = Set(library.songs.filter { restoredSongIDs.contains($0.id) }.flatMap { song in
            song.lines.flatMap { $0.recordings.map(\.id) }
        }).intersection(ids)
        let unavailableParentIDs = Set(library.trashedSongs.map(\.id))
        let retainedSongs = library.songs + library.trashedSongs.map(\.song)
        var activeRecordingIDs = Set(retainedSongs.flatMap { song in
            song.lines.flatMap { $0.recordings.map(\.id) }
        })
        var lineOwners: [UUID: UUID] = [:]
        for song in retainedSongs {
            for line in song.lines { lineOwners[line.id] = song.id }
        }
        let recoverable = library.trashedRecordings.filter {
            ids.contains($0.id) && !$0.isPendingPermanentDeletion
                && !unavailableParentIDs.contains($0.songID)
                && !permanentlyDeletedRecordingIDs.contains($0.id)
                && !$0.recording.audioData.isEmpty && !activeRecordingIDs.contains($0.id)
        }.sorted { lhs, rhs in
            let lhsSongIndex = lhs.restorationContext?.songIndex ?? Int.max
            let rhsSongIndex = rhs.restorationContext?.songIndex ?? Int.max
            if lhsSongIndex != rhsSongIndex { return lhsSongIndex < rhsSongIndex }
            if lhs.songID != rhs.songID { return lhs.songID.uuidString < rhs.songID.uuidString }
            let lhsLineIndex = lhs.restorationContext?.lineIndex ?? Int.max
            let rhsLineIndex = rhs.restorationContext?.lineIndex ?? Int.max
            if lhsLineIndex != rhsLineIndex { return lhsLineIndex < rhsLineIndex }
            if lhs.lineID != rhs.lineID { return lhs.lineID.uuidString < rhs.lineID.uuidString }
            if lhs.recording.createdAt != rhs.recording.createdAt {
                return lhs.recording.createdAt > rhs.recording.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        let now = Date()
        var restoredIDs = restoredAttachedIDs
        for trashed in recoverable {
            // An imported or otherwise reused line identity must not create a
            // second line with that identity in a different song.
            guard !activeRecordingIDs.contains(trashed.id),
                  lineOwners[trashed.lineID].map({ $0 == trashed.songID }) ?? true else {
                continue
            }
            let songIndex: Int
            if let existing = library.songs.firstIndex(where: { $0.id == trashed.songID }) {
                songIndex = existing
            } else {
                var recovered = trashed.restorationContext?.song ?? Song(
                    id: trashed.songID,
                    title: trashed.songTitle,
                    artist: trashed.songArtist,
                    appleMusicURL: nil,
                    lines: [],
                    createdAt: trashed.recording.createdAt,
                    updatedAt: now
                )
                recovered.id = trashed.songID
                recovered.lines = []
                recovered.updatedAt = now
                songIndex = Self.restoredInsertionIndex(
                    for: trashed.songID,
                    siblingOrder: trashed.restorationContext?.songOrder ?? [],
                    currentIDs: library.songs.map(\.id),
                    fallbackIndex: trashed.restorationContext?.songIndex ?? library.songs.count
                )
                library.songs.insert(recovered, at: songIndex)
            }

            let lineIndex: Int
            if let existing = library.songs[songIndex].lines.firstIndex(where: { $0.id == trashed.lineID }) {
                lineIndex = existing
            } else {
                var recovered = trashed.restorationContext?.line ?? LyricLine(
                    id: trashed.lineID,
                    annotation: trashed.annotation,
                    lyric: .plain(trashed.lyricText),
                    timestampSeconds: nil
                )
                recovered.id = trashed.lineID
                recovered.recordings = []
                recovered.selectedRecordingID = nil
                lineIndex = Self.restoredInsertionIndex(
                    for: trashed.lineID,
                    siblingOrder: trashed.restorationContext?.lineOrder ?? [],
                    currentIDs: library.songs[songIndex].lines.map(\.id),
                    fallbackIndex: trashed.restorationContext?.lineIndex ?? library.songs[songIndex].lines.count
                )
                library.songs[songIndex].lines.insert(recovered, at: lineIndex)
                lineOwners[trashed.lineID] = trashed.songID
            }

            let selectedID = library.songs[songIndex].lines[lineIndex].selectedRecording?.id
            library.songs[songIndex].lines[lineIndex].recordings.append(trashed.recording)
            library.songs[songIndex].lines[lineIndex].selectedRecordingID = selectedID ?? trashed.id
            library.songs[songIndex].updatedAt = now
            activeRecordingIDs.insert(trashed.id)
            restoredIDs.insert(trashed.id)
        }

        guard !restoredIDs.isEmpty else { return [] }
        library.trashedRecordings.removeAll { restoredIDs.contains($0.id) }
        voiceRecordings.reconcile(with: library.songs)
        markChanged()
        return restoredIDs
    }

    private static func restoredInsertionIndex(
        for id: UUID,
        siblingOrder: [UUID],
        currentIDs: [UUID],
        fallbackIndex: Int
    ) -> Int {
        if let originalIndex = siblingOrder.firstIndex(of: id) {
            // Preserve the current sibling order and anchor the recovered owner
            // before the nearest surviving following sibling whenever possible.
            for neighbor in siblingOrder.dropFirst(originalIndex + 1) {
                if let index = currentIDs.firstIndex(of: neighbor) { return index }
            }
            for neighbor in siblingOrder.prefix(originalIndex).reversed() {
                if let index = currentIDs.firstIndex(of: neighbor) { return index + 1 }
            }
        }
        return min(max(0, fallbackIndex), currentIDs.count)
    }

    func permanentlyDeleteRecordings(_ ids: Set<UUID>) async {
        guard !isPermanentlyDeletingTrash else { return }
        let selectedRecordings = recordingsInTrash.filter { ids.contains($0.id) }
        let selectedIDs = Set(selectedRecordings.map(\.id))
        guard !selectedIDs.isEmpty else { return }
        guard !autosaveDisabled else {
            storageIssue = StorageIssue(
                title: "Recordings Could Not Be Deleted",
                message: "The library must be saved before audio can be permanently deleted. Resolve the library storage error and reopen the app to retry."
            )
            return
        }

        isPermanentlyDeletingRecordings = true
        defer { isPermanentlyDeletingRecordings = false }
        // Transfer selected nested takes into individual pending entries before
        // saving deletion intent. The song keeps its lyrics and remaining takes.
        let individualIDs = Set(library.trashedRecordings.map(\.id))
        for songIndex in library.trashedSongs.indices {
            for lineIndex in library.trashedSongs[songIndex].song.lines.indices {
                library.trashedSongs[songIndex].song.lines[lineIndex].recordings.removeAll {
                    selectedIDs.contains($0.id)
                }
                if let selectedID = library.trashedSongs[songIndex].song.lines[lineIndex].selectedRecordingID,
                   selectedIDs.contains(selectedID) {
                    library.trashedSongs[songIndex].song.lines[lineIndex].selectedRecordingID = nil
                }
            }
        }
        library.trashedRecordings.append(contentsOf: selectedRecordings.filter {
            !individualIDs.contains($0.id)
        })
        permanentlyDeletedRecordingIDs.formUnion(selectedIDs)
        for index in library.trashedRecordings.indices where selectedIDs.contains(library.trashedRecordings[index].id) {
            library.trashedRecordings[index].isPendingPermanentDeletion = true
            library.trashedRecordings[index].recording.audioData = Data()
        }
        markChanged()
        // Save the deletion intent first. A crash after unlinking is then a retryable
        // pending deletion, never a corrupt library with missing required audio.
        await flush()
        guard !autosaveDisabled else { return }
        #if os(macOS)
        for window in NSApp?.windows ?? [] { window.undoManager?.removeAllActions() }
        #endif

        let pending = library.trashedRecordings.filter { selectedIDs.contains($0.id) }
        var deletedIDs: Set<UUID> = []
        var failedCount = 0
        for recording in pending {
            do {
                try await store.permanentlyDeleteRecording(recording)
                deletedIDs.insert(recording.id)
            } catch {
                failedCount += 1
            }
        }
        if !deletedIDs.isEmpty {
            library.trashedRecordings.removeAll { deletedIDs.contains($0.id) }
            markChanged()
            await flush()
        }
        if failedCount > 0, !autosaveDisabled {
            storageIssue = StorageIssue(
                title: "Some Recordings Could Not Be Deleted",
                message: "\(failedCount) recording(s) remain in Trash with deletion pending. Check access to the library folder, then select them and choose Delete Permanently again."
            )
        }
    }

    func permanentlyDeleteSongs(_ ids: Set<UUID>) async {
        guard !isPermanentlyDeletingTrash else { return }
        let selectedIDs = ids.intersection(Set(library.trashedSongs.map(\.id)))
        guard !selectedIDs.isEmpty else { return }
        guard !autosaveDisabled else {
            storageIssue = StorageIssue(
                title: "Songs Could Not Be Deleted",
                message: "The library must be saved before songs can be permanently deleted. Resolve the library storage error and reopen the app to retry."
            )
            return
        }

        isPermanentlyDeletingSongs = true
        defer { isPermanentlyDeletingSongs = false }
        for index in library.trashedSongs.indices where selectedIDs.contains(library.trashedSongs[index].id) {
            library.trashedSongs[index].isPendingPermanentDeletion = true
            for lineIndex in library.trashedSongs[index].song.lines.indices {
                let recordings = library.trashedSongs[index].song.lines[lineIndex].recordings
                permanentlyDeletedRecordingIDs.formUnion(recordings.map(\.id))
                for recordingIndex in recordings.indices {
                    library.trashedSongs[index].song.lines[lineIndex].recordings[recordingIndex].audioData = Data()
                }
            }
        }
        markChanged()
        // Persist the full pending snapshot before unlinking anything. An
        // interrupted purge retains every identity needed to retry safely.
        await flush()
        guard !autosaveDisabled else { return }
        #if os(macOS)
        for window in NSApp?.windows ?? [] { window.undoManager?.removeAllActions() }
        #endif

        let pending = library.trashedSongs.filter { selectedIDs.contains($0.id) }
        var deletedIDs: Set<UUID> = []
        for entry in pending {
            var deletionSucceeded = true
            for line in entry.song.lines {
                for recording in line.recordings {
                    let pendingRecording = TrashedRecording(
                        recording: recording,
                        songID: entry.id,
                        lineID: line.id,
                        songTitle: entry.song.title,
                        songArtist: entry.song.artist,
                        lyricText: line.lyric.plainText,
                        annotation: line.annotation,
                        deletedAt: entry.deletedAt,
                        isPendingPermanentDeletion: true
                    )
                    do {
                        try await store.permanentlyDeleteRecording(pendingRecording)
                    } catch {
                        deletionSucceeded = false
                    }
                }
            }
            if deletionSucceeded { deletedIDs.insert(entry.id) }
        }
        if !deletedIDs.isEmpty {
            library.trashedSongs.removeAll { deletedIDs.contains($0.id) }
            markChanged()
            await flush()
        }
        let failedCount = selectedIDs.subtracting(deletedIDs).count
        if failedCount > 0, !autosaveDisabled {
            storageIssue = StorageIssue(
                title: "Some Songs Could Not Be Deleted",
                message: "\(failedCount) song(s) remain in Trash with deletion pending. Check access to the library folder, then select them and choose Delete Permanently again."
            )
        }
    }

    #if os(macOS)
    func revealRecordingInFinder(_ recordingID: UUID) async {
        guard let recording = recordingsInTrash.first(where: { $0.id == recordingID }) else { return }
        if !autosaveDisabled { await flush() }
        do {
            let url = try await store.recordingFileURL(
                songID: recording.songID, lineID: recording.lineID, recordingID: recording.id
            )
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            storageIssue = StorageIssue(
                title: "Recording File Could Not Be Revealed",
                message: recording.isPendingPermanentDeletion
                    ? "This recording's file may already have been removed. Select it and choose Delete Permanently to finish clearing the pending entry."
                    : "The audio file is unavailable or could not be saved. Check the library folder and try again."
            )
        }
    }
    #endif

    private static func copyRecordingIdentities(in source: LyricLine) -> LyricLine {
        var line = source
        line.recordings = source.recordings.map { original in
            var recording = original
            recording.id = UUID()
            if source.selectedRecordingID == original.id {
                line.selectedRecordingID = recording.id
            }
            return recording
        }
        return line
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
        if let persistenceTask { await persistenceTask.value }
        while isDirty, !autosaveDisabled {
            await persistCurrentDocument()
        }
    }

    #if os(macOS)
    func revealLibrary() {
        NSWorkspace.shared.activateFileViewerSelecting([JSONLibraryStore.defaultLibraryURL()])
    }
    #endif

    private func markChanged() {
        isDirty = true
        guard !autosaveDisabled else { return }
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
        while let persistenceTask { await persistenceTask.value }
        guard isDirty, !autosaveDisabled else { return }
        let snapshot = library
        let store = store
        let task = Task { [weak self] in
            do {
                try await store.save(snapshot)
                // Finishing a take can add edits while an older snapshot is being saved.
                if self?.library == snapshot { self?.isDirty = false }
            } catch {
                self?.autosaveDisabled = true
                self?.storageIssue = StorageIssue(
                    title: "Library Could Not Be Saved",
                    message: "Your in-memory edits have not been discarded. Autosave is paused.\n\n\(error.localizedDescription)"
                )
            }
            self?.persistenceTask = nil
        }
        persistenceTask = task
        await task.value
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
    static let recordsInLogicPro = "recordsInLogicPro"
    /// Excluded from `all`: Logic Pro keeps learned assignments for this MIDI source identity.
    static let logicProMIDISourceID = "logicProMIDISourceID"

    static let all = [
        selectedSong,
        sortMode,
        appearance,
        lyricSize,
        defaultLyricsFontFamily,
        editorPanelVisible,
        previewPanelVisible,
        recordsInLogicPro,
    ]
}
