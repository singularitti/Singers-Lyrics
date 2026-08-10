import AppKit
import SwiftUI

@MainActor
struct RichTextEditor: NSViewRepresentable {
    @Binding var value: StyledText
    let lineID: UUID
    let accessibilityIdentifier: String
    let editingContext: RichTextEditingContext
    let fallbackFontFamily: String?
    let focusRequested: Bool
    let preferredTypingStyle: TextStyle?
    let onActivate: () -> Void
    let onFocusHandled: () -> Void
    let onSplit: (StyledText, StyledText, TextStyle) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        coordinator.parent.editingContext.remove(textView)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false

        let textView = LineTextView()
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 3)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        textView.textStorage?.setAttributedString(
            AttributedTextCodec.makeAttributedString(
                from: value,
                fallbackFontFamily: fallbackFontFamily
            )
        )
        if value.plainText.isEmpty {
            textView.typingAttributes = AttributedTextCodec.makeAttributes(
                from: preferredTypingStyle ?? .plain,
                fallbackFontFamily: fallbackFontFamily
            )
        }
        textView.onReturn = { [weak coordinator = context.coordinator, weak textView] range in
            guard let coordinator, let textView else { return }
            coordinator.split(textView: textView, selection: range)
        }
        textView.onBecomeFirstResponder = { [weak coordinator = context.coordinator, weak textView] in
            guard let coordinator, let textView else { return }
            coordinator.activate(textView)
        }
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? LineTextView else { return }
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        let current = AttributedTextCodec.makeStyledText(from: textView.attributedString())
        if current != value, textView.window?.firstResponder !== textView {
            context.coordinator.isApplyingModel = true
            textView.textStorage?.setAttributedString(
                AttributedTextCodec.makeAttributedString(
                    from: value,
                    fallbackFontFamily: fallbackFontFamily
                )
            )
            if value.plainText.isEmpty {
                textView.typingAttributes = AttributedTextCodec.makeAttributes(
                    from: preferredTypingStyle ?? .plain,
                    fallbackFontFamily: fallbackFontFamily
                )
            }
            context.coordinator.isApplyingModel = false
        }
        if focusRequested, textView.window?.firstResponder !== textView {
            Task { @MainActor [weak coordinator = context.coordinator, weak textView] in
                guard let coordinator, let textView, coordinator.parent.focusRequested else { return }
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                if let preferredTypingStyle = coordinator.parent.preferredTypingStyle,
                   coordinator.parent.value.plainText.isEmpty {
                    textView.typingAttributes = AttributedTextCodec.makeAttributes(
                        from: preferredTypingStyle,
                        fallbackFontFamily: coordinator.parent.fallbackFontFamily
                    )
                    coordinator.parent.editingContext.selectionDidChange(in: textView)
                }
                coordinator.parent.onFocusHandled()
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = nsView.documentView as? NSTextView else { return nil }
        let proposedWidth = proposal.width ?? 400
        let width = proposedWidth.isFinite ? max(100, proposedWidth) : 400
        textView.frame.size.width = width
        textView.textContainer?.containerSize = NSSize(width: width - 4, height: .greatestFiniteMagnitude)
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 24
        return CGSize(width: width, height: max(30, used + textView.textContainerInset.height * 2))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        weak var textView: NSTextView?
        var isApplyingModel = false

        init(parent: RichTextEditor) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            activate(textView)
        }

        func activate(_ textView: NSTextView) {
            parent.onActivate()
            parent.editingContext.attach(textView) { [weak self, weak textView] in
                guard let self, let textView else { return }
                persist(textView)
            }
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.editingContext.detach(textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            activate(textView)
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingModel, let textView = notification.object as? NSTextView else { return }
            persist(textView)
            parent.editingContext.editorDidChange(in: textView)
        }

        private func persist(_ textView: NSTextView) {
            guard !isApplyingModel else { return }
            parent.value = AttributedTextCodec.makeStyledText(from: textView.attributedString())
        }

        func split(textView: NSTextView, selection: NSRange) {
            let edited = NSMutableAttributedString(attributedString: textView.attributedString())
            let validSelection = NSIntersectionRange(
                selection,
                NSRange(location: 0, length: edited.length)
            )
            let typingStyle = styleForNewLine(
                in: textView,
                selection: validSelection
            )
            if validSelection.length > 0 {
                edited.deleteCharacters(in: validSelection)
            }
            let styled = AttributedTextCodec.makeStyledText(from: edited)
            let parts = styled.split(atUTF16Offset: validSelection.location)
            parent.onSplit(parts.before, parts.after, typingStyle)
        }

        private func styleForNewLine(
            in textView: NSTextView,
            selection: NSRange
        ) -> TextStyle {
            let attributes: [NSAttributedString.Key: Any]
            if selection.location > 0, let storage = textView.textStorage {
                attributes = storage.attributes(at: selection.location - 1, effectiveRange: nil)
            } else if selection.location < textView.attributedString().length,
                      let storage = textView.textStorage {
                attributes = storage.attributes(at: selection.location, effectiveRange: nil)
            } else {
                attributes = textView.typingAttributes
            }
            let marker = NSAttributedString(string: "x", attributes: attributes)
            return AttributedTextCodec.makeStyledText(from: marker).runs.first?.style ?? .plain
        }
    }
}

@MainActor
private final class LineTextView: NSTextView {
    var onReturn: ((NSRange) -> Void)?
    var onBecomeFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let becameFirstResponder = super.becomeFirstResponder()
        if becameFirstResponder {
            onBecomeFirstResponder?()
        }
        return becameFirstResponder
    }

    override func keyDown(with event: NSEvent) {
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        if (event.keyCode == 36 || event.keyCode == 76),
           event.modifierFlags.intersection(disallowedModifiers).isEmpty {
            onReturn?(selectedRange())
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        guard let string = NSPasteboard.general.string(forType: .string) else { return }
        let singleLine = string.replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression)
        let range = selectedRange()
        textStorage?.replaceCharacters(
            in: range,
            with: NSAttributedString(string: singleLine, attributes: typingAttributes)
        )
        setSelectedRange(NSRange(location: range.location + (singleLine as NSString).length, length: 0))
        didChangeText()
    }
}
