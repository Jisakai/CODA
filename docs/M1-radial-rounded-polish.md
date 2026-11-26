# M1 radial rounded-arc polish

## Final third bounded correction - November 26, 2026

Against HEAD `70deac2af07a6f5e18a0e24bcf1e967ca7e2ea7a`, exact native run **45863773368 completed FAILURE**. This is correction **3 of maximum 3**, pending native verification, not an accepted fix. Hermes owns review/release. No M1b code was started.

### Actual evidence and screenshot pixels

Read the exact supplied `t_61b56adc-native-failure.log`: grouping actual XCTest assertion-error records by source line gives **81 at line 200 and 2 at line 252**, exactly **83**. The original full-grid SwiftUI `Path.contains` checks and the two newly added exact cap-tip SwiftUI checks fail false versus true. Adjacent local/placed/bridged CGPath checks and explicit move/close/cubic checks pass. Therefore neither baking placement before bridging nor replacing the stroke with one explicit closed contour resolved the native defect. The full-grid failures remain offset zero near ending caps across directions/counts/slots/scales; this is not evidence of a general winding reversal or placement defect. Supplied passing interaction/music/UI and DSP/transport/sanitizer results do not waive this failure.

Separately inspected the **actual attached run-45863773368 pixels**:

- `M1-radial-primary-fixture.png` (primary): two continuous dark curved backings with round exposed ends and lighter curved inset pills. Swap/duplicate/copy/delete follow the inner curve; Cm9/Cm11/Cm6/grid follow the outer curve. Backing remains visible between choices. The menu overlaps the first chord card and pitch-gutter labels; visible upper ends sit below the timeline.
- `M1-radial-edge-fixture.png` (All): three continuous curved backings with round ends, curved pills, lower paging arrows, bright minor-family choices and dimmer other families. The menu overlaps chord-strip content, including part of the second chord label, and pitch labels. Visible upper ends sit below the timeline. Neither image shows yellow, straight-row choices or disconnected wedge sectors.

These are observations of the supplied failed build, not new correction-3 screenshots or evidence of containment, every-edge fit, or physical testing.

### Bounded diagnosis and implementation

The remaining evidence supports investigating **curve decomposition at the SwiftUI consumer**: a narrow interior cap-tip region disagrees while CGPath consumers agree. The first two construction routes retained long circular-arc cubics. A coarse curve approximation could omit a narrow region near a curved extremum. This is a hypothesis, not an observed SwiftUI implementation detail; the log does not establish private winding/root-solving, ray-degeneracy or flattening internals. No winding reversal, fill-rule change or coordinate nudge is justified by the evidence.

`Sources/CodaInteraction/EditorInputModel.swift`, `RadialArc.path`, now applies three levels of midpoint **de Casteljau subdivision** to each existing cubic: eight shorter cubic elements representing the same original polynomial, with the same traversal, endpoints and tangents (subject only to floating-point arithmetic). Lines, move and close are retained. This does not flatten to a polygon, approximate a circle afresh, enlarge the cap or change dimensions. It changes the curve decomposition delivered to SwiftUI, rather than repeating the failed contour-construction hypothesis. All production rendering and local/placed hit consumers still receive this one canonical CGPath; the existing SwiftUI bridge and real `Path.contains` assertions remain. The bounded cost is eight cubic elements per original cubic and one temporary path per path construction, off the audio thread. No render-thread code changed.

`Tests/CodaAudioTests/EditorStoreRegressionTests.swift` adds only `testRoundedCapSubdivisionSeamsKeepNativeContainmentParity`: 204 strictly interior points around both caps, including junctions, tip and subdivision-angle samples, across two directions and three scales; each checks local CGPath, placed CGPath, bridged CGPath and real SwiftUI containment. **Every original full-grid loop/sample/three-way assertion and both exact cap-tip cases/contour assertions are unchanged.** No shadow wrapper, alternate oracle, relaxed tolerance, skip or redirection was introduced. Existing dimensions, minimum scale, maximum displacement **180 pt**, placement and round shapes remain unchanged.

