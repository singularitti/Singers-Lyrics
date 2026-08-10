import AppKit
import CoreText
import Observation

struct FormattingWarning: Identifiable, Equatable {
    let id = UUID()
    var fontFamily: String
    var traitName: String

    var message: String {
        "“\(fontFamily)” does not provide a \(traitName.lowercased()) face. Choose another font or remove that style first."
    }
}

@MainActor
@Observable
final class RichTextEditingContext {
    @ObservationIgnored private weak var textView: NSTextView?
    @ObservationIgnored private var savedRange = NSRange(location: 0, length: 0)
    @ObservationIgnored private var onFormattingChange: (() -> Void)?

    private(set) var hasActiveEditor = false
    private(set) var isBold = false
    private(set) var isItalic = false
    private(set) var isUnderlined = false
    private(set) var selectedTextColor: RGBAColor?
    private(set) var canUndo = false
    private(set) var canRedo = false
    var warning: FormattingWarning?

    var isEditorFirstResponder: Bool {
        guard let textView else { return false }
        return textView.window?.firstResponder === textView
    }

    func attach(_ textView: NSTextView, onFormattingChange: (() -> Void)? = nil) {
        self.textView = textView
        self.onFormattingChange = onFormattingChange
        savedRange = textView.selectedRange()
        hasActiveEditor = true
        refreshState()
    }

    func detach(_ textView: NSTextView) {
        guard self.textView === textView else { return }
        savedRange = textView.selectedRange()
        // Toolbar and menu clicks temporarily move first-responder status away
        // from the editor. Keep the last editor and selection available so the
        // requested formatting operation still applies to what the user chose.
        refreshState()
    }

    func remove(_ textView: NSTextView) {
        guard self.textView === textView else { return }
        self.textView = nil
        onFormattingChange = nil
        hasActiveEditor = false
        canUndo = false
        canRedo = false
    }

    func selectionDidChange(in textView: NSTextView) {
        guard self.textView === textView else { return }
        savedRange = textView.selectedRange()
        refreshState()
    }

    func editorDidChange(in textView: NSTextView) {
        guard self.textView === textView else { return }
        savedRange = textView.selectedRange()
        refreshState()
    }

    func historyDidChange() {
        guard textView != nil else {
            canUndo = false
            canRedo = false
            return
        }
        refreshState()
    }

    func undo() {
        guard let textView, textView.undoManager?.canUndo == true else { return }
        restoreFocus()
        textView.undoManager?.undo()
        savedRange = textView.selectedRange()
        onFormattingChange?()
        refreshState()
    }

    func redo() {
        guard let textView, textView.undoManager?.canRedo == true else { return }
        restoreFocus()
        textView.undoManager?.redo()
        savedRange = textView.selectedRange()
        onFormattingChange?()
        refreshState()
    }

    func toggleBold() {
        toggleTrait(.boldFontMask)
    }

    func toggleItalic() {
        toggleTrait(.italicFontMask)
    }

    func toggleUnderline() {
        guard let textView else { return }
        restoreFocus()
        let range = validRange(in: textView)
        let shouldUnderline = !isUnderlined
        registerUndo(in: textView, actionName: "Underline")
        if range.length == 0 {
            textView.typingAttributes[.underlineStyle] = shouldUnderline ? NSUnderlineStyle.single.rawValue : 0
        } else {
            textView.textStorage?.addAttribute(
                .underlineStyle,
                value: shouldUnderline ? NSUnderlineStyle.single.rawValue : 0,
                range: range
            )
        }
        commitFormattingChange(in: textView)
        isUnderlined = shouldUnderline
    }

    func applyColor(_ color: RGBAColor?) {
        guard let textView else { return }
        restoreFocus()
        let range = validRange(in: textView)
        let attributes = AttributedTextCodec.colorAttributes(for: color)
        registerUndo(in: textView, actionName: "Text Color")
        if range.length == 0 {
            var typingAttributes = textView.typingAttributes
            typingAttributes.removeValue(forKey: .singersLyricsAdaptiveForeground)
            typingAttributes.removeValue(forKey: .singersLyricsStoredForeground)
            for (key, value) in attributes {
                typingAttributes[key] = value
            }
            textView.typingAttributes = typingAttributes
        } else {
            textView.textStorage?.removeAttribute(.singersLyricsAdaptiveForeground, range: range)
            textView.textStorage?.removeAttribute(.singersLyricsStoredForeground, range: range)
            textView.textStorage?.addAttributes(attributes, range: range)
        }
        commitFormattingChange(in: textView)
        refreshState()
    }

