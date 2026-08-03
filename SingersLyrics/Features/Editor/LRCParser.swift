import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum LRCParser {
    private static let timestampExpression = try! NSRegularExpression(
        pattern: #"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]"#
    )
    private static let metadataExpression = try! NSRegularExpression(
        pattern: #"^\[[A-Za-z]+:.*\]$"#
    )

    static func parse(_ source: String) -> [LyricLine] {
        let normalizedSource = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var rawLines = normalizedSource.split(separator: "\n", omittingEmptySubsequences: false)

        // A conventional final newline terminates the last LRC row; it does not
        // represent an additional, untimed lyric line.
        if normalizedSource.hasSuffix("\n"), rawLines.last?.isEmpty == true {
            rawLines.removeLast()
        }

        return rawLines.compactMap { parseLine(String($0)) }
    }

    private static func parseLine(_ rawLine: String) -> LyricLine? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        if metadataExpression.firstMatch(in: trimmed, range: fullRange) != nil {
            return nil
        }

        let rawRange = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
        guard let match = timestampExpression.firstMatch(in: rawLine, range: rawRange) else {
            return .blank(text: rawLine.trimmingCharacters(in: .newlines))
        }

        let minutes = integerCapture(1, match: match, source: rawLine)
        let seconds = integerCapture(2, match: match, source: rawLine)
        let fractionText = stringCapture(3, match: match, source: rawLine)
        let milliseconds: Double
        if let fractionText {
            let padded = String((fractionText + "000").prefix(3))
            milliseconds = Double(Int(padded) ?? 0) / 1_000
        } else {
            milliseconds = 0
        }

        let lyric = timestampExpression
            .stringByReplacingMatches(in: rawLine, range: rawRange, withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
        var line = LyricLine.blank(text: lyric)
        line.timestampSeconds = Double(minutes * 60 + seconds) + milliseconds
        return line
    }

    private static func integerCapture(_ index: Int, match: NSTextCheckingResult, source: String) -> Int {
        Int(stringCapture(index, match: match, source: source) ?? "") ?? 0
    }

    private static func stringCapture(_ index: Int, match: NSTextCheckingResult, source: String) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: source) else { return nil }
        return String(source[swiftRange])
    }
}

enum LRCExporter {
    static func render(song: Song) -> String {
        var rows: [String] = []
        if !song.title.isEmpty {
            rows.append("[ti:\(metadataValue(song.title))]")
        }
        if !song.artist.isEmpty {
            rows.append("[ar:\(metadataValue(song.artist))]")
        }
        if !rows.isEmpty, !song.lines.isEmpty {
            rows.append("")
        }

        rows.append(contentsOf: song.lines.map { line in
            guard let timestamp = line.timestampSeconds, timestamp.isFinite else {
                return line.lyric.plainText
            }
            let totalCentiseconds = Int((max(0, timestamp) * 100).rounded())
            let minutes = totalCentiseconds / 6_000
            let seconds = (totalCentiseconds % 6_000) / 100
            let centiseconds = totalCentiseconds % 100
            return String(
                format: "[%02d:%02d.%02d]%@",
                minutes,
                seconds,
                centiseconds,
                line.lyric.plainText
            )
        })
        return rows.joined(separator: "\n") + "\n"
    }

    private static func metadataValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}

extension UTType {
    static let lrcLyrics = UTType(
        exportedAs: "com.singularitti.singers-lyrics.lrc",
        conformingTo: .plainText
    )
}

struct LRCFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.lrcLyrics, .plainText] }

    var text: String

    init(song: Song) {
        text = LRCExporter.render(song: song)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
