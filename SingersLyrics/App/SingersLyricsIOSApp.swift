#if os(iOS)
import SwiftUI
import UIKit

@main
struct SingersLyricsIOSApp: App {
    @State private var appModel: AppModel
    @State private var playback: MusicPlaybackModel
    @AppStorage(PreferenceKey.appearance) private var appearance = Appearance.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let appModel = AppModel(store: JSONLibraryStore())
        let playback = MusicPlaybackModel(controller: IOSMusicController())
        appModel.voiceRecordings.prepareForAudio = { [weak playback] in
            await playback?.pauseForVoiceRecording() ?? false
        }
        playback.beforeStartingPlayback = { [weak appModel] in
            appModel?.voiceRecordings.stop()
        }
        _appModel = State(initialValue: appModel)
        _playback = State(initialValue: playback)
    }

    private var voiceAudioIsActive: Bool {
        appModel.voiceRecordings.recordingSongID != nil || appModel.voiceRecordings.playingSongID != nil
    }

    var body: some Scene {
        WindowGroup {
            MobileLibraryView(metadataLookup: ITunesTrackMetadataService())
                .environment(appModel)
                .environment(playback)
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
                .task {
                    appModel.cloudSync.setActive(scenePhase == .active)
                    await appModel.load()
                    await appModel.backfillLinkedTrackMetadata(using: ITunesTrackMetadataService())
                }
                .onChange(of: playback.playbackStartEvent) { _, event in
                    guard let event else { return }
                    appModel.recordPlayback(songID: event.songID, at: event.startedAt)
                }
                .keepsScreenAwake(voiceAudioIsActive)
        }
        .onChange(of: scenePhase) { _, phase in
            appModel.cloudSync.setActive(phase == .active)
            guard phase != .active else { return }
            // Inactive phases include the microphone permission prompt, so only
            // leaving for the background finishes a take before suspension.
            if phase == .background { appModel.voiceRecordings.stop() }
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
