#if os(macOS)
import SwiftUI

struct SongsTrashView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<UUID> = []
    @State private var deletionRequest: SongDeletionRequest?
    @State private var showsDeletionConfirmation = false
    @State private var restoreStatus: String?
    @FocusState private var listHasFocus: Bool

    private var songs: [TrashedSong] {
        model.library.trashedSongs.sorted { lhs, rhs in
            if lhs.deletedAt != rhs.deletedAt { return lhs.deletedAt > rhs.deletedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private var songIDs: Set<UUID> {
        Set(model.library.trashedSongs.map(\.id))
    }

    private var restorableSelection: Set<UUID> {
        selection.intersection(Set(model.library.trashedSongs
            .filter { !$0.isPendingPermanentDeletion }
            .map(\.id)))
    }

    private var selectionSummary: String {
        if selection.isEmpty { return "Select songs to restore or delete permanently." }
        if restorableSelection.count < selection.count {
            return "\(selection.count) selected · \(restorableSelection.count) can be restored"
        }
        return "\(selection.count) selected"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if songs.isEmpty {
                ContentUnavailableView {
                    Text("No Deleted Songs")
                } description: {
                    Text("Restore songs with their lyrics and recordings, or delete them permanently.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("songsTrashEmptyState")
            } else {
                songList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("songsTrashView")
        .onChange(of: songIDs) { _, ids in
            selection.formIntersection(ids)
        }
        .alert(
            deletionRequest?.title ?? "Delete Songs Permanently?",
            isPresented: $showsDeletionConfirmation,
            presenting: deletionRequest
        ) { request in
            Button("Delete Permanently", role: .destructive) {
                let ids = request.ids
                deletionRequest = nil
                Task { await model.permanentlyDeleteSongs(ids) }
            }
            .disabled(model.isPermanentlyDeletingTrash)
            .help("Confirm permanent deletion of the selected songs and their attached recordings")
            .accessibilityLabel("Confirm permanent deletion of \(request.ids.count) songs")
            .accessibilityIdentifier("confirmPermanentSongDeletionButton")

            Button("Cancel", role: .cancel) { deletionRequest = nil }
                .help("Keep these songs in Trash")
                .accessibilityLabel("Cancel permanent song deletion")
                .accessibilityIdentifier("cancelPermanentSongDeletionButton")
        } message: { request in
            Text(request.message)
        }
        .onChange(of: showsDeletionConfirmation) { _, isPresented in
            if !isPresented { deletionRequest = nil }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(songs.count == 1 ? "1 song" : "\(songs.count) songs")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("songsTrashCount")

            HStack(spacing: 10) {
                Button("Select All", action: selectAll)
                    .disabled(songs.isEmpty || selection == songIDs || model.isPermanentlyDeletingTrash)
                    .help("Select every deleted song")
                    .accessibilityLabel("Select all songs in Trash")
                    .accessibilityIdentifier("selectAllTrashedSongsButton")

                Button("Clear Selection") { selection = [] }
                    .disabled(selection.isEmpty || model.isPermanentlyDeletingTrash)
                    .help("Clear the selected songs")
                    .accessibilityLabel("Clear song selection")
                    .accessibilityIdentifier("clearTrashedSongSelectionButton")

                Spacer(minLength: 8)

                Button("Restore Selected", action: restoreSelection)
                    .disabled(restorableSelection.isEmpty || model.isPermanentlyDeletingTrash)
                    .help("Restore eligible selected songs with their lyrics and attached recordings")
                    .accessibilityLabel("Restore \(restorableSelection.count) selected songs")
                    .accessibilityIdentifier("restoreSelectedTrashedSongsButton")

                Button("Delete Permanently…", role: .destructive, action: requestDeletion)
                    .disabled(selection.isEmpty || model.isPermanentlyDeletingTrash)
                    .help("Permanently delete the selected songs and their attached recordings after confirmation")
                    .accessibilityLabel("Permanently delete \(selection.count) selected songs")
                    .accessibilityIdentifier("deleteTrashedSongsPermanentlyButton")
            }
            .buttonStyle(.bordered)

            HStack(spacing: 8) {
                if model.isPermanentlyDeletingTrash {
                    ProgressView().controlSize(.small)
                    Text(model.isPermanentlyDeletingSongs
                        ? "Deleting songs permanently…" : "Deleting recordings permanently…")
                        .accessibilityIdentifier("songsTrashDeletionProgress")
                } else {
                    Text(selectionSummary)
                    Spacer()
                    Text("Use ⌘-click or Shift-click to select multiple songs.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let restoreStatus {
                Text(restoreStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("songsTrashRestoreStatus")
            }
        }
        .padding(16)
    }

    private var songList: some View {
        List(selection: $selection) {
            ForEach(songs) { entry in
                TrashedSongRow(entry: entry, isDeleting: model.isPermanentlyDeletingTrash)
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
        .accessibilityLabel("Deleted songs")
        .accessibilityIdentifier("songsTrashList")
    }

    private func selectAll() {
        selection = songIDs
        listHasFocus = true
    }

    private func requestDeletion() {
        let ids = selection.intersection(songIDs)
        guard !ids.isEmpty, !model.isPermanentlyDeletingTrash else { return }
        deletionRequest = SongDeletionRequest(ids: ids)
        showsDeletionConfirmation = true
    }

    private func restoreSelection() {
        let ids = restorableSelection
        guard !ids.isEmpty, !model.isPermanentlyDeletingTrash,
              !showsDeletionConfirmation else { return }
        let restoredIDs = model.restoreSongs(ids)
        selection.subtract(restoredIDs)
        if restoredIDs.isEmpty {
            restoreStatus = "No songs were restored."
        } else {
            restoreStatus = restoredIDs.count == 1
                ? "Restored 1 song with its lyrics and attached recordings to Songs."
                : "Restored \(restoredIDs.count) songs with their lyrics and attached recordings to Songs."
        }
        let remainingCount = selection.intersection(songIDs).count
        if remainingCount > 0 {
            restoreStatus = (restoreStatus ?? "") + (remainingCount == 1
                ? " 1 selected song remains in Trash."
                : " \(remainingCount) selected songs remain in Trash.")
        }
    }
}

private struct SongDeletionRequest {
    let ids: Set<UUID>

    var title: String {
        ids.count == 1 ? "Delete 1 Song Permanently?" : "Delete \(ids.count) Songs Permanently?"
    }

    var message: String {
        if ids.count == 1 {
            return "The selected song, its lyrics, and its attached recordings will be permanently deleted. This cannot be undone. Recordings deleted independently remain in the Recordings tab."
        }
        return "The \(ids.count) selected songs, their lyrics, and their attached recordings will be permanently deleted. This cannot be undone. Recordings deleted independently remain in the Recordings tab."
    }
}

private struct TrashedSongRow: View {
    let entry: TrashedSong
    let isDeleting: Bool

    private var attachedRecordingCount: Int {
        entry.song.lines.reduce(0) { $0 + $1.recordings.count }
    }

    private var lyricPreview: String? {
        entry.song.lines.lazy.map { $0.lyric.plainText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.song.title.isEmpty ? "Untitled Song" : entry.song.title)
                .font(.headline)
                .lineLimit(2)

            Text(entry.song.artist.isEmpty ? "Unknown Singer" : entry.song.artist)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 16) {
                Text(entry.song.lines.count == 1 ? "1 lyric line" : "\(entry.song.lines.count) lyric lines")
                Text(attachedRecordingCount == 1 ? "1 attached recording" : "\(attachedRecordingCount) attached recordings")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let lyricPreview {
                Text(lyricPreview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text("Deleted \(entry.deletedAt, format: .dateTime.year().month(.abbreviated).day().hour().minute().second())")
                .font(.caption)
                .foregroundStyle(.secondary)

            if entry.isPendingPermanentDeletion && !isDeleting {
                Label("Deletion incomplete. This song cannot be restored. Select it and delete permanently again to retry.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("trashedSongPendingDeletion-\(entry.id.uuidString)")
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("trashedSong-\(entry.id.uuidString)")
    }
}
#endif
