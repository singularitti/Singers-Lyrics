#if os(macOS)
import SwiftUI

struct TrashView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedTab = TrashTab.songs
    @State private var choseInitialTab = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Trash contents", selection: $selectedTab) {
                Text("Songs (\(model.library.trashedSongs.count))")
                    .tag(TrashTab.songs)
                Text("Recordings (\(model.recordingsInTrash.count))")
                    .tag(TrashTab.recordings)
            }
            .pickerStyle(.segmented)
            .help("Choose deleted songs or all deleted recordings, including recordings attached to deleted songs")
            .accessibilityLabel("Trash contents")
            .accessibilityIdentifier("trashContentsPicker")
            .padding(.horizontal, 16)
            .padding(.top, 16)

            switch selectedTab {
            case .songs:
                SongsTrashView()
            case .recordings:
                RecordingsTrashView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("trashView")
        .onAppear {
            guard !choseInitialTab else { return }
            choseInitialTab = true
            if model.library.trashedSongs.isEmpty && !model.recordingsInTrash.isEmpty {
                selectedTab = .recordings
            }
        }
    }
}

private enum TrashTab: Hashable {
    case songs
    case recordings
}
#endif
