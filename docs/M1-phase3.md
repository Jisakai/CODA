# M1 phase 3 — native audio and transport review

Implements only `docs/briefs/M1-phase3.md`, under SPEC §§4–7.2, 7.4,
12–13.7, 16 and 20.11. Full M1 remains incomplete. Physical installation,
latency, long listening, gesture feel and owner acceptance remain deferred to
full M1. No visible editor or demonstration progression was added.

## Changed paths

- `Sources/CodaTransport/include/coda_transport.h`, `include/module.modulemap`,
  `include/CodaAudioAdapter.h`, `coda_transport.cpp`, `RenderGate.h`,
  `CodaAudioAdapter.mm`: POD publication, production scheduler, lifetime gate
  and actual AVAudioSourceNode/AVAudioEngine adapter.
- `Sources/CodaSession/MusicSession.swift`: MainActor observable session,
  actual music editor/compiler/solver/suggestion integration and retry policy.
- `Sources/CodaMusic/NoteEventCompiler.swift`: retains each exact integer grid
  boundary alongside its existing sample offset. Existing event sorting,
  compilation and cycle behavior remain intact.
- `Sources/CodaApp/CodaApp.swift`: owns an initially empty, inactive session;
  background/disconnect suspend it. Audio notifications are owned by the active
  MusicSession lifecycle. Canvas body unchanged.
- `Tests/CodaTransportTests/transport_tests.cpp`, `allocation_hooks.h`:
  production portable tests and thread-local C++ allocation hooks (same hook
  forms as approved DSP tests; no musical/DSP replica).
- `Tests/CodaAudioTests/AudioAdapterTests.mm`, `MusicSessionTests.swift`:
  actual offline engine/source-node and Swift compiler/session integration.
- `Tests/CodaMusicTests/NoteEventCompilerTests.swift`: asserts exact retained
  grid offsets against the existing boundary fixture.
- `project.yml`: static CodaNative/CodaSession modules and CodaAudioTests,
  explicit public headers/module map, AVFoundation/C++ linkage and scheme.
- `.github/workflows/unsigned-ipa.yml`: new portable normal/sanitized transport
  step and explicit XCTest timeouts; no workflow was triggered.
- This report.

Other working-tree changes, including task/roadmap/phase2 documentation and
untracked briefs, fonts and personal notes, belong to the surrounding session
and were not edited by this implementation.

## Ownership, publication and bounded work

Swift owns transient `NativePlan` heap storage with deterministic deinitialization.
The real NoteEventCompiler runs on the control actor, never on render. Its POD
events include exact integer grid boundaries, ranks and region indices.
`publishPlan` synchronously validates and copies the POD into native storage;
no Swift array, temporary buffer pointer or reference-backed event escapes.

Four native slots are allocated at creation. Monotonic uint32 head/tail counters
use release/acquire publication. The consumer retains slot `tail-1` as its active
immutable plan. The producer admits only when `head-(tail ? tail-1 : 0)<3`:
this conservatively leaves a spare slot, allows three initial pending snapshots,
and subsequently an active snapshot plus two pending snapshots. Render chooses
the newest published snapshot and never plays superseded queued snapshots.
It reads the old plan's timing before releasing the old slot, installs the new
active index, then release-stores tail. Only after acquire-observing that tail
may the producer overwrite retired slots. `acknowledged` is the diagnostic
retirement watermark; slots are reused rather than freed. No render reclamation,
allocation, deallocation or reference counting occurs. Counter exhaustion returns
full; a quiescent reprepare resets the publication epoch.

The adapter's producer mutex serializes every control caller, publication and
lifecycle method. Render never acquires it. Native plans, controls and audition
use separate bounded SPSC handoffs, but **only render calls the DSP event/control
producer APIs**. Thus the approved core still has exactly one producer and one
consumer, with no overlapping producer operations. Scheduler publication and
consumption happen sequentially on the same native render thread.

