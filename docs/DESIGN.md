# DESIGN.md — UI Design File

The complete target UI: layout, components, visual states, motion. It replaces the Stitch prototype, which is outdated and kept only as a loose mood reference.

## 0. Purpose & precedence

- **Behavior and rules** (gestures, data, audio, ML) live in `SPEC.md` and win over this file.
- **Layout, visuals and component look** live here and win over `docs/prototype/`.
- Units are SwiftUI points (pt). Heights marked with cm are real-world targets for the 13" iPad Pro (1 cm ≈ 52 pt). Prototype px values map 1:1 to pt for radii, type and small controls.
- Status tags match `SPEC.md`: **DECIDED** (owner said it), **PROPOSED** (default, tunable), **OPEN** (default given).
- Put every size, opacity, duration and radius below in one named design-tokens file so the owner can tune by feel.

---

## 1. Global look

| Rule | Value | Status |
|---|---|---|
| Orientation | Landscape only | DECIDED |
| Canvas | True OLED black `#000000`, edge to edge | DECIDED |
| Chrome surfaces (top bar, drawer, popups, radial slots) | `rgba(22,22,24,0.90)` dark frosted glass, **no borders or strokes** | DECIDED |
| Primary ink | `#e2e2ec` · muted ink `#828695` / `#727685` | DECIDED |
| Layer colors | Chord `#849BB5` (alt `#978EB0`) · Bass `#82A792` · Melody `#9E92B8` · AI accent `#ddb7ff` | DECIDED |
| Danger (delete items only) | desaturated rose `#C98A8A` | PROPOSED |
| Forbidden | Yellow/amber anywhere, pure white fills except the Play button | DECIDED |
| Font | Plus Jakarta Sans 300–800, bundled (`UIAppFonts`) | DECIDED |
| Type scale | 10 pt notes/labels · 12 pt chips/readouts · 13 pt chord names · 15 pt menu items · 600 weight default for labels, 700 for chord names | PROPOSED |
| Radii | 4 inner pills · 6 buttons/capsules/notes · 8 chord blocks, drawers, popups | DECIDED |
| Icons | Solid, filled, rounded, Procreate-style; no text labels where an icon is clear (layer pills keep short text) | DECIDED |
| Persistent sidebars / bottom tabs | None | DECIDED |
| Philosophy | Everything hidden by default; the canvas is the app; the UI is usable without any visible control by Pencil alone | DECIDED |

### Layer visibility rules (apply everywhere)
| State | Look | Status |
|---|---|---|
| Selected layer | Notes at ~88% opacity in layer color; editable | DECIDED / PROPOSED (value) |
| Other layer (dimmed ghost) | ~30% opacity, no labels, no outline; not editable | DECIDED / PROPOSED (value) |
| Muted layer | Mute circle empty; its notes fade further (~15% as ghost; ~45% if selected) | DECIDED / PROPOSED (value) |
| AI ghost (suggestion) | `#ddb7ff` at ~55% fill with a 1 pt dashed hairline in `#ddb7ff` at 60% | PROPOSED |

---

## 2. Screen anatomy

### 2.1 Chords mode (default)

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│ ⚙  ⋯ │ C Min·NAT │ 124 BPM │ 4/4        ⟲   ▶   ◉ ◉ ◉          [Bass][Chord][Melody] ✦ │  52 pt top bar
├───┬──────────────────────────────────────────────────────────────────────────────────┤
│SNP│ 1          2          3          4          5      6      7      8   ◆ playhead   │  ~20 pt timeline
├───┼──────────────────────────────────────────────────────────────────────────────────┤
│CHD│ [Cm7  I ][Abmaj7 VI][Fm9  IV][G7alt V7 ][ · ][ · ][ · ][ · ]                      │  104 pt chord strip
├───┼──────────────────────────────────────────────────────────────────────────────────┤
│C5 │ ░ ghost bass (sage 30%) ░   ▓▓ chord notes (slate 88%) ▓▓   ░ ghost melody (lav) ░│
│B4 │                                                                                  │
│…  │                       full-height piano roll                                      │
│C4•│                                                                                  │
│…  │                                                                                  │
│C3•│                                                                                  │
└───┴──────────────────────────────────────────────────────────────────────────────────┘
 56 pt pitch gutter (left)
