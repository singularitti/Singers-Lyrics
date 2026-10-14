import CloudKit
import CryptoKit
import Foundation

struct CloudLibrarySnapshot: Sendable {
    var document: LibraryDocument
    var revision: String?
    // The manifest has committed even when garbage collection needs another attempt.
    var cleanupPending = false
    // Folder snapshots can arrive concurrently. A new snapshot records the
    // combined ancestry even when the resulting metadata is already identical.
    var requiresConsolidation = false
}

enum CloudLibrarySyncError: LocalizedError, Equatable, Sendable {
    case conflict
    case accountUnavailable
    case accountChanged
    case networkUnavailable
    case serviceUnavailable
    case configurationUnavailable
    case quotaExceeded
    case invalidCloudData
    case missingAudio
    case immutableAudioConflict

    var errorDescription: String? {
        switch self {
        case .conflict:
            "The cloud library changed. Fetch its latest version before saving again."
        case .accountUnavailable:
            "An available iCloud account is required to sync the library."
        case .accountChanged:
            "The iCloud account changed. Sync stopped to preserve this library."
        case .networkUnavailable:
            "Cloud sync could not connect. Your local library is preserved."
        case .serviceUnavailable:
            "Cloud sync is temporarily unavailable. Your local library is preserved."
        case .configurationUnavailable:
            "Cloud sync is not configured for this app build or cloud environment."
        case .quotaExceeded:
            "There is not enough iCloud storage to sync the library."
        case .invalidCloudData:
            "The cloud library could not be read safely. Your local library is preserved."
        case .missingAudio:
            "A required cloud recording is missing or incomplete. Your local library is preserved."
        case .immutableAudioConflict:
            "Different audio already exists for this recording. The existing audio is preserved."
        }
    }
}

