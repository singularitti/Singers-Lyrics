# App architecture

Understand the shared document model, platform services, and application lifecycle.

## Overview

SwiftUI supplies navigation, toolbars, menus, sheets, settings, and the workspace. AppKit and UIKit provide the native text editors and platform integration. The app uses Core Image, Core Animation, Foundation, and OSLog where needed. It has no web view, analytics, telemetry, app-hosted backend, or third-party runtime dependencies.

The personal-use workflow favors public native APIs and local storage. It must not require paid developer enrollment, an app-issued developer-token service, or a paid third-party API. Apple Music subscription content remains subject to the subscriber's access, and free device provisioning expires periodically.

### Locate the implementation

```text
SingersLyrics/
├── App/                 App entry points, commands, and authoritative model
├── Models/              Library, songs, styled lyrics, and timing values
├── Services/            Storage, playback, metadata lookup, and fonts
├── Features/
│   ├── Library/         Native Mac workspace and song management
│   ├── Editor/          AppKit rich-text editing and formatting
│   ├── Sync/            Timestamp adjustment controls
│   ├── Player/          Mac lyric presentation and transport controls
│   ├── Mobile/          iPhone and iPad navigation, editing, and playback
│   └── Settings/        Appearance and fallback-font settings
└── Resources/           Asset catalog and app icon
```

The Xcode project's synchronized source group shares code between targets. The iOS target excludes the Mac entry point and AppKit-specific feature views. Platform compilation conditions select the remaining AppKit or UIKit implementations.

### Share models and isolate platform services

| Component | Responsibility |
| --- | --- |
| `AppModel` | Owns the library, selection, imports, complete-song and recording Trash transitions, metadata backfill, and autosave. |
| `LibraryStoring` | Separates persistent storage from the app model. |
| `JSONLibraryStore` | Reads and saves library metadata, retains active and trashed audio, and permits explicit permanent deletion only after a pending marker is committed. |
| `VoiceRecordingController` | Owns the single microphone/player session, permissions, cancellation, completion callbacks to stable song/line IDs, and on iOS the shared `AVAudioSession` while a take records or plays. |
| `SongBundleCodec` | Exchanges version-2 document packages with a JSON manifest and separate audio files. |
| `TrackMetadataLookingUp` | Separates Apple Music link metadata lookup from the interface. |
| `MusicControlling` | Defines playback state, open, play/pause, seek, stop, and the explicit pause used before voice takes. |
| `MusicPlaybackModel` | Matches the selected song to playback, manages polling, and exposes timing state. |
| `LogicProRecordingModel` | On Mac, persists **Record in Logic Pro**, starts a Logic Pro take after a player play action, and sends Stop only to end that take. |
| `LogicProCommandSending` | Separates the MIDI transport from that model. `MIDILogicProCommandSender` publishes the Singers Lyrics virtual MIDI source. |
| `AttributedTextCodec` | Converts shared styled text to AppKit, UIKit, and SwiftUI representations. |

`AppleMusicController` implements Mac playback with serialized Apple Events. `IOSMusicController` implements mobile playback with MediaPlayer. See <doc:MusicPlayback> for the request flow and identity checks.

### Coordinate loading and saving

`AppModel` coalesces concurrent initial loads into one task. A mobile file-open event waits for that load before importing. This prevents a later load completion from replacing a song imported while the first scene is appearing.

Edits update the model and schedule autosave. On iOS, a background task gives pending saves time to finish when the app leaves the foreground. Storage failures preserve the original document and disable autosave for the session; see <doc:LibraryAndDocuments>.

Completing a voice take appends it through `AppModel` using its original song and line IDs. Removing its owner finishes a running capture before archiving the audio in Trash, or cancels a pending permission request, preventing late callbacks from attaching audio to another line. `replaceSong` detects removed recordings centrally, covering line edits, Undo/Redo, and imported lyric replacement. Saves are serialized, and a flush waits for the latest edits. Mac application termination finishes the active take and waits for persistence; a save failure offers the choice to keep the app open. On iOS, moving the scene to the background finishes the take before the background autosave. Inactive phases, such as the microphone permission prompt, leave a take running.

Both platforms connect `VoiceRecordingController.prepareForAudio` to `MusicPlaybackModel.pauseForVoiceRecording()` and `MusicPlaybackModel.beforeStartingPlayback` to stopping voice audio, so a take and the practice song never play at once. On iOS, the controller switches the shared audio session to play-and-record for capture or playback for listening, keeps it active when switching directly between takes, and restores the app's previous category with `notifyOthersOnDeactivation` once idle. Interruptions such as calls stop the recorder or player, and the capture made before the interruption is saved.

`LibraryDocument.trashedSongs` retains complete deleted songs and their original positions, including metadata, all lyric lines, styled text, annotations, timestamps, track links, favorites, tags, and attached recordings. Empty songs and lyric lines without audio are retained too. `trashedRecordings` holds recordings deleted individually, through lyric-line deletion, or through imported lyric replacement, with their original song/line identities and saved context. Audio keeps the same physical UUID paths in both collections. The Mac and mobile Trash views present Songs and Recordings tabs over the same `AppModel` operations. `AppModel.recordingsInTrash` combines individual entries with a projection of every take in deleted songs, carrying lyric context and parent pending state without duplicating persisted audio ownership.

Whole-song restoration restores the complete snapshot with stable identities and order. Previously deleted independent recordings remain separate. Restoring a projected or individual recording while its parent song is in Songs Trash restores the complete song first, then reattaches any selected individual takes; a pending parent song prevents restoration. When no complete snapshot exists, recording restoration uses only its saved context. Older song deletions cannot recover unrecorded lyric lines absent from that context.

Permanent deletion commits a pending marker before unlinking files, then removes the song or recording metadata after its files are removed. A pending song can tolerate partial removal of its attached audio, and pending entries remain retryable and cannot be restored. Permanently deleting a song removes its attached takes without removing independent recording Trash entries. Permanently deleting an individual take inside a deleted song atomically transfers that take from the song snapshot to an individual pending entry before unlinking it; the song and its other takes remain restorable. Session-level deleted IDs reject stale Undo attempts, and imports reserve identities across active songs and both Trash collections, remapping conflicts. Song package exports contain only active songs and recordings; the portable format remains version 2.

### Manage the mobile lifecycle

The mobile scene manifest permits one window. The library and editor/player screens share one app model and playback model, so switching modes keeps the song and playback session. Restricting the app to one scene avoids independent windows competing for the same player and polling target.

SwiftUI manages the iPhone navigation flow and iPad two-column presentation. Native `UITextView` instances provide lyric editing. The Mac app retains its native `NSTextView` integration and desktop window behavior.

## See Also

- <doc:InterfaceDesign>
- <doc:LibraryAndDocuments>
- <doc:AppResources>
