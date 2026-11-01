import SwiftUI

/// Keep annotations proportional to the lyrics in both editing and playback.
enum LyricTypography {
    // A 24-point lyric leaves its half-size annotation readable at 12 points.
    static let editorLyricSize: CGFloat = 24

    #if os(macOS)
    static let editorTextInset: CGFloat = 2
    #else
    static let editorTextInset: CGFloat = 1
    #endif

    static func annotationSize(for lyricSize: CGFloat) -> CGFloat {
        lyricSize * 0.5
    }

    static func annotationFont(for lyricSize: CGFloat) -> Font {
        .system(size: annotationSize(for: lyricSize)).italic()
    }
}
