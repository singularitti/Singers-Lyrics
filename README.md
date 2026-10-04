# Singers Lyrics

Singers Lyrics is a native Mac, iPhone, and iPad application for editing richly styled lyrics, synchronizing them to Apple Music playback, and presenting them in a karaoke-style player.

The Mac Xcode target and Swift module are named `SingersLyrics`; the iPhone/iPad target and scheme are `SingersLyrics-iOS`. The visible product name is **Singers Lyrics**. The app uses only Apple frameworks, including SwiftUI, AppKit on Mac, UIKit and MediaPlayer on iOS, Core Image, Core Animation, Foundation, and OSLog. It has no package-manager, JavaScript, web-view, analytics, telemetry, or third-party runtime dependencies.

## Requirements

- macOS 26 for the Mac app, or iOS/iPadOS 26 for the mobile app
- The full Xcode application at `/Applications/Xcode.app`

The platform SDKs are supplied by Xcode and must not be copied into this repository or bundled with the app.

## Build and test

Open `SingersLyrics.xcodeproj` in Xcode and select the `SingersLyrics` scheme, or build without changing the system-wide developer directory:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project SingersLyrics.xcodeproj \
  -scheme SingersLyrics \
  -destination 'platform=macOS,arch=arm64' \
  build
```

Unit tests are run only when explicitly requested, as required by the project agent instructions. For a requested unit-test run, use the fast scheme. Once it has been built, the tests typically complete in about one to two seconds:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project SingersLyrics.xcodeproj \
  -scheme SingersLyricsFast \
  -destination 'platform=macOS,arch=arm64' \
  test
```

For an explicitly requested full validation run before release or after UI changes, use the complete unit and UI suite:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project SingersLyrics.xcodeproj \
  -scheme SingersLyrics \
  -destination 'platform=macOS,arch=arm64' \
  test
