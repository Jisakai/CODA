# M1 radial correction — circular options and count-fitted arcs

## Latest owner instruction

> “fully circular buttons in the radial menu not pills and size the menu length around the circles like if there are 7 buttons then size it that way”

This supersedes the November 26 curved-pill direction in `docs/briefs/M1-radial-rounded-polish.md`, `docs/M1-radial-rounded-polish.md`, `SPEC.md`, `docs/DESIGN.md`, and earlier handoffs. The prior pill implementation and screenshots are historical, not acceptance evidence for this correction.

## Authority, ownership, and scope

Read `AGENTS.md`, `SPEC.md` §7.4, `docs/DESIGN.md` §3.8, the current production radial geometry/rendering/selection/placement code, and its native tests before editing. SPEC governs behavior; DESIGN governs visuals. This bounded slice changes radial option geometry and presentation only. Preserve existing chord/tool actions, ring ordering/paging, hover audition, Pencil-lift selection, Pencil-only ingress, placement behavior, menu timing, accessibility names, and unrelated M1b work. Do not alter audio, pattern behavior, drawer, AI, or add dependencies.

Work only in `C:/Users/jisak/CODA/.worktrees/owner-pattern-topbar-four-ui`, branch `coda/owner-pattern-topbar-four-ui`, based on `5be49bcd5a14ea0192d35ce56c1efb1fd655a876`. That worktree already contains separate unreviewed M1b Swing-ingress edits from the previous slice; preserve them exactly and keep their tests/results separate. The root checkout also has protected owner edits—do not reset, overwrite, or copy whole files between checkouts.

Hermes orchestrates and reviews; Codex writes app/tests. One writer only. No staging, commits, pushes, CI triggers, installs, machine settings, credentials/config reads, or unrelated changes. Stop for independent Hermes review.

## Required behavior

1. Every radial option is a true circular button: identical width and height, a round painted/hit silhouette, and no elongated pill/capsule background. Keep the existing per-ring circle diameter derived from the current band interior (`band thickness - 2 × existing inset`, presently 32 pt for a 40 pt band and 40 pt for a 48 pt band) unless source evidence requires a correction. Keep circle and icon/text centers aligned.
2. Compute each ring’s visible layout from its current visible choice count `N`, circle diameter `D`, shared inter-circle gap `G`, and centerline radius `R`. Position all `N` circles with uniform arc spacing; compute the continuous backing’s start/end and total arc length from those same values. A seven-option ring must fit seven non-overlapping circles with consistent gaps; do not use a fixed short/four-slot arc, clip/squeeze options, or leave a large unused fixed-length tail. For one option, keep a compact rounded backing sized around that circle. Do not add/remove user-facing actions to satisfy the seven-choice geometry case.
3. Reuse one canonical count-derived geometry for drawing, Pencil hit testing, rendered bounds, edge/chrome fitting, and any debug fixture. A circle’s painted area is selectable; exposed backing and inter-circle gaps remain non-selectable. Round backing endpoints and all painted buttons must fit the viewport and existing toolbar/timeline exclusion while preserving the existing displacement/scale safety limits.
4. Preserve choice text/icons, disabled/selected/dimmed presentation, color, action dispatch, ring radii/thickness, and page semantics except for the required count-derived arc extent. Centralize any new tunables; use the existing circle dimensions and established gap rather than inventing arbitrary sizes.

## Test-first implementation and acceptance

- Follow strict RED→GREEN TDD: add a native regression for count-dependent circular geometry first, run it, and record the expected failure before production edits.
- Cover visible counts 1 through 7, including 7: derived arc grows with the count, each circle is round/equal-size, neighboring buttons do not overlap and retain the shared gap, and the backing has rounded ends close to the first/last circle rather than the old fixed 120° extent.
- Verify the production hover/hit path agrees with the painted circles at centers/perimeters and rejects the gaps/backing. Keep all prior action and input assertions; update only assertions that directly encoded the superseded pill/fixed-sweep presentation.
- Extend count-aware edge-fit tests across landscape sizes and all existing directions/ring radii. Preserve current minimum scale, maximum displacement and chrome exclusion; do not relax thresholds.
- Produce/review a native screenshot of the real radial UI. If needed, use a DEBUG-only fixture through the production `RadialMenuView`/geometry to show seven choices; do not add a finger-edit shortcut or change production option semantics. Do not claim screenshot/pixel review until new native pixels actually exist and are inspected.
- Run the complete feasible local scaffold suite and `git diff --check`. Windows has no Xcode/Swift toolchain; do not claim native compilation/tests or invent pixel evidence. Report exactly what remains for native CI and physical iPad/Pencil acceptance.

## Stop condition and report

Return a concise report naming the changed app/test/docs files, actual RED/GREEN and full local test output, native limitations, and any remaining gaps. Do not call this design owner-approved beyond the explicit instruction above; do not claim M1b or release acceptance. Stop for independent Hermes review before CI/release workflow.
