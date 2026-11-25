# coda — iPadOS Music Sketchpad — Unified Design & Build Spec (v2)

> Single source of truth for the app's design, sound, interaction, ML and build plan.
> Written for an AI orchestrator/coding agent (Hermes → Codex CLI) and for second-opinion reviewers.
> Date: 2026-11-25. The owner confirms no original blueprint exists; historical comparisons in §21 are not an external source or prerequisite.

> App name: **coda**. Sidekick name: **coda**. Both names are owner-confirmed (DECIDED).

---

## 0. How to use this document

### 0.1 Status tags (every rule carries one)

| Tag | Meaning | Executor behavior |
|---|---|---|
| **DECIDED** | The owner stated or confirmed it. | MUST implement exactly. MUST NOT change without asking the owner. |
| **PROPOSED** | Suggested during brainstorming and not rejected. | Implement as written as the default. Log in ROADMAP.md that it is a default so the owner can veto. |
| **OPEN** | Not decided. | Implement the stated default behind a single constant/flag. Add it to "needs owner input". Never silently invent a different behavior. |
| **CARRIED** | Previously carried forward and not re-discussed. | Keep requirements stated here unless they contradict a DECIDED item. No original blueprint exists; do not invent absent details. |
| **VERIFY** | Platform/API/version claim that was not confirmed. | Check against current Apple/library docs before relying on it. |

### 0.2 Precedence (highest wins)
1. Decisions made in the owner's brainstorming chat (everything tagged DECIDED in this file).
2. The owner's pasted technical spec (ML, build, orchestration) — these are **extensions**, accepted where they do not conflict with (1).
3. `docs/DESIGN.md` — the UI design file (layout, components, visual states, motion). It is the source of truth for how the UI looks and **overrides the prototype**. Where it conflicts with this spec on behavior, this spec wins.
4. The Stitch HTML/CSS prototype in `docs/prototype/` — **AI-generated, outdated and NOT final**; loose mood reference only. Prototype visual tokens are preserved in §15 unless a DECIDED rule or `docs/DESIGN.md` overrides them.
5. There is no original blueprint (owner-confirmed). §19 lists the carried requirements; any unspecified design details must not be attributed to a nonexistent file.

### 0.3 Owner role
The owner decides design, sound and feel. Implementation, architecture and code structure are the agent's job. Do not ask the owner architecture questions. Ask only the OPEN design questions in §22.

### 0.4 Reference style
Sections are cited as `§7.3`. "MUST / MUST NOT" are hard rules. Rules in tables are one row = one testable behavior.

---

## 1. Project snapshot & constraints

| Item | Value | Status |
|---|---|---|
| Scope | Single-user personal iPadOS app. Not a release project. | DECIDED |
| Device | iPad Pro 13" (M5). Owner states 12 GB unified memory (some storage tiers ship 16 GB — confirm on device). | DECIDED / VERIFY |
| Orientation | **Landscape only.** Never portrait. | DECIDED |
| Pencil | Apple Pencil Pro (squeeze, barrel roll, hover, haptics). Tilt and pressure are **not used**. | DECIDED |
| OS target | Latest iPadOS SDK only. No backward compatibility, no iPhone/adaptive layouts, no App Store compliance, no low-RAM fallback modes. | DECIDED |
| Distribution | Unsigned `.ipa` sideloaded via SideStore. Free-account re-signing means special entitlements may be stripped → do not rely on them. | DECIDED / VERIFY |
| Project file | XcodeGen (`project.yml`). Never hand-edit `.xcodeproj`. | DECIDED |
| CI | GitHub Actions (`macos-latest` runner — VERIFY it provides the Xcode/iPadOS SDK needed; pin runner/Xcode if not): `xcodebuild archive` with `CODE_SIGNING_ALLOWED=NO` → package unsigned `App.ipa` artifact. | DECIDED |
| Audio stack | SwiftUI + AVFoundation (`AVAudioEngine`). | DECIDED |
| Real-time rule | ML inference, JSON/XML parsing, text streaming and UI state updates MUST stay off the real-time audio render thread. | DECIDED |
| Sound references | Balatro soundtrack and Tame Impala *Currents*: warm, detuned, wobbly, phased synths. Pluck leans synth, **not** a realistic guitar simulation. | DECIDED |
| Ear safety | Sounds MUST NOT fatigue the ears when one loop plays for 2+ hours (§13.5). | DECIDED |
| Development style | Vibecoded: Hermes (tech lead) briefs Codex CLI per milestone (§24). | DECIDED |

---

## 2. Design principles

| # | Principle | Status |
|---|---|---|
| P1 | **Procreate philosophy.** Canvas-first. Everything hidden by default. The app is usable with no visible UI plus the Pencil. Menus are easy once you know where to open them. No Photoshop-style clutter. | DECIDED |
| P2 | **One home per feature.** A feature has exactly one place to open it; a gesture means the same thing everywhere. | PROPOSED |
| P3 | **Finger looks, Pencil touches.** Fingers navigate and press UI. Only the Pencil edits music. | DECIDED |
| P4 | **Melody is fully manual.** AI never writes or edits melody notes. | CARRIED |
| P5 | **Few presets, few knobs.** 3 presets, slight customization. | DECIDED |
| P6 | **Non-destructive.** AI output appears as ghosts and never overwrites user edits (§14.4). | DECIDED |
| P7 | **Everything undoable** via the finger undo/redo gestures (§3.2). | PROPOSED |
| P8 | **Show less by default.** Dense info (labels, voicing tags, function tags) is revealed on hover or via a toggle. | PROPOSED |

---

## 3. Input model

### 3.1 Finger — DECIDED
- MAY: pan and zoom the canvas; press UI elements (buttons, pills, capsules, mute circles, knobs, sliders, pickers, drawer pull-tab/edge swipe); scrub the timeline strip; drag loop braces; press-and-hold UI elements for hold menus (§12).
- MUST NOT: create, move, resize, delete, select or audition notes, chords or pattern strokes.
- There is intentionally **no finger-edit fallback**. A hand resting on the screen can never change music.

### 3.2 Multi-finger gestures
| Gesture | Action | Status |
|---|---|---|
| Two-finger **double** tap | Undo | DECIDED |
| Three-finger **double** tap | Redo | DECIDED |
| (Single taps) | MUST NOT be used for undo/redo — they would conflict with pan/zoom. | DECIDED |
| Four-finger tap | Toggle hide/show all UI chrome (listen-only mode) | PROPOSED |

Note the naming: the Pencil's **barrel double-tap** (§3.3) and these **finger double-taps** are unrelated gestures.

