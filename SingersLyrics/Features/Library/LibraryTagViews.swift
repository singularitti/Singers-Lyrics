import Foundation
import SwiftUI

struct TagSummary: Identifiable, Equatable {
    var key: String
    var name: String
    var songCount: Int

    var id: String { key }

    static func summaries(for songs: [Song]) -> [TagSummary] {
        var names: [String: String] = [:]
        var counts: [String: Int] = [:]
        for song in songs {
            var songKeys: Set<String> = []
            for tag in song.tags {
                let key = TagAppearance.normalizedKey(tag)
                guard !key.isEmpty else { continue }
                if names[key] == nil { names[key] = tag }
                songKeys.insert(key)
            }
            for key in songKeys { counts[key, default: 0] += 1 }
        }
        return names.map { TagSummary(key: $0.key, name: $0.value, songCount: counts[$0.key, default: 0]) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

enum TagAppearance {
    private static let locale = Locale(identifier: "en_US_POSIX")
    private static let palette: [Color] = [
        .blue,
        .purple,
        .pink,
        .orange,
        .green,
        .teal,
        .indigo,
        .mint,
        .cyan,
        .red,
    ]

    static func normalizedKey(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCompatibilityMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: locale
            )
            .lowercased(with: locale)
    }

    static func color(for name: String) -> Color {
        let bytes = normalizedKey(name).utf8
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

enum TagChipSize {
    case compact
    case regular

    var font: Font {
        switch self {
        case .compact: .caption2
        case .regular: .caption
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .compact: 5
        case .regular: 7
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .compact: 1
        case .regular: 3
        }
    }
}

struct TagChip: View {
    let name: String
    var size = TagChipSize.compact

    var body: some View {
        let color = TagAppearance.color(for: name)
        Text(name)
            .font(size.font.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .overlay {
                Capsule()
                    .stroke(color.opacity(0.65), lineWidth: 0.75)
            }
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
    }
}
