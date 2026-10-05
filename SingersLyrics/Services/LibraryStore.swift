import Foundation

protocol LibraryStoring: Sendable {
    func load() async throws -> LibraryDocument
    func save(_ document: LibraryDocument) async throws
    func recordingFileURL(songID: UUID, lineID: UUID, recordingID: UUID) async throws -> URL
    func permanentlyDeleteRecording(_ recording: TrashedRecording) async throws
}

extension LibraryStoring {
    func recordingFileURL(songID: UUID, lineID: UUID, recordingID: UUID) async throws -> URL {
        throw LibraryStoreError.featureUnsupported
    }

    func permanentlyDeleteRecording(_ recording: TrashedRecording) async throws {
        throw LibraryStoreError.featureUnsupported
    }
}

enum LibraryStoreError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case corruptLibrary(String)
    case featureUnsupported
    case permanentDeletionNotCommitted

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "This library uses unsupported schema version \(version)."
        case .corruptLibrary:
            "The song library could not be read. The original file has been left unchanged."
        case .featureUnsupported:
            "This library does not support access to recording files."
        case .permanentDeletionNotCommitted:
            "The recording must be saved as pending permanent deletion before its audio file can be removed."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .featureUnsupported:
            return nil
        case .permanentDeletionNotCommitted:
            return "Save the pending deletion to the library, then retry."
        case .unsupportedSchema, .corruptLibrary:
            break
        }
        #if os(iOS)
        return "The original library has been preserved. Export any songs you can still access before restoring the app from a backup."
        #else
        return "Reveal the library in Finder and preserve or repair it before trying again."
        #endif
    }
}

