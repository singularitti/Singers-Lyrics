#if os(iOS)
import SwiftUI
import UIKit

struct MobileLyricsEditorView: View {
    @Binding var song: Song
    @Environment(MusicPlaybackModel.self) private var playback
    @AppStorage(PreferenceKey.defaultLyricsFontFamily) private var fallbackFontFamily = ""
    @ScaledMetric(relativeTo: .body) private var lyricFontSize: CGFloat = 18
    @State private var selectedLineID: UUID?
    @State private var editingContext = MobileEditingContext()
    @State private var delay = 0.3
    @State private var preferredTypingStyles: [UUID: TextStyle] = [:]
    @State private var showingSymbols = false
    @State private var requestedTextFocusID: UUID?
    @State private var lyricEditorIsActive = false
    @State private var keyboardIsVisible = false
    @State private var transportActionInProgress = false
    @FocusState private var annotationFocus: UUID?

    private let delays = [0.0, 0.1, 0.2, 0.3, 0.5, 1.0]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if song.lines.isEmpty {
                        ContentUnavailableView {
                            Label("No Lyrics Yet", systemImage: "text.quote")
                        } description: {
                            Text("Add a line to start editing.")
                        } actions: {
                            Button("Add Lyric Line") { addLine(before: nil) }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(.top, 40)
                    } else {
                        ForEach(Array(song.lines.enumerated()), id: \.element.id) { index, line in
                            lineCard(line, index: index)
                                .id(line.id)
                        }

                        Button(action: { addLine(after: song.lines.last?.id) }) {
                            Label("Add Line", systemImage: "plus")
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 18)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                timingDock
            }
            .onChange(of: selectedLineID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardIsVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardIsVisible = false }
        .onAppear {
            selectedLineID = selectedLineID ?? song.lines.first?.id
            ensureLineExists()
        }
        .onChange(of: song.lines.map(\.id)) { _, ids in
            if let selectedLineID, ids.contains(selectedLineID) { return }
            selectedLineID = song.lines.first?.id
        }
        .sheet(isPresented: $showingSymbols) {
            symbolSheet
                .presentationDetents([.medium, .large])
        }
    }

    private func lineCard(_ line: LyricLine, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(selectedLineID == line.id ? Color.accentColor : Color.secondary)
                    .frame(minWidth: 30, minHeight: 36)
                    .accessibilityHidden(true)

                TextField("Annotation (optional)", text: annotationBinding(for: line.id))
                    .font(.subheadline)
                    .textFieldStyle(.plain)
                    .focused($annotationFocus, equals: line.id)
                    .onChange(of: annotationFocus) { _, focusedID in
                        if focusedID == line.id {
                            selectedLineID = line.id
                            lyricEditorIsActive = false
                        }
                    }
                    .submitLabel(.done)
                    .onSubmit { annotationFocus = nil }
                    .accessibilityLabel("Line \(index + 1) annotation")

                Button { selectedLineID = line.id } label: {
                    Text(timestampText(line.timestampSeconds))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(line.timestampSeconds == nil ? .tertiary : .secondary)
                        .frame(minWidth: 50, minHeight: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(line.timestampSeconds.map { "Timestamp \(preciseTime($0))" } ?? "No timestamp")

                Menu {
                    Button("Insert Line Above", systemImage: "arrow.up.to.line") { addLine(before: line.id) }
                    Button("Insert Line Below", systemImage: "arrow.down.to.line") { addLine(after: line.id) }
                    Button("Clear Timestamp", systemImage: "clock.badge.xmark") { setTimestamp(nil, for: line.id) }
                        .disabled(line.timestampSeconds == nil)
                    Divider()
                    Button("Delete Line", systemImage: "trash", role: .destructive) { deleteLine(line.id) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Line actions")
            }

            MobileRichTextEditor(
                value: lyricBinding(for: line.id),
                lineID: line.id,
                editingContext: editingContext,
                fallbackFontFamily: fallbackFontFamily.isEmpty ? nil : fallbackFontFamily,
                fontSize: lyricFontSize,
                preferredTypingStyle: preferredTypingStyles[line.id],
                isSelected: selectedLineID == line.id,
                focusRequested: requestedTextFocusID == line.id,
                onActivate: {
                    selectedLineID = line.id
                    lyricEditorIsActive = true
                },
                onFocusHandled: { requestedTextFocusID = nil },
                onEditingChanged: { active in lyricEditorIsActive = active },
                onSplit: { before, after, typingStyle in
                    splitLine(line.id, before: before, after: after, typingStyle: typingStyle)
                }
            )
            .frame(minHeight: 52)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selectedLineID == line.id ? Color.accentColor.opacity(0.5) : Color(uiColor: .separator).opacity(0.28), lineWidth: selectedLineID == line.id ? 1.5 : 0.7)
            }
            .accessibilityIdentifier("mobileLyricEditor-\(index)")
        }
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { selectedLineID = line.id }
    }

