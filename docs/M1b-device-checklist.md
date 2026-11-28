# M1b listening and Pencil hand checklist

## Status and exact build
This is the M1b delivery checklist, not an assertion that M1b has passed. Use only the final IPA and exact commit/run/SHA256 recorded in the delivery message. Do not substitute an intermediate archive or an older installed app. Automated native tests, simulator pixels and IPA integrity are separate from physical Pencil operation and listening. Earlier permission to progress without device testing does not mean physical tests passed.

Current correction baseline: `5be49bcd5a14ea0192d35ce56c1efb1fd655a876`, run `46060536437`: **failed**, publication skipped. This is not the final deliverable. Owner accepted the barrel-roll speed in the earlier `f6a0dec` IPA, but reported reversed direction and absent light Pencil ticks. Those failures need correction and retest; preserve accepted speed. Radial rounded contours/pills are implemented, but available-space sizing is not yet accepted. Real short Swing drags also remain a native failure at this baseline.

## Prepare safely
- Re-sign/install the final unsigned device IPA through the existing SideStore workflow, then launch in landscape on the iPad Pro with Apple Pencil Pro paired. Start at low output volume; note the audio route, preset and BPM.
- In system Pencil settings, check that squeeze is available to the app and Pencil haptics are enabled. Record settings/hardware and any battery or system restrictions if output is absent. A visual flash or an API-call test does not prove tactile feedback.
- Create a four-bar progression. Record the exact chords, tempo, loop and synth controls so the no-pattern and pattern comparison uses the SAME material. No AI, Bass/Melody, note-edit/razor or arpeggio feature is required by this M1b checklist.

## Compare real playback of the same chords
- With no pattern applied, play the progression: expect the existing simultaneous block-chord sound. Check silence in rests and no stuck notes at chord ends or loop boundaries.
- Squeeze in the big chord piano roll and select **Pattern**. Expect a temporary overlay on that large roll, not a permanent lane, short-strip editor or separate window. Only **Swing** and **Tight/Loose** should appear at the far right of the top bar; no Done, visible Pop Rock action or Spread control.
- Add downstrokes to a few eighth-note slots and replay without changing the chords or synth. The attack rhythm/strum order must be audibly different, not merely a different drawing. Note pitches/chord identities must remain the same.
- Close editing with the existing Pattern squeeze toggle. The pattern must keep affecting playback even while its overlay is closed. Reopen it: the strokes and per-pattern settings must remain.
- Remove the applied pattern through supported undo: the unchanged chords must return to block playback. Redo should restore the patterned playback. Report which transition fails rather than accepting generic nonzero audio as proof.

## Pencil strokes, velocity and chuck
- Confirm exactly **eight quantized slots per bar** aligned with the timeline when panning/zooming.
- Touch down in the top half and drag: downstroke arrow starts at the top, pitches sound low to high. Touch down in the bottom half: upstroke starts below, pitches sound high to low.
- Exercise all **ten** arrow lengths, one tenth to full editing-area height. Arrow/readout/stored base velocity must agree: 10 through 100 in steps of 10. Zero is an empty slot, not an audible eleventh level. At minimum/maximum, check neither arrow nor head is clipped.
- Drag an existing stroke to edit length/direction; tap it with the Pencil to remove it. A completed gesture is one undo operation, not an undo per movement sample. Cancelled/no-op gestures must not add history or clear redo.
- Draw a roughly closed circle: expect chuck ring/X and short percussive rake on **all three presets**. Larger circle changes chuck velocity continuously; chuck size is not forced into arrow's ten levels. Taps, tiny drags and unclosed paths must not accidentally create chuck.
- Start a stroke, cross into a top-bar control/drawer, move back, then lift. The cancelled stroke must not reappear or commit on lift. Verify the following valid Pencil stroke still works.
- Empty pattern slots must introduce no new attack and must not chop a preceding sound. Chord/rest/loop boundaries still stop the appropriate notes. Listen for doubled attacks, old note-offs killing new strokes, stuck notes or clicks.

## Real Swing and Tight/Loose controls
- From Swing 0, perform a short upward finger drag inside the 44pt Swing target and lift: the committed percentage must increase. A second downward drag must decrease from that committed baseline. Preview alone is not success; close/reopen Pattern and check retention.
- Exercise minimum/maximum clamping and a drag that is cancelled. No stale draft should survive cancellation. Chord pitches and chord-history content must not change while adjusting performance settings.
- Tight/Loose must work at both capsule center and padded edge, return to Tight when toggled back, and remain independent of Swing.
- With repeated eighths, compare zero/nonzero Swing: deterministic off-beat lilt should be audible. Compare Tight/Loose at the same Swing: Loose should add small variations, not random rhythm replacement or severe detuning. Repeated wraps must stay synchronized without cumulative drift.

## Pencil roll, haptics and radial follow-up
- Hover a synth/FX knob and roll the Pencil in the direction that should increase it, then reverse. Direction must match the intended physical turn, with the accepted continuous speed preserved. Check a gradual roll, angle wrap, reversal, target change and leaving/re-entering a knob.
- Slowly cross normalized value boundaries around 5% apart: feel light ticks in the Pencil, not merely a screen flash or iPad vibration. Check both directions, default, minimum and maximum. Report whether stronger endpoint/default distinction is actually perceptible; UIKit event dispatch alone cannot certify intensity.
- Squeeze/select/reset a knob and select a chord-radial option or Pattern. Confirmation should be tactile where supported. Rapid selection after a roll tick must not permanently lose its confirmation.
- Inspect primary and All/paged radial menus near center, edges and corners, plus the one-option Pattern menu. Rounded tracks and overlaid curved pills must remain legible with no clipping or hidden choices. Check the corrected available-space sizing/count/spacing behavior against the recorded owner requirement; do not accept the old fixed footprint solely because its ends are rounded.
- Long chord/slash labels, selected/dimmed/disabled states and preview readouts must fit their pills and not obscure a required choice. Hover/cancel must not edit; lift on an enabled choice commits exactly once. Physical reach/readability remains the owner's judgment.

## Safety and regressions
- Fingers may pan/zoom, press UI and drag performance knobs, but must not create/move/remove/select/audition notes, chords or pattern strokes. Resting a hand must not change music. Pressure, tilt and Pencil barrel double-tap remain unused.
- Two-finger double tap undoes; three-finger double tap redoes. Single multitaps must not do either. Keep checking one transaction per completed music edit, cancellation/preview preserving redo, and ordinary chord editing after closing Pattern.
- During playback, adjust BPM, scrub/seek, pause/resume, loop on/off, change presets, mute/unmute and undo/redo a pattern. No crash, persistent silence, out-of-sync attacks, old wet-audio burst or hanging notes.
- Background/foreground and switch audio route where practical: recover safely or show an honest paused/unavailable state. No microphone permission or network/AI service is needed.

## Listening and report
- Listen to patterned/unpatterned versions on Pluck, Currents pad and Wobble at comfortable volume. Judge warmth, strum clarity, humanize subtlety, chuck character, tail overlap and headroom. A brief comparison is not proof of the 2+ hour comfort goal.
- Record exact final commit/IPA hash, iPad/Pencil model and OS, audio route, system Pencil settings, chords, pattern slots/levels, preset, BPM, loop, playback state, reproducible gesture and expected/actual result. For direction, describe the physical turn and observed knob movement. For haptics, distinguish absent/light/strong and approximate speed.
- Mark each section **passed / failed / not tested**. Unperformed physical tests stay not tested; delivery, CI success and permission to advance do not silently convert them to acceptance.
