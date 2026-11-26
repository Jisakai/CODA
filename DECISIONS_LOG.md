# Decisions log

Behavior authority: `SPEC.md`. Visual authority: `docs/DESIGN.md`. Owner decisions supersede earlier OPEN/PROPOSED text. Record adopted defaults per milestone with their source, named tuning constant/flag, and owner-review status.

## Owner-confirmed decisions

### App and sidekick name
- **Status:** DECIDED by the owner.
- **App name:** coda.
- **Qwen co-producer name:** coda.
- coda must have its own visible, recognizable personality, not generic assistant presentation. Owner-confirmed traits: she is chill, open-minded and candid; see the critique decision below.
- **Source:** Owner conversation; reflected in `SPEC.md` title, §14.1 and §22 item 8.

### Sidekick model — Qwen3 4B, 4-bit quantized
- **Status:** DECIDED by the owner; supersedes Qwen2.5 3B.
- Use **Qwen3 4B, 4-bit quantized** for coda's conversational sidekick. Retain the `mlx-swift-lm` integration plan and existing directive/personality responsibilities.
- Exact compatible artifact/revision, download size and real on-device memory usage (including context/KV cache) must be verified at M5. Do not reuse the previous model's size/RAM estimates as facts for Qwen3.
- This is an M5 model decision, not authorization to add ML to current M1 work.
- **Source:** Owner: “we go with Qwen3 4B 4 bit quantized not qwen2.5 3b”. Reflected in SPEC §14.3, §20 item 4 and §21.1.

### Deterministic identification versus learned prediction
- **Status:** DECIDED; existing spec behavior explicitly reaffirmed by the owner.
- Existing chords are identified deterministically by `ChordDetector.swift` (§7.3, §16).
- The trained chord model predicts harmonic possibilities (§17); it is not the existing-chord identifier.
- Qwen provides conversation/personality and steers predictions through the directive channel (§14.2–§14.4); it does not replace deterministic identification.

### Personality and critique of existing chords
- **Status:** DECIDED by the owner.
- coda uses she/her pronouns and has a chill, open-minded personality.
- She can critique existing chords and progressions, not just offer predictions or new suggestions.
- She must be willing to say when something genuinely does not work, without automatic praise. Criticism explains the musical issue in context rather than treating unconventional harmony as inherently bad.
- Critique does not replace deterministic chord identification or authorize automatic edits.
- **Source:** Owner conversation; reflected in `SPEC.md` §14.1 and §22 item 8.

### Delegated execution and permission handling
- **Status:** DECIDED by the owner.
- Hermes may choose how to orchestrate Codex, including scoped micro-prompts, correction runs, and subagents. Every Codex invocation MUST explicitly include `-c model_provider="xingchi"` and use `-m gpt-6.1-sol`; do not rely on the default provider. The owner confirms the explicit `-c` override is required for this setup. Other invocation details may be adapted to the installed CLI.
- Minimize interruptions: handle routine development permissions autonomously within the coda project and authorized build/push workflow. Stop for destructive, unrelated, security-sensitive, or unexpectedly costly operations rather than treating this as unlimited authorization.
- Do not disable or bypass host-enforced approvals or security controls. Unattended execution is a goal, not a guarantee that the host will never require user approval.
- Preserve one-milestone scope, Hermes review of actual diffs, audio-thread constraints, verified unsigned IPA delivery, and the owner's explicit approval gate before the next milestone.
- Hermes still does not write app code directly. The owner approved M0 after installation/launch; M1 is authorized. All later milestone approval gates remain intact.

### No original blueprint exists
- **Status:** Owner-confirmed clarification.
- There is no original blueprint to retrieve. References to it in existing documents are stale, not an owner deliverable or development blocker.
- Use the actual `SPEC.md`, `docs/DESIGN.md`, and supporting files. CARRIED requirements stated in the spec remain requirements; do not invent unspecified details from a nonexistent source.