actor JSONLibraryStore: LibraryStoring {
    static let bundleIdentifier = "app.singerslyrics.SingersLyrics"

    let fileURL: URL
    private let fileManager: FileManager
    private var knownStoredAssets: [String: Data] = [:]
    private var committedPendingRecordings: [UUID: RecordingIdentity] = [:]
    private var committedActiveRecordingIDs: Set<UUID> = []

    private struct RecordingIdentity: Equatable {
        var songID: UUID
        var lineID: UUID
    }

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultLibraryURL(fileManager: fileManager)
    }

    static func defaultLibraryURL(fileManager: FileManager = .default) -> URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport
            .appending(path: bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "library-v1.json", directoryHint: .notDirectory)
    }

    func load() async throws -> LibraryDocument {
        knownStoredAssets.removeAll()
        guard fileManager.fileExists(atPath: fileURL.path) else {
            updateCommittedRecordings(from: LibraryDocument())
            return LibraryDocument()
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let value = try container.decode(String.self)
                guard let date = LibraryDateCodec.date(from: value) else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Expected an ISO-8601 date"
                    )
                }
                return date
            }
            var document = try decoder.decode(LibraryDocument.self, from: data)
            guard document.schemaVersion == LibraryDocument.currentSchemaVersion else {
                throw LibraryStoreError.unsupportedSchema(document.schemaVersion)
            }
            try RecordingAssetStorage.validate(document: document, requireAudio: false)
            let read: ([String]) throws -> Data = { components in
                let assetURL = try RecordingAssetStorage.assetURL(
                    components: components,
                    baseURL: self.fileURL.deletingLastPathComponent(),
                    fileManager: self.fileManager,
                    createDirectories: false
                )
                try RecordingAssetStorage.requireRegularFile(at: assetURL, fileManager: self.fileManager)
                return try Data(contentsOf: assetURL)
            }
            try RecordingAssetStorage.hydrate(songs: &document.songs, read: read)
            try RecordingAssetStorage.hydrate(trash: &document.trashedRecordings, read: read)
            try RecordingAssetStorage.hydrate(songTrash: &document.trashedSongs, read: read)
            knownStoredAssets = Dictionary(uniqueKeysWithValues:
                RecordingAssetStorage.assets(in: document).map {
                    ($0.components.joined(separator: "/"), $0.data)
                }
            )
            updateCommittedRecordings(from: document)
            return document
        } catch let error as LibraryStoreError {
            throw error
        } catch {
            throw LibraryStoreError.corruptLibrary(error.localizedDescription)
        }
    }

    func save(_ document: LibraryDocument) async throws {
        guard document.schemaVersion == LibraryDocument.currentSchemaVersion else {
            throw LibraryStoreError.unsupportedSchema(document.schemaVersion)
        }
        try RecordingAssetStorage.validate(document: document, requireAudio: true)
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(LibraryDateCodec.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)

        // Commit complete assets first. Existing assets are immutable: replacing bytes
        // at the same identifier could damage the previously committed library.
        let assets = RecordingAssetStorage.assets(in: document)
        for asset in assets {
            let key = asset.components.joined(separator: "/")
            let url = try RecordingAssetStorage.assetURL(
                components: asset.components,
                baseURL: directory,
                fileManager: fileManager,
                createDirectories: true
            )
            if knownStoredAssets[key] != asset.data
                || (try? RecordingAssetStorage.requireRegularFile(at: url, fileManager: fileManager)) == nil {
                try RecordingAssetStorage.writeImmutableAsset(
                    asset.data, to: url, fileManager: fileManager
                )
                knownStoredAssets[key] = asset.data
            }
        }
        try data.write(to: fileURL, options: [.atomic])
        updateCommittedRecordings(from: document)
        let referencedKeys = Set(assets.map { $0.components.joined(separator: "/") })
        knownStoredAssets = knownStoredAssets.filter { referencedKeys.contains($0.key) }

        // A failed metadata commit leaves the previous assets intact. Cleanup is
        // best effort after commit; a cleanup error must not report a failed save.
        RecordingAssetStorage.removeUnreferencedAssets(
            songs: document.songs,
            retainedTrash: document.trashedRecordings,
            retainedSongTrash: document.trashedSongs,
            baseURL: directory,
            fileManager: fileManager
        )
    }

    func recordingFileURL(songID: UUID, lineID: UUID, recordingID: UUID) async throws -> URL {
        let url = try RecordingAssetStorage.assetURL(
            components: RecordingAssetStorage.components(
                songID: songID, lineID: lineID, recordingID: recordingID
            ),
            baseURL: fileURL.deletingLastPathComponent(),
            fileManager: fileManager,
            createDirectories: false
        )
        try RecordingAssetStorage.requireRegularFile(at: url, fileManager: fileManager)
        return url
    }

    func permanentlyDeleteRecording(_ recording: TrashedRecording) async throws {
        let identity = RecordingIdentity(songID: recording.songID, lineID: recording.lineID)
        guard recording.isPendingPermanentDeletion,
              committedPendingRecordings[recording.id] == identity,
              !committedActiveRecordingIDs.contains(recording.id) else {
            throw LibraryStoreError.permanentDeletionNotCommitted
        }

        let components = RecordingAssetStorage.components(
            songID: recording.songID, lineID: recording.lineID, recordingID: recording.id
        )
        do {
            let url = try RecordingAssetStorage.assetURL(
                components: components,
                baseURL: fileURL.deletingLastPathComponent(),
                fileManager: fileManager,
                createDirectories: false
            )
            try RecordingAssetStorage.requireRegularFile(at: url, fileManager: fileManager)
            try fileManager.removeItem(at: url)
        } catch {
            // The pending metadata survives a crash after unlink. Retrying must
            // succeed for an absent file while retaining unrelated I/O errors.
            guard RecordingAssetStorage.isMissingFileError(error) else { throw error }
        }
        knownStoredAssets.removeValue(forKey: components.joined(separator: "/"))
    }

    private func updateCommittedRecordings(from document: LibraryDocument) {
        var pending: [(UUID, RecordingIdentity)] = document.trashedRecordings
            .filter(\.isPendingPermanentDeletion).map {
                ($0.id, RecordingIdentity(songID: $0.songID, lineID: $0.lineID))
            }
        for trashed in document.trashedSongs where trashed.isPendingPermanentDeletion {
            for line in trashed.song.lines {
                pending += line.recordings.map {
                    ($0.id, RecordingIdentity(songID: trashed.id, lineID: line.id))
                }
            }
        }
        committedPendingRecordings = Dictionary(uniqueKeysWithValues: pending)
        let protectedSongs = document.songs
            + document.trashedSongs.filter { !$0.isPendingPermanentDeletion }.map(\.song)
        committedActiveRecordingIDs = Set(protectedSongs.flatMap { song in
            song.lines.flatMap { $0.recordings.map(\.id) }
        }).union(document.trashedRecordings.filter { !$0.isPendingPermanentDeletion }.map(\.id))
    }
}

enum RecordingAssetError: LocalizedError {
    case duplicateSongIDs
    case duplicateLineIDs
    case duplicateRecordingIDs
    case invalidRecording
    case invalidSelection
    case invalidAsset
    case conflictingAsset

    var errorDescription: String? {
        switch self {
        case .duplicateSongIDs, .duplicateLineIDs, .duplicateRecordingIDs:
            "The song library contains duplicate identifiers and could not be saved safely."
        case .invalidRecording:
            "A voice recording has invalid metadata or missing audio."
        case .invalidSelection:
            "A lyric line selects a recording that does not belong to it."
        case .invalidAsset:
            "A required voice recording file is missing or has an unsafe file structure."
        case .conflictingAsset:
            "A different audio file already exists for this recording. The existing file has been preserved."
        }
    }
}

