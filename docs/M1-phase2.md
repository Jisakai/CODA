# M1 phase 2 DSP core ? corrective pass 2

Portable C++20 production core; no UI, AVFoundation adapter, transport or ML.
The API is `CodaDSP/include/coda_dsp.h`. Production envelope, EQ and hall units
are in `CodaDSP/include/dsp_units.h` and are tested directly, without algorithm
replicas. This slice does not complete M1.

## Lifecycle and runtime caller contract

Create/prepare/reset/stop/destroy run outside render. **Prepare, reset, stop and
destroy require BOTH render and the serialized producer to be fully quiescent**
(stop/join their work before calling). They must not overlap each other.
The future AV adapter must enforce this contract; the core cannot detect that
an external callback is still in flight. Stop immediately discards voices,
queued events/controls and effect state, and enters a stopped state: process
writes silence, publications fail. Reset/prepare resumes at sample zero.
Mute/fade before stop/reset if continuity matters. Stop does not let tails decay.

Prepare accepts 8,000?384,000 Hz and fixes the maximum block size. It allocates
2 s of delay, 3 s of four-channel FDN ring storage, 25 ms predelay storage and
matching generation tags. The two input diffusers use fixed 4096-cell arrays
in the DSP object. Process is one render consumer, with fixed voice/filter/FX
loops, at most eight control pops per block and 32 event pops per sample. No
render allocation, deallocation, bulk buffer clearing, lock or second consumer.
Generation invalidation clears only fixed filter state and advances tags;
64-bit generation wrap is outside the supported lifetime (reprepare first).

## Publication and admission

Exactly one serialized event/control producer; future transport serializes all
sources. Queues use release/acquire SPSC ownership; slots are reclaimed only by
the render consumer. Events use absolute sample offsets from reset, sorted
nondecreasing, offs before ons at a shared offset. Ranks must be 0?11 and are
sorted pitch ranks within a harmonic region. Simultaneous ons describe one
region; use distinct region IDs for new regions so stale offs remain harmless.

`coda_dsp_push_event` returns false for invalid kind/pitch/rank/negative offset,
descending offsets, off-after-on at a tie, a 33rd event at an offset, a full
queue (1023 usable slots), or stopped state. Failed admission changes neither
the queue nor producer ordering/count state. The same-offset count persists
across queue drains, so refill cannot circumvent the limit. Controls have
seven usable slots; full/invalid/stopped publications return false.

**Publish every event before the block containing its due sample starts.** Do
not refill an offset while its block is rendering. Late publication violates
the caller contract; render diagnostics count late executions, rather than
claiming the core can execute an event in the past. Every admitted group within
this contract fits the bounded 32-event budget without shifting its offset.
Rejected groups must be handled on the producer, never silently discarded by
an adapter. Diagnostics may be read on the consumer between process calls or
under full quiescence; concurrent reads of render state are prohibited.

## Voice and control policy

12 preallocated voice slots, one architecture, three preset data rows:

| Preset | Attack / decay / sustain / release | Default glide |
| --- | --- | --- |
| Pluck | 3 ms / 100 ms / 0 / 200 ms | 0 |
| Currents | 420 ms / 600 ms / 0.78 / 1.8 s | 0 |
| Wobble | 12 ms / 180 ms / 0.72 / 550 ms | 0.35 |

Each voice has explicit idle/attack/decay/sustain/release state. Attack and
decay use linear constant slopes; zero sustain ends at idle. Note-off captures
the current level once; linear release reaches zero after the configured
duration, including note-off during attack/decay. Repeated offs do not restart
release. Shape scales attack/release 0.5?2x, smoothed with other continuous
controls over 12 ms; it changes rates without restarting stage/progress.

An active voice retains its onset preset's oscillator/ADSR data through release.
Preset selection fades the shared output down/up over 12 ms per leg, changes
shared inserts/detune base at zero, and gives later onsets the selected preset.
Existing voices keep their envelope stages. Mac listening still must judge
this explicit policy and its global fade.

Glide works for all presets when raised: 12?462 ms one-pole time constant.
Before processing new onsets, the previous region's current frequencies are
captured by rank into a fixed 12-element snapshot. First onset of a new region
freezes that predecessor; subsequent onsets cannot mutate it. A missing rank
in the immediately preceding region starts at target frequency, even if an
older region's release voice still exists. New voices attack independently;
old releases overlap until the 12-slot limit forces oldest/releasing-first
stealing with a 4 ms sampled output fade. Pitch/rank identity never substitutes
for region identity in offs.

Controls are finite-validated and normalized 0?1, except tempo 30?300 BPM;
resonance is capped at 0.72. Default controls come from
`coda_dsp_default_controls`. Wobble scales drift/chorus/phaser, Warmth closes
the voice filter and adds saturation. Existing default key/tempo/UI unchanged.

