# Synchronizing the library with iCloud

Enable optional sync to carry lyrics, library metadata, voice recordings, and Trash between Mac, iPhone, and iPad.

## Overview

Each app keeps a working local library. The standard Mac and iOS builds can sync through a folder you choose in iCloud Drive, including with ad hoc Mac signing and a free Personal Team on iOS. A paid developer membership is **not** required for this folder workflow. Sync remains off until you choose a folder and enable it.

Sync includes song and lyric metadata, rich text, annotations, timestamps, favorites, tags, linked-track metadata, voice recording metadata and audio, both Trash collections, and permanent deletion state. Apple Music audio is played through Apple Music and is never uploaded by library sync. Appearance preferences, playback position, and local editor history are device settings.

### Set up iCloud Drive with a free Personal Team

1. Rebuild and run the normal **SingersLyrics** scheme on Mac and **SingersLyrics-iOS** on iPhone or iPad. No extra cloud configuration is needed.
2. Enable iCloud Drive in system settings on both devices using the same iCloud account.
3. In Singers Lyrics, open **Settings → iCloud** and choose **Choose iCloud Drive Folder…**. In the system picker, open **iCloud Drive** and choose or create a dedicated folder, such as **Singers Lyrics**. Selecting it enables sync. Turning on the switch before selecting a folder also opens the picker.
4. On the other device, choose that **same folder** from iCloud Drive. Do not create a separate folder with the same name under **On My iPhone** or another local location.
5. Leave both apps open, finish editing or recording, and use **Sync Now** to request a pass. iCloud Drive may need additional time to upload and download files.

The system picker grants access to the folder and its contents. The app holds that grant as soon as you select the folder and tries to remember it with a bookmark. If the provider cannot save the permission, the app can still connect and sync for the current session. Settings shows a separate notice explaining that you must choose the same folder again after reopening the app; the next launch leaves sync off until you reconnect. It does not need an app-owned iCloud container. Apple's [Providing access to directories](https://developer.apple.com/documentation/uikit/providing-access-to-directories) describes this access model.

The folder you select is the library's sync folder. The app stores **commits**, **audio**, and **connections** directly inside it, without adding a **Singers Lyrics Library** wrapper. These contain immutable library snapshots, recording audio named by its content digest, and anonymous connection markers. Keep the selected folder in your own iCloud Drive rather than a folder shared with other people.

When reconnecting a folder used by an earlier build, the app migrates its old **Singers Lyrics Library** contents into the selected folder while preserving library history and saved connections. It verifies the copied data before removing the old copies and removes only empty wrapper directories. Interrupted migration can resume on the next sync; incomplete downloads or conflicting files pause it. Update every device before continuing with the new layout. If you select an existing library folder itself, the app uses it directly.

**Last folder check** and **Folder up to date** refer to the app's merge with files currently available on the device. They do not confirm that iCloud Drive has delivered those files to another device. A folder outside a syncing provider works as local storage only; the app cannot make a local folder appear on another device.

Settings shows the connected folder's name and the last successful folder-check time within the sync status row. An empty library reports **No songs in sync folder**. If another device has songs, compare the selected folders. Use **Change Sync Folder…**, confirm, and select the exact folder used by the device with your songs. This keeps your local library, combines it with the selected folder's library, and preserves the previous connection history locally.

Use the same **Change Sync Folder…** button if a bookmark stops working or access is revoked. Reselecting the original folder renews access while retaining its sync baseline and known commits. Selecting a different folder validates its library and saves the previous connection history before switching. Disabling sync preserves the local library and the files already in the selected folder.

If you deleted the original folder, its saved bookmark and sync history no longer identify a usable library. Choose **Change Sync Folder…**, confirm, then choose or create a dedicated iCloud Drive folder. This keeps the local songs, recordings, Trash, and deletion state and combines them with any existing library in the selected folder. The app validates the replacement library before changing connections and saves the previous sync checkpoint under **Previous Sync Connections** in its local Application Support directory. A moved folder with its original contents can instead be reselected normally. On every device, use **Change Sync Folder…** to choose the same replacement folder.