    func applyFontFamily(_ family: String) {
        guard let textView else { return }
        restoreFocus()
        let range = validRange(in: textView)
        for font in fonts(in: textView, range: range) {
            let originalTraits = NSFontManager.shared.traits(of: font)
            let converted = NSFontManager.shared.convert(font, toFamily: family)
            if originalTraits.contains(.boldFontMask),
               !NSFontManager.shared.traits(of: converted).contains(.boldFontMask) {
                warning = FormattingWarning(fontFamily: family, traitName: "Bold")
                return
            }
            if originalTraits.contains(.italicFontMask),
               !NSFontManager.shared.traits(of: converted).contains(.italicFontMask) {
                warning = FormattingWarning(fontFamily: family, traitName: "Italic")
                return
            }
        }
        registerUndo(in: textView, actionName: "Font")
        if range.length == 0 {
            var typingAttributes = textView.typingAttributes
            typingAttributes.removeValue(forKey: .singersLyricsFallbackFont)
            textView.typingAttributes = typingAttributes
        } else {
            textView.textStorage?.removeAttribute(.singersLyricsFallbackFont, range: range)
        }
        transformFonts(in: textView, range: range) { font in
            NSFontManager.shared.convert(font, toFamily: family)
        }
        commitFormattingChange(in: textView)
        refreshState()
    }

    func insertSymbol(_ symbol: String) {
        guard let textView else { return }
        restoreFocus()
        let range = validRange(in: textView)
        let attributes = textView.typingAttributes
        let replacement = NSAttributedString(string: symbol, attributes: attributes)
        registerUndo(in: textView, actionName: "Insert Symbol")
        textView.textStorage?.replaceCharacters(in: range, with: replacement)
        let caret = NSRange(location: range.location + (symbol as NSString).length, length: 0)
        textView.setSelectedRange(caret)
        savedRange = caret
        commitFormattingChange(in: textView)
    }

    private func toggleTrait(_ trait: NSFontTraitMask) {
        guard let textView else { return }
        restoreFocus()
        let range = validRange(in: textView)
        let removing = trait == .boldFontMask ? isBold : isItalic
        let segments = effectiveFontSegments(in: textView, range: range)
        if !removing {
            for segment in segments {
                let converted = NSFontManager.shared.convert(segment.font, toHaveTrait: trait)
                guard NSFontManager.shared.traits(of: converted).contains(trait) else {
                    warning = FormattingWarning(
                        fontFamily: segment.font.familyName ?? segment.font.displayName ?? "This font",
                        traitName: trait == .boldFontMask ? "Bold" : "Italic"
                    )
                    return
                }
            }
        }
        registerUndo(
            in: textView,
            actionName: trait == .boldFontMask ? "Bold" : "Italic"
        )
        transformEffectiveFonts(in: textView, range: range, segments: segments) { font in
            if removing {
                NSFontManager.shared.convert(font, toNotHaveTrait: trait)
            } else {
                NSFontManager.shared.convert(font, toHaveTrait: trait)
            }
        }
        commitFormattingChange(in: textView)
        refreshState()
    }

    private struct EffectiveFontSegment {
        var range: NSRange
        var font: NSFont
    }

    private func effectiveFontSegments(
        in textView: NSTextView,
        range: NSRange
    ) -> [EffectiveFontSegment] {
        if range.length == 0 {
            let font = textView.typingAttributes[.font] as? NSFont
                ?? NSFont.systemFont(ofSize: 17)
            return [EffectiveFontSegment(range: range, font: font)]
        }

        guard let storage = textView.textStorage,
              let stringRange = Range(range, in: storage.string) else {
            return []
        }

        let string = storage.string
        var result: [EffectiveFontSegment] = []
        string.enumerateSubstrings(
            in: stringRange,
            options: .byComposedCharacterSequences
        ) { _, characterRange, _, _ in
            let characterNSRange = NSRange(characterRange, in: string)
            let nominalFont = storage.attribute(
                .font,
                at: characterNSRange.location,
                effectiveRange: nil
            ) as? NSFont ?? NSFont.systemFont(ofSize: 17)
            let resolved = CTFontCreateForString(
                nominalFont as CTFont,
                string as CFString,
                CFRange(
                    location: characterNSRange.location,
                    length: characterNSRange.length
                )
            )
            let effectiveFont = resolved as NSFont

            if let last = result.last,
               last.font == effectiveFont,
               NSMaxRange(last.range) == characterNSRange.location {
                result[result.count - 1].range.length += characterNSRange.length
            } else {
                result.append(
                    EffectiveFontSegment(range: characterNSRange, font: effectiveFont)
                )
            }
        }
        return result
    }

    private func transformEffectiveFonts(
        in textView: NSTextView,
        range: NSRange,
        segments: [EffectiveFontSegment],
        transform: (NSFont) -> NSFont
    ) {
        if range.length == 0 {
            let current = segments.first?.font
                ?? textView.typingAttributes[.font] as? NSFont
                ?? NSFont.systemFont(ofSize: 17)
            textView.typingAttributes[.font] = transform(current)
            return
        }

        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        for segment in segments {
            storage.addAttribute(.font, value: transform(segment.font), range: segment.range)
        }
        storage.endEditing()
    }

