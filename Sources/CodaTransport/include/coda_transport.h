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
