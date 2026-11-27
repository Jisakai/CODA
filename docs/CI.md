# CODA CI and local native feedback

This workflow change corrects scheduling and release evidence. The same revision
also carries the separately reviewed owner pattern-control correction. No
sanitizer, test-timeout, font or orientation gates are weakened.

## Observed baseline

Run **45983067662**, SHA `96d53cdc5ae91688d8af8ba0bf4070728a9ba8f3`, failed
`ui-a` at `CodaLaunchTests.swift:118`, `XCTAssertFalse(done.exists)`. The other
lanes passed. Recorded lane timings were native **71 s**, archive **83 s**,
unit **484 s**, `ui-a` **1,227 s**, and `ui-b` **1,490 s**. A prior successful
run, **45912226126**, recorded `ui-a` at **890 s** and `ui-b` at **1,299 s**.
These are observed lane times; they do not establish candidate wall time or a
speedup.

The full UI method partition is explicit and exhaustive:

| Lane | Methods |
| --- | --- |
| `ui-a` | `testEmptyEditorScreenshotAttachment`, `testFourBarSeededFixtureScreenshotAttachment`, `testDrawerAndAllThreeProductionPresetsAreReachable`, `testEdgePositionedAllQualityRadialScreenshotFixture`, `testPrimaryRadialScreenshotFixture` |
| `ui-b` | `testKnobValueCapsulesAreOutsideActualDialsAndFingerDragStillWorks`, `testFingerMusicRegionTapDoesNotEditOrCreateHistory`, `testSnapShowsBothFullLabelsInsideOriginalGutterCell` |
| `ui-c` | `testActualSessionPlayPauseAndChordMuteControls`, `testChordMuteCenterAndPaddingRemainTappableInBothStates`, `testKeyboardRowsStayBelowChromeAndFollowSemitoneRegister`, `testCaptureNormalizationAppliesOrientationWithoutForcingLandscape` |
| `ui-d` | `testEverySettingsPopupStaysNearItsOwnInvokingControl`, `testLaunchShowsEmptyEditorAndLocksLandscape`, `testSettingsIconCenterAndPaddingPresentProductionPopups` |

The workflow uses at most **five concurrent Mac runner slots**. Four simulator
suites (`unit`, `ui-a`, `ui-b`, `ui-c`) start alongside one combined
native-checks + device-archive job. Only `ui-d` has `needs: [native]`: it
becomes eligible after the combined native+archive job succeeds and takes the
released fifth slot. It is not an arbitrary sixth job left to queue, and the
other four simulator suites are not gated behind native/archive. The shared
simulator step list uses a YAML anchor so both paths run identical checks.
Publication requires combined native+archive, the four immediate suites, and
the delayed suite; skipped, cancelled or failed dependencies cannot publish.

In successful baseline run **46002209835**, the current partition's per-test
UI sums were `ui-a` **210.766 s**, `ui-b` **187.323 s**, `ui-c` **184.392 s**,
and `ui-d` **117.329 s**. Thus the shortest UI shard is deliberately delayed
so its smaller workload offsets its later start. Native and archive were
separate **43 s** and **106 s** jobs; the combined job is not yet measured.
The unit build/test step was **764 s**, so unit is not the short delayed lane.
These observations guide balancing; they exclude cold setup/build overhead
and are not predicted finish times or a demonstrated speedup. Account-wide
runner admission and other workflows can still affect actual overlap.

The native checks retain optimized DSP, ASan+UBSan DSP, optimized transport,
ASan+UBSan transport, and the complete Python scaffold/font suite. Apple's
CI-only dylib interposition and real mutex/unfair-lock calibration assertions
remain part of the native checks.

Each simulator job uses its own runner, simulator and DerivedData. Simulator
boot starts while `build-for-testing` compiles; `bootstatus -b` waits after the
build, before `test-without-building`. The workflow now reports those three
phase durations separately with success or failure outcome. The baseline run
above does not provide a compile/boot/test decomposition. Phase and method
durations are not total job or queue latency. Shared build transfer and its
end-to-end net effect remain unmeasured. Shared binary reuse is deferred until
safe exact-SHA, toolchain and configuration matching and end-to-end measurements
are available; there is no evidence that it is slower.

### Before/after measurement procedure

