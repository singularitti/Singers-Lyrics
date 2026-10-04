# Testing the app

Choose build checks and manual playback checks that match the behavior being changed.

## Overview

The project has Mac unit and UI test targets. Automated tests use an in-memory library, deterministic metadata lookup, and an inert music controller. They don't read the persistent app library, access the legacy library, query the public network, or control Music.

Run unit tests only when explicitly requested, as required by the project agent instructions. Compilation and documentation checks don't run unit tests.

### Build the affected targets

Use the commands in <doc:BuildingAndRunning> to build for Mac or iOS Simulator. Shared-model and codec changes affect both targets. Compile for a signed physical device when checking device integration; simulator compilation alone doesn't verify permissions, audio, touch interaction, or account access.

### Run requested automated tests

For a requested Mac unit-test run, use the shared Mac scheme and select only the unit-test target:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project SingersLyrics.xcodeproj \
  -scheme SingersLyrics \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:SingersLyricsTests \
  test
```

For a requested run of the complete Mac unit and UI suite:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project SingersLyrics.xcodeproj \
  -scheme SingersLyrics \
  -destination 'platform=macOS,arch=arm64' \
  test
```

These commands use the checked-in scheme. There is no shared iOS test target in the current project.

### Verify Mac playback

1. Add a supported Apple Music song link.
2. Quit Music, start playback from Singers Lyrics, approve Automation access if requested, and confirm that the linked song starts.
3. Check play/pause, seeking, position and duration updates, timing stamps, and lyric selection.
4. Let the selected song finish in player mode and confirm that it repeats with synchronized lyrics.
5. Make Music advance to a different album track and confirm that playback stops while the selected song's lyric position remains frozen.
6. Revoke Automation access and confirm that permission guidance appears.

### Verify iPhone and iPad behavior

1. On iPhone, check library-first launch, song selection, mode switching, and back navigation.
2. On iPad, check the two-column layout, sidebar visibility, rotation, and compact multitasking windows.
3. Edit with the keyboard visible. Check Return splitting, selection formatting, undo, annotations, and large accessibility text sizes.
4. Transfer song bundles in both directions. Include an explicit Mac font unavailable on iOS, then save and reopen to confirm that its stored name and styles survive.
5. On a signed device, check music authorization, audible playback, pause/seek, lyric selection, timing stamps, and same-song repetition in player mode.
6. Check denied access, unavailable tracks, background/foreground transitions, and opening a bundle while the app is launching.

If validating offline behavior, download the song first and launch with network access disabled. Check a fresh playback request; an already buffered stream doesn't establish offline startup support. The current iOS store-ID path hasn't been verified offline.

### Review the iOS introduction checkpoint

The implementation introduced in commit `22d2382` passed macOS, iOS Simulator, and signed iOS-device builds. The signed build was installed and launched on a physical iPad. Audible playback was confirmed after stopping Xcode Device Hub screen sharing.

That checkpoint verifies compilation and the observed playback behavior on the tested device and account. It doesn't cover every interaction, simulator runtime playback, or offline startup. Unit tests weren't run because they weren't requested.

## See Also

- <doc:BuildingAndRunning>
- <doc:MusicPlayback>
- <doc:Troubleshooting>