DSP is prepared with a one-sample maximum block. The outer callback accepts
arbitrary frame counts; for each sample the scheduler publishes that sample's
complete group before processing it. It never queues future notes, so replacing
a plan cannot leave obsolete future onsets in the DSP FIFO. At most 12 held offs
plus 12 replacement ons occur at one sample: **24 < 32**, and **24 < 1023** usable
event slots. Plan validation enforces contiguous sorted ranks, distinct ascending
pitches, one region per onset group, unique region indices, no overlapping
regions, matching offs, ordering, bounds and terminal release. A validation pass
and fixed plan copy run on control only. Reconstruction after a transition scans
at most 3072 events; per-sample ordinary scheduling scans only the due group.
These bounds are explicit; one-sample DSP processing and bounded reconstruction
still need native performance measurement on iPad.

Controls have seven usable native slots and at most seven are forwarded before
the callback's first DSP sample, which drains them within its eight-pop bound.
Rejected full/invalid/unprepared operations return 0/-1 without partial admission.
The Swift facade retains the latest unpublished plan; up to 64 pending control
snapshots retain preset/mute edges. Only consecutive equal-preset/equal-mute
continuous changes coalesce. A 2 ms control Task retries full queues; this Task
does **not** schedule notes or loop boundaries. Capacity errors are thrown;
native invalid publications/failure counters become observable error strings.
Audition has one outstanding native command and reports full for caller retry.

Atomic status fields are observational and may span adjacent callback snapshots;
they do not expose live DSP/voice memory and never drive note timing. Playback
revision and rendered playing are one atomic pair. `playing` reflects an explicit
request immediately, then `status()` reconciles it only when render acknowledges
that same revision. `renderedPlaying` records the observed native result. The
separate private command value is never derived from observational status.

## Timing and transitions

For each event the scheduler computes
`round((cycle * loopLengthSteps + eventStep) * samplesPerStep)` with positive
nearest rounding, rather than adding a rounded cycle duration. This is the same
absolute-grid convention as NoteEventCompiler. No Swift refill is required for
ordinary looping within the supported identity lifetime. Loop-end held offs precede the next cycle's ons at
the same sample. The engine/DSP does not reset at wrap: releases and shared FX
continue. Empty spans emit nothing; empty loops remain silent from fresh state.
Nonloop end releases all held notes and stops scheduling while tails decay.

Native monotonic region IDs survive plan swaps, seeks and auditions. Each new
harmonic onset gets a fresh ID; offsets/region indices from a retired plan cannot
release a replacement. Before identity exhaustion, looping ends with releases;
a subsequent safe reprepare starts a new epoch. No identity wraps silently.

Pause releases held notes but freezes the exact native sample position; resume
reconstructs the chord there. Identical-tempo/length plan changes retain the exact
cycle and sample position, preserving fractional carry through edits/pause.
Restart/stop explicitly seek to zero. Scrub seeks use integer grid steps; seek
while paused changes only position. Tempo changes retain the fractional musical
position, start a new absolute timing epoch, and round its new sample position
once. Loop-bound/toggle changes are configuration snapshots: they retain position
modulo the new span rather than manufacture a seek or Play command.
Nonloop mode uses the entire canvas. Playback plans replace at the next native
sample after publication, including during an irregular callback.

Every replacement releases the old held notes, then reconstructs the currently
sounding chord; DSP envelope releases, voice stealing fades, preset retention
and existing 12 ms control/mute smoothing provide continuity. No DSP reset or
FX clearing is added at those transitions. Knob/control changes publish controls
without rebuilding/restarting transport. Preset and mute policies remain those
of the approved production DSP.

Audition uses the same synth and shared FX. It temporarily releases/replaces the
transport's held chord while musical time continues, then releases the preview
and reconstructs the chord at the current musical position. This avoids a second
synth/FX chain and conflicting simultaneous region identities. Default preview
duration is 0.8 s, bounded natively to ten seconds. Zero pitches cancels preview.
A plan replacement cancels an active audition. Region/candidate audition uses
the existing editor/solver and never changes undo/redo. This replacement policy
is an explicit provisional feel choice for Hermes/owner review, not an assertion
of listening acceptance.

## Lifecycle proof and framework boundary

The Objective-C++ source block captures a native shared gate, **not** the adapter,
Swift session, engine or UI. C++ shared ownership is copied during block creation
and framework block lifetime management, not during invocation. Inside the block
there is no ObjC messaging, Swift call, shared_ptr copy, heap operation, lock,
wait, dispatch, log, parsing or I/O. It calls the gate and production native
renderer on framework-owned mono Float32 storage; malformed output layouts return
an OSStatus error. Closed callbacks write silence.

