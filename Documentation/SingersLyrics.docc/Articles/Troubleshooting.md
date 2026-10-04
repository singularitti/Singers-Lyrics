# Troubleshooting

Resolve common device setup, playback, audio-output, and library issues.

## Overview

Check the failing step before changing subscriptions or signing settings. An installed app, media permission, account playback access, and an audible output are separate parts of the playback flow.

### Find Signing & Capabilities

1. In Xcode, open the Project navigator with Command-1 and select the project.
2. Under **Targets**, select **SingersLyrics-iOS**.
3. Open **Signing & Capabilities** across the top of the editor.
4. Enable **Automatically manage signing** and select your **Personal Team**.

The current personal build doesn't require access to the Apple Developer Identifiers portal. See <doc:BuildingAndRunning> for device provisioning and its expiration.

### Connect a device that Xcode can't use

Unlock the iPhone or iPad and complete its trust and pairing prompts. Keep the device connected while preparing the build. Wi-Fi or Bluetooth being enabled doesn't establish trust or enable development access by itself.

Open **Settings > Privacy & Security > Developer Mode** on the device. Turn it on, restart if requested, then unlock the device and confirm the change. Re-select the device as Xcode's run destination.

### Allow music access

On Mac, open **System Settings > Privacy & Security > Automation** and allow Singers Lyrics to control Music.

On iPhone or iPad, use **Open Settings** from the app's permission notice and enable **Media & Apple Music** access. The app requests this permission on the first playback action, not at launch.

### Inspect a playback failure

Expand **Technical Details** in the mobile error notice. The diagnostic contains the request stage and a sanitized category or numeric error code. It doesn't include account identifiers, tokens, song URLs, or the underlying error payload.

For a song-availability or account-access error, try the same song directly in Music. Complete any account or updated-terms prompts there. If the linked version is unavailable in the account's storefront, replace its link with a playable version shared from Music.

An older build that reports `developerTokenRequestFailed` may still use the previous MusicKit catalog path. Rebuild the current MediaPlayer implementation; configuring paid developer services isn't part of this app's current setup.

### Restore sound when playback advances silently

Try the song in Apple's Music app. If both apps advance without audible sound during device debugging, stop Xcode Device Hub screen sharing and try again. Stopping sharing restored audible output during the recorded iPad check; the underlying system behavior wasn't independently diagnosed.

Also check Control Center's audio output and media volume. Select the device's built-in speakers if audio has been routed elsewhere, then set a comfortable volume. A silent output by itself doesn't identify a subscription or authorization failure.

### Understand offline playback failures

Apple Music downloads support offline listening in supported players. Singers Lyrics currently uses a store-ID queue on iOS, without explicitly selecting a downloaded library item. Offline startup through that path hasn't been verified. Adding or replacing a song link also requires online metadata lookup. See <doc:MusicPlayback>.

### Preserve an unreadable library

If the app reports that the library can't be opened, preserve the original file. Autosave is disabled for that session so in-memory changes don't overwrite it. On Mac, reveal the file in Finder. On iOS, export accessible songs before restoring from a backup. See <doc:LibraryAndDocuments> for storage and recovery details.

## See Also

- <doc:BuildingAndRunning>
- <doc:MusicPlayback>
- <doc:LibraryAndDocuments>
