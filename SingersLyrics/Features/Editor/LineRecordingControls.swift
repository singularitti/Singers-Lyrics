#if os(macOS)
import SwiftUI

/// The voice actions share the lyric row's capsule; the picker edits individual takes.
struct LineRecordingControls: View {
    let songID: UUID
    let line: LyricLine
    let lineNumber: Int
    @Binding var showsPicker: Bool
    let onSelect: (UUID) -> Void
    let onRename: (UUID, String) -> Void
    let onDelete: (UUID) -> Void

    @Environment(AppModel.self) private var model
    @FocusState private var focusedRecordingID: UUID?
    @State private var pickerFocusIsInitialized = false

    private var voice: VoiceRecordingController { model.voiceRecordings }
    private var isRecording: Bool {
        voice.recordingSongID == songID && voice.recordingLineID == line.id
    }
    private var isPlaying: Bool {
        voice.playingSongID == songID && voice.playingLineID == line.id
    }
    private var takes: [VoiceRecording] {
        line.recordings.enumerated().sorted { lhs, rhs in
            if lhs.element.createdAt == rhs.element.createdAt { return lhs.offset > rhs.offset }
            return lhs.element.createdAt > rhs.element.createdAt
        }.map(\.element)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if isRecording {
                    if voice.isPreparing { voice.cancelRecording() }
                    else { voice.finishRecording() }
                } else {
                    Task { await voice.record(songID: songID, lineID: line.id, name: nextTakeName) }
                }
            } label: {
                Image(systemName: isRecording ? "stop.fill" : "record.circle")
                    .foregroundStyle(isRecording ? Color.red : Color.primary)
                    .frame(width: 24, height: 16)
            }
            .help(isRecording
                ? (voice.isPreparing ? "Cancel recording preparation" : "Stop and save this recording")
                : "Record a new take for this lyric line")
            .accessibilityLabel(isRecording
                ? (voice.isPreparing ? "Cancel recording preparation" : "Stop and save recording")
                : "Record lyric line \(lineNumber)")
            .accessibilityIdentifier("recordLine-\(lineNumber - 1)")

            if isRecording {
                Text(voice.isPreparing ? "Preparing…" : elapsedLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.red)
                    .padding(.trailing, 5)
                    .accessibilityLabel(voice.isPreparing ? "Preparing recording" : "Recording, \(elapsedLabel) elapsed")
                    .accessibilityIdentifier("recordingElapsed-\(lineNumber - 1)")
            }

            Divider().frame(height: 12)

