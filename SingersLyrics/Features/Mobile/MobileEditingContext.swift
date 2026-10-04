#if os(iOS)
import SwiftUI
import UIKit
import Observation

@MainActor
@Observable
final class MobileEditingContext {
    @ObservationIgnored private weak var textView: UITextView?
    @ObservationIgnored private var persist: (() -> Void)?
    @ObservationIgnored private var range = NSRange(location: 0, length: 0)
    @ObservationIgnored var fallbackFontFamily: String?

    private(set) var hasActiveEditor = false
    private(set) var isBold = false
    private(set) var isItalic = false
    private(set) var isUnderlined = false
    private(set) var selectedTextColor: RGBAColor?
    var canUndo: Bool { textView?.undoManager?.canUndo ?? false }
    var canRedo: Bool { textView?.undoManager?.canRedo ?? false }

    func undo() { textView?.undoManager?.undo() }
    func redo() { textView?.undoManager?.redo() }

    func attach(_ textView: UITextView, persist: @escaping () -> Void) {
        self.textView = textView
        self.persist = persist
        hasActiveEditor = true
        selectionDidChange(textView)
    }

    func remove(_ textView: UITextView) {
        guard self.textView === textView else { return }
        self.textView = nil
        persist = nil
        hasActiveEditor = false
    }

    func selectionDidChange(_ textView: UITextView) {
        guard self.textView === textView else { return }
        range = textView.selectedRange
        refreshState()
    }

    func editorDidChange(_ textView: UITextView) {
        guard self.textView === textView else { return }
        range = textView.selectedRange
        persist?()
        refreshState()
    }

    func toggleBold() { toggleTrait(.traitBold) }
    func toggleItalic() { toggleTrait(.traitItalic) }

    func toggleUnderline() {
        guard let textView else { return }
        restoreSavedSelection(in: textView)
        let apply = !isUnderlined
        let selected = validRange(textView)
        registerUndo(in: textView, actionName: "Underline")
        if selected.length == 0 {
            var attrs = textView.typingAttributes
            attrs[.underlineStyle] = apply ? NSUnderlineStyle.single.rawValue : 0
            textView.typingAttributes = attrs
        } else {
            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            mutable.addAttribute(.underlineStyle, value: apply ? NSUnderlineStyle.single.rawValue : 0, range: selected)
            textView.attributedText = mutable
            textView.selectedRange = selected
        }
        finishChange(textView)
    }

    func applyColor(_ color: RGBAColor?) {
        guard let textView else { return }
        restoreSavedSelection(in: textView)
        let selected = validRange(textView)
        registerUndo(in: textView, actionName: "Text Color")
        let attrs = AttributedTextCodec.colorAttributes(for: color)
        if selected.length == 0 {
            var typing = textView.typingAttributes
            typing.removeValue(forKey: .singersLyricsAdaptiveForeground)
            typing.removeValue(forKey: .singersLyricsStoredForeground)
            attrs.forEach { typing[$0.key] = $0.value }
            textView.typingAttributes = typing
        } else {
            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            mutable.removeAttribute(.singersLyricsAdaptiveForeground, range: selected)
            mutable.removeAttribute(.singersLyricsStoredForeground, range: selected)
            mutable.addAttributes(attrs, range: selected)
            textView.attributedText = mutable
            textView.selectedRange = selected
        }
        finishChange(textView)
    }

    func applyFontFamily(_ family: String?) {
        guard let textView else { return }
        restoreSavedSelection(in: textView)
        let selected = validRange(textView)
        registerUndo(in: textView, actionName: "Font")
        if selected.length == 0 {
            var typing = textView.typingAttributes
            typing.removeValue(forKey: .singersLyricsFallbackFont)
            typing.removeValue(forKey: .singersLyricsStoredFontFamily)
            let transformed = fontAttributes(typing, family: family)
            transformed.forEach { typing[$0.key] = $0.value }
            textView.typingAttributes = typing
        } else {
            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
            mutable.enumerateAttributes(in: selected, options: []) { attrs, range, _ in
                runs.append((range, attrs))
            }
            mutable.removeAttribute(.singersLyricsFallbackFont, range: selected)
            mutable.removeAttribute(.singersLyricsStoredFontFamily, range: selected)
            for (range, attrs) in runs {
                mutable.addAttributes(fontAttributes(attrs, family: family), range: range)
            }
            textView.attributedText = mutable
            textView.selectedRange = selected
        }
        finishChange(textView)
    }

    func insertSymbol(_ symbol: String) {
        guard let textView else { return }
        restoreSavedSelection(in: textView)
        registerUndo(in: textView, actionName: "Insert Symbol")
        textView.textStorage.replaceCharacters(in: validRange(textView), with: NSAttributedString(string: symbol, attributes: textView.typingAttributes))
        textView.selectedRange = NSRange(location: range.location + (symbol as NSString).length, length: 0)
        finishChange(textView)
    }

