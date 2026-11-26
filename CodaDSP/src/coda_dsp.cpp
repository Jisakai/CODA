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
constexpr float kDelayFeedback = 0.30f;
constexpr float kSmoothingSeconds = 0.012f;
constexpr uint32_t kControlDrainLimit = 8;
// Provisional feel constants; owner listening acceptance remains required.
constexpr float kChuckAttackSeconds=.002f, kChuckDecaySeconds=.035f;
constexpr float kChuckReleaseSeconds=.018f, kChuckFilterSeconds=.008f;
constexpr float kChuckNoiseSeconds=.012f, kChuckNoiseLevel=.24f;
struct Event : CodaNoteEvent { bool performance=false; CodaPerformanceEvent payload{}; };
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

struct Controls {
    float wobble=0, warmth=0, cutoff=0.64f, resonance=0.18f, shape=0.35f;
    float detune=0.22f, glide=0, delay=0.16f, reverb=0.14f;
    float level=1, tempo=124;
    uint8_t preset=CODA_PRESET_PLUCK;
    bool muted=false;
};
bool decode_controls(const CodaControls &in, Controls &out) {
    if (in.preset > CODA_PRESET_WOBBLE) return false;
    const float vals[] = {in.wobble,in.warmth,in.cutoff,in.resonance,in.shape,in.detune,in.glide,
        in.delay_amount,in.reverb_amount,in.chord_level,in.tempo_bpm};
    for (float v : vals) if (!std::isfinite(v)) return false;
    if (in.tempo_bpm <= 0) return false;
    out.wobble=clampf(in.wobble,0,1); out.warmth=clampf(in.warmth,0,1);
    out.cutoff=clampf(in.cutoff,0.015f,0.98f); out.resonance=clampf(in.resonance,0,kMaxResonance);
    out.shape=clampf(in.shape,0,1); out.detune=clampf(in.detune,0,1); out.glide=clampf(in.glide,0,1);
    out.delay=clampf(in.delay_amount,0,1); out.reverb=clampf(in.reverb_amount,0,1);
    out.level=clampf(in.chord_level,0,1); out.tempo=clampf(in.tempo_bpm,30,300);
    out.preset=in.preset; out.muted=in.muted != 0; return true;
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
struct PresetSpec {
    uint8_t oscillatorA, oscillatorB;
    float oscillatorBLevel, attack, decay, sustain, release, detuneCents, subLevel;
    float chorusBaseSeconds, phaserBaseMix, driftBase, glideDefault;
};
constexpr std::array<PresetSpec,3> kPresets{{
    {0,1,0.18f,0.003f,0.10f,0.0f,0.20f,5.0f,0.055f,0.0010f,0.00f,0.0000f,0.0f},
    {0,0,0.12f,0.42f,0.60f,0.78f,1.80f,14.0f,0.075f,0.0020f,0.18f,0.0003f,0.0f},
    {2,1,0.28f,0.012f,0.18f,0.72f,0.55f,14.0f,0.045f,0.0015f,0.12f,0.0008f,0.35f}
}};

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
    std::array<Controls,8> data{};
    alignas(64) std::atomic<uint32_t> head{0};
    alignas(64) std::atomic<uint32_t> tail{0};
    bool push(const Controls &v) noexcept {
        const uint32_t h=head.load(std::memory_order_relaxed), n=(h+1)%data.size();
        if (n==tail.load(std::memory_order_acquire)) return false;
        data[h]=v; head.store(n,std::memory_order_release); return true;
    }
    bool pop(Controls &v) noexcept {
        const uint32_t t=tail.load(std::memory_order_relaxed);
        if (t==head.load(std::memory_order_acquire)) return false;
        v=data[t]; tail.store((t+1)%data.size(),std::memory_order_release); return true;
    }
};
}

