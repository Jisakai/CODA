# M1 phase 1 — deterministic music/event foundation

This is the foundation slice in `.codex_task.md`, not full M1 acceptance.
There is no new UI, gesture handling, synth/DSP, render callback, timer, ML,
chord detector, slicing, pattern playback, persistence, or Bass/Melody work.
The approved `Sources/CodaApp` and launch test remain unchanged.

## Review map

- `Sources/CodaMusic/MusicModel.swift`: immutable validated identity, region,
  progression and loop values. MIDI 0–127; pitch classes 0–11; unique ascending
  pitches; all quality pitch classes required; non-chord slash bass permitted
  only as the actual lowest note. Integer spans must be positive, in canvas,
  overflow safe and nonoverlapping. Adjacent spans are legal; absent regions
  are rests. IDs are supplied by the caller, not generated randomly.
- `ChordVocabulary.swift` and `Resources/vocab.json`: 27 stable quality IDs,
  including Cm7, Abmaj7, Fm9 and G7alt from DESIGN, plus triads, extensions,
  suspensions, diminished, augmented and power chords. Ordered family rings
  and three ordered quality alternatives are data. Malformed metadata,
  duplicate IDs/pitch classes and dangling suggestion IDs are rejected.
- `ProgressionEditor.swift`: atomic batches of add, resize, swap, duplicate,
  paste and delete; value snapshots for undo/redo. Failed transactions retain
  both state and history. Copy/audition are reads. A changed transaction clears
  redo; no-ops do not. Clipboard is a typed chord-strip value, not an OS or
  cross-layer clipboard. Swap regenerates only its target against the nearest
  preceding region; it preserves neighboring explicit pitches.
- `VoiceLeadingSolver.swift`: candidate generation and linear-path Viterbi.
- `ChordSuggestions.swift`: replaceable `ChordSuggestionProvider` interface
  with deterministic key/function rules; explicitly not trained AI.
- `NoteEventCompiler.swift`: pure off-thread compilation to flat value events.
- `Tests/CodaMusicTests/*.swift`: 23 XCTest methods covering vocabulary/model
  validation, all qualities at all roots, edits/history, actual exhaustive
  path optimality, a generated greedy counterexample, slash/register constraints,
  stable ties/suggestions, timing/rates, silence, clipping and off ordering.
- `project.yml`: static `CodaMusic` target and `CodaMusicTests` logic test bundle;
  dedicated `CodaMusic` scheme and inclusion in the existing `coda` scheme.
  Only the specific `vocab.json` resource is copied to app/test bundles. The
  library has no resources, third-party dependencies, UI or audio imports.
  The workflow and SDK/runner pins are unchanged.

## Adopted defaults for Hermes to log

Do not change SPEC, DESIGN, ROADMAP or DECISIONS_LOG for this slice. These
choices are reported here for review and later logging by Hermes.

| Choice | Implementation/source |
| --- | --- |
| 8-bar empty canvas; 16 steps/bar; 4 steps/beat; fixed 4/4 | `MusicDefaults`; SPEC §4, §7.1, §20 |
| C natural minor; 124 BPM | `MusicDefaults`; DESIGN §2.1, §3.1 |
| Loop 1–8 whole bars, bar-aligned, within canvas | `LoopSpan`; SPEC §4 and brief; bar alignment is this slice's explicit implementation default |
| Plain simultaneous block chords, no randomization | SPEC §7.1; no pattern applies in this slice |
| Closest smooth voice leading | SPEC §7.1/§16; exact costs/register below |
| Ordered rule-based three-choice alternatives and next chords | SPEC §7.4; quality IDs/alternatives in JSON; functional rules below |

All register/cost tuning is in `VoicingConfiguration`: MIDI **36–84** inclusive
(C2–C6 with middle C = C4/MIDI 60), center **60**, maximum span **36** semitones.
For every quality, each pitch-class inversion is placed throughout the register.
Candidates include close position, drop-2 (second-highest note down an octave
for four or more notes), and open position (odd sorted ranks up an octave).
Extension intervals retain their identity in the vocabulary, while voicing
candidates fold pitch classes before constructing these shapes. No chord tone
is omitted. A slash bass that is not already lowest is added at the nearest
lower octave of that pitch class; the whole candidate must still fit the bounds.
Duplicate pitch arrays are removed; candidates sort lexicographically.

