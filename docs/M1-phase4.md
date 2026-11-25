# M1 phase4 correction pass — Hermes review handoff

Date: 2026-11-25. Scope: `docs/briefs/M1-phase4-review-fixes.md`, on top of
the existing phase4 UI and phase3 pass2 worktree. Implementation only; stop for
Hermes re-review and combined Mac verification. This is not M1 acceptance.

## Implemented corrections

### Compile and actual Pencil ingress

- `PencilInputAnchorView` has internal access, matching the internal
  `PencilInputBridge` and its UIViewRepresentable witnesses. Conformance was
  preserved; no private result type leaks from an internal witness.
- `CodaEditorStore.value(for:)` and `presetDefault(for:)` now explicitly return
  their switch expressions. `setValue` calls `self.value(for:)` instead of
  resolving the shadowing Double parameter as a function.
- `radialModeName` and `currentRingIsSelected` explicitly return their switches.
  Both inner-tool switches in the production `RadialChoiceResolver.resolve`
  also needed explicit returns after the outer guard.
- The local quality-ID collection no longer shadows `qualities(for:)`.
- `EditorViews` imports `CodaInteraction` for the production radial geometry.
- Checked all `CodaDesignTokens.Colors` references against declarations.
  `mutedInkAlternate` is declared and correct; it was not renamed.
- Official cached DocC references identify the delegate method as
  `pencilInteraction(_:didReceiveSqueeze:)`. The existing `didReceive:` spelling
  was an unrelated method and would not receive the optional delegate callback.
  It now matches Apple's selector. A native selector-response regression is
  included, alongside compilation of the actual bridge in the test target.

### Destructive hold menu and shared gutter

- `HoldMenuLayout` defines the actual clamped rectangle, three 40pt rows and
  two 1pt dividers. Rendering, hover selection, and final lift hit testing all
  use that layout. The final lift recomputes the hit instead of trusting a stale
  Delete hover. X bounds, top/bottom bounds and divider gaps cancel.
- A strip touch at y=100 clamps the first visible row to y=176...216; its
  center y=196 now resolves Copy. Duplicate is y=217...257, Delete y=258...298.
- The strip's leading padding is inside its fixed 56pt header. It no longer
  creates a 64pt footprint. Timeline header width aliases the same gutter token;
  strip, ruler and roll continue using the existing shared viewport transforms.

### Atomic Swap, actual previews, cancellation and audio ownership

- Inner Swap enters root selection. Lifting on a root updates only the draft
  and advances to the existing three quality-family rings. Lifting on a quality
  performs exactly one `session.edit([.swap(...)])` for root plus quality.
  Re-select the current quality for a root-only change. Cancel/dead-zone lift
  before the final quality preserves progression, undo and redo.
- Outer suggestions and outer All retain the original root and slash bass.
  Preview and commit now use the same chord-choice resolver in the store.
  Root hover does not silently change the draft; the root lift chooses it.
- Real hover choices call `MusicSession.auditionPreview`, which uses the actual
  solver and existing adapter/native audition command. No new renderer, note
  timer, DSP code, render-thread allocation, or transport change was added.
- Consecutive identical choices do not retrigger. Changes coalesce into one
  pending MainActor task with a 150ms minimum start interval. Mailbox-capacity
  retries are bounded to four attempts separated by 35ms. Failures are quiet
  inline errors, not successful-audio claims.
- Preview ownership uses a UUID. Dead zone, tool-only choices, touch cancel,
  menu close/commit, hover exit, bridge removal and inactive scene cancel pending
  UI work and request release of only the owned audition. The session sends its
  existing empty-audition release/restore command. Mailbox backpressure retains
  that stop in the existing control-side pump until admission.
- Successful explicit auditions supersede preview ownership; old cleanup cannot
  stop them. Plan replacement retires ownership because the native plan already
  retires the old audition. Suspend clears ownership and pending stops. Delayed
  preview work also checks the existing lifecycle epoch before activating audio.
- The existing finite 0.8s native audition expiry remains a final bound. Editor
  history, redo, playback intent, and phase3 native ownership/quiescence rules
  remain outside preview mutation.

### Drawer gestures, scrolled controls and keyboard extent

- Drawer edge opening compares stable start/current displacement. Ten -10pt
  increments now cross the same threshold as a single -100pt movement. A consumed
  edge gesture cannot reverse itself or begin panning the canvas. Horizontal
  direction is required; non-edge navigation keeps incremental pan behavior.
  The bridge captures touch-down before UIKit's recognition threshold, so a fast
  initial movement cannot move the recorded start out of the edge band.
  Existing drawer scroll/control recognizers and SwiftUI close gestures remain.
