# Building and running the app

Choose a target, configure device signing, and run Singers Lyrics from Xcode or the command line.

## Overview

The project contains native Mac and iOS targets. Both use Swift 6 strict concurrency and Apple frameworks. There are no package-manager or third-party runtime dependencies. Xcode supplies the platform SDKs; don't copy them into the repository or bundle them with the app.

| Platform | Minimum operating system | Target and scheme | Swift module |
| --- | --- | --- | --- |
| Mac | macOS 26 | `SingersLyrics` | `SingersLyrics` |
| iPhone and iPad | iOS/iPadOS 26 | `SingersLyrics-iOS` | `SingersLyrics_iOS` |

### Run on Mac

1. Open `SingersLyrics.xcodeproj` in the full Xcode app.
2. Choose the **SingersLyrics** scheme and **My Mac** as the run destination.
3. Choose **Product > Run** (Command-R).
4. When you first use playback, allow Singers Lyrics to control Music if macOS requests Automation access.

The Mac target uses local ad hoc signing and doesn't use App Sandbox. Developer ID distribution, notarization, and Mac App Store distribution aren't part of the local build workflow.

### Run on iPhone or iPad

1. Connect and unlock the device. Complete any trust or pairing prompts on the device and Mac.
2. On the device, open **Settings > Privacy & Security > Developer Mode**. Turn on Developer Mode, restart if prompted, then confirm it after unlocking the device.
3. In Xcode, open the Project navigator with Command-1 and select the project.
4. Under **Targets**, select **SingersLyrics-iOS**. Open **Signing & Capabilities**, enable **Automatically manage signing**, and choose your team.
5. Choose the **SingersLyrics-iOS** scheme and the connected device as the run destination.
6. Choose **Product > Run** (Command-R).

A free Apple Account appears as a **Personal Team** in Xcode and supports installation on your own devices. Its provisioning profiles expire seven days after issuance, so rebuild and reinstall when necessary. See Apple's [membership comparison](https://developer.apple.com/support/compare-memberships/).

The iOS target uses the application sandbox and includes the Apple Music usage description. The current playback implementation doesn't require MusicKit App Service registration or a developer token. Apple Music catalog content still requires the appropriate music subscription and account access.

#### Keep signing settings local

The shared project enables automatic signing without selecting a development team. Xcode may write `DEVELOPMENT_TEAM` into the project when you select your Personal Team. Retain that value locally for device builds and exclude the account-specific setting from shared commits. Removing it means you may need to select the team again before the next device build.

### Run in Simulator

Choose the **SingersLyrics-iOS** scheme and an installed iPhone or iPad simulator. Install the required runtime through Xcode if no compatible simulator is available. A simulator SDK is sufficient for compilation; launching the app also requires a runtime. Validate actual Apple Music playback on a signed physical device.

### Build from the command line

Run these commands from the repository root. `DEVELOPER_DIR` selects the full Xcode installation without changing the system-wide developer directory.

#### Build for Mac

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project SingersLyrics.xcodeproj \
  -scheme SingersLyrics \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/singerslyrics-macos-build \
  build
```

The application is written to `/tmp/singerslyrics-macos-build/Build/Products/Debug/Singers Lyrics.app`.

#### Build for iOS Simulator

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project SingersLyrics.xcodeproj \
  -scheme SingersLyrics-iOS \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/singerslyrics-ios-build \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The application is written to `/tmp/singerslyrics-ios-build/Build/Products/Debug-iphonesimulator/Singers Lyrics iOS.app`. This command compiles without signing or launching a simulator. A simulator build can't be installed on a physical iPhone or iPad; use the device workflow above.

## See Also

- <doc:Testing>
- <doc:Troubleshooting>
