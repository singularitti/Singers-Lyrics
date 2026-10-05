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

On iPhone, launch shows the searchable **Music** library. Selecting a song opens its editor. The labeled **Player** button at the top right switches that song to presentation mode; **Editor** appears in the same location to return. These are screens in one navigation flow.

On iPad, the library and selected editor or player occupy two columns. The system sidebar control hides or reveals the library. Narrow multitasking windows use the phone navigation flow.

The library ends with a **Trash** row whose badge counts deleted songs and recordings; it opens Trash as another detail destination. In the editor, the selected lyric card, and any card with takes, shows recording controls below its lyric, and the take list expands inside the card rather than in a sheet.

Playback controls are centered along the bottom of the detail view, above the home indicator. Text size, seeking, play/pause, and resume-following controls stay together. The mode switch remains in the navigation bar. Lyrics wrap to the available width, and the editor makes room for its keyboard and timing dock.

### Keep controls clear of content

On Mac, formatting and timing panels float over the lyric scroller in rounded glass capsules. Matching scroll clearance prevents the panels from covering the last lyric. Formatting appears only while lyric text is active or multiple lines are selected; timing remains visible.

Selecting a card, annotation, or timestamp selects that line for timing. Command-click toggles individual line selection, and Shift-click selects a contiguous range. Inline controls insert and delete lines, including the final line. Narrow timing-panel layouts stack related groups while retaining their control sizes.

### Render and scroll the player

The player presents a centered song title and singer before the lyrics. They scroll with the content but remain outside the timed lyric collection, so the first lyric retains synchronization index zero.

Stable row heights and eased scrolling keep the active line readable. The final line can reach the vertical center of the viewport without excess scroll space beyond that position. Bottom clearance adapts to the viewport height.

On Mac, a soft gradient and frosted titlebar fade scrolling lyrics into the player background. The backdrop samples content without reflecting or duplicating it and follows the player column in split and player-only modes. Reduce Transparency replaces the material with an opaque background and color fade. The editor header uses the same approach within its own column boundary.

## See Also

- <doc:EditingLyrics>
- <doc:AppArchitecture>
- <doc:Testing>
