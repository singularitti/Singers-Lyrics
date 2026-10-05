# Playing music

Control Apple Music through platform services and match playback to the selected lyrics.

## Overview

The shared `MusicPlaybackModel` uses a platform-specific `MusicControlling` implementation. The interface and timing code receive the same playback state on Mac, iPhone, and iPad.

| Platform | Implementation | Access required |
| --- | --- | --- |
| Native macOS | `AppleMusicController` sends serialized Apple Events through `NSAppleScript` to Music. | macOS Automation permission |
| iPhone and iPad | `IOSMusicController` uses `MPMusicPlayerController.applicationMusicPlayer`. | Media & Apple Music permission |

`MPMusicPlayerController` supports iOS/iPadOS and Mac Catalyst, but is unavailable to the existing native macOS target. Its typed properties and queue methods suit mobile playback; their availability doesn't establish a general reliability advantage over the Mac's established scripting interface. See Apple's [platform availability](https://developer.apple.com/documentation/mediaplayer/mpmusicplayercontroller).

### Open a song on Mac

The controller searches Music's library using the linked track's title and artist. These values are separate from the editable title and singer displayed in Singers Lyrics. If a matching library item is found, the controller asks Music to play that track once. Otherwise, it opens the saved Apple Music link.

The playback model waits for matching metadata, captures Music's persistent track identifier, and then seeks and starts playback. A changed identifier with mismatched nonempty metadata, including an AutoPlay track, is rejected. Opening Music when it isn't running follows the same identity checks.

### Open a song on iPhone or iPad

The controller requests music authorization on the first playback action. Polling doesn't request access or read library metadata before authorization.

It extracts the store ID from the saved song link and creates a one-item `MPMusicPlayerStoreQueueDescriptor`. It disables shuffle and automatic queue repeat, waits for `prepareToPlay`, and starts playback. The application player keeps its queue separate from the Music app's playback state.

The controller reads the actual `nowPlayingItem` store ID, or a nonzero library persistent ID when the store ID is unavailable. It also reads playback state, duration, and position. It never substitutes the requested ID for the player's actual identity.

This path doesn't make MusicKit catalog, subscription, or developer-token requests. There is no app-issued token or MusicKit App Service registration to configure. Actual playback still depends on music authorization, account access, song availability, and the device's playback service. See Apple's [application player documentation](https://developer.apple.com/documentation/mediaplayer/mpmusicplayercontroller/applicationmusicplayer).

### Synchronize the selected song

The shared model polls every 300 milliseconds without overlapping polls and interpolates playback position between samples. On iOS, a published catalog identity must match the saved link's store ID. When only library identity and metadata are available, the existing title-and-artist matching applies. Once established, a persistent identity keeps the session attached to the same track.

Editing the displayed title or singer doesn't reset the playback session. Unrelated playback leaves lyrics at the beginning. If the player changes to another track during an established session, the model stops playback and freezes the last accepted lyric position. Player mode restarts the selected song from the beginning when it finishes.

Operation generations prevent older asynchronous results from updating a newer action or target. Timing controls require a ready, identified session. Seek positions are finite, nonnegative, and bounded by the known duration on iOS.

### Report playback failures

The mobile notice distinguishes permission, account capability, song availability, network, and player failures. **Technical Details** contains the failed stage and a controlled error category or numeric code. It excludes account identifiers, tokens, song URLs, localized error descriptions, and arbitrary error payloads. Logs follow the same restriction.

Failures remain visible while polling continues and clear on a new action or target change. Subscription guidance appears for a reported playback-capability error instead of being used for every failure. See <doc:Troubleshooting> for the corresponding user actions.

### Understand online and offline behavior

The app stores lyrics, annotations, formatting, timestamps, preferences, and the library locally. Apple Music link import, link replacement, and metadata backfill query Apple's public iTunes Lookup service for title, artist, and album metadata. Those requests need connectivity but no developer token or API payment. Apple-managed playback may use account, catalog, or streaming services.

Apple Music supports [downloaded songs for offline listening](https://support.apple.com/en-us/118288). Those downloads remain managed by Apple Music and subject to subscription authorization.

- On Mac, the library search can select a downloaded matching track for Music to play locally.
- On iOS, the current controller queues a store ID. It doesn't explicitly find the downloaded library item, and offline startup through this path hasn't been verified.
- Looking up a matching downloaded library item before falling back to a store queue is future work. Direct audio-file import is also not implemented.

Downloading a song enables offline listening in supported players; it doesn't guarantee that Singers Lyrics makes no network requests.

## See Also

- <doc:AppArchitecture>
- <doc:LogicProRecording>
- <doc:Testing>
- <doc:Troubleshooting>