Path cost is the sum of each note's absolute distance from MIDI 60 (weight **1**)
plus transition semitone motion (weight **10**) plus **6** for each voice-count
difference. Transitions match ascending ranks, repeating the highest rank of
the shorter chord when counts differ. The optional preceding voicing adds the
same transition cost to the first layer. Equal costs keep the first candidate
and predecessor by their stable sorted indices. This is a global optimum over
the generated **linear** candidate path, not all possible MIDI voicings or a
cyclic last-to-first optimization. Rests do not reset harmonic continuity.
Candidate generation/DP allocate and run off-thread; hover latency has not been
measured on this Windows host or the iPad.

Existing-chord suggestions retain root/slash bass and use the first three
ordered vocabulary alternatives, excluding the current quality. For next chords,
root degrees 1/6 map to tonic, 2/4 to subdominant and 5/7 to dominant; other
degrees are borrowed. Here 6 is the major sixth or minor sixth by key mode,
and 7 is the leading tone. The rule provider ranks DOM → I, IV, vi/VI;
SUB → V, I, IV; otherwise IV, V, I. It uses major/minor sevenths for tonic/IV,
dominant seventh on V (including harmonic-minor borrowing), and the opposite
mode's seventh quality for vi/VI. These are transparent implementation rules,
not a claim that root-only function describes every harmonic interpretation.
The full All vocabulary remains available independently of these suggestions.
G7alt is represented by root, major third, minor seventh, b9, #9 and b13; its
perfect fifth is intentionally absent. This is one explicit altered voicing
definition, not automatic recognition of every possible altered collection.

## Event contract

Sample offsets are `Int64`, rounded nearest/away-from-zero from each absolute
grid boundary: `step * (sampleRate * 60 / BPM / 4)`. No rounded step or loop
duration is repeatedly added. Optional `cycleIndex` (default zero) compiles a
specific repetition off-thread: offsets subtract the rounded absolute origin,
and `originSample` exposes that origin. Adjacent cycles therefore share the
same rounded boundary, carrying fractional samples through changing integer
cycle lengths. Nonfinite/nonpositive inputs, negative cycle indices, integer
overflow, grid indices beyond Double's exact integer range and collapsed
positive note spans throw explicit errors.

Events sort by sample offset, **off before on**, ascending voice rank, pitch,
then progression region index. Region indices refer to the canonical ordered
progression; ranks refer to ascending stored pitches and are independent of
insertion order. Each chord has simultaneous note-ons and note-offs. Event
payloads do not carry reference-backed chord names/IDs. The containing Array
is an off-thread artifact, not a lock-free render handoff implementation.

The compiler emits one cycle with offsets from 0 through `sampleCount`
inclusive. Notes crossing either loop boundary are clipped to it, and sounding
notes are retriggered at zero. Process terminal note-offs **before** the next
cycle's zero note-ons. `noteOff` requests an envelope release; it does not
mandate a hard cut or remove release tails. Silent spans contain no events;
an empty loop still supplies its duration. Later transport must consume the
off-thread compiled successive cycle indices rather than blindly repeat the
rounded cycle-zero length. The XCTest suite checks 100 contiguous fractional
cycles against absolute boundary rounding. No scheduling or transport is
implemented here.

## Checks and remaining gate

On this Windows host, `Get-Command` / `where.exe` found no `swift`, `xcodebuild`
or `xcodegen`; standard Swift/Xcode install locations were absent. Python is
3.11.16. No machine-wide installation was attempted. Native Swift compilation,
XCTest, XcodeGen generation, simulator launch, archive and IPA creation could
not run locally. No Python copy of the music algorithms was used as evidence.

Actual feasible checks:

- `python -m unittest discover -s Tests/Scaffold -p 'test_*.py' -v`: all **13**
  existing scaffold/package tests pass. The package tests use fixtures; their
  output is not a new app archive or installable IPA.
- JSON/YAML structural validation: vocabulary metadata/reference integrity,
  source paths, target dependencies, narrowly declared resources and test scheme
  wiring: **passed**. Six module source files import only Foundation; all 23
  XCTest methods are present. This does not establish native compilation.
- `git diff --check`: clean (only Git line-ending notices).

Hermes can review the diff, then on the pinned Mac toolchain run:

```sh
xcodegen generate --spec project.yml
xcodebuild test -project coda.xcodeproj -scheme CodaMusic \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.2' \
  CODE_SIGNING_ALLOWED=NO
xcodebuild test -project coda.xcodeproj -scheme coda \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.2' \
  CODE_SIGNING_ALLOWED=NO
```

Native compile/test and resource-bundle behavior remain unverified until that
reviewed execution. The existing archive/package workflow is preserved for
Hermes; it was not triggered. No staging, commits or pushes were performed.
No CI success, audio quality, Pencil/hardware behavior, installable new IPA,
full M1 completion or owner acceptance is claimed.