            Button {
                if isPlaying {
                    voice.stopPlayback()
                } else if let recording = line.selectedRecording {
                    Task { await voice.play(recording, songID: songID, lineID: line.id) }
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .frame(width: 24, height: 16)
                    if line.recordings.count > 1 {
                        Text("\(line.recordings.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(line.selectedRecording == nil && !isPlaying)
            .help(isPlaying ? "Stop recording playback" : "Play the selected recording")
            .accessibilityLabel(isPlaying
                ? "Stop recording playback"
                : "Play \(line.selectedRecording?.name ?? "recording") for lyric line \(lineNumber)")
            .accessibilityIdentifier("playRecording-\(lineNumber - 1)")

            Button {
                showsPicker.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 16, height: 16)
            }
            .disabled(line.recordings.isEmpty)
            .help("Choose, rename, or delete recordings")
            .accessibilityLabel("Show recordings for lyric line \(lineNumber)")
            .accessibilityIdentifier("recordingPicker-\(lineNumber - 1)")
            .popover(isPresented: $showsPicker, arrowEdge: .bottom) {
                recordingPicker
            }
        }
    }

    private var recordingPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recordings for Line \(lineNumber)")
                .font(.headline)
            if takes.isEmpty {
                Text("No recordings yet.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(takes) { recording in
                            RecordingTakeRow(
                                recording: recording,
                                isSelected: line.selectedRecording?.id == recording.id,
                                isPlaying: isPlaying && voice.playingRecordingID == recording.id,
                                focusedRecordingID: $focusedRecordingID,
                                onSelect: { selectRecording(recording.id) },
                                onRename: { onRename(recording.id, $0) },
                                onPlay: {
                                    selectRecording(recording.id)
                                    if isPlaying && voice.playingRecordingID == recording.id {
                                        voice.stopPlayback()
                                    } else {
                                        Task { await voice.play(recording, songID: songID, lineID: line.id) }
                                    }
                                },
                                onDelete: { onDelete(recording.id) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(.top, 14)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .frame(width: 380)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityIdentifier("recordingTakePicker")
        .defaultFocus($focusedRecordingID, line.selectedRecording?.id)
        .onAppear {
            // Restore the selected take before focus begins driving selection.
            // This also overrides any automatic first-field focus on presentation.
            focusedRecordingID = line.selectedRecording?.id
            pickerFocusIsInitialized = true
        }
        .onChange(of: focusedRecordingID) { _, recordingID in
            // Ignore an earlier automatic-focus event queued before onAppear.
            guard pickerFocusIsInitialized,
                  recordingID == focusedRecordingID,
                  let recordingID,
                  line.recordings.contains(where: { $0.id == recordingID }) else { return }
            onSelect(recordingID)
        }
        .onDisappear {
            pickerFocusIsInitialized = false
            focusedRecordingID = nil
        }
    }

    private var nextTakeName: String {
        let largest = line.recordings.compactMap { recording -> Int? in
            guard recording.name.hasPrefix("Take ") else { return nil }
            return Int(recording.name.dropFirst(5))
        }.max() ?? 0
        let next = largest < Int.max ? max(0, largest) + 1 : line.recordings.count + 1
        return "Take \(next)"
    }

    private func selectRecording(_ recordingID: UUID) {
        focusedRecordingID = recordingID
        onSelect(recordingID)
    }

    private var elapsedLabel: String {
        recordingDurationLabel(voice.elapsed)
    }
}

private struct RecordingTakeRow: View {
    let recording: VoiceRecording
    let isSelected: Bool
    let isPlaying: Bool
    let focusedRecordingID: FocusState<UUID?>.Binding
    let onSelect: () -> Void
    let onRename: (String) -> Void
    let onPlay: () -> Void
    let onDelete: () -> Void
    @State private var draftName: String
    private var nameHasFocus: Bool { focusedRecordingID.wrappedValue == recording.id }

    init(
        recording: VoiceRecording,
        isSelected: Bool,
        isPlaying: Bool,
        focusedRecordingID: FocusState<UUID?>.Binding,
        onSelect: @escaping () -> Void,
        onRename: @escaping (String) -> Void,
        onPlay: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.recording = recording
        self.isSelected = isSelected
        self.isPlaying = isPlaying
        self.focusedRecordingID = focusedRecordingID
        self.onSelect = onSelect
        self.onRename = onRename
        self.onPlay = onPlay
        self.onDelete = onDelete
        _draftName = State(initialValue: recording.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(recording.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                Spacer(minLength: 6)
                Text(recordingDurationLabel(recording.duration))
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)

            HStack(spacing: 8) {
                TextField("Recording name", text: $draftName)
                    .textFieldStyle(.plain)
                    .focused(focusedRecordingID, equals: recording.id)
                    .onSubmit(commitName)
                    .simultaneousGesture(TapGesture().onEnded { onSelect() })
                    .frame(maxWidth: .infinity)
                    .help("Rename this recording")
                    .accessibilityLabel("Recording name")

                Button(action: onPlay) {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .frame(width: 20, height: 20)
                }
                .help(isPlaying ? "Stop playback" : "Play this recording")
                .accessibilityLabel(isPlaying ? "Stop \(recording.name)" : "Play \(recording.name)")

                Divider().frame(height: 12)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").frame(width: 20, height: 20)
                }
                .help("Move recording to Trash")
                .accessibilityLabel("Move \(recording.name) to Trash")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    isSelected
                        ? Color.accentColor.opacity(0.14)
                        : Color(nsColor: .controlBackgroundColor)
                )
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelect)
        }
        .onChange(of: nameHasFocus) { _, focused in
            if !focused { commitName() }
        }
        .onChange(of: recording.name) { _, name in
            if !nameHasFocus { draftName = name }
        }
        .onDisappear(perform: commitName)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: Text("Select recording"), onSelect)
    }

    private func commitName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            draftName = recording.name
            return
        }
        guard trimmed != recording.name else { return }
        onRename(trimmed)
    }
}

private func recordingDurationLabel(_ duration: Double) -> String {
    let seconds = Int(min(Double(Int32.max), max(0, duration.isFinite ? duration : 0)))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
#endif