### Folder history and concurrent changes

Devices write separate immutable snapshots, each referring to the snapshots it already saw. The app combines concurrent snapshots using their shared history. This avoids relying on a single JSON file that two offline devices could overwrite. Recording audio is verified against its stored digest before adoption; incomplete downloads pause sync while the local library remains usable.

A clean history reset starts a new library generation. Its `library.json` descriptor stays directly in the selected folder, and each of **commits**, **audio**, and **connections** stores the active generation in its own subdirectory. Every device's saved connection identifies that generation. Older files and connections are excluded, so a device returning with stale history cannot merge it into the reset library. A generation mismatch pauses sync instead of automatically rebinding. A reset must publish the verified library and reset all device checkpoints together; it is separate from ordinary folder replacement, which preserves and merges local history.

Permanent deletion state propagates to the current library and prevents an older device from restoring the deleted identities. The folder backend retains historical snapshots and recording assets for reconciliation, so **Delete Permanently does not erase every historical copy from the sync folder**. That history also means the folder can grow over time. Do not manually remove individual files while devices are connected; missing ancestry or audio pauses synchronization.

### Optional CloudKit backend

The alternate CloudKit backend stores the library in an iCloud account's private database without asking the user to choose a folder. It requires paid Apple Developer membership and provisioning for one shared container. A free Personal Team cannot provision this capability. Installing signed development builds on your own devices does not require publishing to the App Store.

Both devices must use the same backend. The iCloud Drive folder and CloudKit private database have separate histories and do not synchronize with each other. The default build setting `SINGERSLYRICS_ICLOUD_ENABLED=NO` selects iCloud Drive; `YES` selects the provisioned CloudKit backend. The steps below apply only to CloudKit.

#### Register and provision the shared container

1. In Apple's developer account tools, register or select the two explicit App IDs: `app.singerslyrics.SingersLyrics` for Mac and `app.singerslyrics.SingersLyrics.iOS` for iOS.
2. Enable iCloud with CloudKit for both App IDs. Register **one** container, `iCloud.app.singerslyrics.SingersLyrics`, and associate it with **both** App IDs. The iOS bundle identifier must not cause Xcode to select a separate `.iOS` container.
3. In Xcode, sign in with the paid developer account and select the same developer team for both targets. Allow Xcode to manage development provisioning, or supply valid profiles that grant the container and CloudKit service entitlements.
4. Sign in to iCloud on the Mac and iPhone or iPad using the same account. Ensure iCloud is available to the app on each device.

Keep team selections local. Do not commit account-specific signing settings, account identifiers, tokens, or profiles. Free Personal Teams cannot provision the CloudKit capability, and an ad hoc Mac signature cannot authorize access to the private container.

#### Opt in from the command line

Run from the repository root after selecting the paid team locally. `-xcconfig` overrides the default app settings for this invocation; omitting it returns to the standard build with optional iCloud Drive folder sync. The checked-in configuration contains no team identifier.

Build the development Mac app:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project SingersLyrics.xcodeproj \
  -scheme SingersLyrics \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -xcconfig Configuration/SingersLyrics-iCloud.xcconfig \
  -derivedDataPath /tmp/singerslyrics-icloud-macos-build \
  -allowProvisioningUpdates \
  build
```

Build the development iOS app for a physical device:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project SingersLyrics.xcodeproj \
  -scheme SingersLyrics-iOS \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -xcconfig Configuration/SingersLyrics-iCloud.xcconfig \
  -derivedDataPath /tmp/singerslyrics-icloud-ios-build \
  -allowProvisioningUpdates \
  build
```

The products are in `Build/Products/Debug/` and `Build/Products/Debug-iphoneos/` beneath those respective build directories. Install the iOS build using Xcode's device tools. Provisioning updates require Xcode's signed-in paid account and access to the registered App IDs and container. Do not pass `CODE_SIGNING_ALLOWED=NO` for a build intended to use iCloud on a device.