```
- `◉` = mute circles (filled = sounding). `SNP` = the 1/16 SNAP cell. `CHD` = strip header label.
- The chord strip exists **only** in Chords mode.

### 2.2 Melody and Bass modes
Same as 2.1 with the chord strip **removed**; the piano roll grows upward. The timeline strip stays and shows **faint chord names** (chord color at ~45%, 11 pt) at the position each chord starts. The selected layer's notes are bright; the other two layers and the chords appear as ghosts.

### 2.3 Right drawer open (Chords mode)
```
┌────────────────────────────────────────────────────────┬────────────────┐
│ top bar …                                              │                │
├────────────────────────────────────────────────────────┤  AI sidekick   │
│ timeline                                               │  (messages,    │
├────────────────────────────────────────────────────────┤   input, chips)│
│ chord strip (ghost chords stay visible here)           ├────────────────┤
├────────────────────────────────────────────────────────┤  ── divider ── │
│ piano roll (not reflowed; drawer overlays it)          │  Synth: preset │
│                                                        │  cards, Wobble │
│                                                        │  Warmth, knobs │
└────────────────────────────────────────────────────────┴────────────────┘
```
The drawer's top edge starts **below the last visible strip** so the timeline and chord strip stay uncovered.

### 2.4 Drawer while typing
Synth half collapses to a slim 28 pt bar showing the preset name; the sidekick fills the drawer above the on-screen keyboard.

### 2.5 UI-hidden mode (four-finger tap)
Everything hides except the piano roll canvas, the playhead and the dimmed layers. Another four-finger tap restores the UI. (PROPOSED)

---

## 3. Components

### 3.1 Top bar (52 pt tall, dark glass, no border)
| Element | Spec | Status |
|---|---|---|
| Padding | 10 pt left/right; controls 32 pt tall, vertically centered; 8 pt gaps | PROPOSED |
| App Settings | 32×32 solid gear, opens a compact popup with tabs | DECIDED |
| Project Settings ⋯ | 32×32 solid ellipsis next to it, popup for misc project settings | DECIDED |
| Vertical divider | 1 pt, white 8% opacity, 20 pt tall, between the two menu buttons and the capsules | PROPOSED |
| Key/Scale capsule | 32 pt tall, radius 6, glass slightly lighter (white 6% overlay); text `C Min` + small `NAT` tag; tap opens picker | DECIDED / PROPOSED |
| BPM capsule | Same style; `124` + small `BPM`; finger drag to change, tap to type | DECIDED / PROPOSED |
| Time-signature badge | `4/4`, non-interactive, radius 4 | DECIDED |
| Center cluster | Loop toggle (32×32) → Play (56×32 capsule, radius 6, solid `#ffffff`, black triangle, white glow `rgba(255,255,255,0.18)`, ~12 pt blur) → three mute circles | DECIDED / PROPOSED |
| Loop toggle | Off: muted ink icon; On: Chord color icon with soft glow | PROPOSED |
| Right cluster | Layer pills, 12 pt gap, then drawer icon (32×32, sparkle/panel glyph) | DECIDED / PROPOSED |

### 3.2 Layer pills (segmented control, right side)
| Rule | Value | Status |
|---|---|---|
| Order | Bass · Chord · Melody | PROPOSED |
| Container | 32 pt tall, radius 6, glass | DECIDED |
| Segment | Icon + short label (`Bass`, `Chord`, `Melody`), 12 pt 600 | PROPOSED |
| Selected segment | Raised: white 8% overlay, radius 4; **6 pt glowing dot** in the layer color before the label (glow ≈ 8 pt blur at 60%) | DECIDED (dot) / PROPOSED (rest) |
| Unselected | Muted ink, no dot | DECIDED |
| Meaning | Switches which piano roll is shown. **Never** mutes. | DECIDED |

### 3.3 Mute circles (center)
| Rule | Value | Status |
|---|---|---|
| Three circles in the same order as the pills (Bass, Chord, Melody) | | DECIDED |
| Size | 14 pt visible circle inside a 32 pt hit area; 8 pt spacing | PROPOSED |
| Sounding | Solid fill in the layer color | DECIDED |
| Muted | Empty ring (1.5 pt stroke, layer color at 50%) | DECIDED |
| Selected layer | Its circle gets a subtle 2 pt outer glow so you can tell which layer is selected | PROPOSED |
| Toggle | Finger tap | DECIDED |

