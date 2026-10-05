#if os(iOS)
import SwiftUI
import UIKit

struct MobileLyricsEditorView: View {
    @Binding var song: Song
    @Environment(MusicPlaybackModel.self) private var playback
    @Environment(AppModel.self) private var model
    @AppStorage(PreferenceKey.defaultLyricsFontFamily) private var fallbackFontFamily = ""
    @ScaledMetric(relativeTo: .body) private var lyricFontSize: CGFloat = 18
    @State private var selectedLineID: UUID?
    @State private var expandedTakesLineID: UUID?
    @State private var editingContext = MobileEditingContext()
    @State private var delay = 0.3
    @State private var preferredTypingStyles: [UUID: TextStyle] = [:]
    @State private var showingSymbols = false
    @State private var requestedTextFocusID: UUID?
    @State private var lyricEditorIsActive = false
    @State private var keyboardIsVisible = false
    @State private var transportActionInProgress = false
    @State private var fineAdjustment: FineTimingAdjustment?
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
            .safeAreaBar(edge: .bottom, spacing: 0) {
                timingDock
            }
            .onChange(of: selectedLineID) { _, id in
                fineAdjustment = nil
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
        .onDisappear {
            // Leaving the editor or switching to the player saves a running take.
            let voice = model.voiceRecordings
            if voice.recordingSongID == song.id { voice.finishRecording() }
            if voice.playingSongID == song.id { voice.stopPlayback() }
        }
        .onChange(of: song.lines.map(\.id)) { _, ids in
            if expandedTakesLineID.map(ids.contains) != true { expandedTakesLineID = nil }
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
                    .strokeBorder(selectedLineID == line.id ? Color.accentColor.opacity(0.5) : Color(uiColor: .separator), lineWidth: selectedLineID == line.id ? 1.5 : 1)
            }
            .accessibilityIdentifier("mobileLyricEditor-\(index)")

            // The timestamp and line menu share the voice row, so the annotation gets the full width.
            MobileLineRecordingControls(
                songID: song.id,
                line: line,
                lineNumber: index + 1,
                showsTakes: Binding(
                    get: { expandedTakesLineID == line.id },
                    set: { expandedTakesLineID = $0 ? line.id : nil }
                ),
                onSelect: { selectRecording($0, on: line.id) },
                onRename: { renameRecording($0, on: line.id, to: $1) },
                onDelete: { deleteRecording($0, from: line.id) }
            ) {
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

    /// Floating Liquid Glass controls without a bar background, so on iPad they stop
    /// at the sidebar; the safe-area bar's scroll edge effect keeps them legible.
    private var timingDock: some View {
        GlassEffectContainer {
            VStack(spacing: 8) {
                if keyboardIsVisible || lyricEditorIsActive {
                    HStack(spacing: 8) {
                        if lyricEditorIsActive {
                            formattingBar
                                .glassEffect(in: .capsule)
                        }
                        Spacer(minLength: 0)
                        Button { dismissKeyboard() } label: {
                            Text("Done")
                                .font(.subheadline.weight(.semibold))
                                .frame(minHeight: 30)
                        }
                        .buttonStyle(.glass)
                    }
                } else {
                    // Play stays away from Stamp, so rhythmic stamping can't pause the song.
                    HStack(spacing: 8) {
                        Button {
                            guard !transportActionInProgress else { return }
                            transportActionInProgress = true
                            Task {
                                await playback.togglePlayback(for: song)
                                transportActionInProgress = false
                            }
                        } label: {
                            Image(systemName: playback.isPlaying(song) ? "pause.fill" : "play.fill")
                                .frame(width: 30, height: 30)
                        }
                        .accessibilityLabel(playback.isPlaying(song) ? "Pause playback" : "Play playback")
                        .disabled(!canStartPlayback || transportActionInProgress)

                        Button {
                            if let id = selectedLineID { setTimestamp(nil, for: id) }
                        } label: {
                            Image(systemName: "clock.badge.xmark")
                                .frame(width: 30, height: 30)
                        }
                        .disabled(selectedLine?.timestampSeconds == nil)
                        .accessibilityLabel("Clear Timestamp")
                        .accessibilityIdentifier("mobileClearTimestampButton")

                        Menu {
                            Picker("Stamp delay", selection: $delay) {
                                ForEach(delays, id: \.self) { option in
                                    Text(String(format: "%.1f seconds", option)).tag(option)
                                }
                            }
                            Divider()
                            Button("Adjust −0.1 seconds") { adjustSelectedTimestamp(by: -0.1) }
                            Button("Adjust +0.1 seconds") { adjustSelectedTimestamp(by: 0.1) }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 30, height: 30)
                        }
                        .accessibilityLabel("More timing actions")

                        Spacer(minLength: 8)

                        Button(action: stampSelectedLine) {
                            Label(stampLabel, systemImage: "clock.badge.checkmark")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .frame(minHeight: 30)
                        }
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.capsule)
                        .disabled(selectedLineID == nil || !isPlaybackReady)
                        .accessibilityIdentifier("mobileStampTimingButton")
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)

                    if let selectedLine {
                        fineTimingControl(for: selectedLine)
                    }
                }
            }
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Shifts the selected line's timestamp by up to half a second either way,
    /// complementing the stamp delay and 0.1-second steps in the timing menu.
    private func fineTimingControl(for line: LyricLine) -> some View {
        let lineNumber = (song.lines.firstIndex(where: { $0.id == line.id }) ?? 0) + 1
        let shift = fineTimingShift
        return HStack(spacing: 12) {
            timingReadout("Line \(lineNumber)", value: preciseTime(line.timestampSeconds), template: "000.00", alignment: .leading)
            Slider(
                value: Binding(
                    get: { activeFineAdjustment?.offset ?? 0 },
                    set: { setFineTimingOffset($0) }
                ),
                in: -0.5...0.5,
                neutralValue: 0
            ) {
                Text("Fine timing adjustment")
            }
            timingReadout("Shift", value: shiftText(shift), template: "−0.00", alignment: .trailing, isHighlighted: shift != 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
        .glassEffect(in: .capsule)
        .disabled(line.timestampSeconds == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fine timing adjustment")
        .accessibilityValue(line.timestampSeconds.map {
            "Line \(lineNumber) at \(preciseTime($0)) seconds" + (shift == 0 ? "" : ", shifted \(shiftText(shift)) seconds")
        } ?? "Line \(lineNumber) has no timestamp")
        .accessibilityAdjustableAction { direction in
            setFineTimingOffset((activeFineAdjustment?.offset ?? 0) + (direction == .increment ? 0.1 : -0.1))
        }
        .accessibilityIdentifier("mobileFineTimingSlider")
    }

    private func timingReadout(
        _ title: String,
        value: String,
        template: String,
        alignment: HorizontalAlignment,
        isHighlighted: Bool = false
    ) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            // The template reserves the widest value, so the slider keeps its width while dragging.
            ZStack(alignment: Alignment(horizontal: alignment, vertical: .center)) {
                Text(template).hidden()
                Text(value).foregroundStyle(isHighlighted ? Color.accentColor : Color.primary)
            }
            .font(.caption.monospacedDigit().weight(.medium))
        }
        .lineLimit(1)
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

    /// The slider's adjustment while the selected line still has the time it set.
    private var activeFineAdjustment: FineTimingAdjustment? {
        guard let fineAdjustment, fineAdjustment.lineID == selectedLineID,
              let timestamp = selectedLine?.timestampSeconds,
              abs(timestamp - fineAdjustment.adjustedSeconds) < 0.0005 else { return nil }
        return fineAdjustment
    }

    private var fineTimingShift: Double {
        activeFineAdjustment.map { $0.adjustedSeconds - $0.originalSeconds } ?? 0
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

    private func selectRecording(_ recordingID: UUID, on lineID: UUID) {
        guard let index = song.lines.firstIndex(where: { $0.id == lineID }),
              song.lines[index].selectedRecording?.id != recordingID else { return }
        song.lines[index].selectedRecordingID = recordingID
    }

    private func renameRecording(_ recordingID: UUID, on lineID: UUID, to name: String) {
        updateLine(lineID) { line in
            guard let index = line.recordings.firstIndex(where: { $0.id == recordingID }) else { return }
            line.recordings[index].name = name
        }
    }

    /// The app model moves the removed take to Trash when the song is replaced.
    private func deleteRecording(_ recordingID: UUID, from lineID: UUID) {
        if model.voiceRecordings.playingRecordingID == recordingID {
            model.voiceRecordings.stopPlayback()
        }
        updateLine(lineID) { line in
            line.recordings.removeAll { $0.id == recordingID }
            if line.selectedRecordingID == recordingID { line.selectedRecordingID = nil }
        }
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

    /// The slider offset is measured from the line's time before its first move.
    /// Stamping, the timing menu, or selecting another line starts a new adjustment.
    private func setFineTimingOffset(_ value: Double) {
        guard let line = selectedLine, let timestamp = line.timestampSeconds else { return }
        // Centisecond steps match the displayed precision and keep a zero shift reachable.
        let offset = min(0.5, max(-0.5, (value * 100).rounded() / 100))
        var adjustment = activeFineAdjustment
            ?? FineTimingAdjustment(lineID: line.id, originalSeconds: timestamp, offset: 0)
        guard adjustment.offset != offset else { return }
        adjustment.offset = offset
        fineAdjustment = adjustment
        setTimestamp(adjustment.adjustedSeconds, for: line.id)
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

    private func shiftText(_ value: Double) -> String {
        let centiseconds = Int((value * 100).rounded())
        guard centiseconds != 0 else { return "0.00" }
        return (centiseconds > 0 ? "+" : "−") + String(format: "%.2f", Double(abs(centiseconds)) / 100)
    }

    private struct FineTimingAdjustment {
        let lineID: UUID
        let originalSeconds: Double
        var offset: Double

        var adjustedSeconds: Double { max(0, originalSeconds + offset) }
    }
}
#endif
