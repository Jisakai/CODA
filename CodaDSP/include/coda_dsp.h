#ifndef CODA_DSP_H
#define CODA_DSP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { CODA_DSP_VOICES = 12, CODA_DSP_QUEUE_CAPACITY = 4096, CODA_DSP_MAX_EVENTS_PER_SAMPLE = 64, CODA_MAX_TRACKS = 12 };
typedef enum { CODA_LAYER_CHORDS = 0, CODA_LAYER_BASS = 1, CODA_LAYER_MELODY = 2, CODA_LAYER_COUNT = 3 } CodaLayer;
typedef enum { CODA_PRESET_PLUCK = 0, CODA_PRESET_CURRENTS = 1, CODA_PRESET_WOBBLE = 2 } CodaPreset;
typedef enum { CODA_EVENT_OFF = 0, CODA_EVENT_ON = 1 } CodaEventKind;

typedef struct {
    int64_t sample_offset;
    uint32_t region_id;
    uint8_t kind;
    uint8_t pitch;
    uint8_t voice_rank;
    uint8_t reserved;
} CodaNoteEvent;

typedef struct {
    uint64_t prepare_epoch, plan_generation, cycle, activation, instance;
} CodaNoteOwner;
typedef enum { CODA_ATTACK_ORDINARY = 0, CODA_ATTACK_CHUCK = 1 } CodaAttackMode;
typedef struct {
    int64_t sample_offset;
    CodaNoteOwner owner;
    uint64_t harmonic_token;
    uint8_t kind, pitch, voice_rank, attack_mode;
    float base_velocity, effective_velocity, detune_cents, filter_delta;
    /* Transport-only continuation metadata, copied as POD. flags: bit 0 carry
       from previous window, bit 1 sustain into next. DSP ownership stays native. */
    uint64_t continuation_id;
    uint8_t continuation_flags, slide, layer;
} CodaPerformanceEvent;

typedef struct {
    float wobble, warmth, cutoff, resonance, shape, detune, glide;
    float delay_amount, reverb_amount, chord_level, tempo_bpm;
    uint8_t preset, muted;
    uint8_t reserved[2];
} CodaControls;

typedef struct {
    float wobble, warmth, cutoff, resonance, shape, detune, glide, level;
    uint8_t preset, muted;
    uint8_t reserved[2];
} CodaLayerControls;

typedef struct {
    CodaLayerControls layers[CODA_LAYER_COUNT];
    float chorus_amount, delay_amount, reverb_amount, tempo_bpm;
} CodaMixerControls;

typedef struct CodaDSP CodaDSP;

CodaDSP *coda_dsp_create(void);
void coda_dsp_destroy(CodaDSP *);
/* Fill normalized control defaults for a preset; callers may override any field. */
int coda_dsp_default_controls(uint8_t preset, CodaControls *out);
CodaMixerControls coda_dsp_default_mixer_controls(void);
/* LIFECYCLE CONTRACT: prepare/reset/stop/destroy require full render AND
   producer quiescence; caller must stop/join both before calling. No concurrent
   lifecycle calls. Prepare/reset may allocate/clear storage. Stop immediately
   invalidates voices, FX and queued controls/events; process then writes silence.
   Reset or prepare resumes at sample zero. Fade/mute before stop for continuity. */
int coda_dsp_prepare(CodaDSP *, double sample_rate, uint32_t max_block_size);
void coda_dsp_reset(CodaDSP *);
/* SPSC: exactly one serialized control/event producer and one render consumer.
   Event publication rejects invalid kind/pitch/rank, descending offsets,
   off-after-on at a tie, >64 events at an offset, full queue, or stopped state.
   False leaves producer admission state unchanged. Usable capacity 4095.
   Publish before the block containing the offset STARTS; late publication is a
   caller violation. Ranks are 0..11, sorted by pitch within one harmonic region;
   all simultaneous ons describe ONE new region. Region IDs identify notes/offs.
   Producer must not refill the same offset after render has begun that block. */
int coda_dsp_publish_controls(CodaDSP *, const CodaControls *);
int coda_dsp_publish_mixer_controls(CodaDSP *, const CodaMixerControls *);
int coda_dsp_publish_track_controls(CodaDSP *, uint8_t track_index, uint8_t eq_profile, const CodaLayerControls *);
int coda_dsp_push_event(CodaDSP *, const CodaNoteEvent *);
/* Shares legacy FIFO/admission. All owner identity fields and harmonic_token MUST be
   nonzero; only owner.cycle may be zero. OFF matches ALL owner fields + pitch, not rank/harmonic.
   Caller supplies nonwrapping runtime identities; compiler tokens alone are
   insufficient. Both kinds require fully valid modulation/velocity payloads. */
int coda_dsp_push_performance_event(CodaDSP *, const CodaPerformanceEvent *);
/* Queue ordered by absolute sample_offset from reset; offs precede ons at ties. */
int coda_dsp_process(CodaDSP *, float *mono_output, uint32_t frame_count);
void coda_dsp_stop(CodaDSP *);
/* Bounded observational diagnostics: consumer thread between process calls,
   or under full quiescence only. No concurrent read of render state. */
typedef struct {
    uint32_t region;
    float amplitude, frequency, target_frequency;
    uint8_t active, stage, preset, rank; /* stage: idle/attack/decay/sustain/release = 0..4 */
} CodaVoiceDiagnostic;
typedef struct {
    uint64_t sample_clock, delivered, late, event_hash, effect_generation;
    float mute_gain;
    CodaVoiceDiagnostic voices[CODA_DSP_VOICES];
} CodaDSPDiagnostics;
void coda_dsp_inspect(const CodaDSP *, CodaDSPDiagnostics *);
typedef struct {
    CodaNoteOwner owner;
    uint64_t harmonic_token;
    float base_velocity, effective_velocity, detune_cents, filter_delta;
    uint8_t active, performance, pitch, rank, attack_mode, releasing;
} CodaPerformanceVoiceDiagnostic;
/* Same consumer-between-blocks/quiescence restriction as coda_dsp_inspect. */
void coda_dsp_inspect_performance(const CodaDSP *, CodaPerformanceVoiceDiagnostic out[CODA_DSP_VOICES]);

#ifdef __cplusplus
}
#endif
#endif
