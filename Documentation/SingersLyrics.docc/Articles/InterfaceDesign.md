# Designing the interface

Adapt the library, editor, and player to each platform while preserving the selected song and playback session.

## Overview

Each platform presents the same song model through a layout suited to its available space. The mobile mode switch stays in a consistent navigation-bar position, and playback controls remain near the bottom of the detail view.

| Platform | Primary layout | Navigation |
| --- | --- | --- |
| Mac | Library, editor, and player columns | Workspace controls select editor-only or player-only modes. |
| iPhone | Library, then the selected song's editor or player | Back returns to the library; the top-right button switches Editor and Player. |
| iPad | Library and one detail column | The detail switches between editor and player; compact windows collapse to the phone flow. |

### Present the Mac workspace

The Mac window places the library, lyric editor, and live player in three columns. A read-only title-and-singer header occupies the editor side of the toolbar and truncates at the editor boundary. It disappears in player-only mode.

The sidebar hides when the window can no longer fit all three columns. Separate collapse and restore thresholds avoid repeated toggling near that width. Manually hiding the sidebar is preserved as the window grows. The app owns the visibility toggle and doesn't widen the window to reveal the sidebar. The divider remains draggable.

The library's add menu and Sort control share a fixed group aligned with the library edge, with six points of internal spacing. The sidebar toggle is inset from the divider. The title and toolbar positions follow the column boundaries as dividers move. Only the sidebar material extends behind the window controls.

Song management, lyric import/export, and workspace visibility use three compact control groups on the player side of the toolbar. Search shrinks as the column narrows, then becomes a button with a search popover. The groups remain within the player column and keep their controls readable.

When the library is empty or nothing is selected, one workspace-wide panel offers song creation and bundle import. The same actions remain available from the sidebar's add menu.

### Present the mobile workspace

On iPhone, launch shows the searchable song library. The library omits a navigation title and its large-title space. Selecting a song opens its editor, which shows the title at the leading edge of the navigation bar, followed by the singer when both fit, like the Mac editor header. The player presents the title and singer above its lyrics instead. The labeled **Player** button at the top right switches that song to presentation mode; **Editor** appears in the same location to return. These are screens in one navigation flow.

On iPad, the library and selected editor or player occupy two columns. The editor title uses the native large-title font at regular widths. The system sidebar control hides or reveals the library. Narrow multitasking windows use the phone navigation flow and compact title size.

The library ends with a **Trash** row whose badge counts deleted songs and recordings; it opens Trash as another detail destination. Song rows show text only, with a heart marking favorites. In the editor, each lyric card gives its annotation the full width. The row below the lyric starts with recording controls on every card and ends with the line's timestamp and actions menu. The take list expands inside the card rather than in a sheet. The editor's timing controls and fine-adjustment slider share one rounded Liquid Glass panel within the detail column, so on iPad they stay beside the sidebar instead of extending beneath it. Formatting and keyboard controls use the same panel while editing text.

Playback controls are centered along the bottom of the detail view, above the home indicator. The player dock uses the same regular Liquid Glass surface and rounded corners as the editor's timing dock. Its maximum width fits all button groups with 12 points of padding on each side. On both iPhone and iPad, every button stays in one row below the progress slider: lyric alignment on the left, then resume-following, then play/pause at the far right. Narrower columns use smaller button widths and spacing, with a 44-point play/pause button instead of the regular 60-point button. The Mac player also places resume-following immediately before play/pause at the far right, after its Logic Pro recording control. There are no five-second seek buttons; use the progress slider to seek. The mode switch remains in the navigation bar. Lyrics wrap to the available width, and the editor makes room for its keyboard and timing dock.

### Keep controls clear of content

On Mac, formatting and timing panels float over the lyric scroller in rounded glass capsules. Matching scroll clearance prevents the panels from covering the last lyric. Formatting appears only while lyric text is active or multiple lines are selected; timing remains visible.

Selecting a card, annotation, or timestamp selects that line for timing. Command-click toggles individual line selection, and Shift-click selects a contiguous range. Inline controls insert and delete lines, including the final line. Narrow timing-panel layouts stack related groups while retaining their control sizes.

### Render and scroll the player

The player presents a centered song title and singer before the lyrics. They scroll with the content but remain outside the timed lyric collection, so the first lyric retains synchronization index zero.

Pinch over the player lyrics to change the text size: use two fingers on iPhone or iPad, or a trackpad pinch on Mac. Lyrics, annotations, and the song header resize together. The lyric size stays within 24–64 points on iOS and 28–72 points on Mac, before iOS Dynamic Type scaling. A completed pinch saves the size for other songs and future launches; a cancelled pinch restores the saved size. VoiceOver also offers **Smaller Lyrics** and **Larger Lyrics** actions on the lyrics scroller.

The initial lyric size is 44 points on Mac and 34 points on iOS. Each lyric entry has vertical padding that grows with the displayed font size within a narrow range: 10–18 points per edge on Mac and 12–20 points per edge on iOS. At the initial sizes, the padding remains 14 and 16 points per edge respectively. The mobile 44-point minimum tap height includes that padding, so short lyrics don't gain another layer of whitespace at small sizes. Dynamic Type still scales the text; the extra padding stays within its range.

Within one lyric entry, wrapped lines use the font's natural line height plus 2–4 points of extra spacing before playback emphasis, less than the padding between separate entries. This extra spacing is six percent of the displayed lyric size, clamped to that range. Mobile lyrics wrap to the available width. Mac lyrics retain their intrinsic width and can scroll horizontally; the same tight spacing applies if an entry contains line breaks.

The pinch begins without a minimum scale-change threshold, and size updates follow the gesture without an easing animation. The player constructs SwiftUI text attributes directly so each update avoids copying and converting editor attributed strings. Lyrics continue to reflow at their actual font size while pinching.

Lyric playback buttons are locked during a pinch and for 180 milliseconds after it ends or is cancelled. Both the buttons and their playback actions reject activation while locked; the brief release delay also absorbs trailing touch or mouse events. A new pinch keeps the lock active, and leaving the player clears it. Audio that is already playing continues normally.

Three alignment icons place lyric blocks at the left, center, or right. Annotations stay left-aligned within their lyric block and wrap to the lyric's width, so longer annotations don't shift the lyric's position. The alignment preference persists between songs and app launches; centered alignment is the default.

The Mac player accounts for the rendered height of active and inactive lyrics before adding row padding, so enlarged text doesn't consume the gap reserved between entries. Its horizontal layout width stays independent of playback emphasis, keeping the scrolling canvas and alignment stable. Measuring row heights up front and easing scrolling keep the active line readable. The final line can reach the vertical center of the viewport without excess scroll space beyond that position. Bottom clearance adapts to the viewport height.

On Mac, a soft gradient and frosted titlebar fade scrolling lyrics into the player background. The backdrop samples content without reflecting or duplicating it and follows the player column in split and player-only modes. Reduce Transparency replaces the material with an opaque background and color fade. The editor header uses the same approach within its own column boundary.

## See Also

- <doc:EditingLyrics>
- <doc:AppArchitecture>
- <doc:Testing>