### Checks, limits and handoff

- `python -m unittest discover -s Tests/Scaffold -v`: **35 run, 34 passed, 1 existing symlink-capability skip**. Synthetic fixture IPA checks are not a native app build.
- `git diff --check`: passed; Git reports LF/CRLF conversion warnings. Inspected the complete three-file correction diff and read back the changes.
- Tool discovery still finds no `swift`, `xcodebuild`, `xcrun` or `xcodegen`. No Swift compilation/execution or Python geometry replica was performed. This correction is **not native-proven** and no replacement pixels exist here.
- Hermes must run the unchanged full-grid and exact cap-tip tests plus the additional regression, required native/sanitizer gates, and produce/review **new** primary and All screenshot pixels. If this final decomposition correction fails, report the native blocker; do not waive or proceed into M1b or make another speculative retry under this authorization.
- Only the production geometry file, native regression file and this report were edited. Pre-existing dirty `.codex_task.md`, `DECISIONS_LOG.md`, `ROADMAP.md`, `docs/briefs/M1b.md` and untracked `docs/briefs/M1b-foundation.md` are preserved, as are unrelated fonts/IDEA/review files. No staging, commits, pushes, CI, dependencies, project/provider/config/credential changes, machine settings, compiler/model/editor launch, drawer/AI/music/audio/pattern work or interim IPA installation.
- M1 remains accepted for progression, not physically tested. Native plus NEW-pixel gates still precede M1b code. No intermediate installation is needed; final M1b device IPA remains required and M2 remains gated. Stop for Hermes review.

## Second bounded correction - November 26, 2026

Against supplied HEAD `7472bab76dcdbef439176437a3ac7c7d5f51c7cd`; Hermes reviews and runs native verification. This is attempt 2 of 3, not M1b implementation. Hermes launched the actual Codex CLI with explicit `-c model_provider="xingchi" -m gpt-6.1-sol` arguments; provider-side routing is not independently observable.

### Evidence and diagnosis

Targeted inspection of `C:/Users/jisak/AppData/Local/hermes/cache/scratch/t_e9d9f394-native-failure.log` confirms **exactly 81 assertion failures**, all `EditorStoreRegressionTests.swift:200`, all SwiftUI `Path.contains(point, eoFill: false)` returning false against true. The adjacent placed CGPath and SwiftUI-bridged CGPath assertions have no failures. Every failure has offset zero and radius 132. There is exactly one failed point for each direction/count/slot/scale combination (three directions, 2+3+4 slots, three scales). Every point is **0.942704220487 degrees before its un-inset slot end**, including the first degree-179 and last degree-149 examples. This identifies the ending round-cap tip region, rather than a general placement, fill-rule or radial-width mismatch. The comparison of logged coordinates/angles is log analysis only, not a Swift geometry execution or Python replacement for native tests.

The source representation was a centerline `CGMutablePath.addArc`, converted by `copy(strokingWithWidth:lineCap:.round,lineJoin:.round,...)`, then affine-copied before bridging to SwiftUI. The preceding retry already made both CGPath checks agree with local hit testing. The remaining evidence isolates the discrepancy to SwiftUI containment on that returned path. It does **not** reveal CoreGraphics' private stroke representation, SwiftUI's containment algorithm, or prove a private-framework root cause. Those internals were not observed on this Windows host. Changing the public construction route is a bounded correction hypothesis requiring native validation.

### Exact correction and coverage