`RenderGate` combines a closed bit and active-reader count in one lock-free atomic.
Entry makes one bounded CAS from zero to one. Concurrent/closing entry returns
silence without retrying. Close atomically latches closed, then waits **only on
control** until the active reader has released its claim. Holding the producer
mutex through close also excludes every producer. Only after BOTH quiescences
does the adapter stop/detach the engine, destroy DSP/plan storage and clear its
gate pointer. Already-retained framework blocks keep closed gate storage alive;
future invocations cannot reach destroyed transport. Engine pause/stop is never
treated as a join. Reopening creates a fresh engine/gate/core and recompiles the
progression at the actual output format. No in-place live prepare is performed.

Audio session setup uses output-only Playback/Default; no input node, recording,
microphone permission or special entitlement. Startup failures throw and leave
available=false. Background, interruption-began, relevant route changes and actual
engine invalidation suspend rather than automatically restarting audio. Observers
register after startup, session notifications filter the shared audio session,
and engine notifications filter this adapter's engine identity. Category-change,
unknown/missing route reasons and interruption-ended do not suspend. A config
notification only suspends if the owned engine is stopped or its output rate no
longer matches preparation; a delayed startup notification with a running,
matching-rate engine is harmless. Old observer callbacks carry a retired epoch
and cannot close a replacement adapter. Observer tokens are removed before close
and on owner destruction. The next explicit play reopens/prepares/recompiles at
the actual sample rate. This conservative resume-at-start policy remains
provisional and observable. Notifications enqueue a MainActor Task: engine
teardown does not execute in Apple's internal configuration-notification callback.
Session deactivation and full render/producer quiescence remain outside render.

The audited boundary ends at our block body and production DSP/scheduler. Apple
invokes/manages the block and engine graph; framework-internal allocations,
block ownership operations, conversion/mixer behavior and hardware driver work
have not been audited or proven allocation-free. Portable hooks instrument C++
new/new[] (including aligned/nothrow forms) and deletes in our render work, not
arbitrary malloc calls or AVFoundation internals. No broader claim is made.

## Defaults for Hermes to log

Existing defaults remain C natural minor, 124 BPM, eight empty bars, 16 steps/bar,
fixed 4/4, whole-bar loops and exactly three approved presets. New bounds are in
`coda_transport.h`/native implementation and `TransportConfiguration`:
3072 events (128 one-step regions × 12 pitches × on/off), four native plan slots
with the conservative occupancy rule above, seven native controls, 64 facade
pending controls, 2 ms retry, 0.8 s audition, ten-second native audition bound.
AV offline checks use 48 kHz/512-frame blocks and cap a request at ten seconds.
Publication latency is the next render sample, plus any observable producer
backpressure/control retry; no physical output latency is claimed. Native status
refresh is caller-driven and not a note scheduler. Lifecycle resume policy,
loop-change position remapping and audition replacement are proposed implementation choices.

## Tests and actual evidence

Prepared portable production tests cover exact event hashes (offset, ID, kind)
over 80 fractional wraps at block sizes 1/17/257/1024; terminal off-before-on;
pause/resume/seek/restart; active plan replacement and superseded-plan skipping;
empty replacement/fresh silence; audition restoration; nonloop end; full/recovery
of plan/control/audition handoffs; malformed/oversized/unsorted plans; dense
3072-event plans; rapid preset/mute controls; one concurrent producer/render;
safe retired-slot reuse; prepare failure/recovery; 8/44.1/48/96/384 kHz reprepare;
and the exact production gate's in-flight reader exclusion/join. New/delete hooks
are calibrated through nonelidable explicit function calls and enabled on the
render consumer only. A 110-second watchdog gives a deterministic timeout.

Prepared XCTest exercises actual AVAudioEngine offline rendering through the
production source block, finite nonzero audio, exact delivery/no-late diagnostics,
repeated close/open and fresh silence. Swift integration uses actual vocabulary,
ProgressionEditor, compiler, solver, transport and engine, including audition
history preservation, tempo/seek/pause, undo/redo and restart. Tests do not rely
on sleeps to establish note timing. Existing production DSP and music tests are
preserved. CI XCTest timeout allowances are 60/120 seconds; transport step timeout
is six minutes. Artifacts remain the existing explicit IPA/text allowlist; no
new WAV, broad workspace or large artifacts.

