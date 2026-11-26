# M1 radial rounded-arc polish — authorized bounded slice

## Latest authorization — November 26, 2026
Owner: "I believe M1 is final I havent tested myself but it looks pretty much fixed. Just One thing radial menu start and end should be rounded and have a whole thing with overlayed pills following the curve. Aside from that looks fine we can go on to M1b".

This supersedes historical M1b prohibitions: M1 is accepted for progression, physical testing has NOT occurred. Finish this visual correction first; M1b implementation is authorized subsequently, M2+ is not. Preserve current drawer and its reserved empty upper half; no AI work.

## Read and implement only this slice
Read AGENTS.md, SPEC §7.4, docs/DESIGN.md §3.8, DECISIONS_LOG.md, current production radial geometry/rendering/hit tests and existing regression/screenshot tests. This brief supersedes active instructions in .codex_task.md for this bounded work. Hermes orchestrates/reviews; actual Codex CLI writes code.

Implement CONTINUOUS dark-glass curved backing for each visible radial ring, with ROUND START AND END caps. Place overlaid rounded pill choices FOLLOWING THE ARC, not disconnected wedge sectors with squared ends or a straight row. Preserve current theme, radii/spacing scale, existing labels/icons, selected/dimmed/disabled states and current tool behavior. Owner's latest visual instruction supersedes earlier segmented-slot visuals only.

Keep the two-ring primary menu, All family paging/max three rings, root/swap semantics, hover audition, lift commit, Pencil-only routing, fixed placement during selection, edge clamping, and toolbar/timeline exclusion. Do not change drawer, music compiler/audio or M1b behavior in this slice. Round caps can extend past the old sector endpoint envelope: account for actual painted bounds without regressing edge clamping. Keep shared render/hit geometry accurate; do not create visible options whose hit areas disagree. Add targeted production geometry/path/edge regression tests and preserve existing coverage. Native screenshots should demonstrate primary and All rings if feasible with existing fixture routes, without finger-edit fallback.

Inspect attached prior screenshot pixels and report actual observations separately from source inference. Hermes vision tool returned HTTP403, so your attached-image inspection is the available alternative. Do not claim a new screenshot has been reviewed until native CI produces it.

Run feasible full local scaffold tests and git diff --check. Native Swift/Xcode execution may be unavailable on Windows; report that honestly. No weakening/skipping assertions, new dependencies, xcodeproj edits, commits, staging, pushes, CI triggers, secret/config reads, or unrelated files. Preserve modified .codex_task.md and ROADMAP.md plus unrelated untracked fonts/IDEA.md/.codex_review.md. Document implementation and exact tests/defaults in docs/M1-radial-rounded-polish.md, then STOP for Hermes review. Do not start M1b code yet.
