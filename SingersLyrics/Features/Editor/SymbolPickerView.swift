import AppKit
import SwiftUI

struct SymbolPickerView: View {
    let editingContext: RichTextEditingContext
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.fixed(36), spacing: 8), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Insert Symbol")
                    .font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(SymbolCatalog.categories) { category in
                        Text(category.name)
                            .font(.headline)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                            ForEach(category.symbols, id: \.self) { symbol in
                                Button(symbol) {
                                    editingContext.insertSymbol(symbol)
                                    dismiss()
                                }
                                .buttonStyle(.bordered)
                                .font(.title3)
                                .frame(width: 36, height: 32)
                                .accessibilityIdentifier("symbolButton-\(symbol)")
                            }
                        }
                    }
                }
            }

            Divider()
            Button("Open Character Viewer…") {
                NSApp.orderFrontCharacterPalette(nil)
                dismiss()
            }
            .accessibilityIdentifier("characterViewerButton")
        }
        .padding(20)
        .frame(width: 420, height: 520)
    }
}
