# M1b corrective slice: trace and repair the real Swing gesture

## Authority and ownership
Read AGENTS.md, SPEC.md section 8, docs/DESIGN.md section 3.7 and this brief. This supersedes M1b-pattern-drag.md. Work ONLY in C:/Users/jisak/CODA/.worktrees/owner-pattern-topbar-four-ui, branch coda/owner-pattern-topbar-four-ui, baseline 5be49bcd5a14ea0192d35ce56c1efb1fd655a876. Remote main equals baseline. Hermes verified no actual Codex exec writer remains; the unrelated desktop app-server is not a writer. You are the sole app/test writer. Root C:/Users/jisak/CODA has protected dirty owner documents: never edit/reset them. Hermes prepared only this brief and the task pointer.

Owner authorizes evidence-based M1b corrections without the superseded three-attempt cap. No blind retries or weakened assertions. No M2/M3/M4 code in this slice; later continuation authorization is separate from physical acceptance. No staging, commits, pushes, CI triggers, subagents, machine settings, gateway/Kanban/rotation work, installs, credentials/config/personal transcript reads. Stop for Hermes review.

## Actual latest RED evidence
Exact-head run 46060536437 attempt 1 completed FAILURE. native+archive, unit 181 cases and UI-B/C/D 10 cases succeeded; publish skipped. UI-A ran all 5 methods: 4 passed, only testFourBarSeededFixtureScreenshotAttachment failed, twice:
- Tests/CodaUITests/CodaLaunchTests.swift:215: first actual short finger Swing drag still commits 0, XCTAssertGreaterThan(0,0).
- :233: second reversed actual drag remains 0, XCTAssertLessThan(0,0).
Both ORIGINAL Humanize/Swing isHittable checks pass, both Humanize center/padding coordinate taps pass, decorative overlay isHittable=false/empty semantics pass. Do not repeat the disproven inaccessible-button diagnosis or remove identifiers.

Diagnostics downloaded and real:
C:/Users/jisak/AppData/Local/hermes/cache/scratch/coda-regular-resume-20261127/run-46060536437/coda-test-log-ui-a/tests.log (read lines 1330-1400 first)
C:/Users/jisak/AppData/Local/hermes/cache/scratch/coda-regular-resume-20261127/run-46060536437/coda-m1-ui-diagnostics-ui-a/artifacts/ui-screenshots/M1b-pattern-controls-AX-before-assertion.txt (24 lines)
Same folder/M1b-pattern-overlay.png (pre-input screenshot only).
Swing target is (1271,4,44,44). First drag (1293,26)->(1293,10), 0.1s press/500 px per second; reverse ends at y42. Both remain inside frame and screen. Do NOT extend/slacken this drag to hide the defect.

The attempted final-onEnded-translation correction in 5be49bc DID NOT resolve native behavior. PatternSwingDrag pure tests and store helper tests pass; they do not prove actual SwiftUI ingress. Latest attachment's uiDiagnostics value contains only early anchors and ends around 500 characters before newer input events. Do not conclude missing callbacks from a truncated old prefix; fix evidence freshness narrowly if necessary.

## Investigation and implementation
1. Trace actual production lifecycle: parent view identity/layout/SwiftUI gesture, root UIKit recognizer admission, updating/onEnded/reset, currentPatternSettings/updatePatternSettings. Rank falsifiable causes, compare working drawer knob. Diagnose before changing the recognizer family or rerouting input. Existing native test is the real RED loop. A new Python model/replica is not proof.
2. Preserve 120pt/full normalized range, preview-only movement, exactly ONE history transaction at lift, no-op/cancel behavior, baseline for second drag/reversal, music/history safety, only Swing/Tight-Loose top-right, existing squeeze toggle and absence of Done/window/PopRock/Spread UI.
3. Fix the demonstrable production source with minimal scope. Add real regression definitions at the involved seam; no new fake fallback, direct-store replacement of coordinate input or accessibility-only test. If native evidence is insufficient, add bounded opt-in latest ingress/callback/commit diagnostic visibility and state explicitly what is still hypothetical rather than claiming proven repair.
4. Preserve every existing UI assertion and coordinate input, including original short drag/nonzero, second reverse, hittability, geometry/music/history and decorative-paint semantics. You may strengthen reverse coverage with a smaller still-real reverse delta and a nonzero intermediate expected value, but do not remove/weaken original behavior. Bounded diagnostic capture must be fresh, not silently truncated before input; keep existing attachment allowlist and file names.
5. Leave workflow, shards, runner count, timeouts, native/sanitizer/source-runtime inventory/provenance and six-image success/failure/final evidence gates untouched. No audio DSP, dependencies, spec/design edits or broad refactor. Only narrow relevant app/test/scaffold changes.

## Verification/report
Use test-first regressions where executable and record actual RED/GREEN. Windows lacks native Xcode; discover availability once, never synthesize native output. Run the COMPLETE python -m unittest discover -s Tests/Scaffold -p 'test_*.py' and git diff --check; preserve unrelated tests and report existing skips honestly. Report exact root-cause evidence versus remaining hypotheses, changed files, commands/results, and what native CI must establish. Write final report to the explicit output-last-message path, then stop for independent review. Hermes deploys only after review. Owner knob direction/haptics issues remain separate queued corrections, not permission to change accepted speed in this slice.