/// Shared UUID-only asset layout for the local library and portable packages.
enum RecordingAssetStorage {
    struct Asset {
        var components: [String]
        var data: Data
    }

    static func components(songID: UUID, lineID: UUID, recordingID: UUID) -> [String] {
        ["recordings", songID.uuidString, lineID.uuidString, recordingID.uuidString + ".m4a"]
    }

    static func validate(document: LibraryDocument, requireAudio: Bool) throws {
        let allSongs = document.songs + document.trashedSongs.map(\.song)
        // Pending song entries retain their metadata, but their audio may already
        // have been unlinked by an interrupted permanent deletion.
        try validate(songs: allSongs, requireAudio: false)
        if requireAudio {
            try validate(
                songs: document.songs
                    + document.trashedSongs.filter { !$0.isPendingPermanentDeletion }.map(\.song),
                requireAudio: true
            )
        }
        for trashed in document.trashedSongs {
            guard trashed.deletedAt.timeIntervalSince1970.isFinite, trashed.originalIndex >= 0 else {
                throw RecordingAssetError.invalidRecording
            }
        }
        var recordingIDs = Set(allSongs.flatMap { song in
            song.lines.flatMap { $0.recordings.map(\.id) }
        })
        for trashed in document.trashedRecordings {
            guard recordingIDs.insert(trashed.id).inserted else {
                throw RecordingAssetError.duplicateRecordingIDs
            }
            guard trashed.deletedAt.timeIntervalSince1970.isFinite else {
                throw RecordingAssetError.invalidRecording
            }
            try validate(
                recording: trashed.recording,
                requireAudio: requireAudio && !trashed.isPendingPermanentDeletion
            )
        }
    }

    static func validate(songs: [Song], requireAudio: Bool) throws {
        var songIDs: Set<UUID> = []
        var lineIDs: Set<UUID> = []
        var recordingIDs: Set<UUID> = []
        for song in songs {
            guard songIDs.insert(song.id).inserted else {
                throw RecordingAssetError.duplicateSongIDs
            }
            for line in song.lines {
                guard lineIDs.insert(line.id).inserted else {
                    throw RecordingAssetError.duplicateLineIDs
                }
                if let selectedID = line.selectedRecordingID,
                   !line.recordings.contains(where: { $0.id == selectedID }) {
                    throw RecordingAssetError.invalidSelection
                }
                for recording in line.recordings {
                    guard recordingIDs.insert(recording.id).inserted else {
                        throw RecordingAssetError.duplicateRecordingIDs
                    }
                    try validate(recording: recording, requireAudio: requireAudio)
                }
            }
        }
    }

    private static func validate(recording: VoiceRecording, requireAudio: Bool) throws {
        guard !recording.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              recording.duration.isFinite, recording.duration > 0,
              recording.createdAt.timeIntervalSince1970.isFinite,
              !requireAudio || !recording.audioData.isEmpty else {
            throw RecordingAssetError.invalidRecording
        }
    }

    static func assets(in document: LibraryDocument) -> [Asset] {
        let retainedSongs = document.songs
            + document.trashedSongs.filter { !$0.isPendingPermanentDeletion }.map(\.song)
        return assets(in: retainedSongs) + document.trashedRecordings
            .filter { !$0.isPendingPermanentDeletion }
            .map { trashed in
                Asset(
                    components: components(
                        songID: trashed.songID, lineID: trashed.lineID, recordingID: trashed.id
                    ),
                    data: trashed.recording.audioData
                )
            }
    }

    static func assets(in songs: [Song]) -> [Asset] {
        songs.flatMap { song in
            song.lines.flatMap { line in
                line.recordings.map { recording in
                    Asset(
                        components: components(
                            songID: song.id, lineID: line.id, recordingID: recording.id
                        ),
                        data: recording.audioData
                    )
                }
            }
        }
    }

    static func hydrate(
        trash: inout [TrashedRecording],
        read: ([String]) throws -> Data
    ) throws {
        for index in trash.indices {
            if trash[index].isPendingPermanentDeletion {
                trash[index].recording.audioData = Data()
                continue
            }
            let data = try read(components(
                songID: trash[index].songID, lineID: trash[index].lineID, recordingID: trash[index].id
            ))
            guard !data.isEmpty else { throw RecordingAssetError.invalidAsset }
            trash[index].recording.audioData = data
        }
    }

