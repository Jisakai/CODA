# M1 phase 2 — production synth/DSP core

This brief supersedes the completed phase1 brief. M0 owner-approved; foundation passed CI45596058488 at e6b82e5: 23 music XCTest, one launch test, 13 Python checks, verified unsigned IPA. M1 is authorized and incomplete; M1b+ not authorized. Hermes briefs/reviews; Codex codes. Implement this bounded slice, not all remaining M1.

## Read first
AGENTS.md; SPEC §0–3, §7.1, §13.1–13.7, §16, §18, §20 item11, §24; docs/sound-brief.md; DESIGN; DECISIONS_LOG; ROADMAP; docs/M1-phase1.md; actual CodaMusic source/event contracts, project.yml and CI. SPEC behavior > DESIGN visuals > prototype mood. No blueprint exists.

## Deliverables now
Separate production DSP module testable without UI/ML/AVFoundation. Prefer portable C++ with narrow POD/C API to avoid Swift/ARC on render. No third-party runtime dependencies. AVAudioEngine adapter, transport and UI come in next reviewed slice, NOT now.

- One voice architecture, exactly three DATA presets: synth Pluck (not guitar/Karplus-Strong), Currents pad, Wobble lead. Two oscillators saw/square/triangle mix, 2–3 detuned unison, quiet sub, amp ADSR, low-pass/filter envelope, slow drift, glide. Avoid naive alias-heavy oscillators. Actual sample-rate support. Preallocate 8–12 voices; define bounded smooth stealing/overlap for dense 7alt/slash chords and rapid changes. Old releases overlap; sorted-rank glide; no lost offs/clicky attacks.
- Centralized presets/ranges: Wobble scales drift/chorus-depth/phaser-speed together, Warmth closes filter/adds soft saturation; five knobs Cutoff, capped Resonance, Shape (attack/release), Detune, Glide. Pluck/pad glide off, lead on. Smooth control/preset/mute/level changes without abruptly resetting buffers/phases.
- §13.7 path: custom chorus/phaser/drift/saturation -> Chords static EQ/volume -> shared dark dotted-eighth delay (~30% feedback, repeats LP~3kHz) + soft long damped plate/hall-style reverb (~20ms predelay) -> gentle master high cut/shelf~8–10kHz, soft 2–4kHz dip, soft saturation, safety limiter. One shared Delay/Reverb amount each, no per-layer sends/Bass/Melody engines. Conservative headroom; no normal hard clipping. Mute fades dry/wet tails to silence, stale wet audio cannot return on unmute.
- Native precompiled flat sample-offset events, off-before-on, explicit region/voice identity and sample-accurate sub-buffer processing. Copy control-thread Swift event arrays into preallocated native storage before publishing. Bounded lock-free SPSC event/control handoff with documented ownership/reclamation. Queue-full returns safe observable failure, never overwrites active slots. No spin/wait or destructor/ARC in render. Future transport serializes producers.
- Render has NO allocation/deallocation, locks, I/O/syscalls, Swift/ObjC runtime, exceptions, parsing, ML/UI or unbounded loops. Allocate voices/FX storage at prepare. Denormal protection incl ARM64, finite control validation, stable bounded filters (not just masking blowups). Lifecycle rules prevent use-after-free; prepare/reprepare/reset outside render as appropriate. Explicit stop/process contracts.
- Real executable production-core tests: sample onset/off across varied buffer sizes; dense voice stealing/release/glide; preset/control endpoints and invalids; finite non-silent output; peak/headroom bounds; long tails/denormals; mute wet/unmute; block-size invariance; handoff capacity/repeated/concurrent producer-consumer. Instrument render allocations via test allocator hooks, sanitizer-friendly where available. Controls must measurably change signal, not just finite values. No Python replicas as proof.
- Offline render harness on same core: four-bar Cm7/Abmaj7/Fm9/G7alt for each preset, optional real WAVs in ignored build output plus objective peak/RMS report. WAV I/O/analysis OFF render. No fabricated/downloaded audio; short renders don't prove two-hour comfort/iPad latency.
- Narrow XcodeGen/CI integration: build/test production core on standard xcode-27 before archive (standalone clang++ harness acceptable); preserve 23 music/one launch/13 Python checks and Xcode/SDK27.2 pins. No hand-edit xcodeproj. Upload only IPA and explicit small verification reports; no WAV or broad workspace upload until review.

## Constraints/defaults
Finger only navigation/UI; Pencil alone edits/auditions music. No input/UI changes now; no pressure/tilt; double-tap unbound. Landscape iPad only, SwiftUI/AVAudioEngine later; no compatibility branches/entitlements. No M1b strum/pattern/chuck, M2 roll tools, M3 layers, ML/LLM, persistence/export or speculative stubs. Qwen3 decision is M5 only.

Use PROPOSED §13 defaults above, 2–5ms pluck attack, subtle long-session FX and conservative gain. Centralize/report exact ranges, voices, smoothing and costs for owner veto. Keep phase1 key/BPM/canvas defaults. No OPEN design question blocks DSP; defer pattern/clipboard/double-tap; architecture is yours.

Windows has no Swift/Xcode/XcodeGen; no clang++, g++, cmake or ninja found on PATH by Hermes. Discover alternatives safely; no machine-wide installs/settings. If no compiler, report native execution pending and exact CI commands. Consult/cite primary docs for VERIFY claims; don't invent APIs or successful outputs.

Do not edit SPEC/AGENTS/ROADMAP/DECISIONS_LOG/DESIGN or briefs. New docs/M1-phase2.md may explain API/constants/checks. No stage/commit/push/CI trigger. No credentials/.env/provider config/transcripts/machine changes; preserve unrelated untracked IDEA.md/.codex_review.md/fonts.

## Exit
Production core, executable tests/harness and CI wiring, then STOP for Hermes review. Report exact files/commands/results, limits, allocation/ownership reasoning, defaults/sources and native limitations. Full M1 exit still: integrated app builds four-bar progression and sounds convincing for long listening; green verified IPA plus owner listening/Pencil checklist and approval. This slice alone is NOT M1 completion.