### 3.3 Apple Pencil Pro
| Gesture | Meaning | Status |
|---|---|---|
| Touch/drag on canvas | All music editing (draw, move, resize, razor, select, strum strokes) | DECIDED |
| **Squeeze** | ALWAYS opens a **radial menu** at the Pencil tip, content depends on context (chord → §7.4, piano roll → §11, knob → §13.4, empty chord slot → §7.4) | DECIDED |
| **Barrel double-tap** | Undecided. Leave unbound. Candidates: "switch to previous tool" (Procreate-style), play/stop. | OPEN |
| **Barrel roll** | ALWAYS interacts with knobs and **cycles through states where possible** (chord voicings, octave spreads, etc.) — see §3.4 | DECIDED |
| **Haptic feedback** | The Pencil gives haptic feedback while rolling — see §3.4 | DECIDED |
| **Hover** | Highlights the target that roll will affect; shows exact knob values; may preview. Needs hover-capable iPad (M-series: yes). | PROPOSED |
| **Pencil tap on a chord** | Auditions that chord (finger cannot audition). | PROPOSED |
| **Press-and-hold on a music object** | Opens a compact option list for that object (§12) | PROPOSED |
| **Pressure, tilt** | Not used anywhere | DECIDED |

**Radial vs hold rule (PROPOSED):** *Squeeze radial = modes and changes (what do I want to do next).* *Press-and-hold list = commands on this object (copy, duplicate, delete…).* Never mix the two.

### 3.4 Barrel roll behavior & haptics
| Rule | Status |
|---|---|
| Roll acts on the element under the Pencil tip (hover or touch). A subtle highlight shows what roll will change. | PROPOSED |
| **Continuous controls (knobs):** roll turns the knob smoothly. | DECIDED |
| **Discrete states:** roll steps one state per detent. Examples: chord inversions/voicings, octave spreads, bass note root↔fifth↔octave, pattern/preset choices. | DECIDED |
| **Haptics:** each discrete step produces one haptic tick. Continuous knobs give light ticks at regular intervals (~every 5% of range), a stronger tick at min, max and at the preset's default value. | DECIDED (feature) / PROPOSED (tick spacing) |
| A haptic tick also confirms a radial-menu selection. | PROPOSED |
| Dead zone: ignore tiny rotations (~±12°) so normal hand movement does not change values. | PROPOSED |
| While stepping chord voicings the new voicing sounds immediately (audition while you roll). | PROPOSED |
| Value readout appears near the tip while rolling. | PROPOSED |
| Implementation: investigate Pencil Pro haptics (candidate API: `UICanvasFeedbackGenerator`) — VERIFY. Haptic calls MUST NOT run on the audio thread and MUST be rate-limited. If unavailable, fall back to a visual detent flash. | VERIFY |

---

## 4. Screen layout (landscape)

```
┌────────────────────────────────────────────────────────────────────────────────┐
│ ⚙ ⋯ │ C Min·NAT │ 124 BPM │ 4/4     ⟲  ▶  ○ ○ ○        [Bass][Chord][Melody] ✦ │ ~1 cm top bar
├────────────────────────────────────────────────────────────────────────────────┤
│SNAP│ 1        2        3        4 … 8  thin timeline · loop braces · playhead  │ very thin
│    │ (faint chord names here in Melody/Bass modes)                              │
├────────────────────────────────────────────────────────────────────────────────┤
│CHORDS│ [Cm7][Abmaj7][Fm9][G7alt][ ][ ][ ][ ]      (Chords mode only)            │ ~2 cm
├──────┬──────────────────────────────────────────────────────────┬──────────────┤
│pitch │  full piano roll for the selected layer                  │ right drawer │
│gutter│  (other layers shown dimmed as ghosts)                   │ (on demand)  │
└──────┴──────────────────────────────────────────────────────────┴──────────────┘
```

