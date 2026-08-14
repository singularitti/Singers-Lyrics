import Foundation

protocol LibraryStoring: Sendable {
    func load() async throws -> LibraryDocument
    func save(_ document: LibraryDocument) async throws
}

enum LibraryStoreError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case corruptLibrary(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            "This library uses unsupported schema version \(version)."
        case .corruptLibrary:
            "The song library could not be read. The original file has been left unchanged."
        }
    }

    var recoverySuggestion: String? {
        "Reveal the library in Finder and preserve or repair it before trying again."
    }
}

actor JSONLibraryStore: LibraryStoring {
    static let bundleIdentifier = "app.singerslyrics.SingersLyrics"

    let fileURL: URL
    private let fileManager: FileManager

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
        guard fileManager.fileExists(atPath: fileURL.path) else {
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
            let document = try decoder.decode(LibraryDocument.self, from: data)
            guard document.schemaVersion == LibraryDocument.currentSchemaVersion else {
                throw LibraryStoreError.unsupportedSchema(document.schemaVersion)
            }
            return document
        } catch let error as LibraryStoreError {
            throw error
        } catch {
            throw LibraryStoreError.corruptLibrary(error.localizedDescription)
        }
    }

    func save(_ document: LibraryDocument) async throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(LibraryDateCodec.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        try data.write(to: fileURL, options: [.atomic])
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
}
