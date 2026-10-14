import CryptoKit
import Darwin
import Foundation

/// Messages deliberately omit provider errors, paths, account names, and identifiers.
enum ICloudDriveSyncError: LocalizedError, Sendable {
    case folderNotSelected
    case bookmarkUnavailable
    case savedFolderMissing
    case folderUnavailable
    case folderChanged
    case localLibraryNotReady
    case downloadPending
    case invalidData
    case immutableAudioConflict

    var errorDescription: String? {
        switch self {
        case .folderNotSelected:
            "Choose an iCloud Drive folder to connect this library."
        case .bookmarkUnavailable:
            "The saved sync folder permission is unavailable. Choose the folder again. Your local library is preserved."
        case .savedFolderMissing:
            "The saved sync folder could not be found. If you moved it, choose it again. If you deleted it, connect a replacement folder. Your local library is preserved."
        case .folderUnavailable:
            "The sync folder could not be accessed. Choose the folder again and retry. Your local library is preserved."
        case .folderChanged:
            "The connected sync folder could not be verified. Use Change Sync Folder to reselect the original folder or connect a replacement. Your local library is preserved."
        case .localLibraryNotReady:
            "The local library is not ready to sync. Finish saving or resolve any library storage issue, then try connecting again."
        case .downloadPending:
            "The sync folder is missing files or is still downloading. Wait for iCloud Drive to finish, then retry. Your local library is preserved."
        case .invalidData:
            "The sync folder contains unsupported or incomplete library data. Your local library is preserved."
        case .immutableAudioConflict:
            "Different audio exists for the same recording in the sync history. Your local library is preserved."
        }
    }
}

