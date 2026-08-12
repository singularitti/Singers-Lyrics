import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct LyricsEditorView: View {
    @Binding var song: Song

    @Environment(MusicPlaybackModel.self) private var playback
    @Environment(\.undoManager) private var undoManager
    @State private var selectedLineIDs: Set<UUID> = []
    @State private var selectionAnchor: UUID?
    @State private var targetID: UUID?
    @State private var editingLineID: UUID?
    @State private var requestedScrollLineID: UUID?
    @State private var requestedFocusLineID: UUID?
    @State private var requestedTypingStyle: TextStyle?
    @State private var editingContext = RichTextEditingContext()
    @State private var lineUndoController = LyricsLineUndoController()
    @State private var showsSymbols = false
    @State private var delay = 0.3
    @State private var shiftPreview: ShiftPreview?
    @State private var isTimingUndoGrouping = false
    @State private var pollingOwner = UUID()
    @State private var hoveredLineID: UUID?
    @AppStorage(PreferenceKey.defaultLyricsFontFamily) private var fallbackFontFamily = ""
    @FocusState private var listHasFocus: Bool
    @FocusState private var focusedAnnotationLineID: UUID?

    private let delayOptions = [0.0, 0.2, 0.3, 0.5, 1.0]
    private let lineControlOverlap = 10.0

    var body: some View {
        VStack(spacing: 0) {
            if playback.state.permissionDenied {
                permissionBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            if let issue = playback.issue {
                playbackIssueBanner(issue)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            editingToolbar
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(3)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if visibleLines.isEmpty {
                            Button {
                                insertLine(after: nil)
                            } label: {
                                Label("Add lyric line", systemImage: "plus")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("emptyAddLineButton")
                        }

                        ForEach(Array(visibleLines.enumerated()), id: \.element.id) { index, line in
                            lineRow(line: line, index: index)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 16)
                    .padding(.bottom, 16)
                }
                .accessibilityIdentifier("lyricsScrollView")
                .onChange(of: requestedScrollLineID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                    requestedScrollLineID = nil
                }
            }
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        listHasFocus = true
                        clearLineSelection()
                    }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($listHasFocus)
            .onKeyPress(keys: ["a"], phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                guard !editingContext.isEditorFirstResponder,
                      focusedAnnotationLineID == nil else { return .ignored }
                selectedLineIDs = Set(visibleLines.map(\.id))
                editingLineID = nil
                targetID = selectedLineIDs.first
                resetShiftPreview()
                return .handled
            }
            .onKeyPress(.delete) {
                guard !editingContext.isEditorFirstResponder,
                      focusedAnnotationLineID == nil,
                      !selectedLineIDs.isEmpty else { return .ignored }
                deleteSelectedLines()
                return .handled
            }
            .onKeyPress(.space) {
                guard !editingContext.isEditorFirstResponder,
                      focusedAnnotationLineID == nil,
                      targetID != nil else { return .ignored }
                stampCurrentLine()
                return .handled
            }
            .onKeyPress(.escape) {
                guard !selectedLineIDs.isEmpty else { return .ignored }
                clearLineSelection()
                return .handled
            }

            timingPanel
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 10)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .background {
            EditPanelOutsideClickMonitor {
                clearLineSelection()
            }
        }
        .onAppear {
            beginTimingWorkspace()
        }
        .onChange(of: song.id) { _, _ in
            beginTimingWorkspace()
        }
        .onChange(of: playbackIdentity) { _, _ in
            refreshTimingPolling()
        }
        .onChange(of: song.lines.map(\.id)) { _, _ in
            reconcileLineSelection()
        }
        .onDisappear {
            resetShiftPreview()
            playback.stopPolling(owner: pollingOwner)
        }
        .sheet(isPresented: $showsSymbols) {
            SymbolPickerView(editingContext: editingContext)
        }
        .alert(item: Binding(
            get: { editingContext.warning },
            set: { editingContext.warning = $0 }
        )) { warning in
            Alert(
                title: Text("Font Style Not Available"),
                message: Text(warning.message),
                dismissButton: .default(Text("OK")) {
                    editingContext.warning = nil
                }
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lyricsWorkspaceView")
    }

    private var editingToolbar: some View {
        HStack(spacing: 14) {
            FormattingToolbar(
                editingContext: editingContext,
                canUndo: editingContext.canUndo || lineUndoController.canUndo,
                canRedo: editingContext.canRedo || lineUndoController.canRedo,
                onUndo: undoEditorChange,
                onRedo: redoEditorChange,
                onSymbols: { showsSymbols = true }
            )
            .layoutPriority(1)

            Spacer(minLength: 0)

            if !selectedLineIDs.isEmpty {
                Button(role: .destructive) {
                    deleteSelectedLines()
                } label: {
                    ViewThatFits(in: .horizontal) {
                        Label(deleteSelectedLinesLabel, systemImage: "trash")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        Image(systemName: "trash")
                    }
                }
                .help(deleteSelectedLinesLabel)
                .accessibilityLabel(deleteSelectedLinesLabel)
                .accessibilityIdentifier("deleteSelectedLinesButton")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(editingLineID == nil ? "lineSelectionPanel" : "textEditingPanel")
    }

    private var deleteSelectedLinesLabel: String {
        let noun = selectedLineIDs.count == 1 ? "line" : "lines"
        return "Delete \(selectedLineIDs.count) \(noun)"
    }

    private var visibleLines: [LyricLine] {
        song.lines
    }

    private var playbackIdentity: TimingPlaybackIdentity {
        TimingPlaybackIdentity(
            title: song.title,
            artist: song.artist,
            appleMusicURL: song.appleMusicURL
        )
    }

    @ViewBuilder
    private func lineRow(line: LyricLine, index: Int) -> some View {
        lineCard(line: line, index: index)
            .overlay(alignment: .bottom) {
                if hoveredLineID == line.id || editingLineID == line.id {
                    lineControls(line: line, index: index)
                        .offset(y: lineControlOverlap)
                }
            }
            .padding(.bottom, lineControlOverlap)
            .contentShape(Rectangle())
            .onHover { isHovering in
                if isHovering {
                    hoveredLineID = line.id
                } else if hoveredLineID == line.id {
                    hoveredLineID = nil
                }
            }
    }

    @ViewBuilder
    private func lineCard(line: LyricLine, index: Int) -> some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                TextField(
                    "Annotation / pronunciation",
                    text: lineBinding(line.id, keyPath: \.annotation)
                )
                .textFieldStyle(.plain)
                .font(.caption.italic())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 2)
                .focused($focusedAnnotationLineID, equals: line.id)
                .simultaneousGesture(TapGesture().onEnded {
                    activateAnnotationLine(line.id)
                })
                .accessibilityIdentifier("annotation-\(index)")

                ZStack(alignment: .leading) {
                    if line.lyric.plainText.isEmpty {
                        Text("Lyric line…")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 2)
                            .allowsHitTesting(false)
                    }
                    RichTextEditor(
                        value: lyricBinding(line.id),
                        lineID: line.id,
                        accessibilityIdentifier: "lyricText-\(index)",
                        editingContext: editingContext,
                        fallbackFontFamily: fallbackFontFamily.isEmpty ? nil : fallbackFontFamily,
                        focusRequested: requestedFocusLineID == line.id,
                        preferredTypingStyle: requestedFocusLineID == line.id
                            ? requestedTypingStyle
                            : nil,
                        onActivate: {
                            activateEditingLine(line.id)
                        },
                        onFocusHandled: {
                            requestedFocusLineID = nil
                            requestedTypingStyle = nil
                        },
                        onSplit: { before, after, typingStyle in
                            splitLine(
                                line.id,
                                before: before,
                                after: after,
                                typingStyle: typingStyle
                            )
                        }
                    )
                }
            }

            Text(preciseTime(line.timestampSeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(line.timestampSeconds == nil ? .tertiary : .secondary)
                .frame(width: 64, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectTimingLine(line.id, modifiers: NSEvent.modifierFlags)
                }
                .accessibilityElement()
                .accessibilityLabel(formatTime(line.timestampSeconds))
                .accessibilityIdentifier("lineTime-\(index)")

        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    selectedLineIDs.contains(line.id)
                        ? Color.accentColor.opacity(0.14)
                        : Color(nsColor: .controlBackgroundColor)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    selectTimingLine(line.id, modifiers: NSEvent.modifierFlags)
                }
        }
        .background {
            ModifiedLineClickMonitor { modifiers in
                selectTimingLine(line.id, modifiers: modifiers)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(selectedLineIDs.contains(line.id) ? Color.accentColor.opacity(0.45) : .clear)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            line.lyric.plainText.isEmpty
                ? "Lyric line \(index + 1), empty lyric"
                : "Lyric line \(index + 1), \(line.lyric.plainText)"
        )
        .accessibilityAddTraits(selectedLineIDs.contains(line.id) ? .isSelected : [])
        .accessibilityAction {
            selectTimingLine(line.id, modifiers: [])
        }
        .accessibilityAction(
            named: Text(
                selectedLineIDs.contains(line.id)
                    ? "Deselect timing line"
                    : "Select for timing"
            )
        ) {
            selectTimingLine(
                line.id,
                modifiers: selectedLineIDs.contains(line.id) ? .command : []
            )
        }
        .accessibilityIdentifier("lyricLine-\(index)")
        .accessibilityValue(line.timestampSeconds.map { String(format: "%.2f", $0) } ?? "No timing")
    }

    private func lineControls(line: LyricLine, index: Int) -> some View {
        HStack(spacing: 0) {
            Button {
                insertLine(after: line.id)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 16)
            }
            .help("Add a lyric line below")
            .accessibilityLabel("Add lyric line below line \(index + 1)")
            .accessibilityIdentifier("addLineBelow-\(index)")

            Divider()
                .frame(height: 12)

            Button(role: .destructive) {
                deleteLines([line.id])
            } label: {
                Image(systemName: "trash")
                    .frame(width: 24, height: 16)
            }
            .help("Delete this lyric line")
            .accessibilityLabel("Delete lyric line \(index + 1)")
            .accessibilityIdentifier("deleteLine-\(index)")
        }
        .buttonStyle(.borderless)
        .controlSize(.mini)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: Capsule())
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lineControls-\(index)")
    }

    private var timingPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                wideTimingHeader
                compactTimingHeader
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ViewThatFits(in: .horizontal) {
                wideTimingControls
                compactTimingControls
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("Click a lyric or timestamp to select · press Space outside text editing or Tap to stamp and advance · use Command/Shift for multi-selection")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .shadow(color: .black.opacity(0.14), radius: 16, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timingPanel")
    }

    private var wideTimingHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            timingHeaderText
                .frame(width: 190, alignment: .leading)

            timingActionRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wideTimingHeader")
    }

    private var compactTimingHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            timingHeaderText
            timingActionRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compactTimingHeader")
    }

    private var timingHeaderText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Time Syncing")
                .font(.headline)
            Text(syncStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("timingStatus")
        }
    }

    private var timingActionRow: some View {
        HStack(spacing: 6) {
            playFromLineTimingButton
            pauseTimingButton
            removeTimingButton
            clearTimingSelectionButton
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("timingActionRow")
    }

    private var playFromLineTimingButton: some View {
        Button {
            Task {
                await playback.seekAndPlay(song, to: targetTimestamp)
            }
        } label: {
            Label("Play from Line", systemImage: "play.fill")
        }
        .accessibilityIdentifier("playFromLineTimingButton")
        .fixedSize(horizontal: true, vertical: false)
    }

    private var pauseTimingButton: some View {
        Button("Pause") {
            Task {
                guard playback.isPlaying(song) else { return }
                await playback.togglePlayback(for: song)
            }
        }
        .disabled(!playback.isPlaying(song))
        .accessibilityIdentifier("pauseTimingButton")
        .fixedSize(horizontal: true, vertical: false)
    }

    private var removeTimingButton: some View {
        Button("Remove Timing") {
            clearSelectedTiming()
        }
        .disabled(adjustmentIDs.isEmpty)
        .accessibilityIdentifier("removeTimingButton")
        .fixedSize(horizontal: true, vertical: false)
    }

    private var clearTimingSelectionButton: some View {
        Button("Cancel", role: .cancel) {
            clearLineSelection()
        }
        .disabled(selectedLineIDs.isEmpty)
        .help("Clear line selection")
        .accessibilityLabel("Clear line selection")
        .accessibilityIdentifier("clearTimingSelectionButton")
        .fixedSize(horizontal: true, vertical: false)
    }

    private var wideTimingControls: some View {
        HStack(spacing: 10) {
            timingSelectionSummary
            timingAdjustmentControls
            stampTimingButton
            delayPicker
        }
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wideTimingControls")
    }

    private var compactTimingControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            timingSelectionSummary

            timingAdjustmentControls
                .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                stampTimingButton
                delayPicker
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compactTimingControls")
    }

    private var timingSelectionSummary: some View {
        Text(adjustmentIDs.isEmpty ? "Select a line" : "\(adjustmentIDs.count) selected")
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("timingSelectionSummary")
    }

    private var timingAdjustmentControls: some View {
        HStack(spacing: 10) {
            timingValue(
                label: "Old",
                value: adjustmentOldTimeText,
                identifier: "timingOldValue"
            )

            TimingJogWheel(
                accessibilityValue: "\(adjustmentOldTimeText) to \(adjustmentNewTimeText)",
                onShift: nudgeAdjustmentTarget(by:),
                onShiftEnded: resetShiftPreview
            )
            .frame(width: 132, height: 40)
            .accessibilityIdentifier("timingJogWheel")

            timingValue(
                label: "New",
                value: adjustmentNewTimeText,
                identifier: "timingNewValue"
            )
        }
        .fixedSize(horizontal: true, vertical: true)
        .disabled(adjustmentIDs.isEmpty)
    }

    private var stampTimingButton: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            Button {
                stampCurrentLine()
            } label: {
                Text("Tap · \(formatTime(playback.interpolatedPosition(at: context.date)))")
                    .monospacedDigit()
                    .frame(minWidth: 112)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("stampTimingButton")
        }
        .fixedSize(horizontal: true, vertical: true)
        .disabled(targetID == nil)
    }

    private var delayPicker: some View {
        Picker("Delay", selection: $delay) {
            ForEach(delayOptions, id: \.self) { option in
                Text(String(format: "%.1fs", option)).tag(option)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityIdentifier("timingDelayPicker")
    }

    private func timingValue(label: String, value: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(label == "New" ? Color.accentColor : .secondary)
                .lineLimit(1)
        }
        .frame(width: 64, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) time")
        .accessibilityValue(value)
        .accessibilityIdentifier(identifier)
    }

    private var syncStatus: String {
        let recorded = song.lines.count { $0.timestampSeconds != nil }
        let nowPlaying = playback.state.trackName.isEmpty
            ? "Play the song in Music to begin"
            : "Now playing: \(playback.state.trackName)"
        return "\(nowPlaying) · Recorded \(recorded)/\(song.lines.count)"
    }

    private var permissionBanner: some View {
        Label(
            "Allow Singers Lyrics to control Music in System Settings › Privacy & Security › Automation.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .foregroundStyle(.orange)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func playbackIssueBanner(_ issue: MusicPlaybackIssue) -> some View {
        Label(issue.message, systemImage: "exclamationmark.octagon.fill")
            .foregroundStyle(.orange)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func beginTimingWorkspace() {
        playback.stopPolling(owner: pollingOwner)
        editingContext.deactivate()
        selectedLineIDs.removeAll()
        selectionAnchor = nil
        targetID = nil
        editingLineID = nil
        focusedAnnotationLineID = nil
        requestedScrollLineID = nil
        requestedFocusLineID = nil
        requestedTypingStyle = nil
        resetShiftPreview()
        refreshTimingPolling()
    }

    private func refreshTimingPolling() {
        playback.startPolling(
            owner: pollingOwner,
            for: song,
            repeatsWhenFinished: false
        )
    }

    private func reconcileLineSelection() {
        let validIDs = Set(song.lines.map(\.id))
        selectedLineIDs.formIntersection(validIDs)
        if selectionAnchor.map(validIDs.contains) != true {
            selectionAnchor = selectedLineIDs.first
        }
        if targetID.map(validIDs.contains) != true || targetID.map(selectedLineIDs.contains) != true {
            targetID = selectedLineIDs.first
        }
        if editingLineID.map(validIDs.contains) != true
            || editingLineID.map(selectedLineIDs.contains) != true {
            editingLineID = nil
            editingContext.deactivate()
        }
        if requestedScrollLineID.map(validIDs.contains) != true {
            requestedScrollLineID = nil
        }
        if focusedAnnotationLineID.map(validIDs.contains) != true {
            focusedAnnotationLineID = nil
        }
        resetShiftPreview()
    }

    private func lyricBinding(_ lineID: UUID) -> Binding<StyledText> {
        Binding(
            get: { song.lines.first(where: { $0.id == lineID })?.lyric ?? .plain("") },
            set: { newValue in
                guard let index = song.lines.firstIndex(where: { $0.id == lineID }) else { return }
                song.lines[index].lyric = newValue.normalized()
            }
        )
    }

    private func lineBinding<Value>(_ lineID: UUID, keyPath: WritableKeyPath<LyricLine, Value>) -> Binding<Value> {
        Binding(
            get: {
                guard let line = song.lines.first(where: { $0.id == lineID }) else {
                    preconditionFailure("A visible lyric line must exist in the bound song")
                }
                return line[keyPath: keyPath]
            },
            set: { value in
                guard let index = song.lines.firstIndex(where: { $0.id == lineID }) else { return }
                song.lines[index][keyPath: keyPath] = value
            }
        )
    }

    private func splitLine(
        _ lineID: UUID,
        before: StyledText,
        after: StyledText,
        typingStyle: TextStyle
    ) {
        guard let index = song.lines.firstIndex(where: { $0.id == lineID }) else { return }
        performLineEdit(actionName: "Split Lyric Line") {
            song.lines[index].lyric = before
            let newLine = LyricLine(id: UUID(), annotation: "", lyric: after, timestampSeconds: nil)
            song.lines.insert(newLine, at: index + 1)
            selectedLineIDs = [newLine.id]
            selectionAnchor = newLine.id
            targetID = newLine.id
            editingLineID = newLine.id
            requestedFocusLineID = newLine.id
            requestedTypingStyle = typingStyle
        }
    }

    private func selectLine(_ lineID: UUID, modifiers: NSEvent.ModifierFlags) {
        targetID = lineID
        resetShiftPreview()
        if modifiers.contains(.shift),
           let anchor = selectionAnchor,
           let start = visibleLines.firstIndex(where: { $0.id == anchor }),
           let end = visibleLines.firstIndex(where: { $0.id == lineID }) {
            let range = min(start, end)...max(start, end)
            selectedLineIDs = Set(range.map { visibleLines[$0].id })
        } else if modifiers.contains(.command) {
            if selectedLineIDs.contains(lineID) {
                selectedLineIDs.remove(lineID)
            } else {
                selectedLineIDs.insert(lineID)
            }
            selectionAnchor = selectedLineIDs.contains(lineID) ? lineID : selectedLineIDs.first
        } else {
            selectedLineIDs = [lineID]
            selectionAnchor = lineID
        }

        if selectedLineIDs.isEmpty {
            targetID = nil
        } else if !selectedLineIDs.contains(lineID) {
            targetID = selectedLineIDs.first
        }
        if editingLineID.map(selectedLineIDs.contains) != true {
            editingLineID = nil
        }
    }

    private func activateEditingLine(_ lineID: UUID) {
        targetID = lineID
        editingLineID = lineID
        focusedAnnotationLineID = nil
        resetShiftPreview()
        guard selectedLineIDs != [lineID] else { return }
        selectedLineIDs = [lineID]
        selectionAnchor = lineID
    }

    private func activateAnnotationLine(_ lineID: UUID) {
        editingContext.deactivate()
        editingLineID = nil
        requestedFocusLineID = nil
        requestedTypingStyle = nil
        selectLine(lineID, modifiers: [])
    }

    private func selectTimingLine(_ lineID: UUID, modifiers: NSEvent.ModifierFlags) {
        editingContext.deactivate()
        editingLineID = nil
        focusedAnnotationLineID = nil
        requestedFocusLineID = nil
        requestedTypingStyle = nil
        selectLine(lineID, modifiers: modifiers)
        listHasFocus = true
    }

    private func clearLineSelection() {
        guard !selectedLineIDs.isEmpty || selectionAnchor != nil else { return }
        editingContext.deactivate()
        selectedLineIDs.removeAll()
        selectionAnchor = nil
        targetID = nil
        editingLineID = nil
        focusedAnnotationLineID = nil
        requestedScrollLineID = nil
        requestedFocusLineID = nil
        requestedTypingStyle = nil
        resetShiftPreview()
    }

    private func deleteSelectedLines() {
        deleteLines(selectedLineIDs)
    }

    private func insertLine(after lineID: UUID?) {
        let insertionIndex = lineID.flatMap { id in
            song.lines.firstIndex(where: { $0.id == id }).map { $0 + 1 }
        } ?? 0
        let typingStyle = lineID.flatMap { id in
            song.lines.first(where: { $0.id == id })?.lyric.runs.last?.style
        } ?? .plain

        performLineEdit(actionName: "Add Lyric Line") {
            let newLine = LyricLine.blank()
            song.lines.insert(newLine, at: min(insertionIndex, song.lines.count))
            selectedLineIDs = [newLine.id]
            selectionAnchor = newLine.id
            targetID = newLine.id
            editingLineID = newLine.id
            requestedFocusLineID = newLine.id
            requestedTypingStyle = typingStyle
        }
    }

    private func deleteLines(_ ids: Set<UUID>) {
        guard !ids.isEmpty,
              let firstDeletedIndex = song.lines.firstIndex(where: { ids.contains($0.id) }) else {
            return
        }

        performLineEdit(actionName: ids.count == 1 ? "Delete Lyric Line" : "Delete Lyric Lines") {
            song.lines.removeAll { ids.contains($0.id) }
            selectedLineIDs.subtract(ids)
            if selectionAnchor.map(ids.contains) == true {
                selectionAnchor = nil
            }

            if song.lines.isEmpty {
                selectedLineIDs.removeAll()
                targetID = nil
                editingLineID = nil
                requestedFocusLineID = nil
                requestedTypingStyle = nil
            } else {
                let focusIndex = min(firstDeletedIndex, song.lines.count - 1)
                let focusLine = song.lines[focusIndex]
                selectedLineIDs = [focusLine.id]
                selectionAnchor = focusLine.id
                targetID = focusLine.id
                editingLineID = focusLine.id
                requestedFocusLineID = focusLine.id
                requestedTypingStyle = focusLine.lyric.runs.last?.style ?? .plain
            }
        }
    }

    private func performLineEdit(actionName: String, mutation: () -> Void) {
        let before = lineEditorSnapshot
        mutation()
        let after = lineEditorSnapshot
        guard before != after, let undoManager else { return }
        lineUndoController.register(
            before: before,
            after: after,
            actionName: actionName,
            undoManager: undoManager,
            apply: restoreLineEditorSnapshot
        )
    }

    private func performTimingEdit(actionName: String, mutation: () -> Void) {
        let before = timingEditorSnapshot
        mutation()
        let after = timingEditorSnapshot
        guard before != after, let undoManager else { return }
        lineUndoController.register(
            before: before,
            after: after,
            actionName: actionName,
            undoManager: undoManager,
            apply: restoreTimingEditorSnapshot
        )
    }

    private var lineEditorSnapshot: LyricsLineEditorSnapshot {
        LyricsLineEditorSnapshot(
            lines: song.lines,
            selectedLineIDs: selectedLineIDs,
            selectionAnchor: selectionAnchor,
            targetID: targetID,
            editingLineID: editingLineID,
            requestedFocusLineID: requestedFocusLineID,
            requestedTypingStyle: requestedTypingStyle
        )
    }

    private func restoreLineEditorSnapshot(_ snapshot: LyricsLineEditorSnapshot) {
        song.lines = snapshot.lines
        selectedLineIDs = snapshot.selectedLineIDs
        selectionAnchor = snapshot.selectionAnchor
        targetID = snapshot.targetID
        editingLineID = snapshot.editingLineID
        requestedFocusLineID = snapshot.requestedFocusLineID
        requestedTypingStyle = snapshot.requestedTypingStyle
    }

    private var timingEditorSnapshot: LyricsTimingEditorSnapshot {
        LyricsTimingEditorSnapshot(
            lineTimings: song.lines.map {
                LyricLineTimingSnapshot(
                    lineID: $0.id,
                    timestampSeconds: $0.timestampSeconds
                )
            },
            selectedLineIDs: selectedLineIDs,
            selectionAnchor: selectionAnchor,
            targetID: targetID,
            editingLineID: editingLineID,
            requestedScrollLineID: requestedScrollLineID
        )
    }

    private func restoreTimingEditorSnapshot(_ snapshot: LyricsTimingEditorSnapshot) {
        let timings = Dictionary(uniqueKeysWithValues: snapshot.lineTimings.map { ($0.lineID, $0) })
        for index in song.lines.indices {
            guard let timing = timings[song.lines[index].id] else { continue }
            song.lines[index].timestampSeconds = timing.timestampSeconds
        }

        let validIDs = Set(song.lines.map(\.id))
        selectedLineIDs = snapshot.selectedLineIDs.intersection(validIDs)
        selectionAnchor = snapshot.selectionAnchor.flatMap { validIDs.contains($0) ? $0 : nil }
        targetID = snapshot.targetID.flatMap { validIDs.contains($0) ? $0 : nil }
        editingLineID = snapshot.editingLineID.flatMap {
            validIDs.contains($0) && selectedLineIDs.contains($0) ? $0 : nil
        }
        requestedScrollLineID = snapshot.requestedScrollLineID.flatMap {
            validIDs.contains($0) ? $0 : nil
        }
        resetShiftPreview()
    }

    private func undoEditorChange() {
        lineUndoController.undo(using: undoManager)
        editingContext.historyDidChange()
    }

    private func redoEditorChange() {
        lineUndoController.redo(using: undoManager)
        editingContext.historyDidChange()
    }

    private var targetIndex: Int {
        guard let targetID else { return 0 }
        return song.lines.firstIndex(where: { $0.id == targetID }) ?? 0
    }

    private var targetTimestamp: Double {
        TimingUtilities.timestamp(forLineAt: targetIndex, in: song.lines)
    }

    private var adjustmentIDs: Set<UUID> {
        if !selectedLineIDs.isEmpty {
            return selectedLineIDs
        }
        return Set(targetID.map { [$0] } ?? [])
    }

    private var adjustmentReferenceID: UUID? {
        if let targetID, adjustmentIDs.contains(targetID) {
            return targetID
        }
        return song.lines.first(where: { adjustmentIDs.contains($0.id) })?.id
    }

    private var adjustmentOldTimeText: String {
        guard let id = adjustmentReferenceID,
              let line = song.lines.first(where: { $0.id == id }) else {
            return preciseTime(nil)
        }
        return preciseTime(shiftPreview?.originalTimes[id] ?? line.timestampSeconds)
    }

    private var adjustmentNewTimeText: String {
        guard let id = adjustmentReferenceID,
              let line = song.lines.first(where: { $0.id == id }) else {
            return preciseTime(nil)
        }
        return preciseTime(line.timestampSeconds)
    }

    private func stampCurrentLine(lineID: UUID? = nil) {
        guard let lineID = lineID ?? targetID,
              let index = song.lines.firstIndex(where: { $0.id == lineID }) else { return }
        performTimingEdit(actionName: "Set Lyric Timing") {
            song.lines[index].timestampSeconds = max(0, playback.interpolatedPosition() - delay)
            let nextIndex = min(index + 1, song.lines.count - 1)
            let nextID = song.lines[nextIndex].id
            targetID = nextID
            selectedLineIDs = [nextID]
            selectionAnchor = nextID
            editingLineID = nil
            requestedScrollLineID = nextID
            resetShiftPreview()
        }
    }

    private func clearSelectedTiming() {
        let ids = adjustmentIDs
        guard !ids.isEmpty else { return }
        performTimingEdit(actionName: ids.count == 1 ? "Remove Lyric Timing" : "Remove Lyrics Timing") {
            for index in song.lines.indices where ids.contains(song.lines[index].id) {
                song.lines[index].timestampSeconds = nil
            }
            resetShiftPreview()
        }
    }

    private func nudgeAdjustmentTarget(by delta: Double) {
        let ids = adjustmentIDs
        guard !ids.isEmpty else { return }
        if !isTimingUndoGrouping, let undoManager {
            undoManager.beginUndoGrouping()
            isTimingUndoGrouping = true
        }
        if shiftPreview?.ids != ids {
            shiftPreview = ShiftPreview(
                ids: ids,
                originalTimes: Dictionary(uniqueKeysWithValues: song.lines.compactMap { line in
                    ids.contains(line.id) ? (line.id, line.timestampSeconds ?? 0) : nil
                }),
                delta: 0
            )
        }
        shiftPreview?.delta += delta
        guard let preview = shiftPreview else { return }
        performTimingEdit(actionName: "Adjust Lyric Timing") {
            for index in song.lines.indices where ids.contains(song.lines[index].id) {
                let original = preview.originalTimes[song.lines[index].id] ?? 0
                song.lines[index].timestampSeconds = max(0, original + preview.delta)
            }
        }
    }

    private func resetShiftPreview() {
        if isTimingUndoGrouping {
            undoManager?.endUndoGrouping()
            isTimingUndoGrouping = false
            lineUndoController.historyDidChange(using: undoManager)
        }
        shiftPreview = nil
    }

    private func preciseTime(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "––:––.––" }
        let centiseconds = Int((max(0, seconds) * 100).rounded())
        let minutes = centiseconds / 6_000
        let remainder = centiseconds % 6_000
        return String(format: "%d:%02d.%02d", minutes, remainder / 100, remainder % 100)
    }

    private struct ShiftPreview {
        var ids: Set<UUID>
        var originalTimes: [UUID: Double]
        var delta: Double
    }

}

private struct TimingPlaybackIdentity: Equatable {
    var title: String
    var artist: String
    var appleMusicURL: URL?
}

private struct ModifiedLineClickMonitor: NSViewRepresentable {
    let onClick: (NSEvent.ModifierFlags) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onClick: onClick)
    }

    func makeNSView(context: Context) -> PassthroughTrackingView {
        let view = PassthroughTrackingView()
        view.setAccessibilityElement(false)
        context.coordinator.trackedView = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ view: PassthroughTrackingView, context: Context) {
        context.coordinator.onClick = onClick
    }

    static func dismantleNSView(_ view: PassthroughTrackingView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator {
        weak var trackedView: NSView?
        var onClick: (NSEvent.ModifierFlags) -> Void
        private var monitor: Any?
        private var isConsumingClick = false

        init(onClick: @escaping (NSEvent.ModifierFlags) -> Void) {
            self.onClick = onClick
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseUp]
            ) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            if event.type == .leftMouseUp, isConsumingClick {
                isConsumingClick = false
                return nil
            }
            guard event.type == .leftMouseDown else { return event }

            let modifiers = event.modifierFlags
            guard modifiers.contains(.command) || modifiers.contains(.shift),
                  let trackedView,
                  let trackedWindow = trackedView.window,
                  event.window === trackedWindow else {
                return event
            }
            let location = trackedView.convert(event.locationInWindow, from: nil)
            guard trackedView.bounds.contains(location) else { return event }
            isConsumingClick = true
            onClick(modifiers)
            return nil
        }
    }

    final class PassthroughTrackingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

