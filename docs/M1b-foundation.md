# M1b bounded foundation: model, editor and independent compiler

Implemented November 26, 2026 for Hermes review. The earlier model/editor slice
is preserved. The subsequent bounded compiler execution adds only
`Sources/CodaMusic/PatternEventCompiler.swift`,
`Tests/CodaMusicTests/PatternEventCompilerTests.swift`,
`Tests/CodaMusicTests/PatternEventCompilerAdversarialTests.swift`, and localized
updates to this report. Existing production APIs/assertions, model/editor files,
native/session/UI code, project configuration, four dirty planning files and
unrelated untracked files are preserved.

Behavior sources: SPEC §8/§13/§16/§20, DESIGN §3.7, the latest owner ten-level
arrow decision, and `docs/briefs/M1b-foundation.md`. The owner-reported exact-head
radial gate is treated as satisfied; this execution does not independently claim
that prior run or its pixel review. No physical acceptance is claimed.

## Production API and invariants

- `ArrowLevel`: validated integer `value` in 1...10. `normalizedLength` and
  `baseVelocity` derive from the identical `value / 10`; `readout` is v10...v100.
  `from(normalizedLength:)` returns nil for finite values <=0, otherwise rounds
  tenths nearest/halfway-away and clamps to 1...10. It clamps above 1 before
  multiplication/Int conversion. Tiny positive finite input yields level1;
  greatestFiniteMagnitude yields level10; nonfinite input throws. There is no
  MIDI127 round trip or height multiplier.
- `ChuckSize`: finite continuous (0,1], with base velocity equal to size,
  including tiny positives. `PatternStroke.Content` holds an arrow direction
  and validated level, or a validated chuck size. `PatternStroke` adds a
  nonempty caller-supplied ID. Content changes retain that ID in the editor.
- `PatternBarRange`: absolute half-open start/length bars; nonnegative start,
  positive length, checked addition and canvas upper bound. `PatternRegion`
  has immutable range, settings and exactly eight optional slots repeated each
  bar. Empty slots are retained as nil; an all-empty region still exists.
- `PatternArrangement`: immutable validated barCount in 1...8, sorted regions,
  no overlaps, ranges within barCount, globally unique region IDs and globally
  unique occupied stroke IDs. The two namespaces are separate. Gaps and
  touching half-open boundaries are legal. Chord identity is independent.
- `PatternScope.resolve(loop:barCount:)`: the ONE scope default is
  `PatternDefaults.defaultScope = .wholeLoop`. Divide existing validated
  LoopSpan grid-step start/length by16 and validate absolute arrangement bars.
  A start32/two-bar loop resolves to [2,4), never [0,2).
- `PatternPreset`: reusable eight-slot content data. `popRock` is
  D,empty,D,U,empty,U,D,U at level8. `instantiate` requires six explicit
  nonempty unique IDs in occupied-slot order. Arrangement admission validates
  freshness against other regions. No random IDs or resource dependency.
- `PatternEdit`/`PatternEditor`: add/delete/resize, settings, set/remove stroke,
  duplicate, and arrangement bar-count edits. `preview` constructs and validates
  the final candidate without history; `apply` commits that same path as one
  undo step. Intermediate overlaps and temporary arrangement-dimension mismatch
  are permitted. Individual values remain validated. Failed and no-op batches
  preserve state, undo and redo; a real edit clears redo. Undo/redo restores the
  complete immutable arrangement. Existing slots require nil `newStrokeID` and
  retain their ID; empty slots require an explicit new ID. Duplicate requires
  an explicit fresh region ID and fresh occupied-stroke IDs, checked against the
  working candidate even if a later edit deletes the source. Preview/commit
  results are canonical sorted arrangements, so input order alone is a no-op.

For later length input integration, call `ArrowLevel.from(normalizedLength:)`;
nil maps to `removeStroke`, otherwise pass `.arrow(direction:level:)` through
`setStroke`. This keeps absence out of audible stroke values.

## Centralized provisional defaults

All tunables live in `PatternDefaults`; settings validate finite swing0...1 and
spread0...60ms. These are implementation defaults for Hermes to log after
review, not new owner sound decisions or listening acceptance.

| Setting | Contract/default |
| --- | --- |
| Scope | wholeLoop, resolved explicitly at application time |
| Slots / preset magnitude | eight eighths per bar / level8 |
| Swing | per pattern, initially0; maximum odd-eighth delay one sixteenth step |
| Humanize | Tight initially; Loose remains an independent setting |
| Spread | initially20ms, accepted0...60ms TOTAL first-to-last onset duration; singleton0 |
| Loose identity metadata | algorithm version1, explicit UInt64 seed initially0 |
| Loose timing | shared per stroke ±3ms |
| Loose per-note deltas | velocity±6/127, detune±3 cents, normalized filter±0.02 |
| Loose effective velocity | clamp0.01...1, without changing stored base velocity |
| Chuck | continuous size/base velocity; provisional total rake12ms, gate40ms |
| Uncovered block base | 0.8 |

