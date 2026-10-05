# Editing and synchronizing lyrics

Add a song, format its lyrics, and assign timestamps while listening to playback.

## Overview

The editor combines text editing and timing in one workspace. A song's displayed title and singer are independent of its linked track metadata, so renaming the song doesn't change the track used for synchronization.

### Add and manage a song

Choose **New Song from Apple Music** and paste a supported HTTPS song link. The app validates the link and retrieves the track metadata before creating the song. For example:

```text
https://music.apple.com/us/song/you-complete-me-theme-song-from-back-to-the-good-times/1342141668
```

Change the displayed title or singer from the song's management controls. Replacing the Apple Music link refreshes the linked track metadata without overwriting those display values. Older library entries receive missing playback metadata through background lookup.

On Mac, Command-click or Shift-click songs in the sidebar to select more than one song for deletion, duplication, or export. On iPhone and iPad, use the editor's song options menu for song details, link replacement, lyric import, and export. See <doc:LibraryAndDocuments> for transfer formats.

Deleting a song moves the complete song to **Trash**, including every lyric line and its recordings. On Mac, open Trash's **Songs** tab and choose **Restore Selected** to recover the song with its metadata, formatting, annotations, timestamps, track link, favorites, and tags. On iPhone and iPad, choose **Trash** at the bottom of the library, then swipe right on the song, or touch and hold it and choose **Restore**. Songs without recordings are also retained, and restoration remains available after restarting the app.

### Edit and format lyrics

Select lyric text to use bold, italic, underline, color, font, and symbol controls. Return splits a line and preserves its styled text. Annotations and timestamps remain associated with their lyric lines.

On Mac, formatting continues to act on the last text selection when a toolbar control takes focus. Attribute-only changes synchronize to the song model. Structural changes share the native undo/redo history with formatting and timing edits. **Undo** and **Redo** are in the formatting bar, which appears while editing text or selecting multiple lyric lines; the same actions are available through **Edit > Undo** (Command-Z) and **Edit > Redo** (Shift-Command-Z). They are disabled when no matching history is available. If a chosen font lacks a requested bold or italic face, the editor warns and leaves the text unchanged.

The mobile editor uses a native `UITextView` for each line. Formatting controls appear while editing lyric text, and a keyboard-dismissal action restores workspace space. It supports text formatting, annotations, symbols, line insertion and deletion, and styled line splitting.

Unformatted text uses an adaptive foreground color. On Mac, use the native color panel for arbitrary sRGB colors and opacity; secondary-click the color well to restore the adaptive default. The codec preserves intentional color and font choices when transferring songs between platforms.

### Record voice annotations

On Mac, hover over a lyric line to reveal **Add | Record | Play | Delete**. Click Record to create a take, then click its Stop button to save. macOS asks for microphone permission on the first recording. A red elapsed-time indicator stays visible while recording, even after the pointer leaves the line.

On iPhone and iPad, every lyric card shows the Record, Play, and takes buttons below the lyric, at the start of the row that ends with the line's timestamp and actions menu. Record and Play show icons only, and Play is available once the line has a take. Tap Record to create a take, then tap the red elapsed-time button to stop and save. iOS asks for microphone permission on the first recording; if access is denied, the error offers **Open Settings**.

Play listens to the default take; recording, selecting, or playing another take makes it the default. On Mac, the arrow beside Play opens a take picker with compact rounded rectangular cards. Each card shows the recording date and time, including seconds, and duration above an editable name, with **Play | Delete** beside the name. Click a card or focus its name to select it without starting playback. Opening the picker preserves the current selection. The selected card and selected lyric lines use an accent-tinted fill without a selection outline. Selecting a take does not add a navigation step to Undo history. This keeps everyday listening to one click while allowing multiple explanations or practice takes per line.

On iPhone and iPad, the takes button expands the card's take list, newest first, with each take's recording date and time, including seconds, and duration. Tap a take to make it the default without starting playback, use its Play button to listen, or open its menu to **Rename** it or **Move to Trash**.

Voice recording and listening pause active practice playback. Starting the song again finishes the voice take and stops voice playback. Changing songs or leaving the editor also finishes the take, as does moving the iOS app to the background. Deleting a take or lyric line moves its recordings to **Trash**; a running take is finished first. On Mac, Undo can restore completed takes until they are permanently deleted. Splitting a lyric leaves existing takes on the original line.