    static func hydrate(
        songTrash: inout [TrashedSong],
        read: ([String]) throws -> Data
    ) throws {
        for index in songTrash.indices {
            if songTrash[index].isPendingPermanentDeletion {
                for lineIndex in songTrash[index].song.lines.indices {
                    for recordingIndex in songTrash[index].song.lines[lineIndex].recordings.indices {
                        songTrash[index].song.lines[lineIndex].recordings[recordingIndex].audioData = Data()
                    }
                }
            } else {
                try hydrate(song: &songTrash[index].song, read: read)
            }
        }
    }

    static func hydrate(
        songs: inout [Song],
        read: ([String]) throws -> Data
    ) throws {
        for songIndex in songs.indices {
            try hydrate(song: &songs[songIndex], read: read)
        }
    }

    private static func hydrate(song: inout Song, read: ([String]) throws -> Data) throws {
        for lineIndex in song.lines.indices {
            for recordingIndex in song.lines[lineIndex].recordings.indices {
                let recordingID = song.lines[lineIndex].recordings[recordingIndex].id
                let data = try read(components(
                    songID: song.id, lineID: song.lines[lineIndex].id, recordingID: recordingID
                ))
                guard !data.isEmpty else { throw RecordingAssetError.invalidAsset }
                song.lines[lineIndex].recordings[recordingIndex].audioData = data
            }
        }
    }

    static func assetURL(
        components: [String],
        baseURL: URL,
        fileManager: FileManager,
        createDirectories: Bool
    ) throws -> URL {
        var directory = baseURL
        try requireDirectory(at: directory, fileManager: fileManager, create: createDirectories)
        for component in components.dropLast() {
            directory.append(path: component, directoryHint: .isDirectory)
            try requireDirectory(at: directory, fileManager: fileManager, create: createDirectories)
        }
        guard let filename = components.last else { throw RecordingAssetError.invalidAsset }
        return directory.appending(path: filename, directoryHint: .notDirectory)
    }

    static func requireDirectory(at url: URL, fileManager: FileManager, create: Bool) throws {
        if let attributes = try attributesIfPresent(at: url, fileManager: fileManager) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw RecordingAssetError.invalidAsset
            }
        } else if create {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
            try requireDirectory(at: url, fileManager: fileManager, create: false)
        } else {
            throw CocoaError(.fileReadNoSuchFile)
        }
    }

    static func requireRegularFile(at url: URL, fileManager: FileManager) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw RecordingAssetError.invalidAsset
        }
    }

    static func writeImmutableAsset(_ data: Data, to url: URL, fileManager: FileManager) throws {
        if try attributesIfPresent(at: url, fileManager: fileManager) != nil {
            try requireRegularFile(at: url, fileManager: fileManager)
            guard try Data(contentsOf: url) == data else {
                throw RecordingAssetError.conflictingAsset
            }
            return
        }

        let temporaryURL = url.deletingLastPathComponent()
            .appending(path: ".recording-" + UUID().uuidString + ".tmp", directoryHint: .notDirectory)
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: [.atomic])
        do {
            // A hard link publishes the finished file without overwriting a racing writer.
            try fileManager.linkItem(at: temporaryURL, to: url)
        } catch {
            guard try attributesIfPresent(at: url, fileManager: fileManager) != nil else {
                throw error
            }
            try requireRegularFile(at: url, fileManager: fileManager)
            guard try Data(contentsOf: url) == data else {
                throw RecordingAssetError.conflictingAsset
            }
        }
    }

    static func removeUnreferencedAssets(
        songs: [Song],
        retainedTrash: [TrashedRecording] = [],
        retainedSongTrash: [TrashedSong] = [],
        baseURL: URL,
        fileManager: FileManager
    ) {
        var referenced = Set(assets(in: songs + retainedSongTrash.map(\.song)).map {
            $0.components.joined(separator: "/")
        })
        for trashed in retainedTrash {
            referenced.insert(components(
                songID: trashed.songID, lineID: trashed.lineID, recordingID: trashed.id
            ).joined(separator: "/"))
        }
        let root = baseURL.appending(path: "recordings", directoryHint: .isDirectory)
        guard (try? requireDirectory(at: root, fileManager: fileManager, create: false)) != nil,
              let songDirectories = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil
              ) else { return }

        // Only touch the managed UUID hierarchy, and never follow a symbolic link.
        for songDirectory in songDirectories where UUID(uuidString: songDirectory.lastPathComponent) != nil {
            guard (try? requireDirectory(at: songDirectory, fileManager: fileManager, create: false)) != nil,
                  let lineDirectories = try? fileManager.contentsOfDirectory(
                    at: songDirectory, includingPropertiesForKeys: nil
                  ) else { continue }
            for lineDirectory in lineDirectories where UUID(uuidString: lineDirectory.lastPathComponent) != nil {
                guard (try? requireDirectory(at: lineDirectory, fileManager: fileManager, create: false)) != nil,
                      let files = try? fileManager.contentsOfDirectory(
                        at: lineDirectory, includingPropertiesForKeys: nil
                      ) else { continue }
                for file in files where file.pathExtension == "m4a" {
                    guard UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
                          (try? requireRegularFile(at: file, fileManager: fileManager)) != nil else { continue }
                    let relative = ["recordings", songDirectory.lastPathComponent,
                                    lineDirectory.lastPathComponent, file.lastPathComponent]
                        .joined(separator: "/")
                    if !referenced.contains(relative) { try? fileManager.removeItem(at: file) }
                }
                removeDirectoryIfEmpty(lineDirectory, fileManager: fileManager)
            }
            removeDirectoryIfEmpty(songDirectory, fileManager: fileManager)
        }
        removeDirectoryIfEmpty(root, fileManager: fileManager)
    }

    private static func removeDirectoryIfEmpty(_ url: URL, fileManager: FileManager) {
        if let contents = try? fileManager.contentsOfDirectory(atPath: url.path), contents.isEmpty {
            try? fileManager.removeItem(at: url)
        }
    }

    static func isMissingFileError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain
            && (error.code == CocoaError.fileReadNoSuchFile.rawValue
                || error.code == CocoaError.fileNoSuchFile.rawValue)
    }

    private static func attributesIfPresent(
        at url: URL, fileManager: FileManager
    ) throws -> [FileAttributeKey: Any]? {
        do {
            return try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            guard isMissingFileError(error) else { throw error }
            return nil
        }
    }
}

