import AppKit
import SwiftUI

struct FormattingToolbar: View {
    let editingContext: RichTextEditingContext
    let canUndo: Bool
    let canRedo: Bool
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onSymbols: () -> Void

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

            Divider().frame(height: 18)

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

            Divider().frame(height: 18)

            Menu {
                Button {
                    editingContext.applyColor(nil)
                } label: {
                    Label("Default (Adaptive)", systemImage: "circle.lefthalf.filled")
                }

                Divider()

                ForEach(TextColorPalette.choices) { choice in
                    Button {
                        editingContext.applyColor(choice.storedColor)
                    } label: {
                        Label(choice.name, systemImage: "circle.fill")
                    }
                    .accessibilityIdentifier("textColor-\(choice.name)")
                }
            } label: {
                Label("Text Color", systemImage: "paintpalette")
            }
            .menuStyle(.borderlessButton)
            .accessibilityIdentifier("textColorMenu")
            .disabled(!editingContext.hasActiveEditor)

            Menu {
                ForEach(FontCatalog.availableFamilies, id: \.self) { family in
                    Button(family) {
                        editingContext.applyFontFamily(family)
                    }
                }
            } label: {
                Label("Font", systemImage: "textformat")
            }
            .menuStyle(.borderlessButton)
            .accessibilityIdentifier("fontMenu")
            .disabled(!editingContext.hasActiveEditor)

            Divider().frame(height: 18)

            Button(action: onSymbols) {
                Label("Symbols", systemImage: "character")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("symbolsButton")
            .disabled(!editingContext.hasActiveEditor)
        }
    }
}
