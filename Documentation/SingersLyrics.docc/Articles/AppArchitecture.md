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
| `AppModel` | Owns the library, selection, imports, metadata backfill, and autosave. |
| `LibraryStoring` | Separates persistent storage from the app model. |
| `JSONLibraryStore` | Reads and atomically saves the versioned library document. |
| `TrackMetadataLookingUp` | Separates Apple Music link metadata lookup from the interface. |
| `MusicControlling` | Defines playback state, open, play/pause, seek, and stop operations. |
| `MusicPlaybackModel` | Matches the selected song to playback, manages polling, and exposes timing state. |
| `AttributedTextCodec` | Converts shared styled text to AppKit, UIKit, and SwiftUI representations. |

`AppleMusicController` implements Mac playback with serialized Apple Events. `IOSMusicController` implements mobile playback with MediaPlayer. See <doc:MusicPlayback> for the request flow and identity checks.

### Coordinate loading and saving

`AppModel` coalesces concurrent initial loads into one task. A mobile file-open event waits for that load before importing. This prevents a later load completion from replacing a song imported while the first scene is appearing.

Edits update the model and schedule autosave. On iOS, a background task gives pending saves time to finish when the app leaves the foreground. Storage failures preserve the original document and disable autosave for the session; see <doc:LibraryAndDocuments>.

### Manage the mobile lifecycle

The mobile scene manifest permits one window. The library and editor/player screens share one app model and playback model, so switching modes keeps the song and playback session. Restricting the app to one scene avoids independent windows competing for the same player and polling target.

SwiftUI manages the iPhone navigation flow and iPad two-column presentation. Native `UITextView` instances provide lyric editing. The Mac app retains its native `NSTextView` integration and desktop window behavior.

## See Also

- <doc:InterfaceDesign>
- <doc:LibraryAndDocuments>
- <doc:AppResources>
