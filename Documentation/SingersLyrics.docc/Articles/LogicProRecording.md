# Recording in Logic Pro

Start a Logic Pro recording when you press Play in the Mac player, and stop it when the song pauses.

## Overview

With **Record in Logic Pro** turned on, a play action in the Mac player starts recording on Logic Pro's selected track, or on its record-enabled tracks. Pausing the song stops the recording. Singers Lyrics sends Logic Pro's Record and Stop key commands as MIDI messages from a virtual MIDI source named Singers Lyrics. Logic Pro must learn those messages once.

The feature is available only in the Mac app. See <doc:LogicProRecording#Understand-iPhone-and-iPad-support>.

### Assign the commands in Logic Pro

Assign both commands once. Logic Pro keeps the assignments for later projects and launches.

1. Open Singers Lyrics, which publishes the Singers Lyrics MIDI source while it runs, then choose **Singers Lyrics > Settings**.
2. In Logic Pro, choose **Logic Pro > Key Commands > Edit Assignments**.
3. Search for `Record`, select the **Record** command, and click **Learn New Assignment**.
4. In Singers Lyrics Settings, click **Send Record**.
5. In Logic Pro, select the **Stop** command and click **Learn New Assignment**.
6. In Singers Lyrics Settings, click **Send Stop**.

If the Key Commands window doesn't show **Learn New Assignment**, choose **Logic Pro > Settings > Advanced** and select **Enable Complete Features**.

The Send buttons also trigger an assigned command, so you can use them to test the assignments.

### Record a take

1. In Logic Pro, open a project and select the track to record, or record-enable the tracks to record.
2. In the Mac player, click the record button beside Play, or turn on **Record in Logic Pro** in Settings. The button's outline turns red while the feature is on. Clicking the player button while the song plays starts recording immediately.
3. Press Play, or select a lyric line to play from it. Logic Pro starts recording once the song is playing, and the record button fills and pulses.
4. Pause the song to stop recording. A pause from the editor's timing controls, Music, or the keyboard's media keys also stops it. The feature stays on for the next Play.

Selecting another song, closing the window, quitting, or turning off **Record in Logic Pro** also stops the recording. Switching between the editor and player columns doesn't.

Logic Pro's own recording settings still apply. Turn off the count-in so recording starts with the song, and turn off **Click while recording** in Logic Pro's metronome settings if you don't want to hear the click while singing.

### Understand the behavior

- A take starts only from the player: Play, a lyric line, or turning on the record button while the song plays. Playback started from the editor's timing controls or from Music doesn't record, so timing work never creates takes. Any pause ends the take.
- Singers Lyrics publishes its MIDI source at launch. Logic Pro connects to a new source asynchronously, so a command sent the moment the source appeared would be lost.
- The model sends Record after the play action leaves the song playing, so a failed or slow startup doesn't record silence.
- Stop is sent only to end a take that Singers Lyrics started. When Logic Pro is already stopped, Stop moves its playhead to the project start.
- A finished song that repeats in the player continues the same take.
- Seeking within the playing song doesn't start a new take.

### Review the MIDI messages

Each command is one Control Change message with value 127 on MIDI channel 16:

| Command | Controller | Bytes |
| --- | --- | --- |
| Record | 102 | `BF 66 7F` |
| Stop | 103 | `BF 67 7F` |

Controllers 102 and 103 are undefined in the MIDI specification, so a message that Logic Pro hasn't learned has no audible effect on the selected track. Each command is a single full-value message rather than a press-and-release pair, so Logic Pro learns a fixed trigger.

The virtual source restores its MIDI unique ID on later launches, so Logic Pro's learned assignments continue to match it. Automated tests use an inert sender and don't publish a source.

### Understand design decisions

- MIDI Machine Control can't start a recording. Logic Pro's **Listen to MMC Input** setting responds to Play, Deferred Play, and Stop, but not Record.
- Simulated keystrokes would require Accessibility access and would reach Logic Pro only while it is the frontmost app. Logic Pro has no scripting dictionary for its transport.
- The connection is one way. Singers Lyrics doesn't confirm that Logic Pro is open or recording; the pulsing button shows that it sent Record.

### Understand iPhone and iPad support

Logic Pro for iPad doesn't offer MIDI-assignable transport commands, and iOS apps can't send key commands to other apps. The iOS app therefore doesn't include this feature.

Triggering Logic Pro on a Mac from an iPhone or iPad over Network MIDI is possible future work. It would require local network permission and connecting the device in Audio MIDI Setup.

### Review validation

The macOS and iOS Simulator builds succeed, and the unit-test target compiles. Unit tests weren't run. A temporary CoreMIDI harness, compiled with the sender, verified the published source, the bytes received by a MIDI 1.0 input port, and unique ID reuse across launches. Logic Pro 12.4 listed the Singers Lyrics source among its enabled MIDI inputs under the persisted unique ID. These checks don't cover recording in Logic Pro after the commands are assigned; use the steps in <doc:Testing>.

## See Also

- <doc:MusicPlayback>
- <doc:Testing>
- <doc:Troubleshooting>
