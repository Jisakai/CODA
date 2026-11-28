# Implementation status — overnight mission

## Stage 1 — source integration in progress (2026-11-28)

All changes in this checkpoint are **UNTESTED and UNBUILT**. **NO TESTS OR BUILDS RUN**. This is source evidence, not native acceptance.

- `Sources/CodaMusic/MusicModel.swift`: `RollNote`, `ChordRegion.notes`, retained unknown identity, tick timing, overflow-checked arrangement/loop lengths. Eight bars remains an initial view.
- `Sources/CodaMusic/ChordDetector.swift`: vocabulary matching with bass/inversion, duration/beat/velocity weight, neutral unknown result; shared live chord-tone labels and checked `ArrangementExtent`.
- `Sources/CodaMusic/ChordRollEditor.swift`: note replacement and ±15-tick all-sounding-note slice synchronization; partial slices retain the parent region.
- `Sources/CodaMusic/ProgressionEditor.swift`: timed-note-preserving clipboard/duplicate/resize and region replacement in existing transaction history; nonmusical extent growth.
- `Sources/CodaApp/ChordRollEditing.swift` and `CodaEditorStore.swift`: Pencil-only draft/commit ingress, combined draw/erase, body/edge/group transforms, rectangle selection, clipboard, object hold actions, voicing-roll preview/detents. Current Pattern squeeze toggle and circle layout retained; roll tool choices added to that same circle menu.
- `Sources/CodaInteraction/EditorInputModel.swift`: viewport scale independent of growing project extent; visible ranges for virtualized drawing; open horizontal panning.
- `Sources/CodaMusic/PatternEventCompiler.swift`: performance payloads for timed manual notes; pattern attacks use sounding note state. `MusicSession` keeps pattern dimensions aligned with arrangement growth and preserves history across navigation.

In-progress remaining connections: editable note rendering/labels/selection, dynamic visible timeline/strip/pattern ranges, native wide timeline types and bounded playback windows. Stage 2 must inherit and finish any explicit transport/pattern window handoff remainder rather than treating viewport growth as complete playback integration.

Later assigned stages retain save/project hub, three-layer mixer/bass following, real predictor and Qwen artifacts/inference, persistence/MIDI/QoL, whole-app Procreate-style renewal, and final source integration. No claims of those stages' completion are made here.
