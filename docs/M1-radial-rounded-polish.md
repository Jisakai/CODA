# M1 radial rounded-arc polish

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
