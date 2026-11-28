#include "coda_dsp.h"
#include "dsp_units.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <iterator>
#include <new>

namespace {
constexpr float kPi = 3.14159265358979323846f;
constexpr float kTwoPi = 2.0f * kPi;
constexpr uint32_t kDelayMaxSeconds = 2;
constexpr uint32_t kReverbMaxSeconds = 3;
constexpr float kDefaultMaster = 0.22f;
constexpr float kMaxResonance = 0.72f;
constexpr float kStealFadeSeconds = 0.004f;
constexpr float kDelayFeedback = 0.36f;
constexpr float kSmoothingSeconds = 0.012f;
constexpr uint32_t kControlDrainLimit = 8;
// Provisional feel constants; owner listening acceptance remains required.
constexpr float kChuckAttackSeconds=.002f, kChuckDecaySeconds=.035f;
constexpr float kChuckReleaseSeconds=.018f, kChuckFilterSeconds=.008f;
constexpr float kChuckNoiseSeconds=.012f, kChuckNoiseLevel=.24f;

struct Event : CodaNoteEvent {
    bool performance=false;
    uint8_t layer=CODA_LAYER_CHORDS;
    CodaPerformanceEvent payload{};
};
bool equal_owner(const CodaNoteOwner &a,const CodaNoteOwner &b) noexcept {
    return a.prepare_epoch==b.prepare_epoch && a.plan_generation==b.plan_generation &&
        a.cycle==b.cycle && a.activation==b.activation && a.instance==b.instance;
}
bool equal_harmonic(const CodaPerformanceEvent &a,const CodaPerformanceEvent &b) noexcept {
    auto owner=a.owner; owner.instance=b.owner.instance;
    return equal_owner(owner,b.owner) && a.harmonic_token==b.harmonic_token;
}

inline float clampf(float x, float lo, float hi) { return std::max(lo, std::min(x, hi)); }
inline float poly_blep(float t, float dt) {
    if (t < dt) { t /= dt; return t + t - t * t - 1.0f; }
    if (t > 1.0f - dt) { t = (t - 1.0f) / dt; return t * t + t + t + 1.0f; }
    return 0.0f;
}
inline float soft_sat(float x, float drive) {
    const float y = x * drive;
    return y / (1.0f + std::abs(y));
}
inline float flush_denormal(float x) { return std::abs(x)<1.0e-20f ? 0.0f : x; }

struct PresetSpec {
    uint8_t oscillatorA, oscillatorB;
    float oscillatorBLevel, attack, decay, sustain, release, detuneCents, subLevel;
    float chorusBaseSeconds, phaserBaseMix, driftBase, glideDefault;
};
constexpr std::array<PresetSpec,3> kPresets{{
    {0,1,0.24f,0.003f,0.34f,0.0f,0.36f,8.0f,0.090f,0.0014f,0.00f,0.00018f,0.0f},
    {0,0,0.12f,0.42f,0.60f,0.78f,1.80f,14.0f,0.075f,0.0020f,0.18f,0.0003f,0.0f},
    {2,1,0.28f,0.012f,0.18f,0.72f,0.55f,14.0f,0.045f,0.0015f,0.12f,0.0008f,0.35f}
}};

struct LayerControls {
    float wobble=0, warmth=0, cutoff=0.64f, resonance=0.18f, shape=0.35f;
    float detune=0.22f, glide=0, level=1;
    uint8_t preset=CODA_PRESET_PLUCK;
    bool muted=false;
};
struct MixerControls {
    std::array<LayerControls, CODA_LAYER_COUNT> layers{};
    float chorus=0.16f, delay=0.16f, reverb=0.14f, tempo=124;
    bool legacyMute=false;
};
struct TrackControlUpdate {
    uint8_t trackIndex=0;
    uint8_t eqProfile=0;
    LayerControls controls{};
};

bool decode_layer_controls(const CodaLayerControls &in, LayerControls &out) {
    if (in.preset > CODA_PRESET_WOBBLE) return false;
    const float vals[] = {in.wobble,in.warmth,in.cutoff,in.resonance,in.shape,in.detune,in.glide,in.level};
    for (float v : vals) if (!std::isfinite(v)) return false;
    out.wobble=clampf(in.wobble,0,1); out.warmth=clampf(in.warmth,0,1);
    out.cutoff=clampf(in.cutoff,0.015f,0.98f); out.resonance=clampf(in.resonance,0,kMaxResonance);
    out.shape=clampf(in.shape,0,1); out.detune=clampf(in.detune,0,1);
    out.glide=clampf(in.glide,0,1); out.level=clampf(in.level,0,1);
    out.preset=in.preset; out.muted=in.muted != 0;
    return true;
}

bool decode_mixer_controls(const CodaMixerControls &in, MixerControls &out) {
    for (int i = 0; i < CODA_LAYER_COUNT; ++i) {
        if (!decode_layer_controls(in.layers[i], out.layers[i])) return false;
    }
    const float shared[] = {in.chorus_amount, in.delay_amount, in.reverb_amount, in.tempo_bpm};
    for (float v : shared) if (!std::isfinite(v)) return false;
    if (in.tempo_bpm <= 0) return false;
    out.chorus=clampf(in.chorus_amount,0,1);
    out.delay=clampf(in.delay_amount,0,1);
    out.reverb=clampf(in.reverb_amount,0,1);
    out.tempo=clampf(in.tempo_bpm,30,300);
    out.legacyMute=false;
    return true;
}

bool decode_legacy_controls(const CodaControls &in, const MixerControls &base, MixerControls &out) {
    if (in.preset > CODA_PRESET_WOBBLE) return false;
    const float vals[] = {in.wobble,in.warmth,in.cutoff,in.resonance,in.shape,in.detune,in.glide,
        in.delay_amount,in.reverb_amount,in.chord_level,in.tempo_bpm};
    for (float v : vals) if (!std::isfinite(v)) return false;
    if (in.tempo_bpm <= 0) return false;
    out = base;
    auto &l0 = out.layers[CODA_LAYER_CHORDS];
    l0.wobble=clampf(in.wobble,0,1); l0.warmth=clampf(in.warmth,0,1);
    l0.cutoff=clampf(in.cutoff,0.015f,0.98f); l0.resonance=clampf(in.resonance,0,kMaxResonance);
    l0.shape=clampf(in.shape,0,1); l0.detune=clampf(in.detune,0,1); l0.glide=clampf(in.glide,0,1);
    l0.level=clampf(in.chord_level,0,1); l0.preset=in.preset; l0.muted=in.muted != 0;
    out.delay=clampf(in.delay_amount,0,1); out.reverb=clampf(in.reverb_amount,0,1);
    out.tempo=clampf(in.tempo_bpm,30,300);
    out.legacyMute = in.muted != 0;
    return true;
}

struct Voice {
    bool active=false, releasing=false, performance=false;
    CodaPerformanceEvent payload{};
    float noteDetuneRatio=1, noiseEnvelope=0; uint32_t noiseState=1;
    coda::Envelope envelope{};
    uint8_t preset=0;
    uint32_t region=0;
    uint8_t pitch=0, rank=0;
    float phase[6]{}, triState[6]{}, subPhase=0, frequency=0, targetFrequency=0, amp=0, filterEnv=0, velocity=0.8f;
    float filterIc1=0, filterIc2=0, stealTail=0, lastOutput=0, stealGain=1;
    uint64_t age=0;
    uint32_t stealRemaining=0, stealTotal=1;
};

struct LayerEngine {
    std::array<Voice,CODA_DSP_VOICES> voices{};
    LayerControls target{}, smooth{};
    uint8_t eqProfile=0;
    bool used=false;
    coda::ChordsEQ chordsEQ{};
    coda::BassEQ bassEQ{};
    coda::MelodyEQ melodyEQ{};
    float *chorusBuf=nullptr;
    uint64_t *chorusGen=nullptr;
    uint32_t chorusWrite=0;
    uint64_t chorusGeneration=1;
    float chorusPhase=0, phaserPhase=0, driftPhase=0, muteGain=1, presetGain=1;
    bool presetSwitchPending=false, muteInvalidationPending=false;
    float phaserState[4]{};
    float detuneRatio[3]{1.0f,1.0f,1.0f};
    uint32_t region=0;
    bool hasRegion=false;
    bool harmonicPerformance=false;
    CodaPerformanceEvent harmonic{};
    std::array<float,CODA_DSP_VOICES> regionFrequency{}, predecessor{};
    std::array<bool,CODA_DSP_VOICES> regionPresent{}, predecessorPresent{};
};

struct SPSCEvents {
    std::array<Event,CODA_DSP_QUEUE_CAPACITY> data{};
    alignas(64) std::atomic<uint32_t> head{0};
    alignas(64) std::atomic<uint32_t> tail{0};
    bool push(const Event &e) noexcept {
        const uint32_t h=head.load(std::memory_order_relaxed), n=(h+1)%CODA_DSP_QUEUE_CAPACITY;
        if (n==tail.load(std::memory_order_acquire)) return false;
        data[h]=e; head.store(n,std::memory_order_release); return true;
    }
    bool pop(Event &e) noexcept {
        const uint32_t t=tail.load(std::memory_order_relaxed);
        if (t==head.load(std::memory_order_acquire)) return false;
        e=data[t]; tail.store((t+1)%CODA_DSP_QUEUE_CAPACITY,std::memory_order_release); return true;
    }
};
static_assert(std::atomic<uint32_t>::is_always_lock_free, "SPSC indices must be lock-free");
struct SPSCControls {
    std::array<MixerControls,8> data{};
    alignas(64) std::atomic<uint32_t> head{0};
    alignas(64) std::atomic<uint32_t> tail{0};
    bool push(const MixerControls &v) noexcept {
        const uint32_t h=head.load(std::memory_order_relaxed), n=(h+1)%data.size();
        if (n==tail.load(std::memory_order_acquire)) return false;
        data[h]=v; head.store(n,std::memory_order_release); return true;
    }
    bool pop(MixerControls &v) noexcept {
        const uint32_t t=tail.load(std::memory_order_relaxed);
        if (t==head.load(std::memory_order_acquire)) return false;
        v=data[t]; tail.store((t+1)%data.size(),std::memory_order_release); return true;
    }
};
struct SPSCTrackControls {
    std::array<TrackControlUpdate,32> data{};
    alignas(64) std::atomic<uint32_t> head{0};
    alignas(64) std::atomic<uint32_t> tail{0};
    bool push(const TrackControlUpdate &v) noexcept {
        const uint32_t h=head.load(std::memory_order_relaxed), n=(h+1)%data.size();
        if (n==tail.load(std::memory_order_acquire)) return false;
        data[h]=v; head.store(n,std::memory_order_release); return true;
    }
    bool pop(TrackControlUpdate &v) noexcept {
        const uint32_t t=tail.load(std::memory_order_relaxed);
        if (t==head.load(std::memory_order_acquire)) return false;
        v=data[t]; tail.store((t+1)%data.size(),std::memory_order_release); return true;
    }
};
}

