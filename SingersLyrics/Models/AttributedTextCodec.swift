import AppKit
import Foundation
import SwiftUI

extension NSAttributedString.Key {
    static let singersLyricsAdaptiveForeground = NSAttributedString.Key(
        "app.singerslyrics.SingersLyrics.adaptiveForeground"
    )
    static let singersLyricsStoredForeground = NSAttributedString.Key(
        "app.singerslyrics.SingersLyrics.storedForeground"
    )
    static let singersLyricsFallbackFont = NSAttributedString.Key(
        "app.singerslyrics.SingersLyrics.fallbackFont"
    )
}

struct TextColorChoice: Identifiable, Hashable, Sendable {
    var id: String { storedColor.hex }
    var name: String
    var storedColor: RGBAColor
    var lightAppearanceColor: RGBAColor
    var darkAppearanceColor: RGBAColor
}

enum TextColorPalette {
    static let choices: [TextColorChoice] = [
        TextColorChoice(
            name: "Rose",
            storedColor: RGBAColor(red: 176, green: 71, blue: 84),
            lightAppearanceColor: RGBAColor(red: 151, green: 38, blue: 57),
            darkAppearanceColor: RGBAColor(red: 255, green: 135, blue: 146)
        ),
        TextColorChoice(
            name: "Orange",
            storedColor: RGBAColor(red: 162, green: 90, blue: 23),
            lightAppearanceColor: RGBAColor(red: 135, green: 70, blue: 7),
            darkAppearanceColor: RGBAColor(red: 255, green: 179, blue: 107)
        ),
        TextColorChoice(
            name: "Green",
            storedColor: RGBAColor(red: 53, green: 120, blue: 90),
            lightAppearanceColor: RGBAColor(red: 31, green: 99, blue: 66),
            darkAppearanceColor: RGBAColor(red: 114, green: 215, blue: 160)
        ),
        TextColorChoice(
            name: "Blue",
            storedColor: RGBAColor(red: 53, green: 116, blue: 168),
            lightAppearanceColor: RGBAColor(red: 31, green: 91, blue: 143),
            darkAppearanceColor: RGBAColor(red: 131, green: 188, blue: 242)
        ),
        TextColorChoice(
            name: "Purple",
            storedColor: RGBAColor(red: 118, green: 84, blue: 168),
            lightAppearanceColor: RGBAColor(red: 98, green: 57, blue: 142),
            darkAppearanceColor: RGBAColor(red: 198, green: 161, blue: 240)
        ),
    ]

    static func displayColor(for storedColor: RGBAColor) -> NSColor {
        guard let choice = choices.first(where: { $0.storedColor == storedColor }) else {
            return storedColor.nsColor
        }
        return NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua
                ? choice.darkAppearanceColor.nsColor
                : choice.lightAppearanceColor.nsColor
        }
    }
}

