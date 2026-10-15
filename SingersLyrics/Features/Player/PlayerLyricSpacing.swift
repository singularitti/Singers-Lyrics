import SwiftUI

/// Extra whitespace around an entry is separate from the font's natural line
/// height and the tighter spacing between wrapped lines within that entry.
struct PlayerLyricSpacing {
    let rowPadding: CGFloat
    let wrappedLineSpacing: CGFloat

    init(fontSize: CGFloat) {
        #if os(iOS)
        rowPadding = min(20, max(12, 16 * fontSize / 34))
        #else
        rowPadding = min(18, max(10, 14 * fontSize / 44))
        #endif
        wrappedLineSpacing = min(4, max(2, fontSize * 0.06))
    }
}
