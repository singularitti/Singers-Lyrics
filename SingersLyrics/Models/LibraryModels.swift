import Foundation

struct LibraryDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var songs: [Song]
    var trashedRecordings: [TrashedRecording]
    var trashedSongs: [TrashedSong]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        songs: [Song] = [],
        trashedRecordings: [TrashedRecording] = [],
        trashedSongs: [TrashedSong] = []
    ) {
        self.schemaVersion = schemaVersion
        self.songs = songs
        self.trashedRecordings = trashedRecordings
        self.trashedSongs = trashedSongs
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, songs, trashedRecordings, trashedSongs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            songs: try container.decode([Song].self, forKey: .songs),
            trashedRecordings: try container.decodeIfPresent(
                [TrashedRecording].self, forKey: .trashedRecordings
            ) ?? [],
            trashedSongs: try container.decodeIfPresent([TrashedSong].self, forKey: .trashedSongs) ?? []
        )
    }
}

struct Song: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var artist: String
    var album: String
    var tags: [String]
    var isFavorite: Bool
    var lastPlayedAt: Date?
    var appleMusicURL: URL?
    var linkedTrackMetadata: TrackMetadata?
    var lines: [LyricLine]
    var createdAt: Date
    var updatedAt: Date

    var playbackMetadata: TrackMetadata {
        linkedTrackMetadata ?? TrackMetadata(title: title, artist: artist, album: album)
    }

    init(
        id: UUID,
        title: String,
        artist: String,
        album: String = "",
        tags: [String] = [],
        isFavorite: Bool = false,
        lastPlayedAt: Date? = nil,
        appleMusicURL: URL?,
        linkedTrackMetadata: TrackMetadata? = nil,
        lines: [LyricLine],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.tags = Self.normalizedTags(tags)
        self.isFavorite = isFavorite
        self.lastPlayedAt = lastPlayedAt
        self.appleMusicURL = appleMusicURL
        self.linkedTrackMetadata = linkedTrackMetadata
        self.lines = lines
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case artist
        case album
        case tags
        case isFavorite
        case lastPlayedAt
        case appleMusicURL
        case linkedTrackMetadata
        case lines
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            title: try container.decode(String.self, forKey: .title),
            artist: try container.decode(String.self, forKey: .artist),
            album: try container.decodeIfPresent(String.self, forKey: .album) ?? "",
            tags: try container.decodeIfPresent([String].self, forKey: .tags) ?? [],
            isFavorite: try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false,
            lastPlayedAt: try container.decodeIfPresent(Date.self, forKey: .lastPlayedAt),
            appleMusicURL: try container.decodeIfPresent(URL.self, forKey: .appleMusicURL),
            linkedTrackMetadata: try container.decodeIfPresent(
                TrackMetadata.self,
                forKey: .linkedTrackMetadata
            ),
            lines: try container.decode([LyricLine].self, forKey: .lines),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt)
        )
    }

    static func normalizedTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        return tags.compactMap { tag in
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let comparisonKey = trimmed.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard seen.insert(comparisonKey).inserted else { return nil }
            return trimmed
        }
    }

    static func blank(now: Date = Date()) -> Song {
        Song(
            id: UUID(),
            title: "Untitled",
            artist: "",
            album: "",
            tags: [],
            appleMusicURL: nil,
            lines: [.blank()],
            createdAt: now,
            updatedAt: now
        )
    }
}

struct TrashedSong: Codable, Equatable, Identifiable, Sendable {
    var song: Song
    var deletedAt: Date
    var originalIndex: Int
    var siblingOrder: [UUID]
    var isPendingPermanentDeletion: Bool

    var id: UUID { song.id }

    init(
        song: Song,
        deletedAt: Date = Date(),
        originalIndex: Int = 0,
        siblingOrder: [UUID] = [],
        isPendingPermanentDeletion: Bool = false
    ) {
        self.song = song
        self.deletedAt = deletedAt
        self.originalIndex = max(0, originalIndex)
        self.siblingOrder = siblingOrder
        self.isPendingPermanentDeletion = isPendingPermanentDeletion
    }