Recordings stay local until you explicitly export the song document. Use the `.singerslyrics` format to transfer lyrics and audio together; LRC contains no audio. See <doc:LibraryAndDocuments> for the package layout.

**Trash** has **Songs** and **Recordings** tabs. On Mac, choose it in the sidebar; on iPhone and iPad, choose it at the bottom of the library. The Songs tab restores complete deleted songs. The Recordings tab lists every deleted recording, including takes attached to songs in the Songs tab and takes removed individually, with a lyric line, or by imported lyric replacement. Each recording shows its original lyric and annotation. On Mac, select one, several, or all entries in the current tab and choose **Restore Selected**. On iPhone and iPad, swipe right on an entry, or touch and hold it and choose **Restore**; tap **Select** to restore or delete several entries at once. Restoring a song includes its attached takes; recordings deleted separately before the song remain independent entries in Recordings.

Restoring a recording while its song is still in Songs Trash restores that complete song with its attached takes, then reattaches any selected independently deleted takes. If no complete song snapshot exists, missing lyrics or songs are recreated only from the recording's saved context. This applies to songs deleted by earlier app versions, which did not retain unrecorded lyric lines. Existing lyrics and takes are preserved.

**Delete Permanently** confirms the exact selected entries before removing them. Permanently deleting a song removes its snapshot and attached takes; independently deleted recordings stay in Recordings. Permanently deleting selected recordings removes only those takes, even when they belong to a deleted song; its lyrics and other recordings remain available for restoration. Entries with permanent deletion pending cannot be restored, and failed removals can be retried. On Mac, **Show in Finder** opens a recording's real file location. Trash survives restarts and is excluded from song exports. See <doc:LibraryAndDocuments> for recovery details.

### Set and adjust timing

Start the linked song, then select a lyric line. Timing controls become available when the player has identified the matching track and is ready for synchronization.

On Mac, press the Space bar outside the text editor, or choose **Tap**, to stamp the selected line and advance. Inside lyric text, the Space bar inserts a space. Choose **Play from Line** to open the linked song if necessary and seek to that line's timestamp.

The Mac timing panel includes **Play from Line**, Pause, **Remove Timing**, and Cancel. It supports multiple selected lines, horizontal dragging, precise two-finger trackpad scrolling, and a jog wheel that previews adjustments. Compact layouts arrange adjustment, stamping, and delay controls vertically. Timing changes update the song, autosave, and participate in undo without replacing concurrent text edits.

On iPhone and iPad, the timing controls float above the lyrics. Tap **Stamp** to stamp the selected line and advance. Play/pause, **Clear Timestamp**, and timing options sit at the other end of the row, so rhythmic stamping can't pause the song. Drag the slider below them to move the selected line's timestamp up to half a second earlier or later; it shows the line's time and the shift as you drag. Selecting another line, stamping, or a timing-menu change starts a new adjustment from the line's current time. Open timing options for the stamp delay and 0.1-second adjustments. The text keyboard and formatting controls adapt to the available space.

### Follow lyrics during playback

Switch to the player to present the lyrics. Select a lyric or use the playback slider to seek; its times show –:–– until Music reports the song's length. Manual scrolling pauses automatic following. Starting playback, selecting a lyric, seeking, or using **Follow Current Lyric** in the playback controls resumes following.

The player can repeat the selected song when it finishes. If playback moves to an unrelated song, the shared playback model stops that playback and freezes lyric progress rather than assigning the new track's position to the selected lyrics.

### Adjust appearance

Use Settings to choose Auto, Light, or Dark appearance. The setting applies across the app's windows, sheets, and toolbars. On Mac, custom titlebar backgrounds also update when the effective appearance changes.

Choose a fallback lyrics font for text that has no explicitly assigned font. The preference leaves intentional font choices in individual runs intact. See <doc:LibraryAndDocuments> for how unavailable fonts are preserved on another platform.

## See Also

- <doc:InterfaceDesign>
- <doc:MusicPlayback>
- <doc:LibraryAndDocuments>
