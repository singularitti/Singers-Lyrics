#if os(macOS)
import AppKit
import SwiftUI

/// A display-only row viewport. The enclosing List retains click and keyboard selection.
@MainActor
struct LibraryRowScrollView<Content: View>: NSViewRepresentable {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> RowScrollView {
        RowScrollView(content: AnyView(content.fixedSize(horizontal: true, vertical: true)))
    }

    func updateNSView(_ view: RowScrollView, context: Context) {
        view.setContent(AnyView(content.fixedSize(horizontal: true, vertical: true)))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RowScrollView, context: Context) -> CGSize? {
        let natural = nsView.measureContent()
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? natural.width
        return CGSize(width: width, height: natural.height)
    }

    @MainActor
    final class RowScrollView: NSScrollView {
        private let hosting: RowHostingView
        private let edgeFadeMask = CAGradientLayer()
        private var measuredSize = NSSize.zero
        private var horizontalGesture = false

        init(content: AnyView) {
            hosting = RowHostingView(rootView: content)
            super.init(frame: .zero)
            borderType = .noBorder
            drawsBackground = false
            hasHorizontalScroller = true
            hasVerticalScroller = false
            autohidesScrollers = true
            scrollerStyle = .overlay
            setAccessibilityIdentifier("libraryRowScrollView")
            horizontalScroller?.setAccessibilityIdentifier("libraryRowHorizontalScroller")
            horizontalScrollElasticity = .none
            verticalScrollElasticity = .none
            automaticallyAdjustsContentInsets = false
            contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            contentView.wantsLayer = true
            edgeFadeMask.startPoint = CGPoint(x: 0, y: 0.5)
            edgeFadeMask.endPoint = CGPoint(x: 1, y: 0.5)
            hosting.sizingOptions = .intrinsicContentSize
            hosting.safeAreaRegions = []
            documentView = hosting
            hosting.onSizeInvalidated = { [weak self] in self?.needsLayout = true }
            _ = measureContent()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var acceptsFirstResponder: Bool { false }

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: measuredSize.height)
        }

        func setContent(_ content: AnyView) {
            hosting.rootView = content
            needsLayout = true
        }

        @discardableResult
        func measureContent() -> NSSize {
            let fitting = hosting.fittingSize
            let size = NSSize(
                width: fitting.width.isFinite ? max(0, ceil(fitting.width)) : 0,
                height: fitting.height.isFinite ? max(0, ceil(fitting.height)) : 0
            )
            if size != measuredSize {
                measuredSize = size
                invalidateIntrinsicContentSize()
            }
            return size
        }

        override func layout() {
            super.layout()
            let natural = measureContent()
            let viewport = contentView.bounds.size
            let documentSize = NSSize(
                // A fixed-size SwiftUI root would center itself in a wider
                // hosting frame. Keep its document at the natural width.
                width: natural.width,
                height: max(natural.height, viewport.height)
            )
            if hosting.frame.size != documentSize { hosting.setFrameSize(documentSize) }
            let maximumX = max(0, documentSize.width - viewport.width)
            let origin = NSPoint(x: min(max(0, contentView.bounds.minX), maximumX), y: 0)
            if contentView.bounds.origin != origin { contentView.scroll(to: origin) }
            reflectScrolledClipView(contentView)
        }

        override func reflectScrolledClipView(_ clipView: NSClipView) {
            super.reflectScrolledClipView(clipView)
            updateEdgeFade()
        }

        private func updateEdgeFade() {
            guard let clipLayer = contentView.layer else { return }
            let viewport = contentView.bounds
            let overflow = max(0, hosting.frame.width - viewport.width)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            guard viewport.width > 0, overflow > 0 else {
                clipLayer.mask = nil
                return
            }

            // Fade only edges with more content beyond them. The mask belongs
            // to the viewport, leaving the selection and scrollbar untouched.
            let offset = min(max(0, viewport.minX), overflow)
            let fadeWidth = min(18, viewport.width / 2)
            let leading = min(fadeWidth, offset) / viewport.width
            let trailing = min(fadeWidth, overflow - offset) / viewport.width
            edgeFadeMask.frame = clipLayer.bounds
            edgeFadeMask.colors = [
                (leading > 0 ? NSColor.clear : NSColor.black).cgColor,
                NSColor.black.cgColor,
                NSColor.black.cgColor,
                (trailing > 0 ? NSColor.clear : NSColor.black).cgColor,
            ]
            edgeFadeMask.locations = [0, NSNumber(value: leading), NSNumber(value: 1 - trailing), 1]
            clipLayer.mask = edgeFadeMask
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let hit = super.hitTest(point) else { return nil }
            if let scroller = horizontalScroller, !scroller.isHidden,
               hit === scroller || hit.isDescendant(of: scroller) {
                return hit
            }
            // Let the List receive ordinary, modified, and contextual clicks directly.
            // Only wheel events need this viewport in their responder path.
            guard NSApp.currentEvent?.type == .scrollWheel else { return nil }
            return self
        }

        override func scrollWheel(with event: NSEvent) {
            let x = abs(event.scrollingDeltaX)
            let y = abs(event.scrollingDeltaY)
            let shiftedWheel = event.modifierFlags.contains(.shift) && y > 0
            if x > 0 || y > 0 { horizontalGesture = x > y || shiftedWheel }

            if horizontalGesture {
                super.scrollWheel(with: event)
            } else {
                // Bypass this horizontal viewport so vertical scrolling reaches the List.
                var ancestor = superview
                while let view = ancestor {
                    if let scrollView = view as? NSScrollView {
                        scrollView.scrollWheel(with: event)
                        break
                    }
                    ancestor = view.superview
                }
            }

            if event.phase.contains(.cancelled) || event.momentumPhase.contains(.ended)
                || event.momentumPhase.contains(.cancelled)
                || (event.phase.isEmpty && event.momentumPhase.isEmpty) {
                horizontalGesture = false
            }
        }
    }

    @MainActor
    private final class RowHostingView: NSHostingView<AnyView> {
        var onSizeInvalidated: (() -> Void)?

        override func invalidateIntrinsicContentSize() {
            super.invalidateIntrinsicContentSize()
            onSizeInvalidated?()
        }
    }
}
#endif
