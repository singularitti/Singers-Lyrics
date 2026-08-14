import Foundation

struct LibraryDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var songs: [Song]

    init(schemaVersion: Int = Self.currentSchemaVersion, songs: [Song] = []) {
        self.schemaVersion = schemaVersion
        self.songs = songs
    }
}

struct Song: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var artist: String
    var appleMusicURL: URL?
    var linkedTrackMetadata: TrackMetadata? = nil
    var lines: [LyricLine]
    var createdAt: Date
    var updatedAt: Date

    var playbackMetadata: TrackMetadata {
        linkedTrackMetadata ?? TrackMetadata(title: title, artist: artist)
    }

    static func blank(now: Date = Date()) -> Song {
        Song(
            id: UUID(),
            title: "Untitled",
            artist: "",
            appleMusicURL: nil,
            lines: [.blank()],
            createdAt: now,
            updatedAt: now
        )
    }
}

struct LyricLine: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var annotation: String
    var lyric: StyledText
    var timestampSeconds: Double?

    static func blank(text: String = "") -> LyricLine {
        LyricLine(
            id: UUID(),
            annotation: "",
            lyric: .plain(text),
            timestampSeconds: nil
        )
    }
}

struct StyledText: Codable, Equatable, Sendable {
    var runs: [TextRun]

    static func plain(_ text: String) -> StyledText {
        StyledText(runs: text.isEmpty ? [] : [TextRun(text: text)])
    }

    var plainText: String {
        runs.map(\.text).joined()
    }

    var utf16Count: Int {
        runs.reduce(0) { $0 + ($1.text as NSString).length }
    }

    func normalized() -> StyledText {
        var result: [TextRun] = []
        for run in runs where !run.text.isEmpty {
            if let last = result.last, last.style == run.style {
                result[result.count - 1].text += run.text
            } else {
                result.append(run)
            }
        }
        return StyledText(runs: result)
    }

    func split(atUTF16Offset offset: Int) -> (before: StyledText, after: StyledText) {
        let clampedOffset = max(0, min(offset, utf16Count))
        var consumed = 0
        var beforeRuns: [TextRun] = []
        var afterRuns: [TextRun] = []

        for run in runs {
            let source = run.text as NSString
            let runLength = source.length
            let localOffset = clampedOffset - consumed

            if localOffset <= 0 {
                afterRuns.append(run)
            } else if localOffset >= runLength {
                beforeRuns.append(run)
            } else {
                let prefix = source.substring(with: NSRange(location: 0, length: localOffset))
                let suffix = source.substring(
                    with: NSRange(location: localOffset, length: runLength - localOffset)
                )
                if !prefix.isEmpty {
                    beforeRuns.append(TextRun(text: prefix, style: run.style))
                }
                if !suffix.isEmpty {
                    afterRuns.append(TextRun(text: suffix, style: run.style))
                }
            }
            consumed += runLength
        }

        return (
            StyledText(runs: beforeRuns).normalized(),
            StyledText(runs: afterRuns).normalized()
        )
    }
}

struct TextRun: Codable, Equatable, Sendable {
    var text: String
    var style: TextStyle

    init(text: String, style: TextStyle = .plain) {
        self.text = text
        self.style = style
    }
}

struct TextStyle: Codable, Equatable, Sendable {
    var fontFamily: String?
    var foregroundColor: RGBAColor?
    var bold: Bool
    var italic: Bool
    var underline: Bool

    static let plain = TextStyle(
        fontFamily: nil,
        foregroundColor: nil,
        bold: false,
        italic: false,
        underline: false
    )
}

struct RGBAColor: Codable, Equatable, Hashable, Sendable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init?(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6 || value.count == 8, let number = UInt64(value, radix: 16) else {
            return nil
        }
        if value.count == 6 {
            red = UInt8((number >> 16) & 0xFF)
            green = UInt8((number >> 8) & 0xFF)
            blue = UInt8(number & 0xFF)
            alpha = 255
        } else {
            red = UInt8((number >> 24) & 0xFF)
            green = UInt8((number >> 16) & 0xFF)
            blue = UInt8((number >> 8) & 0xFF)
            alpha = UInt8(number & 0xFF)
        }
    }

    var hex: String {
        String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let color = RGBAColor(hex: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an sRGB color in #RRGGBB or #RRGGBBAA form"
            )
        }
        self = color
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

enum SongSortMode: String, CaseIterable, Codable, Sendable {
    case manual
    case title
    case artist
    case added
    case edited

    var title: String {
        switch self {
        case .manual: "Manual Order"
        case .title: "Title (A–Z)"
        case .artist: "Singer (A–Z)"
        case .added: "Recently Added"
        case .edited: "Recently Edited"
        }
    }

    func sorted(_ songs: [Song]) -> [Song] {
        switch self {
        case .manual:
            songs
        case .title:
            songs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist:
            songs.sorted { $0.artist.localizedStandardCompare($1.artist) == .orderedAscending }
        case .added:
            songs.sorted { $0.createdAt > $1.createdAt }
        case .edited:
            songs.sorted { $0.updatedAt > $1.updatedAt }
        }
    }
}

enum PlaybackState: String, Codable, Sendable {
    case playing
    case paused
    case stopped
}

struct MusicState: Equatable, Sendable {
    var state: PlaybackState = .stopped
    var position: Double = 0
    var duration: Double = 0
    var trackName: String = ""
    var trackArtist: String = ""
    var trackPersistentID: String = ""
    var permissionDenied = false
}

struct TrackMetadata: Codable, Equatable, Sendable {
    var title: String
    var artist: String
}

enum TimingUtilities {
    static func timestamp(forLineAt index: Int, in lines: [LyricLine]) -> Double {
        guard !lines.isEmpty else { return 0 }
        for candidate in stride(from: min(index, lines.count - 1), through: 0, by: -1) {
            if let timestamp = lines[candidate].timestampSeconds {
                return timestamp
            }
        }
        return 0
    }

    static func activeLineIndex(
        in lines: [LyricLine],
        position: Double,
        tolerance: Double = 0.12
    ) -> Int? {
        var active: Int?
        for (index, line) in lines.enumerated() {
            if let timestamp = line.timestampSeconds, timestamp <= position + tolerance {
                active = index
            }
        }
        return active
    }

    static func shifted(_ timestamp: Double?, by delta: Double) -> Double? {
        timestamp.map { max(0, $0 + delta) }
    }

    static func shiftedByPoints(_ timestamp: Double?, points: Double) -> Double {
        max(0, (timestamp ?? 0) + points * 0.01)
    }
}

func formatTime(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite else { return "––:––" }
    let clamped = max(0, seconds)
    let minutes = Int(clamped) / 60
    let remainder = Int(clamped) % 60
    return String(format: "%d:%02d", minutes, remainder)
}