- Each actual knob circle publishes its frame in `editor.root` coordinates.
  The store uses those frames for both barrel-roll and squeeze-reset targeting,
  with circle containment and clipping to the visible drawer viewport. No fixed
  unscrolled row formulas remain. Hidden FX and a closed drawer reject targets.
- Startup remains top MIDI 84 with 22pt rows. Vertical pan/scale clamps use the
  real `topMIDI + 1` row count down through MIDI 0, rather than a fictitious 128
  rows below startup. Negative offsets still reach MIDI 127 at the top. The
  inclusive final MIDI-0 row is fully reachable; the full keyboard is retained.

### Verified Pencil canvas feedback API

Read the supplied raw official Apple DocC cache files:

- `developer.apple.com-f85b9bee91.md`: UICanvasFeedbackGenerator declaration,
  MainActor annotation, `init(view:)`/`prepare()` example, and references with
  `func alignmentOccurred(at: CGPoint)` and `func pathCompleted(at: CGPoint)`.
- `developer.apple.com-19986f942d.md`: UIPencilInteraction and the exact optional
  squeeze delegate selector above.
- `developer.apple.com-ae6e0993dd.md`: Squeeze `hoverPose: UIPencilHoverPose?`
  and `phase: UIPencilInteraction.Phase` references.
- `developer.apple.com-4836885cb0.md`: hover-pose `location: CGPoint` in the
  interaction view's coordinates and actual `rollAngle: CGFloat` reference.

The bridge creates `UICanvasFeedbackGenerator(view: root)`, prepares it, emits
`alignmentOccurred(at:)` for discrete roll detents, and `pathCompleted(at:)`
for radial/reset confirmation. Calls stay on the MainActor and are limited to
one event per 35ms. No generic UIImpact-only substitute remains. There is no
invented Pencil intensity setter. Finger parameter changes do not increment the
Pencil event sequence; clearing the visual flash does not emit or consume a tick.
The visual detent/readout remains available on devices without tactile output.

**Unresolved tactile requirement:** the cached public canvas APIs do not expose
an intensity parameter. Min/max/default retain stronger visual emphasis, but a
physically stronger Pencil tick at these points has not been established. Do not
claim equivalent or stronger physical feedback merely from the two canvas event
names. Hermes must assess this against SPEC §3.4 with Apple SDK/docs and the owner
on compatible Pencil Pro hardware. There is no physical-feel claim in this pass.

No additional API is required for the implemented canvas feedback calls. The
installed SDK must still compile the bridge, including the existing roll-angle
properties and the squeeze phase cases. If exact phase-case declarations are
needed during Mac review, the primary declaration endpoint is
`https://developer.apple.com/tutorials/data/documentation/uikit/uipencilinteraction/phase.json`.

## Prepared production regressions (native execution pending)

`Tests/CodaInteractionTests/EditorInputModelTests.swift` retains its existing
device gate, exact tap counts, transform, radial-family reachability and roll
tests. Added bounded/clamped hold-layout rows, divider/outside cancellation,
exact 56pt strip boundary, and corrected actual startup-register clamp assertions
that also prove MIDI 127 and MIDI 0 remain reachable.

`Tests/CodaAudioTests/EditorStoreRegressionTests.swift` executes the production
store/bridge source and actual offline MusicSession/AVAudioEngine path:

- Actual optional squeeze selector response.
- Visible Copy populates the clipboard; visible Duplicate/Delete dispatch
  correctly; outside/divider lift cancels even after stale Delete hover.
- Draft root plus quality commits once; cancel preserves an existing redo;
  one undo restores both components. Outer extension/All retain root identity.
- Slow/fast edge opens and closes, consumed-pan isolation and ordinary pan.
- Scroll-frame replacement targets the visible Reverb knob rather than the old
  Cutoff position; clipped/hidden/closed targets are excluded; roll and reset
  dispatch to the same actual target.
- All preset control/default reads; shared FX/level survive preset changes.
- Hover actually delivers native audition events, identical hover deduplicates,
  center cancellation releases voices, redo survives, and no delayed audition
  escapes closure or a suspended lifecycle epoch.
- Stale cancellation cannot stop newer explicit audition. Full mailbox
  cancellation retries and restores transport playback voices.
- Finger knob changes and flash expiry cannot generate Pencil feedback events.

`project.yml` only adds these existing production UI source files and the existing
CodaInteraction module to the current CodaAudioTests target. No external runtime
dependency, new framework architecture, target SDK, scheme, runner, CI workflow,
signing, or installed tooling changed in this correction pass. All existing native
music/DSP/transport/audio/UI tests and the four screenshot names remain enabled.

## Defaults and tuning for Hermes