## EQ, delay, reverb and mute constants

Static EQ coefficients are prepared outside render using the
[RBJ Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/)
biquads, direct form II transposed with double state and denormal flushing:

- Chords: second-order Butterworth HP 120 Hz and LP 9 kHz (Q = sqrt(0.5)).
- Master: high shelf ?3 dB at 9 kHz, slope S=1; peaking dip ?2 dB at
  3 kHz, Q=0.85. It processes **the sum of dry plus delay/reverb wet**.
- At low sample rates, design frequencies clamp to 0.42 times sample rate.
- Master gain 0.22, rational soft saturation, then 0.72*tanh(x/0.72).
- Dotted-eighth delay, 30% feedback, repeats one-pole LP 3 kHz.

Mono hall: 20 ms predelay, then Schroeder allpasses of 4.7 and 6.1 ms
(g=0.6), then a four-line orthogonal Hadamard FDN (matrix normalized by 1/2).
Line delays are 29.7/37.1/41.1/53.3 ms, integer samples truncated at prepare.
Each returning line is damped by a sample-rate-derived one-pole LP at 2.4 kHz.
Each line gain is `pow(0.001, delaySamples/(sampleRate*2.8))`: nominal
low-frequency RT60 2.8 s, with faster decay at high frequencies. Gains are all
strictly below one and the feedback matrix is orthogonal. Predelayed/diffused
input is injected at 0.25 into each line; output is 0.25 times the sum of the
damped/gained returns. Production layer send is 0.08. There is no direct input
or predelay bypass into wet output; every line has a real feedback return.
This is a compact diffuse mono hall network, not a physical plate model or a
claim of final owner-approved hall quality/stereo width.

Mute has one tunable duration: `coda::muteSeconds = 0.012` (12 ms per fade leg).
Every mute request latches fade-to-zero, even if unmute arrives during the fade
or in the same control drain. Existing dry/wet processing continues during the
fade. Only at zero are delay/reverb generations and EQ/phaser/damping states
invalidated in bounded work. Then pending unmute may fade up. While held at
zero, wet inputs are gated. Sustained live notes may sound freshly on unmute;
old wet memory cannot return. A mute received when already silent invalidates
at zero on the next processed sample.

## Regression evidence and pending verification

`CodaDSP/tests/dsp_tests.cpp` includes `pass2_tests.h`. Prepared native tests:

- Direct production envelopes: stage transitions, known sustain, zero-sustain
  idle, current-level release in attack/decay, midpoint/end durations, live
  timing changes, plus actual voice wiring and active-preset retention.
- Production EQ: DC step decay and measured sine gain at low/mid/high bands
  across 44.1/48/96 kHz; localized master dip, high attenuation, state reset.
  Warmed/reset production core must also exactly match a fresh core through
  over two seconds of voice, EQ, delay and FDN output.
- Production hall impulse: zero wet before predelay, dense tail occupancy,
  0.1?0.5/1?1.4/6?6.4 s energy windows, bounded finite output, DC stability,
  generation reset through old tap times, across those sample rates.
- Quick unmute and same-block toggles with audible wet/reference comparison,
  fade continuity, generation advance and >3 s stale-tail silence after unmute.
- 2?1?2 rank matching with older releases and stale offs, all three presets.
- Admission 31/32/33, invalid rank/order, exact delivery times, off-before-on,
  queue full/recovery, stop discarding queued work and reset/resume.
- Thread-local new/new[]/aligned new/array hooks, nothrow variants and matching
  deallocation counts; hook calibration; active FX/controls/stealing/release/
  mute invalidation. Producer allocations do not count against render.
- One real concurrent producer/consumer, future groups published before due
  blocks, note on/off traffic, full/recovery, control storms, delivery count,
  zero late count and ordered event hash. Metrics read on consumer or after join.

Existing finite/headroom/control/block-invariance and offline four-bar tests
remain. WAV output stays only in ignored `build/generated/dsp/`; artifact
allowlist remains IPA plus explicit small text reports. Existing 23 music
XCTest and one launch test are preserved, not claimed executed on Windows.

Actual feasible check on this pass: `python -m unittest discover -s
Tests/Scaffold -p 'test_*.py' -v`: **13 passed**. No clang++, g++, cl, Swift,
xcodebuild or XcodeGen was found on PATH. No compiler was installed. No native
DSP regression, sanitizer, Apple build or device listening result is claimed.
Mac CI must run and review both commands below, plus existing simulator/archive
checks, on standard `xcode-27` / Xcode 27.2 / SDK 27.2. No CI was triggered.
LeakSanitizer support and the existing workflow's `detect_leaks=1` option need
runner verification; support has not been inferred from ASan availability.

