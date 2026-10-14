import Foundation
import OSLog

/// Owns the picker grant for as long as the selected folder transport is in use.
/// Only immutable values cross actors; releasing the grant balances its start.
final class LibrarySyncFolderAccess: @unchecked Sendable {
    let url: URL
    private let startedScope: Bool

    /// Call in the picker callback, before any asynchronous setup work.
    init(url: URL) throws {
        guard url.isFileURL else { throw ICloudDriveSyncError.folderUnavailable }
        let startedScope = url.startAccessingSecurityScopedResource()
        #if os(iOS)
        guard startedScope else { throw ICloudDriveSyncError.folderUnavailable }
        #endif
        // Nonsandboxed macOS can access a folder without a security scope.
        self.url = url
        self.startedScope = startedScope
    }

    deinit {
        if startedScope { url.stopAccessingSecurityScopedResource() }
    }
}

/// A picker grant can remain usable even when the provider cannot persist it.
struct LibrarySyncFolderSelection: Sendable {
    let access: LibrarySyncFolderAccess
    let bookmark: Data?
}

/// Bookmark creation, resolution, and directory inspection can block on a file
/// provider. Keep that work outside the UI actor and never expose a folder path.
actor LibrarySyncFolderStore {
    static let bookmarkPreference = "icloudDriveLibrarySyncFolderBookmark"
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SingersLyrics",
        category: "LibrarySyncFolder"
    )

    func select(_ access: LibrarySyncFolderAccess) throws -> LibrarySyncFolderSelection {
        try prepare(access, bookmark: nil)
    }

    func restore(_ bookmark: Data) throws -> LibrarySyncFolderSelection {
        try Task.checkCancellation()
        var stale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmark, options: [.withoutUI],
                relativeTo: nil, bookmarkDataIsStale: &stale
            )
        } catch {
            Self.log(error, stage: "restore")
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) {
                throw ICloudDriveSyncError.savedFolderMissing
            }
            throw ICloudDriveSyncError.bookmarkUnavailable
        }
        return try prepare(LibrarySyncFolderAccess(url: url), bookmark: stale ? nil : bookmark)
    }

    private func prepare(
        _ access: LibrarySyncFolderAccess, bookmark: Data?
    ) throws -> LibrarySyncFolderSelection {
        try Task.checkCancellation()
        do {
            guard try access.url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw ICloudDriveSyncError.folderUnavailable
            }
        } catch {
            Self.log(error, stage: "inspect")
            throw ICloudDriveSyncError.folderUnavailable
        }
        let data = try bookmark ?? createBookmark(for: access.url)
        try Task.checkCancellation()
        return LibrarySyncFolderSelection(access: access, bookmark: data)
    }

    private func createBookmark(for url: URL) throws -> Data? {
        #if os(iOS)
        // Apple's directory-picker sample uses a minimal bookmark on iOS.
        // Some providers cannot create that form; try the public default once.
        do {
            return try url.bookmarkData(
                options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil
            )
        } catch {
            Self.log(error, stage: "save-minimal")
        }
        try Task.checkCancellation()
        #endif
        do {
            return try url.bookmarkData(
                options: [], includingResourceValuesForKeys: nil, relativeTo: nil
            )
        } catch {
            Self.log(error, stage: "save-default")
            // The live grant is still owned by LibrarySyncFolderAccess. Let the
            // controller validate the connection and use it for this session.
            return nil
        }
    }

    /// Log only fixed stages, known system domains, and numeric error codes.
    /// Provider descriptions and userInfo may contain private paths or accounts.
    private static func log(_ error: Error, stage: String) {
        var current = error as NSError
        for depth in 0..<3 {
            let domain: String
            switch current.domain {
            case NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain,
                 NSURLErrorDomain, NSMachErrorDomain, "NSFileProviderErrorDomain":
                domain = current.domain
            default:
                domain = "Other"
            }
            logger.error("Folder permission: stage=\(stage, privacy: .public) depth=\(depth) domain=\(domain, privacy: .public) code=\(current.code)")
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            current = underlying
        }
    }
}