`Sources/CodaInteraction/EditorInputModel.swift`, `RadialArc.path`, now constructs **one explicit closed filled contour**: outer concentric arc from start to end; semicircular end cap centered on the original centerline endpoint; inner concentric arc back to start; semicircular start cap; close. Outer/inner radii are radius plus/minus half-thickness, and both caps have radius half-thickness. Opposite traversal of the inner arc preserves the filled annular strip. These remain native curved path elements, not polygonal wedges or flattened samples. The nondegenerate contour requires radius greater than half-thickness, true for every production ring/pill; invalid/collapsed dimensions return an empty path. The existing explicit scale/translation remains applied before SwiftUI bridging. Rendering and local/placed hit testing still consume this one production method; no SwiftUI-only workaround or alternate hit envelope was introduced. This also retains the continuous rounded backing, curved overlaid pills, insets, gaps and placement envelope. CoreGraphics may approximate its arc elements internally; no bit-identical stroke tessellation claim is made.

`Tests/CodaAudioTests/EditorStoreRegressionTests.swift` adds `testExplicitRoundedContoursContainReportedCapTipsInAllThreeConsumers`: the exact first and last failed sampling parameters; an independent strict check that each point lies inside its ending cap circle; one move/one close and at least six cubic elements; local, placed, bridged CGPath and SwiftUI containment assertions. The original full-grid samples and every three-way diagnostic assertion remain unchanged. Existing round-cap/perimeter, corner and unreachable-placement regressions remain. `maximumDisplacement = 180` and both feasibility guards are unchanged; no thresholds, tolerances, skips, sampling or displacement limits were relaxed.

### Checks and remaining gate

- `python -m unittest discover -s Tests/Scaffold -p 'test_*.py' -v`: **35 tests, 34 passed, 1 existing symlink-capability skip**. Synthetic IPA fixture output is not a native build.
- `git diff --check`: passed, with LF/CRLF conversion warnings. Reviewed the focused production/test diff and read back the changed content.
- `Get-Command swift,xcodebuild,xcrun,xcodegen -ErrorAction SilentlyContinue`: none available. New Swift was not compiled or executed locally. No native output was fabricated.
- Prior CI run **45858703982** is a failed run; the supplied interaction/UI/music and DSP/sanitizer passes do not establish the new contour passes. Hermes must run native XCTest, including the unchanged full containment grid and new focused test, the required sanitizer gates, and produce/review new primary/All pixels. No new screenshots, green native result or visual acceptance are claimed here.
- Only the production path, native regression file and this report were edited in this attempt. Preserved the dirty task/decisions/roadmap/M1b brief, untracked M1b foundation and unrelated files. No dependencies, project/config changes, staging, commits, push, CI, packaging or owner installation gate.
- M1b and M2 are not implemented. Preserve the reserved drawer upper half/no AI. Future M1b contract remains exactly ten levels 1...10 = editing-height tenths = 10...100% base velocity, identical render/store/base playback/live v10...v100; zero absent; no MIDI-127 roundtrip or 90% multiplier; continuous chuck size. Native plus new-pixel radial gates precede any M1b work; no intermediate IPA/install/owner approval is required.

Stop for Hermes review. The explicit contour is implemented and reviewable; resolution of the SwiftUI-only discrepancy remains unverified until native execution.

## First corrective retry — November 26, 2026

Bounded correction against HEAD `7934c8910536be7c238ff82e59a02602beb77a2e`. Hermes owns review/release. This retry does not implement M1b.

### Actual native evidence and pixels

Inspected the failed-step log for run **45851896022** and both supplied 2752 × 2064 native PNGs, including enlarged crops of their menu regions. That run compiled but failed the two new radial methods: six displacement assertions at approximately **190.1920797087537 > 180**, and **81** rendered-path/shared-hit mismatches (`false` versus `true`). The reported 15 UI and 25 music methods passed; this run did not produce an IPA. It does not satisfy the radial geometry gate.