### 3.4 Timeline strip (~20 pt)
| Element | Spec | Status |
|---|---|---|
| Background | Dark glass, hairline bottom divider `rgba(255,255,255,0.02)` | DECIDED |
| SNAP cell | Left, aligned over the 56 pt gutter: text `1/16` + tiny `SNAP`, tap toggles | PROPOSED (prototype) |
| Bar numbers | `1 | 2 3 4 …` style, 10 pt, muted ink | DECIDED (prototype) |
| Playhead | Glowing marker (◆) on the strip + a 1 pt vertical line through the roll | DECIDED |
| Loop braces | Draggable bracket handles at loop start/end with a faint tinted span between them | PROPOSED |
| Faint chord names | In Melody/Bass mode only: chord name text at each chord start, ~45% opacity, tinted Chord color | DECIDED |

### 3.5 Chord strip (104 pt, Chords mode only)
Header cell (56 pt, aligned with the gutter): `CHORDS` 10 pt muted + tiny `Poly 8`.

| State | Look | Status |
|---|---|---|
| **Default block** | Radius 8, glass slightly lighter than the strip. **Chord name** (13 pt, 700, primary ink) top-left; **Roman numeral** (10 pt, muted) top-right. Width = chord length. | PROPOSED |
| **Detail (on hover, or detail toggle)** | Adds, in rows below: function tag (`TON`, `SUB`, `DOM`), voicing tag (`Root`, `Drop 2`, `Spread`), constituent notes (`Eb · Ab · C · G`), alteration text (`#9 b13`) | PROPOSED (prototype content) |
| **Selected block** | 1.5 pt inset glow in Chord color | PROPOSED |
| **Playing block** | Chord-color tint at 12% | PROPOSED |
| **Empty bar** | Dark-glass placeholder at 40% opacity with a greyed ghost of the same layout (`·`) | DECIDED (prototype) |
| **AI/prediction ghost chord** | AI-ghost style (§1), same block layout | DECIDED |
| **Resize handle** | 6 pt grabber on the right edge, appears on hover | PROPOSED |

### 3.6 Piano roll
| Element | Spec | Status |
|---|---|---|
| Gutter | 56 pt, `#18191d`; pitch labels white at 15–30% opacity, 10 pt; octave-root anchors (`C5`, `C4`, `C3`) brighter with an indicator dot; hairline dividers `rgba(255,255,255,0.02)` | DECIDED |
| Rows | Default 22 pt per semitone (zoomable 14–36 pt). In-scale rows `#151619`, out-of-scale rows `#000000`. | DECIDED / PROPOSED (height) |
| Grid | Subtle beat lines and stronger measure lines across measures 1–8 | DECIDED |
| Notes | Radius 6, **1.5 pt micro-inset** between stacked notes. Fill = layer color. Chord roots slightly brighter than other chord tones. | DECIDED / PROPOSED |
| Labels (toggle, off by default) | Left: pitch (`E6`). Right: function (`Root`, `m3`, `5`, `Maj7`, `9`, `#11`). 10 pt 600. Velocity `v112` 9 pt muted, only when labels are on. Live-updating. | DECIDED / PROPOSED |
| Other layers | Ghost style (§1). Bass ghost blocks may show `BASS: C2` text in Chords mode. | PROPOSED |
| Selection | Selected notes get a 1.5 pt white-12% inset ring and brighter fill; marquee = white 6% fill, 1 pt white 20% outline | PROPOSED |
| Razor | While dragging, a 1 pt vertical cut line in primary ink at 70% | PROPOSED |
| Playhead line | 1 pt, white 35% | PROPOSED |
| Tool glyph | Current tool glyph fades in at the roll's top-left for ~800 ms when the tool changes | PROPOSED |

