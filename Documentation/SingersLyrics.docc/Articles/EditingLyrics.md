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

### Edit and format lyrics

Select lyric text to use bold, italic, underline, color, font, and symbol controls. Return splits a line and preserves its styled text. Annotations and timestamps remain associated with their lyric lines.

On Mac, formatting continues to act on the last text selection when a toolbar control takes focus. Attribute-only changes synchronize to the song model. Structural changes share the native undo/redo history with formatting and timing edits. If a chosen font lacks a requested bold or italic face, the editor warns and leaves the text unchanged.

The mobile editor uses a native `UITextView` for each line. Formatting controls appear while editing lyric text, and a keyboard-dismissal action restores workspace space. It supports text formatting, annotations, symbols, line insertion and deletion, and styled line splitting.

Unformatted text uses an adaptive foreground color. On Mac, use the native color panel for arbitrary sRGB colors and opacity; secondary-click the color well to restore the adaptive default. The codec preserves intentional color and font choices when transferring songs between platforms.

### Set and adjust timing

Start the linked song, then select a lyric line. Timing controls become available when the player has identified the matching track and is ready for synchronization.

On Mac, press the Space bar outside the text editor, or choose **Tap**, to stamp the selected line and advance. Inside lyric text, the Space bar inserts a space. Choose **Play from Line** to open the linked song if necessary and seek to that line's timestamp.

The Mac timing panel includes **Play from Line**, Pause, **Remove Timing**, and Cancel. It supports multiple selected lines, horizontal dragging, precise two-finger trackpad scrolling, and a jog wheel that previews adjustments. Compact layouts arrange adjustment, stamping, and delay controls vertically. Timing changes update the song, autosave, and participate in undo without replacing concurrent text edits.

On iPhone and iPad, use the timing dock to stamp the selected line and advance. Open timing options for fine adjustments. The text keyboard and formatting controls adapt to the available space.

### Follow lyrics during playback

Switch to the player to present the lyrics. Select a lyric or use the playback slider to seek. Manual scrolling pauses automatic following. Starting playback, selecting a lyric, seeking, or using **Follow Current Lyric** on mobile resumes following.

The player can repeat the selected song when it finishes. If playback moves to an unrelated song, the shared playback model stops that playback and freezes lyric progress rather than assigning the new track's position to the selected lyrics.

### Adjust appearance

Use Settings to choose Auto, Light, or Dark appearance. The setting applies across the app's windows, sheets, and toolbars. On Mac, custom titlebar backgrounds also update when the effective appearance changes.

Choose a fallback lyrics font for text that has no explicitly assigned font. The preference leaves intentional font choices in individual runs intact. See <doc:LibraryAndDocuments> for how unavailable fonts are preserved on another platform.

## See Also

- <doc:InterfaceDesign>
- <doc:MusicPlayback>
- <doc:LibraryAndDocuments>