struct CodaDSP {
    double rate=0;
    uint32_t maxBlock=0;
    std::array<Voice,CODA_DSP_VOICES> voices{};
    SPSCEvents events{}; SPSCControls controls{};
    Controls target{}, smooth{};
    Event pending{}; bool hasPending=false;
    std::array<float,3> *delay=nullptr;
    std::array<float,4> *reverb=nullptr;
    float *predelay=nullptr;
    uint64_t *delayGeneration=nullptr, *reverbGeneration=nullptr, *predelayGeneration=nullptr;
    uint32_t delaySize=0, delayWrite=0, reverbSize=0, predelaySize=0;
    uint64_t effectGeneration=1;
    float chorusPhase=0, phaserPhase=0, driftPhase=0, muteGain=1, presetGain=1;
    coda::ChordsEQ chordsEQ{};
    coda::MasterEQ masterEQ{};
    coda::Hall hall{};
    bool muteInvalidationPending=false;
    bool stopped=false;
    int64_t publishedOffset=-1;
    uint32_t publishedAtOffset=0;
    uint8_t publishedKind=0;
    uint32_t region=0;
    bool hasRegion=false;
    bool harmonicPerformance=false; CodaPerformanceEvent harmonic{};
    float chuckFilterDecay=1, chuckNoiseDecay=1;
    std::array<float,CODA_DSP_VOICES> regionFrequency{}, predecessor{};
    std::array<bool,CODA_DSP_VOICES> regionPresent{}, predecessorPresent{};
    uint64_t delivered=0, late=0, eventHash=1469598103934665603ull;
    float phaserState[4]{};
    std::array<float,512> filterG{};
    float detuneRatio[3]{1.0f,1.0f,1.0f};
    float filterEnvDecay=1.0f;
    float delayLowpassCoeff=0.3f, delayLp=0;
    bool presetSwitchPending=false;
    uint64_t sampleClock=0;
};

