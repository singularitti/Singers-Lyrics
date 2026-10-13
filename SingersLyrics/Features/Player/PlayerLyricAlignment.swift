import SwiftUI

enum PlayerLyricAlignment: String, CaseIterable {
    case left
    case center
    case right

    var frameAlignment: Alignment {
        switch self {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }

    var textAlignment: TextAlignment {
        switch self {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }

    var scaleAnchor: UnitPoint {
        switch self {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }

    var symbol: String {
        switch self {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        }
    }

    var label: String {
        switch self {
        case .left: "Align lyrics left"
        case .center: "Align lyrics center"
        case .right: "Align lyrics right"
        }
    }
}

/// The lyric determines the block's width, so a longer annotation cannot move
/// a centered or right-aligned lyric. The optional annotation is the first child.
struct PlayerLyricBlockLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        measurements(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let lyric = subviews.last else { return }
        let measured = measurements(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        if subviews.count > 1 {
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: measured.size.width, height: measured.annotationHeight)
            )
            y += measured.annotationHeight + spacing
        }
        lyric.place(
            at: CGPoint(x: bounds.minX, y: y),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: measured.size.width, height: measured.lyricHeight)
        )
    }

    private func measurements(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> (size: CGSize, annotationHeight: CGFloat, lyricHeight: CGFloat) {
        guard let lyric = subviews.last else { return (.zero, 0, 0) }
        let textProposal = ProposedViewSize(width: proposal.width, height: nil)
        let lyricSize = lyric.sizeThatFits(textProposal)
        guard subviews.count > 1 else { return (lyricSize, 0, lyricSize.height) }

        // An annotation on a blank lyric can still use the available width.
        let width = lyricSize.width > 0 ? lyricSize.width : subviews[0].sizeThatFits(textProposal).width
        let annotationSize = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return (
            CGSize(width: width, height: annotationSize.height + spacing + lyricSize.height),
            annotationSize.height,
            lyricSize.height
        )
    }
}

struct PlayerLyricAlignmentControls: View {
    @Binding var selection: PlayerLyricAlignment

    private var buttonSize: CGFloat {
        #if os(iOS)
        44
        #else
        28
        #endif
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PlayerLyricAlignment.allCases, id: \.self) { alignment in
                Button { selection = alignment } label: {
                    Image(systemName: alignment.symbol)
                        .frame(width: buttonSize, height: buttonSize)
                        .foregroundStyle(selection == alignment ? Color.accentColor : Color.primary)
                        .background(
                            selection == alignment ? Color.accentColor.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(alignment.label)
                .accessibilityLabel(alignment.label)
                .accessibilityAddTraits(selection == alignment ? .isSelected : [])
                .accessibilityIdentifier("lyricAlignment-\(alignment.rawValue)")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lyric alignment")
    }
}