    private func toggleTrait(_ trait: UIFontDescriptor.SymbolicTraits) {
        guard let textView else { return }
        restoreSavedSelection(in: textView)
        let selected = validRange(textView)
        let attrs: [NSAttributedString.Key: Any]
        if selected.length == 0 { attrs = textView.typingAttributes }
        else { attrs = textView.attributedText.attributes(at: selected.location, effectiveRange: nil) }
        let markerKey = trait == .traitBold ? NSAttributedString.Key.singersLyricsStoredBold : .singersLyricsStoredItalic
        let currentFont = attrs[.font] as? UIFont ?? UIFont.systemFont(ofSize: 18)
        let marker = attrs[markerKey] as? Bool
        let currentlyOn = marker ?? currentFont.fontDescriptor.symbolicTraits.contains(trait)
        registerUndo(in: textView, actionName: trait == .traitBold ? "Bold" : "Italic")
        if selected.length == 0 {
            var typing = textView.typingAttributes
            let desired = desiredTraits(in: typing, toggling: trait, currentlyOn: currentlyOn)
            let family = textView.typingAttributes[.singersLyricsStoredFontFamily] as? String
            let changed = font(for: currentFont, desiredTraits: desired, family: family)
            typing[.font] = changed
            typing[.singersLyricsStoredBold] = desired.bold
            typing[.singersLyricsStoredItalic] = desired.italic
            textView.typingAttributes = typing
        } else {
            let mutable = NSMutableAttributedString(attributedString: textView.attributedText)
            var runStates: [(NSRange, [NSAttributedString.Key: Any], Bool)] = []
            mutable.enumerateAttributes(in: selected, options: []) { attributes, range, _ in
                let original = attributes[.font] as? UIFont ?? UIFont.systemFont(ofSize: 18)
                let on = (attributes[markerKey] as? Bool) ?? original.fontDescriptor.symbolicTraits.contains(trait)
                runStates.append((range, attributes, on))
            }
            let shouldTurnOn = !runStates.allSatisfy { $0.2 }
            for (range, attributes, _) in runStates {
                let original = attributes[.font] as? UIFont ?? UIFont.systemFont(ofSize: 18)
                let desired = desiredTraits(in: attributes, setting: trait, to: shouldTurnOn)
                mutable.addAttributes([
                    .font: font(for: original, desiredTraits: desired, family: attributes[.singersLyricsStoredFontFamily] as? String),
                    .singersLyricsStoredBold: desired.bold,
                    .singersLyricsStoredItalic: desired.italic,
                ], range: range)
            }
            textView.attributedText = mutable
            textView.selectedRange = selected
        }
        finishChange(textView)
    }

    private func validRange(_ textView: UITextView) -> NSRange {
        let location = min(range.location, textView.attributedText.length)
        return NSRange(location: location, length: min(range.length, textView.attributedText.length - location))
    }

    private func finishChange(_ textView: UITextView) {
        range = textView.selectedRange
        persist?()
        refreshState()
    }

    private func refreshState() {
        guard let textView else { return }
        let selected = validRange(textView)
        let attrs: [NSAttributedString.Key: Any]
        if selected.length > 0 {
            attrs = textView.attributedText.attributes(at: selected.location, effectiveRange: nil)
        } else {
            attrs = textView.typingAttributes
        }
        if selected.length > 0 {
            var boldStates: [Bool] = []
            var italicStates: [Bool] = []
            var underlineStates: [Bool] = []
            textView.attributedText.enumerateAttributes(in: selected, options: []) { attributes, _, _ in
                let font = attributes[.font] as? UIFont ?? UIFont.systemFont(ofSize: 18)
                boldStates.append(attributes[.singersLyricsStoredBold] as? Bool ?? font.fontDescriptor.symbolicTraits.contains(.traitBold))
                italicStates.append(attributes[.singersLyricsStoredItalic] as? Bool ?? font.fontDescriptor.symbolicTraits.contains(.traitItalic))
                underlineStates.append((attributes[.underlineStyle] as? Int ?? 0) != 0)
            }
            isBold = !boldStates.isEmpty && boldStates.allSatisfy { $0 }
            isItalic = !italicStates.isEmpty && italicStates.allSatisfy { $0 }
            isUnderlined = !underlineStates.isEmpty && underlineStates.allSatisfy { $0 }
        } else {
            let font = attrs[.font] as? UIFont ?? UIFont.systemFont(ofSize: 18)
            isBold = attrs[.singersLyricsStoredBold] as? Bool ?? font.fontDescriptor.symbolicTraits.contains(.traitBold)
            isItalic = attrs[.singersLyricsStoredItalic] as? Bool ?? font.fontDescriptor.symbolicTraits.contains(.traitItalic)
            isUnderlined = (attrs[.underlineStyle] as? Int ?? 0) != 0
        }
        if let hex = attrs[.singersLyricsStoredForeground] as? String {
            selectedTextColor = RGBAColor(hex: hex)
        } else {
            selectedTextColor = nil
        }
    }