enum LibraryDateCodec {
    static func string(from date: Date) -> String {
        var wholeSeconds = floor(date.timeIntervalSince1970)
        var nanoseconds = Int(
            ((date.timeIntervalSince1970 - wholeSeconds) * 1_000_000_000).rounded()
        )
        if nanoseconds == 1_000_000_000 {
            wholeSeconds += 1
            nanoseconds = 0
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let base = formatter.string(from: Date(timeIntervalSince1970: wholeSeconds))
        return "\(base.dropLast()).\(String(format: "%09d", nanoseconds))Z"
    }

    static func date(from value: String) -> Date? {
        if value.hasSuffix("Z"),
           let separator = value.lastIndex(of: "."),
           separator < value.index(before: value.endIndex) {
            let fractionStart = value.index(after: separator)
            let fractionEnd = value.index(before: value.endIndex)
            let fraction = String(value[fractionStart..<fractionEnd])
            if !fraction.isEmpty, fraction.allSatisfy(\.isNumber) {
                let wholeValue = String(value[..<separator]) + "Z"
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                if let wholeDate = formatter.date(from: wholeValue),
                   let fractionalSeconds = Double("0.\(fraction)") {
                    return wholeDate.addingTimeInterval(fractionalSeconds)
                }
            }
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}

actor InMemoryLibraryStore: LibraryStoring {
    private var document: LibraryDocument

    init(document: LibraryDocument = LibraryDocument()) {
        self.document = document
    }

    func load() async throws -> LibraryDocument {
        document
    }

    func save(_ document: LibraryDocument) async throws {
        self.document = document
    }

    func permanentlyDeleteRecording(_ recording: TrashedRecording) async throws {
        let individuallyPending = document.trashedRecordings.contains {
            $0.id == recording.id && $0.songID == recording.songID
                && $0.lineID == recording.lineID && $0.isPendingPermanentDeletion
        }
        let pendingInSong = document.trashedSongs.contains { trashed in
            trashed.id == recording.songID && trashed.isPendingPermanentDeletion
                && trashed.song.lines.contains { line in
                    line.id == recording.lineID && line.recordings.contains { $0.id == recording.id }
                }
        }
        let protectedSongs = document.songs
            + document.trashedSongs.filter { !$0.isPendingPermanentDeletion }.map(\.song)
        guard recording.isPendingPermanentDeletion,
              individuallyPending || pendingInSong,
              !document.trashedRecordings.contains(where: {
                  $0.id == recording.id && !$0.isPendingPermanentDeletion
              }),
              !protectedSongs.contains(where: { song in
                  song.lines.contains { line in
                      line.recordings.contains { $0.id == recording.id }
                  }
              }) else {
            throw LibraryStoreError.permanentDeletionNotCommitted
        }
    }
}
