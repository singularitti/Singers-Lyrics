import Foundation
import CryptoKit

/// Reconciles hydrated libraries against their last shared metadata snapshot.
/// A song and its separately trashed takes form one ownership unit: choosing a
/// branch never accidentally retains the same take in both active and Trash.
enum LibrarySyncMerge {
    enum MergeError: LocalizedError {
        case unsupportedSchema
        case duplicateIdentity
        case invalidMetadata
        case missingAudio
        case incompleteHistory

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema: "The synced library uses an unsupported version."
            case .duplicateIdentity: "The synced library contains conflicting ownership identifiers."
            case .invalidMetadata: "The synced library contains invalid recording or date metadata."
            case .missingAudio: "A synced recording is missing its audio."
            case .incompleteHistory:
                "Some previously synced songs or recordings are unavailable. Sync is paused to preserve your library. Let iCloud finish downloading, then try again."
            }
        }
    }

    private struct Ownership: Codable {
        var song: Song?
        var trashedSong: TrashedSong?
        var recordings: [TrashedRecording] = []

        var ownedSong: Song? { song ?? trashedSong?.song }

        var recordingIDs: Set<UUID> {
            Set((ownedSong?.lines ?? []).flatMap { $0.recordings.map(\.id) })
                .union(recordings.map(\.id))
        }

        func retainsContent(of other: Ownership) -> Bool {
            (other.ownedSong == nil || ownedSong != nil)
                && other.recordingIDs.isSubset(of: recordingIDs)
        }

        mutating func updateSong(_ transform: (inout Song) -> Void) {
            if song != nil { transform(&song!) }
            if trashedSong != nil { transform(&trashedSong!.song) }
        }
    }

    static func metadataEqual(_ lhs: LibraryDocument, _ rhs: LibraryDocument) throws -> Bool {
        try metadataData(lhs) == metadataData(rhs)
    }

    /// The model's Codable representation deliberately excludes all audio.
    /// Tombstone sets are sorted explicitly because Set's encoding order varies.
    static func metadataData(_ document: LibraryDocument) throws -> Data {
        let data = try encoder().encode(document)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MergeError.invalidMetadata
        }
        for key in ["permanentlyDeletedSongIDs", "permanentlyDeletedRecordingIDs"] {
            if let identifiers = object[key] as? [String] { object[key] = identifiers.sorted() }
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func decodeMetadata(_ data: Data) throws -> LibraryDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = LibraryDateCodec.date(from: value), date.timeIntervalSince1970.isFinite else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid library date")
            }
            return date
        }
        let document = try decoder.decode(LibraryDocument.self, from: data)
        try validate(document, requireAudio: false)
        return document
    }

    static func merge(
        base: LibraryDocument,
        local: LibraryDocument,
        remote: LibraryDocument,
        requireAudio: Bool = true
    ) throws -> LibraryDocument {
        // Check each input before constructing dictionaries, which must never
        // silently overwrite duplicate ownership or crash on malformed input.
        for document in [base, local, remote] { try validate(document, requireAudio: false) }
        let documents = [base, local, remote]
        let deletedSongs = documents.reduce(into: Set<UUID>()) {
            $0.formUnion($1.permanentlyDeletedSongIDs)
            $0.formUnion($1.trashedSongs.filter(\.isPendingPermanentDeletion).map(\.id))
        }
        var deletedRecordings = documents.reduce(into: Set<UUID>()) {
            $0.formUnion($1.permanentlyDeletedRecordingIDs)
            $0.formUnion($1.trashedRecordings.filter(\.isPendingPermanentDeletion).map(\.id))
        }
        // File providers can expose an older snapshot than our checkpoint.
        // Absence is not deletion intent: only explicit tombstones or a pending
        // permanent deletion may remove retained songs or recordings.
        for document in documents {
            // A pending purge snapshot identifies the attached takes actually
            // being deleted. A stale song on another device cannot expand that
            // intent to separately trashed takes, which remain recoverable.
            for entry in document.trashedSongs where entry.isPendingPermanentDeletion {
                deletedRecordings.formUnion(entry.song.lines.flatMap { $0.recordings.map(\.id) })
            }
        }

        var retainedDocuments = documents.map {
            pruned($0, songs: deletedSongs, recordings: deletedRecordings)
        }
        normalizeRecoveryOwners(&retainedDocuments, deletedSongs: deletedSongs)
        // A checkpoint contains metadata, not recording bytes. If both current
        // snapshots omit retained baseline content, pause instead of silently
        // dropping it or trying to reconstruct it without its audio.
        guard songIDs(retainedDocuments[0]).isSubset(of:
                songIDs(retainedDocuments[1]).union(songIDs(retainedDocuments[2]))),
              recordingIDs(retainedDocuments[0]).isSubset(of:
                recordingIDs(retainedDocuments[1]).union(recordingIDs(retainedDocuments[2]))) else {
            throw MergeError.incompleteHistory
        }
        let baseOwners = ownerships(retainedDocuments[0])
        let localOwners = ownerships(retainedDocuments[1])
        let remoteOwners = ownerships(retainedDocuments[2])
        let allIDs = Set(localOwners.keys).union(remoteOwners.keys).union(baseOwners.keys)
        var merged: [UUID: Ownership] = [:]
        var conflicts: [(original: UUID, id: UUID, owner: Ownership)] = []
        for id in allIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            let baseline = baseOwners[id]
            guard let localOwner = localOwners[id] else {
                merged[id] = remoteOwners[id]
                continue
            }
            guard let remoteOwner = remoteOwners[id] else {
                merged[id] = localOwner
                continue
            }
            if try equal(localOwner, remoteOwner) {
                var owner = localOwner
                mergeUsage(&owner, local: localOwner, remote: remoteOwner)
                merged[id] = owner
            } else if try equal(localOwner, baseline), remoteOwner.retainsContent(of: localOwner) {
                var owner = remoteOwner
                mergeUsage(&owner, local: localOwner, remote: remoteOwner)
                merged[id] = owner
            } else if try equal(remoteOwner, baseline), localOwner.retainsContent(of: remoteOwner) {
                var owner = localOwner
                mergeUsage(&owner, local: localOwner, remote: remoteOwner)
                merged[id] = owner
            } else {
                // Also retain both versions if a one-sided snapshot drops a
                // recording without moving it to Trash or explicitly purging it.
                // Both devices must choose the same original identity. A local
                // preference would swap original/copy ownership on the next
                // device and produce a third song for only two edit versions.
                let localData = try encoder().encode(comparable(localOwner))
                let remoteData = try encoder().encode(comparable(remoteOwner))
                let localWins = localData.lexicographicallyPrecedes(remoteData)
                var winner = localWins ? localOwner : remoteOwner
                var loser = localWins ? remoteOwner : localOwner
                mergeUsage(&winner, local: localOwner, remote: remoteOwner)
                mergeUsage(&loser, local: localOwner, remote: remoteOwner)
                merged[id] = winner
                let copy = try conflictCopy(loser, originalID: id)
                if !deletedSongs.contains(copy.id) {
                    var copyDocument = LibraryDocument()
                    if let song = copy.owner.song { copyDocument.songs = [song] }
                    if let song = copy.owner.trashedSong { copyDocument.trashedSongs = [song] }
                    copyDocument.trashedRecordings = copy.owner.recordings
                    if let retained = ownerships(pruned(copyDocument, songs: deletedSongs, recordings: deletedRecordings))[copy.id] {
                        conflicts.append((id, copy.id, retained))
                    }
                }
            }
        }
        // A prior retry may already have committed this deterministic copy.
        // Preserve its reconciled state, including any subsequent user edits.
        for index in conflicts.indices {
            if let existing = merged[conflicts[index].id] { conflicts[index].owner = existing }
            merged[conflicts[index].id] = conflicts[index].owner
        }

        var result = LibraryDocument()
        result.permanentlyDeletedSongIDs = deletedSongs
        result.permanentlyDeletedRecordingIDs = deletedRecordings
        let activeOrder = order(base.songs.map(\.id), local.songs.map(\.id), remote.songs.map(\.id))
        let trashOrder = order(base.trashedSongs.map(\.id), local.trashedSongs.map(\.id), remote.trashedSongs.map(\.id))
        let ownerOrder = order(Array(baseOwners.keys).sorted(by: uuidLess),
                               activeOrder + trashOrder + local.trashedRecordings.map(\.songID),
                               remote.songs.map(\.id) + remote.trashedSongs.map(\.id) + remote.trashedRecordings.map(\.songID))
        let conflictIDs = Set(conflicts.map(\.id))
        let allOwnerOrder = unique(ownerOrder + merged.keys.sorted(by: uuidLess)).filter { !conflictIDs.contains($0) }
        for id in allOwnerOrder {
            guard let owner = merged[id] else { continue }
            if let song = owner.song { result.songs.append(song) }
            if let song = owner.trashedSong { result.trashedSongs.append(song) }
            result.trashedRecordings.append(contentsOf: owner.recordings)
            for conflict in conflicts where conflict.original == id {
                if let song = conflict.owner.song { result.songs.append(song) }
                if let song = conflict.owner.trashedSong { result.trashedSongs.append(song) }
                result.trashedRecordings.append(contentsOf: conflict.owner.recordings)
            }
        }
        // Sort collections separately: owner ordering should not couple Trash
        // ordering to the active library. Copies follow their original item.
        result.songs = ordered(result.songs, preferred: activeOrder, conflicts: conflicts)
        result.trashedSongs = ordered(result.trashedSongs, preferred: trashOrder, conflicts: conflicts)
        let takeOrder = order(base.trashedRecordings.map(\.id), local.trashedRecordings.map(\.id), remote.trashedRecordings.map(\.id))
        result.trashedRecordings = ordered(result.trashedRecordings, preferred: takeOrder, conflicts: [])
        // Folder history is merged as metadata first; only recordings retained
        // by the merged heads need to be downloaded before local adoption.
        try validate(result, requireAudio: requireAudio)
        return result
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            guard date.timeIntervalSince1970.isFinite else { throw MergeError.invalidMetadata }
            var container = encoder.singleValueContainer()
            try container.encode(LibraryDateCodec.string(from: date))
        }
        return encoder
    }

    private static func equal(_ lhs: Ownership?, _ rhs: Ownership?) throws -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return try encoder().encode(comparable(lhs)) == encoder().encode(comparable(rhs))
    }

    private static func comparable(_ owner: Ownership) -> Ownership {
        var owner = owner
        let ignoreUsage: (inout Song) -> Void = { song in
            song.lastPlayedAt = nil
            song.updatedAt = song.createdAt
        }
        owner.updateSong(ignoreUsage)
        for index in owner.recordings.indices {
            if owner.recordings[index].restorationContext != nil {
                ignoreUsage(&owner.recordings[index].restorationContext!.song)
            }
        }
        owner.recordings.sort { uuidLess($0.id, $1.id) }
        return owner
    }

    private static func mergeUsage(_ owner: inout Ownership, local: Ownership?, remote: Ownership?) {
        let songs = [local?.ownedSong, remote?.ownedSong].compactMap { $0 }
        owner.updateSong { song in
            song.lastPlayedAt = (songs.compactMap(\.lastPlayedAt) + [song.lastPlayedAt].compactMap { $0 }).max()
            song.updatedAt = (songs.map(\.updatedAt) + [song.updatedAt]).max() ?? song.updatedAt
        }
    }

    private static func ownerships(_ document: LibraryDocument) -> [UUID: Ownership] {
        var result: [UUID: Ownership] = [:]
        for song in document.songs { result[song.id] = Ownership(song: song) }
        for song in document.trashedSongs { result[song.id] = Ownership(trashedSong: song) }
        for recording in document.trashedRecordings {
            result[recording.songID, default: Ownership()].recordings.append(recording)
        }
        return result
    }

    private static func pruned(_ document: LibraryDocument, songs: Set<UUID>, recordings: Set<UUID>) -> LibraryDocument {
        var result = document
        result.songs.removeAll { songs.contains($0.id) }
        result.trashedSongs.removeAll { songs.contains($0.id) }
        // Independently deleted takes outlive a permanently deleted parent.
        // Their ownership snapshots let restoration create a replacement song.
        result.trashedRecordings.removeAll { recordings.contains($0.id) }
        func prune(_ song: inout Song) {
            for index in song.lines.indices {
                song.lines[index].recordings.removeAll { recordings.contains($0.id) }
                if let id = song.lines[index].selectedRecordingID,
                   !song.lines[index].recordings.contains(where: { $0.id == id }) {
                    song.lines[index].selectedRecordingID = nil
                }
            }
        }
        for index in result.songs.indices { prune(&result.songs[index]) }
        for index in result.trashedSongs.indices { prune(&result.trashedSongs[index].song) }
        return result
    }

    /// An offline restoration can move a retained take to a recovered parent
    /// while another device still owns its snapshot under the deleted parent.
    /// Normalize that movement before grouping, so the same recording is never
    /// reconciled independently under two song owners. No parent is created here.
    private static func normalizeRecoveryOwners(
        _ documents: inout [LibraryDocument], deletedSongs: Set<UUID>
    ) {
        let existingOwners = documents.reduce(into: Set<UUID>()) { owners, document in
            owners.formUnion(songIDs(document))
            owners.formUnion(document.trashedRecordings.map(\.songID))
        }
        var replacements: [UUID: UUID] = [:]
        for original in deletedSongs {
            var visited: Set<UUID> = [original]
            var candidate = recoverySongID(forDeletedSongID: original)
            while deletedSongs.contains(candidate), visited.insert(candidate).inserted {
                candidate = recoverySongID(forDeletedSongID: candidate)
            }
            guard !deletedSongs.contains(candidate), existingOwners.contains(candidate) else { continue }
            replacements[original] = candidate
        }
        guard !replacements.isEmpty else { return }
        for documentIndex in documents.indices {
            for recordingIndex in documents[documentIndex].trashedRecordings.indices {
                var entry = documents[documentIndex].trashedRecordings[recordingIndex]
                if let replacement = replacements[entry.songID] {
                    entry.songID = replacement
                    if var context = entry.restorationContext {
                        context.song.id = replacement
                        entry.restorationContext = context
                    }
                }
                if var context = entry.restorationContext {
                    context.songOrder = context.songOrder.map { replacements[$0] ?? $0 }
                    entry.restorationContext = context
                }
                documents[documentIndex].trashedRecordings[recordingIndex] = entry
            }
        }
    }

    /// Remap the entire remote unit, including restoration snapshots. Copies of
    /// individually trashed takes remain in Trash and restore into the copied song.
    private static func conflictCopy(_ original: Ownership, originalID: UUID) throws -> (id: UUID, owner: Ownership) {
        var owner = original
        var seed = Data("LibrarySyncMerge.conflict.v1.\(originalID.uuidString)".utf8)
        seed.append(try encoder().encode(comparable(original)))
        let id = stableID(seed)
        var lineMap: [UUID: UUID] = [:]
        var recordingMap: [UUID: UUID] = [:]
        func lineID(_ original: UUID) -> UUID {
            if let mapped = lineMap[original] { return mapped }
            let mapped = stableID(Data("\(id.uuidString).line.\(original.uuidString)".utf8))
            lineMap[original] = mapped
            return mapped
        }
        func recordingID(_ original: UUID) -> UUID {
            if let mapped = recordingMap[original] { return mapped }
            let mapped = stableID(Data("\(id.uuidString).recording.\(original.uuidString)".utf8))
            recordingMap[original] = mapped
            return mapped
        }
        func copySong(_ song: inout Song) {
            song.id = id
            song.title += " (iCloud conflict)"
            for index in song.lines.indices {
                song.lines[index].id = lineID(song.lines[index].id)
                for take in song.lines[index].recordings.indices {
                    song.lines[index].recordings[take].id = recordingID(song.lines[index].recordings[take].id)
                }
                if let selected = song.lines[index].selectedRecordingID {
                    song.lines[index].selectedRecordingID = recordingID(selected)
                }
            }
        }
        owner.updateSong(copySong)
        if owner.trashedSong != nil {
            owner.trashedSong!.siblingOrder = owner.trashedSong!.siblingOrder.map { $0 == originalID ? id : $0 }
        }
        // Populate every map first so snapshots of deleted lines refer to the
        // same copied identities regardless of recording iteration order.
        for recording in owner.recordings {
            _ = lineID(recording.lineID)
            _ = recordingID(recording.id)
            if let context = recording.restorationContext {
                for oldID in context.lineOrder { _ = lineID(oldID) }
            }
        }
        for index in owner.recordings.indices {
            owner.recordings[index].songID = id
            owner.recordings[index].lineID = lineID(owner.recordings[index].lineID)
            owner.recordings[index].recording.id = recordingID(owner.recordings[index].id)
            owner.recordings[index].songTitle += " (iCloud conflict)"
            if var context = owner.recordings[index].restorationContext {
                copySong(&context.song)
                context.line.id = lineID(context.line.id)
                context.lineOrder = context.lineOrder.map { lineID($0) }
                context.songOrder = context.songOrder.map { $0 == originalID ? id : $0 }
                owner.recordings[index].restorationContext = context
            }
        }
        return (id, owner)
    }

    /// Content-derived IDs make the same conflict copy idempotent across sync
    /// retries and interrupted checkpoint writes. The UUID uses RFC 9562's
    /// custom version 8 format with the standard variant bits.
    private static func stableID(_ seed: Data) -> UUID {
        var bytes = Array(SHA256.hash(data: seed).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Devices restoring independently trashed takes from a purged song agree
    /// on a new parent identity without reviving the permanently deleted one.
    static func recoverySongID(forDeletedSongID songID: UUID) -> UUID {
        stableID(Data("LibrarySyncMerge.recovery.v1.\(songID.uuidString)".utf8))
    }

    private static func songIDs(_ document: LibraryDocument) -> Set<UUID> {
        Set(document.songs.map(\.id)).union(document.trashedSongs.map(\.id))
    }

    private static func recordingIDs(_ document: LibraryDocument) -> Set<UUID> {
        Set((document.songs + document.trashedSongs.map(\.song)).flatMap {
            $0.lines.flatMap { $0.recordings.map(\.id) }
        }).union(document.trashedRecordings.map(\.id))
    }

    private static func uuidLess(_ lhs: UUID, _ rhs: UUID) -> Bool { lhs.uuidString < rhs.uuidString }

    private static func unique(_ ids: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        return ids.filter { seen.insert($0).inserted }
    }

    /// Preserve a one-sided reorder; concurrent reorders prefer local order.
    /// Insert additions beside their nearest surviving neighbor on the other side.
    private static func order(_ base: [UUID], _ local: [UUID], _ remote: [UUID]) -> [UUID] {
        var result = unique(local == base ? remote : local)
        let secondary = unique(local == base ? local : remote)
        for (index, id) in secondary.enumerated() where !result.contains(id) {
            if let next = secondary.dropFirst(index + 1).first(where: { result.contains($0) }),
               let position = result.firstIndex(of: next) {
                result.insert(id, at: position)
            } else {
                result.append(id)
            }
        }
        return result
    }

    private static func ordered<T: Identifiable>(
        _ items: [T], preferred: [UUID], conflicts: [(original: UUID, id: UUID, owner: Ownership)]
    ) -> [T] where T.ID == UUID {
        var ids: [UUID] = []
        for id in preferred {
            ids.append(id)
            ids.append(contentsOf: conflicts.filter { $0.original == id }.map(\.id))
        }
        ids = unique(ids + items.map(\.id))
        let positions = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        return items.sorted { positions[$0.id, default: Int.max] < positions[$1.id, default: Int.max] }
    }

    private static func validate(_ document: LibraryDocument, requireAudio: Bool) throws {
        guard document.schemaVersion == LibraryDocument.currentSchemaVersion else { throw MergeError.unsupportedSchema }
        var songs: Set<UUID> = []
        var lines: [UUID: UUID] = [:]
        var recordings: Set<UUID> = []
        func check(_ recording: VoiceRecording, pending: Bool) throws {
            guard recordings.insert(recording.id).inserted else { throw MergeError.duplicateIdentity }
            guard recording.createdAt.timeIntervalSince1970.isFinite,
                  recording.duration.isFinite, recording.duration >= 0 else { throw MergeError.invalidMetadata }
            if requireAudio && !pending && recording.audioData.isEmpty { throw MergeError.missingAudio }
        }
        for song in document.songs + document.trashedSongs.map(\.song) {
            guard songs.insert(song.id).inserted else { throw MergeError.duplicateIdentity }
            guard song.createdAt.timeIntervalSince1970.isFinite, song.updatedAt.timeIntervalSince1970.isFinite,
                  song.lastPlayedAt?.timeIntervalSince1970.isFinite ?? true else { throw MergeError.invalidMetadata }
            let pending = document.trashedSongs.contains { $0.id == song.id && $0.isPendingPermanentDeletion }
            for line in song.lines {
                guard lines.updateValue(song.id, forKey: line.id) == nil else { throw MergeError.duplicateIdentity }
                guard line.timestampSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw MergeError.invalidMetadata }
                if let selected = line.selectedRecordingID, !line.recordings.contains(where: { $0.id == selected }) {
                    throw MergeError.invalidMetadata
                }
                for recording in line.recordings { try check(recording, pending: pending) }
            }
        }
        for entry in document.trashedSongs {
            guard entry.deletedAt.timeIntervalSince1970.isFinite, entry.originalIndex >= 0 else { throw MergeError.invalidMetadata }
        }
        for entry in document.trashedRecordings {
            guard entry.deletedAt.timeIntervalSince1970.isFinite else { throw MergeError.invalidMetadata }
            if let existingOwner = lines[entry.lineID], existingOwner != entry.songID { throw MergeError.duplicateIdentity }
            // A missing parent is an intentional recoverable snapshot, not an
            // orphan: AppModel can reconstruct it from these ownership fields.
            lines[entry.lineID] = entry.songID
            if let context = entry.restorationContext {
                guard context.song.id == entry.songID, context.line.id == entry.lineID,
                      context.song.lines.isEmpty, context.line.recordings.isEmpty,
                      context.line.selectedRecordingID == nil else { throw MergeError.invalidMetadata }
            }
            try check(entry.recording, pending: entry.isPendingPermanentDeletion)
        }
        // Also validate dates in restoration snapshots and encoded numeric fields.
        _ = try encoder().encode(document)
    }
}
