# Documentation

Read the guides for developing and using Singers Lyrics.

## Browse the guides

The documentation is a standalone [Swift-DocC](https://www.swift.org/documentation/docc/) catalog. Start with the [catalog overview](SingersLyrics.docc/SingersLyrics.md), or open an article:

| Topic | Article |
| --- | --- |
| Build, install, and sign the app | [Building and running the app](SingersLyrics.docc/Articles/BuildingAndRunning.md) |
| Edit lyrics and set timestamps | [Editing and synchronizing lyrics](SingersLyrics.docc/Articles/EditingLyrics.md) |
| Understand the platform layouts | [Designing the interface](SingersLyrics.docc/Articles/InterfaceDesign.md) |
| Work with shared models and services | [App architecture](SingersLyrics.docc/Articles/AppArchitecture.md) |
| Understand playback APIs and offline limits | [Playing music](SingersLyrics.docc/Articles/MusicPlayback.md) |
| Store, transfer, and recover songs | [Managing library documents](SingersLyrics.docc/Articles/LibraryAndDocuments.md) |
| Validate changes | [Testing the app](SingersLyrics.docc/Articles/Testing.md) |
| Resolve device and playback issues | [Troubleshooting](SingersLyrics.docc/Articles/Troubleshooting.md) |
| Review asset provenance | [App resources](SingersLyrics.docc/Articles/AppResources.md) |

## Build the documentation

Run this command from the repository root. It compiles the articles and checks documentation links without building the app or running unit tests:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun docc convert Documentation/SingersLyrics.docc \
  --output-path /tmp/singerslyrics-documentation.doccarchive \
  --warnings-as-errors
```

Open the resulting `.doccarchive` in Xcode to read the rendered documentation. To preview it in a local browser while editing, run:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun docc preview Documentation/SingersLyrics.docc \
  --output-path /tmp/singerslyrics-documentation-preview.doccarchive \
  --port 8080
```

Follow the local preview URL printed by DocC. Keep generated archives outside the repository. The catalog is independent of the application targets, so documentation changes don't require changing the app's signing configuration.

## Organize and write articles

`SingersLyrics.docc` is the documentation catalog. Its root article defines the landing page and curates the articles in `Articles/` into topic groups. `Info.plist` supplies the display name and documentation identifier. DocC defines the catalog format; `Documentation/` and `Articles/` are this project's organization, not required macOS or iOS directory names.

Follow the [Apple Style Guide](https://support.apple.com/guide/applestyleguide/welcome/web) and [DocC documentation](https://www.swift.org/documentation/docc/):

- Give each article a descriptive title, a short summary, and an overview.
- Keep article subsections at heading level 3 under `## Overview`. Reserve level-2 headings for DocC sections such as `Overview`, `Topics`, and `See Also`.
- Organize instructions around tasks, use active voice, and number steps that must happen in sequence.
- Use sentence-style headings in these guides, preserving the capitalization of product names and interface labels.
- Use the exact names of controls, menu commands, Swift symbols, schemes, and files. Format identifiers and file or directory names in code font, following Apple's [code-font guidance](https://support.apple.com/guide/applestyleguide/code-font-in-text-apsg1fde73a3/web).
- Use `<doc:ArticleName>` links inside the catalog, and curate articles under `Topics` on the landing page. Use ordinary relative Markdown links from repository README files.
- Separate current behavior, design decisions, validation evidence, and future work. Keep build instructions in the root README short.

See [Adding Supplemental Content to a Documentation Catalog](https://www.swift.org/documentation/docc/adding-supplemental-content-to-a-documentation-catalog) for the article and catalog conventions.