`Configuration/SingersLyrics-iCloud.xcconfig` enables `SINGERSLYRICS_ICLOUD_ENABLED`, selects `Apple Development` automatic signing, and chooses the platform entitlement file. App targets alone map the custom signing variables to Xcode's signing settings; test targets do not receive the CloudKit entitlement files. Each app's source Info.plist expands this flag into the `SingersLyricsCloudKitEnabled` string, telling the runtime whether cloud support was requested for the build. `SingersLyricsCloudKitEnvironment` expands the same `SINGERSLYRICS_ICLOUD_ENVIRONMENT` variable used by the signed entitlement; the runtime requires `Development` or `Production`. Setting these values alone does not supply a valid signature or provisioning profile.

#### Opt in for Product > Run in Xcode

For each app target and each build configuration you intend to run, open **Build Settings**, choose **All** and **Combined**, and set these values locally:

| Build setting | Mac target | iOS target |
| --- | --- | --- |
| `SINGERSLYRICS_ICLOUD_ENABLED` | `YES` | `YES` |
| `SINGERSLYRICS_ICLOUD_ENVIRONMENT` | `Development` | `Development` |
| `SINGERSLYRICS_APP_CODE_SIGN_STYLE` | `Automatic` | `Automatic` |
| `SINGERSLYRICS_APP_CODE_SIGN_IDENTITY` | `Apple Development` | `Apple Development` |
| `SINGERSLYRICS_APP_ENTITLEMENTS` | `Configuration/SingersLyrics-macOS-iCloud.entitlements` | `Configuration/SingersLyrics-iOS-iCloud.entitlements` |

Add the environment setting as a user-defined setting if it is absent. Select the paid team under **Signing & Capabilities**, then run the corresponding scheme on the device. Check that **Code Signing Entitlements** resolves to the expected file and that the provisioned profile includes the shared container. These target settings mirror the command-line configuration; assigning the xcconfig as a base configuration alone cannot override the explicit default `NO` already on the app target.

To return to the standard build with iCloud Drive folder sync, restore `SINGERSLYRICS_ICLOUD_ENABLED=NO` and an empty `SINGERSLYRICS_APP_ENTITLEMENTS`. Restore the Mac custom signing identity to `-` and style to `Manual`; iOS continues to use automatic development signing. Keep cloud build overrides local rather than committing a requirement for paid provisioning.

#### Use the same CloudKit environment

The opt-in configuration selects **Development** for both platforms. Development and Production databases are separate: a device using one will not see records in the other, even with the same account and container. Debug/Release naming alone is not a reliable indication of the CloudKit environment; inspect the signed entitlement and provisioning profile.

The local sync checkpoint is linked to its original environment as well as its iCloud account. Changing the environment pauses sync for an already linked local library; return to the original environment to resume. The app does not automatically combine Development and Production histories, because an absent record in the other environment must not be interpreted as a deletion.

For distribution with Production profiles, deploy the record schema from Development to Production in CloudKit Console and select `SINGERSLYRICS_ICLOUD_ENVIRONMENT=Production` on both apps with matching distribution signing and profiles. The development xcconfig's `Apple Development` identity is intended for local device use. Copying schema to Production does not copy a user's private development records.

### Enable sync and combine existing libraries

In each app, open **Settings**, enable **Sync Library with iCloud**, and use **Sync Now** for an immediate request. The standard build asks you to choose a folder; a provisioned CloudKit build connects to its private database. First sync combines existing local and remote libraries; an empty library on one device does not erase the populated library on another. Independently created songs retain their identities. If both devices have changed the same song since their common synced version, the merge retains both edits as separate song copies, including their recordings, so you can review them.

