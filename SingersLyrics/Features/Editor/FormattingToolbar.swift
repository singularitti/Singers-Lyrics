import AppKit
import SwiftUI

struct FormattingToolbar: View {
    let editingContext: RichTextEditingContext
    let canUndo: Bool
    let canRedo: Bool
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onSymbols: () -> Void

    private var textColor: Binding<Color> {
        Binding(
            get: {
                guard let color = editingContext.selectedTextColor else {
                    return Color(nsColor: .labelColor)
                }
                return Color(nsColor: TextColorPalette.displayColor(for: color))
            },
            set: { color in
                guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return }
                editingContext.applyColor(RGBAColor(converted))
            }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onUndo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!canUndo)
            .accessibilityLabel("Undo")
            .accessibilityIdentifier("undoFormattingButton")

            Button {
                onRedo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!canRedo)
            .accessibilityLabel("Redo")
            .accessibilityIdentifier("redoFormattingButton")

            Divider()
                .frame(width: 1, height: 18)
                .fixedSize()

            Button {
                editingContext.toggleBold()
            } label: {
                Image(systemName: "bold")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Bold")
            .accessibilityIdentifier("boldButton")
            .accessibilityValue(editingContext.isBold ? "On" : "Off")
            .background(editingContext.isBold ? Color.accentColor.opacity(0.18) : .clear)
            .disabled(!editingContext.hasActiveEditor)

            Button {
                editingContext.toggleItalic()
            } label: {
                Image(systemName: "italic")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Italic")
            .accessibilityIdentifier("italicButton")
            .accessibilityValue(editingContext.isItalic ? "On" : "Off")
            .background(editingContext.isItalic ? Color.accentColor.opacity(0.18) : .clear)
            .disabled(!editingContext.hasActiveEditor)

            Button {
                editingContext.toggleUnderline()
            } label: {
                Image(systemName: "underline")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Underline")
            .accessibilityIdentifier("underlineButton")
            .accessibilityValue(editingContext.isUnderlined ? "On" : "Off")
            .background(editingContext.isUnderlined ? Color.accentColor.opacity(0.18) : .clear)
            .disabled(!editingContext.hasActiveEditor)

            Divider()
                .frame(width: 1, height: 18)
                .fixedSize()

            ColorPicker(
                "Text Color",
                selection: textColor,
                supportsOpacity: true
            )
            .labelsHidden()
            .fixedSize()
            .help("Text Color")
            .accessibilityLabel("Text Color")
            .accessibilityIdentifier("textColorPicker")
            .disabled(!editingContext.hasActiveEditor)
            .contextMenu {
                Button {
                    editingContext.applyColor(nil)
                } label: {
                    Label("Use Default Text Color", systemImage: "circle.lefthalf.filled")
                }
            }

            Menu {
                ForEach(FontCatalog.availableFamilies, id: \.self) { family in
                    Button(family) {
                        editingContext.applyFontFamily(family)
                    }
                }
            } label: {
                Image(systemName: "textformat")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Font")
            .accessibilityLabel("Font")
            .accessibilityIdentifier("fontMenu")
            .disabled(!editingContext.hasActiveEditor)

            Divider()
                .frame(width: 1, height: 18)
                .fixedSize()

            Button(action: onSymbols) {
                Image(systemName: "character")
            }
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Symbols")
            .accessibilityLabel("Symbols")
            .accessibilityIdentifier("symbolsButton")
            .disabled(!editingContext.hasActiveEditor)
        }
        .fixedSize(horizontal: true, vertical: true)
    }
}
