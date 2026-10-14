import Foundation

/// Scheduling and library merging are independent of how snapshots travel
/// between devices. Both backends leave the editable local library intact.
protocol LibrarySyncTransport: Sendable {
    func accountIdentifier() async throws -> String
    func fetch(reusing local: LibraryDocument) async throws -> CloudLibrarySnapshot
    func save(_ document: LibraryDocument, replacing revision: String?) async throws -> CloudLibrarySnapshot
}

extension CloudKitLibraryTransport: LibrarySyncTransport {}
