import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct SongBundle: Codable, Equatable, Sendable {
    static let formatIdentifier = "app.singerslyrics.song-bundle"
    static let currentFormatVersion = 2

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
    case duplicateRecordingIDs
    case invalidRecording
    case invalidSelectedRecordingID
    case packageRequired
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
        case .duplicateSongIDs, .duplicateLineIDs, .duplicateRecordingIDs:
            "This song bundle contains duplicate identifiers and cannot be imported safely."
        case .invalidRecording:
            "This song bundle contains invalid recording metadata or missing audio."
        case .invalidSelectedRecordingID:
            "This song bundle selects a recording that does not belong to its lyric line."
        case .packageRequired:
            "Choose a Singers Lyrics document package. Legacy JSON song exports are not supported."
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

        try validateRecordings(in: bundle, requireAudio: false)

        return bundle
    }

    /// JSON is metadata only. Portable documents must use the package API so
    /// every recording travels alongside the manifest.
    static func fileWrapper(for bundle: SongBundle) throws -> FileWrapper {
        guard bundle.format == SongBundle.formatIdentifier else {
            throw SongBundleError.invalidFormat
        }
        guard bundle.formatVersion == SongBundle.currentFormatVersion else {
            throw SongBundleError.unsupportedVersion(bundle.formatVersion)
        }
        guard !bundle.songs.isEmpty else { throw SongBundleError.noSongs }
        try validateRecordings(in: bundle, requireAudio: true)

        let root = FileWrapper(directoryWithFileWrappers: [
            "manifest.json": FileWrapper(regularFileWithContents: try encode(bundle)),
            "recordings": FileWrapper(directoryWithFileWrappers: [:])
        ])
        for asset in RecordingAssetStorage.assets(in: bundle.songs) {
            var directory = root
            for component in asset.components.dropLast() {
                if let existing = directory.fileWrappers?[component] {
                    directory = existing
                } else {
                    let child = FileWrapper(directoryWithFileWrappers: [:])
                    child.preferredFilename = component
                    directory.addFileWrapper(child)
                    directory = child
                }
            }
            let audio = FileWrapper(regularFileWithContents: asset.data)
            audio.preferredFilename = asset.components.last
            directory.addFileWrapper(audio)
        }
        return root
    }

    static func decode(fileWrapper: FileWrapper) throws -> SongBundle {
        guard fileWrapper.isDirectory, !fileWrapper.isSymbolicLink else {
            throw SongBundleError.packageRequired
        }
        guard let manifest = fileWrapper.fileWrappers?["manifest.json"],
              manifest.isRegularFile, !manifest.isSymbolicLink,
              let data = manifest.regularFileContents,
              let recordings = fileWrapper.fileWrappers?["recordings"],
              recordings.isDirectory, !recordings.isSymbolicLink else {
            throw SongBundleError.corruptFile
        }
        var bundle = try decode(data)
        do {
            try RecordingAssetStorage.hydrate(songs: &bundle.songs) { components in
                var directory = fileWrapper
                for component in components.dropLast() {
                    guard let child = directory.fileWrappers?[component],
                          child.isDirectory, !child.isSymbolicLink else {
                        throw RecordingAssetError.invalidAsset
                    }
                    directory = child
                }
                guard let filename = components.last,
                      let audio = directory.fileWrappers?[filename],
                      audio.isRegularFile, !audio.isSymbolicLink,
                      let audioData = audio.regularFileContents else {
                    throw RecordingAssetError.invalidAsset
                }
                return audioData
            }
        } catch {
            throw SongBundleError.invalidRecording
        }
        return bundle
    }

    static func decode(contentsOf url: URL) throws -> SongBundle {
        let fileManager = FileManager.default
        // Read only manifest-referenced files and check each filesystem component
        // before opening it. Unrelated package contents are never followed.
        do {
            try RecordingAssetStorage.requireDirectory(at: url, fileManager: fileManager, create: false)
        } catch {
            throw SongBundleError.packageRequired
        }
        let manifestURL = url.appending(path: "manifest.json", directoryHint: .notDirectory)
        let data: Data
        do {
            try RecordingAssetStorage.requireRegularFile(at: manifestURL, fileManager: fileManager)
            try RecordingAssetStorage.requireDirectory(
                at: url.appending(path: "recordings", directoryHint: .isDirectory),
                fileManager: fileManager,
                create: false
            )
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw SongBundleError.corruptFile
        }
        var bundle = try decode(data)
        do {
            try RecordingAssetStorage.hydrate(songs: &bundle.songs) { components in
                let assetURL = try RecordingAssetStorage.assetURL(
                    components: components,
                    baseURL: url,
                    fileManager: fileManager,
                    createDirectories: false
                )
                try RecordingAssetStorage.requireRegularFile(at: assetURL, fileManager: fileManager)
                return try Data(contentsOf: assetURL)
            }
        } catch {
            throw SongBundleError.invalidRecording
        }
        return bundle
    }

    private static func validateRecordings(in bundle: SongBundle, requireAudio: Bool) throws {
        do {
            try RecordingAssetStorage.validate(songs: bundle.songs, requireAudio: requireAudio)
        } catch RecordingAssetError.duplicateSongIDs {
            throw SongBundleError.duplicateSongIDs
        } catch RecordingAssetError.duplicateLineIDs {
            throw SongBundleError.duplicateLineIDs
        } catch RecordingAssetError.duplicateRecordingIDs {
            throw SongBundleError.duplicateRecordingIDs
        } catch RecordingAssetError.invalidSelection {
            throw SongBundleError.invalidSelectedRecordingID
        } catch {
            throw SongBundleError.invalidRecording
        }
    }
}

extension UTType {
    static let singersLyricsSongBundle = UTType(
        exportedAs: "app.singerslyrics.song-bundle",
        conformingTo: .package
    )
}

struct SongBundleFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.singersLyricsSongBundle] }

    var bundle: SongBundle

    init(bundle: SongBundle) {
        self.bundle = bundle
    }

    init(configuration: ReadConfiguration) throws {
        bundle = try SongBundleCodec.decode(fileWrapper: configuration.file)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try SongBundleCodec.fileWrapper(for: bundle)
    }
}