| Rule | Status |
|---|---|
| Top bar height ≈ **1 cm** (≈ 52 pt on the 13" iPad). | DECIDED |
| Chord strip height ≈ **2 cm** (≈ 104 pt). Visible **only when Chords mode is selected**. | DECIDED |
| Thin **timeline strip** sits **above** the chord strip, always visible in every mode. It shows bar numbers, playhead, loop braces, and — in Melody/Bass modes — subtle chord names. | DECIDED |
| Timeline strip extras: finger-drag scrub to move the playhead; finger-drag loop brace handles; chord-name text tinted with the Chords layer color. | PROPOSED |
| Piano roll fills the remaining height; **full keyboard in all three layers**. | DECIDED |
| Prototype pixel sizes (§15) are CSS px of a scaled preview. The cm targets above are the real-world intent; verify on device. | VERIFY |
| Visible measures: prototype shows 8. Default to an 8-bar canvas, loop 1–8 bars. | PROPOSED |
| Right drawer overlays the roll (does not reflow it) and starts **below** the thin strips so ghost chords stay visible (§13.6). | PROPOSED |

---

## 5. Top bar (left → right)

| Zone | Element | Behavior | Status |
|---|---|---|---|
| Left | **App Settings** (gear, 32×32) | Opens a compact popup menu with its own tabs, Procreate-style. | DECIDED |
| Left | **Project Settings ⋯** | Popup for *miscellaneous* project settings (time-grid options, output, saving, etc.). Sits next to App Settings, visible, not hidden. | DECIDED |
| Left | **Prominent project settings**, each its own separate control (never lumped into one menu): **Key/Scale capsule** (e.g. `C Min` + `NAT`), **BPM capsule** (e.g. `124` + `BPM`; finger can drag or tap to type), **Time-signature badge** (`4/4`, fixed). | DECIDED (structure) / PROPOSED (exact set) |
| Center | **Loop toggle** (32×32), then **Play/Pause** (solid white, 32 px tall, black triangle, soft white glow), then **three mute circles** (Bass, Chord, Melody order, in layer colors). | DECIDED (play + mutes) / PROPOSED (loop placement from prototype) |
| Center | **Mute circle**: filled = layer sounding, empty = muted. A muted layer is silent and visually fades more. Independent from layer selection. | DECIDED |
| Right | **Layer pills**: three prominent pills that switch which piano roll is shown. Selected pill has a glowing layer-colored indicator dot. Pills are **not** mute. | DECIDED |
| Right | Pill order **Bass · Chord · Melody** (matches low→high pitch register, from the prototype). | PROPOSED |
| Right | **Drawer icon** (32×32, solid) opens/closes the right drawer (§13.6, §14.1). | PROPOSED |
| Behavior | Selecting a muted layer keeps it muted and shows a muted indicator. | OPEN (default: stay muted) |
| Behavior | Four-finger tap hides the whole bar. | PROPOSED |

Visual: dark-glass bar, no hard borders (§15). Icons solid, filled, rounded; no text labels where an icon is clear.

---

## 6. Layers

| Rule | Status |
|---|---|
| Three layers: **Chords**, **Melody**, **Bass**. Each has its **own full piano roll**, own mute state, own synth preset/settings. | DECIDED |
| Selecting a pill shows that layer's roll. The selected layer is bright and editable. | DECIDED |
| The other layers stay **visible but dimmed** (ghosts) in their own colors, so you can write against them. | DECIDED |
| Dimmed layers are not editable by the Pencil. | PROPOSED |
| Layer colors (§15): Chord `#849BB5` / `#978EB0`, Bass `#82A792`, Melody `#9E92B8`; AI accent `#ddb7ff`. The same color is used for the pill dot, mute circle, notes and ghosts. | DECIDED (palette) / PROPOSED (usage) |
| Each layer's synth settings are separate; the drawer's synth half follows the selected layer. | PROPOSED |

---

## 7. Chord layer

### 7.1 Chord identity & performance
| Rule | Status |
|---|---|
| A chord block has a **name/identity** (root, quality, optional slash bass), a start position and a length, and a **voicing** (its actual notes). | DECIDED |
| Chord blocks have **no individual strum/arp mode**. Performance style comes from the **pattern overlay** (§8). Plain chords play as block chords when no pattern applies. | DECIDED |
| Grid: 16 steps per 4/4 bar. Resizable in step units. | CARRIED |
| Voicing is generated at playback/creation by the voice-leading solver (§16) choosing the inversion closest to the previous chord, then editable by hand. | PROPOSED |

### 7.2 Chord strip (Chords mode only)
| Rule | Status |
|---|---|
| Blocks show chord **name** and **Roman numeral** by default (e.g. `Cm7` · `I`). | PROPOSED |
| Revealed on hover (or in a "detail" toggle state = the prototype look): function tag (`TON`, `SUB`, `DOM`), voicing tag (`Root`, `Drop 2`, `Spread`), constituent notes (e.g. `Eb · Ab · C · G`), alteration text (e.g. `#9 b13`). | PROPOSED (prototype content) |
| Empty bars show subtle dark-glass placeholders (greyed ghost of the same layout). | DECIDED (prototype) |
| Header label at the left of the strip: `CHORDS` with a small polyphony note (prototype shows `Poly 8`). | PROPOSED |
| Pencil tap on empty slot adds a chord; Pencil tap on a chord auditions it; Pencil drag on the right edge resizes; Pencil hold opens the hold menu (§12). | PROPOSED / CARRIED |
| Squeeze opens the two-ring radial menu (§7.4). | DECIDED |
| Ghost previews pushed from the AI sidekick appear on the strip in the AI accent color (§14.4). | DECIDED |

### 7.3 Chord piano roll & auto-naming
| Rule | Status |
|---|---|
| The chord roll shows the chord's notes in the Chords color; changing notes into a different chord **updates the chord's name/identity automatically** (bottom-up detection). | DECIDED |
| Detection accounts for the lowest/bass note (inversion), beat weight and pitch classes. | DECIDED (spec) |
| The rename is committed when the Pencil **lifts**, not continuously while dragging (prevents flicker and bass jumping through in-between chords). | PROPOSED |
| If no known chord matches, keep the previous name and show a neutral `?` marker. | PROPOSED |
| Every note renders dual inline labels: left = pitch name (`E6`), right = chord-tone function (`Root`, `m3`, `5`, `Maj7`, `9`, `#11`, …); updates live during edits and previews. Velocity (`v112`) is shown in the prototype. | DECIDED (labels) / PROPOSED (velocity hidden by default) |
| Show/hide toggle for note labels (default off for a calmer canvas; "on" = prototype look). | PROPOSED |
| **Roll the Pencil on a chord** to step through inversions/voicings and octave spreads, with audio preview and haptic detents. | DECIDED |
| Dragging a single note an octave keeps the chord name; changing a pitch class re-detects the chord (§7.3 first row). | PROPOSED |
| **Vertical slice sync:** a razor cut that slices *every* sounding note of a chord at the same tick (±15 ticks strum tolerance) splits the chord block on the strip at that tick into two independent harmonic regions. A partial slice (not all notes) leaves the parent block intact. | DECIDED (spec) |

### 7.4 Squeeze radial menu on a chord — two layered rings
| Rule | Status |
|---|---|
| **Outer ring = alter the existing chord** (extensions/qualities, e.g. maj7, min6, sus4). Slots 1–3 are **prediction-based** options; slot 4 is **"All"**. | DECIDED |
| **"All" opens separate rings per group**, e.g. a **major-family ring** and a **minor-family ring**. | DECIDED |
| A third ring holds the odd chords (sus2, sus4, dim, aug, power chord). | PROPOSED (owner agreed in principle) |
| The ring matching the current chord's quality opens nearest and brightest; the opposite family sits one ring out, dimmer. Picking from the opposite family flips the chord's third (borrowed-chord move). | PROPOSED |
| Max three rings visible at once; non-hovered rings dim. | PROPOSED |
| **Inner ring = tool-style choices** (Procreate-like): swap chord, duplicate, copy, delete. | DECIDED (concept) / PROPOSED (items) |
| "Change chord" and "add extension" are separate (inner vs outer). | DECIDED |
| Hovering an option auditions it; **lifting the Pencil on the option selects it**. | PROPOSED |
| Menu repositions away from screen edges so it never clips (the chord strip is near the top). | PROPOSED |
| **Empty slot squeeze:** same two rings; outer ring = 3 predicted **next chords** + "All"; inner ring = tools (paste, rest…). | PROPOSED |
| Prediction source: rule-based by key/function first; replaced by the Core ML ranker (§17) without changing the UI. | PROPOSED |

### 7.5 Prediction hooks (from the Core ML model)
- **Extension/substitution** (center-masked): fills the 3 outer-ring predictions on an existing chord.
- **Next chord** (end-masked): fills the 3 predictions on an empty slot / added bar.
- The prototype's "hover popover" is folded into the squeeze rings: hover only **highlights**; a tiny optional chip may show the top-1 prediction (PROPOSED).

---

## 8. Pattern overlay (strum / arpeggio)

| Rule | Status |
|---|---|
| A **pattern** (strum or arpeggio) defines how the chords **below it** are played. Chords themselves hold no strum/arp setting. | DECIDED |
| The pattern is **not a permanent lane**. It appears as an **overlay on top of the chord view only while tweaking**. | DECIDED |
| Overlay target: the **big chord piano roll** (the 2 cm strip is too short for velocity-length arrows). | OPEN (recommended: big roll) |
| How the overlay opens/closes: default is a "Pattern" entry in the chord-roll squeeze menu that toggles it, and a **Done** pill that closes it (`docs/DESIGN.md` §3.7). | OPEN |
| Grid: **8 eighth-note slots per bar**. Placement is quantized; **no freehand timing**. | DECIDED |
| **Stroke entry (one Pencil gesture):** touch-down in the **top half** → **downstroke**, arrow drawn from the top downward; touch-down in the **bottom half** → **upstroke**, arrow from the bottom upward. **Drag length = velocity.** | DECIDED |
| **Chuck (X):** draw a **circular motion**. Circle size sets chuck velocity. The circle must roughly close, so small drags are never read as chucks. | DECIDED (gesture) / PROPOSED (size, closure) |
| **Remove a stroke:** tap it again with the Pencil. | DECIDED |
| Dragging from an existing stroke edits its length/direction. | PROPOSED |
| Empty slot = no new stroke (previous sound rings on). | PROPOSED |
| Downstroke plays low→high; upstroke plays high→low; chuck is a short percussive dead-string rake synthesized by the engine (works on any preset). | CARRIED |
| **Swing knob exists** (delays off-beat eighths). Location: per pattern (recommended) vs one global control. | DECIDED (exists) / OPEN (location) |
| **Humanize** switch (Tight/Loose): small random timing and velocity variation; also nudges per-note detune/filter so repeated chords never sound identical. Swing (deterministic lilt) and humanize (random) stay separate controls. | DECIDED (humanize) / PROPOSED (extension) |
| Strum spread (stagger between strings, ~0–60 ms) and humanize ranges (~±3 ms timing, ~±6 velocity) are CARRIED from the blueprint. | CARRIED |
| Pattern scope: a pattern applies to a **range of bars** (default: the whole loop); starting a new pattern block changes feel from that point. | OPEN (default: whole loop) |
| Arpeggio definition on the same 8-slot grid (which chord tone each slot plays, up/down/up-down, rate). | OPEN |
| Preset patterns are expressed in the arrow format (e.g. "Pop Rock 8-beat": D · D U · U D U). | CARRIED |

---

## 9. Bass layer

| Rule | Status |
|---|---|
| **Full piano roll.** | DECIDED |
| Bass **originates from the chords' root notes** and **transposes with chord changes**. | DECIDED |
| A bass note that sits **on a chord tone** follows that tone's *function* when the chord changes (e.g. the third becomes the new third even if the quality changes). | DECIDED |
| A bass note **not on a chord tone** keeps its **fixed semitone offset** from the root. | DECIDED |
| After a chord switch the user can move notes freely, including making deliberate clashes. | DECIDED |
| Dragging a bass note re-evaluates its relationship (chord tone vs fixed offset) at its new pitch. | PROPOSED |
| Rhythm is preserved on chord changes. | CARRIED |
| Bass resolves into a low octave window so root changes (C→B) don't jump octaves. | PROPOSED |
| Per-note slide/glide is available (synth Glide). Slash-bass is supported through the chord identity. | CARRIED |
| In Chords mode the bass appears as ghost blocks labeled like `BASS: C2` (prototype). | PROPOSED |

---

## 10. Melody layer

| Rule | Status |
|---|---|
| **Full piano roll**, **100% manual**. No AI edits. | DECIDED / CARRIED |
| In-scale pitch rows lightly tinted; chord tones faintly tinted. | PROPOSED (prototype: in-scale rows `#151619`) |
| No scale snapping. Grid snap is a separate toggle (`1/16 SNAP` cell above the pitch gutter). | PROPOSED (prototype) |
| Roll the Pencil to nudge timing slightly off-grid. | CARRIED |
| In Chords mode melody notes appear as small dimmed ghost notes. | PROPOSED |

---

## 11. Shared piano roll tools — squeeze radial menu (all three rolls)

| Tool / button | Behavior | Status |
|---|---|---|
| **Draw / Erase** — one combined mode | Pencil on empty space draws a note. Pencil **tap on an existing note deletes it ("tap again to delete")**. Drag a note body to move it; drag its right edge to resize it. | DECIDED |
| **Razor** | Pencil drag across a note slices it at that position. Across all notes of a chord at one tick → splits the chord block (§7.3). | DECIDED |
| **Selection** | Pencil drag selects notes (default rectangle marquee). Selected notes highlight; drag to move. Selection is scoped to the active layer. | DECIDED (mode) / OPEN (rectangle vs lasso) |
| **Copy** | Copies the selection. **Dimmed/disabled when nothing is selected.** | DECIDED |
| **Paste** | Pastes the clipboard (default: at the playhead, left selected so it can be dragged). **Dimmed/disabled when nothing has been copied.** | DECIDED (button + dimming) / PROPOSED (placement) |
| Active tool indication | The current tool is highlighted in the ring; a small glyph fades in/out near the corner when the tool changes. | PROPOSED |
| Last-used tool persists. | PROPOSED |
| Pasting across layers | Allowed? Absolute pitch kept? | OPEN |

---

## 12. Press-and-hold option menus — PROPOSED (all items)

Mechanism: press and hold ~0.4 s without moving → compact popup list (iOS context-menu style) anchored to the object. **Pencil** for music objects; **finger** for UI elements. Destructive items are undoable.

| Object | Held with | Options |
|---|---|---|
| Chord block (strip) | Pencil | Copy · Duplicate · Delete · Split here |
| Note (any roll) | Pencil | Copy · Duplicate · Delete · Slide into note (toggle) |
| Selection | Pencil | Copy · Duplicate · Delete · Octave up · Octave down |
| Empty roll space | Pencil | Paste here (dim if clipboard empty) · Select bar |
| Pattern stroke | Pencil | Accent (max velocity) · Flip direction · Delete |
| Pattern overlay background | Pencil | Load preset pattern · Copy pattern · Paste pattern · Clear pattern |
| Ghost chord (AI/prediction) | Pencil | Audition · Accept · Accept all · Dismiss all |
| Mute circle | Finger | Solo this layer · Unmute all |
| Layer pill | Finger | Solo · Clear layer (undoable) |
| Play button | Finger | Play from loop start |
| Loop toggle | Finger | Set loop to selection · Clear loop |
| BPM capsule | Finger | Tap tempo · Halve · Double |
| Key/Scale capsule | Finger | Transpose +1 semitone · Transpose −1 semitone · Relative major/minor |
| Synth preset card | Finger | Reset to factory · Save tweaks as my version |
| Knob | Finger | Reset to preset default |

---

## 13. Sound engine & synth

### 13.1 Voice architecture
| Rule | Status |
|---|---|
| **One voice architecture; presets are parameter sets** (data, not separate engines). | PROPOSED |
| Voice: 2 oscillators (saw/square/triangle mix) with 2–3 detuned unison voices + quiet sub, low-pass filter with its own envelope, amp ADSR, detune, glide, slow analog-style pitch drift. | PROPOSED |
| Polyphony 8–12 voices, preallocated. | PROPOSED (prototype hint: `Poly 8`) |
| **Glide on chords:** each voice slides from the previous chord's note matched by sorted pitch order. | PROPOSED |
| Overlapping chord tails: the old chord fades under the next. | PROPOSED |
| The strum engine reuses the same synth and sample-accurate note scheduling (no separate audio path). `X` chuck is a synth feature (short envelope, filter snap, noise burst). | DECIDED (strum on top of synth) |

### 13.2 Presets (exactly three)
| Preset | Character | Glide default | Status |
|---|---|---|---|
| **Pluck** | Synth-style pluck: saw + touch of square, snappy filter-envelope, short decay, 2–5 ms attack (no click), light chorus. **Not** a guitar simulation. | off | DECIDED (concept) / PROPOSED (details) |
| **Currents pad** | Detuned saws, slow phaser, warm low-pass, slow attack, long release. | off | DECIDED (concept) / PROPOSED (details) |
| **Wobble lead** | Detuned triangle/square, tape wobble, glide on. | on | DECIDED (concept) / PROPOSED (details) |

Names are provisional. Slight customization only. No Karplus-Strong string model.

### 13.3 Controls
| Control | Notes | Status |
|---|---|---|
| **Wobble** macro | One knob scaling tape drift + chorus depth + phaser speed together. 0 = clean, max = warped. | DECIDED |
| **Warmth** macro | Closes the filter slightly and adds soft saturation. | DECIDED |
| Five knobs: **Cutoff, Resonance, Attack/Release (one "Shape" or two), Detune, Glide** | | PROPOSED |
| Humanize (§8) adds per-note random variation. | | DECIDED |

### 13.4 Knob interaction
Finger drags a knob; **Pencil barrel roll turns it** (with haptics, §3.4); hover shows the exact value; **squeeze on a knob opens a small radial menu** (Reset to default, …). | DECIDED (roll) / PROPOSED (rest)

### 13.5 FX chain & ear-fatigue rules
| Rule | Status |
|---|---|
| Small fixed FX chain: chorus, phaser, tape-style soft saturation, tempo-synced (dotted) delay, reverb. | PROPOSED |
| `AVAudioEngine` has no built-in chorus/phaser (as far as known) → implement them as small custom DSP in the real-time path (modulated delay; all-pass stages). | VERIFY |
| Master: gentle high cut/shelf around 8–10 kHz; soft dip in the 2–4 kHz harshness zone; **soft-clip, never hard-clip**; safety limiter; conservative default level with headroom. | DECIDED (goal) / PROPOSED (numbers) |
| Cap resonance range so filters can't whistle. | PROPOSED |
| Very slow LFOs (phaser, filter, pitch) so a long loop keeps "breathing" instead of sitting static. | PROPOSED |
| Static per-layer EQ carving (bass low-pass, chords band-limited) — do not market as "auto" unless sidechain ducking is added. Full design in §13.7. | CARRIED |

### 13.6 Right drawer (shared with the sidekick)
| Rule | Status |
|---|---|
| Opens from the **right edge** via pull-tab, finger swipe from the edge, or the top-bar drawer icon; closes by tapping the canvas or swiping back. | PROPOSED |
| Overlays roughly a quarter to a third of the width; does not reflow the roll. | PROPOSED |
| **Split:** top third to half = **AI sidekick**; below it = **synth** (preset cards, Wobble + Warmth macros, five knobs). Optional draggable divider. | DECIDED |
| **While the user is typing to the sidekick the synth half is not needed** — collapse/hide it (the on-screen keyboard also covers most of the drawer). | DECIDED |
| The synth half follows the selected layer; the sidekick is project-level. | PROPOSED |

### 13.7 Mixer & FX

**Signal path (PROPOSED):**
`layer synth voice → per-preset inserts (chorus, phaser, tape drift, soft saturation) → per-layer EQ → per-layer volume → sum → shared Delay + Reverb sends → master chain`

| Rule | Status |
|---|---|
| **Per-preset inserts** (chorus, phaser, tape drift/wobble, soft saturation) live inside each layer's voice chain and are driven by the preset and the **Wobble** / **Warmth** macros (§13.3). They are not separate user-facing effects. | PROPOSED |
| **Per-layer static EQ ("carving")** keeps layers out of each other's way. No knobs; fixed starting values, tunable in one named place: Bass = high-pass ~35 Hz, low-pass ~2.5 kHz · Chords = high-pass ~120 Hz, gentle high cut ~9 kHz · Melody = high-pass ~200 Hz, soft dip around 2–4 kHz. | CARRIED (idea) / PROPOSED (values) |
| Do not call the EQ "auto". Optional later: light sidechain duck of the chords under bass hits (off by default, not in M1). | CARRIED / PROPOSED |
| **Per-layer volume**: one fader per layer, default level leaves at least 6 dB of master headroom. | PROPOSED |
| **Delay and Reverb are shared**: **one** Delay amount and **one** Reverb amount for the whole project, not per layer. Per-layer sends are deliberately out of scope for now. | DECIDED |
| **Delay:** tempo-synced, dotted-eighth by default, moderate feedback (~30%), repeats low-passed (~3 kHz) so echoes stay soft and never pile up harshly. | PROPOSED |
| **Reverb:** one soft, long-tailed plate/hall-style reverb, ~20 ms pre-delay, damped highs so the tail never turns bright or hissy. | PROPOSED |
| Defaults are subtle so a 2+ hour loop stays easy on the ears. | DECIDED (goal) / PROPOSED (values) |
| A muted layer is silent including its effect tails (short fade, no click). | PROPOSED |
| **Master chain** (unchanged from §13.5): gentle high cut/shelf ~8–10 kHz, soft dip 2–4 kHz, soft-clip saturation, safety limiter. | PROPOSED |
| All of the above runs in the real-time audio path under the audio-thread rules (`AGENTS.md`). Parameter changes are smoothed. | DECIDED |
| **UI:** a collapsed **FX & Mix** row at the bottom of the drawer's synth area (`docs/DESIGN.md` §3.10): shared Delay and Reverb knobs plus three layer volume faders. Collapsed by default. Pencil barrel roll turns these knobs like any other (§3.4). | PROPOSED |
| **Milestones:** shared delay + reverb, EQ and volume for the Chords layer arrive in M1; Bass and Melody EQ/volume arrive with those layers in M3. | PROPOSED |

---

## 14. AI sidekick (co-producer)

### 14.1 UI
| Rule | Status |
|---|---|
| Lives in the **right drawer, top third to half** (§13.6). Opened by the drawer icon/pull-tab. Not a separate floating window. | DECIDED |
| Visible conversation text streams in the drawer. | DECIDED |
| Concrete suggestions appear as **ghost previews** on the chord strip, not as text. | DECIDED |
| Theory questions get short text answers. | PROPOSED |
| Named persona **coda**, sharing the app's name, with its own visible, recognizable personality in `PersonaPrompt.swift`; streams concise theory insights and clarifying creative questions. She is chill, open-minded and candid, not an automatic cheerleader. | DECIDED |
| coda can critique the user's existing chords and progressions, not just propose new ones. She must be willing to say when something genuinely does not work, rather than praise it automatically. Criticism should explain the musical issue in context; unconventional harmony is not inherently bad. Critique does not change deterministic chord identification or authorize edits. | DECIDED |
| Input method: typing, Apple **Scribble** handwriting, and/or tappable quick prompts ("moodier", "more tension"). | OPEN (recommend: all three; chips minimize typing) |
| The sidekick **never touches melody**. | CARRIED / PROPOSED |

### 14.2 Closed-loop pipeline
`User text → Qwen co-producer → (visible text) + <directive> JSON → ChordPredictor (Core ML, steered logits) → VoiceLeadingSolver → Ghost Previews on the strip`
- The LLM **never emits raw MIDI numbers**; it only steers (CARRIED).
- The music model is used **only for predictions or via the sidekick — never direct generation** (DECIDED).
- Identifying existing chords is deterministic (`ChordDetector.swift`, §16), not a task for Qwen or the trained predictor. The trained model predicts harmonic possibilities; Qwen provides the conversational persona and steers predictions. (DECIDED; owner-confirmed.)

### 14.3 LLM
| Item | Value | Status |
|---|---|---|
| Model | `mlx-community/Qwen2.5-3B-Instruct-4bit` via `mlx-swift-lm` | DECIDED (spec) |
| Delivery | ~1.8 GB, downloaded once on first launch into Application Support | DECIDED (spec) |
| Memory | ~2.3–2.8 GB active RAM ceiling to stay under per-process limits | DECIDED (spec) / VERIFY |
| Alternative | Apple on-device Foundation Models (iPadOS 26) with guided JSON output — no download. Evaluate before committing. | PROPOSED / VERIFY |

### 14.4 `<directive>` channel
- The model streams conversational text and, when proposing concrete changes, appends `<directive>{…}</directive>`.
- Fields: `target_bars`, `section_hint`, `genre_hint`, `harmonic_bias` (`tension_level`, `preferred_qualities`), `seed_chords`.
- Example shape (agent may refine types): `{"target_bars":[3,4],"section_hint":"chorus","genre_hint":"soul","harmonic_bias":{"tension_level":0.6,"preferred_qualities":["maj7","m9"]},"seed_chords":["Fm9","G7alt"]}`
- Swift **strips `<directive>…</directive>` from the visible bubble in real time**, including across token boundaries (buffer partial tags like `<direct`).
- Malformed/missing JSON → show text only, no ghosts. Never show wrong ghosts.
- Ghost previews carry `[Pitch  ChordTone]` labels, use the AI accent color `#ddb7ff`, are auditionable, and **never overwrite user edits**. Pencil tap accepts (one undo step); hold → Dismiss/Accept all; any user edit in that region dismisses or rebases the ghost.

---

## 15. Visual design tokens (from the prototype; preserved exactly)

> Prototype px are CSS px of a preview; §4 cm targets are the real-world intent. A DECIDED rule in this spec overrides a token only where stated in §21. The complete visual/layout design for every screen and state is in `docs/DESIGN.md`, which overrides the prototype.

### 15.1 Colors and surfaces
| Token | Value |
|---|---|
| `oled` (primary canvas) | `#000000` |
| `dark-glass` (top bar, floating drawers) | `rgba(22, 22, 24, 0.90)` (`#161618`), borderless frosted dark glass — **no hard borders or strokes** |
| `coal-gutter` (piano roll left pitch gutter) | `#18191d`, **56 px** wide; muted pitch labels at 15%–30% white opacity; brighter octave-root anchors with indicator dots (`C5`, `C4`, `C3`); hairline dividers `rgba(255,255,255,0.02)` |
| `coal-scale` (in-scale pitch rows) | `#151619`, against `#000000` out-of-scale rows; subtle beat and measure grid lines across measures 1–8 |
| Primary ink | `#e2e2ec` / `#e1e2eb` |
| Muted labels/tags | `#828695` / `#727685` |
| Chord (slate-mist / pewter-lilac) | `#849BB5` / `#978EB0` |
| Bass (bass-sage) | `#82A792` |
| Melody (melody-lavender) | `#9E92B8` |
| AI co-producer accent | `#ddb7ff` |
| Rule | Desaturated pastels. **Strictly no yellow.** (The prototype's amber octave labels violate this — use the muted/white-ink styling above.) |

### 15.2 Typography, icons, radii
| Token | Value |
|---|---|
| Font | Plus Jakarta Sans (weights 300, 400, 500, 600, 700, 800) bundled via Info.plist `UIAppFonts`; used everywhere |
| Icons | Solid, fully filled, rounded Procreate-style vector icons; omit text labels where an icon communicates the action |
| Radii | 4 px inner pills · 6 px buttons/capsules/notes · 8 px chord blocks and floating drawers |

### 15.3 Layout tokens
| Element | Value |
|---|---|
| Top bar | 48 px tall (≈ 1 cm target) |
| Gear / loop / AI-drawer buttons | 32 × 32 px |
| Play button | 32 px tall, solid `#ffffff`, `#000000` triangle, soft glow `rgba(255,255,255,0.18)` |
| Key/Scale capsule | e.g. `C Min` + `NAT` |
| BPM capsule | e.g. `124` + `BPM` |
| Time-signature badge | `4/4` |
| Vertical divider | between gear and the capsules |
| Layer switcher | segmented control; active segment has a glowing layer-colored indicator dot (Chord = `#849BB5`) |
| Chord strip | ~88 px (≈ 2 cm target), measures 1–8, directly under the timeline strip |
| Measure ruler / timeline | ~24 px; includes a **1/16 SNAP** toggle cell aligned above the 56 px pitch gutter, ruler `1 | 2 3 4 … 8`, and a glowing playhead marker |
| Note blocks | 4–6 px radius, **1.5 px micro-inset** so stacked chord voicings stay visually distinct |
| Note labels | Plus Jakarta Sans; left = pitch name, right = chord-tone function; live-updating |
| Chord block content (prototype) | name (`Cm7`, `Abmaj7`, `Fm9`, `G7alt`), Roman numeral, function tag (`I · TON`, `VI · SUB`, `IV · SUB`, `V7 · DOM`), voicing tag (`Root`, `Drop 2`, `Spread`), constituent notes |
| No persistent sidebars, no bottom tab bar | the canvas stays chrome-free |

---

## 16. Music-engine modules (deterministic Swift, zero ML)

Names are from the owner's spec (suggested file names).

| Module | Responsibility | Status |
|---|---|---|
| `ChordDetector.swift` | Bottom-up detection from active pitch classes (bass note/inversion, beat weight). Updates the chord on Pencil lift (§7.3). Must map to the supported chord vocabulary (`vocab.json`); unknown shapes → `?`. | DECIDED |
| `TimelineSliceReducer.swift` | Vertical slice sync: a cut through every sounding note of a chord at one tick (±15 ticks) splits the chord block; partial slices keep the parent. | DECIDED |
| `ChordToneAnalyzer.swift` | Computes `[Pitch  ChordTone]` labels for every note relative to its active chord slice, live. | DECIDED |
| `VoiceLeadingSolver.swift` | Viterbi solver for smoothest voice-leading MIDI notes (close, drop-2, open, register constraints). Runs in microseconds on hover/preview. | DECIDED |
| Compile step | UI state → flat timed note-event list (sample offsets); the audio thread reads only that list. | PROPOSED |
| Bass follower | Applies the §9 follow rules on chord changes. | DECIDED |
| Pattern/strum scheduler | Expands patterns (§8) into timed events with swing, spread, humanize. | PROPOSED |

---

## 17. Core ML chord predictor — training & integration

| Rule | Status |
|---|---|
| **Training your own small model is approved.** | DECIDED |
| Artifact: `ChordPredictor.mlpackage` (~5 MB) + `vocab.json`. | DECIDED |
| Script: `scripts/train_chord_predictor.py`; includes `--smoke-test` (~30 s) for a fast first `.mlpackage`. | DECIDED |
| Architecture: compact 4-layer **bidirectional Transformer encoder (~1.5 M params)** in PyTorch; exported with `coremltools`. | DECIDED |
| Data: Hugging Face `ailsntua/Chordonomicon`. Masking: 50% center-masking, 50% end-masking. | DECIDED |
| Conditioning: section tokens (`<verse>`, `<chorus>`, `<bridge>`, `<intro>`, `<outro>`) and `main_genre` tokens (soul, jazz, pop, electronic, rock, …). | DECIDED |
| Oversample progressions with 7th/9th/11th/13th/altered extensions to avoid triad bias. | DECIDED |
| Roles: **hover/extension** = center-masked (`[Chord_1, Chord_2, <MASK_ext:root>, Chord_4]`); **add bar/slice** = end-masked (`[Chord_1, Chord_2, Chord_3, <MASK>]`). | DECIDED |
| **Steerable logits:** accepts an external logit-bias vector (quality/extension boost + genre/section override) set by the LLM directive. | DECIDED |
| Ranks suggestions on demand; never overwrites user edits. Output is a **ranked list with scores** (powers the 3 outer-ring slots and ghosts). | DECIDED |
| Baseline for comparison: a simple key/function transition table; the learned model must beat it. | PROPOSED |
| Inference runs off the audio thread. | DECIDED |

---

## 18. Milestones (execute in order; each ends with a working, installable `.ipa`)

| # | Milestone | Exit criteria |
|---|---|---|
| M0 | Scaffolding: XcodeGen `project.yml`, GitHub Actions unsigned `.ipa`, Plus Jakarta Sans via `UIAppFonts`, landscape lock, OLED theme tokens (§15). | App launches on the iPad with the black canvas and font. |
| M1 | **Synth + chord track.** Voice engine, 3 presets, Wobble/Warmth + five knobs, FX chain, shared delay + reverb and per-layer EQ/volume (§13.7), ear-safety master, glide. Top bar (settings, key/scale, BPM, loop, play), thin timeline, chord strip, add/resize/delete chords by Pencil, tap-to-audition, plain block-chord playback, rule-based two-ring radial menu, undo/redo gestures, right drawer (synth half only). | Build a 4-bar progression and hear a convincing loop that stays pleasant for long listening. |
| M1b | **Strum engine on top of the synth:** pattern overlay (8 eighth slots, arrow strokes, chuck, tap-to-remove), swing, humanize, spread. | A pattern changes how the same chords play. |
| M2 | Chord roll: voicings, roll-to-step with haptics, chord-tone labels, auto-naming on lift, vertical slice sync, razor/select/copy/paste/draw-erase radial menu, hold menus. | Reshaping notes renames the chord; slicing splits chord blocks. |
| M3 | Bass + melody layers: pills, mute circles, ghosts, full rolls, bass follow rules, timeline chord names. | Bass moves with chords per §9; layers mute/select independently. |
| M4 | Train and integrate `ChordPredictor` (§17): prediction-driven outer ring, voice-leading previews, ghost previews. | Outer-ring suggestions come from the model; transition-table baseline beaten. |
| M5 | Sidekick: drawer split, Qwen download + streaming, `<directive>` parser, steered ghosts, accept/dismiss. Typing hides the synth half. | A chat request produces auditionable ghosts. |
| M6 | QoL and carried features (§19), persistence, export. | Projects save/load; MIDI export works. |

---

## 19. Carried-over features (no original blueprint exists; use the requirements stated here)

A/B snapshot compare · global transpose (now also in the Key/Scale hold menu) · `+ Bar` duplicate · `.json` project saves · MIDI export · FL-style scale highlighting · humanize ranges and strum spread values · "Pop Rock 8-beat" style preset patterns · per-note slide/glide · slash-bass · static per-layer EQ carving.

---

## 20. Edge cases & gaps audit

| # | Issue | Handling |
|---|---|---|
| 1 | Chord detection ambiguity (inversions, partial voicings, rare shapes like `G7alt`) | Use bass note + beat weight; map to `vocab.json`; unknown → keep name + `?`. |
| 2 | Auto-rename flicker | Commit on Pencil lift (§7.3). |
| 3 | Bass follow when a chord's root changes mid-pattern | Apply §9 rules per chord span; rhythm untouched. |
| 4 | Memory on a sideloaded app: LLM 2.3–2.8 GB + audio + Core ML | Check available memory at runtime; unload the LLM when idle; app must fully work without the LLM. VERIFY the real per-app limit on the device. |
| 5 | First-launch model download fails/offline | Sidekick shows a quiet unavailable state; everything else works. |
| 6 | Partial `<directive>` across streamed tokens | Buffer and strip in real time; validate JSON; ignore if invalid. |
| 7 | Ghost vs user edit conflict | Ghosts never overwrite; edits dismiss/rebase ghosts; accepting is one undo step. |
| 8 | Finger-only usage | Intentionally cannot edit music (owner decision). |
| 9 | Pencil double-tap | Leave unbound until decided (§22). |
| 10 | Layer selected while muted | Default: stays muted with an indicator. |
| 11 | Audio thread safety | No allocation/locks/ARC-heavy closures on the render path; preallocated voices; lock-free event handoff; sample-accurate scheduling; smoothed parameters; denormal protection. |
| 12 | Haptics API availability/behavior | VERIFY; visual fallback (§3.4). |
| 13 | Time signature | Fixed 4/4; 8 eighth slots per bar; 16 steps per bar. |
| 14 | SideStore cert expiry (re-sign cycle) | Keep project saves exportable/backed up. |
| 15 | CI toolchain | VERIFY `macos-latest` has the needed Xcode/SDK; pin if not. |
| 16 | Prototype vs spec conflicts | §21 resolves them; this spec wins. |
| 17 | Hold menu vs drag ambiguity | Hold requires no movement for ~0.4 s. |
| 18 | Chuck vs short drag | Circle must roughly close (§8). |
| 19 | Overlay target (strip vs roll) | OPEN; recommend the big roll for arrow room. |
| 20 | RAM figure (12 GB stated, 16 GB on some tiers) | Confirm on device. |

---

## 21. Changes vs the original blueprint and vs the prototype

### 21.1 Versus the original blueprint
| Original | Now |
|---|---|
| Per-chord strum mode | Pattern overlay over chords (§8) |
| Finger tap to audition/add chords | Pencil only; fingers navigate |
| Fixed Pencil gesture table (~30 mappings) | Squeeze = context radial; roll = knobs/states; double-tap OPEN |
| Pressure/tilt ideas | Removed |
| 6–8 presets per layer, preset files | 3 presets total, slight customization |
| Simplified bass roll | Full piano roll with chord-following rules |
| Undo via single two-finger tap | Two-finger **double** tap undo, three-finger double tap redo |
| Trained symbolic MIDI model idea | Small chord predictor you train yourself (§17) + steered by LLM |
| Original sidekick LLM sketch | Qwen2.5-3B 4-bit via `mlx-swift-lm`, directive channel (§14) |
| Bidirectional chord/notes sync | Kept **only in the chord roll** (auto-naming); bass is a follower |

### 21.2 Versus the Stitch prototype
| Prototype | Final |
|---|---|
| Single gear button | App Settings + Project Settings ⋯ side by side |
| No mute circles | Mute circles beside Play |
| AI icon opens a separate floating chat | Drawer icon opens the shared right drawer (sidekick top, synth below) |
| Ruler *below* chord strip | Thin timeline strip *above* the chord strip |
| Dense chord blocks / note labels always on | Name + numeral by default; extras on hover or label toggle |
| Hover popover for extensions | Squeeze two-ring radial menu; hover only highlights |
| No pattern/strum UI, no swing, no synth drawer | Added (§8, §13) |
| Amber octave labels | Removed (no-yellow rule) |
| Layer switcher order Bass · Chord · Melody | Kept (PROPOSED) |

---

## 22. Open questions (owner input needed)

1. Pencil barrel **double-tap** action (previous tool? play/stop?).
2. **Swing**: per pattern or global?
3. **Pattern scope**: whole loop vs per bar range; how **arpeggios** are defined on the 8-slot grid.
4. **Pattern overlay target**: big chord roll (recommended) vs the 2 cm strip.
5. **Sidekick input**: typing, Scribble, quick-prompt chips, or all.
6. **Selecting a muted layer**: stay silent (default) or auto-unmute.
7. **Selection style**: rectangle (default) vs lasso; clipboard rules across layers.
8. Sidekick/co-producer name resolved: **coda**, also the app name. Personality: she is chill, open-minded and candid, including honest critique of existing chords (DECIDED; §14.1).
9. Pill order (Bass · Chord · Melody vs Chords · Melody · Bass) and loop button placement.
10. Whether to evaluate Apple's Foundation Models as the LLM alternative (§14.3).
11. How the pattern overlay opens and closes (default in §8).

---

## 23. Glossary

| Term | Meaning |
|---|---|
| Layer | Chords, Melody or Bass; each has its own piano roll, mute, synth settings. |
| Layer pill | Right-side top-bar button that switches the visible piano roll. |
| Mute circle | Center top-bar circle per layer (filled = sounding, empty = muted). |
| Timeline strip | Thin strip above the chord strip: bars, playhead, loop braces, faint chord names. |
| Chord strip | ~2 cm strip of chord blocks; Chords mode only. |
| Chord roll / chord piano roll | The big piano roll in Chords mode. |
| Pattern overlay | Temporary editor over the chord view that defines a strum/arp pattern. |
| Stroke | One arrow (down/up) or circle (chuck) in a pattern slot. |
| Ghost | Dimmed other-layer notes, or AI/prediction suggestions awaiting acceptance (AI accent color). |
| Radial menu | Squeeze-opened context menu at the Pencil tip. |
| Hold menu | Press-and-hold command list on one object. |
| Drawer | Right-edge panel: sidekick (top) + synth (below). |
| Directive | `<directive>…</directive>` JSON the LLM appends to steer the chord predictor. |

---

## 24. Agent orchestration rules (from the owner's spec)

- **Hermes (tech lead):** maintains `ROADMAP.md` with `[ ]` / `[x]` milestones (§18), writes scoped briefs to `.codex_task.md`, **never writes app code directly and never one-shots the codebase**.
- **Codex CLI (builder):** invoked externally with `pty: true`. Every invocation MUST explicitly include `-c model_provider="xingchi"` and `-m gpt-6.1-sol`. Hermes may adapt other flags to the installed CLI and use scoped micro-prompts, correction runs, or subagents within the current milestone. Follow with actual `git diff` review and GitHub Actions `.ipa` verification (`gh run watch`). Minimize routine permission interruptions without bypassing host-enforced controls. Never advance to the next milestone without the owner's explicit `approved` reply.
- Each brief MUST: cite spec section IDs, list DECIDED rules as constraints, list the PROPOSED defaults being used, list OPEN items being defaulted, and state the milestone's exit criteria.
- After every milestone: update `ROADMAP.md`, record any PROPOSED/OPEN defaults chosen, and verify the unsigned `.ipa` builds before starting the next milestone.
