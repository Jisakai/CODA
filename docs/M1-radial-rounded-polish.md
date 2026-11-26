# M1 radial rounded-arc polish

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
