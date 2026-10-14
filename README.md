# Singers Lyrics

Prepare, synchronize, and follow lyrics on Mac, iPhone, and iPad.

## Why Singers Lyrics

Singers Lyrics brings formatted lyrics, annotations, and song timing into one native workspace. Edit while listening to Apple Music, then switch to the player to follow the lyrics during practice. Your library works locally, with optional iCloud synchronization between Mac, iPhone, and iPad.

## Build and run

Use the full Xcode app with the macOS and iOS SDKs installed. Singers Lyrics requires macOS 26 or later, or iOS/iPadOS 26 or later.

1. Open `SingersLyrics.xcodeproj` in Xcode.
2. Choose a scheme and run destination from the toolbar:

   | Build for | Scheme | Run destination |
   | --- | --- | --- |
   | Mac | `SingersLyrics` | My Mac |
   | iPhone or iPad | `SingersLyrics-iOS` | Your device or an installed simulator |

3. For a physical iPhone or iPad, select **SingersLyrics-iOS** under **Targets**, open **Signing & Capabilities**, and choose your **Personal Team**. Connect and unlock the device, and enable Developer Mode on it. A free Apple Account supports personal device builds.
4. Choose **Product > Run** (Command-R).

For command-line builds and detailed setup, see [Building and running the app](Documentation/SingersLyrics.docc/Articles/BuildingAndRunning.md).

iCloud Drive sync works with the standard Mac build and free Personal Team iOS builds. In **Settings → iCloud**, choose the same folder in iCloud Drive on each device and enable **Sync Library with iCloud**. Songs, lyrics, voice recordings, and Trash are included; the local library remains available offline. Paid membership is only needed for the optional CloudKit backend. See [Synchronizing the library with iCloud](Documentation/SingersLyrics.docc/Articles/ICloudSync.md) for setup, transfer timing, and conflict handling.

[Documentation](Documentation/README.md) · [License](LICENSE)