struct CodaDSP {
    double rate=0;
    uint32_t maxBlock=0;
    std::array<LayerEngine,CODA_MAX_TRACKS> layers{};
    SPSCEvents events{};
    SPSCControls controls{};
    SPSCTrackControls trackControls{};
    MixerControls lastPublishedMixer{};
    float targetChorus=0.16f, targetDelay=0.16f, targetReverb=0.14f, targetTempo=124.0f;
    float smoothChorus=0.16f, smoothDelay=0.16f, smoothReverb=0.14f, smoothTempo=124.0f;
    bool legacyMute=false;
    Event pending{}; bool hasPending=false;
    std::array<float,3> *delay=nullptr;
    std::array<float,4> *reverb=nullptr;
    float *predelay=nullptr;
    float *masterChorus=nullptr;
    uint64_t *delayGeneration=nullptr, *reverbGeneration=nullptr, *predelayGeneration=nullptr, *masterChorusGen=nullptr;
    uint32_t delaySize=0, delayWrite=0, reverbSize=0, predelaySize=0, chorusSize=0, masterChorusSize=0, masterChorusWrite=0;
    uint64_t effectGeneration=1;
    float muteGain=1;
    coda::MasterEQ masterEQ{};
    coda::Hall hall{};
    bool muteInvalidationPending=false;
    bool stopped=false;
    int64_t publishedOffset=-1;
    uint32_t publishedAtOffset=0;
    uint8_t publishedKind=0;
    float chuckFilterDecay=1, chuckNoiseDecay=1;
    uint64_t delivered=0, late=0, eventHash=1469598103934665603ull;
    std::array<float,512> filterG{};
    float filterEnvDecay=1.0f;
    float delayLowpassCoeff=0.3f, delayLp=0, delayHpCoeff=0.02f, delayHp=0;
    float masterChorusPhaseA=0, masterChorusPhaseB=0, delayWowPhase=0;
    uint64_t sampleClock=0;
};

