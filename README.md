# Singers Lyrics

Singers Lyrics is a native macOS application for editing richly styled lyrics, synchronizing them to Music.app playback, and presenting them in a karaoke-style player.

The Xcode target and Swift module are named `SingersLyrics`; the visible product name is **Singers Lyrics**. The app uses only Apple frameworks: SwiftUI, AppKit, Foundation, and OSLog. It has no package-manager, JavaScript, web-view, analytics, telemetry, or third-party runtime dependencies.

## Requirements

- macOS 26
- The full Xcode application at `/Applications/Xcode.app`

The macOS SDK is supplied by Xcode and must not be copied into this repository or bundled with the app.

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

For the normal edit-test loop, run the fast unit-test scheme. Once it has been built, the tests typically complete in about one to two seconds:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project SingersLyrics.xcodeproj \
  -scheme SingersLyricsFast \
  -destination 'platform=macOS,arch=arm64' \
  test
```

Run the complete unit and UI suite before release or after UI changes:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project SingersLyrics.xcodeproj \
  -scheme SingersLyrics \
  -destination 'platform=macOS,arch=arm64' \
  test
```

The project uses Swift 6 strict concurrency, a macOS 26 deployment target, local ad-hoc signing, and no App Sandbox for the initial local-only release. Developer ID signing, notarization, sandboxing, and Mac App Store distribution are intentionally deferred.

## Main workflows

Choose **New Song from Apple Music** and paste a supported HTTPS Apple Music song link. The app validates the link, looks up its public track metadata, and creates the song only after that lookup succeeds. The title and artist are read-only Apple Music metadata; replacing the link performs a new lookup and updates both values together.

The main window has three columns: the song library, lyric editor, and live preview/player. The library uses the native sidebar collapse behavior, while dedicated toolbar buttons independently hide or restore the editor and preview. At least one workspace panel always remains visible. The selected song appears as one compact, left-aligned navigation title in `Title | Singer` form, and link/delete controls remain available when the library is collapsed.

The editor uses one unified workspace for text editing and time syncing. Clicking lyric text reveals the contextual formatting controls; clearing the line selection hides them. Clicking a card, annotation, or timestamp selects that exact line for timing, with selection conveyed by the highlighted cell instead of a separate marker. Compact notebook-style controls below each lyric cell insert or delete lines, including the final line, and reduced cell insets leave more room for lyrics. Structural edits share the native undo/redo history with formatting and timing changes.

Unformatted lyrics use the semantic macOS label color, so they remain legible in both light and dark appearances. The native color panel supports arbitrary sRGB colors and opacity while retaining a stable value in the library document; right-clicking the color well restores the adaptive default. Bold, italic, underline, font, color, symbol insertion, and style-preserving line splitting operate on the last text selection even when a toolbar control temporarily takes focus. The compact formatting controls stay on one line in narrow editor layouts. Attribute-only edits are explicitly synchronized back to the song model. If a selected font has no requested bold or italic face, the app warns and leaves the text unchanged.

Settings includes a default fallback lyrics font. It applies only to runs without an explicitly selected font, so changing the preference updates plain lyrics without overwriting intentional per-run font choices.

The timing panel remains visible below the lyrics. Space outside the rich-text editor, or the prominent **Tap** button, stamps the selected line and advances; Space inside lyric text is typed normally. The panel also supports multi-selection, timing removal, horizontal dragging, and precise two-finger horizontal trackpad scrolling. A single visible jog wheel adjusts every selected line and shows before/after timestamp previews. At narrow editor widths, the panel switches to stacked, aligned rows so playback, adjustment, stamping, and delay controls retain their natural sizes. Timing edits update the song live, autosave normally, and can be undone without replacing concurrent lyric edits.

## Architecture

```text
SingersLyrics/
├── App/                 application entry point, commands, and authoritative app model
├── Models/              versioned library, songs, styled lyrics, and timing utilities
├── Services/            JSON storage, Music automation, metadata lookup, and fonts
├── Features/
│   ├── Library/         searchable/sortable sidebar and three-panel workspace
│   ├── Editor/          AppKit rich-text bridge, imports, formatting, and symbols
│   ├── Sync/            reusable timestamp adjustment controls
│   ├── Player/          timed karaoke presentation and transport controls
│   └── Settings/        persistent appearance and fallback-font settings
└── Resources/           asset catalog and app icon
```

SwiftUI supplies the application shell, navigation, toolbars, menus, sheets, alerts, settings, unified lyrics workspace, and player. A focused `NSTextView` bridge supplies native attributed-text editing. Internal `LibraryStoring`, `MusicControlling`, and `TrackMetadataLookingUp` protocols isolate filesystem, Apple Event, and network behavior for tests.

## Library data and recovery

The app starts with a new empty library. It never searches for, reads, imports, or modifies the legacy Glaze library or `songs.json`.

The native version-1 document is stored at:

```text
~/Library/Application Support/app.singerslyrics.SingersLyrics/library-v1.json
```

The JSON contains a schema version and an ordered array of songs. Each song contains stable UUIDs, metadata, ordered lyric lines, styled text runs, optional timestamps, and ISO-8601 dates. Saves are atomic, pretty-printed, and key-sorted.

If the file is corrupt or uses an unsupported schema, the app leaves it byte-for-byte unchanged, disables autosave for that session, and offers to reveal it in Finder. In-memory edits are not silently written over an unreadable library.

## Music.app automation

Singers Lyrics uses serialized Apple Events to read Music.app state and to play, pause, and seek. macOS may ask for Automation access the first time one of these actions is used. If access was denied, enable it under **System Settings → Privacy & Security → Automation**.

Opening a track is identity-aware, including when Music.app was not already running. The app sends one link-opening request to Music, waits until Music reports metadata matching the selected song, captures Music's persistent track ID, and only then seeks and starts playback. A changed persistent ID with mismatched non-empty metadata, including an AutoPlay item, is rejected. Playback commands request the current track only, reducing accidental album-queue advancement.

The player polls Music.app every 300 milliseconds without overlapping requests. Once a playback session has identified its track, a different persistent ID is treated as a different song: Music is stopped immediately and lyric progression freezes. If the identified song itself finishes in the preview/player, it starts again at the beginning. Logs contain only operational metadata; lyrics, song links, and other user content are never logged.

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
