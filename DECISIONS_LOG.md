# Decisions log

Behavior authority: `SPEC.md`. Visual authority: `docs/DESIGN.md`. Owner decisions supersede earlier OPEN/PROPOSED text. Record adopted defaults per milestone with their source, named tuning constant/flag, and owner-review status. No implementation defaults have been adopted yet.

## Owner-confirmed decisions

### App and sidekick name
- **Status:** DECIDED by the owner.
- **App name:** coda.
- **Qwen co-producer name:** coda.
- coda must have its own visible, recognizable personality, not generic assistant presentation. Owner-confirmed traits: she is chill, open-minded and candid; see the critique decision below.
- **Source:** Owner conversation; reflected in `SPEC.md` title, §14.1 and §22 item 8.

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
- Hermes still does not write app code directly. The owner has authorized M0 implementation; all later milestone approval gates remain intact.

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

## PROPOSED and OPEN defaults adopted

### M0 — Scope and provisional toolchain
- **Scope:** M0 only; no audio, editing, AI, networking or model download. Its on-device exit criterion and owner approval remain pending until delivery/testing.
- **Latest SDK interpretation:** latest stable release, not a beta. Primary-source preflight lists Xcode 27.2 with iOS/iPadOS SDK 27.2; minimum deployment will match 27.2, with no compatibility branches. Actual CI must assert the installed toolchain before the build.
- **Runner:** standard `xcode-27` arm64 label with `/Applications/Xcode_27.2.app/Contents/Developer`; not the larger/paid `xcode-27-xlarge` label. Pinning is required because the inspected `macos-latest` image lists an older SDK. This is an implementation choice under SPEC §1/§20, not a change to the latest-SDK rule.
- **Primary sources inspected:** Apple `https://developer.apple.com/support/xcode/`; official `actions/runner-images` README and `images/macos/xcode-27-arm64-Readme.md`. Source lookup is not proof of a successful CI execution; record actual build results separately.
- **PROPOSED defaults:** represent the existing DESIGN.md type scale (10/12/13/15 pt, label weight 600, chord-name weight 700) in tokens. Only a restrained wordmark is visible in M0 to demonstrate the bundled font. Other components are not rendered yet.
- **OPEN defaults:** none needed for M0. Future design decisions remain deferred.
- Record final implemented token values, tooling dependencies, and build evidence after review.
