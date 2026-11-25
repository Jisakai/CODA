# Owner-authorized narrow fix — Hall reprepare cursor safety

Owner explicitly authorized one further correction after two-pass budget exhaustion. This is NOT permission for another broad DSP iteration.

Read CodaDSP/include/dsp_units.h Hall, actual coda_dsp_prepare/reset/stop, and existing production tests/pass2 regressions before editing. Root C:/Users/jisak/CODA. Codex writes code; Hermes reviews. No local toolchain installs; native checks on Mac CI. No stage/commit/push/CI trigger, no unrelated changes or UI/AV adapter.

## Confirmed sole blocker from final review
Hall::prepare binds newly sized storage but retains write/preWrite/diffWrite. Hall::reset only increments generation and clears damping. On lower-rate reprepare old cursors can exceed new allocations at tick writes. Example: prepare96000/block256, process eight blocks, quiesce, prepare48000, process1: preWrite2048 exceeds new preSize1200. Also exercise longer render to expose FDN write versus shrinking size; diffuser cursors must fit new tap lengths.

## Scope
- Reinitialize all Hall ring/diffusion cursor state consistently when preparing newly bound/re-sized buffers. Preserve correct generation invalidation/damping behavior and documented no-allocation bounded render reset. Trace prepare failure and quiescent lifecycle enough to avoid new misuse; do not refactor unrelated DSP.
- Add production-core regression tests on SAME object: high->low, low->high, repeated same-rate reprepare, reset/reprepare after nonzero cursor positions, including enough samples to push old FDN cursor beyond new capacity. Cover96000->48000 and valid extreme rates where feasible. Verify finite/silent reset output with no notes and normal non-silent playback after new events. Reprepare only with producer/render fully quiescent.
- Regressions must exercise actual public coda_dsp_prepare/process path, not only a duplicated Hall algorithm. Existing Mac ASan/UBSan workflow must execute them. No Python algorithm replica. Native tests unavailable locally; report pending honestly. Existing13 Python checks and whitespace checks feasible.
- Update docs/M1-phase2.md narrowly with fix/test evidence and limitations if needed. Do not edit SPEC/ROADMAP/DECISIONS_LOG/briefs/workflow unless a minimal change is genuinely needed to invoke new tests (existing harness should already include them).

Stop after this narrow fix; report changed paths, concrete tests, actual feasible results. No claim of compilation, sanitizer pass, IPA success, subjective sound or full M1. Any new blocker beyond this scope must be reported to Hermes, not silently expanded.