/// A user-selected, security-scoped folder needs no CloudKit container entitlement.
/// Commits and content-addressed audio are immutable. Coordination protects local
/// file access; graph ancestry, rather than a shared overwritten manifest, handles
/// devices that publish concurrently while offline. Historical audio is retained
/// with its commits, including after permanent deletion from the current library.
actor ICloudDriveLibraryTransport: LibrarySyncTransport {
    static let storeDirectoryName = "Singers Lyrics Library"

    private let folderURL: URL
    private let expectedFolderIdentifier: String?
    private var knownRevision: String?
    private var binding: Binding?
    private var bindingTask: Task<Binding, Error>?

    init(folderURL: URL, expectedFolderIdentifier: String? = nil, expectedRevision: String? = nil) {
        self.folderURL = folderURL
        self.expectedFolderIdentifier = expectedFolderIdentifier
        knownRevision = expectedRevision
    }

    func accountIdentifier() async throws -> String {
        try await connection().identifier
    }

    func fetch(reusing local: LibraryDocument) async throws -> CloudLibrarySnapshot {
        let binding = try await connection()
        let required = try Self.heads(from: knownRevision)
        let snapshot = try await Self.perform(in: folderURL) { folder in
            let store = binding.store
            try await Self.verifyStore(store)
            let graph = try await Self.readGraph(store: store, connection: binding.id, required: required)
            var document = try Self.mergeHeads(graph.heads, graph: graph)
            try await Self.hydrate(&document, reusing: local, store: store)
            try await Self.verifyStore(store)
            try await Self.remember(graph.heads, connection: binding.id, store: store)
            try await Self.verifyStore(store)
            return CloudLibrarySnapshot(
                document: document, revision: Self.revision(graph.heads),
                requiresConsolidation: graph.heads.count > 1
            )
        }
        knownRevision = snapshot.revision
        return snapshot
    }

    func save(_ document: LibraryDocument, replacing revision: String?) async throws -> CloudLibrarySnapshot {
        let binding = try await connection()
        let required = try Self.heads(from: knownRevision).union(Self.heads(from: revision))
        let snapshot = try await Self.perform(in: folderURL) { folder in
            let store = binding.store
            try await Self.verifyStore(store)
            try RecordingAssetStorage.validate(document: document, requireAudio: true)
            let graph = try await Self.readGraph(store: store, connection: binding.id, required: required)
            guard Self.revision(graph.heads) == revision else { throw CloudLibrarySyncError.conflict }
            let metadata = try LibrarySyncMerge.metadataData(document)
            _ = try LibrarySyncMerge.decodeMetadata(metadata)
            let assets = try Self.audioReferences(document)
            // Recording IDs are immutable across the entire known history.
            for commit in graph.commits.values {
                for (recording, digest) in commit.audio {
                    if let proposed = assets[recording], proposed != digest {
                        throw ICloudDriveSyncError.immutableAudioConflict
                    }
                }
            }
            if graph.heads.count == 1, let head = graph.heads.first,
               let commit = graph.commits[head], commit.metadata == metadata, commit.audio == assets {
                try await Self.verifyStore(store)
                try await Self.remember(graph.heads, connection: binding.id, store: store)
                try await Self.verifyStore(store)
                return CloudLibrarySnapshot(document: document, revision: revision)
            }
            if graph.heads.isEmpty, try LibrarySyncMerge.metadataEqual(document, LibraryDocument()) {
                try await Self.verifyStore(store)
                return CloudLibrarySnapshot(document: document, revision: nil)
            }
            // Publish all audio before the commit that references it. A future
            // device may still receive the commit first and must wait for audio.
            var written = Set<String>()
            for asset in RecordingAssetStorage.assets(in: document) {
                try Task.checkCancellation()
                let digest = Self.digest(asset.data)
                if written.insert(digest).inserted {
                    let url = store.directory("audio")
                        .appending(path: digest + ".m4a", directoryHint: .notDirectory)
                    try await Self.publish(asset.data, to: url, store: store.root)
                }
            }
            // Recheck immediately before publication. Invisible remote commits
            // cannot be detected here; immutable siblings survive and merge later.
            let latest = try await Self.readGraph(
                store: store, connection: binding.id, required: required.union(graph.heads)
            )
            guard Self.revision(latest.heads) == revision else { throw CloudLibrarySyncError.conflict }
            let commit = Commit(
                version: 1, id: UUID(), parents: graph.heads, metadata: metadata,
                metadataDigest: Self.digest(metadata), audio: assets
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(commit)
            // The bound namespace never changes during this save. A concurrent
            // reset can at most receive obsolete writes in the old namespace.
            try await Self.verifyStore(store)
            try await Self.publish(bytes, to: Self.commitURL(commit.id, store: store), store: store.root)
            try await Self.remember([commit.id], connection: binding.id, store: store)
            try await Self.verifyStore(store)
            return CloudLibrarySnapshot(document: document, revision: Self.revision([commit.id]))
        }
        knownRevision = snapshot.revision
        return snapshot
    }

    private func connection() async throws -> Binding {
        try Task.checkCancellation()
        if let task = bindingTask { return try await task.value }
        let folder = folderURL
        let expected = binding?.identifier ?? expectedFolderIdentifier
        let task = Task.detached {
            try await Self.withFolderScope(folder) { folder in
                try await Self.openConnection(in: folder, expected: expected)
            }
        }
        bindingTask = task
        do {
            let opened = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            binding = opened
            bindingTask = nil
            return opened
        } catch {
            bindingTask = nil
            throw Self.safeError(error)
        }
    }

    private struct Marker: Codable { var version: Int; var id: UUID }
    private struct Descriptor: Codable { var version: Int; var generation: UUID }
    private struct Store: Sendable {
        var root: URL
        var generation: UUID?

        func directory(_ name: String) -> URL {
            let directory = root.appending(path: name, directoryHint: .isDirectory)
            return generation.map { directory.appending(path: $0.uuidString, directoryHint: .isDirectory) } ?? directory
        }
    }
    private struct Binding: Sendable {
        var store: Store
        var id: UUID

        var identifier: String {
            if let generation = store.generation {
                return "drive-v2:" + generation.uuidString + ":" + id.uuidString
            }
            return "drive:" + id.uuidString
        }
    }
    private struct Receipt: Codable { var version: Int; var commit: UUID }
    private struct Commit: Codable {
        var version: Int
        var id: UUID
        var parents: [UUID]
        var metadata: Data
        var metadataDigest: String
        // Keys are canonical recording UUIDs; values are lowercase SHA-256 hex.
        var audio: [String: String]
    }
    private struct Graph {
        var commits: [UUID: Commit]
        var heads: [UUID]
    }

    private struct LayoutReceipt: Codable {
        var version = 1
        // Relative immutable file names and verified SHA-256 values. Retaining
        // this until cleanup completes makes partially removed wrappers resumable.
        var files: [String: String]
        var sources: [String: [String: String]]?
        var initializing: Bool?
        var cleanup: Bool?
    }
    private static let layoutReceiptName = ".direct-library-layout.json"
    private static let managedDirectories = ["audio", "commits", "connections"]

    private static func names(in directory: URL, root: URL) async throws -> Set<String> {
        Set(try await list(directory, root: root).map { logicalName($0.lastPathComponent) })
    }

    private static func makeDirectory(_ directory: URL, root: URL) async throws {
        try await coordinatedWrite(directory, root: root) { accessed in
            try RecordingAssetStorage.requireDirectory(at: accessed, fileManager: .default, create: true)
        }
    }

    /// Only wrappers BELOW the selected folder migrate. The selected folder may
    /// itself already be a library, and its original security-scoped URL is kept.
    private static func prepareStore(in folder: URL, allowCreation: Bool) async throws {
        let rootNames = try await names(in: folder, root: folder)
        var rootReceipt: LayoutReceipt?
        if rootNames.contains(layoutReceiptName) {
            let bytes = try await read(folder.appending(path: layoutReceiptName), root: folder)
            let receipt = try JSONDecoder().decode(LayoutReceipt.self, from: bytes)
            try validateLayoutReceipt(receipt)
            // Graph reads retain this evidence without repeatedly downloading
            // historical audio after migration has finished.
            rootReceipt = receipt
        }
        var sources: [URL] = []
        var parent = folder
        var parentNames = rootNames
        while parentNames.contains(storeDirectoryName) {
            try Task.checkCancellation()
            let child = parent.appending(path: storeDirectoryName, directoryHint: .isDirectory)
            parentNames = try await names(in: child, root: folder)
            sources.append(child)
            parent = child
        }
        if sources.isEmpty {
            let present = managedDirectories.filter { rootNames.contains($0) }
            // Never repair an incomplete existing store into an apparently empty
            // library. A provider may still be materializing the missing folders.
            guard present.count == managedDirectories.count || rootReceipt?.initializing == true || (present.isEmpty && rootReceipt == nil && allowCreation) else {
                throw ICloudDriveSyncError.downloadPending
            }
            if present.count != managedDirectories.count, rootReceipt == nil {
                _ = try await writeLayoutReceipt(LayoutReceipt(files: [:], initializing: true), in: folder, root: folder)
            }
            for name in managedDirectories {
                try await makeDirectory(folder.appending(path: name), root: folder)
            }
            if rootReceipt?.initializing == true || (present.isEmpty && rootReceipt == nil) {
                _ = try await writeLayoutReceipt(LayoutReceipt(files: [:], initializing: false), in: folder, root: folder)
            }
            for (source, files) in rootReceipt?.sources ?? [:] {
                try await retireLayoutSource(source, files: files, in: folder)
            }
            return
        }

        // Read and validate all legacy inventories before changing their contents.
        var inventories: [(URL, LayoutReceipt)] = []
        for (index, source) in sources.enumerated() {
            let key = Array(repeating: storeDirectoryName, count: index + 1).joined(separator: "/")
            inventories.append((source, try await inventory(source, root: folder, completedInventory: rootReceipt?.sources?[key])))
        }
        for name in managedDirectories {
            try await makeDirectory(folder.appending(path: name), root: folder)
        }
        for (source, receipt) in inventories {
            // Audio precedes history, and receipts precede connection markers.
            let paths = receipt.files.keys.sorted {
                let lhs = migrationOrder($0), rhs = migrationOrder($1)
                return lhs == rhs ? $0 < $1 : lhs < rhs
            }
            for path in paths {
                try Task.checkCancellation()
                guard let hash = receipt.files[path] else { throw ICloudDriveSyncError.invalidData }
                let target = folder.appending(path: migrationDestination(path, hash: hash))
                let original = source.appending(path: path)
                if try await filePresent(original, root: folder) {
                    let bytes = try await read(original, root: folder)
                    guard digest(bytes) == receipt.files[path] else { throw ICloudDriveSyncError.invalidData }
                    try await makeDirectory(target.deletingLastPathComponent(), root: folder)
                    try await publish(bytes, to: target, store: folder)
                } else {
                    // A receipt proves this file was copied before a previous
                    // interruption. Require its destination to remain available.
                    guard digest(try await read(target, root: folder)) == receipt.files[path] else {
                        throw ICloudDriveSyncError.invalidData
                    }
                }
            }
        }
        let graph = try await readGraph(store: folder, connection: nil)
        for hash in Set(graph.commits.values.flatMap { $0.audio.values }) {
            let bytes = try await read(folder.appending(path: "audio/" + hash + ".m4a"), root: folder)
            guard !bytes.isEmpty, digest(bytes) == hash else { throw ICloudDriveSyncError.invalidData }
        }
        var combined = LayoutReceipt(files: [:], sources: [:], initializing: false)
        for (index, item) in inventories.enumerated() {
            let receipt = item.1
            let key = Array(repeating: storeDirectoryName, count: index + 1).joined(separator: "/")
            combined.sources?[key] = receipt.files
            for (path, hash) in receipt.files {
                let destination = migrationDestination(path, hash: hash)
                guard combined.files[destination] == nil || combined.files[destination] == hash else { throw ICloudDriveSyncError.invalidData }
                combined.files[destination] = hash
            }
        }
        let durable = try await writeLayoutReceipt(combined, in: folder, root: folder)
        for (path, hash) in durable.files {
            guard digest(try await read(folder.appending(path: path), root: folder)) == hash else {
                throw ICloudDriveSyncError.invalidData
            }
        }
        // No source is removed until the complete union (including historical
        // audio and receipts from every device) has been published and checked.
        for (index, item) in inventories.enumerated().reversed() {
            let (source, receipt) = item
            var cleanupReceipt = receipt
            cleanupReceipt.cleanup = true
            let recorded = try await writeLayoutReceipt(cleanupReceipt, in: source, root: folder)
            for (path, hash) in recorded.files {
                let target = folder.appending(path: migrationDestination(path, hash: hash))
                guard digest(try await read(target, root: folder)) == hash else {
                    throw ICloudDriveSyncError.invalidData
                }
                try await removeVerifiedFile(source.appending(path: path), matching: target, hash: hash, root: folder)
            }
            let connectionNames = Set(recorded.files.keys.compactMap { path -> String? in
                let parts = path.split(separator: "/")
                return parts.count == 3 && parts[0] == "connections" ? String(parts[1]) : nil
            })
            for name in connectionNames {
                try await removeEmptyDirectory(source.appending(path: "connections/" + name), root: folder)
            }
            for name in managedDirectories {
                try await removeEmptyDirectory(source.appending(path: name), root: folder)
            }
            try await coordinatedWrite(source, root: folder) { accessed in
                let remaining = try FileManager.default.contentsOfDirectory(at: accessed, includingPropertiesForKeys: nil)
                guard remaining.map(\.lastPathComponent) == [layoutReceiptName] else {
                    throw ICloudDriveSyncError.downloadPending
                }
                let journal = accessed.appending(path: layoutReceiptName)
                try checkPath(journal, inside: folder, allowMissing: false)
                let current = try JSONDecoder().decode(LayoutReceipt.self, from: Data(contentsOf: journal))
                guard current.version == 1, current.files == recorded.files else { throw ICloudDriveSyncError.downloadPending }
                try FileManager.default.removeItem(at: journal)
                // rmdir never recursively removes a late or unenumerated child.
                guard rmdir(accessed.path) == 0 || errno == ENOENT else {
                    throw ICloudDriveSyncError.downloadPending
                }
            }
            let key = Array(repeating: storeDirectoryName, count: index + 1).joined(separator: "/")
            if let files = durable.sources?[key] {
                try await retireLayoutSource(key, files: files, in: folder)
            }
        }
    }

    private static func migrationOrder(_ path: String) -> Int {
        if path.hasPrefix("audio/") { return 0 }
        if path.hasPrefix("commits/") { return 1 }
        if path.hasPrefix("connections/") { return path.hasSuffix("/marker.json") ? 3 : 2 }
        return 4
    }

    private static func migrationDestination(_ path: String, hash: String) -> String {
        // Finder and AppleDouble metadata is mutable and can differ between
        // wrappers. Preserve each byte sequence without colliding with root data.
        isIncidental(path.split(separator: "/").last.map(String.init) ?? "")
            ? ".preserved-library-metadata-" + hash + ".bin" : path
    }

    private static func isPreservedMetadata(_ name: String) -> Bool {
        let prefix = ".preserved-library-metadata-"
        return name.hasPrefix(prefix) && name.hasSuffix(".bin") && validDigest(String(name.dropFirst(prefix.count).dropLast(4)))
    }

    private static func validMigrationPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(""), !parts.contains("."), !parts.contains("..") else { return false }
        if parts.count == 1 { return isIncidental(parts[0]) || isPreservedMetadata(parts[0]) }
        if parts.count == 2 {
            if isIncidental(parts[1]) { return managedDirectories.contains(parts[0]) }
            if parts[0] == "audio" { return parts[1].hasSuffix(".m4a") && validDigest(String(parts[1].dropLast(4))) }
            if parts[0] == "commits" { return fileID(parts[1], suffix: ".json") != nil }
        }
        if parts.count == 3, parts[0] == "connections", canonicalUUID(parts[1]) {
            return parts[2] == "marker.json" || fileID(parts[2], suffix: ".seen") != nil || isIncidental(parts[2])
        }
        return false
    }

    private static func validateLayoutReceipt(_ receipt: LayoutReceipt) throws {
        guard receipt.version == 1, receipt.files.allSatisfy({ validMigrationPath($0.key) && validDigest($0.value) }) else {
            throw ICloudDriveSyncError.invalidData
        }
        for (source, files) in receipt.sources ?? [:] {
            let components = source.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty, components.allSatisfy({ $0 == storeDirectoryName }),
                  files.allSatisfy({ validMigrationPath($0.key) && validDigest($0.value) }) else {
                throw ICloudDriveSyncError.invalidData
            }
        }
    }

    private static func inventory(_ source: URL, root: URL, completedInventory: [String: String]?) async throws -> LayoutReceipt {
        let entries = try await names(in: source, root: root)
        var receipt = LayoutReceipt(files: completedInventory ?? [:])
        if entries.contains(layoutReceiptName) {
            receipt = try JSONDecoder().decode(LayoutReceipt.self, from: await read(source.appending(path: layoutReceiptName), root: root))
            try validateLayoutReceipt(receipt)
        }
        guard managedDirectories.allSatisfy({ entries.contains($0) }) || receipt.cleanup == true || completedInventory != nil else {
            throw ICloudDriveSyncError.downloadPending
        }
        var paths: [String] = []
        for name in entries {
            if name == layoutReceiptName || name == storeDirectoryName { continue }
            if isIncidental(name) || isPreservedMetadata(name) { paths.append(name); continue }
            guard managedDirectories.contains(name) else { throw ICloudDriveSyncError.invalidData }
            for child in try await names(in: source.appending(path: name), root: root) {
                if name == "connections", canonicalUUID(child) {
                    let directory = source.appending(path: "connections/" + child)
                    let files = try await names(in: directory, root: root)
                    // A connection left without its marker is only acceptable
                    // during receipt-backed cleanup from a previous attempt.
                    guard files.contains("marker.json") || receipt.files["connections/" + child + "/marker.json"] != nil else {
                        throw ICloudDriveSyncError.downloadPending
                    }
                    paths.append(contentsOf: files.map { "connections/" + child + "/" + $0 })
                } else { paths.append(name + "/" + child) }
            }
        }
        for path in paths {
            guard validMigrationPath(path) else { throw ICloudDriveSyncError.invalidData }
            let bytes = try await read(source.appending(path: path), root: root)
            let hash = digest(bytes)
            if let previous = receipt.files[path], previous != hash,
               !isIncidental(path.split(separator: "/").last.map(String.init) ?? "") {
                throw ICloudDriveSyncError.invalidData
            }
            receipt.files[path] = hash
        }
        return receipt
    }

    private static func filePresent(_ url: URL, root: URL) async throws -> Bool {
        do { return try await names(in: url.deletingLastPathComponent(), root: root).contains(url.lastPathComponent) }
        catch where RecordingAssetStorage.isMissingFileError(error) { return false }
    }

    private static func writeLayoutReceipt(_ receipt: LayoutReceipt, in source: URL, root: URL) async throws -> LayoutReceipt {
        try await coordinatedWrite(source, root: root) { accessed in
            let url = accessed.appending(path: layoutReceiptName)
            try checkPath(url, inside: root, allowMissing: true)
            let placeholder = accessed.appending(path: "." + layoutReceiptName + ".icloud")
            if FileManager.default.fileExists(atPath: placeholder.path), !FileManager.default.fileExists(atPath: url.path) {
                throw ICloudDriveSyncError.downloadPending
            }
            var merged = receipt
            if FileManager.default.fileExists(atPath: url.path) {
                let existing = try JSONDecoder().decode(LayoutReceipt.self, from: Data(contentsOf: url))
                guard existing.version == 1 else { throw ICloudDriveSyncError.invalidData }
                for (path, hash) in existing.files {
                    let incidental = isIncidental(path.split(separator: "/").last.map(String.init) ?? "")
                    guard validMigrationPath(path), validDigest(hash), incidental || merged.files[path] == nil || merged.files[path] == hash else {
                        throw ICloudDriveSyncError.invalidData
                    }
                    if merged.files[path] == nil { merged.files[path] = hash }
                }
                var sources = existing.sources ?? [:]
                for (source, files) in merged.sources ?? [:] {
                    var previous = sources[source] ?? [:]
                    for (path, hash) in files {
                        let incidental = isIncidental(path.split(separator: "/").last.map(String.init) ?? "")
                        guard incidental || previous[path] == nil || previous[path] == hash else { throw ICloudDriveSyncError.invalidData }
                        previous[path] = hash
                    }
                    sources[source] = previous
                }
                if !sources.isEmpty { merged.sources = sources }
                if merged.initializing == nil { merged.initializing = existing.initializing }
                if merged.cleanup == nil { merged.cleanup = existing.cleanup }
            }
            try validateLayoutReceipt(merged)
            try encode(merged).write(to: url, options: [.atomic])
            return merged
        }
    }

    private static func retireLayoutSource(_ source: String, files: [String: String], in root: URL) async throws {
        try await coordinatedWrite(root, root: root) { accessed in
            let url = accessed.appending(path: layoutReceiptName)
            try checkPath(url, inside: root, allowMissing: false)
            var receipt = try JSONDecoder().decode(LayoutReceipt.self, from: Data(contentsOf: url))
            try validateLayoutReceipt(receipt)
            // Keep a concurrently changed inventory for the next attempt.
            guard receipt.sources?[source] == files else { return }
            receipt.sources?.removeValue(forKey: source)
            try encode(receipt).write(to: url, options: [.atomic])
        }
    }

    private static func removeVerifiedFile(_ source: URL, matching target: URL, hash: String, root: URL) async throws {
        guard try await filePresent(source, root: root) else { return }
        try await waitForDownload(source, root: root)
        try await waitForDownload(target, root: root)
        let coordinator = Coordinator()
        try await withTaskCancellationHandler {
            var failure: NSError?
            var result: Result<Void, Error>?
            coordinator.value.coordinate(readingItemAt: target, options: [], writingItemAt: source, options: .forDeleting, error: &failure) { destination, original in
                result = Result {
                    try Task.checkCancellation()
                    try checkPath(destination, inside: root, allowMissing: false)
                    try checkPath(original, inside: root, allowMissing: false)
                    try RecordingAssetStorage.requireRegularFile(at: destination, fileManager: .default)
                    try RecordingAssetStorage.requireRegularFile(at: original, fileManager: .default)
                    let copied = try Data(contentsOf: destination)
                    guard digest(copied) == hash, try Data(contentsOf: original) == copied else {
                        throw ICloudDriveSyncError.invalidData
                    }
                    try FileManager.default.removeItem(at: original)
                }
            }
            if let failure { throw failure }
            guard let result else { throw ICloudDriveSyncError.folderUnavailable }
            try result.get()
        } onCancel: { coordinator.value.cancel() }
    }

    private static func removeEmptyDirectory(_ url: URL, root: URL) async throws {
        do {
            try await coordinatedWrite(url, root: root) { accessed in
                guard rmdir(accessed.path) == 0 || errno == ENOENT else {
                    throw ICloudDriveSyncError.downloadPending
                }
            }
        } catch where RecordingAssetStorage.isMissingFileError(error) { return }
    }

    private static func descriptor(in folder: URL, required: Bool = false) async throws -> Descriptor? {
        let url = folder.appending(path: "library.json")
        let present = try await coordinatedRead(folder, root: folder) { accessed in
            let entries = try FileManager.default.contentsOfDirectory(at: accessed, includingPropertiesForKeys: nil)
            return entries.contains { logicalName($0.lastPathComponent) == "library.json" }
                || FileManager.default.fileExists(atPath: accessed.appending(path: "library.json").path)
        }
        guard present || required else { return nil }
        let value = try JSONDecoder().decode(Descriptor.self, from: await read(url, root: folder))
        guard value.version == 2 else { throw ICloudDriveSyncError.invalidData }
        return value
    }

    private static func verifyStore(_ store: Store) async throws {
        let current = try await descriptor(in: store.root, required: store.generation != nil)
        guard current?.generation == store.generation else { throw ICloudDriveSyncError.folderChanged }
    }

    private static func parseBinding(_ value: String, in root: URL) throws -> Binding {
        let parts = value.components(separatedBy: ":")
        let result: Binding
        if parts.count == 2, parts[0] == "drive", let id = UUID(uuidString: parts[1]) {
            result = Binding(store: Store(root: root, generation: nil), id: id)
        } else if parts.count == 3, parts[0] == "drive-v2",
                  let generation = UUID(uuidString: parts[1]), let id = UUID(uuidString: parts[2]) {
            result = Binding(store: Store(root: root, generation: generation), id: id)
        } else { throw ICloudDriveSyncError.folderChanged }
        guard result.identifier == value else { throw ICloudDriveSyncError.folderChanged }
        return result
    }

    private static func openConnection(in folder: URL, expected: String?) async throws -> Binding {
        guard folder.isFileURL else { throw ICloudDriveSyncError.folderUnavailable }
        try await coordinatedRead(folder, root: folder) { url in
            try RecordingAssetStorage.requireDirectory(at: url, fileManager: .default, create: false)
        }
        let previous = try expected.map { try parseBinding($0, in: folder) }
        let current = try await descriptor(in: folder, required: previous?.store.generation != nil)
        let store = Store(root: folder, generation: current?.generation)
        if let previous, previous.store.generation != store.generation {
            throw ICloudDriveSyncError.folderChanged
        }
        if store.generation == nil {
            try await prepareStore(in: folder, allowCreation: previous == nil)
        } else {
            // A descriptor is published with its complete namespace. Missing
            // directories can be incomplete iCloud availability, never emptiness.
            for name in managedDirectories {
                do {
                    try await coordinatedRead(store.directory(name), root: folder) { accessed in
                        try RecordingAssetStorage.requireDirectory(at: accessed, fileManager: .default, create: false)
                    }
                } catch where RecordingAssetStorage.isMissingFileError(error) {
                    throw ICloudDriveSyncError.downloadPending
                }
            }
        }
        try await verifyStore(store)
        if let previous {
            let id = previous.id
            let connection = connectionURL(id, store: store)
            do {
                let markerData = try await read(connection.appending(path: "marker.json"), root: folder)
                let marker = try JSONDecoder().decode(Marker.self, from: markerData)
                guard marker.version == 1, marker.id == id else { throw ICloudDriveSyncError.folderChanged }
                for name in managedDirectories {
                    try await coordinatedRead(store.directory(name), root: folder) { url in
                        try RecordingAssetStorage.requireDirectory(at: url, fileManager: .default, create: false)
                    }
                }
                try await verifyStore(store)
                return previous
            } catch is CancellationError { throw CancellationError() }
            catch let error as ICloudDriveSyncError where error == .downloadPending { throw error }
            catch { throw ICloudDriveSyncError.folderChanged }
        }
        // Validate existing history before adding a new binding. Receipts from
        // other devices also prevent an omitted commit from looking like emptiness.
        _ = try await readGraph(store: store, connection: nil)
        let id = UUID()
        let connection = connectionURL(id, store: store)
        try await coordinatedWrite(connection, root: folder) { url in
            try RecordingAssetStorage.requireDirectory(at: url, fileManager: .default, create: true)
        }
        try await verifyStore(store)
        try await publish(try encode(Marker(version: 1, id: id)),
                          to: connection.appending(path: "marker.json"), store: folder)
        try await verifyStore(store)
        return Binding(store: store, id: id)
    }

    private static func readGraph(
        store: URL, connection: UUID?, required: Set<UUID> = []
    ) async throws -> Graph {
        try await readGraph(store: Store(root: store, generation: nil), connection: connection, required: required)
    }

    private static func readGraph(
        store: Store, connection: UUID?, required: Set<UUID> = []
    ) async throws -> Graph {
        var recorded: [String: String] = [:]
        if store.generation == nil, try await names(in: store.root, root: store.root).contains(layoutReceiptName) {
            let data = try await read(store.root.appending(path: layoutReceiptName), root: store.root)
            let receipt = try JSONDecoder().decode(LayoutReceipt.self, from: data)
            try validateLayoutReceipt(receipt)
            recorded = receipt.files
        }
        let commitsURL = store.directory("commits")
        let entries = try await list(commitsURL, root: store.root)
        // Locally checkpointed heads are independent of provider enumeration.
        // Read them directly even if both a commit and its .seen receipt are
        // omitted from listings; an older graph must not roll back saved edits.
        var pending = required
        for entry in entries {
            let name = logicalName(entry.lastPathComponent)
            if isIncidental(name) { continue }
            guard let id = fileID(name, suffix: ".json") else { throw ICloudDriveSyncError.invalidData }
            pending.insert(id)
        }
        for path in recorded.keys where path.hasPrefix("commits/") {
            if let id = fileID(String(path.dropFirst(8)), suffix: ".json") { pending.insert(id) }
        }
        // Receipts preserve evidence of observed history if provider enumeration
        // later omits a previously downloaded commit. Never interpret it as empty.
        var connections = try await names(in: store.directory("connections"), root: store.root)
        for path in recorded.keys {
            let parts = path.split(separator: "/")
            if parts.count == 3, parts[0] == "connections" { connections.insert(String(parts[1])) }
        }
        var foundConnection = connection == nil
        for name in connections {
            if isIncidental(name) { continue }
            guard let id = UUID(uuidString: name), canonicalUUID(name) else {
                throw ICloudDriveSyncError.invalidData
            }
            if id == connection { foundConnection = true }
            let directory = connectionURL(id, store: store)
            let markerData = try await read(directory.appending(path: "marker.json"), root: store.root)
            if let hash = recorded["connections/" + name + "/marker.json"], digest(markerData) != hash {
                throw ICloudDriveSyncError.invalidData
            }
            let marker = try JSONDecoder().decode(Marker.self, from: markerData)
            guard marker.version == 1, marker.id == id else { throw ICloudDriveSyncError.invalidData }
            var receipts = try await names(in: directory, root: store.root)
            let prefix = "connections/" + name + "/"
            for path in recorded.keys where path.hasPrefix(prefix) {
                receipts.insert(String(path.dropFirst(prefix.count)))
            }
            for name in receipts {
                if name == "marker.json" || isIncidental(name) { continue }
                guard let id = fileID(name, suffix: ".seen") else { throw ICloudDriveSyncError.invalidData }
                let data = try await read(directory.appending(path: name), root: store.root)
                if let hash = recorded[prefix + name], digest(data) != hash { throw ICloudDriveSyncError.invalidData }
                let receipt = try JSONDecoder().decode(Receipt.self, from: data)
                guard receipt.version == 1, receipt.commit == id else { throw ICloudDriveSyncError.invalidData }
                pending.insert(id)
            }
        }
        guard foundConnection else { throw ICloudDriveSyncError.downloadPending }
        var graph = Graph(commits: [:], heads: [])
        var globalAudio: [String: String] = [:]
        while let id = pending.popFirst() {
            try Task.checkCancellation()
            if graph.commits[id] != nil { continue }
            let data = try await read(commitURL(id, store: store), root: store.root)
            if let hash = recorded["commits/" + id.uuidString + ".json"], digest(data) != hash {
                throw ICloudDriveSyncError.invalidData
            }
            let commit = try JSONDecoder().decode(Commit.self, from: data)
            guard commit.version == 1, commit.id == id,
                  commit.parents == Array(Set(commit.parents)).sorted(by: uuidLess),
                  !commit.parents.contains(id), commit.metadataDigest == digest(commit.metadata) else {
                throw ICloudDriveSyncError.invalidData
            }
            let document = try LibrarySyncMerge.decodeMetadata(commit.metadata)
            let required = try recordingIDs(in: document)
            guard Set(commit.audio.keys) == required else { throw ICloudDriveSyncError.invalidData }
            for (recording, hash) in commit.audio {
                guard canonicalUUID(recording), validDigest(hash) else { throw ICloudDriveSyncError.invalidData }
                if let previous = globalAudio[recording], previous != hash {
                    throw ICloudDriveSyncError.immutableAudioConflict
                }
                globalAudio[recording] = hash
            }
            graph.commits[id] = commit
            pending.formUnion(commit.parents.filter { graph.commits[$0] == nil })
        }

        // Validate cycles iteratively. Caching the full ancestry of every commit
        // would consume quadratic memory for an ordinary linear editing history.
        var remainingParents: [UUID: Int] = [:]
        var children: [UUID: [UUID]] = [:]
        for (id, commit) in graph.commits {
            remainingParents[id] = commit.parents.count
            for parent in commit.parents {
                guard graph.commits[parent] != nil else { throw ICloudDriveSyncError.invalidData }
                children[parent, default: []].append(id)
            }
        }
        var ready = remainingParents.keys.filter { remainingParents[$0] == 0 }
        var visitedCount = 0
        while let id = ready.popLast() {
            try Task.checkCancellation()
            visitedCount += 1
            for child in children[id, default: []] {
                remainingParents[child, default: 0] -= 1
                if remainingParents[child] == 0 { ready.append(child) }
            }
        }
        guard visitedCount == graph.commits.count else { throw ICloudDriveSyncError.invalidData }
        let parents = Set(graph.commits.values.flatMap(\.parents))
        graph.heads = Set(graph.commits.keys).subtracting(parents).sorted(by: uuidLess)
        return graph
    }

    /// Deterministic recursive merge bases also handle criss-cross histories.
    /// A virtual merged head carries the union of its inputs' ancestry. Maximal
    /// common ancestors are merged recursively, rather than choosing an arbitrary
    /// old baseline that could turn later additions into deletion intent.
    private static func mergeHeads(_ heads: [UUID], graph: Graph) throws -> LibraryDocument {
        var documents: [UUID: LibraryDocument] = [:]
        var ancestry: [UUID: Set<UUID>] = [:]
        return try mergeHeads(heads, graph: graph, documents: &documents, ancestry: &ancestry)
    }

    private static func mergeHeads(
        _ heads: [UUID], graph: Graph,
        documents: inout [UUID: LibraryDocument], ancestry: inout [UUID: Set<UUID>]
    ) throws -> LibraryDocument {
        if heads.isEmpty { return LibraryDocument() }
        let sorted = heads.sorted(by: uuidLess)
        guard let first = sorted.first else { throw ICloudDriveSyncError.invalidData }
        var document = try graphDocument(first, graph: graph, cache: &documents)
        // A single head is already a complete snapshot. No ancestry closures or
        // historical decoded libraries are needed for the common linear case.
        if sorted.count == 1 { return document }
        var mergedAncestors = try graphAncestors(first, graph: graph, cache: &ancestry)
        for head in heads.sorted(by: uuidLess).dropFirst() {
            try Task.checkCancellation()
            let remote = try graphDocument(head, graph: graph, cache: &documents)
            let remoteAncestors = try graphAncestors(head, graph: graph, cache: &ancestry)
            let common = mergedAncestors.intersection(remoteAncestors)
            // The intersection is ancestry-closed, so every nonmaximal common
            // ancestor is a direct parent of another member of the intersection.
            let parents = Set(common.flatMap { graph.commits[$0]?.parents ?? [] })
            let maximal = common.subtracting(parents).sorted(by: uuidLess)
            let base = try mergeHeads(maximal, graph: graph, documents: &documents, ancestry: &ancestry)
            document = try LibrarySyncMerge.merge(base: base, local: document, remote: remote, requireAudio: false)
            mergedAncestors.formUnion(remoteAncestors)
        }
        return document
    }

    private static func graphDocument(
        _ id: UUID, graph: Graph, cache: inout [UUID: LibraryDocument]
    ) throws -> LibraryDocument {
        if let document = cache[id] { return document }
        guard let commit = graph.commits[id] else { throw ICloudDriveSyncError.invalidData }
        var document = try LibrarySyncMerge.decodeMetadata(commit.metadata)
        // Digest bytes survive conflict-copy identity remapping because audioData
        // is carried in memory but excluded from metadata Codable.
        try hydrateCarriers(&document, references: commit.audio)
        cache[id] = document
        return document
    }

    private static func graphAncestors(
        _ id: UUID, graph: Graph, cache: inout [UUID: Set<UUID>]
    ) throws -> Set<UUID> {
        if let ancestors = cache[id] { return ancestors }
        var ancestors = Set<UUID>()
        var pending = [id]
        while let next = pending.popLast() {
            try Task.checkCancellation()
            guard ancestors.insert(next).inserted else { continue }
            guard let commit = graph.commits[next] else { throw ICloudDriveSyncError.invalidData }
            pending.append(contentsOf: commit.parents)
        }
        cache[id] = ancestors
        return ancestors
    }

    private static func hydrateCarriers(_ document: inout LibraryDocument, references: [String: String]) throws {
        let read: ([String]) throws -> Data = { components in
            guard let hash = references[try recordingID(components)], let bytes = digestBytes(hash) else {
                throw ICloudDriveSyncError.invalidData
            }
            return bytes
        }
        try RecordingAssetStorage.hydrate(songs: &document.songs, read: read)
        try RecordingAssetStorage.hydrate(trash: &document.trashedRecordings, read: read)
        try RecordingAssetStorage.hydrate(songTrash: &document.trashedSongs, read: read)
    }

    private static func hydrate(_ document: inout LibraryDocument, reusing local: LibraryDocument, store: Store) async throws {
        var cache: [String: Data] = [:]
        for asset in RecordingAssetStorage.assets(in: local) where !asset.data.isEmpty {
            cache[digest(asset.data)] = asset.data
        }
        var references: [String: String] = [:]
        for asset in RecordingAssetStorage.assets(in: document) {
            guard asset.data.count == 32 else { throw ICloudDriveSyncError.invalidData }
            let hash = hex(asset.data)
            references[try recordingID(asset.components)] = hash
            if cache[hash] == nil {
                let bytes = try await read(store.directory("audio").appending(path: hash + ".m4a"), root: store.root)
                guard !bytes.isEmpty, digest(bytes) == hash else { throw ICloudDriveSyncError.invalidData }
                cache[hash] = bytes
            }
        }
        let read: ([String]) throws -> Data = { components in
            guard let hash = references[try recordingID(components)], let bytes = cache[hash] else {
                throw ICloudDriveSyncError.invalidData
            }
            return bytes
        }
        try RecordingAssetStorage.hydrate(songs: &document.songs, read: read)
        try RecordingAssetStorage.hydrate(trash: &document.trashedRecordings, read: read)
        try RecordingAssetStorage.hydrate(songTrash: &document.trashedSongs, read: read)
        try RecordingAssetStorage.validate(document: document, requireAudio: true)
    }

    private static func recordingIDs(in document: LibraryDocument) throws -> Set<String> {
        Set(try RecordingAssetStorage.assets(in: document).map { try recordingID($0.components) })
    }
    private static func audioReferences(_ document: LibraryDocument) throws -> [String: String] {
        var result: [String: String] = [:]
        for asset in RecordingAssetStorage.assets(in: document) {
            guard result.updateValue(digest(asset.data), forKey: try recordingID(asset.components)) == nil else {
                throw ICloudDriveSyncError.invalidData
            }
        }
        return result
    }
    private static func recordingID(_ components: [String]) throws -> String {
        guard let last = components.last, let id = fileID(last, suffix: ".m4a") else {
            throw ICloudDriveSyncError.invalidData
        }
        return id.uuidString
    }
    private static func remember(_ heads: [UUID], connection: UUID, store: Store) async throws {
        for id in heads {
            let data = try encode(Receipt(version: 1, commit: id))
            try await publish(data, to: connectionURL(connection, store: store).appending(path: id.uuidString + ".seen"), store: store.root)
        }
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private static func revision(_ heads: [UUID]) -> String? {
        heads.isEmpty ? nil : "drive-v1:" + heads.sorted(by: uuidLess).map(\.uuidString).joined(separator: ",")
    }
    private static func heads(from revision: String?) throws -> Set<UUID> {
        guard let revision else { return [] }
        guard revision.hasPrefix("drive-v1:") else { throw ICloudDriveSyncError.invalidData }
        let names = String(revision.dropFirst("drive-v1:".count)).components(separatedBy: ",")
        let ids = names.compactMap(UUID.init(uuidString:))
        guard !ids.isEmpty, ids.count == names.count, Set(ids).count == ids.count,
              Self.revision(ids) == revision else { throw ICloudDriveSyncError.invalidData }
        return Set(ids)
    }
    private static func connectionURL(_ id: UUID, store: Store) -> URL {
        store.directory("connections")
            .appending(path: id.uuidString, directoryHint: .isDirectory)
    }
    private static func commitURL(_ id: UUID, store: Store) -> URL {
        store.directory("commits")
            .appending(path: id.uuidString + ".json", directoryHint: .notDirectory)
    }
    private static func uuidLess(_ lhs: UUID, _ rhs: UUID) -> Bool { lhs.uuidString < rhs.uuidString }
    private static func canonicalUUID(_ value: String) -> Bool { UUID(uuidString: value)?.uuidString == value }
    private static func fileID(_ value: String, suffix: String) -> UUID? {
        guard value.hasSuffix(suffix) else { return nil }
        let text = String(value.dropLast(suffix.count))
        guard canonicalUUID(text) else { return nil }
        return UUID(uuidString: text)
    }
    private static func digest(_ data: Data) -> String { hex(Data(SHA256.hash(data: data))) }
    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func digestBytes(_ value: String) -> Data? {
        guard validDigest(value) else { return nil }
        let chars = Array(value.utf8)
        func nibble(_ byte: UInt8) -> UInt8 { byte <= 57 ? byte - 48 : byte - 87 }
        return Data(stride(from: 0, to: chars.count, by: 2).map { nibble(chars[$0]) * 16 + nibble(chars[$0 + 1]) })
    }
    private static func logicalName(_ name: String) -> String {
        if name.hasPrefix("."), name.hasSuffix(".icloud") { return String(name.dropFirst().dropLast(7)) }
        return name
    }
    private static func isIncidental(_ name: String) -> Bool { name == ".DS_Store" || name.hasPrefix("._") }

    // Every blocking filesystem operation runs in a detached task, including the
    // synchronous coordinator wait. The security scope covers the entire operation.
    private static func perform<T: Sendable>(
        in folder: URL, operation: @escaping @Sendable (URL) async throws -> T
    ) async throws -> T {
        let task = Task.detached { try await withFolderScope(folder, operation: operation) }
        do {
            return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch { throw safeError(error) }
    }
    private static func withFolderScope<T: Sendable>(
        _ folder: URL, operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let started = folder.startAccessingSecurityScopedResource()
        defer { if started { folder.stopAccessingSecurityScopedResource() } }
        return try await operation(folder)
    }

    /// Refuse symlinks and special files for every managed path component.
    /// The user's selected root can have ordinary system ancestors outside scope.
    private static func checkPath(_ url: URL, inside root: URL, allowMissing: Bool) throws {
        // Standardization is filesystem-dependent: on iOS it can strip /private
        // from an existing root but retain it on a child we have not created yet.
        // Compare lexical components first, preserving the original scoped URL.
        let rootParts = root.pathComponents
        let parts = url.pathComponents
        guard root.isFileURL, url.isFileURL,
              rootParts.first == "/", parts.first == "/",
              !rootParts.contains(".."), !parts.contains(".."),
              !rootParts.contains("."), !parts.contains(".") else {
            throw ICloudDriveSyncError.invalidData
        }

        let boundaryCount: Int
        if Array(parts.prefix(rootParts.count)) == rootParts {
            boundaryCount = rootParts.count
        } else {
            // A coordinator may return the other spelling of an existing system
            // ancestor, such as /var versus /private/var. Find that same existing
            // root boundary, then inspect its descendants without resolving them.
            // Resolving the whole target would hide a symlink inside the library.
            let resolvedRoot = root.resolvingSymlinksInPath().pathComponents
            var prefix = URL(fileURLWithPath: "/", isDirectory: true)
            var matchedCount: Int? = resolvedRoot == ["/"] ? 1 : nil
            for (index, component) in parts.dropFirst().enumerated() {
                if matchedCount != nil { break }
                prefix.appendPathComponent(component, isDirectory: true)
                if prefix.resolvingSymlinksInPath().pathComponents == resolvedRoot {
                    matchedCount = index + 2
                }
            }
            guard let matchedCount else { throw ICloudDriveSyncError.invalidData }
            boundaryCount = matchedCount
        }

        let descendants = Array(parts.dropFirst(boundaryCount))
        var current = url
        for _ in descendants { current.deleteLastPathComponent() }
        for (index, component) in ([""] + descendants).enumerated() {
            if !component.isEmpty { current.append(path: component) }
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: current.path)
                let type = attrs[.type] as? FileAttributeType
                let isFileLeaf = index > 0 && index == descendants.count
                guard type == .typeDirectory || (isFileLeaf && type == .typeRegular) else {
                    throw ICloudDriveSyncError.invalidData
                }
            } catch {
                if allowMissing && RecordingAssetStorage.isMissingFileError(error) { continue }
                throw error
            }
        }
    }

    private final class Coordinator: @unchecked Sendable {
        let value = NSFileCoordinator(filePresenter: nil)
    }
    private static func coordinatedRead<T>(
        _ url: URL, root: URL, operation: (URL) throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let coordinator = Coordinator()
        return try await withTaskCancellationHandler {
            var failure: NSError?
            var result: Result<T, Error>?
            coordinator.value.coordinate(readingItemAt: url, options: [], error: &failure) { accessed in
                result = Result {
                    try Task.checkCancellation()
                    try checkPath(accessed, inside: root, allowMissing: false)
                    return try operation(accessed)
                }
            }
            try Task.checkCancellation()
            if let failure { throw failure }
            guard let result else { throw ICloudDriveSyncError.folderUnavailable }
            return try result.get()
        } onCancel: { coordinator.value.cancel() }
    }
    private static func coordinatedWrite<T>(
        _ url: URL, root: URL, operation: (URL) throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let coordinator = Coordinator()
        return try await withTaskCancellationHandler {
            var failure: NSError?
            var result: Result<T, Error>?
            coordinator.value.coordinate(writingItemAt: url, options: [], error: &failure) { accessed in
                result = Result {
                    try Task.checkCancellation()
                    try checkPath(accessed, inside: root, allowMissing: true)
                    return try operation(accessed)
                }
            }
            try Task.checkCancellation()
            if let failure { throw failure }
            guard let result else { throw ICloudDriveSyncError.folderUnavailable }
            return try result.get()
        } onCancel: { coordinator.value.cancel() }
    }

    private static func waitForDownload(_ url: URL, root: URL) async throws {
        try checkPath(url, inside: root, allowMissing: true)
        // Providers that expose no ubiquity metadata are handled by coordinated
        // access instead. A false startAccess result is valid for an ordinary URL.
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != nil else { return }
        if values.ubiquitousItemDownloadingStatus == .current { return }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            var refreshedURL = url
            refreshedURL.removeAllCachedResourceValues()
            let updated = try? refreshedURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if updated?.ubiquitousItemDownloadingStatus == .current { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw ICloudDriveSyncError.downloadPending
    }
    private static func read(_ url: URL, root: URL) async throws -> Data {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while true {
            try Task.checkCancellation()
            try await waitForDownload(url, root: root)
            do {
                return try await coordinatedRead(url, root: root) { accessed in
                    try RecordingAssetStorage.requireRegularFile(at: accessed, fileManager: .default)
                    return try Data(contentsOf: accessed)
                }
            } catch {
                guard RecordingAssetStorage.isMissingFileError(error) else { throw error }
                guard ContinuousClock.now < deadline else { throw ICloudDriveSyncError.downloadPending }
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }
    private static func list(_ url: URL, root: URL) async throws -> [URL] {
        try await waitForDownload(url, root: root)
        return try await coordinatedRead(url, root: root) { accessed in
            try RecordingAssetStorage.requireDirectory(at: accessed, fileManager: .default, create: false)
            return try FileManager.default.contentsOfDirectory(at: accessed, includingPropertiesForKeys: nil)
        }
    }
    private static func publish(_ data: Data, to url: URL, store: URL) async throws {
        // Existing content-addressed files may be placeholders. Coordinate and
        // verify them before deciding whether publication is already complete.
        try checkPath(url, inside: store, allowMissing: true)
        let placeholder = url.deletingLastPathComponent().appending(path: "." + url.lastPathComponent + ".icloud")
        if FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: placeholder.path) {
            guard try await read(url, root: store) == data else { throw ICloudDriveSyncError.invalidData }
            return
        }
        try await coordinatedWrite(url, root: store) { accessed in
            // Write outside the commits directory so enumeration never observes
            // partially written commits. Move publishes a complete unique file.
            let temporary = store.appending(path: ".pending-" + UUID().uuidString + ".tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: [.withoutOverwriting])
            try Task.checkCancellation()
            do { try FileManager.default.moveItem(at: temporary, to: accessed) }
            catch {
                try RecordingAssetStorage.requireRegularFile(at: accessed, fileManager: .default)
                guard try Data(contentsOf: accessed) == data else { throw ICloudDriveSyncError.invalidData }
            }
        }
    }
    private static func safeError(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        if let error = error as? ICloudDriveSyncError { return error }
        if let error = error as? LibrarySyncMerge.MergeError { return error }
        if error as? CloudLibrarySyncError == .conflict { return CloudLibrarySyncError.conflict }
        if error is DecodingError || error is RecordingAssetError {
            return ICloudDriveSyncError.invalidData
        }
        return ICloudDriveSyncError.folderUnavailable
    }
}

extension ICloudDriveSyncError: Equatable {}