/// A private-database snapshot transport. Scheduling and conflict merging belong to
/// the coordinator. Constructing this actor does not initialize CloudKit.
actor CloudKitLibraryTransport {
    static let containerIdentifier = "iCloud.app.singerslyrics.SingersLyrics"

    private static let zoneName = "SingersLyricsLibrary"
    private static let manifestType = "SLLibraryManifest"
    private static let audioType = "SLRecordingAudio"
    private static let formatVersion = 1
    private static let batchSize = 100

    private var container: CKContainer?
    private var expectedAccountIdentifier: String?
    private let accountChanges = CloudAccountChangeMonitor()

    init(expectedAccountIdentifier: String? = nil) {
        self.expectedAccountIdentifier = expectedAccountIdentifier
    }

    /// Returns an opaque binding for local persistence. Never display this value.
    /// A transport latches its first account and refuses to follow an account switch.
    func accountIdentifier() async throws -> String {
        do {
            return try await verifiedAccount(generation: accountChanges.generation)
        } catch {
            throw Self.safeError(error)
        }
    }

    func fetch(reusing local: LibraryDocument) async throws -> CloudLibrarySnapshot {
        let generation = accountChanges.generation
        do {
            try await checkAccount(generation)
            let database = cloudContainer().privateCloudDatabase
            let manifest: CKRecord
            do {
                manifest = try await database.record(for: manifestID)
            } catch {
                try await checkAccount(generation)
                if Self.isMissingRecord(error) || Self.hasCode(error, .zoneNotFound) {
                    return CloudLibrarySnapshot(document: LibraryDocument(), revision: nil)
                }
                throw error
            }
            try await checkAccount(generation)
            try Self.validate(record: manifest, type: Self.manifestType)
            guard let revision = manifest.recordChangeTag else {
                throw CloudLibrarySyncError.invalidCloudData
            }
            var document = try LibrarySyncMerge.decodeMetadata(Self.readAsset(manifest["metadata"]))
            let digests = try JSONDecoder().decode(
                [String: String].self, from: Self.readAsset(manifest["audioDigests"])
            )
            let required = try Self.audioAssets(in: document)
            guard Set(required.keys) == Set(digests.keys),
                  digests.values.allSatisfy(Self.isDigest) else {
                throw CloudLibrarySyncError.invalidCloudData
            }

            // Matching IDs alone do not prove that bytes belong to this snapshot.
            // The digest index allows safe reuse without downloading CKAssets.
            let localAssets = try Self.audioAssets(in: local)
            var audio: [String: Data] = [:]
            for id in required.keys {
                if let bytes = localAssets[id], !bytes.isEmpty,
                   Self.digest(bytes) == digests[id] {
                    audio[id] = bytes
                }
            }
            let missing = required.keys.filter { audio[$0] == nil }.sorted()
            for batch in Self.batches(missing) {
                try await checkAccount(generation)
                let results = try await database.records(for: batch.map(audioID))
                try await checkAccount(generation)
                for id in batch {
                    guard let result = results[audioID(id)] else {
                        throw CloudLibrarySyncError.missingAudio
                    }
                    let record: CKRecord
                    do { record = try result.get() } catch {
                        if Self.isMissingRecord(error) { throw CloudLibrarySyncError.missingAudio }
                        throw error
                    }
                    try Self.validate(record: record, type: Self.audioType)
                    let bytes = try Self.readAsset(record["audio"])
                    guard !bytes.isEmpty, record["digest"] as? String == digests[id],
                          Self.digest(bytes) == digests[id] else {
                        throw CloudLibrarySyncError.missingAudio
                    }
                    audio[id] = bytes
                }
            }
            let read: ([String]) throws -> Data = { components in
                let id = try Self.recordingID(from: components)
                guard let bytes = audio[id] else { throw CloudLibrarySyncError.missingAudio }
                return bytes
            }
            try RecordingAssetStorage.hydrate(songs: &document.songs, read: read)
            try RecordingAssetStorage.hydrate(trash: &document.trashedRecordings, read: read)
            try RecordingAssetStorage.hydrate(songTrash: &document.trashedSongs, read: read)
            try RecordingAssetStorage.validate(document: document, requireAudio: true)
            try await checkAccount(generation)
            let cleanupPending = try await cleanupAudio(in: document, generation: generation)
            return CloudLibrarySnapshot(
                document: document, revision: revision, cleanupPending: cleanupPending
            )
        } catch {
            try accountChanges.requireGeneration(generation)
            throw Self.safeError(error)
        }
    }

    func save(
        _ document: LibraryDocument, replacing revision: String?
    ) async throws -> CloudLibrarySnapshot {
        let generation = accountChanges.generation
        do {
            try RecordingAssetStorage.validate(document: document, requireAudio: true)
            let metadata = try LibrarySyncMerge.metadataData(document)
            _ = try LibrarySyncMerge.decodeMetadata(metadata)
            let audio = try Self.audioAssets(in: document)
            guard audio.keys.allSatisfy({ key in
                guard let id = UUID(uuidString: key) else { return false }
                return !document.permanentlyDeletedRecordingIDs.contains(id)
            }) else { throw CloudLibrarySyncError.invalidCloudData }
            let digests = audio.mapValues(Self.digest)
            try await checkAccount(generation)
            let database = cloudContainer().privateCloudDatabase

            // Check the caller's base before uploading. Keep the fetched record's
            // system fields intact so the actual commit also compares change tags.
            let manifest = try await manifestForSave(revision: revision, generation: generation)
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appending(path: "library-cloud-" + UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: temporaryDirectory, withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

            for batch in Self.batches(audio.keys.sorted()) {
                try await checkAccount(generation)
                let results = try await database.records(
                    for: batch.map(audioID), desiredKeys: ["formatVersion", "digest"]
                )
                try await checkAccount(generation)
                var uploads: [CKRecord] = []
                for id in batch {
                    guard let result = results[audioID(id)], let bytes = audio[id],
                          let digest = digests[id] else {
                        throw CloudLibrarySyncError.invalidCloudData
                    }
                    switch result {
                    case .success(let existing):
                        try Self.validate(record: existing, type: Self.audioType)
                        guard existing["digest"] as? String == digest else {
                            throw CloudLibrarySyncError.immutableAudioConflict
                        }
                    case .failure(let error):
                        guard Self.isMissingRecord(error) else { throw error }
                        let record = CKRecord(recordType: Self.audioType, recordID: audioID(id))
                        record["formatVersion"] = NSNumber(value: Self.formatVersion)
                        record["digest"] = digest as NSString
                        record["audio"] = try Self.temporaryAsset(
                            bytes, name: id + ".m4a", directory: temporaryDirectory
                        )
                        uploads.append(record)
                    }
                }
                if !uploads.isEmpty {
                    let results = try await modify(
                        saving: uploads, deleting: [], atomically: false, generation: generation
                    )
                    for record in uploads {
                        guard let result = results.saved[record.recordID] else {
                            throw CloudLibrarySyncError.serviceUnavailable
                        }
                        do { _ = try result.get() } catch {
                            // A racing device can publish the same immutable audio.
                            // Its digest must match; never overwrite its record.
                            guard Self.hasCode(error, .serverRecordChanged) else { throw error }
                            try await checkAccount(generation)
                            let existing = try await database.records(
                                for: [record.recordID], desiredKeys: ["formatVersion", "digest"]
                            )
                            try await checkAccount(generation)
                            guard let remote = try existing[record.recordID]?.get() else {
                                throw CloudLibrarySyncError.immutableAudioConflict
                            }
                            try Self.validate(record: remote, type: Self.audioType)
                            guard remote["digest"] as? String == record["digest"] as? String else {
                                throw CloudLibrarySyncError.immutableAudioConflict
                            }
                        }
                    }
                }
            }

            // Audio is now complete. Only this CAS commit publishes the snapshot.
            manifest["formatVersion"] = NSNumber(value: Self.formatVersion)
            manifest["metadata"] = try Self.temporaryAsset(
                metadata, name: "metadata.json", directory: temporaryDirectory
            )
            let digestEncoder = JSONEncoder()
            digestEncoder.outputFormatting = [.sortedKeys]
            manifest["audioDigests"] = try Self.temporaryAsset(
                digestEncoder.encode(digests), name: "audio-digests.json", directory: temporaryDirectory
            )
            let committed = try await modify(
                saving: [manifest], deleting: [], atomically: true, generation: generation
            )
            guard let result = committed.saved[manifest.recordID] else {
                throw CloudLibrarySyncError.serviceUnavailable
            }
            let saved = try result.get()
            guard let savedRevision = saved.recordChangeTag else {
                throw CloudLibrarySyncError.invalidCloudData
            }

            // Tombstones are permanent. Cleanup never deletes a live referenced
            // asset, and a cleanup failure must not disguise a successful commit.
            let cleanupPending = try await cleanupAudio(in: document, generation: generation)
            try await checkAccount(generation)
            return CloudLibrarySnapshot(
                document: document, revision: savedRevision, cleanupPending: cleanupPending
            )
        } catch {
            try accountChanges.requireGeneration(generation)
            throw Self.safeError(error)
        }
    }

    private func cleanupAudio(in document: LibraryDocument, generation: UInt64) async throws -> Bool {
        var cleanupPending = false
        let referencedIDs = Set(try Self.audioAssets(in: document).keys)
        let deletedIDs = document.permanentlyDeletedRecordingIDs.map(\.uuidString).sorted()
        guard referencedIDs.isDisjoint(with: deletedIDs) else {
            throw CloudLibrarySyncError.invalidCloudData
        }
        for batch in Self.batches(deletedIDs) {
            do {
                let deleted = try await modify(
                    saving: [], deleting: batch.map(audioID), atomically: false, generation: generation
                )
                for id in batch {
                    guard let result = deleted.deleted[audioID(id)] else {
                        cleanupPending = true
                        continue
                    }
                    if case .failure(let error) = result, !Self.isMissingRecord(error) {
                        cleanupPending = true
                    }
                }
            } catch {
                try accountChanges.requireGeneration(generation)
                if error as? CloudLibrarySyncError == .accountChanged { throw error }
                if error is CancellationError { throw error }
                cleanupPending = true
                break
            }
        }
        return cleanupPending
    }

    private var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    private var manifestID: CKRecord.ID {
        CKRecord.ID(recordName: "root", zoneID: zoneID)
    }

    private func audioID(_ id: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "audio-" + id, zoneID: zoneID)
    }

    private func cloudContainer() -> CKContainer {
        if let container { return container }
        accountChanges.startObserving()
        let created = CKContainer(identifier: Self.containerIdentifier)
        container = created
        return created
    }

    private func verifiedAccount(generation: UInt64) async throws -> String {
        try accountChanges.requireGeneration(generation)
        try Task.checkCancellation()
        let container = cloudContainer()
        guard try await container.accountStatus() == .available else {
            throw CloudLibrarySyncError.accountUnavailable
        }
        let recordID = try await container.userRecordID()
        try accountChanges.requireGeneration(generation)
        let identifier = Self.digest(Data((Self.containerIdentifier + "|" + recordID.recordName).utf8))
        if let expectedAccountIdentifier, expectedAccountIdentifier != identifier {
            throw CloudLibrarySyncError.accountChanged
        }
        expectedAccountIdentifier = identifier
        return identifier
    }

    private func checkAccount(_ generation: UInt64) async throws {
        _ = try await verifiedAccount(generation: generation)
    }

    private func manifestForSave(revision: String?, generation: UInt64) async throws -> CKRecord {
        try await checkAccount(generation)
        let database = cloudContainer().privateCloudDatabase
        do {
            let results = try await database.records(
                for: [manifestID], desiredKeys: ["formatVersion"]
            )
            try await checkAccount(generation)
            guard let result = results[manifestID] else {
                throw CloudLibrarySyncError.serviceUnavailable
            }
            let record = try result.get()
            try Self.validate(record: record, type: Self.manifestType)
            guard let revision, record.recordChangeTag == revision else {
                throw CloudLibrarySyncError.conflict
            }
            return record
        } catch {
            guard Self.isMissingRecord(error) || Self.hasCode(error, .zoneNotFound) else { throw error }
            guard revision == nil else { throw CloudLibrarySyncError.conflict }
            if Self.hasCode(error, .zoneNotFound) {
                try await checkAccount(generation)
                _ = try await database.save(CKRecordZone(zoneID: zoneID))
                try await checkAccount(generation)
            }
            return CKRecord(recordType: Self.manifestType, recordID: manifestID)
        }
    }

    private func modify(
        saving records: [CKRecord], deleting ids: [CKRecord.ID], atomically: Bool,
        generation: UInt64
    ) async throws -> CloudRecordModificationResults {
        try await checkAccount(generation)
        let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: ids)
        operation.savePolicy = .ifServerRecordUnchanged
        operation.isAtomic = atomically
        let results = CloudRecordModificationCollector()
        operation.perRecordSaveBlock = { id, result in results.saved(id, result) }
        operation.perRecordDeleteBlock = { id, result in results.deleted(id, result) }
        let monitor = accountChanges
        let database = cloudContainer().privateCloudDatabase
        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<CloudRecordModificationResults, Error>) in
                operation.modifyRecordsResultBlock = { result in
                    monitor.finished(operation)
                    operation.modifyRecordsResultBlock = nil
                    switch result {
                    case .success:
                        continuation.resume(returning: results.snapshot())
                    case .failure(let error):
                        // Nonatomic batches report individual failures as partial
                        // failure. Preserve all per-record results for the caller.
                        if Self.hasCode(error, .partialFailure) {
                            continuation.resume(returning: results.snapshot())
                        } else {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                do { try monitor.submit(operation, database: database, generation: generation) }
                catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            operation.cancel()
        }
        try await checkAccount(generation)
        return value
    }

    private static func audioAssets(in document: LibraryDocument) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for asset in RecordingAssetStorage.assets(in: document) {
            let id = try recordingID(from: asset.components)
            guard result.updateValue(asset.data, forKey: id) == nil else {
                throw CloudLibrarySyncError.invalidCloudData
            }
        }
        return result
    }

    private static func recordingID(from components: [String]) throws -> String {
        guard let last = components.last,
              let id = UUID(uuidString: String(last.dropLast(4))), last.hasSuffix(".m4a") else {
            throw CloudLibrarySyncError.invalidCloudData
        }
        return id.uuidString
    }

    private static func validate(record: CKRecord, type: String) throws {
        guard record.recordType == type,
              (record["formatVersion"] as? NSNumber)?.intValue == formatVersion else {
            throw CloudLibrarySyncError.invalidCloudData
        }
    }

    private static func readAsset(_ value: (any CKRecordValueProtocol)?) throws -> Data {
        guard let asset = value as? CKAsset, let url = asset.fileURL else {
            throw CloudLibrarySyncError.missingAudio
        }
        try RecordingAssetStorage.requireRegularFile(at: url, fileManager: .default)
        return try Data(contentsOf: url)
    }

    private static func temporaryAsset(_ data: Data, name: String, directory: URL) throws -> CKAsset {
        let url = directory.appending(path: name, directoryHint: .notDirectory)
        try data.write(to: url, options: [.atomic])
        return CKAsset(fileURL: url)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func batches<T>(_ elements: [T]) -> [[T]] {
        stride(from: 0, to: elements.count, by: batchSize).map {
            Array(elements[$0..<min($0 + batchSize, elements.count)])
        }
    }

    private static func isMissingRecord(_ error: Error) -> Bool {
        hasCode(error, .unknownItem)
    }

    private static func hasCode(_ error: Error, _ code: CKError.Code) -> Bool {
        (error as? CKError)?.code == code
    }

    private static func safeError(_ error: Error) -> Error {
        if let safe = error as? CloudLibrarySyncError { return safe }
        if error is CancellationError { return CancellationError() }
        if error is LibraryStoreError || error is RecordingAssetError || error is LibrarySyncMerge.MergeError
            || error is DecodingError || error is EncodingError {
            return CloudLibrarySyncError.invalidCloudData
        }
        guard let cloud = error as? CKError else { return CloudLibrarySyncError.serviceUnavailable }
        switch cloud.code {
        case .operationCancelled:
            return CancellationError()
        case .serverRecordChanged:
            return CloudLibrarySyncError.conflict
        case .notAuthenticated, .managedAccountRestricted:
            return CloudLibrarySyncError.accountUnavailable
        case .networkFailure, .networkUnavailable:
            return CloudLibrarySyncError.networkUnavailable
        case .quotaExceeded:
            return CloudLibrarySyncError.quotaExceeded
        case .badContainer, .badDatabase, .missingEntitlement, .permissionFailure, .serverRejectedRequest:
            return CloudLibrarySyncError.configurationUnavailable
        case .unknownItem:
            return CloudLibrarySyncError.missingAudio
        default:
            // Do not expose CloudKit's userInfo, record IDs, or account details.
            return CloudLibrarySyncError.serviceUnavailable
        }
    }
}