The actual primary PNG shows two uninterrupted curved dark bands, rounded backing starts/ends and four curved inset choices per band. Swap, duplicate, copy and delete icons follow the inner curve; Cm9, Cm11, Cm6 and the grid icon follow the outer curve. The All PNG shows three continuous rounded bands, curved pills, bright minor-family text and dimmer major/odd-family text with paging arrows at the lower ends. Exposed backing bridges the pill gaps. In these captures the visible backings sit below the timeline; both menus cover parts of chord-strip content and pitch-gutter labels, and the All menu obscures part of the second chord label. No yellow or wedge-sector presentation is visible. These observations establish the rounded visual treatment in these two images only, not hit parity, all-edge fitting, or hardware input correctness. They are pre-retry images; no corrected-build pixels exist locally.

### Cause, correction and remaining uncertainty

- **Proven placement defect:** fallback used `displacement + scalePenalty + angularPenalty` without an absolute displacement feasibility guard. Thus a candidate outside 180 pt remained eligible to beat smaller candidates. Fallback now rejects displacement above the unchanged **180 pt** limit before scoring. Existing rotation/scale preferences and all coverage remain. A focused actual XCTest additionally covers the two top/chrome All corners, requires scaled placement within 180 pt and the original conservative bounds, and rejects an unreachable remote tip.
- **Bounds retained:** `outerRadius - capRadius` is the outer centerline radius; expansion by capRadius encloses the round stroke caps. Including the origin is conservative but also encloses smaller concentric rings and the center dot. Removing the origin or ignoring caps would undercut that guarantee; neither is necessary to enforce the missing absolute limit. No bounds relaxation was made.
- **Render-path trace:** production creates an increasing-angle, `clockwise: false` centerline, then CoreGraphics strokes it with round caps/joins to produce the filled outline. Hit testing consumes that CGPath in local coordinates with the default nonzero winding rule. Rendering previously bridged the outline into SwiftUI `Path` *before* applying scale concatenated with translation. That transform is intended to map `p` to `scale * p + center`; positive scales do not intentionally change winding, and neither caller requests even-odd fill. The native log lacks sampled coordinates and intermediate path results, so it does **not** prove an arc-winding, fill-rule, or SwiftUI-internal cause for the 81 differences.
- **Narrow render correction, native confirmation required:** `RadialArc.path(center:scale:)` now strokes in the same canonical local coordinates and explicitly bakes the affine coefficients `(scale, 0, 0, scale, center.x, center.y)` into the filled CGPath before creating SwiftUI `Path`. `RadialArcShape` no longer applies a SwiftUI-side transform. This removes the differing transform route while retaining the exact stroke outline, cap geometry and winding. This is a targeted correction to the observed comparison boundary, **not a locally proven explanation or resolution of the 81 mismatches**.
- The existing full 360° width/cap/scale parity grid and center-dead-zone assertions remain. Each sample now separately compares placed CGPath containment, SwiftUI's bridged CGPath containment and SwiftUI Path containment against the original shared local hit result, with direction/count/slot/scale/degree/offset/local/placed coordinates in failure messages. This will distinguish affine/path-bridge/containment failures in the replacement native run. No tolerances, thresholds, skips or sample coverage were weakened.

### Exact changed files and executed checks

Only `Sources/CodaInteraction/EditorInputModel.swift`, `Sources/CodaApp/EditorViews.swift`, `Tests/CodaInteractionTests/EditorInputModelTests.swift`, `Tests/CodaAudioTests/EditorStoreRegressionTests.swift` and this report were changed by this retry.

