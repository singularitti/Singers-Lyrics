import Foundation
import Observation

/// Coordinates cloud work separately from local autosave. Network failures never
/// disable editing or turn a successful local save into a storage failure.
@MainActor
@Observable
final class LibrarySyncController {
    let isAvailable: Bool
    let usesICloudDrive: Bool
    private(set) var hasSyncFolder: Bool
    private(set) var syncFolderName: String?
    private let cloudEnvironment: String
    private(set) var isEnabled: Bool
    private(set) var isSyncing = false
    private(set) var isSelectingFolder = false
    private(set) var status = "Off"
    private(set) var lastSyncedAt: Date?
    private(set) var lastSyncedSongCount: Int?
    private(set) var errorMessage: String?
    private(set) var folderPermissionNotice: String?
    private(set) var canReplaceSyncFolder = false

    @ObservationIgnored var prepareLocalLibrary: (() async -> LibraryDocument?)?
    @ObservationIgnored var canApplyLibrary: ((LibraryDocument, LibraryDocument) throws -> Bool)?
    @ObservationIgnored var applyLibrary: ((LibraryDocument, LibraryDocument) async throws -> Bool)?
    @ObservationIgnored private var transport: (any LibrarySyncTransport)?
    @ObservationIgnored private let checkpointStore: LibrarySyncCheckpointStore
    @ObservationIgnored private let folderStore = LibrarySyncFolderStore()
    @ObservationIgnored private var folderAccess: LibrarySyncFolderAccess?
    @ObservationIgnored private var checkpoint: LibrarySyncCheckpoint?
    @ObservationIgnored private var hasReadCheckpoint = false
    @ObservationIgnored private var scheduledSync: Task<Void, Never>?
    @ObservationIgnored private var periodicSync: Task<Void, Never>?
    @ObservationIgnored private var activeSync: Task<Void, Never>?
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var resyncRequested = false
    @ObservationIgnored private var generation: UInt64 = 0

    private static let enabledPreference = "icloudLibrarySyncEnabled"
    private static let driveEnabledPreference = "icloudDriveLibrarySyncEnabled"
    private var currentEnabledPreference: String {
        usesICloudDrive ? Self.driveEnabledPreference : Self.enabledPreference
    }

    init(usesPersistentLibrary: Bool) {
        let value = Bundle.main.object(forInfoDictionaryKey: "SingersLyricsCloudKitEnabled")
        let configured = (value as? Bool == true)
            || ["YES", "TRUE", "1"].contains((value as? String)?.uppercased() ?? "")
        usesICloudDrive = !configured
        cloudEnvironment = configured
            ? Bundle.main.object(forInfoDictionaryKey: "SingersLyricsCloudKitEnvironment") as? String ?? ""
            : "iCloudDrive"
        checkpointStore = LibrarySyncCheckpointStore(usesICloudDrive: !configured)
        let hasSavedFolder = !configured && UserDefaults.standard.data(
            forKey: LibrarySyncFolderStore.bookmarkPreference
        ) != nil
        hasSyncFolder = hasSavedFolder
        let process = ProcessInfo.processInfo
        let isTesting = process.environment["XCTestConfigurationFilePath"] != nil
            || process.arguments.contains("--ui-testing")
        isAvailable = usesPersistentLibrary && !isTesting
            && (!configured || ["Development", "Production"].contains(cloudEnvironment))
        let wantsSync = UserDefaults.standard.bool(
            forKey: configured ? Self.enabledPreference : Self.driveEnabledPreference
        )
        isEnabled = isAvailable && wantsSync && (configured || hasSavedFolder)
        if !isAvailable { status = "Unavailable in this build" }
        else if isEnabled { status = "Waiting to sync" }
        else if usesICloudDrive && wantsSync && !hasSyncFolder {
            folderPermissionNotice = "Choose your sync folder again to resume syncing. Its permission could not be saved for this launch."
        }
    }

    func start() {
        hasStarted = true
        recoverSavedFolderIfNeeded()
        schedulePeriodicSync()
        requestSync()
    }

