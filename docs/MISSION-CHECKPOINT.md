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
- [in_progress] **Wave 2 — `CodaSession` 3-Layer Wiring + Complete Procreate-Style UI Redesign + Save Hub + Sidekick Drawer**
  - Subagent C (`sa-0-a3703d8b`): `Sources/CodaSession/`, `Tests/CodaAudioTests/`, `project.yml`.
  - Subagent D (`sa-1-4943233c`): `Sources/CodaApp/`, `Sources/CodaInteraction/`, `docs/DESIGN.md` (full Procreate-style UI redesign + 3 layers + Save Hub + Sidekick Drawer).
- [pending] **Wave 3 — Local Scaffold/C++ Verification + Push to GitHub Actions CI (`coda/owner-pattern-topbar-four-ui`)**
- [pending] **Wave 4 — Fix Any CI Failures, Verify Green Exact-Head `App.ipa`, Download & Inspect Locally**

## Last Updated
2026-11-28 02:42 UTC+03:00 (2026-11-27 23:42 UTC)