Moving a song or recording to Trash syncs its recoverable state. **Delete Permanently** creates persistent deletion tombstones, so an older device's next sync does not restore the deleted identities. Recordings already deleted independently remain in Recordings Trash when their parent song is purged. Restoring these takes reconstructs their saved context under a new deterministic parent identity, preserving the permanent deletion of the original song. CloudKit recording cleanup happens after the updated manifest is committed and may be retried if interrupted. The folder backend retains history as described above. Exports and backups outside the managed library remain separate.

Only an explicit permanent-deletion record or pending purge removes a song or recording during a merge. An item missing from an older snapshot is not a deletion request. Retained songs and Trash entries from either device are preserved; a competing song version that would discard a recording is kept as a conflict copy. If neither current snapshot contains an item retained by the last shared version, sync pauses instead of silently dropping it. An item's internal identity determines whether a deletion applies; a matching song title alone does not.

Each device also saves the Drive commit heads used for its last merge in its local checkpoint. Later syncs read those commits directly even when iCloud Drive omits them from folder listings. Missing known history pauses sync rather than rolling lyrics, Trash state, or recordings back to an older snapshot.

The app saves edits locally while offline and retries sync on later requests. A network failure, missing iCloud account, quota limit, or unavailable recording asset must not replace a usable local library with an incomplete download. Keep an export or independent backup before consolidating valuable libraries; sync also propagates deliberate permanent deletion.

Disabling sync stops requests on that installation and leaves its local library usable. It does not remove the remote library or disable sync on another device.

CloudKit binds its checkpoint to the iCloud account that first used it. Switching accounts pauses sync rather than transferring the previous account's library to the new one. Return to the original iCloud account to resume. The folder backend instead binds to an anonymous connection marker in the selected folder and pauses if that marker is unavailable.

### Understand when devices converge

Sync is requested after local saves, when the app becomes active, and approximately every 30 seconds while it stays active. **Sync Now** requests another pass, and Settings displays progress, completion, or an error requiring attention. Leave both apps open with network access while transferring recordings; larger libraries require more time and iCloud storage.

The folder backend leaves file transfers to iCloud Drive. The CloudKit backend uses direct requests without `CKSyncEngine` or push notification subscriptions. Synchronization is not instantaneous, and the app does not promise continuous background synchronization while suspended or closed. A completed pass on one device does not mean another device has already downloaded the result.

Saved local edits can upload while you edit, but incoming changes wait while a lyric editor or recording session is active. Finish editing, dismiss the mobile keyboard, and stop the take so incoming changes can be adopted. Adopting remote changes clears native editor Undo history to prevent an older editor snapshot from overwriting the merged library; persistent Trash remains available for restoration.

### Inspect the CloudKit schema

The app creates the custom record zone `SingersLyricsLibrary` in the private database. Records are fetched by known record ID, so no query indexes are required.

| Record type and ID | Field | CloudKit field type | Contents |
| --- | --- | --- | --- |
| `SLLibraryManifest`, `root` | `formatVersion` | Int64 | Manifest format version, currently `1`. |
| `SLLibraryManifest`, `root` | `metadata` | Asset | JSON library sync metadata, including deletion state. |
| `SLLibraryManifest`, `root` | `audioDigests` | Asset | JSON map from recording UUID to SHA-256 digest. |
| `SLRecordingAudio`, `audio-<UUID>` | `formatVersion` | Int64 | Audio record format version, currently `1`. |
| `SLRecordingAudio`, `audio-<UUID>` | `digest` | String | SHA-256 digest of the recording bytes. |
| `SLRecordingAudio`, `audio-<UUID>` | `audio` | Asset | Recorded `.m4a` audio. |

Recording assets upload before the manifest publishes references to them. The manifest uses conditional saves against CloudKit's current record revision; concurrent updates trigger another merge rather than silently overwriting a newer revision. Audio downloads are checked against their recorded digests before adoption. Development schema can be created by successful development saves; Production requires deploying the schema through CloudKit Console before use.

## See Also

- <doc:BuildingAndRunning>
- <doc:LibraryAndDocuments>
- <doc:AppArchitecture>
- <doc:Troubleshooting>