### Public-repository privacy and release hygiene
- **Status:** DECIDED by the owner; the repository is intentionally public.
- Before any commit/push, review the exact staged files and diff for sensitive information. Stage explicitly selected project files, not the entire working directory indiscriminately.
- Keep credentials, tokens, `.env` files, provider/auth configuration, signing certificates, provisioning profiles, personal project saves, chat/session transcripts and local IDE state out of Git. Ignore patterns are a secondary guard, not proof that a commit is safe.
- Do not copy local Codex/Hermes configuration into the repository or CI. Use the required provider override locally; the unsigned CI build must not require Apple login or signing secrets.
- Review workflow logging and artifact contents for private data; do not dump environment variables or upload broad workspace/archive directories. Publish only intended build/test outputs.
- Use minimal GitHub workflow permissions and avoid exposing secrets to untrusted pull-request code.
- If a secret is accidentally exposed, stop publication and notify the owner; deleting it in a later commit does not revoke it or remove it from history.

### M1 drawer layout confirmation - November 26, 2026
- **Status:** DECIDED by the owner.
- **Exact owner quote:** "keep the empty half current version that empty place will get the ai later on"
- Preserve the current drawer layout documented in `docs/M1-phase4.md`: it covers the strip and roll from below the timeline to the viewport bottom; the empty upper half is reserved for future AI, and the lower-half synth scrolls independently.
- This decision explicitly supersedes contrary original below-chord-strip/full-height-synth interpretations for this issue.
- No AI implementation or M1b work is authorized. Physical iPad/Pencil/audio checks and final M1 owner approval remain pending; this confirmation does not constitute overall M1 acceptance.
- The unchanged existing verified native-green IPA may be reused without CI solely for this confirmation.
- **Source:** Owner decision on Kanban task `t_4f929ac3`, November 26, 2026.

## PROPOSED and OPEN defaults adopted

### M1b arrow length and base velocity — owner decision November 26, 2026
- **Status:** DECIDED by the owner; supersedes the approximate 90%-height arrow maximum in earlier visual guidance.
- **Exact owner quote:** "arrow lengths should be snapped to 10th grid of the height meaning 10 long is full velocity 1 long is %10 velocity".
- Arrow lengths use exactly ten discrete increments of pattern editing area height. Levels 1...10 mean 10%...100% base velocity; a full-height arrow is 100%. The rendered arrow, live readout and stored/base playback velocity share the same quantized value, never independent continuous mappings.
- Zero means no stroke, not an eleventh audible level. Preserve top/bottom direction gestures and Pencil tap-to-remove. Do not extend this quantization to chuck-circle size without owner instruction. Humanize remains a separate playback variation around the quantized base value.
- Require regressions covering all ten levels, endpoints, clamping and edit/render/playback consistency. Carry this requirement into every M1b implementation slice and handoff.
- Source: latest operator-delivered owner requirement on task `t_257ae4a6`; active brief `docs/briefs/M1b.md`.

### M1 progression authorization and radial visual correction — November 26, 2026
- **Status:** DECIDED by the owner; supersedes earlier M1b prohibitions and the pending M1 progression gate, not hardware-testing evidence.
- **Exact owner quote:** "I believe M1 is final I havent tested myself but it looks pretty much fixed. Just One thing radial menu start and end should be rounded and have a whole thing with overlayed pills following the curve. Aside from that looks fine we can go on to M1b".
- M1 is accepted for progression, with radial visual polish outstanding; physical iPad/Pencil/listening remain unverified. Each radial ring should have a continuous curved backing with round start/end caps and overlaid pills following the arc. Preserve existing behavior, placement and the owner-confirmed reserved upper drawer half.
- M1b strum implementation, normal scoped release commits/pushes, native verification and unsigned IPA delivery are authorized. Stop after M1b delivery for explicit approval before M2. No AI implementation.
- Source: owner authorization recorded on Kanban task `t_257ae4a6`; current bounded brief `docs/briefs/M1-radial-rounded-polish.md`.