    func restoreDefaultColor() { applyColor(nil) }

    private func restoreSavedSelection(in textView: UITextView) {
        textView.selectedRange = NSRange(
            location: min(range.location, textView.attributedText.length),
            length: min(range.length, max(0, textView.attributedText.length - min(range.location, textView.attributedText.length)))
        )
    }

    private func registerUndo(in textView: UITextView, actionName: String) {
        registerUndo(in: textView, actionName: actionName, onChange: persist)
    }

    private func registerUndo(in textView: UITextView, actionName: String, onChange: (() -> Void)?) {
        guard let undoManager = textView.undoManager else { return }
        let prior = NSAttributedString(attributedString: textView.attributedText)
        let priorRange = textView.selectedRange
        undoManager.registerUndo(withTarget: self) { [weak textView] context in
            guard let textView else { return }
            context.registerUndo(in: textView, actionName: actionName, onChange: onChange)
            textView.attributedText = prior
            textView.selectedRange = NSRange(location: min(priorRange.location, prior.length), length: min(priorRange.length, max(0, prior.length - min(priorRange.location, prior.length))))
            onChange?()
            if context.textView === textView {
                context.range = textView.selectedRange
                context.refreshState()
            }
        }
        undoManager.setActionName(actionName)
    }

    private func fontAttributes(_ attributes: [NSAttributedString.Key: Any], family: String?) -> [NSAttributedString.Key: Any] {
        let current = attributes[.font] as? UIFont ?? UIFont.systemFont(ofSize: 18)
        let wantedBold = attributes[.singersLyricsStoredBold] as? Bool ?? current.fontDescriptor.symbolicTraits.contains(.traitBold)
        let wantedItalic = attributes[.singersLyricsStoredItalic] as? Bool ?? current.fontDescriptor.symbolicTraits.contains(.traitItalic)
        let updated = font(for: current, desiredTraits: (wantedBold, wantedItalic), family: family)
        var result: [NSAttributedString.Key: Any] = [
            .font: updated,
            .singersLyricsStoredBold: wantedBold,
            .singersLyricsStoredItalic: wantedItalic,
        ]
        if let family {
            result[.singersLyricsStoredFontFamily] = family
            result.removeValue(forKey: .singersLyricsFallbackFont)
        } else {
            result[.singersLyricsFallbackFont] = true
            result.removeValue(forKey: .singersLyricsStoredFontFamily)
        }
        return result
    }

    private func desiredTraits(in attributes: [NSAttributedString.Key: Any], toggling trait: UIFontDescriptor.SymbolicTraits, currentlyOn: Bool) -> (bold: Bool, italic: Bool) {
        let font = attributes[.font] as? UIFont ?? UIFont.systemFont(ofSize: 18)
        var bold = attributes[.singersLyricsStoredBold] as? Bool ?? font.fontDescriptor.symbolicTraits.contains(.traitBold)
        var italic = attributes[.singersLyricsStoredItalic] as? Bool ?? font.fontDescriptor.symbolicTraits.contains(.traitItalic)
        if trait == .traitBold { bold = !currentlyOn } else { italic = !currentlyOn }
        return (bold, italic)
    }

    private func desiredTraits(in attributes: [NSAttributedString.Key: Any], setting trait: UIFontDescriptor.SymbolicTraits, to value: Bool) -> (bold: Bool, italic: Bool) {
        let font = attributes[.font] as? UIFont ?? UIFont.systemFont(ofSize: 18)
        var bold = attributes[.singersLyricsStoredBold] as? Bool ?? font.fontDescriptor.symbolicTraits.contains(.traitBold)
        var italic = attributes[.singersLyricsStoredItalic] as? Bool ?? font.fontDescriptor.symbolicTraits.contains(.traitItalic)
        if trait == .traitBold { bold = value } else { italic = value }
        return (bold, italic)
    }

    private func font(for font: UIFont, desiredTraits: (bold: Bool, italic: Bool), family: String?) -> UIFont {
        var style = TextStyle.plain
        style.fontFamily = family
        style.bold = desiredTraits.bold
        style.italic = desiredTraits.italic
        return AttributedTextCodec.makeAttributes(
            from: style, size: font.pointSize, fallbackFontFamily: fallbackFontFamily
        )[.font] as? UIFont ?? font
    }
}
#endif
