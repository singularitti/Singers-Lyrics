#if os(macOS)
import SwiftUI

struct RecordingsTrashView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<UUID> = []
    @State private var deletionRequest: RecordingDeletionRequest?
    @State private var showsDeletionConfirmation = false
    @State private var revealingIDs: Set<UUID> = []
    @State private var restoreStatus: String?
    @FocusState private var listHasFocus: Bool

    private var recordings: [TrashedRecording] {
        model.recordingsInTrash.sorted { lhs, rhs in
            if lhs.deletedAt != rhs.deletedAt { return lhs.deletedAt > rhs.deletedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private var recordingIDs: Set<UUID> {
        Set(model.recordingsInTrash.map(\.id))
    }

    private var trashedSongIDs: Set<UUID> {
        Set(model.library.trashedSongs.map(\.id))
    }

    private var pendingSongIDs: Set<UUID> {
        Set(model.library.trashedSongs.filter(\.isPendingPermanentDeletion).map(\.id))
    }

    private var restorableSelection: Set<UUID> {
        let blockedSongIDs = pendingSongIDs
        return selection.intersection(Set(model.recordingsInTrash
            .filter { !$0.isPendingPermanentDeletion && !blockedSongIDs.contains($0.songID) }
            .map(\.id)))
    }

    private var selectionSummary: String {
        if selection.isEmpty { return "Select recordings to restore or delete permanently." }
        if restorableSelection.count < selection.count {
            return "\(selection.count) selected · \(restorableSelection.count) can be restored"
        }
        return "\(selection.count) selected"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if recordings.isEmpty {
                ContentUnavailableView {
                    Text("No Deleted Recordings")
                } description: {
                    Text("All deleted recordings appear here, including those from deleted songs. Restore them or delete them permanently; lyrics are kept.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("recordingsTrashEmptyState")
            } else {
                recordingList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("recordingsTrashView")
        .onChange(of: recordingIDs) { _, ids in
            selection.formIntersection(ids)
        }
        .alert(
            deletionRequest?.title ?? "Delete Recordings Permanently?",
            isPresented: $showsDeletionConfirmation,
            presenting: deletionRequest
        ) { request in
            Button("Delete Permanently", role: .destructive) {
                // Use the confirmed snapshot, even if the list selection changes.
                let ids = request.ids
                deletionRequest = nil
                Task { await model.permanentlyDeleteRecordings(ids) }
            }
            .disabled(model.isPermanentlyDeletingTrash)
            .help("Confirm permanent deletion of the selected recordings and their audio files")
            .accessibilityLabel("Confirm permanent deletion of \(request.ids.count) recordings")
            .accessibilityIdentifier("confirmPermanentRecordingDeletionButton")
            Button("Cancel", role: .cancel) { deletionRequest = nil }
                .help("Keep these recordings in Trash")
                .accessibilityLabel("Cancel permanent recording deletion")
                .accessibilityIdentifier("cancelPermanentRecordingDeletionButton")
        } message: { request in
            Text(request.message)
        }
        .onChange(of: showsDeletionConfirmation) { _, isPresented in
            if !isPresented { deletionRequest = nil }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(recordings.count == 1 ? "1 recording" : "\(recordings.count) recordings")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("recordingsTrashCount")

            HStack(spacing: 10) {
                Button("Select All", action: selectAll)
                    .disabled(recordings.isEmpty || selection == recordingIDs || model.isPermanentlyDeletingTrash)
                    .help("Select every recording in Trash")
                    .accessibilityLabel("Select all recordings in Trash")
                    .accessibilityIdentifier("selectAllTrashedRecordingsButton")

                Button("Clear Selection") { selection = [] }
                    .disabled(selection.isEmpty || model.isPermanentlyDeletingTrash)
                    .help("Clear the selected recordings")
                    .accessibilityLabel("Clear recording selection")
                    .accessibilityIdentifier("clearTrashedRecordingSelectionButton")

                Spacer(minLength: 8)

                Button("Restore Selected", action: restoreSelection)
                    .disabled(restorableSelection.isEmpty || model.isPermanentlyDeletingTrash || !revealingIDs.isEmpty)
                    .help("Restore eligible selected recordings to their original song and lyric lines")
                    .accessibilityLabel("Restore \(restorableSelection.count) selected recordings")
                    .accessibilityIdentifier("restoreSelectedTrashedRecordingsButton")

                Button("Delete Permanently…", role: .destructive, action: requestDeletion)
                    .disabled(selection.isEmpty || model.isPermanentlyDeletingTrash || !revealingIDs.isEmpty)
                    .help("Permanently delete only the selected takes after confirmation, preserving songs, lyrics, and other takes")
                    .accessibilityLabel("Permanently delete \(selection.count) selected recordings")
                    .accessibilityIdentifier("deleteTrashedRecordingsPermanentlyButton")
            }
            .buttonStyle(.bordered)

            HStack(spacing: 8) {
                if model.isPermanentlyDeletingTrash {
                    ProgressView().controlSize(.small)
                    Text(model.isPermanentlyDeletingSongs
                        ? "Deleting songs permanently…" : "Deleting recordings permanently…")
                        .accessibilityIdentifier("recordingsTrashDeletionProgress")
                } else {
                    Text(selectionSummary)
                    Spacer()
                    Text("Use ⌘-click or Shift-click to select multiple recordings.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let restoreStatus {
                Text(restoreStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("recordingsTrashRestoreStatus")
            }
        }
        .padding(16)
    }

    private var recordingList: some View {
        List(selection: $selection) {
            ForEach(recordings) { entry in
                TrashedRecordingRow(
                    entry: entry,
                    isDeleting: model.isPermanentlyDeletingTrash,
                    isRevealing: revealingIDs.contains(entry.id),
                    isOwningSongInTrash: trashedSongIDs.contains(entry.songID),
                    isOwningSongPendingDeletion: pendingSongIDs.contains(entry.songID),
                    onReveal: { reveal(entry.id) }
                )
                .tag(entry.id)
            }
        }
        .listStyle(.inset)
        .focusable()
        .focused($listHasFocus)
        .onKeyPress(keys: ["a"], phases: .down) { press in
            guard listHasFocus, press.modifiers == .command,
                  !model.isPermanentlyDeletingTrash,
                  !showsDeletionConfirmation else { return .ignored }
            selectAll()
            return .handled
        }
        .accessibilityLabel("Deleted recordings")
        .accessibilityIdentifier("recordingsTrashList")
    }

    private func selectAll() {
        selection = recordingIDs
        listHasFocus = true
    }

    private func requestDeletion() {
        let ids = selection.intersection(recordingIDs)
        guard !ids.isEmpty, !model.isPermanentlyDeletingTrash,
              revealingIDs.isEmpty else { return }
        deletionRequest = RecordingDeletionRequest(ids: ids)
        showsDeletionConfirmation = true
    }

    private func restoreSelection() {
        let ids = restorableSelection
        guard !ids.isEmpty, !model.isPermanentlyDeletingTrash,
              revealingIDs.isEmpty, !showsDeletionConfirmation else { return }
        let owningSongsBeforeRestore = trashedSongIDs
        let owningSongsByRecording = Dictionary(uniqueKeysWithValues: recordings
            .filter { ids.contains($0.id) && owningSongsBeforeRestore.contains($0.songID) }
            .map { ($0.id, $0.songID) })
        let restoredIDs = model.restoreRecordings(ids).intersection(ids)
        selection.subtract(restoredIDs)
        if restoredIDs.isEmpty {
            restoreStatus = "No recordings were restored."
        } else {
            let count = restoredIDs.count
            restoreStatus = count == 1
                ? "Restored 1 recording to its original lyric line in Songs."
                : "Restored \(count) recordings to their original lyric lines in Songs."
        }
        let restoredOwningSongIDs = Set(restoredIDs.compactMap { owningSongsByRecording[$0] })
        let restoredSongCount = restoredOwningSongIDs.subtracting(trashedSongIDs).count
        if restoredSongCount > 0 {
            restoreStatus = (restoreStatus ?? "") + (restoredSongCount == 1
                ? " 1 owning song was also restored with its lyrics and attached recordings."
                : " \(restoredSongCount) owning songs were also restored with their lyrics and attached recordings.")
        }
        let remainingCount = selection.intersection(recordingIDs).count
        if remainingCount > 0 {
            restoreStatus = (restoreStatus ?? "") + (remainingCount == 1
                ? " 1 selected recording remains in Trash."
                : " \(remainingCount) selected recordings remain in Trash.")
        }
    }

    private func reveal(_ id: UUID) {
        guard !model.isPermanentlyDeletingTrash, !revealingIDs.contains(id) else { return }
        revealingIDs.insert(id)
        Task {
            await model.revealRecordingInFinder(id)
            revealingIDs.remove(id)
        }
    }
}

private struct RecordingDeletionRequest {
    let ids: Set<UUID>

    var title: String {
        ids.count == 1 ? "Delete 1 Recording Permanently?" : "Delete \(ids.count) Recordings Permanently?"
    }

    var message: String {
        if ids.count == 1 {
            return "The selected recording and its stored audio file will be permanently deleted. Its song, lyrics, and other recordings will be preserved. This cannot be undone."
        }
        return "The \(ids.count) selected recordings and their stored audio files will be permanently deleted. Their songs, lyrics, and other recordings will be preserved. This cannot be undone."
    }
}

private struct TrashedRecordingRow: View {
    let entry: TrashedRecording
    let isDeleting: Bool
    let isRevealing: Bool
    let isOwningSongInTrash: Bool
    let isOwningSongPendingDeletion: Bool
    let onReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(entry.recording.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(trashRecordingDurationLabel(entry.recording.duration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(action: onReveal) {
                    Label("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(.borderless)
                .disabled(isDeleting || isRevealing)
                .help("Reveal this recording’s stored audio file in Finder")
                .accessibilityLabel("Show \(entry.recording.name) in Finder")
                .accessibilityIdentifier("revealTrashedRecording-\(entry.id.uuidString)")
            }

            Text(songContext)
                .font(.subheadline)
                .lineLimit(2)

            if !entry.lyricText.isEmpty {
                Text(entry.lyricText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !entry.annotation.isEmpty {
                Text("Annotation: \(entry.annotation)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { recordedDate; deletedDate }
                VStack(alignment: .leading, spacing: 2) { recordedDate; deletedDate }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if entry.isPendingPermanentDeletion && !isDeleting {
                Label("Deletion incomplete. This recording cannot be restored. Select it and delete permanently again to retry.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("trashedRecordingPendingDeletion-\(entry.id.uuidString)")
            } else if isOwningSongPendingDeletion && !isDeleting {
                Label("The song is awaiting permanent deletion. This recording cannot be restored.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("trashedRecordingOwningSongPendingDeletion-\(entry.id.uuidString)")
            } else if isOwningSongInTrash && !isDeleting {
                Text("Restoring this recording also restores its song with its lyrics and attached recordings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trashedRecording-\(entry.id.uuidString)")
    }

    private var songContext: String {
        let title = entry.songTitle.isEmpty ? "Untitled Song" : entry.songTitle
        return entry.songArtist.isEmpty ? title : "\(title) — \(entry.songArtist)"
    }

    private var recordedDate: some View {
        Text("Recorded \(entry.recording.createdAt, format: .dateTime.year().month(.abbreviated).day().hour().minute().second())")
    }

    private var deletedDate: some View {
        Text("Deleted \(entry.deletedAt, format: .dateTime.year().month(.abbreviated).day().hour().minute().second())")
    }
}

private func trashRecordingDurationLabel(_ duration: Double) -> String {
    // Clamp imported durations before conversion so even extreme finite values are safe.
    let seconds = Int(min(Double(Int32.max), max(0, duration.isFinite ? duration : 0)))
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
#endif
