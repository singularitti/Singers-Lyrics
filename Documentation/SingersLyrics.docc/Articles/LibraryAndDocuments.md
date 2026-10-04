# Managing library documents

Store songs locally, exchange them between platforms, and preserve data when a library can't be read.

## Overview

The Mac and iOS targets share the version-1 library and song-bundle schema. Each installation has its own library. There is no automatic cloud synchronization.

The app starts with an empty library and doesn't search for, read, import, or modify the legacy Glaze library or `songs.json`.

### Store the library

On Mac, the library is stored at:

```text
~/Library/Application Support/app.singerslyrics.SingersLyrics/library-v1.json
```

On iOS, `JSONLibraryStore` uses the app container's Application Support directory with the same library subdirectory and filename. The app doesn't store its library in another app's container.

The JSON document contains a schema version and an ordered song array. Each song includes its UUID, display metadata, optional linked-track metadata, lyric lines, styled text runs, annotations, optional timestamps, and ISO-8601 dates. Saves are atomic, pretty-printed, and sorted by key.

Initial loads are coalesced so an incoming file-open event can't race a second library read. Mobile imports wait for loading to finish, and the app flushes pending autosaves when it leaves the foreground.

### Exchange songs

Use `.singerslyrics` bundles to transfer songs without losing formatting, annotations, timestamps, tags, track links, or stored metadata. A bundle can contain any selected subset of the library. Mac multi-selection exports all selected songs into one bundle.

Share or AirDrop a bundle from Mac, then open it in Singers Lyrics on iPhone or iPad. You can also choose **Import Song Bundle** and select it in Files. An empty library offers the same creation and import actions as the library's add menu.

LRC is a single-song compatibility format containing the title, singer, plain lyric text, and timestamps. On mobile, import it into the selected song through **Import Lyrics > Choose File**. Importing plain text or LRC confirms replacement of the existing lyric lines, formatting, annotations, and timing. External file opening is registered for song bundles; LRC import remains scoped to a selected song.

### Preserve rich text across platforms

`AttributedTextCodec` converts shared styled text to native `NSAttributedString` values for AppKit and UIKit and to `AttributedString` for SwiftUI rendering. Adaptive foreground colors remain semantic when no explicit color is stored. A fallback-font preference applies only to runs without an explicitly assigned family.

If a Mac font isn't available on iOS, UIKit displays a substitute. Stored-attribute markers retain the original family and intended bold/italic traits, allowing a later save or export to preserve the Mac styling. Display-only fallback choices don't silently replace the stored font name.

### Recover from a read failure

If the document is corrupt or its schema version isn't supported, the app preserves the original file and disables autosave for that session. It doesn't write in-memory edits over an unreadable library.

On Mac, use the recovery action to reveal the library in Finder and preserve a copy before repairing or restoring it. On iOS, export any songs you can still access before restoring the app from a backup. See <doc:Troubleshooting>.

## See Also

- <doc:EditingLyrics>
- <doc:AppArchitecture>
- <doc:Testing>