Actual local commands/results on this Windows execution:

- `Get-Command clang++,g++,cl,swift,xcodebuild,xcodegen,python -ErrorAction SilentlyContinue`:
  only Python found. No tool installation attempted.
- `python -m unittest discover -s Tests/Scaffold -p 'test_*.py' -v`: **13 passed**.
  Packaging output is fixture evidence, not a new app archive.
- PyYAML parsed project/workflow; declared source paths, target dependencies,
  audio test scheme and unchanged xcode-27/Xcode27.2 pins verified.
- `git diff --check`: passed; only Git line-ending notices.
- Primary Apple documentation JSON fetched successfully with Python urllib;
  PowerShell Invoke-WebRequest initially failed TLS. No credentials/config used.

**No new C++/Swift/ObjC++ compilation, native test, sanitizer, simulator, device
archive, IPA or listening result is claimed.** Hermes reports prior phase2
production DSP + ASan/UBSan passed run 45618129186; that is baseline evidence,
not verification of this uncompiled phase3 diff. Native module exposure, Swift 6
import/isolation, source-node format behavior, runtime teardown and performance
must pass reviewed Mac CI. LeakSanitizer remains intentionally disabled on Apple;
this does not test leaks. Owner iPad listening/installation remains deferred.

## Exact native review invocation (not executed here)

Use pinned standard xcode-27 / Xcode 27.2 / SDK 27.2. The unchanged existing DSP
normal/sanitized commands also remain mandatory in the workflow.

```sh
mkdir -p build/generated/transport
clang++ -std=c++20 -O2 -Wall -Wextra -pthread \
  -I CodaDSP/include -I Sources/CodaTransport/include -I Sources/CodaTransport \
  CodaDSP/src/coda_dsp.cpp Sources/CodaTransport/coda_transport.cpp \
  Tests/CodaTransportTests/transport_tests.cpp -o build/generated/transport/transport_tests
build/generated/transport/transport_tests
clang++ -std=c++20 -O1 -g -Wall -Wextra -pthread \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I CodaDSP/include -I Sources/CodaTransport/include -I Sources/CodaTransport \
  CodaDSP/src/coda_dsp.cpp Sources/CodaTransport/coda_transport.cpp \
  Tests/CodaTransportTests/transport_tests.cpp -o build/generated/transport/transport_tests_sanitized
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  build/generated/transport/transport_tests_sanitized
xcodegen generate --spec project.yml
xcodebuild test -project coda.xcodeproj -scheme coda \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.2' \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 120 CODE_SIGNING_ALLOWED=NO
xcodebuild archive -project coda.xcodeproj -scheme coda \
  -destination 'generic/platform=iOS' -archivePath build/coda.xcarchive CODE_SIGNING_ALLOWED=NO
python3 scripts/package_ipa.py --archive build/coda.xcarchive --output-dir build/artifacts \
  --xcode-version 27.2 --ios-sdk-version 27.2 --xcodegen-version "$(xcodegen --version)"
```

## Apple primary sources actually inspected

Fetched Apple's DocC JSON, including Objective-C declaration variants, for:

- [AVAudioSourceNodeRenderBlock](https://developer.apple.com/documentation/avfaudio/avaudiosourcenoderenderblock):
  silence pointer, const AudioTimeStamp pointer, frame count, AudioBufferList,
  OSStatus; error marks output invalid.
- [Source-node format/render initializer](https://developer.apple.com/documentation/avfaudio/avaudiosourcenode/init(format:renderblock:)):
  `initWithFormat:renderBlock:`, PCM conversion/connection format and real-time
  callback constraints.
- [Engine start](https://developer.apple.com/documentation/avfaudio/avaudioengine/start())
  and [stop](https://developer.apple.com/documentation/avfaudio/avaudioengine/stop()):
  start failure modes; stop resource behavior, without an asserted callback join.
- [Enable manual rendering](https://developer.apple.com/documentation/avfaudio/avaudioengine/enablemanualrenderingmode(_:format:maximumframecount:))
  and [render offline](https://developer.apple.com/documentation/avfaudio/avaudioengine/renderoffline(_:to:)):
  stopped-engine setup, PCM buffer match, `renderOffline:toBuffer:error:` and status/frameLength.
- [Engine configuration notification](https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchangenotification):
  hardware format changes stop/uninitialize engine; explicitly warns against
  deallocating engine inside its internal notification handler.
- [Session category/mode/options](https://developer.apple.com/documentation/avfaudio/avaudiosession/setcategory(_:mode:options:)),
  [route change](https://developer.apple.com/documentation/avfaudio/avaudiosession/routechangenotification)
  and [interruption](https://developer.apple.com/documentation/avfaudio/avaudiosession/interruptionnotification):
  control-side session setup and notification thread/lifecycle semantics.

Stop for Hermes diff/native review. No staging, commit, push, CI trigger,
installation, credential/configuration read, visible editor, next slice or full
M1 acceptance occurred in this execution.


## Correction pass1 ? independent review response

Applied only `docs/briefs/M1-phase3-review-fixes.md`. Paths changed in this pass:

- `Sources/CodaSession/MusicSession.swift`: split fallible plan preparation from
  nonthrowing intent/pending-plan commit. Tempo prepares the plan and preflights
  control validation/capacity before changing tempo or controls. Loop and
  play/pause/stop/restart prepare before changing intent. Edits/undo/redo prepare
  before committing editor/history and publish afterward. Latest pending plan,
  continuous-control coalescing and FIFO preset/mute edges remain intact; no
  audio reset was added. Startup prepares before start/available, preserves
  unpublished control edges on failure, and avoids duplicating the final edge.
  Strictly ascending/unique audition pitches are checked before lazy activation.
  Native voice capacity is checked before edits/history even while inactive.
  Lifecycle routing now lives alongside the owning adapter and epoch.
- `Sources/CodaApp/CodaApp.swift`: removed blanket, object-unfiltered audio
  observers; retained background/disconnect suspension and unchanged canvas.
- `Sources/CodaTransport/include/CodaAudioAdapter.h` and
  `Sources/CodaTransport/CodaAudioAdapter.mm`: control-only engine identity and
  actual configuration-invalidation queries under the existing producer mutex.
  Gate closure, render/producer joins, teardown and render callback are unchanged.
- `Tests/CodaAudioTests/MusicSessionTests.swift`: production facade/offline-engine
  regressions detailed below; no mock facade or renderer.
- `Tests/CodaTransportTests/transport_tests.cpp`: exact endpoint/audition tests
  against the production core, with existing render allocation hooks enabled.
- `docs/M1-phase3.md`: this review evidence and revised lifecycle description.

No scheduler, endpoint logic, DSP, tuning, UI, configuration, spec, design, brief,
status or unrelated files were edited in this pass. Session/vocabulary `try?`
boot initialization remains the known quiet-error work for the upcoming UI slice.

### Failure reachability and transactions

The public facade has a fixed validated 128-step canvas. Every constructible
LoopSpan ends within 128, so setLoop's out-of-canvas error is structurally
unreachable through the current session API. After native voice-capacity checks,
validated public music data admits at most 128 nonoverlapping one-step regions,
12 pitches/region and 3072 events; all native indices fit. At the adapter's
8?384 kHz and facade's 30?300 BPM bounds, samples/step is 400?192000 and compiler
timing cannot overflow at cycle zero. Those bounds explain why a forced compiler
failure inside a valid tempo/loop/play request would require a fake injection.
No such injection or artificial invalid LoopSpan test was added. Preparation
still precedes intent commit so future throwing preparation remains exception-safe.

A full facade control queue can reject a new preset/mute edge. Tempo always keeps
the current preset/mute and therefore coalesces with its matching last pending
edge, including at full capacity. The real 64-edge capacity test verifies a
rejected distinct edge leaves controls unchanged and tempo still coalesces.
CodaMusic itself permits more than twelve pitches with matching pitch classes;
this is a real reachable production capacity failure. Tests use a valid 16-pitch
minor7 region to prove failed edits preserve progression, undo/redo and the
latest unpublished transport request, both active and inactive. No failed setter
publishes controls/plan or overwrites pending intent before its fallible work.
Native full returns still retain the latest plan for retry; unexpected native
rejection remains an observable error, as before.

### Prepared regression conditions (native execution pending)

- Nonloop endpoints use samples/step 400.02 and 400.04: 16-step ends round down
  from 6400.32 and up from 6400.64. At blocks 1/17/257/1024, two adjacent 12-note
  regions assert the exact sample/kind/region hash, the middle off-before-on
  order, 36 events immediately before end, 48 after the endpoint sample, stopped
  playing, unchanged region IDs/hash/count during further rendering, and zero
  admission/late errors. Existing endpoint release was correct; no core fix.
- At both rounded ends, a 12-note audition starts three samples before end and
  (a) expires three samples after end, (b) expires exactly at end, or (c) is
  canceled by same-timing nonloop plan replacement exactly at end. Exact hashes
  assert the transport chord is released/replaced with 24 events at audition
  start, independent preview expiry/cancellation releases exactly once, no
  stopped transport restoration, 72 total events and only three region IDs.
  Further rendering adds no events. All use production admission checks and
  allocation hooks. The documented finite audition policy was correct; no core fix.
- Facade tests fill the native plan handoff, supersede the retained latest plan,
  reject invalid tempo/seek/controls/edit batches and actual over-voice edits,
  then render/pump the real engine and verify retained seek intent, exact event
  count, unchanged history/controls and no errors. Undo/failed edit/redo checks
  prove rejection preserves redo. Invalid duplicate/unsorted/out-of-range
  auditions are rejected before activation. Actual offline rendering also covers
  successful tempo/loop changes and pause/play/stop/restart; knob changes advance
  the same native clock without retriggering notes or resetting DSP.
- Deterministic lifecycle tests directly invoke the same MainActor router used
  by observer Tasks, with actual offline adapters: category-change, ended,
  missing/unknown reason and running-engine config notifications are ignored;
  began and all six selected route reasons suspend; ended never restarts;
  retired epochs cannot suspend a reopened engine. The actual owned AVAudioEngine
  is stopped before testing configuration invalidation. Tests use no sleeps and
  do not claim hardware route/startup-notification timing is proven. Object
  filtering uses NotificationCenter's explicit owner filter at registration.

### Actual pass1 checks and limits

- `python -m unittest discover -s Tests/Scaffold -p 'test_*.py' -v`: **13 passed**.
  IPA output is packaging-fixture evidence only.
- `Get-Command clang++,g++,cl,swift,xcodebuild,xcodegen,python -ErrorAction SilentlyContinue`:
  only Python found. No native compiler or Xcode execution, installs or CI trigger.
- `git diff --check` plus explicit trailing-whitespace/conflict-marker checks of
  all seven pass1 paths (including untracked phase3 files): passed.
- Attempted primary Apple DocC JSON refresh with Python urllib for
  `AVAudioSession.RouteChangeReason`; blocked by host network policy
  (`WinError 10013`). No fresh Apple-doc fetch is claimed for pass1. Existing
  previously inspected primary sources above remain the reference. Routing uses
  established AVAudioSession reason/type enums and AVAudioEngine `isRunning` /
  output-format queries, with no new speculative Apple API. Relevant references:
  [route reasons](https://developer.apple.com/documentation/avfaudio/avaudiosession/routechangereason),
  [interruption types](https://developer.apple.com/documentation/avfaudio/avaudiosession/interruptiontype),
  and [engine configuration notification](https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchangenotification).

Normal production transport, ASan/UBSan, actual AV offline XCTest, Swift 6/native
interop compilation and hardware startup/route verification remain pending Mac
execution. Keep the exact reviewed native invocations above; no new build,
archive, IPA, sanitizer, simulator or listening result is asserted. Stop here for
Hermes re-review; no staging, commits, pushes, CI/config reads, installs, UI or
later-milestone work.


## Correction pass2 - durable transport intent

Executed only `docs/briefs/M1-phase3-review-fixes-pass2.md`. Exact changed paths:
`Sources/CodaSession/MusicSession.swift`,
`Sources/CodaTransport/include/coda_transport.h`,
`Sources/CodaTransport/coda_transport.cpp`,
`Tests/CodaTransportTests/transport_tests.cpp`,
`Tests/CodaAudioTests/MusicSessionTests.swift`,
`Tests/CodaAudioTests/AudioAdapterTests.mm`, and `docs/M1-phase3.md`.

Each immutable POD snapshot now carries independent cumulative playback and
position revisions. Only explicit playback/position requests advance them; the
latest values travel through every later snapshot, including replacement of a
queue-full facade pending plan. The newest native plan consumes each revision
once. Stop supplies paused plus position zero, Play supplies playback only,
Restart supplies playback plus zero, and later seeks replace earlier positions.
Configuration cannot revive naturally completed playback. Native completion is
retained through tempo/span remapping; explicit Play after completion starts at
zero unless a newer explicit position supplies the start. Pause/resume with
unchanged timing retains the exact sample and fractional cycle carry. Existing
slot ownership, exclusive render event production, endpoint release, finite
independent audition expiry and 24-events/sample bound remain in place. No render
allocation, lock, wait, command queue or producer scheduling from status was added.

Playback revisions are bounded by INT64_MAX so native status can atomically
publish revision plus playing in one lock-free uint64. Position revisions use
UINT64_MAX. Facade exhaustion throws capacity before any mutation/publication;
configuration still works without incrementing. Commands never wrap. Explicit
suspension clears commands/position and reopening creates a fresh native epoch,
retaining the existing conservative resume-at-start policy. An inactive scrub
after launch or suspension persists in `requestedStep` without opening hardware;
activation seeds the fresh core from that retained span-relative position.
Startup failure preserves retained commands for retry. A retained seek outside a
subsequently shortened span clamps to its last step when first consumed.

`status()` updates public playing after natural completion only if the atomic
render acknowledgment matches the latest explicit playback revision. A stale
observation cannot cancel an unapplied Play. The private playback command value
stays independent of status. Configuration setters still prepare and validate
before committing state, intent revisions, history, controls or pending plans.

Prepared production regressions (not executed on this Windows host):

- Portable native tests: nonloop completion then tempo does not restart; explicit
  Play after end; Stop then Play without render; seek then tempo/event edit;
  multiple seeks last wins; consumed seeks do not replay; fresh native epoch;
  maximum revisions and invalid playback overflow; exact fractional pause/resume
  across five cycles and unchanged configuration. Existing exact boundary hashes,
  off-before-on, audition expiry, queue pressure and render new/delete hooks remain.
- Actual Swift facade + offline AVAudioEngine: full eight-bar nonloop playback
  with an opening chord, completion/status/tempo and completion/tempo without
  polling, explicit Play protected against stale status, inactive scrub through
  edit/tempo/activation, Stop->Play, seek->tempo/edit, multiple seeks, consumed seek,
  Restart/seek ordering, suspend/reopen, substep pause/config/resume, and full
  native queue plus repeated facade pending-plan replacement for Stop and Seek.
  Invalid tempo must leave the retained request intact. Native adapter fixtures
  now declare explicit initial playback revision. No replacement renderer is used.

Actual local pass2 checks:

- `python -m unittest discover -s Tests/Scaffold -p 'test_*.py' -v`: 13 passed;
  packaging output is fixture evidence only.
- PyYAML parsed project/workflow; all 21 declared source paths, target
  dependencies, audio test scheme and native module-map path passed checks.
- `git diff --check`: passed. An explicit worktree whitespace/EOF/conflict scan
  passed across all 24 changed tracked paths, including files added in the index.
  The allocation_hooks.h worktree EOF cleanup is preserved.
- `git diff --cached --check`: reports the pre-existing extra final empty line
  at `Tests/CodaTransportTests/allocation_hooks.h:34` in the index. The index still
  contains the older version; no staging was performed to replace it. Hermes must
  review/use the cleaned worktree version when handling the index.

Only Python was discovered by the compiler/tool availability check; no C++, Swift,
ObjC++, sanitizer, simulator or AV test execution is claimed. Those checks remain
pending on Mac with the reviewed commands above. No UI, DSP tuning, index writes,
commit, push, CI trigger, install, personal configuration read or later milestone
work. Stop for Hermes re-review; further blockers must be reported to Hermes.