    private func recoverSavedFolderIfNeeded() {
        guard hasStarted, isAvailable, isActive, usesICloudDrive,
              !hasSyncFolder, !isEnabled, !isSelectingFolder,
              UserDefaults.standard.bool(forKey: currentEnabledPreference) else { return }
        let recoveryGeneration = generation
        Task {
            do {
                try await readCheckpoint()
                guard generation == recoveryGeneration else { return }
                // The checkpoint is authoritative after a connection change.
                // Recover if the app exited before its preferences cache saved.
                if let bookmark = checkpoint?.folderBookmark?.data {
                    UserDefaults.standard.set(bookmark, forKey: LibrarySyncFolderStore.bookmarkPreference)
                    hasSyncFolder = true
                    folderPermissionNotice = nil
                    setEnabled(true)
                }
            } catch {
                guard generation == recoveryGeneration else { return }
                errorMessage = Self.message(for: error)
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isAvailable, enabled != isEnabled else { return }
        if enabled, usesICloudDrive, !hasSyncFolder {
            errorMessage = ICloudDriveSyncError.folderNotSelected.localizedDescription
            return
        }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: currentEnabledPreference)
        generation &+= 1
        if enabled { errorMessage = nil }
        status = enabled ? "Waiting to sync" : "Off"
        scheduledSync?.cancel()
        scheduledSync = nil
        periodicSync?.cancel()
        periodicSync = nil
        activeSync?.cancel()
        resyncRequested = false
        if enabled {
            schedulePeriodicSync()
            requestSync()
        }
    }

    /// Re-selecting the same folder renews its picker grant. A linked library's
    /// ancestry is retained. A different binding requires an explicit change.
    func selectSyncFolder(_ url: URL, replacingConnection: Bool = false) {
        guard isAvailable, usesICloudDrive, !isSelectingFolder else { return }
        do {
            // Acquire the original picker URL's scope before returning from the
            // callback, rather than after waiting for sync and checkpoint I/O.
            let access = try LibrarySyncFolderAccess(url: url)
            Task {
                if await connectSyncFolder(access, replacingConnection: replacingConnection) {
                    setEnabled(true)
                }
            }
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    @discardableResult
    private func connectSyncFolder(
        _ access: LibrarySyncFolderAccess, replacingConnection: Bool
    ) async -> Bool {
        guard isAvailable, usesICloudDrive, !isSelectingFolder else { return false }
        // Retain the grant even if setup is canceled while a provider operation
        // is still finishing. A rejected selection releases it on return.
        defer { withExtendedLifetime(access) {} }
        isSelectingFolder = true
        generation &+= 1
        let selectionGeneration = generation
        scheduledSync?.cancel()
        scheduledSync = nil
        periodicSync?.cancel()
        periodicSync = nil
        resyncRequested = false
        activeSync?.cancel()
        if let activeSync { await activeSync.value }
        defer {
            isSelectingFolder = false
            // A rejected or canceled replacement leaves the old connection in
            // place. Resume its timer without immediately clearing the error.
            // The existing guards also prevent a duplicate timer after success.
            schedulePeriodicSync()
        }

        do {
            try checkSelection(selectionGeneration)
            try await readCheckpoint()
            try checkSelection(selectionGeneration)
            let selection = try await folderStore.select(access)
            try checkSelection(selectionGeneration)
            var candidateTransport = ICloudDriveLibraryTransport(
                folderURL: selection.access.url,
                expectedFolderIdentifier: checkpoint?.accountIdentifier,
                expectedRevision: checkpoint?.driveRevision
            )
            let binding: String
            var replacesCheckpoint = false
            do {
                // Even after confirming a folder change, reselecting the
                // original folder must retain its baseline and known commits.
                binding = try await candidateTransport.accountIdentifier()
            } catch {
                guard replacingConnection, checkpoint != nil,
                      let folderError = error as? ICloudDriveSyncError,
                      folderError == .folderChanged || folderError == .downloadPending else { throw error }
                try checkSelection(selectionGeneration)
                candidateTransport = ICloudDriveLibraryTransport(folderURL: selection.access.url)
                binding = try await candidateTransport.accountIdentifier()
                replacesCheckpoint = true
            }
            try checkSelection(selectionGeneration)
            if !replacingConnection, let checkpoint, checkpoint.accountIdentifier != binding {
                throw ICloudDriveSyncError.folderChanged
            }
            var connected = checkpoint ?? LibrarySyncCheckpoint(
                accountIdentifier: binding, environment: cloudEnvironment
            )
            if replacesCheckpoint {
                guard let local = await prepareLocalLibrary?() else {
                    throw ICloudDriveSyncError.localLibraryNotReady
                }
                try checkSelection(selectionGeneration)
                // Validate any existing library in the replacement folder before
                // changing the local connection. Nothing is applied or uploaded.
                _ = try await candidateTransport.fetch(reusing: local)
                try checkSelection(selectionGeneration)
                connected = LibrarySyncCheckpoint(
                    accountIdentifier: binding, environment: cloudEnvironment
                )
            }
            connected.folderBookmark = LibrarySyncFolderBookmark(data: selection.bookmark)
            if replacesCheckpoint { try await checkpointStore.replaceConnection(with: connected) }
            else { try await checkpointStore.save(connected) }
            // The binding and bookmark (including session-only access) commit
            // atomically. Adopt them even if the scene became inactive while
            // saving; never resume the old transport with this new checkpoint.
            checkpoint = connected
            lastSyncedAt = connected.lastSyncedAt
            lastSyncedSongCount = connected.lastSyncedAt == nil ? nil : connected.base.songs.count
            // The old bookmark and scope remain intact until both access and the
            // existing library binding have been checked successfully.
            adoptFolderSelection(selection)
            transport = candidateTransport
            errorMessage = nil
            status = isEnabled ? "Waiting to check sync folder" : "Off"
            isSelectingFolder = false
            schedulePeriodicSync()
            requestSync()
            return generation == selectionGeneration && !Task.isCancelled
        } catch is CancellationError {
            status = isEnabled ? "Waiting to check sync folder" : "Off"
            return false
        } catch {
            status = isEnabled ? "Sync paused" : "Off"
            errorMessage = Self.message(for: error)
            if Self.offersFolderReplacement(for: error) { canReplaceSyncFolder = true }
            return false
        }
    }

    private func adoptFolderSelection(_ selection: LibrarySyncFolderSelection) {
        if let bookmark = selection.bookmark {
            UserDefaults.standard.set(bookmark, forKey: LibrarySyncFolderStore.bookmarkPreference)
        } else {
            // Never restore an older grant after accepting a session-only one.
            UserDefaults.standard.removeObject(forKey: LibrarySyncFolderStore.bookmarkPreference)
        }
        folderAccess = selection.access
        hasSyncFolder = true
        syncFolderName = selection.access.url.lastPathComponent
        canReplaceSyncFolder = false
        folderPermissionNotice = selection.bookmark == nil
            ? "This folder is connected for this session, but its permission could not be saved. Choose the same folder again after reopening the app to resume syncing."
            : nil
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            recoverSavedFolderIfNeeded()
            schedulePeriodicSync()
            requestSync()
        } else {
            generation &+= 1
            scheduledSync?.cancel()
            scheduledSync = nil
            periodicSync?.cancel()
            periodicSync = nil
            activeSync?.cancel()
        }
    }

    func libraryDidSave() { requestSync() }

    private func requestSync() {
        guard hasStarted, isAvailable, isEnabled, isActive, !isSelectingFolder else { return }
        if isSyncing {
            resyncRequested = true
            return
        }
        scheduledSync?.cancel()
        scheduledSync = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.scheduledSync = nil
            await self.syncNow()
        }
    }

    private func schedulePeriodicSync() {
        guard periodicSync == nil, hasStarted, isEnabled, isActive, !isSelectingFolder else { return }
        periodicSync = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
                guard let self, self.isEnabled, self.isActive else { return }
                await self.syncNow()
            }
        }
    }

    func syncNow() async {
        scheduledSync?.cancel()
        scheduledSync = nil
        guard hasStarted, isAvailable, isEnabled, isActive, !isSelectingFolder else { return }
        guard activeSync == nil else {
            resyncRequested = true
            return
        }
        // Every entry point shares a cancellable task, including Settings and the
        // debounce timer. Suspending or disabling sync stops subsequent uploads.
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performSync()
        }
        activeSync = task
        await task.value
        activeSync = nil
    }

    private func performSync() async {
        guard hasStarted, isAvailable, isEnabled, isActive, !isSelectingFolder else { return }
        guard !isSyncing else {
            resyncRequested = true
            return
        }
        isSyncing = true
        resyncRequested = false
        errorMessage = nil
        status = "Syncing…"
        let operationGeneration = generation
        defer {
            isSyncing = false
            if !isEnabled { status = "Off" }
            else if !isActive { status = "Waiting for the app to open" }
            if resyncRequested { requestSync() }
        }

        do {
            try await readCheckpoint()
            try checkOperation(operationGeneration)
            if transport == nil {
                if usesICloudDrive {
                    let savedBookmark: Data?
                    if let recorded = checkpoint?.folderBookmark {
                        savedBookmark = recorded.data
                        if savedBookmark == nil {
                            // A committed session-only selection must never fall
                            // back to an older bookmark left in preferences.
                            UserDefaults.standard.removeObject(forKey: LibrarySyncFolderStore.bookmarkPreference)
                            hasSyncFolder = false
                            isEnabled = false
                            folderPermissionNotice = "Choose your sync folder again to resume syncing. Its permission could not be saved for this launch."
                            return
                        }
                    } else {
                        savedBookmark = UserDefaults.standard.data(
                            forKey: LibrarySyncFolderStore.bookmarkPreference
                        )
                    }
                    guard let bookmark = savedBookmark else { throw ICloudDriveSyncError.folderNotSelected }
                    let selection = try await folderStore.restore(bookmark)
                    defer { withExtendedLifetime(selection.access) {} }
                    try checkOperation(operationGeneration)
                    let candidate = ICloudDriveLibraryTransport(
                        folderURL: selection.access.url, expectedFolderIdentifier: checkpoint?.accountIdentifier,
                        expectedRevision: checkpoint?.driveRevision
                    )
                    let binding = try await candidate.accountIdentifier()
                    try checkOperation(operationGeneration)
                    var connected = checkpoint ?? LibrarySyncCheckpoint(
                        accountIdentifier: binding, environment: cloudEnvironment
                    )
                    connected.folderBookmark = LibrarySyncFolderBookmark(data: selection.bookmark)
                    try await checkpointStore.save(connected)
                    checkpoint = connected
                    adoptFolderSelection(selection)
                    transport = candidate
                } else {
                    transport = CloudKitLibraryTransport(
                        expectedAccountIdentifier: checkpoint?.accountIdentifier
                    )
                }
            }
            guard let transport else { return }
            let account = try await transport.accountIdentifier()
            try checkOperation(operationGeneration)
            if let checkpoint, checkpoint.accountIdentifier != account {
                if usesICloudDrive { throw ICloudDriveSyncError.folderChanged }
                throw CloudLibrarySyncError.accountChanged
            }
            if checkpoint == nil {
                // Bind the library before any upload, including across a crash.
                let initial = LibrarySyncCheckpoint(accountIdentifier: account, environment: cloudEnvironment)
                try await checkpointStore.save(initial)
                checkpoint = initial
            }
            guard let local = await prepareLocalLibrary?() else {
                status = "Waiting for local changes to finish saving"
                return
            }
            // An upload can finish just as editing begins. The uploaded local
            // snapshot is then the correct ancestor for the still-unadopted data.
            let base = checkpoint?.pendingLocalBase ?? checkpoint?.base ?? LibraryDocument()

            // Another device can commit between our fetch and save. Always re-read
            // and merge on a conflict; never change the save policy to overwrite.
            for attempt in 0..<3 {
                try checkOperation(operationGeneration)
                let remote = try await transport.fetch(reusing: local)
                try checkOperation(operationGeneration)
                if remote.revision == nil,
                   !(try LibrarySyncMerge.metadataEqual(base, LibraryDocument())) {
                    throw usesICloudDrive
                        ? LibrarySyncCheckpointError.folderLibraryMissing
                        : LibrarySyncCheckpointError.cloudLibraryMissing
                }
                let merged = try LibrarySyncMerge.merge(base: base, local: local, remote: remote.document)
                guard try canApplyLibrary?(merged, local) != false else {
                    status = "Waiting for editing or recording to finish"
                    return
                }
                let metadataChanged = try !LibrarySyncMerge.metadataEqual(merged, remote.document)
                let needsUpload = remote.revision == nil
                    || metadataChanged
                    || remote.cleanupPending
                    || remote.requiresConsolidation
                let committed: CloudLibrarySnapshot
                do {
                    committed = needsUpload
                        ? try await transport.save(merged, replacing: remote.revision)
                        : remote
                } catch CloudLibrarySyncError.conflict where attempt < 2 {
                    continue
                }
                try checkOperation(operationGeneration)
                // Persist the recovery ancestor after a successful cloud commit
                // but before applying it. A crash or newly focused editor must
                // not make the next pass mistake our own upload for another edit.
                var pending = checkpoint ?? LibrarySyncCheckpoint(
                    accountIdentifier: account, environment: cloudEnvironment
                )
                pending.pendingLocalBase = local
                if usesICloudDrive { pending.driveRevision = committed.revision }
                try await checkpointStore.save(pending)
                checkpoint = pending
                guard try await applyLibrary?(committed.document, local) == true else {
                    status = "Waiting for editing or recording to finish"
                    return
                }
                // Applying can suspend during disk I/O. Keep the previous baseline
                // if sync was disabled or the account changed in the meantime.
                try checkOperation(operationGeneration)
                guard try await transport.accountIdentifier() == account else {
                    if usesICloudDrive { throw ICloudDriveSyncError.folderChanged }
                    throw CloudLibrarySyncError.accountChanged
                }
                try checkOperation(operationGeneration)
                let completedAt = Date()
                let next = LibrarySyncCheckpoint(
                    accountIdentifier: account, environment: cloudEnvironment, base: committed.document,
                    lastSyncedAt: completedAt, folderBookmark: checkpoint?.folderBookmark,
                    driveRevision: usesICloudDrive ? committed.revision : nil
                )
                try await checkpointStore.save(next)
                checkpoint = next
                lastSyncedAt = completedAt
                lastSyncedSongCount = committed.document.songs.count
                if usesICloudDrive {
                    status = committed.document.songs.isEmpty
                        ? "No songs in sync folder"
                        : (needsUpload ? "Saved to sync folder" : "Folder up to date")
                } else {
                    status = committed.cleanupPending ? "Finishing recording deletions" : "Up to date"
                }
                return
            }
        } catch is CancellationError {
            if isEnabled { status = "Waiting to sync" }
        } catch {
            // All cloud errors are separate from local storageIssue/autosaveDisabled.
            status = "Sync paused"
            errorMessage = Self.message(for: error)
            if usesICloudDrive, Self.offersFolderReplacement(for: error) {
                canReplaceSyncFolder = true
                if folderAccess == nil { hasSyncFolder = false }
            }
        }
    }

    private func checkOperation(_ expectedGeneration: UInt64) throws {
        try Task.checkCancellation()
        guard generation == expectedGeneration, isEnabled, isActive else {
            throw CancellationError()
        }
    }

    private func checkSelection(_ expectedGeneration: UInt64) throws {
        try Task.checkCancellation()
        guard generation == expectedGeneration else { throw CancellationError() }
    }

    private func readCheckpoint() async throws {
        if !hasReadCheckpoint {
            let loaded = try await checkpointStore.load()
            // Startup recovery and a picker selection can both await this read.
            // A late result must not overwrite an already adopted connection.
            if !hasReadCheckpoint {
                checkpoint = loaded
                hasReadCheckpoint = true
                lastSyncedAt = checkpoint?.lastSyncedAt
                lastSyncedSongCount = checkpoint?.lastSyncedAt == nil ? nil : checkpoint?.base.songs.count
            }
        }
        if let checkpoint, checkpoint.environment != cloudEnvironment {
            throw LibrarySyncCheckpointError.environmentChanged
        }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? CloudLibrarySyncError { return error.localizedDescription }
        if let error = error as? ICloudDriveSyncError { return error.localizedDescription }
        if let error = error as? LibrarySyncCheckpointError { return error.localizedDescription }
        if let error = error as? LibrarySyncMerge.MergeError { return error.localizedDescription }
        if error is LibraryStoreError || error is RecordingAssetError {
            return "The library could not be merged safely. Your local songs are preserved. Try syncing again after resolving the library storage issue."
        }
        return "iCloud sync could not finish. Your songs remain saved on this device. Try Sync Now again."
    }

    private static func offersFolderReplacement(for error: Error) -> Bool {
        if let error = error as? ICloudDriveSyncError {
            switch error {
            case .savedFolderMissing, .bookmarkUnavailable, .folderChanged: return true
            default: return false
            }
        }
        if let error = error as? LibrarySyncCheckpointError,
           case .folderLibraryMissing = error { return true }
        return false
    }
}

