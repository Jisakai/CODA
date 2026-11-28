# CODA Full-App Autonomous Mission Checkpoint

- **Owner Directive (Nov 28, 2026):** Drop Codex; Hermes is both implementer and orchestrator. Work nonstop with unlimited tokens until **2026-11-28 20:53 UTC** to finish the entire CODA app (M1b → M6 + complete Procreate-style UI redesign + bottom FL-style Synth/AUv3+SoundFont VST Plugin Rack up to 50% height + right drawer AI Sidekick ONLY) AND deliver a verified green unsigned `App.ipa` via GitHub Actions CI.
- **Rate Limit Discipline:** Keep active API concurrency moderate (~2–3 subagents max) to stay safely under ~10 RPM / 5M TPM.
- **Active Worktree:** `C:/Users/jisak/CODA/.worktrees/owner-pattern-topbar-four-ui`
- **Active Branch:** `coda/owner-pattern-topbar-four-ui` (base `5be49bc`)
- **Protected Root:** `C:/Users/jisak/CODA` (do not reset/overwrite).

## Stage Status
- [done] **Wave 1 — Core Audio + Music Engine + Sidekick + ML Script**
  - `CodaDSP/` + `Sources/CodaTransport/`: 3-layer synth/EQ/mixer/mute/audition, per-layer transport tracking; compiled & passed UBSan locally with zero render allocations!
  - `Sources/CodaMusic/`: Stage 1 fixes, `LayerModels`, `BassFollower`, `MultiLayerEventCompiler`, `CoreMLChordPredictor`, `CodaProjectDocument`, `MIDIExporter` + 4 XCTest suites.
  - `Sources/CodaSidekick/`: `PersonaPrompt`, `DirectiveStreamParser`, `SidekickModelManager`, `SidekickEngine` + tests.
  - `scripts/train_chord_predictor.py`: verified Chordonomicon pipeline + baseline + Core ML export + 3 passing Python unit tests.