private struct EditPanelOutsideClickMonitor: NSViewRepresentable {
    let onOutsideClick: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOutsideClick: onOutsideClick)
    }

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughTrackingView()
        context.coordinator.trackedView = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onOutsideClick = onOutsideClick
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator {
        weak var trackedView: NSView?
        var onOutsideClick: () -> Void
        private var monitor: Any?

        init(onOutsideClick: @escaping () -> Void) {
            self.onOutsideClick = onOutsideClick
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        private func handle(_ event: NSEvent) {
            guard let trackedView, let trackedWindow = trackedView.window else { return }
            // Contextual panels and sheets use their own windows. Keep the
            // active lyric selection while the user interacts with them.
            guard event.window === trackedWindow else { return }
            let location = trackedView.convert(event.locationInWindow, from: nil)
            if !trackedView.bounds.contains(location) {
                onOutsideClick()
            }
        }
    }

    private final class PassthroughTrackingView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

private struct LyricsLineEditorSnapshot: Equatable {
    var lines: [LyricLine]
    var selectedLineIDs: Set<UUID>
    var selectionAnchor: UUID?
    var targetID: UUID?
    var editingLineID: UUID?
    var requestedFocusLineID: UUID?
    var requestedTypingStyle: TextStyle?
}

private struct LyricLineTimingSnapshot: Equatable {
    var lineID: UUID
    var timestampSeconds: Double?
}

private struct LyricsTimingEditorSnapshot: Equatable {
    var lineTimings: [LyricLineTimingSnapshot]
    var selectedLineIDs: Set<UUID>
    var selectionAnchor: UUID?
    var targetID: UUID?
    var editingLineID: UUID?
    var requestedScrollLineID: UUID?
}

@MainActor
@Observable
private final class LyricsLineUndoController {
    private(set) var canUndo = false
    private(set) var canRedo = false

    func register<Snapshot>(
        before: Snapshot,
        after: Snapshot,
        actionName: String,
        undoManager: UndoManager,
        apply: @escaping (Snapshot) -> Void
    ) {
        registerRestore(
            before,
            inverse: after,
            actionName: actionName,
            undoManager: undoManager,
            apply: apply
        )
        refresh(using: undoManager)
    }

    func undo(using undoManager: UndoManager?) {
        undoManager?.undo()
        refresh(using: undoManager)
    }

    func redo(using undoManager: UndoManager?) {
        undoManager?.redo()
        refresh(using: undoManager)
    }

    func historyDidChange(using undoManager: UndoManager?) {
        refresh(using: undoManager)
    }

    private func registerRestore<Snapshot>(
        _ snapshot: Snapshot,
        inverse: Snapshot,
        actionName: String,
        undoManager: UndoManager,
        apply: @escaping (Snapshot) -> Void
    ) {
        undoManager.registerUndo(withTarget: self) { controller in
            controller.registerRestore(
                inverse,
                inverse: snapshot,
                actionName: actionName,
                undoManager: undoManager,
                apply: apply
            )
            apply(snapshot)
        }
        undoManager.setActionName(actionName)
    }

    private func refresh(using undoManager: UndoManager?) {
        canUndo = undoManager?.canUndo == true
        canRedo = undoManager?.canRedo == true
    }
}

struct ImportLyricsSheet: View {
    let onImport: ([LyricLine]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var showsFileImporter = false
    @State private var errorMessage: String?

    private var parsedLines: [LyricLine] { LRCParser.parse(source) }
    private var timedCount: Int { parsedLines.count { $0.timestampSeconds != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Lyrics")
                .font(.title2.bold())
            Text("Paste plain lyrics with one lyric per line, or use LRC timestamps such as [00:12.34]. Importing replaces the current lyric lines.")
                .foregroundStyle(.secondary)

            TextEditor(text: $source)
                .font(.body.monospaced())
                .frame(minHeight: 280)
                .border(Color.secondary.opacity(0.25))
                .accessibilityIdentifier("lyricsImportText")

            HStack {
                Button("Choose .lrc or .txt File…") {
                    showsFileImporter = true
                }
                if timedCount > 0 {
                    Text("\(timedCount) timed lines detected")
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Replace Lyrics") {
                    onImport(parsedLines)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(source.isEmpty)
                .accessibilityIdentifier("confirmLyricsImportButton")
            }
        }
        .padding(20)
        .frame(width: 680, height: 470)
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [UTType.plainText, UTType(filenameExtension: "lrc") ?? .plainText]
        ) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                source = try String(contentsOf: url, encoding: .utf8)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .alert("File Could Not Be Imported", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }
}