namespace {
void release_voice(Voice &v) noexcept { if (v.active) {v.releasing=true;v.envelope.off();} }

float tick_layer_eq(LayerEngine &l, float x) noexcept {
    switch (l.eqProfile) {
    case CODA_LAYER_CHORDS: return l.chordsEQ.tick(x);
    case CODA_LAYER_BASS: return l.bassEQ.tick(x);
    case CODA_LAYER_MELODY: return l.melodyEQ.tick(x);
    default: return x;
    }
}
void reset_layer_eq(LayerEngine &l) noexcept {
    l.chordsEQ.reset();
    l.bassEQ.reset();
    l.melodyEQ.reset();
}
bool all_used_layers_muted(const CodaDSP &d, bool useTarget) noexcept {
    if (d.legacyMute) return true;
    for (int i = 0; i < CODA_MAX_TRACKS; ++i) {
        if (!d.layers[i].used) continue;
        const bool m = useTarget ? d.layers[i].target.muted : d.layers[i].smooth.muted;
        if (!m) return false;
    }
    return true;
}

void note_on(CodaDSP &d, LayerEngine &l, const Event &e) noexcept {
    if(!l.hasRegion || l.harmonicPerformance!=e.performance ||
       (e.performance ? !equal_harmonic(l.harmonic,e.payload) : l.region!=e.region_id)) {
        l.predecessor=l.regionFrequency;l.predecessorPresent=l.regionPresent;
        l.regionPresent.fill(false);l.region=e.region_id;l.hasRegion=true;
        l.harmonicPerformance=e.performance;l.harmonic=e.payload;
    }
    Voice *slot=nullptr;
    for (auto &v:l.voices) if (v.active && v.performance==e.performance && v.pitch==e.pitch &&
        (e.performance || v.region==e.region_id)) { slot=&v; break; }
    if (!slot) for (auto &v:l.voices) if (!v.active) { slot=&v; break; }
    if (!slot) {
        slot=&l.voices[0];
        for (auto &v:l.voices) if ((v.releasing && !slot->releasing) || (v.releasing==slot->releasing && v.age<slot->age)) slot=&v;
        slot->stealTail=slot->lastOutput;
        slot->stealTotal=std::max(1u,static_cast<uint32_t>(kStealFadeSeconds*d.rate));
        slot->stealRemaining=slot->stealTotal;
    }
    if(e.performance && slot->active && slot->stealRemaining==0) {
        slot->stealTail=slot->lastOutput;
        slot->stealTotal=std::max(1u,static_cast<uint32_t>(kStealFadeSeconds*d.rate));
        slot->stealRemaining=slot->stealTotal;
    }
    Voice &v=*slot;
    const float midi=440.0f*std::pow(2.0f,(static_cast<int>(e.pitch)-69)/12.0f);
    const bool canGlide=(l.smooth.glide>0.001f || (e.performance && e.payload.slide)) && l.predecessorPresent[e.voice_rank];
    const float old=l.predecessor[e.voice_rank];
    v.active=true; v.releasing=false; v.region=e.region_id; v.pitch=e.pitch; v.rank=e.voice_rank;
    v.targetFrequency=midi; v.frequency=canGlide ? old : midi; v.amp=0; v.envelope.on(); v.preset=l.smooth.preset; v.filterEnv=1.0f;
    v.filterIc1=v.filterIc2=0;
    v.performance=e.performance; v.payload=e.payload;
    v.velocity=e.performance?e.payload.effective_velocity:0.8f;
    v.noteDetuneRatio=e.performance?std::pow(2.0f,e.payload.detune_cents/1200.0f):1.0f;
    v.noiseEnvelope=1; v.noiseState=static_cast<uint32_t>(e.payload.owner.instance)^0x9e3779b9u;
    if(!v.noiseState) v.noiseState=1;
    v.age=d.sampleClock;
    if(slot->stealRemaining==0) v.stealGain=1.0f;
    l.regionFrequency[e.voice_rank]=midi; l.regionPresent[e.voice_rank]=true;
}

void note_off(LayerEngine &l, const Event &e) noexcept {
    for (auto &v:l.voices) if (v.active && v.performance==e.performance && v.pitch==e.pitch &&
        (e.performance?equal_owner(v.payload.owner,e.payload.owner):v.region==e.region_id)) release_voice(v);
}

float oscillator(float phase, float increment, uint8_t shape, float &triangleState) noexcept {
    const float t=phase/kTwoPi;
    const float saw=2.0f*t-1.0f-poly_blep(t,increment/kTwoPi);
    float square=t<0.5f?1.0f:-1.0f;
    square+=poly_blep(t,increment/kTwoPi);
    float t2=t+0.5f; if(t2>=1)t2-=1;
    square-=poly_blep(t2,increment/kTwoPi);
    triangleState=0.9995f*triangleState+4.0f*increment/kTwoPi*square;
    if(shape==0) return saw;
    if(shape==1) return square;
    return clampf(triangleState,-1.0f,1.0f);
}

float voice_sample(CodaDSP &d, LayerEngine &l, Voice &v) noexcept {
    const LayerControls &c=l.smooth;
    const PresetSpec &spec=kPresets[v.preset];
    const float glideAmount=(v.performance && v.payload.slide)?std::max(0.2f,c.glide):c.glide;
    const float glideSeconds=glideAmount>0.001f?(0.012f+0.45f*glideAmount):0.0f;
    if(glideSeconds>0) v.frequency += (v.targetFrequency-v.frequency)/(glideSeconds*static_cast<float>(d.rate));
    else v.frequency=v.targetFrequency;
    const float shapeScale=0.5f+1.5f*c.shape;
    const bool chuck=v.performance && v.payload.attack_mode==CODA_ATTACK_CHUCK;
    v.amp=chuck?v.envelope.tick(d.rate,kChuckAttackSeconds,kChuckDecaySeconds,0,kChuckReleaseSeconds):
        v.envelope.tick(d.rate,spec.attack*shapeScale,spec.decay,spec.sustain,spec.release*shapeScale);
    if(v.envelope.stage==coda::Stage::idle) {v.active=false;return 0;}
    const float wobble=c.wobble;
    l.driftPhase+=kTwoPi*(0.07f+0.55f*wobble)/static_cast<float>(d.rate); if(l.driftPhase>=kTwoPi)l.driftPhase-=kTwoPi;
    const float drift=std::sin(l.driftPhase)*(spec.driftBase+0.0025f*wobble);
    const float center=v.frequency*(1.0f+drift)*v.noteDetuneRatio;
    float bankA=0,bankB=0;
    for(int i=0;i<3;i++) {
        const float hz=center*l.detuneRatio[i];
        const float inc=std::min(kTwoPi*0.45f,hz*kTwoPi/static_cast<float>(d.rate));
        const float oscA=oscillator(v.phase[i*2],inc,spec.oscillatorA,v.triState[i*2]);
        const float oscB=oscillator(v.phase[i*2+1],inc,spec.oscillatorB,v.triState[i*2+1]);
        for(int bank=0;bank<2;bank++) { float &phase=v.phase[i*2+bank];phase+=inc;if(phase>=kTwoPi)phase-=kTwoPi; }
        const float weight=i==1?0.42f:0.29f;
        bankA+=oscA*weight; bankB+=oscB*weight;
    }
    float raw=bankA*(1.0f-spec.oscillatorBLevel)+bankB*spec.oscillatorBLevel;
    const float subHz=center*0.5f, subInc=std::min(kTwoPi*0.45f,subHz*kTwoPi/static_cast<float>(d.rate));
    const float sub=std::sin(v.subPhase)*spec.subLevel;
    v.subPhase+=subInc;if(v.subPhase>=kTwoPi)v.subPhase-=kTwoPi;
    raw+=sub;
    if(chuck) {
        v.noiseState^=v.noiseState<<13;v.noiseState^=v.noiseState>>17;v.noiseState^=v.noiseState<<5;
        raw+=(static_cast<float>(v.noiseState>>8)*(2.0f/16777215.0f)-1.0f)*v.noiseEnvelope*kChuckNoiseLevel;
        v.noiseEnvelope=flush_denormal(v.noiseEnvelope*d.chuckNoiseDecay);
    }
    v.filterEnv*=chuck?d.chuckFilterDecay:d.filterEnvDecay;
    const float filterEnvDepth=(v.preset==CODA_PRESET_PLUCK && !chuck)?0.34f:0.20f;
    const float cutoffNorm=clampf(c.cutoff*(1.0f-0.28f*c.warmth)+filterEnvDepth*v.filterEnv+(v.performance?v.payload.filter_delta:0.0f),0,1);
    const uint32_t cutoffIndex=static_cast<uint32_t>(cutoffNorm*511.0f+0.5f);
    const float g=d.filterG[cutoffIndex];
    const float k=2.0f-1.85f*c.resonance;
    const float a1=1.0f/(1.0f+g*(g+k));
    const float v1=a1*(v.filterIc1+g*(raw-v.filterIc2));
    const float v2=v.filterIc2+g*v1;
    v.filterIc1=flush_denormal(2.0f*v1-v.filterIc1); v.filterIc2=flush_denormal(2.0f*v2-v.filterIc2);
    float out=v2;
    const float sat=1.0f+0.5f*c.warmth;
    out=soft_sat(out,sat);
    float result=out*v.amp*v.velocity*v.stealGain;
    if(v.stealRemaining) {
        result+=v.stealTail*(static_cast<float>(v.stealRemaining)/static_cast<float>(v.stealTotal));
        --v.stealRemaining;
        if(v.stealRemaining==0) v.stealTail=0;
    }
    v.lastOutput=result;
    return result;
}

float process_sample(CodaDSP &d) noexcept {
    const float alpha=1.0f-std::exp(-1.0f/(kSmoothingSeconds*static_cast<float>(d.rate)));
    const float fadeStep=1.0f/std::max(1.0f,0.012f*static_cast<float>(d.rate));
    const float muteStep=1.0f/std::max(1.0f,coda::muteSeconds*static_cast<float>(d.rate));

    d.smoothChorus=flush_denormal(d.smoothChorus+alpha*(d.targetChorus-d.smoothChorus));
    d.smoothDelay=flush_denormal(d.smoothDelay+alpha*(d.targetDelay-d.smoothDelay));
    d.smoothReverb=flush_denormal(d.smoothReverb+alpha*(d.targetReverb-d.smoothReverb));
    d.smoothTempo=flush_denormal(d.smoothTempo+alpha*(d.targetTempo-d.smoothTempo));

    for(int li=0;li<CODA_MAX_TRACKS;++li) {
        auto &l=d.layers[li];
        if(!l.used) continue;
#define SMOOTH_L(field) l.smooth.field=flush_denormal(l.smooth.field+alpha*(l.target.field-l.smooth.field))
        SMOOTH_L(wobble); SMOOTH_L(warmth); SMOOTH_L(cutoff); SMOOTH_L(resonance);
        SMOOTH_L(shape); SMOOTH_L(detune); SMOOTH_L(glide); SMOOTH_L(level);
#undef SMOOTH_L
        l.smooth.muted=l.target.muted;
        if(l.presetSwitchPending) {
            bool hasVoice=false;
            for(const auto &voice:l.voices) hasVoice|=voice.active;
            if(!hasVoice) { l.smooth.preset=l.target.preset; l.presetGain=1.0f; l.presetSwitchPending=false; }
            else {
                l.presetGain=std::max(0.0f,l.presetGain-fadeStep);
                if(l.presetGain<=0.0f) { l.smooth.preset=l.target.preset; l.presetSwitchPending=false; }
            }
        } else {
            l.presetGain=std::min(1.0f,l.presetGain+fadeStep);
        }
        for(const auto &v:l.voices) if(v.active && v.performance==l.harmonicPerformance &&
            (v.performance?equal_harmonic(v.payload,l.harmonic):v.region==l.region))
            l.regionFrequency[v.rank]=v.frequency;
    }

    for(uint32_t applied=0;applied<CODA_DSP_MAX_EVENTS_PER_SAMPLE;applied++) {
        if(!d.hasPending&&d.events.pop(d.pending)) d.hasPending=true;
        if(!d.hasPending||d.pending.sample_offset>static_cast<int64_t>(d.sampleClock)) break;
        if(d.pending.layer<CODA_MAX_TRACKS) {
            auto &targetLayer=d.layers[d.pending.layer];
            targetLayer.used=true;
            if(d.pending.kind==CODA_EVENT_OFF) note_off(targetLayer,d.pending);
            else note_on(d,targetLayer,d.pending);
        }
        ++d.delivered;
        if(d.pending.sample_offset!=static_cast<int64_t>(d.sampleClock)) ++d.late;
        d.eventHash=(d.eventHash ^ static_cast<uint64_t>(d.pending.sample_offset))*1099511628211ull;
        if(d.pending.performance) {
            const auto &p=d.pending.payload;
            const uint64_t words[]={0x50455246ull,p.owner.prepare_epoch,p.owner.plan_generation,p.owner.cycle,
                p.owner.activation,p.owner.instance,p.harmonic_token,p.pitch,p.voice_rank,p.attack_mode,p.layer};
            for(auto word:words) d.eventHash=(d.eventHash^word)*1099511628211ull;
            const float values[]={p.base_velocity,p.effective_velocity,p.detune_cents,p.filter_delta};
            for(float value:values){uint32_t bits;std::memcpy(&bits,&value,sizeof(bits));d.eventHash=(d.eventHash^bits)*1099511628211ull;}
        } else {
            d.eventHash=(d.eventHash ^ d.pending.region_id)*1099511628211ull;
        }
        d.eventHash=(d.eventHash ^ d.pending.kind)*1099511628211ull;
        d.hasPending=false;
    }

    float sum=0.0f;
    const uint32_t chorusN=d.chorusSize;
    for(int li=0;li<CODA_MAX_TRACKS;++li) {
        auto &l=d.layers[li];
        if(!l.used) continue;
        const PresetSpec &spec=kPresets[l.smooth.preset];
        for(int i=0;i<3;i++) l.detuneRatio[i]=std::pow(2.0f,(static_cast<float>(i)-1.0f)*l.smooth.detune*spec.detuneCents/1200.0f);
        float dry=0.0f;
        for(auto &v:l.voices) if(v.active) dry+=voice_sample(d,l,v);
        dry*=0.20f;

        const float chorusDepth=(spec.chorusBaseSeconds+0.005f*l.smooth.wobble)*static_cast<float>(d.rate);
        l.chorusPhase+=kTwoPi*(0.18f+0.52f*l.smooth.wobble)/static_cast<float>(d.rate);
        if(l.chorusPhase>=kTwoPi) l.chorusPhase-=kTwoPi;
        l.phaserPhase+=kTwoPi*(0.07f+0.35f*l.smooth.wobble)/static_cast<float>(d.rate);
        if(l.phaserPhase>=kTwoPi) l.phaserPhase-=kTwoPi;

        const uint32_t mod=static_cast<uint32_t>((0.5f+0.5f*std::sin(l.chorusPhase))*chorusDepth);
        const uint32_t chorusDelay=static_cast<uint32_t>(0.018f*static_cast<float>(d.rate))+mod;
        const uint32_t chorusIndex=(l.chorusWrite+chorusN-std::min(chorusN-1,chorusDelay))%chorusN;
        const float chorus=l.chorusGen[chorusIndex]==l.chorusGeneration?l.chorusBuf[chorusIndex]:0.0f;
        const bool layerMuted=l.muteGain<=0.0f && !l.muteInvalidationPending;
        l.chorusBuf[l.chorusWrite]=layerMuted?0.0f:clampf(dry,-2.0f,2.0f);
        l.chorusGen[l.chorusWrite]=l.chorusGeneration;
        l.chorusWrite=(l.chorusWrite+1)%chorusN;

        float phased=dry;
        const float coeff=0.12f+0.76f*(0.5f+0.5f*std::sin(l.phaserPhase));
        for(int stage=0;stage<4;stage++) {
            const float y=-coeff*phased+l.phaserState[stage];
            l.phaserState[stage]=flush_denormal(phased+coeff*y);
            phased=y;
        }
        float insert=dry+0.12f*chorus+(spec.phaserBaseMix+0.20f*l.smooth.wobble)*phased;
        insert=soft_sat(insert,1.0f+0.65f*l.smooth.warmth+0.15f*l.smooth.wobble);
        float layerOut=tick_layer_eq(l,insert);

        const float wantedLayerMute=(l.muteInvalidationPending||l.smooth.muted)?0.0f:1.0f;
        l.muteGain+=clampf(wantedLayerMute-l.muteGain,-muteStep,muteStep);
        layerOut*=l.smooth.level*l.smooth.level*l.muteGain*l.presetGain;
        if(l.muteInvalidationPending && l.muteGain<=0.0f) {
            ++l.chorusGeneration;
            std::fill(std::begin(l.phaserState),std::end(l.phaserState),0.0f);
            reset_layer_eq(l);
            l.muteInvalidationPending=false;
        }
        sum+=layerOut;
    }

    const bool allMuted=all_used_layers_muted(d,false);
    const bool masterMuted=d.muteGain<=0 && !d.muteInvalidationPending;

    // 1. Master Post-FX Analog Chorus (dual-tap quadrature modulated BBD/Juno style).
    const uint32_t mcN=d.masterChorusSize;
    d.masterChorusPhaseA+=kTwoPi*0.42f/static_cast<float>(d.rate);
    if(d.masterChorusPhaseA>=kTwoPi) d.masterChorusPhaseA-=kTwoPi;
    d.masterChorusPhaseB+=kTwoPi*0.67f/static_cast<float>(d.rate);
    if(d.masterChorusPhaseB>=kTwoPi) d.masterChorusPhaseB-=kTwoPi;
    auto readMasterChorus=[&](float delaySamples) noexcept -> float {
        const float clamped=clampf(delaySamples,1.0f,static_cast<float>(mcN-2));
        const uint32_t i0=static_cast<uint32_t>(clamped);
        const float frac=clamped-static_cast<float>(i0);
        const uint32_t idx0=(d.masterChorusWrite+mcN-i0)%mcN;
        const uint32_t idx1=(idx0+mcN-1)%mcN;
        const float s0=d.masterChorusGen[idx0]==d.effectGeneration?d.masterChorus[idx0]:0.0f;
        const float s1=d.masterChorusGen[idx1]==d.effectGeneration?d.masterChorus[idx1]:0.0f;
        return s0+(s1-s0)*frac;
    };
    const float mcBaseA=(0.0085f+0.0042f*std::sin(d.masterChorusPhaseA))*static_cast<float>(d.rate);
    const float mcBaseB=(0.0135f+0.0048f*std::cos(d.masterChorusPhaseB))*static_cast<float>(d.rate);
    const float mcWet=0.5f*(readMasterChorus(mcBaseA)+readMasterChorus(mcBaseB));
    d.masterChorus[d.masterChorusWrite]=masterMuted?0.0f:clampf(sum+mcWet*0.12f,-2.0f,2.0f);
    d.masterChorusGen[d.masterChorusWrite]=d.effectGeneration;
    d.masterChorusWrite=(d.masterChorusWrite+1)%mcN;
    const float chorused=sum+d.smoothChorus*0.42f*mcWet;

    // 2. Revised Dual-Tap Tape Delay (dotted-eighth primary + eighth cross-tap,
    //    subtle tape wow, 160Hz HPF + 3.4kHz LPF feedback damping, warm tape saturation).
    const uint32_t delayN=d.delaySize;
    d.delayWowPhase+=kTwoPi*0.55f/static_cast<float>(d.rate);
    if(d.delayWowPhase>=kTwoPi) d.delayWowPhase-=kTwoPi;
    const float wowSamples=0.0006f*static_cast<float>(d.rate)*std::sin(d.delayWowPhase);
    const float beatSamples=static_cast<float>(d.rate*60.0/d.smoothTempo);
    auto readDelay=[&](float delaySamples) noexcept -> float {
        const float clamped=clampf(delaySamples,1.0f,static_cast<float>(delayN-2));
        const uint32_t i0=static_cast<uint32_t>(clamped);
        const float frac=clamped-static_cast<float>(i0);
        const uint32_t idx0=(d.delayWrite+delayN-i0)%delayN;
        const uint32_t idx1=(idx0+delayN-1)%delayN;
        const float s0=d.delayGeneration[idx0]==d.effectGeneration?d.delay[idx0][0]:0.0f;
        const float s1=d.delayGeneration[idx1]==d.effectGeneration?d.delay[idx1][0]:0.0f;
        return s0+(s1-s0)*frac;
    };
    const float primaryTap=readDelay(beatSamples*0.75f+wowSamples);
    const float crossTap=readDelay(beatSamples*0.50f-wowSamples*0.5f);
    float echo=primaryTap*0.72f+crossTap*0.32f;
    d.delayHp=flush_denormal(d.delayHp+d.delayHpCoeff*(echo-d.delayHp));
    const float echoHp=echo-d.delayHp;
    d.delayLp=flush_denormal(d.delayLp+d.delayLowpassCoeff*(echoHp-d.delayLp));
    echo=d.delayLp;
    const float fbSample=soft_sat(chorused+d.delayLp*kDelayFeedback,1.12f);
    d.delay[d.delayWrite][0]=masterMuted?0.0f:clampf(fbSample,-2.0f,2.0f);
    d.delayGeneration[d.delayWrite]=d.effectGeneration;
    d.delayWrite=(d.delayWrite+1)%delayN;

    // 3. Revised Modulated Hall Reverb (fed by chorused bus + subtle delay tail bloom).
    const float rv=d.hall.tick(masterMuted?0.0f:(chorused*0.24f+echo*d.smoothDelay*0.12f));

    const float wet=d.smoothDelay*echo+d.smoothReverb*rv;
    const float wantedMaster=(d.muteInvalidationPending||allMuted)?0.0f:1.0f;
    d.muteGain+=clampf(wantedMaster-d.muteGain,-muteStep,muteStep);
    float out=d.masterEQ.tick(chorused+wet)*d.muteGain*kDefaultMaster;
    out=soft_sat(out,1.0f);
    out=0.72f*std::tanh(out/0.72f);
    ++d.sampleClock;
    if(d.muteInvalidationPending && d.muteGain<=0.0f) {
        ++d.effectGeneration;
        d.delayLp=0; d.delayHp=0;
        d.masterEQ.reset();
        d.hall.reset();
        for(auto &l:d.layers) {
            ++l.chorusGeneration;
            std::fill(std::begin(l.phaserState),std::end(l.phaserState),0.0f);
            reset_layer_eq(l);
        }
        d.muteInvalidationPending=false;
    }
    return std::isfinite(out)?out:0.0f;
}

void free_buffers(CodaDSP *d) noexcept {
    delete[] d->delay; d->delay=nullptr;
    delete[] d->reverb; d->reverb=nullptr;
    delete[] d->predelay; d->predelay=nullptr;
    delete[] d->masterChorus; d->masterChorus=nullptr;
    delete[] d->delayGeneration; d->delayGeneration=nullptr;
    delete[] d->reverbGeneration; d->reverbGeneration=nullptr;
    delete[] d->predelayGeneration; d->predelayGeneration=nullptr;
    delete[] d->masterChorusGen; d->masterChorusGen=nullptr;
    for(auto &l:d->layers) {
        delete[] l.chorusBuf; l.chorusBuf=nullptr;
        delete[] l.chorusGen; l.chorusGen=nullptr;
    }
}
}