### 3.7 Pattern overlay (Chords mode, while tweaking)
| Element | Spec | Status |
|---|---|---|
| Veil | `rgba(0,0,0,0.55)` over the chord roll; notes dim to ~25% | PROPOSED |
| Grid | **8 slot columns per bar**, hairline `rgba(255,255,255,0.06)`; slot under the Pencil gets a Chord-color 12% tint | DECIDED (8 slots) / PROPOSED (look) |
| Downstroke | Arrow starting at the **top** edge, pointing down. Touch-down in the top half. | DECIDED |
| Upstroke | Arrow starting at the **bottom** edge, pointing up. Touch-down in the bottom half. | DECIDED |
| Arrow style | 3 pt stroke, rounded caps, small solid head, Chord color. **Length = velocity** (max ≈ 90% of roll height). | DECIDED (length) / PROPOSED (style) |
| Chuck | Drawn by a circular motion; rendered as a ring with an × inside, ring diameter scales with velocity | DECIDED (gesture) / PROPOSED (style) |
| Live readout | A small capsule near the Pencil shows velocity (`v96`) while drawing | PROPOSED |
| Remove | Tap a stroke again | DECIDED |
| Controls | Slim dark-glass capsule pinned top-right inside the overlay: **Swing** knob (28 pt), **Tight/Loose** switch, **Done** pill | DECIDED (controls exist) / OPEN (placement of swing) |
| Open/close | Default: a "Pattern" entry in the chord-roll squeeze menu toggles the overlay; the **Done** pill closes it | OPEN |

### 3.8 Radial menus (squeeze, opens centered on the Pencil tip)
General: a small 8 pt center dot marks the tip. Each ring is a band of glass slots with 1.5 pt gaps. Slot labels 12 pt 600; icons where clearer. The slot under the Pencil brightens (white 10% overlay) and its label turns primary ink. Selecting happens when the Pencil **lifts on a slot**. Non-hovered rings fade to ~45%. The menu shifts away from screen edges so it never clips. Appear: 100 ms, scale 0.92→1.

| Menu | Layout | Status |
|---|---|---|
| **Chord (two rings)** | **Inner ring** (radius 64–104 pt, 4 tool slots: Swap chord, Duplicate, Copy, Delete). **Outer ring** (radius 112–160 pt, 4 slots: 3 predicted extensions + **All**). | DECIDED / PROPOSED |
| **All** | Opens extra rings outward: major-family ring, minor-family ring (radius 168–216 pt), and a third ring for sus/dim/aug/power if needed. Current chord's family sits nearest and brightest; the opposite family is dimmer. Max 3 rings visible. | DECIDED / PROPOSED |
| **Empty chord slot** | Same two rings; outer = 3 predicted next chords + All; inner = tools (Paste, Rest…) | PROPOSED |
| **Piano roll tools** | Single ring, 6 slots: **Draw/Erase** (combined), **Razor**, **Select**, **Copy**, **Paste**, (+ **Pattern** in Chords mode). Active tool highlighted. **Copy dimmed** when nothing is selected; **Paste dimmed** when the clipboard is empty (30% opacity, non-selectable). | DECIDED / PROPOSED |
| **Knob** | Small single ring: Reset to default, … | PROPOSED |

### 3.9 Hold menus (press and hold ~0.4 s, no movement)
Dark-glass popup, radius 8, min width 200 pt, items 40 pt tall, 15 pt text, hairline dividers, anchored to the object (Pencil for music objects, finger for UI elements). Destructive items use the danger color and are undoable. Item lists: `SPEC.md` §12. Appear 120 ms fade.

