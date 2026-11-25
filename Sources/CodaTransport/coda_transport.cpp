#include "coda_transport.h"
#include <atomic>
#include <cmath>
#include <new>
#include <limits>

static_assert(std::atomic<uint64_t>::is_always_lock_free);
static_assert(std::atomic<uint32_t>::is_always_lock_free);
namespace {
constexpr uint64_t maxGrid = 9007199254740992ULL;
struct Held { uint32_t region=0; uint8_t pitch=0, rank=0; bool on=false; };
struct Audition { uint8_t pitches[12]{}; uint32_t count=0, frames=0; };
bool validControls(const CodaControls &c) {
    const float v[]={c.wobble,c.warmth,c.cutoff,c.resonance,c.shape,c.detune,c.glide,
        c.delay_amount,c.reverb_amount,c.chord_level,c.tempo_bpm};
    for (float f:v) if (!std::isfinite(f)) return false;
    return c.preset<=2 && c.tempo_bpm>=30 && c.tempo_bpm<=300;
}
bool valid(const CodaPlan &p) {
    if (p.playback_revision>(UINT64_MAX>>1) || !std::isfinite(p.samples_per_step) || p.samples_per_step<400 ||
        p.samples_per_step>192000 || !p.length || p.length>128 || p.length%16 ||
        (p.position_revision && p.seek_step==UINT16_MAX) || (p.seek_step>127 && p.seek_step!=UINT16_MAX) || p.count>CODA_PLAN_EVENTS || p.playing>1 || p.looping>1) return false;
    bool held[12]{}; uint16_t regions[12]{}; uint8_t pitches[12]{};
    unsigned group=0, onCount=0; uint32_t onRegion=0;
    bool used[128]{}; uint8_t previousPitch=0;
    for (uint32_t i=0;i<p.count;++i) {
        const auto &e=p.events[i];
        if(e.step>p.length || e.region>=128 || e.kind>1 || e.pitch>127 || e.rank>=12) return false;
        if(i && (e.step<p.events[i-1].step ||
           (e.step==p.events[i-1].step && e.kind<p.events[i-1].kind))) return false;
        if(!i || e.step!=p.events[i-1].step) {group=0; onRegion=128; onCount=0;}
        if(++group>24) return false;
        if(e.kind) {
            if(e.step==p.length || held[e.rank] || (onRegion!=128 && onRegion!=e.region)) return false;
            if(onRegion==128) {
                for(bool h:held) if(h) return false;
                if(used[e.region]) return false;
                used[e.region]=true;
            }
            if(e.rank!=onCount || (onCount && e.pitch<=previousPitch)) return false;
            ++onCount; previousPitch=e.pitch;
            onRegion=e.region; held[e.rank]=true; regions[e.rank]=e.region; pitches[e.rank]=e.pitch;
        } else {
            if(!held[e.rank] || regions[e.rank]!=e.region || pitches[e.rank]!=e.pitch) return false;
            held[e.rank]=false;
        }
    }
    for(bool h:held) if(h) return false;
    return true;
}
}
struct CodaTransport {
    CodaDSP *dsp=nullptr;
    CodaPlan plans[CODA_PLAN_SLOTS]{};
    std::atomic<uint32_t> head{0}, tail{0};
    uint32_t active=0; bool hasPlan=false, prepared=false, playing=false;
    CodaControls controls[8]{};
    std::atomic<uint32_t> ch{0}, ct{0};
    Audition audition{};
    std::atomic<uint32_t> ah{0}, at{0};
    Held held[12]{};
    uint64_t clock=0, cycle=0, position=0, origin=0, auditionEnd=0;
    uint64_t playbackRevision=0, positionRevision=0;
    bool completed=false;
    uint32_t index=0, nextRegion=0, failures=0;
    uint32_t regionIDs[128]{};
    bool auditioning=false, restore=false;
    std::atomic<uint64_t> outPlaybackState{0};
    std::atomic<uint64_t> outClock{0}, outCycle{0}, outDelivered{0}, outLate{0}, outHash{0};
    std::atomic<uint32_t> outAck{0}, outFailures{0}, outRegion{0}, outPosition{0};
    uint64_t boundary(uint64_t step) const {
        return uint64_t(std::round(double(step)*plans[active].samples_per_step));
    }
    bool emit(uint8_t kind, uint8_t pitch, uint8_t rank, uint32_t region) {
        CodaNoteEvent e{int64_t(clock),region,kind,pitch,rank,0};
        if(!coda_dsp_push_event(dsp,&e)) { ++failures; playing=false; return false; }
        if(kind) held[rank]={region,pitch,rank,true}; else held[rank].on=false;
        return true;
    }
    void release() {
        for(auto &h:held) if(h.on) emit(0,h.pitch,h.rank,h.region);
    }
    uint32_t newRegion() {
        if(nextRegion==std::numeric_limits<uint32_t>::max()) {
            ++failures; playing=false; return 0;
        }
        return ++nextRegion;
    }
    void resumeChord() {
        bool on[12]{}; CodaGridEvent notes[12]{};
        const auto &p=plans[active];
        for(uint32_t i=0;i<p.count;++i) {
            const auto &e=p.events[i];
            if(boundary(cycle*p.length+e.step)>position) break;
            on[e.rank]=e.kind; notes[e.rank]=e;
        }
        auto id=newRegion();
        for(unsigned r=0;r<12;++r) if(on[r] && id) {
            regionIDs[notes[r].region]=id;
            emit(1,notes[r].pitch,uint8_t(r),id);
        }
    }
    void tick() {
        // At most one plan and one audition per sample. Old queue contains no
        // future notes: the scheduler is the exclusive DSP producer/consumer.
        const auto h=head.load(std::memory_order_acquire);
        bool changed=false;
        if(tail.load(std::memory_order_relaxed)!=h) {
            release(); auditioning=false;
            const auto oldCycle=cycle, oldPosition=position;
            const auto oldLength=hasPlan?plans[active].length:0;
            const auto oldRate=hasPlan?plans[active].samples_per_step:1;
            const double oldStep=hasPlan?double(position-boundary(cycle*oldLength))/oldRate:0;
            const auto t=h-1; // superseded queued snapshots never produce notes
            active=t%CODA_PLAN_SLOTS; hasPlan=true;
            const auto &p=plans[active];
            const bool playbackCommand=p.playback_revision>playbackRevision;
            const bool positionCommand=p.position_revision>positionRevision;
            cycle=0;
            // A stopped endpoint is not a wrapped step zero. Preserve it through
            // configuration remapping until an explicit Play or position command.
            position=completed?boundary(p.length):uint64_t(std::round(std::fmod(oldStep,p.length)*p.samples_per_step));
            if(oldLength==p.length && oldRate==p.samples_per_step) {
                cycle=oldCycle; position=oldPosition;
            }
            if(positionCommand) {
                cycle=0; position=boundary(p.seek_step<p.length?p.seek_step:p.length-1);
                positionRevision=p.position_revision; completed=false;
            }
            if(playbackCommand) {
                if(p.playing && completed) {cycle=0; position=0; completed=false;}
                playing=p.playing; playbackRevision=p.playback_revision;
            }
            origin=position; index=0;
            for(auto &id:regionIDs) id=0;
            // ACK previous slot only AFTER its last access. Retain current slot.
            if(t>0) outAck.store(t,std::memory_order_release);
            tail.store(h,std::memory_order_release);
            restore=playing; changed=true;
        }
        if(ah.load(std::memory_order_acquire)!=at.load(std::memory_order_relaxed)) {
            if(!changed) release();
            const auto a=audition; // fixed POD copy before acknowledgment
            at.store(ah.load(std::memory_order_relaxed),std::memory_order_release);
            auditioning=a.count!=0; auditionEnd=clock+a.frames;
            if(auditioning) {
                auto id=newRegion();
                for(uint32_t r=0;r<a.count && id;++r) emit(1,a.pitches[r],uint8_t(r),id);
            } else restore=playing;
            changed=true;
        } else if(auditioning && clock>=auditionEnd) {
            release(); auditioning=false; restore=playing; changed=true;
        }
        if(hasPlan && playing) {
            const auto &p=plans[active];
            const auto end=boundary((cycle+1)*p.length);
            if(position>=end) {
                if(!auditioning && !changed) release();
                if(!p.looping || (cycle+2)*p.length>maxGrid || nextRegion>UINT32_MAX-256) {
                    playing=false; completed=true; restore=false;
                } else { ++cycle; index=0; for(auto &id:regionIDs) id=0; restore=!auditioning; }
            }
            if(playing) {
                if(restore && !auditioning) {
                    // Releases and replacement ons fit 24/sample. Skip due
                    // events already represented by the reconstructed chord.
                    resumeChord(); restore=false;
                    while(index<p.count && boundary(cycle*p.length+p.events[index].step)<=position) ++index;
                } else {
                    while(index<p.count && boundary(cycle*p.length+p.events[index].step)<=position) {
                        const auto &e=p.events[index++];
                        if(auditioning) continue;
                        if(e.kind && !regionIDs[e.region]) regionIDs[e.region]=newRegion();
                        if(regionIDs[e.region]) emit(e.kind,e.pitch,e.rank,regionIDs[e.region]);
                    }
                }
                ++position;
            }
        }
        ++clock;
    }
};
extern "C" {
CodaTransport *coda_transport_create() {
    auto *t=new(std::nothrow) CodaTransport;
    if(t) {t->dsp=coda_dsp_create(); if(!t->dsp) {delete t; return nullptr;}}
    return t;
}
void coda_transport_destroy(CodaTransport *t) { if(t) {coda_dsp_destroy(t->dsp); delete t;} }
int coda_transport_prepare(CodaTransport *t,double sr) {
    if(!t) return 0;
    t->prepared=false;
    if(!coda_dsp_prepare(t->dsp,sr,1)) return 0;
    t->head=0; t->tail=0; t->ch=0; t->ct=0; t->ah=0; t->at=0;
    t->hasPlan=false; t->playing=false; t->auditioning=false; t->restore=false;
    t->playbackRevision=0; t->positionRevision=0; t->completed=false; t->outPlaybackState=0;
    t->clock=0; t->cycle=0; t->position=0; t->nextRegion=0; t->failures=0;
    for(auto &h:t->held) h={};
    t->outAck=0; t->outFailures=0; t->outPosition=0;
    t->outClock=0; t->outCycle=0; t->outDelivered=0; t->outLate=0; t->outHash=0; t->outRegion=0;
    t->prepared=true; return 1;
}
int coda_transport_publish(CodaTransport *t,const CodaPlan *p) {
    if(!t || !t->prepared || !p || !valid(*p)) return -1;
    const auto h=t->head.load(std::memory_order_relaxed);
    // tail identifies first queued slot; tail-1 is still active. Keep it alive.
    const auto tail=t->tail.load(std::memory_order_acquire);
    if(h-(tail?tail-1:0)>=CODA_PLAN_SLOTS-1 || h==UINT32_MAX) return 0;
    t->plans[h%CODA_PLAN_SLOTS]=*p;
    t->head.store(h+1,std::memory_order_release); return 1;
}
int coda_transport_controls(CodaTransport *t,const CodaControls *c) {
    if(!t || !t->prepared || !c || !validControls(*c)) return -1;
    auto h=t->ch.load(std::memory_order_relaxed);
    if(h-t->ct.load(std::memory_order_acquire)==7) return 0;
    t->controls[h%8]=*c; t->ch.store(h+1,std::memory_order_release); return 1;
}
int coda_transport_audition(CodaTransport *t,const uint8_t *p,uint32_t n,uint32_t frames) {
    if(!t || !t->prepared || n>12 || (n && (!p || !frames || frames>384000*10))) return -1;
    for(uint32_t i=0;i<n;++i) if(p[i]>127 || (i && p[i]<=p[i-1])) return -1;
    auto h=t->ah.load(std::memory_order_relaxed);
    if(h!=t->at.load(std::memory_order_acquire)) return 0;
    t->audition.count=n; t->audition.frames=frames;
    for(uint32_t i=0;i<n;++i) t->audition.pitches[i]=p[i];
    t->ah.store(h+1,std::memory_order_release); return 1;
}
void coda_transport_render(CodaTransport *t,float *out,uint32_t n) {
    if(!out || !n) return;
    if(!t || !t->prepared) {for(uint32_t i=0;i<n;++i) out[i]=0; return;}
    // Exactly seven controls per callback; empty DSP control FIFO by first
    // process sample. No competing producer can fill either DSP FIFO.
    auto c=t->ct.load(std::memory_order_relaxed), h=t->ch.load(std::memory_order_acquire);
    for(unsigned i=0;i<7 && c!=h;++i,++c)
        if(!coda_dsp_publish_controls(t->dsp,&t->controls[c%8])) ++t->failures;
    t->ct.store(c,std::memory_order_release);
    for(uint32_t i=0;i<n;++i) {t->tick(); if(!coda_dsp_process(t->dsp,out+i,1)) ++t->failures;}
    CodaDSPDiagnostics d{}; coda_dsp_inspect(t->dsp,&d);
    t->outClock.store(t->clock,std::memory_order_relaxed); t->outCycle.store(t->cycle,std::memory_order_relaxed);
    t->outDelivered.store(d.delivered,std::memory_order_relaxed); t->outLate.store(d.late,std::memory_order_relaxed);
    t->outHash.store(d.event_hash,std::memory_order_relaxed); t->outFailures.store(t->failures,std::memory_order_relaxed);
    t->outRegion.store(t->nextRegion,std::memory_order_relaxed);
    t->outPlaybackState.store((t->playbackRevision<<1) | uint64_t(t->playing),std::memory_order_release);
    t->outPosition.store(uint32_t(t->playing)<<16 | (t->hasPlan?uint32_t(std::fmod(double(t->position)/t->plans[t->active].samples_per_step,t->plans[t->active].length)):0),std::memory_order_release);
}
void coda_transport_status(const CodaTransport *t,CodaTransportStatus *s) {
    if(!t || !s) return;
    auto p=t->outPosition.load(std::memory_order_acquire);
    const auto intent=t->outPlaybackState.load(std::memory_order_acquire);
    *s={t->outClock.load(),t->outCycle.load(),t->outDelivered.load(),t->outLate.load(),t->outHash.load(),
        intent>>1,t->outAck.load(),t->outFailures.load(),t->outRegion.load(),uint16_t(p&65535),uint8_t(intent&1)};
}
}