```sh
clang++ -std=c++20 -O2 -Wall -Wextra -pthread \
  -I CodaDSP/include CodaDSP/src/coda_dsp.cpp CodaDSP/tests/dsp_tests.cpp \
  -o build/generated/dsp/dsp_tests
build/generated/dsp/dsp_tests build/generated/dsp/four-bar
clang++ -std=c++20 -O1 -g -Wall -Wextra -pthread \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I CodaDSP/include CodaDSP/src/coda_dsp.cpp CodaDSP/tests/dsp_tests.cpp \
  -o build/generated/dsp/dsp_tests_sanitized
UBSAN_OPTIONS=halt_on_error=1 build/generated/dsp/dsp_tests_sanitized
```

## Owner-authorized narrow Hall reprepare correction (2026-11-25)

`Hall::prepare` now zeros the FDN write cursor, predelay write cursor and both
diffuser write cursors when binding storage. Its existing `reset()` call still
advances the generation and clears damping state. The bounded render-time
`Hall::reset` path is unchanged: no allocation or bulk buffer clearing added.

`test_public_reprepare` exercises the same production object through public
prepare/process calls, with full producer/render quiescence at every lifecycle
boundary. Cases cover 96 -> 48 kHz after 2048 samples (eight 256-frame blocks)
and 192013 samples (old FDN cursor beyond the new 144000-cell allocation),
48 -> 96 kHz, repeated 48 -> 48 kHz, reset/stop before reprepare at nonzero
cursors, and both directions between valid extremes 8 and 384 kHz. The extreme
downshift warms 32013 samples, beyond the new 24000-cell FDN capacity. Each case
also repeats prepare at its target rate. Tests require first-sample and extended
finite exact silence without new notes, cleared queued events/voices/timeline,
then finite non-silent playback with one new event delivered without lateness.
Direct production Hall assertions additionally check all four cursors, generation
advance and cleared damping state after prepare. These tests are invoked by
`test_pass2` in the existing normal and ASan/UBSan harness; no workflow edit.

Lifecycle trace: invalid prepare arguments return before touching existing
storage. Allocation failure deletes/nulls owned buffers; `process` rejects those
null buffers before reaching Hall's retained bindings. Reset/stop only invalidate
Hall generation/damping and do not dereference its storage. A successful retry
rebinds Hall and reinitializes cursors. No lifecycle contract or failure-path
implementation changed; this trace is code inspection, not fault-injection proof.

Feasible checks for this correction: all 13 Python scaffold/package tests passed
with the unittest command above. Tracked `git diff --check` and explicit whitespace
checks of the three correction files found no whitespace errors. No C++/Swift/
Apple toolchain was found on PATH and none was installed. Production native tests,
ASan/UBSan, Apple build/IPA and listening remain pending; the Mac commands above
have not been executed here. No staging, commit, push or CI trigger.

Stop for Hermes review; native
compile/test failures or unresolved DSP/listening concerns escalate rather
than starting another automatic corrective pass. No UI/adapter or next
milestone work, staging, commit, push, installation or CI trigger occurred.

## Subsequent Hermes native CI verification

GitHub Actions run 45618129186 succeeded at commit
`62cc900928e219a0be8ae3551c38ad1f19e92374` using Xcode/SDK 27.2:
the production C++ DSP suite (including public Hall reprepare regressions),
AddressSanitizer/UndefinedBehaviorSanitizer run, 13 scaffold/package checks,
23 music XCTest methods, one simulator launch test, unsigned archive and
IPA packaging all passed. The compiler reports a nonblocking misleading-
indentation warning at `pass2_tests.h:196`; no warning-free build is claimed.

The first attempt, run 45617610096, passed normal DSP tests but aborted before
sanitizer test execution because Apple's runtime rejects `detect_leaks=1`.
The workflow now explicitly uses `detect_leaks=0:halt_on_error=1` with
`UBSAN_OPTIONS=halt_on_error=1`. This verifies address/undefined-behavior
checks, NOT LeakSanitizer or freedom from all leaks/data races.

Hermes downloaded the successful artifact and independently checked its SHA-256,
ZIP integrity, unsigned arm64 Mach-O, iPad/device/deployment/orientation metadata,
and exact bundled font/vocabulary bytes against the repository.
IPA SHA-256: `427688fdef9b6c64bda61940167a5504945a0324ebd91769cb10207a3803cdd9`.
The app is still the foundation UI at this commit; this standalone DSP slice
does not yet provide integrated app audio. No physical installation/listening
test or full M1 acceptance is claimed. Owner has explicitly deferred those
device checks until complete M1 delivery; automated CI continues between slices.