- `python -m unittest discover -s Tests/Scaffold -p 'test_*.py' -v`: **35 run, 34 passed, 1 existing symlink-capability skip**. No Python geometry replica was created or used. Synthetic IPA fixture output is not an app build.
- `git diff --check`: passed, with existing LF/CRLF warnings on pre-existing planning files.
- `Get-Command swift,xcodebuild,xcrun,xcodegen -ErrorAction SilentlyContinue`: none available. Changed Swift has **not** been compiled or executed here. Native parity, exact corner scaling and replacement screenshots remain unknown pending Hermes's replacement native CI. No green-build, IPA or physical-test claim.
- Preserved the pre-existing dirty task/decisions/roadmap/M1b brief files and unrelated untracked fonts, IDEA/review files and M1b foundation brief. No staging, commits, pushes, CI/config/credential access, drawer work or M1b code.
- Future immutable M1b handoff only: arrow levels exactly 1...10 represent 10...100% editing height and identical stored/base playback/render/live velocities v10...v100; zero is absent; no MIDI-127 roundtrip or 90% multiplier; retain top/bottom directions, Pencil tap-remove and continuous chuck size. No implementation in this retry.

Stop for Hermes review. A replacement native run must pass actual XCTest/sanitizer gates and produce corrected primary/All screenshots for actual pixel review before M1b implementation. Latest owner delivery cadence: "no need to new install new ipa until end of M1b". No radial-only IPA delivery, intermediate installation or owner approval gate is requested. Defer archive/packaging/delivery to M1b completion where practical; existing CI may produce incidental artifacts. Final reviewed exact-head M1b unsigned IPA and direct verification remain required. Physical testing is unclaimed; M2 remains gated.

Implemented November 26, 2026, under `docs/briefs/M1-radial-rounded-polish.md` and its latest owner authorization. This slice stops before M1b. Behavior authority remains SPEC §7.4; the owner's continuous-backing/rounded-pill instruction supersedes only the older segmented-slot presentation in DESIGN §3.8.

## Actual prior-image observations

Inspected the supplied real `M1-radial-edge-fixture.png` pixels (2752 × 2064). Three dark curved bands appear near the upper-left editor area. Each band is split into separate wedge-like sectors with black gaps and straight end cuts. Labels and paging-arrow icons follow the curve, with brighter and dimmer ink visible. The menu is close to the left screen edge; its visible top ends are below the timeline. This image does not show the requested continuous backing or rounded pill choices. These are observations of the prior image, not evidence of the new implementation or of physical Pencil behavior.

## Source findings and implementation

- Previously, `RingSlotShape` joined outer and inner arcs with straight radial edges, and each slot separately clipped `CodaAcrylic`. Production hit testing used radial bands plus angular sector intervals. Those are source findings, separate from image observations.
- `RadialArc` in `CodaInteraction/EditorInputModel.swift` now creates a filled round-capped arc by stroking a centerline with CoreGraphics round caps. Each visible ring renders one continuous `CodaAcrylic` backing. Curved capsule choices overlay that backing. Existing labels, icons and their selected/current-family/dimmed/disabled ink rules remain in place; disabled choices remain governed by the existing resolver.
- Both the SwiftUI choice shape and production Pencil hit testing consume the same filled pill path. The store converts root coordinates back through the frozen placement scale before testing. Exposed backing, rounded-off choice corners and inter-choice gaps do not select options. Path creation stays in the UI/interaction path, never the audio render thread.
- Choice paths are constructed in unscaled coordinates and then transformed, so pill insets and cap geometry scale identically for drawing and hit testing at 1.0, 0.9 and 0.8.
- Placement now receives the active outer band's half-width as its cap radius. Its conservative envelope is the center-inclusive centerline sector hull expanded by that radius. Including the center also safely encloses smaller concentric rings, at the cost of a conservative allowance near the tip. This accounts for painted caps extending beyond the old sector endpoints. Existing orientation preference, edge search, bounded scale/displacement fallback, chrome exclusion and frozen selection placement remain.
- Primary still has two rings; All still has at most three family rings with existing paging. Swap/root draft, hover audition, lift commit, Pencil-only ingress and tool dispatch code are retained. Drawer, music compiler/audio, dependencies, generated projects and M1b behavior were not changed.

## Tunable values