namespace {
void release_voice(Voice &v) noexcept { if (v.active) {v.releasing=true;v.envelope.off();} }
void note_on(CodaDSP &d, const Event &e) noexcept {
    if(!d.hasRegion || d.harmonicPerformance!=e.performance ||
       (e.performance ? !equal_harmonic(d.harmonic,e.payload) : d.region!=e.region_id)) {
        d.predecessor=d.regionFrequency;d.predecessorPresent=d.regionPresent;
        d.regionPresent.fill(false);d.region=e.region_id;d.hasRegion=true;
        d.harmonicPerformance=e.performance;d.harmonic=e.payload;
    }
    Voice *slot=nullptr;
    for (auto &v:d.voices) if (v.active && v.performance==e.performance && v.pitch==e.pitch &&
        (e.performance || v.region==e.region_id)) { slot=&v; break; }
    if (!slot) for (auto &v:d.voices) if (!v.active) { slot=&v; break; }
    if (!slot) {
        slot=&d.voices[0];
        for (auto &v:d.voices) if ((v.releasing && !slot->releasing) || (v.releasing==slot->releasing && v.age<slot->age)) slot=&v;
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
    const bool canGlide=d.smooth.glide>0.001f && d.predecessorPresent[e.voice_rank];
    const float old=d.predecessor[e.voice_rank];
    v.active=true; v.releasing=false; v.region=e.region_id; v.pitch=e.pitch; v.rank=e.voice_rank;
    v.targetFrequency=midi; v.frequency=canGlide ? old : midi; v.amp=0; v.envelope.on();v.preset=d.smooth.preset; v.filterEnv=1.0f;
    v.filterIc1=v.filterIc2=0;
    v.performance=e.performance;v.payload=e.payload;
    v.velocity=e.performance?e.payload.effective_velocity:0.8f;
    v.noteDetuneRatio=e.performance?std::pow(2.0f,e.payload.detune_cents/1200.0f):1.0f;
    v.noiseEnvelope=1;v.noiseState=static_cast<uint32_t>(e.payload.owner.instance)^0x9e3779b9u;
    if(!v.noiseState)v.noiseState=1;
    v.age=d.sampleClock;
    if(slot->stealRemaining==0) v.stealGain=1.0f;
    d.regionFrequency[e.voice_rank]=midi;d.regionPresent[e.voice_rank]=true;
}
void note_off(CodaDSP &d, const Event &e) noexcept {
    for (auto &v:d.voices) if (v.active && v.performance==e.performance && v.pitch==e.pitch &&
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
float voice_sample(CodaDSP &d, Voice &v) noexcept {
    const Controls &c=d.smooth;
    const PresetSpec &spec=kPresets[v.preset];
    const float glideSeconds=c.glide>0.001f?(0.012f+0.45f*c.glide):0.0f;
    if(glideSeconds>0) v.frequency += (v.targetFrequency-v.frequency)/(glideSeconds*static_cast<float>(d.rate));
    else v.frequency=v.targetFrequency;
    const float shapeScale=0.5f+1.5f*c.shape;
    const bool chuck=v.performance && v.payload.attack_mode==CODA_ATTACK_CHUCK;
    v.amp=chuck?v.envelope.tick(d.rate,kChuckAttackSeconds,kChuckDecaySeconds,0,kChuckReleaseSeconds):
        v.envelope.tick(d.rate,spec.attack*shapeScale,spec.decay,spec.sustain,spec.release*shapeScale);
    if(v.envelope.stage==coda::Stage::idle) {v.active=false;return 0;}
    const float wobble=c.wobble;
    d.driftPhase+=kTwoPi*(0.07f+0.55f*wobble)/static_cast<float>(d.rate); if(d.driftPhase>=kTwoPi)d.driftPhase-=kTwoPi;
    const float drift=std::sin(d.driftPhase)*(spec.driftBase+0.0025f*wobble);
    const float center=v.frequency*(1.0f+drift)*v.noteDetuneRatio;
    float bankA=0,bankB=0;
    for(int i=0;i<3;i++) {
        const float hz=center*d.detuneRatio[i];
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
    const float cutoffNorm=clampf(c.cutoff*(1.0f-0.28f*c.warmth)+0.20f*v.filterEnv+(v.performance?v.payload.filter_delta:0.0f),0,1);
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
#define SMOOTH(field) d.smooth.field=flush_denormal(d.smooth.field+alpha*(d.target.field-d.smooth.field))
    SMOOTH(wobble); SMOOTH(warmth); SMOOTH(cutoff); SMOOTH(resonance); SMOOTH(shape);
    SMOOTH(detune); SMOOTH(glide); SMOOTH(delay); SMOOTH(reverb); SMOOTH(level); SMOOTH(tempo);
#undef SMOOTH
    d.smooth.muted=d.target.muted;
    const float fadeStep=1.0f/std::max(1.0f,0.012f*static_cast<float>(d.rate));
    if(d.presetSwitchPending) {
        bool hasVoice=false;for(const auto &voice:d.voices)hasVoice|=voice.active;
        if(!hasVoice) { d.smooth.preset=d.target.preset;d.presetGain=1.0f;d.presetSwitchPending=false; }
        else {
            d.presetGain=std::max(0.0f,d.presetGain-fadeStep);
            if(d.presetGain<=0.0f) { d.smooth.preset=d.target.preset; d.presetSwitchPending=false; }
        }
    } else d.presetGain=std::min(1.0f,d.presetGain+fadeStep);
    for(const auto &v:d.voices) if(v.active && v.performance==d.harmonicPerformance &&
        (v.performance?equal_harmonic(v.payload,d.harmonic):v.region==d.region))
        d.regionFrequency[v.rank]=v.frequency;
    for(uint32_t applied=0;applied<CODA_DSP_MAX_EVENTS_PER_SAMPLE;applied++) {
        if(!d.hasPending&&d.events.pop(d.pending)) d.hasPending=true;
        if(!d.hasPending||d.pending.sample_offset>static_cast<int64_t>(d.sampleClock)) break;
        if(d.pending.kind==CODA_EVENT_OFF) note_off(d,d.pending); else note_on(d,d.pending);
        ++d.delivered;
        if(d.pending.sample_offset!=static_cast<int64_t>(d.sampleClock))++d.late;
        d.eventHash=(d.eventHash ^ static_cast<uint64_t>(d.pending.sample_offset))*1099511628211ull;
        if(d.pending.performance) {
            const auto &p=d.pending.payload;
            const uint64_t words[]={0x50455246ull,p.owner.prepare_epoch,p.owner.plan_generation,p.owner.cycle,
                p.owner.activation,p.owner.instance,p.harmonic_token,p.pitch,p.voice_rank,p.attack_mode};
            for(auto word:words)d.eventHash=(d.eventHash^word)*1099511628211ull;
            const float values[]={p.base_velocity,p.effective_velocity,p.detune_cents,p.filter_delta};
            for(float value:values){uint32_t bits;std::memcpy(&bits,&value,sizeof(bits));d.eventHash=(d.eventHash^bits)*1099511628211ull;}
        } else d.eventHash=(d.eventHash ^ d.pending.region_id)*1099511628211ull;
        d.eventHash=(d.eventHash ^ d.pending.kind)*1099511628211ull;
        d.hasPending=false;
    }
    float dry=0;
    const PresetSpec &spec=kPresets[d.smooth.preset];
    for(int i=0;i<3;i++)d.detuneRatio[i]=std::pow(2.0f,(static_cast<float>(i)-1.0f)*d.smooth.detune*spec.detuneCents/1200.0f);
    for(auto &v:d.voices) if(v.active) dry+=voice_sample(d,v);
    dry*=0.20f;
    const PresetSpec &fxPreset=kPresets[d.smooth.preset];
    const float chorusDepth=(fxPreset.chorusBaseSeconds+0.005f*d.smooth.wobble)*static_cast<float>(d.rate);
    d.chorusPhase+=kTwoPi*(0.18f+0.52f*d.smooth.wobble)/static_cast<float>(d.rate); if(d.chorusPhase>=kTwoPi)d.chorusPhase-=kTwoPi;
    d.phaserPhase+=kTwoPi*(0.07f+0.35f*d.smooth.wobble)/static_cast<float>(d.rate); if(d.phaserPhase>=kTwoPi)d.phaserPhase-=kTwoPi;
    const uint32_t delayN=d.delaySize;
    const uint32_t baseDelay=std::min(delayN-1,static_cast<uint32_t>(d.rate*60.0/d.smooth.tempo*0.75));
    const uint32_t mod=static_cast<uint32_t>((0.5f+0.5f*std::sin(d.chorusPhase))*chorusDepth);
    const uint32_t chorusDelay=static_cast<uint32_t>(0.018f*static_cast<float>(d.rate))+mod;
    const uint32_t chorusIndex=(d.delayWrite+delayN-std::min(delayN-1,chorusDelay))%delayN;
    const float chorus=d.delayGeneration[chorusIndex]==d.effectGeneration?d.delay[chorusIndex][0]:0.0f;
    float phased=dry;
    const float coeff=0.12f+0.76f*(0.5f+0.5f*std::sin(d.phaserPhase));
    for(int stage=0;stage<4;stage++) { const float y=-coeff*phased+d.phaserState[stage];d.phaserState[stage]=flush_denormal(phased+coeff*y);phased=y; }
    float insert=dry+0.12f*chorus+(fxPreset.phaserBaseMix+0.20f*d.smooth.wobble)*phased;
    insert=soft_sat(insert,1.0f+0.65f*d.smooth.warmth+0.15f*d.smooth.wobble);
    float layer=d.chordsEQ.tick(insert);
    layer*=d.smooth.level*d.smooth.level;
    const float delayIn=layer+chorus*0.16f;
    const uint32_t echoIndex=(d.delayWrite+delayN-baseDelay)%delayN;
    float echo=d.delayGeneration[echoIndex]==d.effectGeneration?d.delay[echoIndex][0]:0.0f;
    d.delayLp=flush_denormal(d.delayLp+d.delayLowpassCoeff*(echo-d.delayLp));
    echo=d.delayLp;
    const bool muted=d.muteGain<=0 && !d.muteInvalidationPending;
    d.delay[d.delayWrite][0]=muted?0.0f:delayIn+d.delayLp*kDelayFeedback;
    d.delayGeneration[d.delayWrite]=d.effectGeneration;
    d.delay[d.delayWrite][0]=clampf(d.delay[d.delayWrite][0],-2.0f,2.0f);
    const float rv=d.hall.tick(muted?0.0f:layer*.08f);
    d.delayWrite=(d.delayWrite+1)%delayN;
    const float wet=(d.smooth.delay*echo+d.smooth.reverb*rv);
    const float wanted=(d.muteInvalidationPending||d.smooth.muted)?0.0f:1.0f;
    const float muteStep=1.0f/std::max(1.0f,coda::muteSeconds*static_cast<float>(d.rate));
    d.muteGain += clampf(wanted-d.muteGain,-muteStep,muteStep);
    float out=d.masterEQ.tick(layer+wet)*d.muteGain*d.presetGain*kDefaultMaster;
    out=soft_sat(out,1.0f);
    out=0.72f*std::tanh(out/0.72f);
    ++d.sampleClock;
    if(d.muteInvalidationPending&&d.muteGain<=0.0f) {
      ++d.effectGeneration;d.delayLp=0;d.chordsEQ.reset();d.masterEQ.reset();d.hall.reset();
      std::fill(std::begin(d.phaserState),std::end(d.phaserState),0.0f);
      d.muteInvalidationPending=false;

    }
    return std::isfinite(out)?out:0.0f;
}
}

extern "C" {
CodaDSP *coda_dsp_create(void) { return new (std::nothrow) CodaDSP{}; }
int coda_dsp_default_controls(uint8_t preset,CodaControls *out) {
    if(!out||preset>CODA_PRESET_WOBBLE)return 0;
    *out=CodaControls{};
    out->cutoff=0.64f;out->resonance=0.18f;out->shape=0.35f;out->detune=0.22f;
    out->glide=kPresets[preset].glideDefault;out->delay_amount=0.16f;out->reverb_amount=0.14f;
    out->chord_level=1.0f;out->tempo_bpm=124.0f;out->preset=preset;
    return 1;
}
void coda_dsp_destroy(CodaDSP *d) {
    if(!d)return;
    delete[] d->delay;delete[] d->reverb;delete[] d->predelay;
    delete[] d->delayGeneration;delete[] d->reverbGeneration;delete[] d->predelayGeneration;delete d;
}
int coda_dsp_prepare(CodaDSP *d,double rate,uint32_t block) {
    if(!d||!std::isfinite(rate)||rate<8000||rate>384000||block==0) return 0;
    delete[] d->delay; delete[] d->reverb; d->delay=nullptr; d->reverb=nullptr;
    delete[] d->delayGeneration; delete[] d->reverbGeneration;
    delete[] d->predelay;delete[] d->predelayGeneration;
    d->delayGeneration=nullptr; d->reverbGeneration=nullptr;d->predelay=nullptr;d->predelayGeneration=nullptr;
    d->rate=rate; d->maxBlock=block;
    d->delaySize=std::max(2u,static_cast<uint32_t>(rate*kDelayMaxSeconds));
    d->reverbSize=std::max(64u,static_cast<uint32_t>(rate*kReverbMaxSeconds));
    d->predelaySize=std::max(2u,static_cast<uint32_t>(rate*0.025));
    d->delay=new(std::nothrow) std::array<float,3>[d->delaySize];
    d->reverb=new(std::nothrow) std::array<float,4>[d->reverbSize];
    d->delayGeneration=new(std::nothrow) uint64_t[d->delaySize];
    d->reverbGeneration=new(std::nothrow) uint64_t[d->reverbSize];
    d->predelay=new(std::nothrow) float[d->predelaySize];
    d->predelayGeneration=new(std::nothrow) uint64_t[d->predelaySize];
    if(!d->delay||!d->reverb||!d->delayGeneration||!d->reverbGeneration||!d->predelay||!d->predelayGeneration) {
        delete[] d->delay;delete[] d->reverb;delete[] d->predelay;
        delete[] d->delayGeneration;delete[] d->reverbGeneration;delete[] d->predelayGeneration;
        d->delay=nullptr;d->reverb=nullptr;d->predelay=nullptr;d->delayGeneration=nullptr;d->reverbGeneration=nullptr;d->predelayGeneration=nullptr;
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
    d->delayLowpassCoeff=1.0f-std::exp(-kTwoPi*3000.0f/static_cast<float>(rate));
    d->chordsEQ.prepare(rate);d->masterEQ.prepare(rate);
    d->hall.prepare(rate,d->reverb,d->reverbGeneration,d->reverbSize,d->predelay,d->predelayGeneration,d->predelaySize);
    std::memset(d->delay,0,sizeof(*d->delay)*d->delaySize); std::memset(d->reverb,0,sizeof(*d->reverb)*d->reverbSize);
    std::fill_n(d->delayGeneration,d->delaySize,0);std::fill_n(d->reverbGeneration,d->reverbSize,0);
    std::fill_n(d->predelay,d->predelaySize,0.0f);std::fill_n(d->predelayGeneration,d->predelaySize,0);
    coda_dsp_reset(d); return 1;
}
void coda_dsp_reset(CodaDSP *d) {
    if(!d)return;
    d->voices={}; d->delayWrite=0; d->effectGeneration=1; d->chorusPhase=d->phaserPhase=d->driftPhase=0;
    d->muteGain=d->presetGain=1; d->delayLp=0;d->chordsEQ.reset();d->masterEQ.reset();d->hall.reset();
    d->muteInvalidationPending=false;
    std::fill(std::begin(d->phaserState),std::end(d->phaserState),0.0f);
    d->presetSwitchPending=false; d->sampleClock=0; d->hasPending=false;
    d->target=Controls{}; d->smooth=d->target;d->stopped=false;
    d->publishedOffset=-1;d->publishedAtOffset=0;d->publishedKind=0;
    d->hasRegion=false;d->harmonicPerformance=false;d->harmonic={};d->regionPresent.fill(false);d->predecessorPresent.fill(false);
    d->delivered=d->late=0;d->eventHash=1469598103934665603ull;
    if(d->delay)std::memset(d->delay,0,sizeof(*d->delay)*d->delaySize);
    if(d->reverb)std::memset(d->reverb,0,sizeof(*d->reverb)*d->reverbSize);
    if(d->predelay)std::fill_n(d->predelay,d->predelaySize,0.0f);
    if(d->delayGeneration)std::fill_n(d->delayGeneration,d->delaySize,0);
    if(d->reverbGeneration)std::fill_n(d->reverbGeneration,d->reverbSize,0);
    if(d->predelayGeneration)std::fill_n(d->predelayGeneration,d->predelaySize,0);
    Event e; while(d->events.pop(e)){} Controls c; while(d->controls.pop(c)){}
}
int coda_dsp_publish_controls(CodaDSP *d,const CodaControls *v) {
    if(!d||!v||d->stopped)return 0; Controls decoded; if(!decode_controls(*v,decoded))return 0; return d->controls.push(decoded)?1:0;
}
static int enqueue(CodaDSP *d,const Event &e) {
    if(d->stopped || e.sample_offset<d->publishedOffset)return 0;
    const bool same=e.sample_offset==d->publishedOffset;
    if(same && (e.kind<d->publishedKind || d->publishedAtOffset>=CODA_DSP_MAX_EVENTS_PER_SAMPLE))return 0;
    if(!d->events.push(e))return 0;
    d->publishedAtOffset=same?d->publishedAtOffset+1:1;
    d->publishedOffset=e.sample_offset;d->publishedKind=e.kind;return 1;
}
int coda_dsp_push_event(CodaDSP *d,const CodaNoteEvent *e) {
    if(!d||!e||e->sample_offset<0||e->kind>CODA_EVENT_ON||e->pitch>127||e->voice_rank>=CODA_DSP_VOICES)return 0;
    Event event{};static_cast<CodaNoteEvent&>(event)=*e;return enqueue(d,event);
}
int coda_dsp_push_performance_event(CodaDSP *d,const CodaPerformanceEvent *e) {
    if(!d||!e||e->sample_offset<0||e->kind>CODA_EVENT_ON||e->pitch>127||e->voice_rank>=CODA_DSP_VOICES||
       e->attack_mode>CODA_ATTACK_CHUCK||!e->owner.prepare_epoch||!e->owner.plan_generation||
       !e->owner.activation||!e->owner.instance||!e->harmonic_token)return 0;
    if(!std::isfinite(e->base_velocity)||e->base_velocity<=0||e->base_velocity>1||
       !std::isfinite(e->effective_velocity)||e->effective_velocity<=0||e->effective_velocity>1||
       !std::isfinite(e->detune_cents)||std::abs(e->detune_cents)>3||
       !std::isfinite(e->filter_delta)||std::abs(e->filter_delta)>.02f)return 0;
    Event event{};event.sample_offset=e->sample_offset;event.kind=e->kind;event.pitch=e->pitch;
    event.voice_rank=e->voice_rank;event.performance=true;event.payload=*e;return enqueue(d,event);
}
int coda_dsp_process(CodaDSP *d,float *out,uint32_t frames) {
    if(!d||!out||!d->delay||!d->reverb||!d->predelay||!d->delayGeneration||!d->reverbGeneration||!d->predelayGeneration||frames>d->maxBlock)return 0;
    if(d->stopped){std::fill_n(out,frames,0.0f);return 1;}
    Controls next;
    for(uint32_t i=0;i<kControlDrainLimit&&d->controls.pop(next);i++) {
        if(next.preset!=d->target.preset)d->presetSwitchPending=true;
        if(next.muted&&!d->target.muted)d->muteInvalidationPending=true;
        d->target=next;
    }
    for(uint32_t i=0;i<frames;i++) out[i]=process_sample(*d);
    return 1;
}
void coda_dsp_stop(CodaDSP *d) {
    if(!d)return;
    coda_dsp_reset(d);d->stopped=true;
}
void coda_dsp_inspect(const CodaDSP *d,CodaDSPDiagnostics *out) {
    if(!d||!out)return;
    *out={};out->sample_clock=d->sampleClock;out->delivered=d->delivered;out->late=d->late;out->event_hash=d->eventHash;
    out->mute_gain=d->muteGain;out->effect_generation=d->effectGeneration;
    for(size_t i=0;i<d->voices.size();i++) {
        const auto &v=d->voices[i];auto &o=out->voices[i];
        o.active=v.active;o.stage=static_cast<uint8_t>(v.envelope.stage);o.preset=v.preset;
        o.region=v.region;o.rank=v.rank;o.amplitude=v.amp;o.frequency=v.frequency;o.target_frequency=v.targetFrequency;
    }
}
}

extern "C" void coda_dsp_inspect_performance(const CodaDSP *d,CodaPerformanceVoiceDiagnostic out[CODA_DSP_VOICES]) {
    if(!d||!out)return;
    for(size_t i=0;i<d->voices.size();++i) {
        const auto &v=d->voices[i];auto &o=out[i];o={};
        o.owner=v.payload.owner;o.harmonic_token=v.payload.harmonic_token;
        o.base_velocity=v.performance?v.payload.base_velocity:.8f;o.effective_velocity=v.velocity;
        o.detune_cents=v.payload.detune_cents;o.filter_delta=v.payload.filter_delta;
        o.active=v.active;o.performance=v.performance;o.pitch=v.pitch;o.rank=v.rank;
        o.attack_mode=v.payload.attack_mode;o.releasing=v.releasing;
    }
}
