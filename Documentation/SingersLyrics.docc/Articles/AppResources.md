# App resources

Review the app icon's provenance and the repository's resource boundaries.

## Overview

The app uses Apple's platform frameworks and the resources in its source tree. Platform SDKs, generated builds, and user libraries aren't repository resources.

### Identify the app icon source

The PNG renditions in `SingersLyrics/Resources/Assets.xcassets/AppIcon.appiconset` were generated on August 2, 2026, from the former Lyric Studio artwork at `.glaze-sources/app-icon.icns`, using the macOS `iconutil` and `sips` tools.

The source ICNS file has this SHA-256 digest:

```text
62be622a7c77eb03148986fc379480dcada21e3ed612725e5a8b52d1730459d5
```

The asset catalog contains the Mac renditions and a universal iOS icon entry that reuses the existing 1024-by-1024-pixel artwork.

### Keep legacy data separate

The icon artwork is the only material copied from the legacy app. The repository doesn't include its TypeScript, Glaze templates, notes, generated builds, npm dependencies, or user data. The native library starts independently; see <doc:LibraryAndDocuments>.

### Review the license

The repository's `LICENSE` file contains the project's license terms. Keep resource provenance with the source documentation when modifying the asset catalog.

## See Also

- <doc:AppArchitecture>
- <doc:LibraryAndDocuments>
