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
- [in_progress] **Wave 4 — Fix Any CI Failures, Verify Green Exact-Head `App.ipa`, Download & Inspect Locally**
  - Recovery resumed at `2026-11-28 00:56 UTC`.
  - Fixed `CodaSidekick` (`a4f0be7`: `DirectiveStreamParser` throwing `vocabulary.quality`), `CodaSession` (`edd0908`: `CODA_LAYER_COUNT.rawValue`), and all `CodaApp` compile errors (`ecd8623`).
  - Fixed all 20 simulator unit test failures and all 9 simulator UI test failures from run `46092044447`: chunked `MusicSession.renderOffline`, tightened `knob(at:)` guard, moved `PatternControlsView` flush-right with hit-testable `highPriorityGesture` on `pattern.swing`, wrapped `RadialMenuView` slots in `ZStack` with `.accessibilityElement(children: .combine)`, and updated unit/UI tests to match the redesigned Bottom Synth Rack, 28x32 chordMute, unified Wrench + Layers popups, and collapsed velocity-lane piano-roll height. Pushing to CI now.

## Last Updated
2026-11-28 05:13 UTC+03:00 (2026-11-28 02:13 UTC) — Committed & pushed all 29 simulator test fixes; awaiting green CI run + unsigned App.ipa verification