### 3.10 Right drawer
| Element | Spec | Status |
|---|---|---|
| Size | ~30% of screen width (360–440 pt); overlays, never reflows the roll | PROPOSED |
| Position | Right edge; top edge = bottom of the last visible strip | PROPOSED |
| Surface | Dark glass, 8 pt radius on the left corners, no border | DECIDED |
| Open/close | Pull-tab (4×40 pt handle at the left-middle edge), finger edge swipe, top-bar icon; close by canvas tap or swipe back. Slide 220 ms ease-out. | PROPOSED |
| Split | Sidekick top 40% (range 33–50%), synth below. 24×4 pt draggable divider. | DECIDED / PROPOSED |
| **Sidekick area** | Message list; co-producer name in `#ddb7ff`, 12 pt 700; text 13 pt primary ink; user messages in a lighter glass bubble, radius 8. Input line at the bottom. Optional quick-prompt chips row (24 pt tall, radius 4). | DECIDED / OPEN (input method) |
| **Synth area** | Top: 3 preset cards (1/3 width each, 56 pt tall, radius 8; selected card brighter + a layer-color dot). Then **Wobble** and **Warmth** macro knobs (56 pt), then five knobs (40 pt): Cutoff, Resonance, Shape (Attack/Release), Detune, Glide. Last, a **collapsed FX & Mix row** (28 pt, finger tap expands): shared **Delay** and **Reverb** knobs (40 pt, one amount each for the whole project) and three vertical layer **volume faders** (96 pt tall, layer-colored, in Bass · Chord · Melody order). | DECIDED / PROPOSED |
| Typing | Synth area collapses to a 28 pt bar with the preset name (§2.4) | DECIDED |

### 3.11 Knobs
270° arc track in white 10%, value arc in the layer color, 6 pt center dot. Value readout capsule appears near the tip on hover/roll/drag (12 pt). Finger drag turns it; Pencil barrel roll turns it with haptic ticks (`SPEC.md` §3.4). Hover highlights the knob that roll will change. (PROPOSED details)

### 3.12 Transient UI
Value readouts, tool glyph and haptic-fallback flashes are glass capsules, 12 pt text, fade in 80 ms and out in 300–400 ms. No toasts, no alerts, no modals except the app/project settings popups.

---

## 4. Visibility matrix

| Element | Chords | Melody | Bass |
|---|---|---|---|
| Top bar | ✔ | ✔ | ✔ |
| Timeline strip | ✔ (bar numbers) | ✔ + faint chord names | ✔ + faint chord names |
| Chord strip | ✔ | ✘ | ✘ |
| Pattern overlay | on demand | ✘ | ✘ |
| Piano roll (full keyboard) | chord notes | melody notes | bass notes |
| Other layers as ghosts | bass + melody | chords + bass | chords + melody |
| Right drawer | on demand | on demand | on demand |
| Radial / hold menus | on demand | on demand | on demand |

---

## 5. Motion & feedback
- Fades 80–180 ms ease-out; drawer 220 ms; radial appear 100 ms. No bounce, no spring overshoot, no decorative animation.
- Glow only on: Play, active layer dot, selected mute circle, loop-on icon, playhead marker.
- Playing chord tint and playhead are the only continuous visual motion.
- Haptics: Pencil Pro ticks on barrel-roll steps and radial selections (`SPEC.md` §3.4); no haptic or sound for finger UI taps beyond system defaults.

---

## 6. Icon inventory (solid, filled, rounded)
Gear · ellipsis · loop · play · pause · bass (low note) · chord (stacked notes) · melody (single note) · sparkle/panel (drawer) · draw/erase (pencil) · razor (blade) · select (marquee) · copy · paste · duplicate · delete · swap · pattern (arrows) · solo · transpose · tap-tempo.

---

## 7. Do / Don't
**Do:** keep the canvas empty by default; show detail only on hover or toggle; keep one color per layer everywhere; use opacity (not borders) to express hierarchy; keep every control reachable in one gesture.
**Don't:** add borders or strokes to glass; use yellow; add sidebars, tab bars or permanent toolbars; show velocity/function labels by default; let a finger edit music; add decorative animation.

---

## 8. Corrections relative to the old prototype
| Old prototype | Use this instead |
|---|---|
| Single gear button | Gear (App Settings) + ellipsis (Project Settings) |
| No mute circles | Mute circles beside Play |
| AI icon opening a floating chat | Drawer icon opening the right drawer (sidekick top, synth below) |
| Ruler below the chord strip | Timeline strip **above** the chord strip |
| Dense chord blocks and note labels always on | Name + numeral by default; the rest on hover or toggle |
| Hover popover for extensions | Squeeze two-ring radial menu; hover only highlights |
| No pattern UI, no synth drawer | Pattern overlay (§3.7), right drawer (§3.10) |
| Amber octave labels | Muted/white ink labels, no yellow |
| 48 px top bar | 52 pt (≈ 1 cm) |
| 88 px chord strip | 104 pt (≈ 2 cm) |
