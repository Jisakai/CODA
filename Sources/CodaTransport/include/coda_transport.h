#ifndef CODA_TRANSPORT_H
#define CODA_TRANSPORT_H
#include "coda_dsp.h"
#ifdef __cplusplus
extern "C" {
#endif
/* Central transport configuration: 128 grid steps, 12 voices, 3072 events,
   four preallocated slots (one conservatively spare); no render heap ownership. */
enum { CODA_PLAN_EVENTS = 3072, CODA_PLAN_SLOTS = 4 };
typedef struct {
    uint16_t step, region;
    uint8_t kind, pitch, rank, reserved;
} CodaGridEvent;
typedef struct {
    /* Durable cumulative intent within one prepare epoch. Revisions never wrap.
       Configuration copies both revisions/values unchanged; only a new explicit
       command increments its revision. Zero means no command. Playback is bounded
       by INT64_MAX, position by UINT64_MAX; exhaustion requires a fresh epoch.
       Retained seek_step is 0...127, clamped if configuration shrinks the span. */
    uint64_t playback_revision, position_revision;
    double samples_per_step;
    uint32_t count;
    uint16_t length, seek_step;
    uint8_t playing, looping;
    CodaGridEvent events[CODA_PLAN_EVENTS];
} CodaPlan;
/* Compiler-local ownership: only instance is supplied; all other owner fields
   MUST be zero. sample_offset is relative to sample_origin. */
typedef struct {
    uint64_t cycle_index, sample_origin, sample_count;
    uint32_t count;
    CodaPerformanceEvent events[CODA_PLAN_EVENTS];
} CodaPerformanceCycle;
typedef struct {
    uint64_t playback_revision, position_revision;
    double samples_per_step;
    uint16_t length, seek_step;
    uint8_t playing, looping;
    CodaPerformanceCycle initial_cycle;
} CodaPerformancePlan;
typedef struct {
    uint64_t prepare_epoch, generation, cycle, next_requested_cycle, underruns;
    uint32_t queued;
    uint8_t underrun;
    uint64_t applied_generation, rejected_generation, required_cycle;
} CodaPerformanceStatus;
typedef struct CodaTransport CodaTransport;
typedef struct {
    uint64_t clock, cycle, delivered, late, hash;
    uint64_t playback_revision; // render-consumed command, not producer publication
    uint32_t acknowledged, failures, region;
    uint16_t step;
    uint8_t playing;
} CodaTransportStatus;
CodaTransport *coda_transport_create(void);
/* ALL lifecycle calls require serialized producer and excluded render. */
void coda_transport_destroy(CodaTransport *);
int coda_transport_prepare(CodaTransport *, double sample_rate);
/* Copies caller POD synchronously. 1 accepted, 0 full, -1 invalid/unprepared.
   Exactly ONE serialized producer. Retry full; caller retains intent. */
int coda_transport_publish(CodaTransport *, const CodaPlan *);
/* Same serialized producer and configuration ordering as legacy publication.
   1 = QUEUED, not applied. Consumer compatibility check precedes all mutation.
   Observe applied_generation/rejected_generation; rejection preserves cumulative
   command revisions, notes and phase. Recompile for required_cycle and retry the
   same intent. Only a new explicit seek/restart authorizes a cycle reset.
   Output generation changes only on queue success. Full leaves intent intact.
   Each retained generation has its own refill lane; old ACTIVE may be refilled
   until replacement applies. Retired generations return -1. Status never admits.
   queued observes active-lane pending cycles; refill sequence is producer-owned. Status fields are
   individually atomic, observational, NOT a coupled transactional snapshot.
   required_cycle may belong to a newer rejection than rejected_generation.
   Compile using the freshest active cycle and retry on rejection; identify
   application/rejection and stale refill failures by explicit generation. */
int coda_transport_publish_performance(CodaTransport *, const CodaPerformancePlan *, uint64_t *accepted_generation);
int coda_transport_enqueue_performance_cycle(CodaTransport *, uint64_t generation, const CodaPerformanceCycle *);
void coda_transport_performance_status(const CodaTransport *, CodaPerformanceStatus *);
/* Consumer between callbacks or full quiescence ONLY. */
void coda_transport_inspect_performance(const CodaTransport *, CodaPerformanceVoiceDiagnostic out[CODA_DSP_VOICES]);
int coda_transport_controls(CodaTransport *, const CodaControls *);
/* Audition overlays the transport in time, temporarily replacing chord notes.
   Musical clock continues; end restores current chord without editing history.
   Zero pitches cancels. One outstanding command; full is observable. */
int coda_transport_audition(CodaTransport *, const uint8_t *, uint32_t count, uint32_t frames);
/* Single native render consumer. Output is mono float; no allocation/locks. */
void coda_transport_render(CodaTransport *, float *, uint32_t frames);
/* Atomically published control-side status; no reads of mutable DSP state. */
void coda_transport_status(const CodaTransport *, CodaTransportStatus *);
#ifdef __cplusplus
}
#endif
#endif