extern "C" {
CodaDSP *coda_dsp_create(void) { return new (std::nothrow) CodaDSP{}; }

int coda_dsp_default_controls(uint8_t preset,CodaControls *out) {
    if(!out||preset>CODA_PRESET_WOBBLE) return 0;
    *out=CodaControls{};
    out->cutoff=0.64f; out->resonance=0.18f; out->shape=0.35f; out->detune=0.22f;
    out->glide=kPresets[preset].glideDefault; out->delay_amount=0.16f; out->reverb_amount=0.14f;
    out->chord_level=1.0f; out->tempo_bpm=124.0f; out->preset=preset;
    return 1;
}

CodaMixerControls coda_dsp_default_mixer_controls(void) {
    CodaMixerControls m{};
    for(int i=0;i<CODA_LAYER_COUNT;++i) {
        auto &l=m.layers[i];
        l.wobble=0.0f; l.warmth=0.0f; l.cutoff=0.64f; l.resonance=0.18f;
        l.shape=0.35f; l.detune=0.22f; l.glide=kPresets[CODA_PRESET_PLUCK].glideDefault;
        l.level=1.0f; l.preset=CODA_PRESET_PLUCK; l.muted=0;
    }
    m.chorus_amount=0.16f; m.delay_amount=0.16f; m.reverb_amount=0.14f; m.tempo_bpm=124.0f;
    return m;
}

void coda_dsp_destroy(CodaDSP *d) {
    if(!d) return;
    free_buffers(d);
    delete d;
}

int coda_dsp_prepare(CodaDSP *d,double rate,uint32_t block) {
    if(!d||!std::isfinite(rate)||rate<8000||rate>384000||block==0) return 0;
    free_buffers(d);
    d->rate=rate; d->maxBlock=block;
    d->delaySize=std::max(2u,static_cast<uint32_t>(rate*kDelayMaxSeconds));
    d->reverbSize=std::max(64u,static_cast<uint32_t>(rate*kReverbMaxSeconds));
    d->predelaySize=std::max(2u,static_cast<uint32_t>(rate*0.025));
    d->chorusSize=std::max(2u,static_cast<uint32_t>(rate*0.04));
    d->masterChorusSize=std::max(8u,static_cast<uint32_t>(rate*0.04));
    d->delay=new(std::nothrow) std::array<float,3>[d->delaySize];
    d->reverb=new(std::nothrow) std::array<float,4>[d->reverbSize];
    d->delayGeneration=new(std::nothrow) uint64_t[d->delaySize];
    d->reverbGeneration=new(std::nothrow) uint64_t[d->reverbSize];
    d->predelay=new(std::nothrow) float[d->predelaySize];
    d->predelayGeneration=new(std::nothrow) uint64_t[d->predelaySize];
    d->masterChorus=new(std::nothrow) float[d->masterChorusSize];
    d->masterChorusGen=new(std::nothrow) uint64_t[d->masterChorusSize];
    bool ok=d->delay&&d->reverb&&d->delayGeneration&&d->reverbGeneration&&d->predelay&&d->predelayGeneration&&d->masterChorus&&d->masterChorusGen;
    for(auto &l:d->layers) {
        l.chorusBuf=new(std::nothrow) float[d->chorusSize];
        l.chorusGen=new(std::nothrow) uint64_t[d->chorusSize];
        ok=ok&&l.chorusBuf&&l.chorusGen;
    }
    if(!ok) {
        free_buffers(d);
        return 0;
    }
    for(size_t i=0;i<d->filterG.size();i++) {
        const float normalized=static_cast<float>(i)/static_cast<float>(d->filterG.size()-1);
        const float hz=80.0f*std::pow(160.0f,normalized);
        d->filterG[i]=std::tan(kPi*std::min(hz,static_cast<float>(rate)*0.42f)/static_cast<float>(rate));
    }
    d->chuckFilterDecay=std::exp(-1.0f/(kChuckFilterSeconds*static_cast<float>(rate)));
    d->chuckNoiseDecay=std::exp(-1.0f/(kChuckNoiseSeconds*static_cast<float>(rate)));
    d->filterEnvDecay=std::exp(-1.0f/(0.08f*static_cast<float>(rate)));
    d->delayLowpassCoeff=1.0f-std::exp(-kTwoPi*3400.0f/static_cast<float>(rate));
    d->delayHpCoeff=1.0f-std::exp(-kTwoPi*160.0f/static_cast<float>(rate));
    for(auto &l:d->layers) {
        l.chordsEQ.prepare(rate);
        l.bassEQ.prepare(rate);
        l.melodyEQ.prepare(rate);
    }
    d->masterEQ.prepare(rate);
    d->hall.prepare(rate,d->reverb,d->reverbGeneration,d->reverbSize,d->predelay,d->predelayGeneration,d->predelaySize);
    std::memset(d->delay,0,sizeof(*d->delay)*d->delaySize);
    std::memset(d->reverb,0,sizeof(*d->reverb)*d->reverbSize);
    std::fill_n(d->delayGeneration,d->delaySize,0);
    std::fill_n(d->reverbGeneration,d->reverbSize,0);
    std::fill_n(d->predelay,d->predelaySize,0.0f);
    std::fill_n(d->predelayGeneration,d->predelaySize,0);
    std::fill_n(d->masterChorus,d->masterChorusSize,0.0f);
    std::fill_n(d->masterChorusGen,d->masterChorusSize,0);
    for(auto &l:d->layers) {
        std::fill_n(l.chorusBuf,d->chorusSize,0.0f);
        std::fill_n(l.chorusGen,d->chorusSize,0);
    }
    coda_dsp_reset(d);
    return 1;
}

void coda_dsp_reset(CodaDSP *d) {
    if(!d) return;
    d->delayWrite=0; d->masterChorusWrite=0; d->effectGeneration=1; d->muteGain=1; d->delayLp=0; d->delayHp=0;
    d->masterChorusPhaseA=0; d->masterChorusPhaseB=0; d->delayWowPhase=0;
    d->masterEQ.reset(); d->hall.reset();
    d->muteInvalidationPending=false;
    d->sampleClock=0; d->hasPending=false;
    d->lastPublishedMixer=MixerControls{};
    d->targetChorus=d->smoothChorus=0.16f;
    d->targetDelay=d->smoothDelay=0.16f;
    d->targetReverb=d->smoothReverb=0.14f;
    d->targetTempo=d->smoothTempo=124.0f;
    d->legacyMute=false;
    d->stopped=false;
    d->publishedOffset=-1; d->publishedAtOffset=0; d->publishedKind=0;
    d->delivered=d->late=0; d->eventHash=1469598103934665603ull;
    for(int li=0;li<CODA_MAX_TRACKS;++li) {
        auto &l=d->layers[li];
        l.voices={};
        l.target=LayerControls{}; l.smooth=l.target;
        l.eqProfile=static_cast<uint8_t>(li<CODA_LAYER_COUNT?li:CODA_LAYER_CHORDS);
        l.used=(li<CODA_LAYER_COUNT);
        reset_layer_eq(l);
        l.chorusWrite=0; l.chorusGeneration=1;
        l.chorusPhase=l.phaserPhase=l.driftPhase=0;
        l.muteGain=l.presetGain=1;
        l.presetSwitchPending=false; l.muteInvalidationPending=false;
        std::fill(std::begin(l.phaserState),std::end(l.phaserState),0.0f);
        l.detuneRatio[0]=l.detuneRatio[1]=l.detuneRatio[2]=1.0f;
        l.region=0; l.hasRegion=false; l.harmonicPerformance=false; l.harmonic={};
        l.regionFrequency={}; l.predecessor={};
        l.regionPresent.fill(false); l.predecessorPresent.fill(false);
        if(l.chorusBuf) std::fill_n(l.chorusBuf,d->chorusSize,0.0f);
        if(l.chorusGen) std::fill_n(l.chorusGen,d->chorusSize,0);
    }
    if(d->delay) std::memset(d->delay,0,sizeof(*d->delay)*d->delaySize);
    if(d->reverb) std::memset(d->reverb,0,sizeof(*d->reverb)*d->reverbSize);
    if(d->predelay) std::fill_n(d->predelay,d->predelaySize,0.0f);
    if(d->masterChorus) std::fill_n(d->masterChorus,d->masterChorusSize,0.0f);
    if(d->delayGeneration) std::fill_n(d->delayGeneration,d->delaySize,0);
    if(d->reverbGeneration) std::fill_n(d->reverbGeneration,d->reverbSize,0);
    if(d->predelayGeneration) std::fill_n(d->predelayGeneration,d->predelaySize,0);
    if(d->masterChorusGen) std::fill_n(d->masterChorusGen,d->masterChorusSize,0);
    Event e; while(d->events.pop(e)){}
    MixerControls c; while(d->controls.pop(c)){}
    TrackControlUpdate tu; while(d->trackControls.pop(tu)){}
}

int coda_dsp_publish_controls(CodaDSP *d,const CodaControls *v) {
    if(!d||!v||d->stopped) return 0;
    MixerControls decoded;
    if(!decode_legacy_controls(*v,d->lastPublishedMixer,decoded)) return 0;
    if(!d->controls.push(decoded)) return 0;
    d->lastPublishedMixer=decoded;
    return 1;
}

int coda_dsp_publish_mixer_controls(CodaDSP *d,const CodaMixerControls *v) {
    if(!d||!v||d->stopped) return 0;
    MixerControls decoded;
    if(!decode_mixer_controls(*v,decoded)) return 0;
    if(!d->controls.push(decoded)) return 0;
    d->lastPublishedMixer=decoded;
    return 1;
}

int coda_dsp_publish_track_controls(CodaDSP *d,uint8_t track_index,uint8_t eq_profile,const CodaLayerControls *v) {
    if(!d||!v||d->stopped||track_index>=CODA_MAX_TRACKS||eq_profile>=CODA_LAYER_COUNT) return 0;
    TrackControlUpdate tu{};
    tu.trackIndex=track_index;
    tu.eqProfile=eq_profile;
    if(!decode_layer_controls(*v,tu.controls)) return 0;
    return d->trackControls.push(tu)?1:0;
}

static int enqueue(CodaDSP *d,const Event &e) {
    if(d->stopped || e.sample_offset<d->publishedOffset) return 0;
    const bool same=e.sample_offset==d->publishedOffset;
    if(same && (e.kind<d->publishedKind || d->publishedAtOffset>=CODA_DSP_MAX_EVENTS_PER_SAMPLE)) return 0;
    if(!d->events.push(e)) return 0;
    d->publishedAtOffset=same?d->publishedAtOffset+1:1;
    d->publishedOffset=e.sample_offset; d->publishedKind=e.kind;
    return 1;
}

int coda_dsp_push_event(CodaDSP *d,const CodaNoteEvent *e) {
    if(!d||!e||e->sample_offset<0||e->kind>CODA_EVENT_ON||e->pitch>127||e->voice_rank>=CODA_DSP_VOICES) return 0;
    Event event{};
    static_cast<CodaNoteEvent&>(event)=*e;
    event.layer=CODA_LAYER_CHORDS;
    return enqueue(d,event);
}

int coda_dsp_push_performance_event(CodaDSP *d,const CodaPerformanceEvent *e) {
    if(!d||!e||e->sample_offset<0||e->kind>CODA_EVENT_ON||e->pitch>127||e->voice_rank>=CODA_DSP_VOICES||
       e->layer>=CODA_MAX_TRACKS||e->attack_mode>CODA_ATTACK_CHUCK||!e->owner.prepare_epoch||
       !e->owner.plan_generation||!e->owner.activation||!e->owner.instance||!e->harmonic_token) return 0;
    if(!std::isfinite(e->base_velocity)||e->base_velocity<=0||e->base_velocity>1||
       !std::isfinite(e->effective_velocity)||e->effective_velocity<=0||e->effective_velocity>1||
       !std::isfinite(e->detune_cents)||std::abs(e->detune_cents)>3||
       !std::isfinite(e->filter_delta)||std::abs(e->filter_delta)>.02f) return 0;
    Event event{};
    event.sample_offset=e->sample_offset; event.kind=e->kind; event.pitch=e->pitch;
    event.voice_rank=e->voice_rank; event.layer=e->layer;
    event.performance=true; event.payload=*e;
    return enqueue(d,event);
}

int coda_dsp_process(CodaDSP *d,float *out,uint32_t frames) {
    if(!d||!out||!d->delay||!d->reverb||!d->predelay||!d->masterChorus||!d->delayGeneration||!d->reverbGeneration||!d->predelayGeneration||!d->masterChorusGen||frames>d->maxBlock) return 0;
    for(const auto &l:d->layers) if(!l.chorusBuf||!l.chorusGen) return 0;
    if(d->stopped){std::fill_n(out,frames,0.0f);return 1;}
    MixerControls next;
    for(uint32_t i=0;i<kControlDrainLimit&&d->controls.pop(next);i++) {
        const bool wasAllMuted=all_used_layers_muted(*d,true);
        for(int li=0;li<CODA_LAYER_COUNT;++li) {
            auto &l=d->layers[li];
            if(next.layers[li].preset!=l.target.preset) l.presetSwitchPending=true;
            if(next.layers[li].muted && !l.target.muted) l.muteInvalidationPending=true;
            l.target=next.layers[li];
        }
        d->targetChorus=next.chorus;
        d->targetDelay=next.delay; d->targetReverb=next.reverb; d->targetTempo=next.tempo;
        d->legacyMute=next.legacyMute;
        const bool nowAllMuted=all_used_layers_muted(*d,true);
        if(nowAllMuted && !wasAllMuted) d->muteInvalidationPending=true;
    }
    TrackControlUpdate tu;
    for(uint32_t i=0;i<32&&d->trackControls.pop(tu);i++) {
        if(tu.trackIndex<CODA_MAX_TRACKS) {
            const bool wasAllMuted=all_used_layers_muted(*d,true);
            auto &l=d->layers[tu.trackIndex];
            l.used=true;
            l.eqProfile=tu.eqProfile;
            if(tu.controls.preset!=l.target.preset) l.presetSwitchPending=true;
            if(tu.controls.muted && !l.target.muted) l.muteInvalidationPending=true;
            l.target=tu.controls;
            const bool nowAllMuted=all_used_layers_muted(*d,true);
            if(nowAllMuted && !wasAllMuted) d->muteInvalidationPending=true;
        }
    }
    for(uint32_t i=0;i<frames;i++) out[i]=process_sample(*d);
    return 1;
}

void coda_dsp_stop(CodaDSP *d) {
    if(!d) return;
    coda_dsp_reset(d); d->stopped=true;
}

void coda_dsp_inspect(const CodaDSP *d,CodaDSPDiagnostics *out) {
    if(!d||!out) return;
    *out={};
    out->sample_clock=d->sampleClock; out->delivered=d->delivered; out->late=d->late; out->event_hash=d->eventHash;
    out->mute_gain=d->muteGain; out->effect_generation=d->effectGeneration;
    const auto &voices=d->layers[CODA_LAYER_CHORDS].voices;
    for(size_t i=0;i<voices.size();i++) {
        const auto &v=voices[i]; auto &o=out->voices[i];
        o.active=v.active; o.stage=static_cast<uint8_t>(v.envelope.stage); o.preset=v.preset;
        o.region=v.region; o.rank=v.rank; o.amplitude=v.amp; o.frequency=v.frequency; o.target_frequency=v.targetFrequency;
    }
}

void coda_dsp_inspect_performance(const CodaDSP *d,CodaPerformanceVoiceDiagnostic out[CODA_DSP_VOICES]) {
    if(!d||!out) return;
    const auto &voices=d->layers[CODA_LAYER_CHORDS].voices;
    for(size_t i=0;i<voices.size();++i) {
        const auto &v=voices[i]; auto &o=out[i]; o={};
        o.owner=v.payload.owner; o.harmonic_token=v.payload.harmonic_token;
        o.base_velocity=v.performance?v.payload.base_velocity:.8f; o.effective_velocity=v.velocity;
        o.detune_cents=v.payload.detune_cents; o.filter_delta=v.payload.filter_delta;
        o.active=v.active; o.performance=v.performance; o.pitch=v.pitch; o.rank=v.rank;
        o.attack_mode=v.payload.attack_mode; o.releasing=v.releasing;
    }
}
}