Existing geometry is retained: 120° sweep, canonical −120° upward direction / +60° downward direction; primary radii 84/136 pt and band widths 40/48 pt; root picker radius 136 pt / width 40 pt; All radii 132/196/260 pt and widths 48 pt; 8 pt edge margin; existing scales 1.0/0.9/0.8. Radii and band widths remain in `CodaDesignTokens.EditorSurface`.

`RadialGeometry.pillInset = 4 pt` leaves exposed glass on either side of the pill (32 pt inner/root pills; 40 pt outer/family pills). The centerline is shortened at each end by `asin(pillHalfWidth / radius) + slotGap`, preserving the existing `slotGap = 0.015 rad` and avoiding overlapping choice caps. Backing caps have radius half the full band width; pill caps have radius half the inset width. `CodaDesignTokens.EditorSurface` adds pill overlay opacities: normal 0.05, selected 0.13 (the previous selected overlay value), disabled 0.015. These are bounded visual tuning defaults for owner review; no new OPEN behavior or dependency was adopted.

## Regression coverage

Native XCTest changes (added/expanded, **not executed on this Windows host**):

- `testCurvedBackingIsContinuousAndPillsHaveRoundCapsWithNonselectableGlassGaps`: all production band sizes, one through four choices, rotated/wrapped directions; choice centers, exposed rim and seam cancellation; both backing and pill caps accept points inside the cap and reject points beyond it and in squared corners.
- `testRoundedPaintedPerimetersFitEveryEdgeAndChromeAtPrimaryRootAndAllExtents`: three landscape viewport sizes, edges/corners and screenshot anchors, primary/root/All extents, deterministic placement, scale/displacement limits. Independently samples circles along each complete centerline, including cap perimeters, against viewport and toolbar/timeline exclusion.
- `testRenderedCurvedPillsMatchHitTestingAcrossTheirWidthCapsAndScale`: expands the former sector path comparison to actual curved pill paths, full 360° sampling, multiple radial offsets, three directions, two through four choices, and all three fitting scales. Retains center-dead-zone checks.
- `testProductionHoverUsesRoundedPillsAndCancelsOnExposedBackingInEveryMode`: actual store Pencil hover accepts cap points and cancels on exposed backing in primary, roots and All; frozen placement and unchanged progression are checked through the existing swap/root route.
- Existing production edge/path checks now inspect every continuous backing as well as every choice path, including cap bounds. Existing paging, dispatch, audition, lift, cancellation and Pencil routing tests remain.
- New DEBUG-only `--coda-ui-fixture-radial-primary` route opens the production primary menu through `openSqueeze`. `testPrimaryRadialScreenshotFixture` checks both primary rings and attaches `M1-radial-primary-fixture.png`. The existing edge-positioned All fixture is preserved. Neither fixture adds a finger music-editing route.
- Screenshot export and exact artifact paths now include the primary image. The scaffold screenshot contract requires it. Workflow edits only name this additional artifact in the two existing upload lists; no CI run was triggered.

## Executed checks and limits

- `python -m unittest discover -s Tests/Scaffold -p 'test_*.py' -v`: **35 tests run, 34 passed, 1 skipped**. The existing symlink test self-skipped because this Windows host cannot create symlinks. No assertion or skip logic was changed. The package verification output belongs to the Python synthetic IPA fixture, not a new native app build.
- `git diff --check`: passed (Git emitted existing LF/CRLF conversion warnings).
- Command discovery found no `swift`, `xcodebuild`, `xcrun` or `xcodegen` executables. Swift/CoreGraphics/SwiftUI compilation, native XCTest, simulator screenshots, archive and unsigned IPA verification were therefore not executed here.
- **No new native screenshot was produced or reviewed.** Primary and All screenshots must be produced by a later authorized native run before reviewing the new pixels. Physical iPad/Pencil/listening checks remain unverified.
- No staging, commits, pushes or CI triggers. Unrelated working-tree edits and untracked files were preserved, including the owner/orchestrator's task, roadmap and decisions updates. Stop here for Hermes review; do not start M1b in this slice.
