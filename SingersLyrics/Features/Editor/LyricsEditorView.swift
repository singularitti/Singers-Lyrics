import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct LyricsEditorView: View {
    @Binding var song: Song
    @Binding var timingLines: [LyricLine]
    let isSyncing: Bool
    let onCancelSync: () -> Void

    @Environment(MusicPlaybackModel.self) private var playback
    @Environment(\.undoManager) private var undoManager
    @State private var selectedLineIDs: Set<UUID> = []
    @State private var selectionAnchor: UUID?
    @State private var targetID: UUID?
    @State private var requestedFocusLineID: UUID?
    @State private var requestedTypingStyle: TextStyle?
    @State private var editingContext = RichTextEditingContext()
    @State private var lineUndoController = LyricsLineUndoController()
    @State private var showsSymbols = false
    @State private var delay = 0.3
    @State private var shiftPreview: ShiftPreview?
    @State private var pollingOwner = UUID()
    @State private var hoveredLineID: UUID?
    @AppStorage(PreferenceKey.defaultLyricsFontFamily) private var fallbackFontFamily = ""
    @FocusState private var listHasFocus: Bool

    private let delayOptions = [0.0, 0.2, 0.3, 0.5, 1.0]
    private let lineControlOverlap = 10.0
    private let editingToolbarClearance = 72.0

    var body: some View {
        VStack(spacing: 0) {
            if isSyncing, playback.state.permissionDenied {
                permissionBanner
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            if isSyncing, let issue = playback.issue {
                playbackIssueBanner(issue)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if visibleLines.isEmpty {
                            if isSyncing {
                                ContentUnavailableView(
                                    "No Lyrics to Sync",
                                    systemImage: "text.badge.clock"
                                )
                            } else {
                                Button {
                                    insertLine(after: nil)
                                } label: {
                                    Label("Add lyric line", systemImage: "plus")
                                }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("emptyAddLineButton")
                            }
                        }

                        ForEach(Array(visibleLines.enumerated()), id: \.element.id) { index, line in
                            lineRow(line: line, index: index)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, showsEditingToolbar ? editingToolbarClearance : 16)
                    .padding(.bottom, 16)
                    .animation(.snappy(duration: 0.2), value: showsEditingToolbar)
                }
                .accessibilityIdentifier("lyricsScrollView")
                .onChange(of: targetID) { _, id in
                    guard isSyncing, let id else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .contentShape(Rectangle())
            .focusable()
            .focusEffectDisabled()
            .focused($listHasFocus)
            .onTapGesture {
                listHasFocus = true
                if !isSyncing {
                    clearLineSelection()
                }
            }
            .onKeyPress(keys: ["a"], phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                guard isSyncing || !editingContext.isEditorFirstResponder else { return .ignored }
                selectedLineIDs = Set(visibleLines.map(\.id))
                resetShiftPreview()
                return .handled
            }
            .onKeyPress(.delete) {
                if isSyncing {
                    clearSelectedTiming()
                    return .handled
                }
                guard !editingContext.isEditorFirstResponder, !selectedLineIDs.isEmpty else { return .ignored }
                deleteSelectedLines()
                return .handled
            }
            .onKeyPress(.space) {
                guard isSyncing else { return .ignored }
                stampCurrentLine()
                return .handled
            }
            .onKeyPress(.escape) {
                guard isSyncing else { return .ignored }
                onCancelSync()
                return .handled
            }
        }
        .background(.background)
        .overlay(alignment: .top) {
            if showsEditingToolbar {
                editingToolbar
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: showsEditingToolbar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSyncing {
                timingPanel
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
            }
        }
        .background {
            if !isSyncing {
                EditPanelOutsideClickMonitor {
                    clearLineSelection()
                }
            }
        }
        .onAppear {
            if isSyncing {
                beginSyncing()
            }
        }
        .onChange(of: isSyncing) { _, syncing in
            if syncing {
                beginSyncing()
            } else {
                playback.stopPolling(owner: pollingOwner)
                resetShiftPreview()
            }
        }
        .onDisappear {
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
        .accessibilityIdentifier(isSyncing ? "syncView" : "lyricsEditorView")
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    private var showsEditingToolbar: Bool {
        !isSyncing && !selectedLineIDs.isEmpty
    }

    private var deleteSelectedLinesLabel: String {
        let noun = selectedLineIDs.count == 1 ? "line" : "lines"
        return "Delete \(selectedLineIDs.count) \(noun)"
    }

    private var visibleLines: [LyricLine] {
        isSyncing ? timingLines : song.lines
    }

    @ViewBuilder
    private func lineRow(line: LyricLine, index: Int) -> some View {
        lineCard(line: line, index: index)
            .overlay(alignment: .bottom) {
                if !isSyncing, hoveredLineID == line.id {
                    lineControls(line: line, index: index)
                        .offset(y: lineControlOverlap)
                }
            }
            .padding(.bottom, isSyncing ? 0 : lineControlOverlap)
            .contentShape(Rectangle())
            .onHover { isHovering in
                guard !isSyncing else { return }
                if isHovering {
                    hoveredLineID = line.id
                } else if hoveredLineID == line.id {
                    hoveredLineID = nil
                }
            }
    }

    @ViewBuilder
    private func lineCard(line: LyricLine, index: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                selectLine(line.id, modifiers: NSEvent.modifierFlags)
                listHasFocus = true
            } label: {
                Image(systemName: selectionSymbol(for: line.id))
                    .foregroundStyle(selectedLineIDs.contains(line.id) ? Color.accentColor : .secondary)
                    .frame(width: 16, height: 34, alignment: .center)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                selectedLineIDs.contains(line.id)
                    ? "Deselect lyric line \(index + 1)"
                    : "Select lyric line \(index + 1)"
            )
            .accessibilityValue(selectedLineIDs.contains(line.id) ? "Selected" : "Not selected")
            .accessibilityIdentifier("selectLine-\(index)")

            VStack(alignment: .leading, spacing: 2) {
                if isSyncing {
                    Text(line.annotation.isEmpty ? "Annotation / pronunciation" : line.annotation)
                        .font(.caption.italic())
                        .foregroundStyle(line.annotation.isEmpty ? .tertiary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 7)
                } else {
                    TextField(
                        "Annotation / pronunciation",
                        text: lineBinding(line.id, keyPath: \.annotation)
                    )
                    .textFieldStyle(.plain)
                    .font(.caption.italic())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 7)
                    .accessibilityIdentifier("annotation-\(index)")
                }

                if isSyncing {
                    Group {
                        if line.lyric.plainText.isEmpty {
                            Text("Lyric line…")
                                .foregroundStyle(.tertiary)
                        } else {
                            Text(
                                AttributedTextCodec.makeSwiftUIAttributedString(
                                    from: line.lyric,
                                    size: 17,
                                    fallbackFontFamily: fallbackFontFamily.isEmpty ? nil : fallbackFontFamily
                                )
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    .padding(.leading, 7)
                } else {
                    ZStack(alignment: .leading) {
                        if line.lyric.plainText.isEmpty {
                            Text("Lyric line…")
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 7)
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
            }

            Text(isSyncing ? preciseTime(line.timestampSeconds) : formatTime(line.timestampSeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(line.timestampSeconds == nil ? .tertiary : .secondary)
                .frame(width: 64, alignment: .trailing)
                .accessibilityElement()
                .accessibilityLabel(formatTime(line.timestampSeconds))
                .accessibilityIdentifier("lineTime-\(index)")

        }
        .padding(10)
        .background(
            selectedLineIDs.contains(line.id)
                ? Color.accentColor.opacity(isSyncing ? 0.14 : 0.12)
                : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(selectedLineIDs.contains(line.id) ? Color.accentColor.opacity(0.45) : .clear)
        }
        .contentShape(Rectangle())
        .overlay {
            if isSyncing {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: 36)
                        .allowsHitTesting(false)

                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            handleSyncLineTap(line.id, modifiers: NSEvent.modifierFlags)
                        }
                }
            }
        }
        .accessibilityElement(children: isSyncing ? .combine : .contain)
        .accessibilityIdentifier(isSyncing ? "syncLine-\(index)" : "editLine-\(index)")
        .accessibilityValue(
            isSyncing
                ? line.timestampSeconds.map { String(format: "%.2f", $0) } ?? "No timing"
                : ""
        )
        .overlay(alignment: .trailing) {
            if isSyncing {
                Color.clear
                    .frame(width: 64)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(formatTime(line.timestampSeconds))
                    .accessibilityIdentifier("lineTime-\(index)")
            }
        }
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
        .background {
            Color.clear
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("lineControls-\(index)")
        }
    }

    private func selectionSymbol(for lineID: UUID) -> String {
        guard selectedLineIDs.contains(lineID) else { return "circle" }
        return isSyncing ? "circle.fill" : "checkmark.circle.fill"
    }

    private var timingPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Time Syncing")
                        .font(.headline)
                    Text(syncStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if song.appleMusicURL != nil {
                    Button("Open in Music") {
                        Task { await playback.play(song, from: targetTimestamp) }
                    }
                }

                Button {
                    Task {
                        if playback.isPlaying(song) {
                            await playback.togglePlayback(for: song)
                        } else {
                            await playback.seekAndPlay(song, to: targetTimestamp)
                        }
                    }
                } label: {
                    Label(
                        playback.isPlaying(song) ? "Pause" : "Play from Line",
                        systemImage: playback.isPlaying(song) ? "pause.fill" : "play.fill"
                    )
                }

                Button("Remove Timing") {
                    clearSelectedTiming()
                }
                .accessibilityIdentifier("removeTimingButton")

                Button("Cancel", role: .cancel, action: onCancelSync)
                    .accessibilityIdentifier("cancelTimingButton")
            }

            HStack(spacing: 10) {
                Text("Shift \(adjustmentIDs.count) selected")
                    .foregroundStyle(.secondary)

                timingValue(
                    label: "Old",
                    value: adjustmentOldTimeText,
                    identifier: "timingOldValue"
                )

                TimingJogWheel(
                    accessibilityValue: "\(adjustmentOldTimeText) to \(adjustmentNewTimeText)",
                    onShift: nudgeAdjustmentTarget(by:)
                )
                .frame(width: 132, height: 40)
                .accessibilityIdentifier("timingJogWheel")

                timingValue(
                    label: "New",
                    value: adjustmentNewTimeText,
                    identifier: "timingNewValue"
                )

                Spacer(minLength: 0)

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

                Picker("Delay", selection: $delay) {
                    ForEach(delayOptions, id: \.self) { option in
                        Text(String(format: "%.1fs", option)).tag(option)
                    }
                }
                .frame(width: 105)
            }

            Text("Click a lyric to select · press Space or Tap to stamp and advance · use the circles with Command/Shift for multi-selection")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .shadow(color: .black.opacity(0.14), radius: 16, y: 5)
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
        .frame(minWidth: 64, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) time")
        .accessibilityValue(value)
        .accessibilityIdentifier(identifier)
    }

    private var syncStatus: String {
        let recorded = timingLines.count { $0.timestampSeconds != nil }
        let nowPlaying = playback.state.trackName.isEmpty
            ? "Play the song in Music to begin"
            : "Now playing: \(playback.state.trackName)"
        return "\(nowPlaying) · Recorded \(recorded)/\(timingLines.count)"
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

    private func beginSyncing() {
        if timingLines.isEmpty {
            timingLines = song.lines
        }
        let validIDs = Set(timingLines.map(\.id))
        selectedLineIDs.formIntersection(validIDs)
        if selectedLineIDs.isEmpty, let firstID = timingLines.first?.id {
            selectedLineIDs = [firstID]
            selectionAnchor = firstID
        }
        targetID = timingLines.first(where: { selectedLineIDs.contains($0.id) })?.id
            ?? timingLines.first?.id
        listHasFocus = true
        playback.startPolling(
            owner: pollingOwner,
            for: song,
            repeatsWhenFinished: false
        )
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
            requestedFocusLineID = newLine.id
            requestedTypingStyle = typingStyle
        }
    }

    private func selectLine(_ lineID: UUID, modifiers: NSEvent.ModifierFlags) {
        if isSyncing {
            targetID = lineID
            resetShiftPreview()
        }
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
        } else if !isSyncing, selectedLineIDs.contains(lineID) {
            selectedLineIDs.remove(lineID)
            if selectionAnchor == lineID {
                selectionAnchor = selectedLineIDs.first
            }
        } else {
            selectedLineIDs = [lineID]
            selectionAnchor = lineID
        }
    }

    private func activateEditingLine(_ lineID: UUID) {
        guard !isSyncing, selectedLineIDs != [lineID] else { return }
        selectedLineIDs = [lineID]
        selectionAnchor = lineID
    }

    private func handleSyncLineTap(_ lineID: UUID, modifiers: NSEvent.ModifierFlags) {
        selectLine(lineID, modifiers: modifiers)
        listHasFocus = true
    }

    private func clearLineSelection() {
        guard !selectedLineIDs.isEmpty || selectionAnchor != nil else { return }
        selectedLineIDs.removeAll()
        selectionAnchor = nil
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
                requestedFocusLineID = nil
                requestedTypingStyle = nil
            } else {
                let focusIndex = min(firstDeletedIndex, song.lines.count - 1)
                let focusLine = song.lines[focusIndex]
                selectedLineIDs = [focusLine.id]
                selectionAnchor = focusLine.id
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

    private var lineEditorSnapshot: LyricsLineEditorSnapshot {
        LyricsLineEditorSnapshot(
            lines: song.lines,
            selectedLineIDs: selectedLineIDs,
            selectionAnchor: selectionAnchor,
            requestedFocusLineID: requestedFocusLineID,
            requestedTypingStyle: requestedTypingStyle
        )
    }

    private func restoreLineEditorSnapshot(_ snapshot: LyricsLineEditorSnapshot) {
        song.lines = snapshot.lines
        selectedLineIDs = snapshot.selectedLineIDs
        selectionAnchor = snapshot.selectionAnchor
        requestedFocusLineID = snapshot.requestedFocusLineID
        requestedTypingStyle = snapshot.requestedTypingStyle
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
        return timingLines.firstIndex(where: { $0.id == targetID }) ?? 0
    }

    private var targetTimestamp: Double {
        TimingUtilities.timestamp(forLineAt: targetIndex, in: timingLines)
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
        return timingLines.first(where: { adjustmentIDs.contains($0.id) })?.id
    }

    private var adjustmentOldTimeText: String {
        guard let id = adjustmentReferenceID,
              let line = timingLines.first(where: { $0.id == id }) else {
            return preciseTime(nil)
        }
        return preciseTime(shiftPreview?.originalTimes[id] ?? line.timestampSeconds)
    }

    private var adjustmentNewTimeText: String {
        guard let id = adjustmentReferenceID,
              let line = timingLines.first(where: { $0.id == id }) else {
            return preciseTime(nil)
        }
        return preciseTime(line.timestampSeconds)
    }

    private func stampCurrentLine(lineID: UUID? = nil) {
        guard !timingLines.isEmpty else { return }
        let index = lineID.flatMap { id in
            timingLines.firstIndex(where: { $0.id == id })
        } ?? targetIndex
        timingLines[index].timestampSeconds = max(0, playback.interpolatedPosition() - delay)
        let nextIndex = min(index + 1, timingLines.count - 1)
        let nextID = timingLines[nextIndex].id
        targetID = nextID
        selectedLineIDs = [nextID]
        selectionAnchor = nextID
        resetShiftPreview()
    }

    private func clearSelectedTiming() {
        let ids = adjustmentIDs
        for index in timingLines.indices where ids.contains(timingLines[index].id) {
            timingLines[index].timestampSeconds = nil
        }
        resetShiftPreview()
    }

    private func nudgeAdjustmentTarget(by delta: Double) {
        let ids = adjustmentIDs
        guard !ids.isEmpty else { return }
        if shiftPreview?.ids != ids {
            shiftPreview = ShiftPreview(
                ids: ids,
                originalTimes: Dictionary(uniqueKeysWithValues: timingLines.compactMap { line in
                    ids.contains(line.id) ? (line.id, line.timestampSeconds ?? 0) : nil
                }),
                delta: 0
            )
        }
        shiftPreview?.delta += delta
        guard let preview = shiftPreview else { return }
        for index in timingLines.indices where ids.contains(timingLines[index].id) {
            let original = preview.originalTimes[timingLines[index].id] ?? 0
            timingLines[index].timestampSeconds = max(0, original + preview.delta)
        }
    }

    private func resetShiftPreview() {
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
            guard event.window === trackedWindow else {
                onOutsideClick()
                return
            }
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
    var requestedFocusLineID: UUID?
    var requestedTypingStyle: TextStyle?
}

@MainActor
@Observable
private final class LyricsLineUndoController {
    private(set) var canUndo = false
    private(set) var canRedo = false

    func register(
        before: LyricsLineEditorSnapshot,
        after: LyricsLineEditorSnapshot,
        actionName: String,
        undoManager: UndoManager,
        apply: @escaping (LyricsLineEditorSnapshot) -> Void
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

    private func registerRestore(
        _ snapshot: LyricsLineEditorSnapshot,
        inverse: LyricsLineEditorSnapshot,
        actionName: String,
        undoManager: UndoManager,
        apply: @escaping (LyricsLineEditorSnapshot) -> Void
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
