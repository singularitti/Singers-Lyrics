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

### Verify Logic Pro recording

Assign the Record and Stop commands as described in <doc:LogicProRecording>, then open a Logic Pro project with an audio track selected.

1. Turn on **Record in Logic Pro** in the player. Press Play and confirm that Logic Pro starts recording on the selected track once the song plays.
2. Pause from the player and confirm that recording stops without moving Logic Pro's playhead to the project start.
3. Turn off the record button, press Play, then turn the button on while the song plays. Confirm that recording starts immediately, and that turning the button off stops it while the song continues.
4. Start a take, then pause from the editor's timing controls and from Music. Confirm that each pause stops recording.
5. Start playback from the editor's **Play from Line** button and confirm that Logic Pro doesn't record.
6. During a take, switch between the editor and player columns and confirm that recording continues. Select another song and confirm that it stops.
7. Quit and reopen Singers Lyrics, then confirm that Logic Pro still responds without learning the commands again.

### Verify iPhone and iPad behavior

1. On iPhone and iPad, check library-first launch, song selection, mode switching, and back navigation. Each screen should occupy the full available width. On iPad mini, check the All Songs title in portrait, landscape, and narrow multitasking windows; larger iPads should use the same single-column flow. Confirm the search field stays in the library and matches titles, singers, albums, tags, lyrics, and annotations.
2. Combine All Songs, Recent, or Favorites with tags; check each recent time range, sorting, counts, and Clear Filters. Open a song or Trash, go back, and confirm the previous search and filters remain. Add, import, and duplicate while filtered, and confirm the result is revealed under All Songs. With zero matches, check Show All Songs and opening Trash from the filter menu.
3. With a hardware keyboard, select a library row and delete it, then confirm the adjacent visible row stays selected without opening a song. Keyboard Delete must ignore a selection hidden by filtering and must not delete a library song while the editor or Trash is open. If the currently open song is removed by synchronization, the stack should return to the library.
4. In Settings, change each artwork size and turn artwork off, then check list rows in narrow windows and at large accessibility text sizes. Tags should appear only at Large. Check artwork placeholders without a link or when a request fails. Edit with the keyboard visible and check Return splitting, selection formatting, undo, and annotations.
5. Transfer song bundles in both directions. Include an explicit Mac font unavailable on iOS, then save and reopen to confirm that its stored name and styles survive.
6. On a signed device, check music authorization, audible playback, pause/seek, lyric selection, timing stamps, and same-song repetition in player mode.
7. Check denied access, unavailable tracks, background/foreground transitions, and opening a bundle while the app is launching or while a song or Trash is open. A new import should replace the current destination, and Back should return directly to the library.

If validating offline behavior, download the song first and launch with network access disabled. Check a fresh playback request; an already buffered stream doesn't establish offline startup support. The current iOS store-ID path hasn't been verified offline.

### Review the iOS introduction checkpoint

The implementation introduced in commit `22d2382` passed macOS, iOS Simulator, and signed iOS-device builds. The signed build was installed and launched on a physical iPad. Audible playback was confirmed after stopping Xcode Device Hub screen sharing.

That checkpoint verifies compilation and the observed playback behavior on the tested device and account. It doesn't cover every interaction, simulator runtime playback, or offline startup. Unit tests weren't run because they weren't requested.

## See Also

- <doc:BuildingAndRunning>
- <doc:MusicPlayback>
- <doc:Troubleshooting>