```

The project uses Swift 6 strict concurrency. The Mac target uses local ad-hoc signing and no App Sandbox for the initial local-only release. Developer ID signing, notarization, sandboxing, and Mac App Store distribution are intentionally deferred. The iOS target uses the normal application sandbox and automatic signing without a checked-in development team.

## iPhone and iPad

Choose the **SingersLyrics-iOS** scheme in Xcode. To build against the simulator SDK without signing or launching a simulator:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project SingersLyrics.xcodeproj \
  -scheme SingersLyrics-iOS \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

To run on an iPhone or iPad, click the blue project icon in Xcode's Project navigator (**⌘1**), select **TARGETS → SingersLyrics-iOS**, then open **Signing & Capabilities** across the top of the editor. Enable automatic signing and select your team. A free Apple Account's **Personal Team** can install a development build on your own devices; Apple limits these provisioning profiles to seven days, so they need periodic rebuilding. Choose the device as the run destination, enable Developer Mode on it, and press **⌘R**. The target includes the Apple Music usage description. A simulator runtime is needed for simulator launches; compiling against the SDK alone does not validate touch interaction or music playback.

On iPhone, launch opens **Music**, the searchable song library. Selecting a song opens its editor. A labeled **Player** button at the top right switches the same song into presentation mode; **Editor** in the same position returns to editing. Back navigation returns to the library. These are screens in one navigation flow, so switching modes keeps the same song and playback session.

On iPad, the library and the selected editor or player occupy two columns. The system sidebar control can hide or reveal the library, and narrow iPad windows collapse to the phone navigation flow. Playback controls remain centered at the bottom of the detail column, above the home indicator. Lyrics wrap to the available width. Text size, seeking, play/pause, and resume-following controls stay together in that bottom panel; the mode switch remains in the navigation bar. Manual scrolling pauses lyric following until playback or the Follow Current Lyric button resumes it.

The mobile editor uses a native `UITextView` for each lyric line, preserves styled runs, and supports annotations, bold/italic/underline, colors, fonts, symbols, line insertion/deletion, and timing. Return splits a lyric while preserving its styles. A compact timing dock stamps the selected line and advances; timing options provide fine adjustments. Formatting controls appear when editing lyric text, and keyboard dismissal is explicit. Song details, link replacement, lyric import, and export are in the editor's song menu. Importing plain text or LRC explicitly confirms replacement of the existing lyric lines.

The library's add menu accepts Apple Music links or `.singerslyrics` bundles. Song bundles preserve the same versioned schema on all three platforms, including formatting, annotations, timestamps, display metadata, tags, and linked-track metadata. Share or AirDrop a bundle from Mac, then open it in Singers Lyrics or choose **Import Song Bundle** from Files. LRC files are imported into a selected song through **Import Lyrics → Choose File**. Libraries are local to each installation; automatic cloud synchronization is not included.

iOS uses MediaPlayer's in-app `MPMusicPlayerController.applicationMusicPlayer` with a one-song store queue built directly from the linked song's ID. It prepares that queue before starting playback and reads the current item's identity, duration, and position for lyric synchronization. Music access is requested on the first playback action, not at launch. Actual playback depends on authorization, an Apple Music account with playback access, song availability in its storefront, and network or downloaded-content availability. Permission denial offers a Settings link. The iOS app does not use Apple Events or require Mac Automation access.

The playback path does not make MusicKit catalog, subscription, or developer-token requests, and there is no developer token to configure or store. MediaPlayer's public store-ID queue API lets the app request playback without MusicKit App Service registration in the developer portal. A Personal Team build has been installed and audible playback verified on a physical iPad. That check covers the tested device and music account; availability still depends on Apple's playback service and the requested song. See Apple's [application player documentation](https://developer.apple.com/documentation/mediaplayer/mpmusicplayercontroller/applicationmusicplayer) and [membership comparison](https://developer.apple.com/support/compare-memberships/).

Playback failures distinguish permission, account capability, song availability, network, and player errors. **Technical Details** shows the failed step and a sanitized error category/code; it never displays tokens, account identifiers, song URLs, or Apple's raw error payloads. Subscription guidance is based on a reported playback-capability error, rather than being shown for every failure.

If both Singers Lyrics and Apple's Music app advance silently while developing, stop Xcode Device Hub screen sharing and try again, then check Control Center's audio output and media volume. Stopping device screen sharing restored audible playback during the physical iPad check. A silent output alone does not establish a subscription or app-authorization failure.

### API choices, local data, and offline limits

The personal-use app uses public native APIs and local storage. Its core workflow must not require paid developer enrollment, an app-hosted backend, a custom developer-token service, or a paid third-party API. An Apple Music subscription remains necessary for subscription catalog content, and free Personal Team provisioning still expires periodically.

| Platform | Playback implementation | Reason |
| --- | --- | --- |
| Native macOS | Serialized Apple Events through `NSAppleScript` | Controls the installed Music app locally using its supported scripting interface. |
| iPhone and iPad | MediaPlayer's application music player | Provides an in-app one-song queue, playback position, seeking, and media-library authorization without app-issued developer tokens. |

`MPMusicPlayerController` is available to iOS/iPadOS and Mac Catalyst, but is unavailable to the existing native macOS target. Catalyst would require a different app target and interface integration. Keeping the current Mac playback controller preserves the established desktop behavior. See Apple's [platform availability](https://developer.apple.com/documentation/mediaplayer/mpmusicplayercontroller).

Lyrics, annotations, formatting, timestamps, preferences, and the library document are stored on the device. Apple Music link import, link replacement, and metadata backfill use Apple's public iTunes Lookup endpoint to obtain title, artist, and album metadata. Those requests require connectivity but no developer token or API payment. Apple-managed playback may also use online account, catalog, or streaming services.

Apple Music supports [downloaded songs for offline listening](https://support.apple.com/en-us/118288). Those downloads remain managed by Apple Music and its subscription authorization. The Mac controller already searches the Music library before opening a song link, allowing Music to play a downloaded matching item. The iOS controller currently queues a store ID; it does not explicitly select the downloaded library item, and offline startup through that path has not been verified. Looking up a matching downloaded item before falling back to a store queue is future work. Direct audio-file import is also not implemented. Downloading music does not guarantee that the app makes no network requests.

### Shared state and document compatibility

The iOS target shares the version-1 library and song-bundle schema with the Mac target. UIKit and AppKit have separate attributed-text bridges. When a Mac font is unavailable on iOS, the mobile editor displays a substitute while retaining the explicit family name and intended bold/italic traits in stored-attribute markers. Saving and exporting preserve those choices for a later return to the Mac. Adaptive foreground colors and semantic fallback fonts retain their existing behavior on both platforms.

Mobile file-open handling waits for a coalesced initial library load before importing, preventing a later load completion from overwriting imported songs. Autosaves are flushed when the app leaves the foreground. The mobile scene manifest permits one window so independent windows cannot compete for the shared player and polling target.

The shared playback model accepts state only for the selected song. On iOS it compares the actual player's store identity with the saved link's ID when available, and it retains the existing metadata matching for library identities. Operation generations prevent older asynchronous results from updating a newer playback action. Timing controls require an identified, ready playback session. Failures remain visible through polling until a new action or target change, and the player view retains same-song repetition at the end of playback.

### Validation

The implementation has passed macOS, iOS simulator, and signed iOS-device builds. The device build was installed and launched on a physical iPad, where audible playback was confirmed after stopping Xcode Device Hub screen sharing. The simulator build verifies compilation against that SDK; it does not establish simulator runtime or playback behavior. Compilation and the device playback check do not cover every interaction or offline behavior. Unit tests were not run because they were not requested.

Before device release, manually verify the remaining behavior:

1. Library-first launch, selecting a song, switching modes, and back navigation on iPhone.
2. Two columns on iPad, sidebar visibility, rotation, and compact multitasking windows.
3. Editing with the keyboard visible, Return splitting, selection formatting, undo, annotations, and large accessibility text sizes.
4. Bundle transfer in both directions, including explicit Mac fonts unavailable on iOS; saving and reopening must preserve their stored names and styles.
5. Authorization, actual Apple Music playback, pause/seek, tapping lyrics, timing stamps, and repeating the selected song in player mode on a signed device.
6. Denied access, unavailable songs, background/foreground transitions, and opening a song bundle while the app is launching.

The existing unit-test targets remain Mac targets; run unit tests only when explicitly requested.

## Main workflows

Choose **New Song from Apple Music** and paste a supported HTTPS Apple Music song link. The app validates the link, looks up its public track metadata, and creates the song only after that lookup succeeds. Title and singer can be changed independently from the song’s management menu in the library sidebar. The linked track retains separate Music metadata for playback, and replacing its Apple Music link refreshes that metadata without overwriting the title and singer shown in the app. Older library entries receive this separate metadata from their saved links in the background. Playback first asks Music for the linked track’s title and artist, then falls back to opening the saved link.

The main window presents three columns: the song library, lyric editor, and a prominent live preview/player. A view-only `Title | Singer` header sits in the editor side of the toolbar and truncates within the editor boundary. Its frosted backdrop blurs passing lyrics with the editor’s background color, stays within the editor column, and disappears in player-only mode. Reduce Transparency uses an opaque editor-colored backdrop. The library supports Command-click and Shift-click multi-selection for bulk deletion, duplication, and lossless export. The toolbar export action and the sidebar context menu write every selected song to one `.singerslyrics` bundle. When the library is empty or no song is selected, one workspace-wide panel offers both the shared add-song action and an import action for one of these bundles. The sidebar plus menu offers the same Apple Music and song-bundle choices. That menu and Sort share a fixed group pinned to the library edge, with a six-point internal gap. The sidebar hides automatically when the window can no longer fit all three columns and restores after widening leaves enough room for its chosen width. Separate collapse and restore thresholds keep it stable near the breakpoint. The app owns the sidebar layout and a single visibility toggle, so resizing cannot introduce another system toggle or expand the window to restore the sidebar. Manually hiding it is preserved across resizing; showing it again is available when the panels fit. The sidebar divider remains draggable. The metadata title stays anchored to the editor’s left edge and truncates with an ellipsis inside its right boundary, including while the sidebar is hidden. The sidebar toggle keeps an inset from the sidebar divider. Toolbar positions follow the actual column boundaries as either divider moves. Only the sidebar material extends behind the window controls, avoiding a blurred copy of the section headings. The workspace control group retains the explicit editor-only and player-only actions. The search field and three distinct compact control-group capsules are right-aligned together for song management, lyric import/export, and workspace visibility. The action capsules retain fixed readable widths and stay inside the player column. Search shrinks first as that column narrows, regardless of the window width, then becomes a circular magnifier with a search popover if a readable field no longer fits. Player mode presents a centered title larger than the lyrics, with the singer before the first lyric; they scroll away with the lyrics but remain outside the timed lyric collection, so line 1 is still synchronization index 0.

Player lyrics blur and fade into the player-colored titlebar through a soft gradient below the toolbar. The backdrop samples the actual scrolling content without reflecting or duplicating lyrics, stays aligned to the player column in split and player-only layouts, and uses an opaque titlebar with a color fade when Reduce Transparency is enabled.

Player lyrics use stable row heights and an eased scrolling animation when the active line changes. Manual scrolling pauses automatic following; pressing Play, clicking a lyric, or seeking with the playback slider resumes it. The final lyric can scroll up to the vertical center of the lyrics viewport, with the bottom clearance adapting to the window and font size and no vertical overscroll past that limit.

The editor uses one unified workspace for text editing and time syncing. The formatting panel appears only while lyric text is active or multiple lines are selected. It and the timing panel float as rounded liquid-glass capsules over the lyric scroller, with matching internal scroll clearance so neither capsule hides lyric text. Clicking a card, annotation, or timestamp selects that exact line for timing, with selection conveyed by the highlighted cell instead of a separate marker. Command-clicking anywhere in a cell toggles it in a multi-selection, while Shift-clicking a cell selects the contiguous range from the anchor. Compact notebook-style controls below each lyric cell insert or delete lines, including the final line, and reduced cell insets leave more room for lyrics. Structural edits share the native undo/redo history with formatting and timing changes.

Unformatted lyrics use the semantic macOS label color, so they remain legible in both light and dark appearances. The native color panel supports arbitrary sRGB colors and opacity while retaining a stable value in the library document; right-clicking the color well restores the adaptive default. Bold, italic, underline, font, color, symbol insertion, and style-preserving line splitting operate on the last text selection even when a toolbar control temporarily takes focus. The compact formatting controls stay on one line in narrow editor layouts. Attribute-only edits are explicitly synchronized back to the song model. If a selected font has no requested bold or italic face, the app warns and leaves the text unchanged.

Settings applies one appearance to the whole application, including the main window, settings, and native toolbars. Auto follows the system appearance; Light and Dark override it. Custom titlebar backgrounds refresh when their effective appearance changes, including while another window has focus.

Settings also includes a default fallback lyrics font. It applies only to runs without an explicitly selected font, so changing the preference updates plain lyrics without overwriting intentional per-run font choices.

The timing panel remains visible below the lyrics. Space outside the rich-text editor, or the prominent **Tap** button, stamps the selected line and advances; Space inside lyric text is typed normally. The trailing action row keeps **Play from Line**, icon-only **Pause**, **Remove Timing**, and icon-only **Cancel** together in that order. Play from Line opens the linked song when needed before seeking to the selected timestamp. The panel also supports multi-selection, timing removal, horizontal dragging, and precise two-finger horizontal trackpad scrolling. A single visible jog wheel adjusts every selected line and shows before/after timestamp previews. At narrow editor widths, the adjustment, stamping, and delay controls switch to stacked, aligned rows so they retain their natural sizes. Timing edits update the song live, autosave normally, and can be undone without replacing concurrent lyric edits.

## Architecture

```text
SingersLyrics/
├── App/                 application entry point, commands, and authoritative app model
├── Models/              versioned library, songs, styled lyrics, and timing utilities
├── Services/            JSON storage, Music automation, metadata lookup, and fonts
├── Features/
│   ├── Library/         searchable/sortable native three-column workspace
│   ├── Editor/          AppKit rich-text bridge, imports, formatting, and symbols
│   ├── Sync/            reusable timestamp adjustment controls
│   ├── Player/          timed karaoke presentation and transport controls
│   ├── Mobile/          adaptive iPhone/iPad navigation, touch editor, and player
│   └── Settings/        persistent appearance and fallback-font settings
└── Resources/           asset catalog and app icon
```

SwiftUI supplies the application shell, navigation, toolbars, menus, sheets, alerts, settings, unified lyrics workspace, and player. Focused `NSTextView` and `UITextView` bridges supply native attributed-text editing on their respective platforms. The Mac and iOS targets share the app model, library codec, attributed-text schema, metadata lookup, and playback model. Internal `LibraryStoring`, `MusicControlling`, and `TrackMetadataLookingUp` protocols isolate filesystem, platform playback, and network behavior.

## Library data and recovery

The app starts with a new empty library. It never searches for, reads, imports, or modifies the legacy Glaze library or `songs.json`.

The native version-1 document is stored at:

```text
~/Library/Application Support/app.singerslyrics.SingersLyrics/library-v1.json
```

The JSON contains a schema version and an ordered array of songs. Each song contains stable UUIDs, editable display metadata, optional linked-track Music metadata, ordered lyric lines, styled text runs, optional timestamps, and ISO-8601 dates. Saves are atomic, pretty-printed, and key-sorted.

Lossless exports use the `.singerslyrics` extension. They are versioned, pretty-printed JSON song bundles containing the same complete song records: annotations, rich-text runs and styles, timing, links, both forms of metadata, identities, and dates. One bundle can contain any selected subset of the library and can be imported from the empty-library workspace. LRC remains available as a single-song compatibility export, but it intentionally contains only title, singer, plain lyric text, and timestamps.

If the file is corrupt or uses an unsupported schema, the app leaves it byte-for-byte unchanged, disables autosave for that session, and offers to reveal it in Finder. In-memory edits are not silently written over an unreadable library.

## Music.app automation

Singers Lyrics uses serialized Apple Events to read Music.app state and to play, pause, and seek. macOS may ask for Automation access the first time one of these actions is used. If access was denied, enable it under **System Settings → Privacy & Security → Automation**.

Opening a track is identity-aware, including when Music.app was not already running. The app searches and validates against the linked track’s Music metadata rather than its editable display title and singer. It sends one link-opening request to Music, waits until Music reports matching metadata, captures Music's persistent track ID, and only then seeks and starts playback. A changed persistent ID with mismatched non-empty metadata, including an AutoPlay item, is rejected. Playback commands request the current track only, reducing accidental album-queue advancement.

The player polls Music.app every 300 milliseconds without overlapping requests. Lyrics advance only after Music's current title and artist match the linked Music metadata; the captured persistent track ID then locks that playback session to the same track. Editing the title or singer shown in Singers Lyrics does not reset that session. Unrelated Music playback leaves the lyrics at the beginning, and a different persistent ID after a session is established is treated as a different song: Music is stopped immediately and lyric progression freezes. If the identified song itself finishes in the preview/player, it starts again at the beginning. Logs contain only operational metadata; lyrics, song links, and other user content are never logged.

Automated tests use an in-memory library, a deterministic metadata service, and an inert Music controller. They do not access the native library, the legacy library, the public network, or real Music.app playback.

Real Music playback remains a manual acceptance test:

1. Add a supported HTTPS Apple Music song link.
2. Quit Music.app, press Play in Singers Lyrics, approve Automation access if prompted, and verify that the linked track both opens and starts playing.
3. Verify play/pause, seek, position/duration updates, synchronization stamping, and click-to-seek.
4. Let the selected track finish in the preview/player and verify that the same track restarts from the beginning with synchronized lyrics.
5. Cause Music to advance to a different album track and verify that it stops immediately while the displayed lyrics remain frozen on the original song.
6. Deny or revoke Automation access and verify that the permission guidance appears.

## App icon provenance

The PNG renditions in `SingersLyrics/Resources/Assets.xcassets/AppIcon.appiconset` were generated on 2026-08-02 from the former Lyric Studio artwork at `.glaze-sources/app-icon.icns` using the macOS `iconutil` and `sips` tools.

Source ICNS SHA-256:

```text
62be622a7c77eb03148986fc379480dcada21e3ed612725e5a8b52d1730459d5
```

This artwork is the only material copied from the legacy app. No TypeScript, Glaze templates, notes, generated builds, npm dependencies, or user data are part of this repository.

## License

See `LICENSE`.
