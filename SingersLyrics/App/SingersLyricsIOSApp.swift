#if os(iOS)
import SwiftUI
import UIKit

@main
struct SingersLyricsIOSApp: App {
    @State private var appModel = AppModel(store: JSONLibraryStore())
    @State private var playback = MusicPlaybackModel(controller: IOSMusicController())
    @AppStorage(PreferenceKey.appearance) private var appearance = Appearance.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MobileLibraryView(metadataLookup: ITunesTrackMetadataService())
                .environment(appModel)
                .environment(playback)
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
                .task {
                    await appModel.load()
                    await appModel.backfillLinkedTrackMetadata(using: ITunesTrackMetadataService())
                }
                .onChange(of: playback.playbackStartEvent) { _, event in
                    guard let event else { return }
                    appModel.recordPlayback(songID: event.songID, at: event.startedAt)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            // Finish the pending autosave while iOS transitions out of the app.
            let taskID = UIApplication.shared.beginBackgroundTask(withName: "Save lyrics")
            Task {
                await appModel.flush()
                if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) }
            }
        }
    }
}
#endif