    private var formattingBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Button { editingContext.undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .frame(width: 44, height: 44)
                }
                .disabled(!editingContext.canUndo)
                .accessibilityLabel("Undo")

                Button { editingContext.redo() } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .frame(width: 44, height: 44)
                }
                .disabled(!editingContext.canRedo)
                .accessibilityLabel("Redo")

                formatButton("bold", label: "Bold", isOn: editingContext.isBold) { editingContext.toggleBold() }
                formatButton("italic", label: "Italic", isOn: editingContext.isItalic) { editingContext.toggleItalic() }
                formatButton("underline", label: "Underline", isOn: editingContext.isUnderlined) { editingContext.toggleUnderline() }

                ColorPicker("Text Color", selection: colorBinding, supportsOpacity: true)
                    .labelsHidden()
                    .frame(width: 44, height: 44)
                    .disabled(!editingContext.hasActiveEditor)
                    .accessibilityLabel("Text color")
                    .contextMenu {
                        Button("Use Default Text Color", systemImage: "circle.lefthalf.filled") {
                            editingContext.restoreDefaultColor()
                        }
                    }

                Menu {
                    Button("Default System Font") { editingContext.applyFontFamily(nil) }
                    ForEach(["Avenir Next", "Georgia", "Helvetica Neue", "Menlo", "Palatino"], id: \.self) { family in
                        Button(family) { editingContext.applyFontFamily(family) }
                    }
                } label: {
                    Image(systemName: "textformat")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!editingContext.hasActiveEditor)
                .accessibilityLabel("Font family")

                Button { showingSymbols = true } label: {
                    Image(systemName: "character")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!editingContext.hasActiveEditor)
                .accessibilityLabel("Insert symbol")
            }
            .padding(.horizontal, 4)
        }
        .scrollIndicators(.hidden)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                guard let color = editingContext.selectedTextColor else { return Color(uiColor: .label) }
                return Color(uiColor: TextColorPalette.displayColor(for: color))
            },
            set: { color in
                guard let rgba = RGBAColor(UIColor(color)) else { return }
                editingContext.applyColor(rgba)
            }
        )
    }

    private var timingDock: some View {
        VStack(spacing: 4) {
            if keyboardIsVisible || lyricEditorIsActive {
                HStack(spacing: 4) {
                    if lyricEditorIsActive { formattingBar }
                    Spacer(minLength: 0)
                    Button("Done") { dismissKeyboard() }
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 56, minHeight: 44)
                }
            } else {
                HStack(spacing: 8) {
                    Button(action: stampSelectedLine) {
                        Label(stampLabel, systemImage: "clock.badge.checkmark")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedLineID == nil || !isPlaybackReady)
                    .accessibilityIdentifier("mobileStampTimingButton")

                    Button {
                        guard !transportActionInProgress else { return }
                        transportActionInProgress = true
                        Task {
                            await playback.togglePlayback(for: song)
                            transportActionInProgress = false
                        }
                    } label: {
                        Image(systemName: playback.isPlaying(song) ? "pause.fill" : "play.fill")
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(playback.isPlaying(song) ? "Pause playback" : "Play playback")
                    .disabled(!canStartPlayback || transportActionInProgress)

                    Menu {
                        Picker("Stamp delay", selection: $delay) {
                            ForEach(delays, id: \.self) { option in
                                Text(String(format: "%.1f seconds", option)).tag(option)
                            }
                        }
                        Divider()
                        Button("Adjust −0.1 seconds") { adjustSelectedTimestamp(by: -0.1) }
                        Button("Adjust +0.1 seconds") { adjustSelectedTimestamp(by: 0.1) }
                        Button("Clear Timestamp", systemImage: "clock.badge.xmark") {
                            if let id = selectedLineID { setTimestamp(nil, for: id) }
                        }
                        .disabled(selectedLine?.timestampSeconds == nil)
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 48, height: 48)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("More timing actions")
                }
                if let selectedLine {
                    Text("Line \((song.lines.firstIndex(where: { $0.id == selectedLine.id }) ?? 0) + 1) · \(preciseTime(selectedLine.timestampSeconds))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 4)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Rectangle().fill(Color(uiColor: .separator).opacity(0.35)).frame(height: 0.5) }
    }

    private var symbolSheet: some View {
        NavigationStack {
            List(SymbolCatalog.categories) { category in
                Section(category.name) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 48))], spacing: 8) {
                        ForEach(category.symbols, id: \.self) { symbol in
                            Button(symbol) {
                                editingContext.insertSymbol(symbol)
                                showingSymbols = false
                            }
                            .font(.title2)
                            .frame(minWidth: 44, minHeight: 44)
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Insert Symbol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSymbols = false } } }
        }
    }

    private var selectedLine: LyricLine? {
        guard let selectedLineID else { return nil }
        return song.lines.first(where: { $0.id == selectedLineID })
    }

    private var isPlaybackReady: Bool {
        playback.canSynchronize(song)
    }

    private var canStartPlayback: Bool { isPlaybackReady || song.appleMusicURL != nil }

    private var stampLabel: String {
        let value = playback.interpolatedPosition(for: song)
        return "Stamp · \(preciseTime(max(0, value - delay)))"
    }

    private func formatButton(_ symbol: String, label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                .frame(width: 44, height: 44)
                .background(isOn ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }
        .disabled(!editingContext.hasActiveEditor)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
    }

    private func annotationBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { song.lines.first(where: { $0.id == id })?.annotation ?? "" },
            set: { value in updateLine(id) { $0.annotation = value } }
        )
    }

    private func lyricBinding(for id: UUID) -> Binding<StyledText> {
        Binding(
            get: { song.lines.first(where: { $0.id == id })?.lyric ?? .plain("") },
            set: { value in updateLine(id) { $0.lyric = value } }
        )
    }

    private func updateLine(_ id: UUID, change: (inout LyricLine) -> Void) {
        guard let index = song.lines.firstIndex(where: { $0.id == id }) else { return }
        change(&song.lines[index])
        song.updatedAt = Date()
    }

    private func ensureLineExists() {
        if song.lines.isEmpty { song.lines = [.blank()] }
        selectedLineID = selectedLineID ?? song.lines.first?.id
    }

    private func addLine(before id: UUID? = nil) {
        let line = LyricLine.blank()
        if let id, let index = song.lines.firstIndex(where: { $0.id == id }) {
            song.lines.insert(line, at: index)
        } else {
            song.lines.append(line)
        }
        song.updatedAt = Date()
        selectedLineID = line.id
        requestedTextFocusID = line.id
    }

    private func addLine(after id: UUID?) {
        guard let id, let index = song.lines.firstIndex(where: { $0.id == id }) else {
            addLine(before: nil)
            return
        }
        let line = LyricLine.blank()
        song.lines.insert(line, at: index + 1)
        song.updatedAt = Date()
        selectedLineID = line.id
        requestedTextFocusID = line.id
    }

    private func deleteLine(_ id: UUID) {
        guard let index = song.lines.firstIndex(where: { $0.id == id }) else { return }
        song.lines.remove(at: index)
        if song.lines.isEmpty { song.lines = [.blank()] }
        song.updatedAt = Date()
        selectedLineID = song.lines[min(index, song.lines.count - 1)].id
    }

    private func splitLine(_ id: UUID, before: StyledText, after: StyledText, typingStyle: TextStyle) {
        guard let index = song.lines.firstIndex(where: { $0.id == id }) else { return }
        song.lines[index].lyric = before
        let next = LyricLine(id: UUID(), annotation: "", lyric: after, timestampSeconds: nil)
        song.lines.insert(next, at: index + 1)
        preferredTypingStyles[next.id] = typingStyle
        song.updatedAt = Date()
        selectedLineID = next.id
        requestedTextFocusID = next.id
    }

    private func setTimestamp(_ seconds: Double?, for id: UUID) {
        updateLine(id) { $0.timestampSeconds = seconds.map { max(0, $0) } }
    }

    private func stampSelectedLine() {
        guard isPlaybackReady else { return }
        guard let id = selectedLineID, let index = song.lines.firstIndex(where: { $0.id == id }) else { return }
        setTimestamp(max(0, playback.interpolatedPosition(for: song) - delay), for: id)
        if index + 1 < song.lines.count { selectedLineID = song.lines[index + 1].id }
    }

    private func adjustSelectedTimestamp(by amount: Double) {
        guard let line = selectedLine, let timestamp = line.timestampSeconds else { return }
        setTimestamp(max(0, timestamp + amount), for: line.id)
    }

    private func dismissKeyboard() {
        annotationFocus = nil
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func timestampText(_ value: Double?) -> String { value.map { preciseTime($0) } ?? "—" }

    private func preciseTime(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f", value)
    }
}
#endif