Existing defaults remain: C natural minor, 124 BPM, eight bars, fixed 4/4, 16
steps/bar, startup top MIDI 84, 22pt semitones, knob 12-degree dead zone and 5%
detents, 0.4s hold, 220ms drawer animation, finite 0.8s native audition.
The new preview interval/retry bounds and haptic minimum interval live together
in `CodaDesignTokens.Input`. Shared menu width/divider dimensions are there too.
Root-then-quality is the bounded completion flow for inner Swap; the final lift
is its single history transaction. No OPEN design question was newly defaulted.
No source-of-truth/tracking document was edited; Hermes owns any decisions log.

## Local checks actually run

Windows host, 2026-11-25:

- `python -m unittest discover -s Tests/Scaffold -p 'test_*.py' -v`: 14 passed.
  Package tests use synthetic archives; this is not a new app archive/IPA result.
- `python -m py_compile scripts/package_ipa.py scripts/export_ui_screenshots.py
  Tests/Scaffold/test_project_scaffold.py Tests/Scaffold/test_package_ipa.py`:
  passed.
- Python/PyYAML validation: parsed `project.yml` and existing unsigned-IPA workflow;
  checked all target dependencies, all declared source paths, the combined four
  native test bundles, and iOS 27.2 target: passed.
- Python palette scan: all app `CodaDesignTokens.Colors` uses have declarations;
  verified `mutedInkAlternate`: passed.
- `git diff --check`: passed for tracked changes (Git emitted existing CRLF
  conversion warnings). Separately checked the scoped new Swift/report files
  for trailing whitespace/conflict markers because Git does not diff untracked
  files by default.
- `Get-Command swift,xcodebuild,xcodegen,clang++,g++,cmake -ErrorAction
  SilentlyContinue`: none of these toolchains was available on PATH. Python was
  available. No toolchain or dependency was installed.

No Swift/XCTest, native C++/sanitizer, simulator, XcodeGen, archive or physical
device result is claimed. No screenshot was generated or visually reviewed.

## Remaining acceptance gates and manual device checklist

1. Hermes reviews this correction with the existing phase3 pass2 diff. Pending
   native compilation can still reveal SDK/type/concurrency integration issues;
   local Python/YAML checks do not prove Swift compilation or test success.
2. On the prescribed Mac, run XcodeGen and the existing combined coda scheme
   (music, interaction, audio/store and UI tests); retain the native transport/DSP
   suites and ASan/UBSan. Inspect failures rather than skipping tests. Phase3
   acceptance remains pending; this pass does not supersede its report.
3. Generate and inspect the existing four named simulator screenshots: empty
   editor, four-bar fixture, synth drawer, edge radial. Check the shared gutter,
   clamped menu rows, drawer clipping/scroll and all quality labels. The fixture
   is not proof of a physical squeeze, barrel roll or Pencil touch.
4. Archive/package/verify the unsigned arm64 iPad-only landscape IPA using the
   existing pipeline after review. No CI, archive, install, staging, commit or
   push was performed in this turn.
5. On iPad Pro/Pencil Pro, start empty and build four bars with Pencil only;
   resize once and undo once; copy/paste/duplicate/delete via both applicable
   menus; lift outside each destructive row, in dividers and beyond both X edges.
   Verify Copy at the first clamped row never deletes. Repeat near every edge.
6. Exercise inner Swap root then quality and cancellation at each stage. One
   undo must restore both. Verify outer suggestions and all three quality-family
   rings preserve root; hover auditions must match the finally committed chord.
   Move rapidly through slots; leave hover, cancel, background, interrupt and
   resume. Verify no stuck notes and no preview that reopens background audio.
7. Check slow and fast edge swipes in both directions, drawer scrolling, pan,
   pinch, exact two/three-finger double-tap history, four-finger chrome toggle,
   palm rejection and finger music taps that never select/edit/audition. Pan the
   keyboard to MIDI 127 and 0 and verify alignment after pan/zoom.
8. Scroll expanded FX into view. Pencil roll/squeeze over each visible knob must
   affect exactly that knob; its former location and clipped controls must not.
   Check 12-degree dead zone, regular detents, default/endpoints, reset radial and
   visible fallback. Confirm actual tactile output and assess the unresolved
   stronger-tick requirement above. No pressure/tilt/barrel-double-tap behavior
   was introduced. If system settings divert squeeze to a Shortcut, no squeeze
   callback is guaranteed; set the system action appropriately for this check.
9. Play/pause/scrub/loop the progression through all three production presets,
   shared FX, mute and level; verify stable native playhead, edits during playback,
   route/interruption recovery and acceptable sound/feel. Owner listening and
   physical feedback remain deferred and unaccepted.

Remaining M1 exclusions stay explicit: no Bass/Melody controls/engines, ML,
sidekick, persistence/export, roll editing, voicing roll, razor/split tools or
patterns. Strip Split remains omitted (optional in this brief). No M1b work.
This report records prepared coverage, not proof that the complete original M1
acceptance checklist has passed. Stop here for Hermes review.