private struct LibrarySyncCheckpoint: Codable, Sendable {
    var version = 1
    var accountIdentifier: String
    var environment: String
    var base = LibraryDocument()
    var lastSyncedAt: Date?
    var pendingLocalBase: LibraryDocument?
    var folderBookmark: LibrarySyncFolderBookmark?
    // Pins the history that produced base/pendingLocalBase independently of
    // iCloud Drive directory and receipt visibility. Older checkpoints decode nil.
    var driveRevision: String?
}

/// A present wrapper with nil data records session-only access. An absent wrapper
/// identifies legacy checkpoints whose bookmark is still stored in preferences.
private struct LibrarySyncFolderBookmark: Codable, Sendable {
    var data: Data?
}

private enum LibrarySyncCheckpointError: LocalizedError {
    case unreadable
    case couldNotSave
    case cloudLibraryMissing
    case folderLibraryMissing
    case environmentChanged

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "The saved iCloud sync history could not be read. Sync is paused to protect your library. Your local songs are unchanged."
        case .couldNotSave:
            "The iCloud sync history could not be saved on this device. Check available storage and try again."
        case .cloudLibraryMissing:
            "The previously synced iCloud library could not be found. Sync is paused to protect your local songs. Check that both devices use the same iCloud container and environment."
        case .folderLibraryMissing:
            "The previously synced folder library could not be found. Wait for its files to finish downloading, or connect a replacement folder if you deleted it. Your local library is preserved."
        case .environmentChanged:
            "This library is linked to a different iCloud environment. Use its original Development or Production build to continue syncing. Your local songs have been preserved."
        }
    }
}

