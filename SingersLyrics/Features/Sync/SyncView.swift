import AppKit
import SwiftUI

struct TimingJogWheel: View {
    let valueText: String
    let onShift: (Double) -> Void

    @State private var previousDragWidth = 0.0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
            HStack(spacing: 5) {
                ForEach(0..<17, id: \.self) { index in
                    Capsule()
                        .fill(index == 8 ? Color.accentColor : Color.secondary.opacity(0.45))
                        .frame(width: index == 8 ? 2 : 1, height: index.isMultiple(of: 4) ? 22 : 13)
                }
            }
            Text(valueText)
                .font(.caption.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
        }
        .overlay {
            TimingJogScrollView(onShift: onShift)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let delta = value.translation.width - previousDragWidth
                    previousDragWidth = value.translation.width
                    onShift(delta * 0.01)
                }
                .onEnded { _ in
                    previousDragWidth = 0
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Fine timing adjustment wheel")
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            onShift(direction == .increment ? 0.1 : -0.1)
        }
        .help("Drag horizontally for 0.01 seconds per point, or use a mouse wheel or trackpad")
    }
}

private struct TimingJogScrollView: NSViewRepresentable {
    let onShift: (Double) -> Void

    func makeNSView(context: Context) -> TimingJogNSView {
        let view = TimingJogNSView()
        view.onShift = onShift
        return view
    }

    func updateNSView(_ view: TimingJogNSView, context: Context) {
        view.onShift = onShift
    }
}

private final class TimingJogNSView: NSView {
    var onShift: ((Double) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        NSApp.currentEvent?.type == .scrollWheel ? self : nil
    }

    override func scrollWheel(with event: NSEvent) {
        let horizontal = Double(event.scrollingDeltaX)
        let vertical = Double(event.scrollingDeltaY)
        let primary = abs(horizontal) > abs(vertical) ? horizontal : vertical
        let multiplier = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
        guard primary != 0 else { return }
        onShift?(primary * multiplier)
    }
}