    private enum CodingKeys: String, CodingKey {
        case song, deletedAt, originalIndex, siblingOrder, isPendingPermanentDeletion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let song = try container.decode(Song.self, forKey: .song)
        self.init(
            song: song,
            deletedAt: try container.decodeIfPresent(Date.self, forKey: .deletedAt) ?? song.updatedAt,
            originalIndex: try container.decodeIfPresent(Int.self, forKey: .originalIndex) ?? 0,
            siblingOrder: try container.decodeIfPresent([UUID].self, forKey: .siblingOrder) ?? [],
            isPendingPermanentDeletion: try container.decodeIfPresent(
                Bool.self, forKey: .isPendingPermanentDeletion
            ) ?? false
        )
    }
}

struct VoiceRecording: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date
    var duration: Double
    var audioData: Data

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        duration: Double,
        audioData: Data
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.duration = duration
        self.audioData = audioData
    }

    // Audio belongs in the recording asset tree, never in JSON metadata.
    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, duration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            duration: try container.decode(Double.self, forKey: .duration),
            audioData: Data()
        )
    }
}

struct TrashedRecording: Codable, Equatable, Identifiable, Sendable {
    var recording: VoiceRecording
    var songID: UUID
    var lineID: UUID
    var songTitle: String
    var songArtist: String
    var lyricText: String
    var annotation: String
    var deletedAt: Date
    var isPendingPermanentDeletion: Bool
    var restorationContext: RecordingRestorationContext?

    var id: UUID { recording.id }

    init(
        recording: VoiceRecording,
        songID: UUID,
        lineID: UUID,
        songTitle: String,
        songArtist: String,
        lyricText: String,
        annotation: String,
        deletedAt: Date,
        isPendingPermanentDeletion: Bool = false,
        restorationContext: RecordingRestorationContext? = nil
    ) {
        self.recording = recording
        self.songID = songID
        self.lineID = lineID
        self.songTitle = songTitle
        self.songArtist = songArtist
        self.lyricText = lyricText
        self.annotation = annotation
        self.deletedAt = deletedAt
        self.isPendingPermanentDeletion = isPendingPermanentDeletion
        self.restorationContext = restorationContext
    }

    private enum CodingKeys: String, CodingKey {
        case recording, songID, lineID, songTitle, songArtist, lyricText, annotation
        case deletedAt, isPendingPermanentDeletion
        case restorationContext
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            recording: try container.decode(VoiceRecording.self, forKey: .recording),
            songID: try container.decode(UUID.self, forKey: .songID),
            lineID: try container.decode(UUID.self, forKey: .lineID),
            songTitle: try container.decode(String.self, forKey: .songTitle),
            songArtist: try container.decode(String.self, forKey: .songArtist),
            lyricText: try container.decode(String.self, forKey: .lyricText),
            annotation: try container.decode(String.self, forKey: .annotation),
            deletedAt: try container.decode(Date.self, forKey: .deletedAt),
            isPendingPermanentDeletion: try container.decodeIfPresent(
                Bool.self, forKey: .isPendingPermanentDeletion
            ) ?? false,
            restorationContext: try container.decodeIfPresent(
                RecordingRestorationContext.self, forKey: .restorationContext
            )
        )
    }
}

/// A small ownership snapshot for restoring a deleted lyric line or song. It
/// contains rich lyric styling and song metadata, but never sibling lines or audio.
struct RecordingRestorationContext: Codable, Equatable, Sendable {
    var song: Song
    var line: LyricLine
    var lineIndex: Int
    var songIndex: Int?
    var lineOrder: [UUID]
    var songOrder: [UUID]

    init(
        song: Song,
        line: LyricLine,
        lineIndex: Int,
        songIndex: Int? = nil,
        lineOrder: [UUID] = [],
        songOrder: [UUID] = []
    ) {
        var metadata = song
        metadata.lines = []
        var lyric = line
        lyric.recordings = []
        lyric.selectedRecordingID = nil
        self.song = metadata
        self.line = lyric
        self.lineIndex = max(0, lineIndex)
        self.songIndex = songIndex.map { max(0, $0) }
        self.lineOrder = lineOrder
        self.songOrder = songOrder
    }

    private enum CodingKeys: String, CodingKey {
        case song, line, lineIndex, songIndex, lineOrder, songOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            song: try container.decode(Song.self, forKey: .song),
            line: try container.decode(LyricLine.self, forKey: .line),
            lineIndex: try container.decodeIfPresent(Int.self, forKey: .lineIndex) ?? 0,
            songIndex: try container.decodeIfPresent(Int.self, forKey: .songIndex),
            lineOrder: try container.decodeIfPresent([UUID].self, forKey: .lineOrder) ?? [],
            songOrder: try container.decodeIfPresent([UUID].self, forKey: .songOrder) ?? []
        )
    }
}

