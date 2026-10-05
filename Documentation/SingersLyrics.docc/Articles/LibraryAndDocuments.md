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

The JSON document contains a schema version, an ordered active song array, and persistent `trashedSongs` and `trashedRecordings` collections. Each song includes its UUID, display metadata, optional linked-track metadata, lyric lines, styled text runs, annotations, optional timestamps, and ISO-8601 dates. Each line also owns its recording metadata and selected recording ID. Saves are atomic, pretty-printed, and sorted by key.

Audio is stored separately beside the JSON file at `recordings/<song UUID>/<line UUID>/<recording UUID>.m4a`. Recording names and lyric text are never used as filesystem paths. New audio is saved before the metadata that references it. Deleting a whole song stores the complete song and its original position in `trashedSongs`, including all lyric lines and attached recordings. Deleting an individual take or lyric line, or replacing lyrics through an import, retains the removed recordings separately in `trashedRecordings`. Both collections keep audio files at their existing UUID paths. Duplicating or importing a conflicting song gives its recordings independent identities.

The local JSON schema remains version 1 with additive recording fields so installed libraries remain readable. Audio bytes are loaded into memory with the library and never encoded as base64 in its JSON. This design is intended for short voice notes. Future large recording libraries may need lazy audio loading.

Initial loads are coalesced so an incoming file-open event can't race a second library read. Mobile imports wait for loading to finish, and the app flushes pending autosaves when it leaves the foreground.

### Manage Trash

On Mac, select one or more songs in the sidebar and press **Delete** while the sidebar has keyboard focus to move them directly to Trash without a confirmation dialog. Their lyrics and recordings are preserved for restoration. The shortcut also works for song rows under **Recent** and **Favorite**.

Choose **Trash** in the Mac sidebar and switch between its **Songs** and **Recordings** tabs. This is an in-app Trash, separate from macOS Trash; it survives app restarts and has no automatic expiration. Normal song exports include only active songs and exclude both Trash collections.

Click one row, Command-click or Shift-click several, or use **Select All** (Command-A with the list focused). In Songs, **Restore Selected** restores each complete snapshot with stable identities and its original order. It includes display and linked-track metadata, every lyric line, styled text, annotations, timestamps, favorites, tags, and attached recordings. Lines without recordings and songs without recordings are retained and restored too. A recording deleted separately before its song was deleted remains an independent Recordings entry and is not restored with the song.

The Recordings tab combines recordings attached to deleted songs with independently deleted recordings. Each take appears once and retains its name, recording date and duration, deletion date, original song and lyric, annotation, and saved context. **Show in Finder** reveals the actual managed `.m4a` file. **Restore Selected** returns these takes to their original lyric lines without overwriting current lyrics or takes or changing audio file locations. If a recording's song is in Songs Trash, restoring the recording first restores the complete song with its attached takes, then reattaches any selected independently deleted takes. A parent song with permanent deletion pending blocks that restoration.

For missing owners without a complete song snapshot, recording restoration recreates only the saved song and lyric context, once for all selected takes belonging to that owner. Songs already deleted by an earlier implementation have no recoverable snapshot of unrecorded lines. Their recording entries can still restore the information they contain, but missing lines, timing, styling, or metadata cannot be reconstructed. Use an earlier song export or library backup to recover information absent from Trash.

**Delete Permanently** confirms the exact selected songs or recordings before removing their files and entries. Permanently deleting a song removes its complete snapshot and all takes attached to that snapshot. Independently deleted recordings remain in Recordings. Deleting selected recordings permanently removes only those takes from their owning snapshot, preserving the deleted song, its lyrics, and all other takes. Pending entries cannot be restored; mixed selections restore eligible entries and leave pending or blocked entries in Trash. Completed exports, external copies, and backups are separate from the managed library.

Ordinary editor deletion remains undoable while its editor history is available; restoring a take or lyric line through Undo removes its recording from Trash. Use the formatting bar's **Undo** button or **Edit > Undo** (Command-Z); **Redo** uses Shift-Command-Z. Undo history is temporary, while **Restore Selected** works from the persistent Trash. Permanent deletion cannot be undone and clears the window's editing history so retained snapshots cannot restore removed audio. If a recording is running when its lyric line or song is deleted, the app first finishes the take and moves it to Trash; it cancels a pending microphone request when no capture has started.

Permanent deletion first saves an `isPendingPermanentDeletion` marker before unlinking audio. After its files are removed, the song or recording entry is cleared from metadata. Failed or interrupted deletions stay pending and visible for retry, including when only some attached files have been removed. Retrying an already removed file is safe. Loading pending entries does not require their audio files, so quitting during removal does not make the library unreadable. Audio files already removed by an earlier app version cannot be reconstructed from this metadata.

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

Version-1 JSON song exports are not accepted by the new document importer. Missing audio, duplicate identities, invalid take selections, unsupported versions, and symbolic links in required package files are rejected before the library changes. Import identity reservations include active songs and both Trash collections, so an imported document cannot reuse identities needed for restoration. Trash does not change the version-2 portable format. Stable identities and separate audio files prepare this format for future synchronization; iCloud transport, conflict resolution, and deletion propagation are not implemented.

Share or AirDrop a package from Mac, then open it in Singers Lyrics on iPhone or iPad. You can also choose **Import Song Bundle** and select it in Files. An empty library offers the same creation and import actions as the library's add menu. Recording and listening controls currently appear on Mac; iOS retains the audio through import, editing, duplication, and export. Shared mobile storage also retains complete deleted songs and separately deleted recordings, while the Trash management interface remains Mac-only.

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
