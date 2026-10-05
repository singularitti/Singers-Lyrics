#if os(iOS)
import SwiftUI

/// Voice actions for one lyric card, sharing their row with the card's trailing
/// accessory. The take list expands inside the card, so recording and playback
/// errors can still be presented by the library.
struct MobileLineRecordingControls<Accessory: View>: View {
    let songID: UUID
    let line: LyricLine
    let lineNumber: Int
    @Binding var showsTakes: Bool
    let onSelect: (UUID) -> Void
    let onRename: (UUID, String) -> Void
    let onDelete: (UUID) -> Void
    @ViewBuilder let accessory: () -> Accessory

    @Environment(AppModel.self) private var model
    @State private var renamingRecordingID: UUID?
    @State private var draftName = ""

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
        VStack(alignment: .leading, spacing: 8) {
            // Larger text sizes shorten the take count, then give the accessory its own row.
            ViewThatFits(in: .horizontal) {
                actionRow(showsTakeTitle: true)
                actionRow(showsTakeTitle: false)
                VStack(alignment: .leading, spacing: 8) {
                    actions(showsTakeTitle: false)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        accessory()
                    }
                }
            }

            if showsTakes, !takes.isEmpty {
                takeList
            }
        }
        .alert("Rename Recording", isPresented: Binding(
            get: { renamingRecordingID != nil },
            set: { if !$0 { renamingRecordingID = nil } }
        )) {
            TextField("Recording name", text: $draftName)
            Button("Cancel", role: .cancel) { renamingRecordingID = nil }
            Button("Rename", action: commitRename)
        }
    }

    private func actionRow(showsTakeTitle: Bool) -> some View {
        HStack(spacing: 8) {
            actions(showsTakeTitle: showsTakeTitle)
            Spacer(minLength: 0)
            accessory()
        }
    }

    /// Record and Play are icon-only; while a take is in progress, Record also shows
    /// its status or elapsed time. The bordered style's padding brings each label
    /// to a 44-point-high capsule.
    private func actions(showsTakeTitle: Bool) -> some View {
        HStack(spacing: 8) {
            Button(action: toggleRecording) {
                HStack(spacing: 6) {
                    Image(systemName: recordSymbol)
                    if isRecording {
                        Text(recordTitle).monospacedDigit()
                    }
                }
                .frame(minWidth: 20, minHeight: 30)
            }
            .tint(isRecording ? Color.red : nil)
            .accessibilityLabel(isRecording
                ? (voice.isPreparing ? "Cancel recording preparation" : "Stop and save recording")
                : "Record lyric line \(lineNumber)")
            .accessibilityValue(isRecording && !voice.isPreparing ? "\(recordTitle) elapsed" : "")
            .accessibilityIdentifier("mobileRecordLine-\(lineNumber - 1)")

            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .frame(minWidth: 20, minHeight: 30)
            }
            .disabled(line.selectedRecording == nil && !isPlaying)
            .accessibilityLabel(isPlaying
                ? "Stop recording playback"
                : "Play \(line.selectedRecording?.name ?? "recording") for lyric line \(lineNumber)")
            .accessibilityIdentifier("mobilePlayRecording-\(lineNumber - 1)")

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showsTakes.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(showsTakeTitle ? takeCountTitle : "\(takes.count)")
                        .monospacedDigit()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(showsTakes ? 180 : 0))
                }
                .frame(minHeight: 30)
            }
            .disabled(takes.isEmpty)
            .accessibilityLabel(showsTakes
                ? "Hide recordings for lyric line \(lineNumber)"
                : "Show recordings for lyric line \(lineNumber)")
            .accessibilityValue(takeCountTitle)
            .accessibilityIdentifier("mobileRecordingTakes-\(lineNumber - 1)")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .font(.subheadline.weight(.medium))
    }

    private var takeList: some View {
        VStack(spacing: 0) {
            ForEach(takes) { take in
                takeRow(take)
                if take.id != takes.last?.id {
                    Divider().padding(.leading, 34)
                }
            }
        }
        .padding(.leading, 10)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recordings for line \(lineNumber)")
        .accessibilityIdentifier("mobileRecordingTakeList-\(lineNumber - 1)")
    }

    private func takeRow(_ take: VoiceRecording) -> some View {
        let isSelected = line.selectedRecording?.id == take.id
        let isPlayingTake = isPlaying && voice.playingRecordingID == take.id
        return HStack(spacing: 0) {
            Button { onSelect(take.id) } label: {
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(take.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text("\(take.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute().second()) · \(mobileRecordingDurationLabel(take.duration))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(take.name)
            .accessibilityValue(mobileRecordingDurationLabel(take.duration))
            .accessibilityHint(isSelected ? "" : "Uses this take for Play")
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            Button { play(take) } label: {
                Image(systemName: isPlayingTake ? "stop.fill" : "play.fill")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isPlayingTake ? "Stop \(take.name)" : "Play \(take.name)")

            Menu {
                Button("Rename", systemImage: "pencil") {
                    draftName = take.name
                    renamingRecordingID = take.id
                }
                Button("Move to Trash", systemImage: "trash", role: .destructive) {
                    onDelete(take.id)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Actions for \(take.name)")
        }
    }

    private var recordSymbol: String {
        guard isRecording else { return "record.circle" }
        return voice.isPreparing ? "xmark" : "stop.fill"
    }

    private var recordTitle: String {
        guard isRecording else { return "Record" }
        return voice.isPreparing ? "Preparing…" : mobileRecordingDurationLabel(voice.elapsed)
    }

    private var takeCountTitle: String {
        takes.count == 1 ? "1 Take" : "\(takes.count) Takes"
    }

    private var nextTakeName: String {
        let largest = line.recordings.compactMap { recording -> Int? in
            guard recording.name.hasPrefix("Take ") else { return nil }
            return Int(recording.name.dropFirst(5))
        }.max() ?? 0
        let next = largest < Int.max ? max(0, largest) + 1 : line.recordings.count + 1
        return "Take \(next)"
    }

    private func toggleRecording() {
        if isRecording {
            if voice.isPreparing { voice.cancelRecording() }
            else { voice.finishRecording() }
        } else {
            Task { await voice.record(songID: songID, lineID: line.id, name: nextTakeName) }
        }
    }

    private func togglePlayback() {
        if isPlaying {
            voice.stopPlayback()
        } else if let recording = line.selectedRecording {
            Task { await voice.play(recording, songID: songID, lineID: line.id) }
        }
    }

    private func play(_ take: VoiceRecording) {
        onSelect(take.id)
        if isPlaying && voice.playingRecordingID == take.id {
            voice.stopPlayback()
        } else {
            Task { await voice.play(take, songID: songID, lineID: line.id) }
        }
    }

    private func commitRename() {
        guard let recordingID = renamingRecordingID else { return }
        renamingRecordingID = nil
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let current = line.recordings.first(where: { $0.id == recordingID }),
              current.name != trimmed else { return }
        onRename(recordingID, trimmed)
    }
}

func mobileRecordingDurationLabel(_ duration: Double) -> String {
    // Clamp imported durations before conversion so even extreme finite values are safe.
    let seconds = Int(min(Double(Int32.max), max(0, duration.isFinite ? duration : 0)))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
#endif
