# M1 device acceptance checklist

Use this checklist only with the final M1 candidate IPA identified in the delivery message. Intermediate foundation/DSP IPAs do not contain the complete editor. Passing automated CI is not owner approval and does not establish physical Pencil behavior, latency, sound quality or listening comfort.

## Installation and startup
- Re-sign/install the supplied unsigned `App.ipa` using the existing SideStore workflow. Launch on the landscape iPad Pro with Apple Pencil Pro paired.
- Expect an empty eight-bar canvas, not a preloaded song. Check landscape remains locked after an attempted physical rotation, and labels use the bundled Plus Jakarta Sans font without clipped text.
- Start at low system/output volume. No microphone permission should be needed. If audio is unavailable, the app should show an honest quiet error instead of implying playback succeeded.
- For app squeeze interaction, ensure the Pencil system Squeeze setting is not assigned to a Shortcut that consumes it. Record the setting when reporting squeeze issues.

## Make a four-bar progression
- Pencil-tap empty chord-strip slots to create four consecutive chords; use the chord radial/swap choices to make **Cm7, Abmaj7, Fm9, G7alt** if available. Other four-chord choices are also valid for basic functional testing.
- Verify each block shows its chord name and Roman numeral. Hover/detail mode should reveal additional information without permanent visual clutter.
- Pencil-drag a chord's right edge: timing should snap to legal steps and neighboring blocks must not overlap. A completed resize should be one undo action, not many.
- Pencil-hold a chord and exercise Copy, Duplicate and Delete. Paste into a legal empty location. Invalid placements should leave the progression unchanged.
- Two-finger **double** tap undoes; three-finger **double** tap redoes. Single multi-finger taps should not undo/redo. Audition should not add history entries or clear redo.

## Input separation and radial menus
- Tap, drag and hold chords with a finger: **no add, selection, edit, deletion or audition**. Fingers may navigate the canvas and press ordinary controls only.
- Pencil-tap a chord to audition it. Confirm hover previews do not permanently alter the progression.
- Squeeze over an existing chord: inner tools and outer three rule-based quality/extension choices plus All should appear. Outer choices should preserve the chord root; Swap is separate.
- Squeeze an empty slot: try suggested next chords and Paste/Rest as available. Cancel without committing by moving away/lifting outside a choice.
- In All, exercise major, minor and odd chord families, including an opposite-family choice. Labels must stay reachable near all screen edges; no menu should clip offscreen or react to a resting finger.
- Barrel double-tap remains unbound; pressure and tilt must not change music.

## Transport and editing while playing
- Set a four-bar loop, press Play and listen through repeated wraps. Chords should be simultaneous blocks; M1 has no strum/pattern engine yet.
- Pause/resume, restart, disable looping and let playback end. No hanging held notes or obsolete queued chords should remain.
- Finger-scrub the timeline, drag loop braces, change BPM (drag and typed entry), and edit a chord during playback. Check playhead alignment, stable timing, valid looping and no crash/persistent silence.
- Leave the loop running while opening settings/drawer or briefly leaving UI idle. Note scheduling must not depend on active finger movement.
- Pan/zoom: ruler, chord blocks, notes and playhead should stay aligned. No finger navigation should create music.

## Synth and drawer
- Open/close by drawer icon, right-edge/pull-tab gesture and canvas dismissal. Drawer should overlay below the strips, not cover them or shrink/reflow the canvas.
- Switch **Pluck, Currents, Wobble**; exactly three presets. Verify real sound changes, no clicky global reset or lost controls.
- Exercise **Wobble, Warmth, Cutoff, Resonance, Shape, Detune, Glide**, shared **Delay/Reverb**, Chords volume and Chords mute.
- Finger-drag knobs; hover for exact readout; Pencil-roll knobs through default/min/max; squeeze a knob to reset. Judge detents/dead zone and physical haptics or the documented visual fallback.
- Mute with audible delay/reverb tails, then unmute quickly. Old wet audio must not suddenly return. Watch for clipping on dense extended chords.
- Toggle hidden UI with four fingers and restore it. Canvas/playhead should remain usable/visible; no unexpected edits.

## Listening (from docs/sound-brief.md)
At normal comfortable volume, play the four-bar progression on loop:
1. Is Pluck a synth pluck, not a guitar?
2. Is Currents warm and spacious without mud?
3. Is Wobble's glide musical rather than seasick?
4. Do Wobble and Warmth make sense over their full ranges?
5. After 20–30 minutes, are highs, resonance or repeating clicks tiring? The longer 2+ hour comfort goal still needs real listening; a short test cannot prove it.
6. Do old chord tails overlap the next chord smoothly, without pops/clicks?
7. At normal volume, is there headroom and no clipping on dense chords?

## Lifecycle and reporting
- Background/foreground the app, interrupt audio, and change output route where practical. It must recover safely or present a clear paused/unavailable state, never crash or leave stuck notes.
- Report a failure with the exact gesture/controls, chord sequence, preset, BPM, loop bounds, output route and whether playback was active. For sound, simple descriptions are enough (for example, "Currents gets harsh with Warmth low").
- Final M1 acceptance requires the owner's explicit **approved** reply after testing. Until then M1 remains awaiting device acceptance, and M1b must not start.
