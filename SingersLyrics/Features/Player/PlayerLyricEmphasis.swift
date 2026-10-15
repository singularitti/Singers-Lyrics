import SwiftUI

/// Share one readable dimmed state across platforms, including untimed lyrics
/// and the intro before the first cue.
enum PlayerLyricEmphasis {
    static func opacity(isActive: Bool) -> Double {
        isActive ? 1 : 0.42
    }
}

/// Measure one scaled lyric block's rendered height while keeping its intrinsic
/// width stable, so emphasis doesn't resize the horizontal scrolling canvas.
struct PlayerLyricScaleLayout: Layout {
    var scale: CGFloat
    var anchor: UnitPoint

    var animatableData: CGFloat {
        get { scale }
        set { scale = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let block = subviews.first else { return .zero }
        let size = block.sizeThatFits(proposal)
        return CGSize(width: size.width, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let block = subviews.first else { return }
        let size = block.sizeThatFits(proposal)
        block.place(
            at: CGPoint(x: bounds.minX + bounds.width * anchor.x, y: bounds.midY),
            anchor: anchor,
            proposal: ProposedViewSize(width: size.width, height: size.height)
        )
    }
}
