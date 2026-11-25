# AGENTS.md — rules for any coding agent working in this repo

This is a single-user, personal iPadOS music sketchpad app (iPad Pro 13", landscape only, sideloaded unsigned `.ipa`). Not an App Store product.

## Source of truth
1. `SPEC.md` is the source of truth for behavior. `docs/DESIGN.md` is the source of truth for UI layout and visuals. Read the sections cited in `.codex_task.md` before writing code.
2. Precedence: `SPEC.md` (behavior) > `docs/DESIGN.md` (layout and visuals; overrides the prototype) > `docs/prototype/` (outdated mood reference only, NOT final). The owner confirms no original blueprint exists. Implement CARRIED requirements stated in the spec; do not invent an absent source or treat it as a prerequisite.
3. Status tags in `SPEC.md`:
   - **DECIDED** — implement exactly. Never change it.
   - **PROPOSED** — implement as the default; note it in `DECISIONS_LOG.md`.
   - **OPEN** — implement the stated default behind one constant/flag; note it in `DECISIONS_LOG.md`. Never invent a different behavior silently.
   - **CARRIED** — keep unless it contradicts a DECIDED item.
   - **VERIFY** — check current Apple/library docs before relying on it.
4. If the brief and `SPEC.md` disagree, stop and report the conflict. Do not guess.

## Hard rules
- Target the latest iPadOS SDK only. No backward compatibility, no iPhone/adaptive layouts, no App Store compliance code, no low-RAM fallback modes.
- Landscape only. Lock orientation.
- Project files: use XcodeGen (`project.yml`). **Never hand-edit `.xcodeproj`.** The generated project is not committed.
- UI is SwiftUI. Audio is `AVAudioEngine` / AVFoundation.
- **Real-time audio safety:** nothing on the audio render thread may allocate memory, take locks, call Swift runtime-heavy code (retain/release-heavy closures), run ML, parse JSON/XML, or touch UI state. Preallocate voices. Pass events from the UI to the audio thread through a lock-free handoff of a precompiled flat event list with sample-accurate offsets. Smooth parameter changes. Protect against denormals.
- ML inference, LLM streaming, `<directive>` parsing and UI updates stay off the audio thread.
- Finger vs Pencil: **fingers only pan/zoom and press UI elements; only the Apple Pencil edits music.** Do not add finger editing. Do not use pressure or tilt.
- Colors, font, radii and sizes come from `docs/DESIGN.md` and `SPEC.md` §15. **No yellow.** Plus Jakarta Sans bundled via `UIAppFonts`.
- Do not add dependencies without a reason noted in `DECISIONS_LOG.md`.
- Do not rely on special entitlements (the app is sideloaded with free-account re-signing).

## Build & CI
- CI: GitHub Actions, `xcodegen generate` then `xcodebuild archive` with `CODE_SIGNING_ALLOWED=NO`, packaged into an unsigned `App.ipa` artifact. Verify the runner's Xcode/SDK supports the target iPadOS; pin if needed.
- Every milestone must end with a green build that produces an installable unsigned `.ipa`.

## Working style
- Work one milestone at a time, exactly as scoped in `.codex_task.md`. Do not start the next milestone.
- Keep audio DSP, music-theory logic (chord detection, voice leading, slice sync, bass follower), UI and ML in separate modules so each can be tested without the others.
- Music-theory modules are pure functions where possible and get unit tests.
- Keep presets, patterns and chord vocabulary as data, not hard-coded branches.
- Prefer small, reviewable commits. Describe what changed and which spec sections it satisfies.
- Anything involving feel (sound, haptics, gesture timing, menu behavior) is judged by the owner on the iPad. Put tunable values in one clearly named place so they are easy to adjust.
- Never write secrets or tokens into the repo.

## Owner interaction
The owner decides design, sound and feel. Architecture and implementation are your decisions. Ask the owner only about OPEN design questions listed in `SPEC.md` §22, and only through the orchestrator.