    private func transformFonts(
        in textView: NSTextView,
        range: NSRange,
        transform: (NSFont) -> NSFont
    ) {
        if range.length == 0 {
            let current = textView.typingAttributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 17)
            textView.typingAttributes[.font] = transform(current)
            return
        }

        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = value as? NSFont ?? NSFont.systemFont(ofSize: 17)
            storage.addAttribute(.font, value: transform(font), range: subrange)
        }
        storage.endEditing()
    }

    private func fonts(in textView: NSTextView, range: NSRange) -> [NSFont] {
        if range.length == 0 {
            return [textView.typingAttributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 17)]
        }
        guard let storage = textView.textStorage else { return [] }
        var result: [NSFont] = []
        storage.enumerateAttribute(.font, in: range) { value, _, _ in
            result.append(value as? NSFont ?? NSFont.systemFont(ofSize: 17))
        }
        return result
    }

    private func restoreFocus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(validRange(in: textView))
    }

    private func commitFormattingChange(in textView: NSTextView) {
        savedRange = textView.selectedRange()
        textView.didChangeText()
        // Attribute-only edits are not delivered consistently through every
        // NSTextView delegate path. Persist explicitly so the SwiftUI model
        // cannot repaint the editor with its pre-formatting value.
        onFormattingChange?()
        refreshHistoryState(in: textView)
    }

    private struct EditorSnapshot {
        var contents: NSAttributedString
        var typingAttributes: [NSAttributedString.Key: Any]
        var selection: NSRange
    }

    private func snapshot(of textView: NSTextView) -> EditorSnapshot {
        EditorSnapshot(
            contents: NSAttributedString(attributedString: textView.attributedString()),
            typingAttributes: textView.typingAttributes,
            selection: textView.selectedRange()
        )
    }

    private func registerUndo(in textView: NSTextView, actionName: String) {
        guard let undoManager = textView.undoManager else { return }
        let previous = snapshot(of: textView)
        undoManager.registerUndo(withTarget: self) { context in
            context.restore(previous, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    private func restore(_ snapshot: EditorSnapshot, actionName: String) {
        guard let textView else { return }
        if let undoManager = textView.undoManager {
            let inverse = self.snapshot(of: textView)
            undoManager.registerUndo(withTarget: self) { context in
                context.restore(inverse, actionName: actionName)
            }
            undoManager.setActionName(actionName)
        }
        textView.textStorage?.setAttributedString(snapshot.contents)
        textView.typingAttributes = snapshot.typingAttributes
        let length = textView.string.utf16.count
        let location = min(snapshot.selection.location, length)
        textView.setSelectedRange(
            NSRange(
                location: location,
                length: min(snapshot.selection.length, length - location)
            )
        )
        savedRange = textView.selectedRange()
        textView.didChangeText()
        onFormattingChange?()
        refreshState()
    }

    private func validRange(in textView: NSTextView) -> NSRange {
        let length = textView.string.utf16.count
        let location = min(savedRange.location, length)
        return NSRange(location: location, length: min(savedRange.length, length - location))
    }

    private func refreshState() {
        guard let textView else { return }
        let range = validRange(in: textView)
        let attributes: [NSAttributedString.Key: Any]
        if range.location < textView.string.utf16.count {
            attributes = textView.textStorage?.attributes(at: range.location, effectiveRange: nil) ?? [:]
        } else {
            attributes = textView.typingAttributes
        }
        let font = effectiveFontSegments(in: textView, range: range).first?.font
            ?? attributes[.font] as? NSFont
            ?? NSFont.systemFont(ofSize: 17)
        if attributes[.singersLyricsAdaptiveForeground] != nil {
            selectedTextColor = nil
        } else if let storedHex = attributes[.singersLyricsStoredForeground] as? String {
            selectedTextColor = RGBAColor(hex: storedHex)
        } else {
            selectedTextColor = (attributes[.foregroundColor] as? NSColor)
                .flatMap { $0.usingColorSpace(.sRGB) }
                .map(RGBAColor.init)
        }
        let traits = NSFontManager.shared.traits(of: font)
        isBold = traits.contains(.boldFontMask)
        isItalic = traits.contains(.italicFontMask)
        isUnderlined = (attributes[.underlineStyle] as? Int ?? 0) != 0
        refreshHistoryState(in: textView)
    }

    private func refreshHistoryState(in textView: NSTextView) {
        canUndo = textView.undoManager?.canUndo == true
        canRedo = textView.undoManager?.canRedo == true
    }
}