- [done] **Wave 2 — `CodaSession` 3-Layer Wiring + Complete Procreate-Style UI Redesign + Save Hub + Sidekick Drawer** (committed in `4d8321d`, `c876c50`)
- [done] **Wave 3 — Local Scaffold/C++ Verification + Push to GitHub Actions CI (`coda/owner-pattern-topbar-four-ui`)**
- [done] **Wave 4 — Fix Any CI Failures, Verify Green Exact-Head `App.ipa`, Download & Inspect Locally**
  - Recovery resumed at `2026-11-28 00:56 UTC`.
  - Fixed `CodaSidekick` (`a4f0be7`: `DirectiveStreamParser` throwing `vocabulary.quality`), `CodaSession` (`edd0908`: `CODA_LAYER_COUNT.rawValue`), and all `CodaApp` compile errors (`ecd8623`).
  - Fixed all 20 simulator unit test failures and all 9 simulator UI test failures from run `46092044447`: chunked `MusicSession.renderOffline`, tightened `knob(at:)` guard, moved `PatternControlsView` flush-right with hit-testable `highPriorityGesture` on `pattern.swing`, wrapped `RadialMenuView` slots in `ZStack` with `.accessibilityElement(children: .combine)`, and updated unit/UI tests to match the redesigned Bottom Synth Rack, 28x32 chordMute, unified Wrench + Layers popups, and collapsed velocity-lane piano-roll height. Pushing to CI now.

  - Fixed remaining 3 unit + 1 UI-C failures from run `46096795727` (`ui-b` and `ui-d` already green; `ui-a` was runner-canceled): fixed `MusicSession.preparePlan` restart-from-cycle-0 detection for unconsumed `play()` followed by `setTempo`, switched the 2 barrel-roll tests in `EditorStoreRegressionTests` from `drawerOpen` to `synthRackOpen`, and hardened `top.synthRack` tap/wait in `CodaLaunchTests.testActualSessionPlayPauseAndChordMuteControls`.
  - Run `46098898969` passed `native + archive`, `ui-b`, `ui-c`, `ui-d`, AND 100% of simulator unit tests! Fixed the final 4 CI items: added `CodaSidekickTests` to `scripts/ci_evidence.py` `unit_inventory()`, switched `RadialMenuView` slots to `.accessibilityElement(children: .ignore)` with explicit `slotAccessibilityLabel` so AX frames match the square `buttonDiameter * scale`, replaced `PatternControlsView`'s SwiftUI `DragGesture` with a direct UIKit `SwingDragSurface` touch overlay (`touchesBegan/Moved/Ended`) for reliable vertical Swing drag, and waited for `rackElement.waitForNonExistence(timeout: 5)` after tapping `synthRack.close` in `testDrawerAndAllThreeProductionPresetsAreReachable`. Pushing to CI now.

  - Run `46101256443` passed **5 of 6 jobs**: `native + archive`, `simulator (unit)` (all 222 tests + provenance), `ui-b`, `ui-c`, and `ui-d`! Only 2 tests failed in `ui-a` (`testFourBarSeededFixtureScreenshotAttachment` PASSED with `SwingDragSurface`):
    1. `BottomSynthRackView.swift` (`testDrawerAndAllThreeProductionPresetsAreReachable`): `synthRack.close` (`chevron.down.circle.fill`) had no `.background(...)` or `.contentShape(Rectangle())`, so XCUITest's center tap fell through the SF Symbol's transparent chevron cutout. Added a `32×32` subtle circular backing + `.contentShape(Rectangle())`.
    2. `EditorViews.swift` — `RadialMenuView` (`testPrimaryRadialScreenshotFixture`): `.accessibilityElement(children: .ignore)` was placed AFTER `.position(point)` and without a frame-filling backing view, so AX frames still collapsed to inner `Text` glyph bounds. Added `Color.white.opacity(0.001)` inside the `ZStack`, `.contentShape(Rectangle())`, and moved `.accessibilityElement(children: .ignore)` + label/id/value BEFORE `.position(point)`. Pushing to CI now.

  - **ALL 7 CI JOBS PASSED on `69f010c312a86f65071d524d9d2dc56b26fca4b8`** in clean single-attempt `workflow_dispatch` run [`46113829427`](https://github.com/Jisakai/CODA/actions/runs/46113829427):
    - `native + archive` (2m42s), `simulator (unit)` (9m30s), `simulator (ui-a)` (14m56s), `simulator (ui-b)` (17m49s), `simulator (ui-c)` (22m23s), `simulator_delayed (ui-d)` (16m37s), and `publish` (10s) all `success`.
  - Downloaded & inspected `coda-unsigned-ipa` locally (`C:/Users/jisak/AppData/Local/hermes/cache/scratch/coda-ipa-46113829427`):
    - `App.ipa`: `1,346,623` bytes, SHA-256 `41093ea8a06f79302373cddb8c0799c92a9983dbe0921045fbb91c2fd9b0da97` (matches `App-verification.txt`), `Payload/coda.app`, `com.coda.sketchpad`, `arm64`, iPad-only (`UIDeviceFamily 2`), landscape-only, iOS SDK `27.2`, all 6 `PlusJakartaSans-*.ttf` weights + `OFL.txt` + `vocab.json` bundled.
    - `DSP-verification.txt`: `dsp_tests` + `four-bar` passed (Pluck/Currents/Wobble).
    - 6 UI verification screenshots present in `ui-screenshots/`.

## Completion
MISSION_COMPLETE=true

## Last Updated
2026-11-28 09:14 UTC+03:00 (2026-11-28 06:14 UTC) — Mission complete. Clean single-attempt CI run `46113829427` on `coda/owner-pattern-topbar-four-ui` @ `69f010c312a86f65071d524d9d2dc56b26fca4b8` passed all 7 jobs including `publish`, and `App.ipa` was downloaded and verified locally.