struct LyricLine: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var annotation: String
    var lyric: StyledText
    var timestampSeconds: Double?
    var recordings: [VoiceRecording]
    var selectedRecordingID: UUID?

    var selectedRecording: VoiceRecording? {
        if let selectedRecordingID,
           let selected = recordings.first(where: { $0.id == selectedRecordingID }) {
            return selected
        }
        return recordings.enumerated().max { lhs, rhs in
            if lhs.element.createdAt == rhs.element.createdAt {
                return lhs.offset < rhs.offset
            }
            return lhs.element.createdAt < rhs.element.createdAt
        }?.element
    }

    init(
        id: UUID,
        annotation: String,
        lyric: StyledText,
        timestampSeconds: Double?,
        recordings: [VoiceRecording] = [],
        selectedRecordingID: UUID? = nil
    ) {
        self.id = id
        self.annotation = annotation
        self.lyric = lyric
        self.timestampSeconds = timestampSeconds
        self.recordings = recordings
        self.selectedRecordingID = selectedRecordingID
    }

    private enum CodingKeys: String, CodingKey {
        case id, annotation, lyric, timestampSeconds, recordings, selectedRecordingID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            annotation: try container.decode(String.self, forKey: .annotation),
            lyric: try container.decode(StyledText.self, forKey: .lyric),
            timestampSeconds: try container.decodeIfPresent(Double.self, forKey: .timestampSeconds),
            recordings: try container.decodeIfPresent([VoiceRecording].self, forKey: .recordings) ?? [],
            selectedRecordingID: try container.decodeIfPresent(UUID.self, forKey: .selectedRecordingID)
        )
    }

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
    case artist
    case title
    case album
    case dateAdded
    case dateModified

    var title: String {
        switch self {
        case .artist: "Singer"
        case .title: "Title"
        case .album: "Album"
        case .dateAdded: "Date Added"
        case .dateModified: "Date Modified"
        }
    }

    func sorted(_ songs: [Song]) -> [Song] {
        songs.sorted { lhs, rhs in
            switch self {
            case .dateAdded:
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt > rhs.createdAt
                }
            case .dateModified:
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
            case .artist, .title, .album:
                break
            }

            let lhsKeys: [String]
            let rhsKeys: [String]
            switch self {
            case .artist:
                lhsKeys = [lhs.artist, lhs.title, lhs.album]
                rhsKeys = [rhs.artist, rhs.title, rhs.album]
            case .title:
                lhsKeys = [lhs.title, lhs.artist, lhs.album]
                rhsKeys = [rhs.title, rhs.artist, rhs.album]
            case .album:
                lhsKeys = [lhs.album, lhs.title, lhs.artist]
                rhsKeys = [rhs.album, rhs.title, rhs.artist]
            case .dateAdded, .dateModified:
                lhsKeys = [lhs.title, lhs.artist, lhs.album]
                rhsKeys = [rhs.title, rhs.artist, rhs.album]
            }

            for (lhsKey, rhsKey) in zip(lhsKeys, rhsKeys) {
                let lhsIsEmpty = lhsKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let rhsIsEmpty = rhsKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if lhsIsEmpty != rhsIsEmpty {
                    return !lhsIsEmpty
                }
                switch lhsKey.localizedStandardCompare(rhsKey) {
                case .orderedAscending:
                    return true
                case .orderedDescending:
                    return false
                case .orderedSame:
                    continue
                }
            }
            return lhs.id.uuidString < rhs.id.uuidString
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
    var actionFailed = false
    var failure: MusicPlaybackFailure? = nil
}

struct TrackMetadata: Codable, Equatable, Sendable {
    var title: String
    var artist: String
    var album: String

    init(title: String, artist: String, album: String = "") {
        self.title = title
        self.artist = artist
        self.album = album
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case artist
        case album
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decode(String.self, forKey: .artist)
        album = try container.decodeIfPresent(String.self, forKey: .album) ?? ""
    }
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

/// Player transport times use –:–– until playback reports the song's length.
func formatPlaybackTime(_ seconds: Double?) -> String {
    seconds.map(formatTime) ?? "–:––"
}
