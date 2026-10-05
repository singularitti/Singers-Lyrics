#if os(iOS)
import SwiftUI

/// Deleted songs and recordings on this device. Swipe or long-press a row to
/// restore or permanently delete it; Select enables multiple selection.
struct MobileTrashView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedTab = MobileTrashTab.songs
    @State private var choseInitialTab = false

    var body: some View {
        Group {
            switch selectedTab {
            case .songs:
                MobileSongsTrashList()
            case .recordings:
                MobileRecordingsTrashList()
            }
        }
        .safeAreaBar(edge: .top) {
            VStack(spacing: 8) {
                Picker("Trash contents", selection: $selectedTab) {
                    Text("Songs (\(model.library.trashedSongs.count))")
                        .tag(MobileTrashTab.songs)
                    Text("Recordings (\(model.recordingsInTrash.count))")
                        .tag(MobileTrashTab.recordings)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Trash contents")
                .accessibilityIdentifier("mobileTrashContentsPicker")

                if model.isPermanentlyDeletingTrash {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(model.isPermanentlyDeletingSongs
                            ? "Deleting songs permanently…" : "Deleting recordings permanently…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("mobileTrashDeletionProgress")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .navigationTitle("Trash")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("mobileTrashView")
        .onAppear {
            guard !choseInitialTab else { return }
            choseInitialTab = true
            if model.library.trashedSongs.isEmpty && !model.recordingsInTrash.isEmpty {
                selectedTab = .recordings
            }
        }
    }
}

private enum MobileTrashTab: Hashable {
    case songs
    case recordings
}

private struct MobileSongsTrashList: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<UUID> = []
    @State private var editMode = EditMode.inactive
    @State private var deletionRequest: MobileSongDeletionRequest?
    @State private var restoreStatus: String?

    private var songs: [TrashedSong] {
        model.library.trashedSongs.sorted { lhs, rhs in
            if lhs.deletedAt != rhs.deletedAt { return lhs.deletedAt > rhs.deletedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private var songIDs: Set<UUID> {
        Set(model.library.trashedSongs.map(\.id))
    }

    private var restorableIDs: Set<UUID> {
        Set(model.library.trashedSongs.filter { !$0.isPendingPermanentDeletion }.map(\.id))
    }

    private var selectionSummary: String {
        let restorableCount = selection.intersection(restorableIDs).count
        if selection.isEmpty { return "Select songs to restore or delete permanently." }
        if restorableCount < selection.count {
            return "\(selection.count) selected · \(restorableCount) can be restored"
        }
        return "\(selection.count) selected"
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(songs) { entry in
                    MobileTrashedSongRow(entry: entry, isDeleting: model.isPermanentlyDeletingTrash)
                        .tag(entry.id)
                        .swipeActions(edge: .leading) {
                            if restorableIDs.contains(entry.id) {
                                Button("Restore", systemImage: "arrow.uturn.backward") { restore([entry.id]) }
                                    .tint(.green)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                requestDeletion([entry.id])
                            }
                        }
                }
            } header: {
                if editMode.isEditing || !selection.isEmpty {
                    Text(selectionSummary)
                        .textCase(nil)
                } else if let restoreStatus {
                    Text(restoreStatus)
                        .textCase(nil)
                        .accessibilityIdentifier("mobileSongsTrashRestoreStatus")
                }
            }
        }
        .environment(\.editMode, $editMode)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if !ids.isEmpty {
                Button("Restore", systemImage: "arrow.uturn.backward") { restore(ids) }
                    .disabled(ids.isDisjoint(with: restorableIDs) || model.isPermanentlyDeletingTrash)
                Button("Delete Permanently…", systemImage: "trash", role: .destructive) {
                    requestDeletion(ids)
                }
                .disabled(model.isPermanentlyDeletingTrash)
            }
        }
        .overlay {
            if songs.isEmpty {
                ContentUnavailableView {
                    Label("No Deleted Songs", systemImage: "trash")
                } description: {
                    Text("Restore songs with their lyrics and recordings, or delete them permanently.")
                }
                .accessibilityIdentifier("mobileSongsTrashEmptyState")
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                MobileTrashSelectButton(editMode: $editMode, selection: $selection, isEmpty: songs.isEmpty)
            }
            if editMode.isEditing || !selection.isEmpty {
                ToolbarItemGroup(placement: .bottomBar) {
                    MobileTrashSelectAllButton(selection: $selection, allIDs: songIDs)
                    Spacer()
                    Button("Restore") { restore(selection) }
                        .disabled(selection.isDisjoint(with: restorableIDs) || model.isPermanentlyDeletingTrash)
                        .accessibilityLabel("Restore \(selection.intersection(restorableIDs).count) selected songs")
                        .accessibilityIdentifier("mobileRestoreSelectedTrashedSongsButton")
                    Button("Delete", role: .destructive) { requestDeletion(selection) }
                        .disabled(selection.isEmpty || model.isPermanentlyDeletingTrash)
                        .accessibilityLabel("Permanently delete \(selection.count) selected songs")
                        .accessibilityIdentifier("mobileDeleteTrashedSongsPermanentlyButton")
                }
            }
        }
        .alert(
            deletionRequest?.title ?? "Delete Songs Permanently?",
            isPresented: Binding(get: { deletionRequest != nil }, set: { if !$0 { deletionRequest = nil } }),
            presenting: deletionRequest
        ) { request in
            Button("Delete Permanently", role: .destructive) {
                let ids = request.ids
                deletionRequest = nil
                Task { await model.permanentlyDeleteSongs(ids) }
            }
            .accessibilityIdentifier("mobileConfirmPermanentSongDeletionButton")
            Button("Cancel", role: .cancel) { deletionRequest = nil }
        } message: { request in
            Text(request.message)
        }
        .onChange(of: songIDs) { _, ids in
            selection.formIntersection(ids)
            if ids.isEmpty { editMode = .inactive }
        }
        .accessibilityIdentifier("mobileSongsTrashList")
    }

    private func requestDeletion(_ ids: Set<UUID>) {
        let ids = ids.intersection(songIDs)
        guard !ids.isEmpty, !model.isPermanentlyDeletingTrash else { return }
        deletionRequest = MobileSongDeletionRequest(ids: ids)
    }

    private func restore(_ requestedIDs: Set<UUID>) {
        let ids = requestedIDs.intersection(restorableIDs)
        guard !ids.isEmpty, !model.isPermanentlyDeletingTrash else { return }
        let restoredIDs = model.restoreSongs(ids)
        selection.subtract(restoredIDs)
        var status = switch restoredIDs.count {
        case 0: "No songs were restored."
        case 1: "Restored 1 song with its lyrics and attached recordings to your library."
        default: "Restored \(restoredIDs.count) songs with their lyrics and attached recordings to your library."
        }
        let remainingCount = requestedIDs.intersection(songIDs).count
        if remainingCount > 0 {
            status += remainingCount == 1
                ? " 1 selected song remains in Trash."
                : " \(remainingCount) selected songs remain in Trash."
        }
        restoreStatus = status
    }
}

private struct MobileRecordingsTrashList: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<UUID> = []
    @State private var editMode = EditMode.inactive
    @State private var deletionRequest: MobileRecordingDeletionRequest?
    @State private var restoreStatus: String?

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

    private var restorableIDs: Set<UUID> {
        let blockedSongIDs = pendingSongIDs
        return Set(model.recordingsInTrash
            .filter { !$0.isPendingPermanentDeletion && !blockedSongIDs.contains($0.songID) }
            .map(\.id))
    }

    private var selectionSummary: String {
        let restorableCount = selection.intersection(restorableIDs).count
        if selection.isEmpty { return "Select recordings to restore or delete permanently." }
        if restorableCount < selection.count {
            return "\(selection.count) selected · \(restorableCount) can be restored"
        }
        return "\(selection.count) selected"
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(recordings) { entry in
                    MobileTrashedRecordingRow(
                        entry: entry,
                        isDeleting: model.isPermanentlyDeletingTrash,
                        isOwningSongInTrash: trashedSongIDs.contains(entry.songID),
                        isOwningSongPendingDeletion: pendingSongIDs.contains(entry.songID)
                    )
                    .tag(entry.id)
                    .swipeActions(edge: .leading) {
                        if restorableIDs.contains(entry.id) {
                            Button("Restore", systemImage: "arrow.uturn.backward") { restore([entry.id]) }
                                .tint(.green)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            requestDeletion([entry.id])
                        }
                    }
                }
            } header: {
                if editMode.isEditing || !selection.isEmpty {
                    Text(selectionSummary)
                        .textCase(nil)
                } else if let restoreStatus {
                    Text(restoreStatus)
                        .textCase(nil)
                        .accessibilityIdentifier("mobileRecordingsTrashRestoreStatus")
                }
            }
        }
        .environment(\.editMode, $editMode)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if !ids.isEmpty {
                Button("Restore", systemImage: "arrow.uturn.backward") { restore(ids) }
                    .disabled(ids.isDisjoint(with: restorableIDs) || model.isPermanentlyDeletingTrash)
                Button("Delete Permanently…", systemImage: "trash", role: .destructive) {
                    requestDeletion(ids)
                }
                .disabled(model.isPermanentlyDeletingTrash)
            }
        }
        .overlay {
            if recordings.isEmpty {
                ContentUnavailableView {
                    Label("No Deleted Recordings", systemImage: "waveform")
                } description: {
                    Text("All deleted recordings appear here, including those from deleted songs. Restore them or delete them permanently; lyrics are kept.")
                }
                .accessibilityIdentifier("mobileRecordingsTrashEmptyState")
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                MobileTrashSelectButton(editMode: $editMode, selection: $selection, isEmpty: recordings.isEmpty)
            }
            if editMode.isEditing || !selection.isEmpty {
                ToolbarItemGroup(placement: .bottomBar) {
                    MobileTrashSelectAllButton(selection: $selection, allIDs: recordingIDs)
                    Spacer()
                    Button("Restore") { restore(selection) }
                        .disabled(selection.isDisjoint(with: restorableIDs) || model.isPermanentlyDeletingTrash)
                        .accessibilityLabel("Restore \(selection.intersection(restorableIDs).count) selected recordings")
                        .accessibilityIdentifier("mobileRestoreSelectedTrashedRecordingsButton")
                    Button("Delete", role: .destructive) { requestDeletion(selection) }
                        .disabled(selection.isEmpty || model.isPermanentlyDeletingTrash)
                        .accessibilityLabel("Permanently delete \(selection.count) selected recordings")
                        .accessibilityIdentifier("mobileDeleteTrashedRecordingsPermanentlyButton")
                }
            }
        }
        .alert(
            deletionRequest?.title ?? "Delete Recordings Permanently?",
            isPresented: Binding(get: { deletionRequest != nil }, set: { if !$0 { deletionRequest = nil } }),
            presenting: deletionRequest
        ) { request in
            Button("Delete Permanently", role: .destructive) {
                // Use the confirmed snapshot, even if the list selection changes.
                let ids = request.ids
                deletionRequest = nil
                Task { await model.permanentlyDeleteRecordings(ids) }
            }
            .accessibilityIdentifier("mobileConfirmPermanentRecordingDeletionButton")
            Button("Cancel", role: .cancel) { deletionRequest = nil }
        } message: { request in
            Text(request.message)
        }
        .onChange(of: recordingIDs) { _, ids in
            selection.formIntersection(ids)
            if ids.isEmpty { editMode = .inactive }
        }
        .accessibilityIdentifier("mobileRecordingsTrashList")
    }

    private func requestDeletion(_ ids: Set<UUID>) {
        let ids = ids.intersection(recordingIDs)
        guard !ids.isEmpty, !model.isPermanentlyDeletingTrash else { return }
        deletionRequest = MobileRecordingDeletionRequest(ids: ids)
    }

    private func restore(_ requestedIDs: Set<UUID>) {
        let ids = requestedIDs.intersection(restorableIDs)
        guard !ids.isEmpty, !model.isPermanentlyDeletingTrash else { return }
        let owningSongsBeforeRestore = trashedSongIDs
        let owningSongsByRecording = Dictionary(
            recordings
                .filter { ids.contains($0.id) && owningSongsBeforeRestore.contains($0.songID) }
                .map { ($0.id, $0.songID) },
            uniquingKeysWith: { first, _ in first }
        )
        let restoredIDs = model.restoreRecordings(ids).intersection(ids)
        selection.subtract(restoredIDs)
        var status = switch restoredIDs.count {
        case 0: "No recordings were restored."
        case 1: "Restored 1 recording to its original lyric line."
        default: "Restored \(restoredIDs.count) recordings to their original lyric lines."
        }
        let restoredOwningSongIDs = Set(restoredIDs.compactMap { owningSongsByRecording[$0] })
        let restoredSongCount = restoredOwningSongIDs.subtracting(trashedSongIDs).count
        if restoredSongCount > 0 {
            status += restoredSongCount == 1
                ? " 1 owning song was also restored with its lyrics and attached recordings."
                : " \(restoredSongCount) owning songs were also restored with their lyrics and attached recordings."
        }
        let remainingCount = requestedIDs.intersection(recordingIDs).count
        if remainingCount > 0 {
            status += remainingCount == 1
                ? " 1 selected recording remains in Trash."
                : " \(remainingCount) selected recordings remain in Trash."
        }
        restoreStatus = status
    }
}