Read exact-run job and step timestamps with `gh run view RUN --repo
Jisakai/CODA --json headSha,status,conclusion,jobs,createdAt,updatedAt` and
retrieve producer logs with `gh run view RUN --repo Jisakai/CODA --log`.
Compare successful runs with equivalent complete runtime inventories; the
failed baseline above is diagnostic evidence, not an acceptance comparison.
Record the candidate SHA/run/attempt, creation-to-final-publication elapsed
time, per-job start delay and duration, summed Mac job seconds, phase timing
summaries, runtime inventories, screenshots and verified device IPA. Start
delay includes dependency/scheduling effects; it is not pure queue time.
Count overlapping job intervals to measure observed capacity, not account
entitlement. The runner API lists self-hosted runners, not hosted capacity.
The observed five overlapping jobs do not prove six or ten available slots.

The four-way partition separates presets, knobs, transport and the settings
outlier while retaining all mandatory review fixtures in `ui-a`. It is a
measurement candidate, not a proven end-to-end balanced topology: each shard
still pays cold compilation and simulator startup costs. Retain it only after
equivalent exact-head gates pass and total publication turnaround improves;
otherwise regroup. Shared builds require a separate bounded comparison of
build, upload, download, boot and execution time with exact SHA, SDK, Xcode,
architecture, configuration and test-selection compatibility enforced.

`scripts/ui_shards.json` is a disjoint, complete 15-method partition; source
inventory changes fail closed. Runtime evidence checks exact class/method
identity, including the two Objective-C adapter tests whose runtime class has
no Swift module prefix. Missing, duplicate, unexpected, failed or skipped
cases fail the lane. Publication reruns those checks from the simulator
artifact logs and compares the result with producer evidence. Native and
archive evidence carry an empty runtime-test list.

Matrix fail-fast is disabled so independent failures retain diagnostics.
Per-ref cancellation of superseded runs remains enabled. The bounded named
PNG/AX diagnostic allowlist is retained, including failure branches. `ui-a`
strictly requires the five review screenshots on success; other UI shards may
export available allowlisted diagnostics. Final assembly checks the five
review images again. Whole `.xcresult` bundles are not uploaded.

The archive is published only as the intermediate `coda-internal-archive`
artifact, which may be visible in a public repository and is not an approved
release. GitHub artifacts are not private storage. The Linux publication job
downloads artifacts from the current run only and requires every lane to
succeed. Each producer records exact event SHA (including a PR merge SHA), run
ID, attempt, lane, Xcode/SDK, architecture, configuration, runtime inventory
and SHA-256 payload hashes. Publication verifies provenance and payloads before
assembling the final IPA. Rerun all jobs rather than combining artifacts from
different run attempts. The final artifact contains the verified unsigned IPA,
verification report, native report and required review screenshots.

The official `actions/download-artifact` v4.3.0 action is pinned to
`d3f86a106a0bac45b974a628896c90dbdf5c8093`; existing action pins remain intact.

## Reproduce portable checks in WSL Ubuntu

```powershell
wsl.exe -d Ubuntu -- bash -lc 'clang++ --version'
wsl.exe -d Ubuntu -- bash -lc 'cd /mnt/c/Users/jisak/CODA && bash scripts/local_native_checks.sh /tmp/coda-ci-20261127'
wsl.exe -d Ubuntu -- bash -lc 'cd /mnt/c/Users/jisak/CODA && python3 -m unittest discover -s Tests/Scaffold -p "test_*.py" -v'
```

The script compiles the production `coda_dsp.cpp` and `coda_transport.cpp`
with their existing C++ test drivers in optimized and ASan+UBSan builds.
Allocation/render, concurrency, musical/signal/performance and boundary
assertions run from those drivers. Linux LeakSanitizer remains enabled;
Apple CI keeps its `detect_leaks=0` exception while retaining address and
undefined-behavior checks. Write outputs outside the checkout. Ubuntu clang
**21.1.8** passed all four executables during the prior local check. The
existing misleading-indentation warning in `pass2_tests.h` was left unchanged.

Linux does not exercise Apple's guarded dyld interposition and unfair-lock
assertions, AVFoundation, Swift/UIKit/SwiftUI, simulator gestures or pixels,
XcodeGen generation, device archive or IPA verification. Those still require
the exact-head Mac CI run and review. Physical iPad sound and feel acceptance
also remains separate.