### M0 — Scope and provisional toolchain
- **Scope:** M0 only; no audio, editing, AI, networking or model download. Completed with green CI and owner-confirmed installation/launch followed by explicit **M0 approved**. Rotation was not separately described by the owner.
- **Latest SDK interpretation:** latest stable release, not a beta. Primary-source preflight lists Xcode 27.2 with iOS/iPadOS SDK 27.2; minimum deployment will match 27.2, with no compatibility branches. Actual CI must assert the installed toolchain before the build.
- **Runner:** standard `xcode-27` arm64 label with `/Applications/Xcode_27.2.app/Contents/Developer`; not the larger/paid `xcode-27-xlarge` label. Pinning is required because the inspected `macos-latest` image lists an older SDK. This is an implementation choice under SPEC §1/§20, not a change to the latest-SDK rule.
- **Primary sources inspected:** Apple `https://developer.apple.com/support/xcode/`; official `actions/runner-images` README and `images/macos/xcode-27-arm64-Readme.md`. Source lookup is not proof of a successful CI execution; record actual build results separately.
- **PROPOSED defaults:** represent the existing DESIGN.md type scale (10/12/13/15 pt, label weight 600, chord-name weight 700) in tokens. Only a restrained wordmark is visible in M0 to demonstrate the bundled font. Other components are not rendered yet.
- **OPEN defaults:** none needed for M0. Future design decisions remain deferred.
- **Implemented tokens:** `CodaDesignTokens.swift`; 52 pt top bar, 20 pt timeline, 104 pt chord strip, 56 pt gutter; existing palette/radii/type scale. Visible wordmark uses Plus Jakarta Sans Light, 20 pt, tracking 0.2, opacity 0.72.
- **Tooling:** XcodeGen 2.46.0 recorded by CI; dependency-free Python scaffold/package checks and XCTest launch smoke check; no third-party runtime dependency.
- **Build evidence:** [CI run 45589404244](https://github.com/Jisakai/CODA/actions/runs/45589404244) succeeded for commit `2ac995fc142a2b780ffab1fd136362d56c142e2c`. Independently verified unsigned arm64 executable, iPad-only landscape metadata, SDK/deployment 27.2, bundled fonts/license, ZIP integrity and checksum. IPA SHA-256: `32aa7ea75b86957f986dbce201dea94e6ebdf915e6f3e89987d737e21c8d065c`.

### M1 — Foundation slice defaults (provisional until owner M1 review)
- **Source:** SPEC §4, §7.1, §7.4, §16 and §20; DESIGN examples. Full rationale/contracts are in `docs/M1-phase1.md`.
- `MusicDefaults`: empty eight-bar canvas, fixed 4/4, 16 steps/bar, C natural minor, 124 BPM. `LoopSpan` currently restricts loops to whole-bar spans of one to eight bars.
- `VoicingConfiguration`: MIDI 36–84, center 60, maximum span 36 semitones; movement weight 10, register weight 1, voice-count penalty 6. Viterbi optimizes a linear path, not cyclic last-to-first motion; explicit neighboring voicings are preserved on a single-region swap.
- `vocab.json`: ordered 27-quality vocabulary and alternatives; `7alt` explicitly includes root, third, minor seventh, b9, #9 and b13 without the perfect fifth. Rule-based suggestions remain deterministic key/function rules, not learned predictions.
- `NoteEventCompiler`: simultaneous block chords, nearest-rounded absolute sample boundaries, cycle-indexed fractional carry, terminal note-offs before next-cycle note-ons. Loop-crossing sustains release/retrigger at boundaries; actual envelope tails belong to the later DSP implementation. No allocation-heavy Swift compiler work belongs on the render thread.
- No OPEN design choice was required; barrel double-tap, patterns/arp and cross-layer clipboard remain deferred. No new third-party dependency.
- **Verification:** Hermes reran 13 existing Python checks successfully; independent static review reported no blocking logic/security defects. [CI run 45596058488](https://github.com/Jisakai/CODA/actions/runs/45596058488) succeeded for `e6b82e522fa60ed9a406a40f5ce8e9f33b2f4afd`: XcodeGen, native Swift compilation, 23 music XCTest methods and 1 launch test, unsigned archive/package passed. Downloaded IPA independently verified against CI checksum, iPad metadata, unsigned arm64 Mach-O and repository font/vocabulary bytes. SHA-256 `7fcfc7bf0eee05c51a502f739daa36de7113d35b2268d7a22080e26ee6f46b19`. Audio/UI implementation and full M1 on-device acceptance remain pending.