private struct MobileTrashSelectButton: View {
    @Binding var editMode: EditMode
    @Binding var selection: Set<UUID>
    let isEmpty: Bool

    var body: some View {
        Button(editMode.isEditing ? "Done" : "Select") {
            withAnimation {
                if editMode.isEditing {
                    editMode = .inactive
                    selection = []
                } else {
                    editMode = .active
                }
            }
        }
        .disabled(isEmpty && !editMode.isEditing)
        .accessibilityIdentifier("mobileTrashSelectButton")
    }
}

private struct MobileTrashSelectAllButton: View {
    @Binding var selection: Set<UUID>
    let allIDs: Set<UUID>

    var body: some View {
        if !allIDs.isEmpty && selection == allIDs {
            Button("Deselect All") { selection = [] }
        } else {
            Button("Select All") { selection = allIDs }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(allIDs.isEmpty)
        }
    }
}

private struct MobileSongDeletionRequest {
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

private struct MobileRecordingDeletionRequest {
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

private struct MobileTrashedSongRow: View {
    let entry: TrashedSong
    let isDeleting: Bool

    private var attachedRecordingCount: Int {
        entry.song.lines.reduce(0) { $0 + $1.recordings.count }
    }

    private var lyricPreview: String? {
        entry.song.lines.lazy.map { $0.lyric.plainText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private var contentSummary: String {
        let lineCount = entry.song.lines.count
        let lines = lineCount == 1 ? "1 lyric line" : "\(lineCount) lyric lines"
        let recordings = attachedRecordingCount == 1
            ? "1 attached recording" : "\(attachedRecordingCount) attached recordings"
        return "\(lines) · \(recordings)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.song.title.isEmpty ? "Untitled Song" : entry.song.title)
                .font(.headline)
                .lineLimit(2)

            Text(entry.song.artist.isEmpty ? "Unknown Singer" : entry.song.artist)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let lyricPreview {
                Text(lyricPreview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text(contentSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Deleted \(entry.deletedAt, format: .dateTime.year().month(.abbreviated).day().hour().minute().second())")
                .font(.caption)
                .foregroundStyle(.secondary)

            if entry.isPendingPermanentDeletion && !isDeleting {
                Label("Deletion incomplete. This song cannot be restored. Delete it permanently again to retry.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mobileTrashedSongPendingDeletion-\(entry.id.uuidString)")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mobileTrashedSong-\(entry.id.uuidString)")
    }
}

private struct MobileTrashedRecordingRow: View {
    let entry: TrashedRecording
    let isDeleting: Bool
    let isOwningSongInTrash: Bool
    let isOwningSongPendingDeletion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(entry.recording.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(mobileRecordingDurationLabel(entry.recording.duration))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(songContext)
                .font(.subheadline)
                .lineLimit(2)

            if !entry.lyricText.isEmpty {
                Text(entry.lyricText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if !entry.annotation.isEmpty {
                Text("Annotation: \(entry.annotation)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text("Recorded \(entry.recording.createdAt, format: .dateTime.year().month(.abbreviated).day().hour().minute().second())")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Deleted \(entry.deletedAt, format: .dateTime.year().month(.abbreviated).day().hour().minute().second())")
                .font(.caption)
                .foregroundStyle(.secondary)

            if entry.isPendingPermanentDeletion && !isDeleting {
                Label("Deletion incomplete. This recording cannot be restored. Delete it permanently again to retry.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mobileTrashedRecordingPendingDeletion-\(entry.id.uuidString)")
            } else if isOwningSongPendingDeletion && !isDeleting {
                Label("The song is awaiting permanent deletion. This recording cannot be restored.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mobileTrashedRecordingOwningSongPendingDeletion-\(entry.id.uuidString)")
            } else if isOwningSongInTrash && !isDeleting {
                Text("Restoring this recording also restores its song with its lyrics and attached recordings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mobileTrashedRecording-\(entry.id.uuidString)")
    }

    private var songContext: String {
        let title = entry.songTitle.isEmpty ? "Untitled Song" : entry.songTitle
        return entry.songArtist.isEmpty ? title : "\(title) — \(entry.songArtist)"
    }
}
#endif
