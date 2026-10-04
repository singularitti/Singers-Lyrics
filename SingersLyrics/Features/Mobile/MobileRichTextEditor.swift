#if os(iOS)
import SwiftUI
import UIKit

@MainActor
struct MobileRichTextEditor: UIViewRepresentable {
    @Binding var value: StyledText
    let lineID: UUID
    let editingContext: MobileEditingContext
    let fallbackFontFamily: String?
    let fontSize: CGFloat
    let preferredTypingStyle: TextStyle?
    let isSelected: Bool
    let focusRequested: Bool
    let onActivate: () -> Void
    let onFocusHandled: () -> Void
    let onEditingChanged: (Bool) -> Void
    let onSplit: (StyledText, StyledText, TextStyle) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    static func dismantleUIView(_ textView: UITextView, coordinator: Coordinator) {
        coordinator.parent.editingContext.remove(textView)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = WindowAwareTextView()
        textView.delegate = context.coordinator
        textView.onWindowChange = { [weak textView, weak coordinator = context.coordinator] in
            guard let textView, let coordinator else { return }
            coordinator.attemptPendingFocus(on: textView)
        }
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 4, left: 1, bottom: 4, right: 1)
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.widthTracksTextView = true
        textView.adjustsFontForContentSizeCategory = false
        textView.autocapitalizationType = .sentences
        textView.autocorrectionType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.allowsEditingTextAttributes = false
        textView.accessibilityLabel = "Lyric line"
        textView.accessibilityIdentifier = "mobileRichText-\(lineID.uuidString)"
        textView.attributedText = makeDisplayText(value)
        if value.plainText.isEmpty {
            textView.typingAttributes = scaledTypingAttributes
        }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        editingContext.fallbackFontFamily = fallbackFontFamily
        textView.accessibilityIdentifier = "mobileRichText-\(lineID.uuidString)"
        let current = AttributedTextCodec.makeStyledText(from: textView.attributedText)
        let appearanceChanged = context.coordinator.lastFontSize != fontSize
            || context.coordinator.lastFallbackFontFamily != fallbackFontFamily
        // Keep UIKit's live selection and marked text intact while this editor owns focus.
        if textView.markedTextRange == nil,
           (current != value && !textView.isFirstResponder || appearanceChanged && current == value) {
            let selection = textView.selectedRange
            context.coordinator.isApplyingModel = true
            textView.attributedText = makeDisplayText(value)
            if value.plainText.isEmpty {
                textView.typingAttributes = scaledTypingAttributes
            }
            textView.selectedRange = NSRange(location: min(selection.location, textView.attributedText.length), length: min(selection.length, max(0, textView.attributedText.length - min(selection.location, textView.attributedText.length))))
            context.coordinator.isApplyingModel = false
        }
        context.coordinator.lastFontSize = fontSize
        context.coordinator.lastFallbackFontFamily = fallbackFontFamily
        if isSelected, !textView.isFirstResponder {
            textView.accessibilityTraits.insert(.selected)
        } else {
            textView.accessibilityTraits.remove(.selected)
        }
        if focusRequested { context.coordinator.requestFocus(on: textView) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        let target = CGSize(width: max(1, width), height: .greatestFiniteMagnitude)
        let measured = uiView.sizeThatFits(target)
        return CGSize(width: target.width, height: max(52, measured.height))
    }

    private func makeDisplayText(_ value: StyledText) -> NSAttributedString {
        // The parent supplies an already scaled Dynamic Type size.
        AttributedTextCodec.makeAttributedString(
            from: value,
            size: fontSize,
            fallbackFontFamily: fallbackFontFamily
        )
    }

    private var scaledTypingAttributes: [NSAttributedString.Key: Any] {
        AttributedTextCodec.makeAttributes(
            from: preferredTypingStyle ?? .plain,
            size: fontSize,
            fallbackFontFamily: fallbackFontFamily
        )
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MobileRichTextEditor
        var isApplyingModel = false
        var pendingFocus = false
        var lastFontSize: CGFloat?
        var lastFallbackFontFamily: String?

        init(parent: MobileRichTextEditor) { self.parent = parent }

        func requestFocus(on textView: UITextView) {
            pendingFocus = true
            attemptPendingFocus(on: textView)
        }

        func attemptPendingFocus(on textView: UITextView) {
            guard pendingFocus, !textView.isFirstResponder, textView.window != nil else { return }
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView, self.pendingFocus, textView.window != nil else { return }
                if textView.becomeFirstResponder() {
                    self.pendingFocus = false
                    self.parent.onFocusHandled()
                }
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onActivate()
            parent.onEditingChanged(true)
            parent.editingContext.attach(textView) { [weak self, weak textView] in
                guard let self, let textView else { return }
                persist(textView)
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingModel else { return }
            parent.value = AttributedTextCodec.makeStyledText(from: textView.attributedText)
            parent.editingContext.editorDidChange(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard textView.isFirstResponder else { return }
            parent.editingContext.selectionDidChange(textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            persist(textView)
            parent.onEditingChanged(false)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n" else { return true }
            let attributed = NSMutableAttributedString(attributedString: textView.attributedText)
            let location = min(range.location, attributed.length)
            let safeRange = NSRange(location: location, length: min(range.length, attributed.length - location))
            var styleAttributes = textView.typingAttributes
            if location > 0 {
                styleAttributes = attributed.attributes(at: location - 1, effectiveRange: nil)
            } else if location < attributed.length {
                styleAttributes = attributed.attributes(at: location, effectiveRange: nil)
            }
            if safeRange.length > 0 { attributed.deleteCharacters(in: safeRange) }
            let styled = AttributedTextCodec.makeStyledText(from: attributed)
            let parts = styled.split(atUTF16Offset: safeRange.location)
            let marker = NSAttributedString(string: "x", attributes: styleAttributes)
            let typingStyle = AttributedTextCodec.makeStyledText(from: marker).runs.first?.style ?? .plain
            isApplyingModel = true
            textView.attributedText = parent.makeDisplayText(parts.before)
            textView.selectedRange = NSRange(location: parts.before.utf16Count, length: 0)
            parent.value = parts.before
            isApplyingModel = false
            parent.onSplit(parts.before, parts.after, typingStyle)
            return false
        }

        private func persist(_ textView: UITextView) {
            guard !isApplyingModel else { return }
            parent.value = AttributedTextCodec.makeStyledText(from: textView.attributedText)
        }
    }
}

@MainActor
private final class WindowAwareTextView: UITextView {
    var onWindowChange: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
    }
}
#endif
