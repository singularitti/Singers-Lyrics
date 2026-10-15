import SwiftUI

/// Share one readable dimmed state across platforms, including untimed lyrics
/// and the intro before the first cue.
enum PlayerLyricEmphasis {
    static let activeScale: CGFloat = 1.08
    static let motionAnimation = Animation.interpolatingSpring(stiffness: 90, damping: 20)
    static let highlightAnimation = Animation.easeOut(duration: 0.4)

    static func scale(isActive: Bool) -> CGFloat {
        isActive ? activeScale : 0.96
    }

    static func opacity(isActive: Bool) -> Double {
        isActive ? 1 : 0.42
    }
}

/// Reserve the emphasized height at every cue so scaling never moves neighboring
/// rows or changes an in-flight auto-scroll target. Keep intrinsic width stable.
struct PlayerLyricScaleLayout: Layout {
    var maximumScale: CGFloat
    var anchor: UnitPoint

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let block = subviews.first else { return .zero }
        let size = block.sizeThatFits(proposal)
        return CGSize(width: size.width, height: size.height * maximumScale)
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