private struct CloudRecordModificationResults: Sendable {
    var saved: [CKRecord.ID: Result<CKRecord, Error>]
    var deleted: [CKRecord.ID: Result<Void, Error>]
}

/// CloudKit callbacks may run concurrently. The lock guards only callback state.
private final class CloudRecordModificationCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var value = CloudRecordModificationResults(saved: [:], deleted: [:])

    func saved(_ id: CKRecord.ID, _ result: Result<CKRecord, Error>) {
        lock.withLock { value.saved[id] = result }
    }

    func deleted(_ id: CKRecord.ID, _ result: Result<Void, Error>) {
        lock.withLock { value.deleted[id] = result }
    }

    func snapshot() -> CloudRecordModificationResults { lock.withLock { value } }
}

/// Account notifications invalidate an operation even if the user switches away
/// and back. They also cancel pending uploads as soon as CloudKit reports a change.
private final class CloudAccountChangeMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var operations: [ObjectIdentifier: CKOperation] = [:]
    private var observer: NSObjectProtocol?

    var generation: UInt64 { lock.withLock { epoch } }

    func startObserving() {
        lock.withLock {
            guard observer == nil else { return }
            observer = NotificationCenter.default.addObserver(
                forName: .CKAccountChanged, object: nil, queue: nil
            ) { [weak self] _ in self?.accountChanged() }
        }
    }

    func requireGeneration(_ generation: UInt64) throws {
        try lock.withLock {
            guard epoch == generation else { throw CloudLibrarySyncError.accountChanged }
        }
    }

    func submit(_ operation: CKDatabaseOperation, database: CKDatabase, generation: UInt64) throws {
        try lock.withLock {
            guard epoch == generation else { throw CloudLibrarySyncError.accountChanged }
            operations[ObjectIdentifier(operation)] = operation
            database.add(operation)
        }
    }

    func finished(_ operation: CKOperation) {
        _ = lock.withLock { operations.removeValue(forKey: ObjectIdentifier(operation)) }
    }

    private func accountChanged() {
        let pending = lock.withLock {
            epoch &+= 1
            return Array(operations.values)
        }
        pending.forEach { $0.cancel() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
