# CODA CI and local native feedback

This slice changes feedback and release scheduling only. No app, project,
font, orientation, assertion, sanitizer, or test-timeout changes are intended.

## Measured baseline

Run **45893010956**, SHA `6a9a4dfd3dd742c88e72b38d7c3170b1029ed30a`,
November 26, 2026: job 20:42:50–21:02:20 UTC = **1,170 seconds**.
The job/step timestamps were independently retrieved with:

```powershell
& 'C:/Program Files/GitHub CLI/gh.exe' run view 45893010956 --json jobs,headSha
& 'C:/Program Files/GitHub CLI/gh.exe' run view 45893010956 --log
```

Simulator boot: **129 s**; combined build/test step: **895 s**; device
archive: **66 s**. The xcodebuild log reports 642.183 s for testing operations;
that is not pure test-method execution or a separately measured compile step.
Do not subtract these overlapping/differently bounded measurements and label
the result a measured compiler duration.

The complete runtime inventory and individual durations, without truncation,
are in `docs/ci-baseline-45893010956.json`: **149 passed XCTest cases**:
67 music, 25 interaction, 42 audio (including two Objective-C adapter tests),
and 15 UI. The UI methods total **507.413 s**. UI shard A has 7 methods /
**252.699 s**; B has 8 / **254.714 s**. A owns all five required review images.
These sums informed partitioning; they do not predict wall time on cold runners.

## Scheduling and release gate

At most five standard `xcode-27` Mac jobs run together:

1. Original optimized DSP, ASan+UBSan DSP, optimized transport, ASan+UBSan
   transport, and complete Python scaffold/font checks. Original Apple dylib
   interposition, real mutex/unfair-lock calibration/assertions remain intact.
2. All non-UI tests from the original four-target scheme, excluding only the
   UI target. New non-UI cases are automatically included.
3. Explicit UI method shard A.
4. Explicit UI method shard B.
5. Original unsigned device archive and full IPA package verification.

Simulator jobs own separate runner/simulator/DerivedData instances. Boot starts
before `build-for-testing`; `bootstatus -b` must complete before
`test-without-building`. Build and execution use the same local DerivedData,
Debug configuration, destination, revision and toolchain. No simulator binaries
are transferred. This accepts repeated cold compilation rather than introducing
unmeasured large artifact-transfer overhead and a serial build dependency.
The first native run must measure whether this tradeoff is worthwhile.

`scripts/ui_shards.json` is an explicit disjoint partition. A source inventory
change fails closed until reviewed. Successful execution must additionally
match the *actual XCTest passed cases* exactly: missing, duplicate, unexpected,
failed and skipped cases reject evidence. This is not a source-name-only count.
The unit lane requires passing runtime suites for all three unit targets.

Matrix fail-fast is disabled; independent lane failures preserve diagnostics.
Per-ref cancellation of superseded runs remains enabled. UI exports retain the
existing bounded named PNG/AX allowlist, including failure branches. Shard A
strictly requires all review screenshots on success; B exports its available
allowlisted diagnostics. Final assembly strictly checks the five review images
again. No whole xcresult bundle is uploaded.

Archive output is `coda-internal-archive`, never the final release name. It is
available as an intermediate artifact on a public repository and is **not a
delivered/approved release**. GitHub artifacts are not private storage.
Only the downstream Linux publication job can upload `coda-unsigned-ipa`, after
native, all matrix children, and archive succeed. It downloads artifacts from
the current run only. Each producer records exact event SHA (including PR merge
SHA), run ID, attempt, lane, Xcode/SDK, architecture, configuration, runtime
inventory and SHA-256 payload hashes. Publication independently validates these
before copying anything into the final delivery. Old run/attempt evidence is
rejected: rerun **all jobs**, not a mixture of old and new attempts.

All original action SHAs remain; the one new action is official
`actions/download-artifact` v4.3.0, resolved with the official GitHub API to
`d3f86a106a0bac45b974a628896c90dbdf5c8093`.

Every lane records total elapsed time, simulator compilation/runtime timings,
and the full passed-case list with durations in job summaries. Internal evidence
contains hashes and inventory for later measurement. Compare the next reviewed
exact-head run against this baseline; **no optimized wall-time speedup has yet
been measured**. No workflow was triggered by this slice.

## Reproduce portable checks in WSL Ubuntu

```powershell
wsl.exe -d Ubuntu -- bash -lc 'clang++ --version'
wsl.exe -d Ubuntu -- bash -lc 'cd /mnt/c/Users/jisak/CODA && bash scripts/local_native_checks.sh /tmp/coda-ci-20261127'
wsl.exe -d Ubuntu -- bash -lc 'cd /mnt/c/Users/jisak/CODA && python3 -m unittest discover -s Tests/Scaffold -p "test_*.py" -v'
```

The script compiles real `coda_dsp.cpp` / `coda_transport.cpp` with the complete
existing C++ test drivers, both `-O2` and `-O1 -g` ASan+UBSan. Allocation/render,
concurrency, musical/signal/performance and boundary assertions execute as
provided by those drivers. Linux LeakSanitizer remains enabled; Apple's CI-only
`detect_leaks=0` exception is unchanged. Outputs must be outside the checkout.
Ubuntu clang **21.1.8** passed all four executables during this slice. The
existing misleading-indentation warning in `pass2_tests.h` was left unchanged.

Linux does **not** exercise the guarded Apple dyld interposition/unfair-lock
assertions, AVFoundation, Swift/UIKit/SwiftUI, simulator gestures/pixels,
XcodeGen generation, device archive or IPA verification. Those still require
the exact-head Mac CI run and Hermes review. Physical iPad sound/feel acceptance
also remains separate.

The two untracked Swift drafts (`PerformancePlanBridge.swift` and its test)
are excluded naturally from clean tracked CI checkout. This local C++ script
does not compile Swift. Do not run a local directory-scanning XcodeGen benchmark
with these drafts and describe it as the tracked CI revision. Existing dirty
task/log/roadmap/brief files and unrelated untracked files are preserved.
