# Roadmap

Source: `SPEC.md` §18. Behavior follows `SPEC.md`; visuals follow `docs/DESIGN.md`. Prototype files are outdated mood references only. The owner confirms no original blueprint exists; use the CARRIED requirements actually stated in the spec.

## Execution and approval gates

- Hermes writes planning/review documents only; Codex CLI writes app code, one scoped milestone at a time.
- Every milestone requires a reviewed diff, a green GitHub Actions unsigned archive, and a verified `App.ipa` artifact. CI success alone does not establish on-device acceptance.
- After delivery, stop for the owner's exact `approved` reply before beginning the next milestone. Owner feedback becomes a scoped Codex fix brief and repeats review/build/delivery.
- Use the requested Codex command with a PTY. Never silently change DECIDED behavior, add finger music editing, or relax audio render-thread constraints.
- On CI failure, return the actual error to Codex; allow at most three corrective retries, then stop and report.
- M1 and M1b delivery must include the listening checklist from `docs/sound-brief.md`, hand-testing instructions, and chosen defaults.
- Before M4, verify network access to `ailsntua/Chordonomicon` and sufficient training compute. Stop and ask the owner if either is insufficient.
- Log each adopted PROPOSED/OPEN default in `DECISIONS_LOG.md`; summarize it here at the relevant milestone. OPEN defaults belong behind a single named constant/flag. Questions with no stated default remain unresolved until needed.

## Milestones

- [ ] **M0 — Scaffolding.** XcodeGen `project.yml`, GitHub Actions unsigned `.ipa`, Plus Jakarta Sans via `UIAppFonts`, landscape lock, OLED theme tokens (§15).
  - **Exit criterion (§18):** App launches on the iPad with the black canvas and font.
  - Build/artifact: implementation authorized and in progress. Device acceptance: pending. Owner approval: pending.
- [ ] **M1 — Synth + chord track.** Voice engine, 3 presets, Wobble/Warmth + five knobs, FX chain, shared delay + reverb and per-layer EQ/volume (§13.7), ear-safety master, glide. Top bar (settings, key/scale, BPM, loop, play), thin timeline, chord strip, Pencil add/resize/delete and audition, plain block-chord playback, rule-based two-ring radial, undo/redo, right drawer (synth half only).
  - **Exit criterion (§18):** Build a 4-bar progression and hear a convincing loop that stays pleasant for long listening.
  - Scope clarification from §13.7: Chords EQ/volume in M1; Bass/Melody EQ/volume with those layers in M3.
  - Build/artifact: not started. Listening/hand acceptance: pending. Owner approval: pending.
- [ ] **M1b — Strum engine on top of the synth.** Pattern overlay with 8 eighth slots, arrow strokes, chuck, tap-to-remove, swing, humanize, spread.
  - **Exit criterion (§18):** A pattern changes how the same chords play.
  - Build/artifact: not started. Listening/hand acceptance: pending. Owner approval: pending.
- [ ] **M2 — Chord roll.** Voicings, roll-to-step with haptics, chord-tone labels, auto-naming on lift, vertical slice sync, razor/select/copy/paste/draw-erase radial, hold menus.
  - **Exit criterion (§18):** Reshaping notes renames the chord; slicing splits chord blocks.
  - Build/artifact: not started. Device acceptance: pending. Owner approval: pending.
- [ ] **M3 — Bass + melody layers.** Pills, mute circles, ghosts, full rolls, bass follow rules, timeline chord names.
  - **Exit criterion (§18):** Bass moves with chords per §9; layers mute/select independently.
  - Build/artifact: not started. Device acceptance: pending. Owner approval: pending.
- [ ] **M4 — Train and integrate ChordPredictor (§17).** Prediction-driven outer ring, voice-leading previews, ghost previews. Mandatory network/compute preflight before starting.
  - **Exit criterion (§18):** Outer-ring suggestions come from the model; transition-table baseline beaten.
  - Build/artifact: not started. Training/evaluation evidence: pending. Device acceptance: pending. Owner approval: pending.
- [ ] **M5 — Sidekick.** Drawer split, Qwen download + streaming, `<directive>` parser, steered ghosts, accept/dismiss. Typing hides the synth half.
  - **Exit criterion (§18):** A chat request produces auditionable ghosts.
  - Build/artifact: not started. Device acceptance: pending. Owner approval: pending.
- [ ] **M6 — QoL and carried features (§19), persistence, export.**
  - **Exit criterion (§18):** Projects save/load; MIDI export works.
  - Build/artifact: not started. Device acceptance: pending. Owner approval: pending.

## Preflight status

The owner authorized M0 implementation. Do not start M1 before the M0 approval gate.

- Read `AGENTS.md`, `SPEC.md`, `docs/DESIGN.md`, `docs/sound-brief.md`, and prototype HTML/design text. Prototype `screen.png` visual inspection was attempted but the vision provider returned HTTP 403; no visual inspection is claimed.
- Local Git repository initialized on `main`, connected to the owner's public `Jisakai/CODA` repository. No remote commits existed at the start of M0.
- Codex CLI is available (`codex-cli 0.171.0`). Provider/auth readiness has not been tested.
- GitHub CLI installed; authenticated repo access verified. CI will be verified against the actual M0 commit.
- No blueprint exists (owner-confirmed); this is not a blocker.
- Apple Xcode support and official runner-image manifests inspected. Latest stable Xcode listed is 27.2, with the iOS/iPadOS 27.2 SDK; the `xcode-27` runner lists it installed. Pin that toolchain and assert the SDK in CI rather than silently building with the older `macos-latest` default. Beta toolchains are not selected by default.

## Deferred design questions without complete stated defaults

These are not prerequisites to M0 and must not cause invented decisions: arpeggio definition (§8) and cross-layer clipboard rules (§11). Raise them with the owner when their milestone requires them. The sidekick name and personality have been decided in §14.1.
