# Managing library documents

Store songs locally, exchange them between platforms, and preserve data when a library can't be read.

## Overview

The Mac and iOS targets share the local library model and version-2 song document package. Each installation has its own library. There is no automatic cloud synchronization.

The app starts with an empty library and doesn't search for, read, import, or modify the legacy Glaze library or `songs.json`.

### Store the library

On Mac, the library is stored at:

```text
~/Library/Application Support/app.singerslyrics.SingersLyrics/library-v1.json
```

On iOS, `JSONLibraryStore` uses the app container's Application Support directory with the same library subdirectory and filename. The app doesn't store its library in another app's container.

The JSON document contains a schema version and an ordered song array. Each song includes its UUID, display metadata, optional linked-track metadata, lyric lines, styled text runs, annotations, optional timestamps, and ISO-8601 dates. Each line also owns its recording metadata and selected recording ID. Saves are atomic, pretty-printed, and sorted by key.

Audio is stored separately beside the JSON file at `recordings/<song UUID>/<line UUID>/<recording UUID>.m4a`. Recording names and lyric text are never used as filesystem paths. New audio is saved before the metadata that references it. Deleting a take, line, or song moves its recordings into the library's persistent `trashedRecordings` collection and keeps their audio files at the same locations. Replacing lyrics through an import also retains the removed recordings in Trash. Duplicating or importing a conflicting song gives its recordings independent identities.

The local JSON schema remains version 1 with additive recording fields so installed libraries remain readable. Audio bytes are loaded into memory with the library and never encoded as base64 in its JSON. This design is intended for short voice notes. Future large recording libraries may need lazy audio loading.

Initial loads are coalesced so an incoming file-open event can't race a second library read. Mobile imports wait for loading to finish, and the app flushes pending autosaves when it leaves the foreground.

### Manage deleted recordings

Choose **Trash** in the Mac sidebar. Each entry retains the take's name, recording date and duration, deletion date, original song and lyric, and annotation. **Show in Finder** reveals the actual managed `.m4a` file. This is an in-app Trash, separate from macOS Trash; it survives app restarts and has no automatic expiration. Normal song exports exclude Trash.

Click one row, Command-click or Shift-click several, or use **Select All** (Command-A with the list focused). **Restore Selected** returns the selected recordings to their original song and lyric lines without overwriting current content or changing the audio file locations. If a line or song was deleted, restoration recreates the missing owner once for all its selected takes. New Trash entries retain song metadata, styled lyric text, annotations, timing, and original positions for this purpose. Older entries restore only the context they already contain; their missing timing, styling, or song metadata cannot be recovered. Restoration remains available after restarting the app.

Trash currently retains recordings, not complete deleted songs. Recreating a song through recording restoration recovers only the lyric lines attached to the restored takes. Lines without recordings are not retained by song deletion, and a song without recordings has no Trash entry. There is currently no whole-song restore action; a previously exported song document or a library backup is needed to recover the complete deleted song.

**Delete Permanently** confirms the exact selected set before removing its audio files and Trash entries. Recordings with permanent deletion pending cannot be restored. Mixed selections restore eligible recordings and leave pending entries in Trash. Completed exports, external copies, and backups are separate from the managed library.

Ordinary editor deletion remains undoable while its editor history is available; restoring a take or lyric line through Undo removes its recording from Trash. Use the formatting bar's **Undo** button or **Edit > Undo** (Command-Z); **Redo** uses Shift-Command-Z. Undo history is temporary, while **Restore Selected** works from the persistent Trash. Permanent deletion cannot be undone and clears the window's editing history so retained snapshots cannot restore removed audio. If a recording is running when its lyric line or song is deleted, the app first finishes the take and moves it to Trash; it cancels a pending microphone request when no capture has started.

Permanent deletion first saves an `isPendingPermanentDeletion` marker before unlinking each file. Successfully removed entries are then cleared from metadata. Failed or interrupted deletions stay visible for retry, and an already removed file is safe to retry. Loading a pending entry does not require its audio file, so quitting during removal does not make the library unreadable. Audio files already removed by an earlier app version cannot be reconstructed from this metadata.

### Exchange songs

Use `.singerslyrics` document packages to transfer songs without losing formatting, annotations, timestamps, tags, track links, stored metadata, or voice recordings. A package can contain any selected subset of the library. Mac multi-selection exports all selected songs into one package.

A package is a directory presented as one document by Finder and Files. Transfer the whole document, including its contents:

```text
Song.singerslyrics/
├── manifest.json
└── recordings/
    └── <song UUID>/
        └── <line UUID>/
            └── <recording UUID>.m4a
```

The manifest has `format: "app.singerslyrics.song-bundle"`, `formatVersion: 2`, and a `songs` array. Each line's `recordings` array contains `id`, `name`, `createdAt`, and `duration` in seconds; `selectedRecordingID` identifies the default take for Play. The audio path is derived from the three owning UUIDs. Recordings use AAC audio in an MPEG-4 container. An empty `recordings` directory is included when there are no takes.

Version-1 JSON song exports are not accepted by the new document importer. Missing audio, duplicate identities, invalid take selections, unsupported versions, and symbolic links in required package files are rejected before the library changes. Stable identities and separate audio files prepare this format for future synchronization; iCloud transport, conflict resolution, and deletion propagation are not implemented.

Share or AirDrop a package from Mac, then open it in Singers Lyrics on iPhone or iPad. You can also choose **Import Song Bundle** and select it in Files. An empty library offers the same creation and import actions as the library's add menu. Recording and listening controls currently appear on Mac; iOS retains the audio through import, editing, duplication, and export.

LRC is a single-song compatibility format containing the title, singer, plain lyric text, and timestamps. It cannot include annotations, formatting, or recordings. On mobile, import it into the selected song through **Import Lyrics > Choose File**. Importing plain text or LRC confirms replacement of the existing lyric lines, formatting, annotations, and timing, moving their attached recordings to the library's recording trash. The Trash management interface currently appears on Mac. External file opening is registered for song bundles; LRC import remains scoped to a selected song.

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
