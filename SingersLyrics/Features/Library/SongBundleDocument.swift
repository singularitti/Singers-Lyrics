import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct SongBundle: Codable, Equatable, Sendable {
    static let formatIdentifier = "app.singerslyrics.song-bundle"
    static let currentFormatVersion = 1

    var format: String
    var formatVersion: Int
    var songs: [Song]

    init(
        format: String = Self.formatIdentifier,
        formatVersion: Int = Self.currentFormatVersion,
        songs: [Song]
    ) {
        self.format = format
        self.formatVersion = formatVersion
        self.songs = songs
    }
}

enum SongBundleError: LocalizedError, Equatable {
    case invalidFormat
    case unsupportedVersion(Int)
    case noSongs
    case duplicateSongIDs
    case duplicateLineIDs
    case couldNotEncode
    case corruptFile

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            "This is not a Singers Lyrics song bundle."
        case .unsupportedVersion(let version):
            "This song bundle uses unsupported format version \(version)."
        case .noSongs:
            "This song bundle does not contain any songs."
        case .duplicateSongIDs, .duplicateLineIDs:
            "This song bundle contains duplicate identifiers and cannot be imported safely."
        case .couldNotEncode:
            "The selected songs could not be written to a song bundle."
        case .corruptFile:
            "The song bundle is incomplete or damaged."
        }
    }
}

enum SongBundleCodec {
    static func encode(_ bundle: SongBundle) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(LibraryDateCodec.string(from: date))
            }
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(bundle)
        } catch {
            throw SongBundleError.couldNotEncode
        }
    }

    static func decode(_ data: Data) throws -> SongBundle {
        let bundle: SongBundle
        do {
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
            bundle = try decoder.decode(SongBundle.self, from: data)
        } catch let error as SongBundleError {
            throw error
        } catch {
            throw SongBundleError.corruptFile
        }

        guard bundle.format == SongBundle.formatIdentifier else {
            throw SongBundleError.invalidFormat
        }
        guard bundle.formatVersion == SongBundle.currentFormatVersion else {
            throw SongBundleError.unsupportedVersion(bundle.formatVersion)
        }
        guard !bundle.songs.isEmpty else {
            throw SongBundleError.noSongs
        }

        let songIDs = bundle.songs.map(\.id)
        guard Set(songIDs).count == songIDs.count else {
            throw SongBundleError.duplicateSongIDs
        }
        let lineIDs = bundle.songs.flatMap { $0.lines.map(\.id) }
        guard Set(lineIDs).count == lineIDs.count else {
            throw SongBundleError.duplicateLineIDs
        }

        return bundle
    }
}

extension UTType {
    static let singersLyricsSongBundle = UTType(
        exportedAs: "app.singerslyrics.song-bundle",
        conformingTo: .json
    )
}

struct SongBundleFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.singersLyricsSongBundle] }

    var bundle: SongBundle

    init(bundle: SongBundle) {
        self.bundle = bundle
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw SongBundleError.corruptFile
        }
        bundle = try SongBundleCodec.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try SongBundleCodec.encode(bundle))
    }
}