The independent compiler now consumes these constants. Tight has exactly zero
variation, including tiny-positive chuck velocity. These are compiler payloads,
not executed DSP or listening acceptance.

## Independent compiler contract

`PatternEventCompiler.compile(_:arrangement:tempo:sampleRate:loop:cycleIndex:)`
returns `PatternCompilation.legacy(CompiledLoop)` or
`.pattern(CompiledPatternLoop)`. Checked arrangement/progression dimension
equality is the FIRST operation and throws `PatternCompilerError.dimensionMismatch`
before tempo/rate/span/cycle errors. Matching dimensions with no intersecting
pattern range delegate directly to the unchanged `NoteEventCompiler.compile`;
there is no re-creation, retiming or extra capacity validation of legacy output.
Applied all-empty coverage takes the pattern branch and suppresses attacks.

Pattern output contains immutable events, harmonic/occurrence metadata, cycle
index, origin/count and Loose algorithm version. Three separate nonzero UInt16
token types identify harmonic regions, nominal stroke occurrences and exact note
instances. Checked allocation never wraps. Tokens are LOCAL to this one compiled
cycle, and may repeat in the next result. They are NOT runtime generations.
Slice2 MUST qualify ownership with nonwrapping prepare epoch, plan generation,
cycle and local instance token; restore/audition require fresh runtime ownership.
Occurrence metadata retains clipped/cancelled/coalesced nominal occurrences;
only emitted event pairs identify audible retained instances.

Chord/coverage/loop intersections define disjoint half-open ownership intervals.
Absolute bar-local eighth anchors select the chord before any swing, shared
jitter or spread. Odd-step chord changes do not restart pattern phase. Early
jitter clamps to the ownership start; delayed ons at/past its end are omitted.
Empty slots neither attack nor stop held notes. Uncovered spans attack a
simultaneous unmodulated0.8 block at chord start or coverage exit. Entering
coverage clips that block and introduces no implicit attack.

Each onset is computed as one nearest-away rounding of absolute cycle time,
including swing/jitter/spread, followed by subtraction of the rounded cycle
origin. No adjustment is added to an already-rounded offset. Origin/count use
the legacy arithmetic and checked Int64/2^53 precision guard. Adjacent cycles
share the exact terminal/origin boundary. Invalid/nonfinite/overflowed or
collapsed timing is rejected, including a retained chuck gate rounding to zero.

Onset ordinal follows down/up rake order; ascending rank always follows sorted
harmonic pitches, including zero spread and sample ties. Expansion precomputes
chronological onsets and resolves same ownership, pitch and rounded-sample
collisions within each complete sample group before deriving that group's chuck
cancellation/damping. Latest nominal occurrence wins; ordinal then local
instance token break remaining ties. Superseded attacks never receive offs or
consume admission capacity. Reverse chronological same-pitch matching derives
one exact-instance off per retained attack, clipped to ownership, replacement,
chuck gate and the next chuck damping point. Offs precede ons at every tie;
remaining order is occurrence, ordinal, token. Capacity validation replays exact
instances and rejects rather than truncates:12 pitches/chord,3072 total events,
32 events/sample and12 held notes.

Chuck uses the continuous base size (including tiny positive Tight values),
12ms TOTAL low-to-high rake independent of ordinary spread, and40ms from each
adjusted onset. The first retained onset damps held instances once; earlier
strokes' pending ons at/after damping are cancelled. Later chucks likewise cancel
unfinished older chucks. A completely clipped chuck introduces no damping.

Loose version1 uses explicit length-delimited UTF-8 FNV-1a hashing with
little-endian UInt64 fields and per-channel SplitMix64 finalization. Inputs are
algorithm version, explicit seed, cycle, chord/pattern/stroke IDs, absolute bar,
slot and (for per-note channels) MIDI pitch. Timing is one shared stroke value;
velocity/detune/filter use independent note channels. Intentional wrapping exists
only in integer hash arithmetic. No Swift Hasher/global randomness seeds audio
variation. Tight and uncovered blocks bypass modulation/clamping entirely.

The compiler's production spread and capacity primitives have internal visibility
for focused tests. A singleton cannot pass the existing vocabulary/progression
validation (at least two pitch classes); its zero-spread rule is tested through
the actual production primitive. Similarly, disjoint validated ownership cannot
reach32 simultaneous events or13 held notes after pitch admission: exact/one-over
limits are tested through the production capacity primitive, plus actual flat
event admission/replay and the densest mixed compiler output. No model bypass,
Python compiler replica or weakened legacy assertion was introduced.

## Verification and remaining work