private actor LibrarySyncCheckpointStore {
    private let url: URL
    private let validEnvironments: [String]

    init(usesICloudDrive: Bool) {
        url = JSONLibraryStore.defaultLibraryURL().deletingLastPathComponent()
            .appendingPathComponent(usesICloudDrive ? "icloud-drive-sync-v1.json" : "icloud-sync-v1.json")
        validEnvironments = usesICloudDrive ? ["iCloudDrive"] : ["Development", "Production"]
    }

    func load() throws -> LibrarySyncCheckpoint? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let value = try decoder.singleValueContainer().decode(String.self)
                guard let date = LibraryDateCodec.date(from: value) else {
                    throw LibrarySyncCheckpointError.unreadable
                }
                return date
            }
            let checkpoint = try decoder.decode(LibrarySyncCheckpoint.self, from: Data(contentsOf: url))
            guard checkpoint.version == 1, !checkpoint.accountIdentifier.isEmpty,
                  validEnvironments.contains(checkpoint.environment) else {
                throw LibrarySyncCheckpointError.unreadable
            }
            try RecordingAssetStorage.validate(document: checkpoint.base, requireAudio: false)
            if let pending = checkpoint.pendingLocalBase {
                try RecordingAssetStorage.validate(document: pending, requireAudio: false)
            }
            return checkpoint
        } catch { throw LibrarySyncCheckpointError.unreadable }
    }

    func save(_ checkpoint: LibrarySyncCheckpoint) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(LibraryDateCodec.string(from: date))
            }
            let data = try encoder.encode(checkpoint)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
        } catch { throw LibrarySyncCheckpointError.couldNotSave }
    }

    /// Keep the previous connection history locally before explicitly rebinding.
    /// An empty baseline combines the local and new remote library; it cannot
    /// interpret the deleted folder's absence as deletion of local songs.
    func replaceConnection(with checkpoint: LibrarySyncCheckpoint) throws {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let backups = url.deletingLastPathComponent()
                    .appendingPathComponent("Previous Sync Connections", isDirectory: true)
                try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
                try FileManager.default.copyItem(
                    at: url, to: backups.appendingPathComponent(UUID().uuidString + ".json")
                )
            }
            try save(checkpoint)
        } catch { throw LibrarySyncCheckpointError.couldNotSave }
    }
}