enum AttributedTextCodec {
    static func makeAttributedString(
        from styledText: StyledText,
        size: CGFloat = 17,
        fallbackFontFamily: String? = nil
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()

        for run in styledText.normalized().runs {
            output.append(
                NSAttributedString(
                    string: run.text,
                    attributes: makeAttributes(
                        from: run.style,
                        size: size,
                        fallbackFontFamily: fallbackFontFamily
                    )
                )
            )
        }

        if output.length == 0 {
            output.append(
                NSAttributedString(
                    string: "",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: size),
                        .foregroundColor: NSColor.labelColor,
                        .singersLyricsAdaptiveForeground: true,
                        .singersLyricsFallbackFont: true,
                    ]
                )
            )
        }
        return output
    }

    static func makeAttributes(
        from style: TextStyle,
        size: CGFloat = 17,
        fallbackFontFamily: String? = nil
    ) -> [NSAttributedString.Key: Any] {
        let fontManager = NSFontManager.shared
        var traits: NSFontTraitMask = []
        if style.bold { traits.insert(.boldFontMask) }
        if style.italic { traits.insert(.italicFontMask) }

        let normalizedFallback = fallbackFontFamily?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedFamily = style.fontFamily
            ?? (normalizedFallback?.isEmpty == false ? normalizedFallback : nil)

        let font: NSFont
        if let selectedFamily {
            font = fontManager.font(
                withFamily: selectedFamily,
                traits: traits,
                weight: 5,
                size: size
            ) ?? fontManager.font(
                withFamily: selectedFamily,
                traits: [],
                weight: 5,
                size: size
            ) ?? NSFont.systemFont(ofSize: size)
        } else {
            var system = NSFont.systemFont(ofSize: size)
            if style.bold {
                system = fontManager.convert(system, toHaveTrait: .boldFontMask)
            }
            if style.italic {
                system = fontManager.convert(system, toHaveTrait: .italicFontMask)
            }
            font = system
        }

        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        // A nil family means “use the user's fallback choice”, including the
        // system default. Keep that semantic marker even when AppKit resolves
        // a script such as Chinese to a concrete display font.
        if style.fontFamily == nil {
            attributes[.singersLyricsFallbackFont] = true
        }
        attributes.merge(colorAttributes(for: style.foregroundColor)) { _, new in new }
        if style.underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    static func makeStyledText(from attributedString: NSAttributedString) -> StyledText {
        guard attributedString.length > 0 else { return StyledText(runs: []) }
        let fontManager = NSFontManager.shared
        var runs: [TextRun] = []

        attributedString.enumerateAttributes(
            in: NSRange(location: 0, length: attributedString.length),
            options: []
        ) { attributes, range, _ in
            let text = attributedString.attributedSubstring(from: range).string
            guard !text.isEmpty else { return }

            let font = attributes[.font] as? NSFont
            let traits = font.map(fontManager.traits(of:)) ?? []
            let color: RGBAColor?
            if attributes[.singersLyricsAdaptiveForeground] != nil {
                color = nil
            } else if let storedHex = attributes[.singersLyricsStoredForeground] as? String {
                color = RGBAColor(hex: storedHex)
            } else {
                color = (attributes[.foregroundColor] as? NSColor)
                    .flatMap { $0.usingColorSpace(.sRGB) }
                    .map(RGBAColor.init)
            }
            let underline = (attributes[.underlineStyle] as? Int ?? 0) != 0
            let usesFallbackFont = attributes[.singersLyricsFallbackFont] != nil
            let family = usesFallbackFont
                || font?.familyName == NSFont.systemFont(ofSize: 17).familyName
                ? nil
                : font?.familyName

            runs.append(
                TextRun(
                    text: text,
                    style: TextStyle(
                        fontFamily: family,
                        foregroundColor: color,
                        bold: traits.contains(.boldFontMask),
                        italic: traits.contains(.italicFontMask),
                        underline: underline
                    )
                )
            )
        }

        return StyledText(runs: runs).normalized()
    }

    static func makeSwiftUIAttributedString(
        from styledText: StyledText,
        size: CGFloat,
        fallbackFontFamily: String? = nil
    ) -> AttributedString {
        let appKitValue = NSMutableAttributedString(
            attributedString: makeAttributedString(
                from: styledText,
                size: size,
                fallbackFontFamily: fallbackFontFamily
            )
        )
        let fullRange = NSRange(location: 0, length: appKitValue.length)
        appKitValue.removeAttribute(.singersLyricsAdaptiveForeground, range: fullRange)
        appKitValue.removeAttribute(.singersLyricsStoredForeground, range: fullRange)
        appKitValue.removeAttribute(.singersLyricsFallbackFont, range: fullRange)
        return (try? AttributedString(appKitValue, including: \.appKit)) ?? AttributedString(styledText.plainText)
    }

    static func colorAttributes(for color: RGBAColor?) -> [NSAttributedString.Key: Any] {
        if let color {
            return [
                .foregroundColor: TextColorPalette.displayColor(for: color),
                .singersLyricsStoredForeground: color.hex,
            ]
        }
        return [
            .foregroundColor: NSColor.labelColor,
            .singersLyricsAdaptiveForeground: true,
        ]
    }
}

extension RGBAColor {
    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: CGFloat(alpha) / 255
        )
    }

    init(_ color: NSColor) {
        self.init(
            red: UInt8((color.redComponent * 255).rounded()),
            green: UInt8((color.greenComponent * 255).rounded()),
            blue: UInt8((color.blueComponent * 255).rounded()),
            alpha: UInt8((color.alphaComponent * 255).rounded())
        )
    }
}