The earlier two model/editor XCTest classes exercise production APIs: all ten levels through
conversion, editing, stored drawing length, base velocity and percentage readout;
halfway ties, clamping, absence, nonfinite/extreme inputs; continuous chuck;
range overflow, bar counts, half-open adjacency, overlap and arrangement bounds;
ID namespaces/collisions; eight-slot validation; exact reusable preset content;
absolute nonzero-loop scope; settings endpoints/defaults/metadata; preview,
final-state atomic edits, failed/no-op redo preservation, full undo/redo, explicit
fresh duplicate IDs and missing/invalid edit targets. These check the model's
render/base contract; they do not execute a renderer or playback compiler.

The two compiler test files contain26 real XCTest methods against production APIs:
dimension/error precedence and exact legacy equality, all-ten edit-to-compiler
bases, actual Pop Rock expansion, direction/rank/ordinal/spread, empty and mixed
coverage, odd chord changes/rests, collisions/latest winner/stale offs, chuck
pending cancellation/gates/clipping/continuous tiny velocity, swing, Loose
determinism/bounds/variation, 44.1/48/96kHz and awkward-BPM absolute rounding,
cycle boundaries/local token reuse, numeric overflow/2^53/collapsed timing,
capacity boundaries/one-over rejection and active-instance replay. The densest
mixed validated fixture expects2880 events with12 held and24/sample. Separate
production admission fixtures exercise3072 events and its one-over rejection.

Actual local results:

- `python -B -m unittest discover -s Tests/Scaffold -p "test_*.py" -v`:
  35 discovered, 34 passed, one existing symlink test skipped because creating
  symlinks is unavailable on this host. The package checks use fixtures; their
  output is not evidence of a real new IPA.
- `git diff --check` and `git diff --no-index --check -- /dev/null <file>`
  for the compiler, its two test files and this untracked report: no whitespace
  errors (no-index returns1 for new-file differences). Git emitted its existing
  LF-to-CRLF notices; no settings were changed.
- `Get-Command swift,xcodebuild,xcodegen -ErrorAction SilentlyContinue`:
  all three unavailable. The26 compiler XCTest methods and earlier16 model/editor
  methods have NOT been compiled or executed. No native pass is claimed.

Native Swift/XCTest, Xcode builds, sanitizers, simulator pixels and a new unsigned
device IPA are unexecuted on this Windows host. Existing XcodeGen directory
declarations include the new Swift files without project edits.

The bounded compiler implementation is ready for Hermes review. Swift type
checking/XCTest execution remain unresolved risks until the authorized native
review workflow runs; static inspection and Python scaffold checks do not replace
them. Native transport/session/DSP integration, gesture/UI work, new native/
sanitizer/pixel verification and reviewed exact-head independently verified real
unsigned DEVICE IPA remain outside this writer's slice. No contract conflict,
dependency, install, configuration, staging, commit, push or CI action was needed.
M1b is not delivered by this slice. Stop for Hermes review; do not start M2.

## Bounded compiler recovery review - November 26, 2026

Reviewed the actual compiler, both compiler XCTest files, model/editor APIs and
legacy compiler against the complete foundation contract. Found one behavioral
defect: chuck cutoff/damping was recorded before same-sample/pitch coalescing,
so an onset later superseded by an ordinary winner could damp held notes early.
The surgical correction resolves each sample group's collision winners before
selecting its retained chuck cutoff. Existing chronological ordering, persistent
pending-note cancellation, exact-instance offs and lifetime/admission checks
remain in place. No other static Swift API/expectation defect was identified;
this is not a substitute for native type checking or XCTest execution.

Added two production-API XCTest regressions in the adversarial compiler file:

- At100Hz/6000BPM, chuck candidates round to[1,1,1,2]; a later ordinary block
  supersedes all three sample1 candidates. Only pitch70 at sample2 remains a
  chuck, and all four ordinary notes must release at2. The prior implementation
  would leave three of those notes held until4 because it recorded damping at1.
- At2Hz/120BPM, the later ordinary block supersedes the entire chuck, including
  its collapsed gates. No chuck is emitted; the replacement block sustains to4.

These fixtures call the real compiler and replay its exact instance events; no
Python timing replica was used. They are written and statically inspected, but
cannot run on this host. The compiler test total is now26 methods.

Recovery checks rerun: full `python -B -m unittest discover -s Tests/Scaffold
-p 'test_*.py' -v` exited0:35 tests,34 passed,1 existing unavailable-symlink skip.
Tracked `git diff --check` and no-index new-file whitespace checks for the
compiler, both compiler test files and this report found no whitespace errors;
no-index exit1 denotes new-file differences. Git emitted LF-to-CRLF notices.
`Get-Command swift,xcodebuild,xcodegen -ErrorAction SilentlyContinue` found none.
Native Swift/XCTest, sanitizers and a real unsigned device IPA remain unverified.
This recovery changed only the compiler, adversarial tests and this report;
the four dirty planning files and unrelated content were preserved. No native,
session or UI work, stage/commit/push, configuration or authentication access was
performed. This execution stops at compiler finalization for Hermes review.
