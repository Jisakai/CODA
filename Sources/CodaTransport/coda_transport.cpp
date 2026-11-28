#include "coda_transport.h"
#include <atomic>
#include <cmath>
#include <new>
#include <limits>
#include <algorithm>

static_assert(std::atomic<uint64_t>::is_always_lock_free);
static_assert(std::atomic<uint32_t>::is_always_lock_free);
namespace {
constexpr uint64_t maxGrid = 9007199254740992ULL;
struct Held { uint32_t region=0; uint8_t pitch=0, rank=0; bool on=false; };
struct Audition { uint8_t layer=0; uint8_t pitches[12]{}; uint32_t count=0, frames=0; };
struct ControlMsg {
    uint8_t kind=0; // 0=legacy, 1=mixer, 2=track
    uint8_t trackIndex=0;
    uint8_t eqProfile=0;
    CodaControls legacy{};
    CodaMixerControls mixer{};
    CodaLayerControls track{};
};
bool validLayerControls(const CodaLayerControls &l) {
    const float lv[]={l.wobble,l.warmth,l.cutoff,l.resonance,l.shape,l.detune,l.glide,l.level};
    for (float f:lv) if (!std::isfinite(f)) return false;
    return l.preset<=2;
}
bool validControls(const CodaControls &c) {
    const float v[]={c.wobble,c.warmth,c.cutoff,c.resonance,c.shape,c.detune,c.glide,
        c.delay_amount,c.reverb_amount,c.chord_level,c.tempo_bpm};
    for (float f:v) if (!std::isfinite(f)) return false;
    return c.preset<=2 && c.tempo_bpm>=30 && c.tempo_bpm<=300;
}
bool validMixerControls(const CodaMixerControls &m) {
    for (int i=0;i<CODA_LAYER_COUNT;++i) {
        if (!validLayerControls(m.layers[i])) return false;
    }
    const float sv[]={m.chorus_amount,m.delay_amount,m.reverb_amount,m.tempo_bpm};
    for (float f:sv) if (!std::isfinite(f)) return false;
    return m.tempo_bpm>=30 && m.tempo_bpm<=300;
}
bool valid(const CodaPlan &p) {
    if (p.playback_revision>(UINT64_MAX>>1) || !std::isfinite(p.samples_per_step) || p.samples_per_step<400 ||
        p.samples_per_step>192000 || !p.length || p.length>maxGrid || p.length%16 ||
        (p.position_revision && p.seek_step==UINT64_MAX) || p.count>CODA_PLAN_EVENTS || p.playing>1 || p.looping>1) return false;
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
    CodaPerformancePlan performancePlans[CODA_PLAN_SLOTS]{};
    uint64_t generations[CODA_PLAN_SLOTS]{};
    bool performanceModes[CODA_PLAN_SLOTS]{};
    uint64_t epoch=0, generationCounter=0, activation=0;
    struct Lane {
        CodaPerformanceCycle cycles[4]{};
        std::atomic<uint64_t> head{0}, tail{0};
        uint64_t producerGeneration=0, lastCycle=0;
        double rate=0; uint64_t length=0;
    } lanes[CODA_PLAN_SLOTS];
    // Producer owns occupancy; consumer publishes retirement only after last use.
    uint64_t occupied[CODA_PLAN_SLOTS]{};
    std::atomic<uint64_t> retired[CODA_PLAN_SLOTS]{};
    uint32_t queuedSlots[CODA_PLAN_SLOTS]{};
    std::atomic<uint64_t> outApplied{0},outRejected{0},outRequired{0},outConsumedPosition{0};
    int reserveSlot() {
        unsigned used=0;int free=-1;
        for(unsigned i=0;i<CODA_PLAN_SLOTS;++i) {
            if(occupied[i] && retired[i].load(std::memory_order_acquire)==occupied[i]) occupied[i]=0;
            if(occupied[i]) ++used;else free=int(i);
        }
        return used>=3?-1:free;
    }
    const CodaPerformanceCycle *pc=nullptr;
    uint64_t generation=0, localPosition=0, underruns=0;
    bool performance=false, starved=false;
    CodaPerformanceEvent performanceHeld[CODA_MAX_TRACKS][CODA_DSP_VOICES]{};
    uint64_t performanceInstances[CODA_MAX_TRACKS][CODA_DSP_VOICES]{};
    bool performanceOn[CODA_MAX_TRACKS][CODA_DSP_VOICES]{};
    CodaPerformanceEvent auditionPerfHeld[CODA_DSP_VOICES]{};
    bool auditionPerfOn[CODA_DSP_VOICES]{};
    std::atomic<uint64_t> outEpoch{0}, outGeneration{0}, outPerformanceCycle{0}, outRequested{0}, outUnderruns{0};
    std::atomic<uint32_t> outStarved{0},outQueued{0};
    bool freshActivation() {
        if(activation==UINT64_MAX) {++failures; playing=false; return false;}
        ++activation; return true;
    }
    void performanceEmit(CodaPerformanceEvent e, bool qualified=false) {
        if(e.layer>=CODA_MAX_TRACKS) {++failures; playing=false; return;}
        const unsigned L=e.layer;
        e.sample_offset=int64_t(clock);
        if(!qualified) e.owner={epoch,generation,pc->cycle_index,activation,e.owner.instance};
        if(!coda_dsp_push_performance_event(dsp,&e)) {++failures; playing=false;return;}
        if(e.kind) { for(unsigned i=0;i<CODA_DSP_VOICES;++i) if(!performanceOn[L][i]) {
            performanceOn[L][i]=true;performanceHeld[L][i]=e;performanceInstances[L][i]=e.owner.instance;break;
        }} else for(unsigned i=0;i<CODA_DSP_VOICES;++i) if(performanceOn[L][i]) {
            const auto &a=performanceHeld[L][i].owner;const auto &b=e.owner;
            if(a.prepare_epoch==b.prepare_epoch && a.plan_generation==b.plan_generation && a.cycle==b.cycle &&
               a.activation==b.activation && a.instance==b.instance && performanceHeld[L][i].pitch==e.pitch) performanceOn[L][i]=false;
        }
    }
    void performanceRelease() {
        for(unsigned L=0;L<CODA_MAX_TRACKS;++L)
            for(unsigned i=0;i<CODA_DSP_VOICES;++i) if(performanceOn[L][i]) {
                auto e=performanceHeld[L][i];e.kind=0;performanceEmit(e,true);
            }
    }
    void auditionReleasePerf() {
        for(unsigned i=0;i<CODA_DSP_VOICES;++i) if(auditionPerfOn[i]) {
            auto e=auditionPerfHeld[i];e.kind=0;e.sample_offset=int64_t(clock);
            if(!coda_dsp_push_performance_event(dsp,&e)) {++failures; playing=false;}
            auditionPerfOn[i]=false;
        }
    }
    void performanceRestore() {
        CodaPerformanceEvent notes[CODA_MAX_TRACKS][CODA_DSP_VOICES]{};
        bool on[CODA_MAX_TRACKS][CODA_DSP_VOICES]{};
        index=0;
        while(index<pc->count && uint64_t(pc->events[index].sample_offset)<=localPosition) {
            auto e=pc->events[index++];
            if(e.layer>=CODA_MAX_TRACKS) continue;
            const unsigned L=e.layer;
            if(e.kind) {for(unsigned i=0;i<CODA_DSP_VOICES;++i) if(!on[L][i]) {notes[L][i]=e;on[L][i]=true;break;}}
            else for(unsigned i=0;i<CODA_DSP_VOICES;++i) if(on[L][i] && notes[L][i].owner.instance==e.owner.instance) on[L][i]=false;
        }
        if(!freshActivation()) return;
        for(unsigned L=0;L<CODA_MAX_TRACKS;++L)
            for(unsigned i=0;i<CODA_DSP_VOICES;++i) if(on[L][i]) performanceEmit(notes[L][i]);
    }
    void performanceDue() {
        while(index<pc->count && uint64_t(pc->events[index].sample_offset)<=localPosition) {
            auto e=pc->events[index++];
            if(e.layer>=CODA_MAX_TRACKS) continue;
            const unsigned L=e.layer;
            if(e.kind) {
                bool continued=false;
                if(e.continuation_flags&1) for(unsigned i=0;i<CODA_DSP_VOICES;++i)
                    if(performanceOn[L][i] && performanceInstances[L][i]==e.owner.instance &&
                       performanceHeld[L][i].continuation_id==e.continuation_id && performanceHeld[L][i].pitch==e.pitch) {continued=true;break;}
                if(!continued) performanceEmit(e);
            } else for(unsigned i=0;i<CODA_DSP_VOICES;++i) if(performanceOn[L][i] && performanceInstances[L][i]==e.owner.instance) {
                const bool windowed=performancePlans[active].window_steps!=0;
                if(windowed && uint64_t(e.sample_offset)==pc->sample_count && (e.continuation_flags&2)) break;
                auto off=performanceHeld[L][i];off.kind=0;performanceEmit(off,true);break;
            }
        }
    }
    void advancePerformanceWindow(const CodaPerformanceCycle *next) {
        // Rebind compiler-local instances while retaining the original DSP owner
        // and envelope. All scans are bounded by 12 voices per layer / preallocated events.
        for(unsigned L=0;L<CODA_MAX_TRACKS;++L)
            for(unsigned i=0;i<CODA_DSP_VOICES;++i) if(performanceOn[L][i]) {
                const CodaPerformanceEvent *match=nullptr;
                if(performanceHeld[L][i].continuation_flags&2) {
                    for(uint32_t j=0;j<next->count && next->events[j].sample_offset==0;++j) {
                        const auto &e=next->events[j];
                        if(e.kind && e.layer==L && (e.continuation_flags&1) && e.continuation_id &&
                           e.continuation_id==performanceHeld[L][i].continuation_id && e.pitch==performanceHeld[L][i].pitch) {match=&e;break;}
                    }
                }
                if(match) {
                    performanceInstances[L][i]=match->owner.instance;
                    performanceHeld[L][i].continuation_flags=match->continuation_flags;
                } else {auto off=performanceHeld[L][i];off.kind=0;performanceEmit(off,true);}
            }
    }
    void performanceTick(bool changed) {
        if(!playing || !pc) return;
        if(localPosition>=pc->sample_count) {
            if(!auditioning) performanceDue();
            const auto unit=performancePlans[active].window_steps;
            const bool terminal=!plans[active].looping && (!unit || pc->cycle_index+1>=plans[active].length/unit);
            if(terminal) {performanceRelease();playing=false;completed=true;return;}
            auto &lane=lanes[active];
            const auto t=lane.tail.load(std::memory_order_relaxed), h=lane.head.load(std::memory_order_acquire);
            if(t==h) {
                if(!starved) {++underruns;starved=true;}
                performanceRelease();
                return;
            }
            const auto *next=&lane.cycles[t%4];
            if(unit && !starved && !auditioning) advancePerformanceWindow(next);
            else performanceRelease();
            const bool reconstruct=starved || !unit;
            pc=next;lane.tail.store(t+1,std::memory_order_release);
            localPosition=0;cycle=pc->cycle_index;index=0;starved=false;restore=reconstruct && !auditioning;
        }
        if(!auditioning) {
            if(restore || changed) {performanceRestore();restore=false;}
            else performanceDue();
        }
        ++localPosition;++position;
    }

    CodaDSP *dsp=nullptr;
    CodaPlan plans[CODA_PLAN_SLOTS]{};
    std::atomic<uint32_t> head{0}, tail{0};
    uint32_t active=0; bool hasPlan=false, prepared=false, playing=false;
    ControlMsg controls[8]{};
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
    std::atomic<uint32_t> outAck{0}, outFailures{0}, outRegion{0}, outCompleted{0};
    std::atomic<uint64_t> outPosition{0};
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
        performanceRelease();
        auditionReleasePerf();
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
        // Leave room for the DSP signed sample clock. Exhaustion cannot alias an
        // earlier timestamp; retire ownership once and then remain silent.
        if(clock>=uint64_t(INT64_MAX)-1) {release();playing=false;++clock;return;}

        // At most one plan and one audition per sample. Old queue contains no
        // future notes: the scheduler is the exclusive DSP producer/consumer.
        const auto h=head.load(std::memory_order_acquire);
        bool changed=false;
        if(tail.load(std::memory_order_relaxed)!=h) {
            const auto first=tail.load(std::memory_order_relaxed), candidate=queuedSlots[(h-1)%CODA_PLAN_SLOTS];
            const auto &incoming=plans[candidate];
            const bool explicitPosition=incoming.position_revision>positionRevision;
            const bool restart=incoming.playback_revision>playbackRevision && incoming.playing && completed;
            const bool atBoundary=hasPlan && playing && plans[active].looping &&
                (performance ? pc && localPosition>=pc->sample_count
                             : position>=boundary((cycle+1)*plans[active].length));
            const auto required=atBoundary ? cycle+1:cycle;
            const bool reject=performanceModes[candidate] && hasPlan && !explicitPosition && !restart &&
                performancePlans[candidate].initial_cycle.cycle_index!=required;
            if(reject) {
                outRequired.store(required,std::memory_order_relaxed);
                outRejected.store(generations[candidate],std::memory_order_release);
                retired[candidate].store(generations[candidate],std::memory_order_release);
                // Superseded slots share this published outcome; release before tail reuse.
                for(auto q=first;q<h-1;++q) {
                    const auto slot=queuedSlots[q%CODA_PLAN_SLOTS];
                    retired[slot].store(generations[slot],std::memory_order_release);
                }
                tail.store(h,std::memory_order_release);
            } else {
            release(); auditioning=false;
            const auto oldCycle=cycle, oldPosition=position;
            const bool oldPerformance=performance, restarting=completed;
            const auto oldLocalPosition=localPosition;
            const auto oldLength=hasPlan?plans[active].length:0;
            const auto oldRate=hasPlan?plans[active].samples_per_step:1;
            const double oldStep=hasPlan?std::fmod(double(position)/oldRate,double(oldLength)):0;
            const auto t=h-1;
            const bool hadPlan=hasPlan;const auto previous=active;
            active=candidate; hasPlan=true;
            performance=performanceModes[active];generation=generations[active];
            if(performance) {
                pc=&performancePlans[active].initial_cycle;
                localPosition=0; starved=false;
            }
            const auto &p=plans[active];
            const bool playbackCommand=p.playback_revision>playbackRevision;
            const bool positionCommand=p.position_revision>positionRevision;
            const auto windowSteps=performance?performancePlans[active].window_steps:0;
            if(windowSteps) {
                cycle=pc->cycle_index;
                const double step=positionCommand?double(std::min(p.seek_step,p.length-1)):
                    ((playbackCommand && p.playing && restarting)?0:std::fmod(oldStep,double(p.length)));
                const double localStep=std::fmod(step,double(windowSteps));
                const auto absolute=uint64_t(std::round((double(cycle*windowSteps)+localStep)*p.samples_per_step));
                localPosition=absolute>=pc->sample_origin?std::min(absolute-pc->sample_origin,pc->sample_count):0;
                position=pc->sample_origin+localPosition;
                if(positionCommand) {
                    positionRevision=p.position_revision;completed=false;
                    outConsumedPosition.store(positionRevision,std::memory_order_release);
                }
                if(playbackCommand) {playing=p.playing;playbackRevision=p.playback_revision;if(p.playing)completed=false;}
            } else {
            cycle=0;
            // A stopped endpoint is not a wrapped step zero. Preserve it through
            // configuration remapping until an explicit Play or position command.
            position=completed?boundary(p.length):uint64_t(std::round(std::fmod(oldStep,p.length)*p.samples_per_step));
            if(oldLength==p.length && oldRate==p.samples_per_step) {
                cycle=oldCycle; position=oldPosition;
            }
            if(oldLength && oldPerformance!=performance && !completed) {
                cycle=required;
                if(atBoundary || oldLength!=p.length || oldRate!=p.samples_per_step) {
                    const double localStep=atBoundary?0:std::fmod(oldStep,p.length);
                    position=uint64_t(std::round((double(cycle*p.length)+localStep)*p.samples_per_step));
                }
            }
            if(positionCommand) {
                cycle=0; position=boundary(p.seek_step<p.length?p.seek_step:p.length-1);
                positionRevision=p.position_revision; completed=false;
                outConsumedPosition.store(positionRevision,std::memory_order_release);
            }
            if(playbackCommand) {
                if(p.playing && completed) {cycle=0; position=0; completed=false;}
                playing=p.playing; playbackRevision=p.playback_revision;
            }
            if(performance) {
                cycle=pc->cycle_index;
                if(positionCommand) {
                    const auto step=p.seek_step<p.length?p.seek_step:p.length-1;
                    localPosition=boundary(cycle*p.length+step)-pc->sample_origin;
                } else if(oldLength && oldCycle==cycle) {
                    if(playbackCommand && p.playing && restarting) localPosition=0;
                    else if(oldPerformance && oldLength==p.length && oldRate==p.samples_per_step) localPosition=oldLocalPosition;
                    else localPosition=uint64_t(std::round((double(cycle*p.length)+std::fmod(oldStep,p.length))*p.samples_per_step))-pc->sample_origin;
                    if(localPosition>pc->sample_count) localPosition=pc->sample_count;
                } else localPosition=0;
                position=pc->sample_origin+localPosition;
            }
            }
            origin=position; index=0;
            for(auto &id:regionIDs) id=0;
            // ACK previous slot only AFTER its last access. Retain current slot.
            outApplied.store(generations[active],std::memory_order_release);
            // Acquiring retirement must also observe the replacement ACK.
            if(hadPlan) retired[previous].store(generations[previous],std::memory_order_release);
            if(t>0) outAck.store(t,std::memory_order_release);
                // Superseded slots share this published outcome; release before tail reuse.
                for(auto q=first;q<h-1;++q) {
                    const auto slot=queuedSlots[q%CODA_PLAN_SLOTS];
                    retired[slot].store(generations[slot],std::memory_order_release);
                }
            tail.store(h,std::memory_order_release);
            restore=playing; changed=true;
            }
        }
        if(ah.load(std::memory_order_acquire)!=at.load(std::memory_order_relaxed)) {
            if(!changed) release();
            const auto a=audition; // fixed POD copy before acknowledgment
            at.store(ah.load(std::memory_order_relaxed),std::memory_order_release);
            auditioning=a.count!=0; auditionEnd=clock+a.frames;
            if(auditioning) {
                if(a.layer==CODA_LAYER_CHORDS) {
                    auto id=newRegion();
                    for(uint32_t r=0;r<a.count && id;++r) emit(1,a.pitches[r],uint8_t(r),id);
                } else if(a.layer<CODA_MAX_TRACKS && freshActivation()) {
                    const uint64_t gen=generation?generation:1;
                    for(uint32_t r=0;r<a.count;++r) {
                        CodaPerformanceEvent e{};
                        e.sample_offset=int64_t(clock);
                        e.owner={epoch,gen,UINT64_MAX,activation,uint64_t(r+1)};
                        e.harmonic_token=1;
                        e.kind=CODA_EVENT_ON;
                        e.pitch=a.pitches[r];
                        e.voice_rank=uint8_t(r);
                        e.attack_mode=CODA_ATTACK_ORDINARY;
                        e.base_velocity=0.8f;
                        e.effective_velocity=0.8f;
                        e.layer=a.layer;
                        if(!coda_dsp_push_performance_event(dsp,&e)) {++failures; playing=false; break;}
                        auditionPerfHeld[r]=e; auditionPerfOn[r]=true;
                    }
                }
            } else restore=playing;
            changed=true;
        } else if(auditioning && clock>=auditionEnd) {
            release(); auditioning=false; restore=playing; changed=true;
        }
        if(hasPlan && performance) {
            performanceTick(changed);++clock;return;
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
namespace {
bool cycleBoundary(uint64_t cycle,double rate,uint64_t length,uint64_t &origin) {
    if(!length || length>maxGrid || cycle==UINT64_MAX) return false;
    if(cycle>maxGrid/length || cycle*length>maxGrid-length) return false;
    const double value=std::round(double(cycle*length)*rate);
    if(!std::isfinite(value) || value<0 || value>=double(INT64_MAX)) return false;
    origin=uint64_t(value);return true;
}
bool validCycle(const CodaPerformanceCycle &c,double rate,uint64_t length) {
    uint64_t origin,end;
    if(c.count>CODA_PLAN_EVENTS || !cycleBoundary(c.cycle_index,rate,length,origin) ||
       !cycleBoundary(c.cycle_index+1,rate,length,end) || c.sample_origin!=origin || !c.sample_count || c.sample_count!=end-origin) return false;
    CodaPerformanceEvent held[CODA_MAX_TRACKS][CODA_DSP_VOICES]{};
    bool on[CODA_MAX_TRACKS][CODA_DSP_VOICES]{};
    unsigned group=0;
    for(uint32_t i=0;i<c.count;++i) {
        const auto &e=c.events[i];const auto &o=e.owner;
        if(e.sample_offset<0 || uint64_t(e.sample_offset)>c.sample_count || e.kind>1 || e.pitch>127 || e.voice_rank>=CODA_DSP_VOICES ||
           e.layer>=CODA_MAX_TRACKS ||
           e.attack_mode>1 || e.slide>1 || e.continuation_flags>3 || (e.continuation_flags && !e.continuation_id) || !o.instance || o.prepare_epoch || o.plan_generation || o.cycle || o.activation || !e.harmonic_token ||
           !std::isfinite(e.base_velocity) || e.base_velocity<=0 || e.base_velocity>1 ||
           !std::isfinite(e.effective_velocity) || e.effective_velocity<=0 || e.effective_velocity>1 ||
           !std::isfinite(e.detune_cents) || std::abs(e.detune_cents)>3 ||
           !std::isfinite(e.filter_delta) || std::abs(e.filter_delta)>.02f) return false;
        if(i && (e.sample_offset<c.events[i-1].sample_offset || (e.sample_offset==c.events[i-1].sample_offset && e.kind<c.events[i-1].kind))) return false;
        if(!i || e.sample_offset!=c.events[i-1].sample_offset) group=0;
        if(++group>CODA_DSP_MAX_EVENTS_PER_SAMPLE) return false;
        const unsigned L=e.layer;
        if(e.kind) {
            if(uint64_t(e.sample_offset)==c.sample_count) return false;
            for(uint32_t j=0;j<i;++j) if(c.events[j].kind && c.events[j].layer==L && c.events[j].owner.instance==o.instance) return false;
            for(unsigned j=0;j<CODA_DSP_VOICES;++j) if(on[L][j] && held[L][j].pitch==e.pitch) return false;
            unsigned j=0;while(j<CODA_DSP_VOICES && on[L][j]) ++j;if(j==CODA_DSP_VOICES) return false;
            held[L][j]=e;on[L][j]=true;
        } else {
            unsigned j=0;while(j<CODA_DSP_VOICES && (!on[L][j] || held[L][j].owner.instance!=o.instance || held[L][j].pitch!=e.pitch)) ++j;
            if(j==CODA_DSP_VOICES) return false;
            on[L][j]=false;
        }
    }
    for(unsigned L=0;L<CODA_MAX_TRACKS;++L)
        for(unsigned j=0;j<CODA_DSP_VOICES;++j) if(on[L][j]) return false;
    return true;
}
}
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
    if(t->epoch==UINT64_MAX || !coda_dsp_prepare(t->dsp,sr,1)) return 0;
    ++t->epoch;t->activation=0;
    t->performance=false;t->pc=nullptr;t->underruns=0;t->starved=false;
    for(unsigned i=0;i<CODA_PLAN_SLOTS;++i) {t->occupied[i]=0;t->retired[i]=0;t->lanes[i].head=0;t->lanes[i].tail=0;t->lanes[i].producerGeneration=0;}
    t->outApplied=0;t->outRejected=0;t->outRequired=0;t->outConsumedPosition=0;
    for(unsigned L=0;L<CODA_MAX_TRACKS;++L)
        for(unsigned i=0;i<CODA_DSP_VOICES;++i) t->performanceOn[L][i]=false;
    for(unsigned i=0;i<CODA_DSP_VOICES;++i) t->auditionPerfOn[i]=false;
    t->outEpoch=t->epoch;t->outGeneration=0;t->outPerformanceCycle=0;t->outRequested=0;t->outUnderruns=0;t->outStarved=0;t->outQueued=0;
    t->head=0; t->tail=0; t->ch=0; t->ct=0; t->ah=0; t->at=0;
    t->hasPlan=false; t->playing=false; t->auditioning=false; t->restore=false;
    t->playbackRevision=0; t->positionRevision=0; t->completed=false; t->outPlaybackState=0;
    t->clock=0; t->cycle=0; t->position=0; t->nextRegion=0; t->failures=0;
    for(auto &h:t->held) h={};
    t->outAck=0; t->outFailures=0; t->outPosition=0;t->outCompleted=0;
    t->outClock=0; t->outCycle=0; t->outDelivered=0; t->outLate=0; t->outHash=0; t->outRegion=0;
    t->prepared=true; return 1;
}
int coda_transport_publish(CodaTransport *t,const CodaPlan *p) {
    uint64_t ignored=0; return coda_transport_publish_generation(t,p,&ignored);
}
int coda_transport_publish_generation(CodaTransport *t,const CodaPlan *p,uint64_t *accepted) {
    if(!accepted) return -1;
    if(!t || !t->prepared || !p || !valid(*p)) return -1;
    const auto h=t->head.load(std::memory_order_relaxed);
    const int available=t->reserveSlot();
    if(available<0 || h==UINT32_MAX) return 0;
    if(t->generationCounter==UINT64_MAX) return -1;
    const auto slot=uint32_t(available);
    t->performanceModes[slot]=false;
    t->generations[slot]=++t->generationCounter;t->occupied[slot]=t->generationCounter;
    t->plans[slot]=*p;t->queuedSlots[h%CODA_PLAN_SLOTS]=slot;
    t->head.store(h+1,std::memory_order_release); *accepted=t->generationCounter; return 1;
}
int coda_transport_controls(CodaTransport *t,const CodaControls *c) {
    if(!t || !t->prepared || !c || !validControls(*c)) return -1;
    auto h=t->ch.load(std::memory_order_relaxed);
    if(h-t->ct.load(std::memory_order_acquire)==7) return 0;
    ControlMsg msg{}; msg.kind=0; msg.legacy=*c;
    t->controls[h%8]=msg; t->ch.store(h+1,std::memory_order_release); return 1;
}
int coda_transport_mixer_controls(CodaTransport *t,const CodaMixerControls *m) {
    if(!t || !t->prepared || !m || !validMixerControls(*m)) return -1;
    auto h=t->ch.load(std::memory_order_relaxed);
    if(h-t->ct.load(std::memory_order_acquire)==7) return 0;
    ControlMsg msg{}; msg.kind=1; msg.mixer=*m;
    t->controls[h%8]=msg; t->ch.store(h+1,std::memory_order_release); return 1;
}
int coda_transport_track_controls(CodaTransport *t,uint8_t track_index,uint8_t eq_profile,const CodaLayerControls *c) {
    if(!t || !t->prepared || !c || track_index>=CODA_MAX_TRACKS || eq_profile>=CODA_LAYER_COUNT || !validLayerControls(*c)) return -1;
    auto h=t->ch.load(std::memory_order_relaxed);
    if(h-t->ct.load(std::memory_order_acquire)==7) return 0;
    ControlMsg msg{}; msg.kind=2; msg.trackIndex=track_index; msg.eqProfile=eq_profile; msg.track=*c;
    t->controls[h%8]=msg; t->ch.store(h+1,std::memory_order_release); return 1;
}
int coda_transport_audition_layer(CodaTransport *t,uint8_t layer,const uint8_t *p,uint32_t n,uint32_t frames) {
    if(!t || !t->prepared || layer>=CODA_MAX_TRACKS || n>12 || (n && (!p || !frames || frames>384000*10))) return -1;
    for(uint32_t i=0;i<n;++i) if(p[i]>127 || (i && p[i]<=p[i-1])) return -1;
    auto h=t->ah.load(std::memory_order_relaxed);
    if(h!=t->at.load(std::memory_order_acquire)) return 0;
    t->audition.layer=layer; t->audition.count=n; t->audition.frames=frames;
    for(uint32_t i=0;i<n;++i) t->audition.pitches[i]=p[i];
    t->ah.store(h+1,std::memory_order_release); return 1;
}
int coda_transport_audition(CodaTransport *t,const uint8_t *p,uint32_t n,uint32_t frames) {
    return coda_transport_audition_layer(t,CODA_LAYER_CHORDS,p,n,frames);
}
void coda_transport_render(CodaTransport *t,float *out,uint32_t n) {
    if(!out || !n) return;
    if(!t || !t->prepared) {for(uint32_t i=0;i<n;++i) out[i]=0; return;}
    // Exactly seven controls per callback; empty DSP control FIFO by first
    // process sample. No competing producer can fill either DSP FIFO.
    auto c=t->ct.load(std::memory_order_relaxed), h=t->ch.load(std::memory_order_acquire);
    for(unsigned i=0;i<7 && c!=h;++i,++c) {
        const auto &msg=t->controls[c%8];
        const int ok=(msg.kind==2)
            ? coda_dsp_publish_track_controls(t->dsp,msg.trackIndex,msg.eqProfile,&msg.track)
            : (msg.kind==1
                ? coda_dsp_publish_mixer_controls(t->dsp,&msg.mixer)
                : coda_dsp_publish_controls(t->dsp,&msg.legacy));
        if(!ok) ++t->failures;
    }
    t->ct.store(c,std::memory_order_release);
    for(uint32_t i=0;i<n;++i) {
        if(t->clock>=uint64_t(INT64_MAX)) {out[i]=0;continue;}
        t->tick(); if(!coda_dsp_process(t->dsp,out+i,1)) ++t->failures;
    }
    CodaDSPDiagnostics d{}; coda_dsp_inspect(t->dsp,&d);
    t->outGeneration.store(t->performance?t->generation:0);
    t->outPerformanceCycle.store(t->performance && t->pc?t->pc->cycle_index:0);
    t->outRequested.store(t->performance && t->pc?t->pc->cycle_index+1:0);
    if(t->performance) {
        const auto &lane=t->lanes[t->active];
        t->outQueued.store(uint32_t(lane.head.load(std::memory_order_acquire)-lane.tail.load(std::memory_order_relaxed)));
    } else t->outQueued.store(0);
    t->outUnderruns.store(t->underruns);t->outStarved.store(t->starved);
    t->outClock.store(t->clock,std::memory_order_relaxed); t->outCycle.store(t->cycle,std::memory_order_relaxed);
    t->outDelivered.store(d.delivered,std::memory_order_relaxed); t->outLate.store(d.late,std::memory_order_relaxed);
    t->outHash.store(d.event_hash,std::memory_order_relaxed); t->outFailures.store(t->failures,std::memory_order_relaxed);
    t->outRegion.store(t->nextRegion,std::memory_order_relaxed);
    t->outPlaybackState.store((t->playbackRevision<<1) | uint64_t(t->playing),std::memory_order_release);
    t->outCompleted.store(t->completed,std::memory_order_relaxed);
    const auto step=t->hasPlan?(t->completed?t->plans[t->active].length-1:
        uint64_t(std::fmod(double(t->position)/t->plans[t->active].samples_per_step,double(t->plans[t->active].length)))):0;
    t->outPosition.store(step,std::memory_order_release);
}
void coda_transport_status(const CodaTransport *t,CodaTransportStatus *s) {
    if(!t || !s) return;
    auto p=t->outPosition.load(std::memory_order_acquire);
    const auto intent=t->outPlaybackState.load(std::memory_order_acquire);
    *s={t->outClock.load(),t->outCycle.load(),t->outDelivered.load(),t->outLate.load(),t->outHash.load(),
        intent>>1,t->outAck.load(),t->outFailures.load(),t->outRegion.load(),p,uint8_t(intent&1),uint8_t(t->outCompleted.load())};
}
int coda_transport_publish_performance(CodaTransport *t,const CodaPerformancePlan *p,uint64_t *accepted) {
    if(!t || !t->prepared || !p || !accepted) return -1;
    CodaPlan shell{};shell.playback_revision=p->playback_revision;shell.position_revision=p->position_revision;
    shell.samples_per_step=p->samples_per_step;shell.length=p->length;shell.seek_step=p->seek_step;
    shell.playing=p->playing;shell.looping=p->looping;
    const auto unit=p->window_steps?p->window_steps:p->length;
    if((p->window_steps && (p->window_steps%16 || p->length%p->window_steps)) || !valid(shell) ||
       !validCycle(p->initial_cycle,p->samples_per_step,unit) || t->generationCounter==UINT64_MAX) return -1;
    const auto h=t->head.load(std::memory_order_relaxed);
    const int available=t->reserveSlot();
    if(available<0 || h==UINT32_MAX) return 0;
    const auto slot=uint32_t(available);const auto g=t->generationCounter+1;
    t->performancePlans[slot]=*p;t->plans[slot]=shell;t->performanceModes[slot]=true;t->generations[slot]=g;
    auto &lane=t->lanes[slot];lane.head=0;lane.tail=0;lane.producerGeneration=g;
    lane.rate=p->samples_per_step;lane.length=unit;lane.lastCycle=p->initial_cycle.cycle_index;
    t->occupied[slot]=g;t->generationCounter=g;t->queuedSlots[h%CODA_PLAN_SLOTS]=slot;
    *accepted=g;t->head.store(h+1,std::memory_order_release);return 1;
}
int coda_transport_enqueue_performance_cycle(CodaTransport *t,uint64_t g,const CodaPerformanceCycle *c) {
    if(!t || !t->prepared || !c || !g) return -1;
    for(unsigned slot=0;slot<CODA_PLAN_SLOTS;++slot) {
        if(t->occupied[slot]!=g || t->retired[slot].load(std::memory_order_acquire)==g) continue;
        auto &lane=t->lanes[slot];
        if(lane.producerGeneration!=g || lane.lastCycle==UINT64_MAX || c->cycle_index!=lane.lastCycle+1 ||
           !validCycle(*c,lane.rate,lane.length)) return -1;
        const auto h=lane.head.load(std::memory_order_relaxed),tail=lane.tail.load(std::memory_order_acquire);
        if(h-(tail?tail-1:0)>=3 || h==UINT64_MAX) return 0;
        lane.cycles[h%4]=*c;lane.lastCycle=c->cycle_index;
        lane.head.store(h+1,std::memory_order_release);return 1;
    }
    return -1;
}
void coda_transport_performance_status(const CodaTransport *t,CodaPerformanceStatus *s) {
    if(!t || !s) return;
    *s={t->outEpoch.load(),t->outGeneration.load(),t->outPerformanceCycle.load(),t->outRequested.load(),t->outUnderruns.load(),t->outQueued.load(),uint8_t(t->outStarved.load()),
        t->outApplied.load(std::memory_order_acquire),t->outRejected.load(std::memory_order_acquire),t->outRequired.load(),t->outConsumedPosition.load(std::memory_order_acquire)};
}

void coda_transport_inspect_performance(const CodaTransport *t,CodaPerformanceVoiceDiagnostic out[CODA_DSP_VOICES]) {
    if(t && out) coda_dsp_inspect_performance(t->dsp,out);
}

}
