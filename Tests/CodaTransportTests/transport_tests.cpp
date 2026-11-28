#include "coda_transport.h"
#include "RenderGate.h"
#include "allocation_hooks.h"
#include <cmath>
#include <cstdio>
#include <thread>
#include <vector>
#include <condition_variable>
#include <chrono>
#if defined(__APPLE__)
#include "../../CodaDSP/tests/lock_hooks.h"
#include <pthread.h>
#include <os/lock.h>
#endif

static void check(bool ok,const char *s) {if(!ok) {std::fprintf(stderr,"FAIL: %s\n",s);std::exit(1);}}
struct Owner {
    CodaTransport *t=coda_transport_create();
    Owner(double sr=8000) {check(t && coda_transport_prepare(t,sr),"prepare");}
    ~Owner() {coda_transport_destroy(t);}
};
static CodaPlan plan(double step=400.137) {
    CodaPlan p{}; p.playback_revision=1; p.samples_per_step=step; p.length=16; p.playing=1; p.looping=1; p.count=6;
    for(uint8_t r=0;r<3;++r) {
        p.events[r]={0,0,1,uint8_t(60+r*3),r,0};
        p.events[r+3]={16,0,0,uint8_t(60+r*3),r,0};
    }
    return p;
}
static CodaTransportStatus status(CodaTransport *t) {CodaTransportStatus s{}; coda_transport_status(t,&s); return s;}
static void run(CodaTransport *t,uint32_t n,uint32_t block=257) {
    float out[1024]; check(block<=1024,"test block");
    count_allocations=true;
#if defined(__APPLE__)
    coda_test_lock_begin();
#endif
    for(uint32_t at=0;at<n;) {
        auto size=std::min(block,n-at); coda_transport_render(t,out,size); at+=size;
        for(uint32_t i=0;i<size;++i) check(std::isfinite(out[i]) && std::abs(out[i])<0.73f,"finite safe audio");
    }
    count_allocations=false;
#if defined(__APPLE__)
    coda_test_lock_end();check(coda_test_lock_count()==0,"transport render zero mutex/unfair locks");
#endif
    check(allocation_count==0 && deallocation_count==0,"zero render allocations/deallocations");
    check(status(t).failures==0 && status(t).late==0,"no admission failures or late events");
}
static uint64_t hashEvent(uint64_t h,uint64_t sample,uint32_t region,uint8_t kind) {
    h=(h^sample)*1099511628211ULL; h=(h^region)*1099511628211ULL; return (h^kind)*1099511628211ULL;
}
static void timing() {
    for(uint32_t block:{1u,17u,257u,1024u}) {
        Owner o; auto p=plan(); check(coda_transport_publish(o.t,&p)==1,"publish");
        constexpr uint32_t cycles=80;
        const auto total=uint32_t(std::floor(cycles*16*p.samples_per_step+0.5))+1;
        run(o.t,total,block);
        uint64_t hash=1469598103934665603ULL, delivered=0;
        for(uint32_t c=0;c<=cycles;++c) {
            const auto sample=uint64_t(std::floor(c*16*p.samples_per_step+0.5));
            if(c) for(int r=0;r<3;++r) {hash=hashEvent(hash,sample,c,0); ++delivered;}
            for(int r=0;r<3;++r) {hash=hashEvent(hash,sample,c+1,1); ++delivered;}
        }
        const auto s=status(o.t);
        check(s.hash==hash && s.delivered==delivered,"absolute fractional wraps: exact sample/off-before-on/region hash");
        check(s.cycle==cycles && s.region==cycles+1,"cycle-safe unique IDs");
    }
}
static void transitions() {
    Owner o; auto p=plan(); check(coda_transport_publish(o.t,&p)==1,"initial plan"); run(o.t,19);
    auto s=status(o.t); check(s.delivered==3,"initial onset");
    p.playing=0; ++p.playback_revision; p.seek_step=UINT16_MAX; check(coda_transport_publish(o.t,&p)==1,"pause"); run(o.t,1);
    check(status(o.t).delivered==6 && !status(o.t).playing,"pause releases"); run(o.t,100);
    check(status(o.t).delivered==6,"paused no onsets");
    p.playing=1; ++p.playback_revision; check(coda_transport_publish(o.t,&p)==1,"resume"); run(o.t,1);
    check(status(o.t).delivered==9,"resume reconstructs current chord");
    const uint8_t pitches[]={48,52,55};
    check(coda_transport_audition(o.t,pitches,3,10)==1,"audition");
    check(coda_transport_audition(o.t,pitches,3,10)==0,"audition full observable");
    run(o.t,11);
    check(status(o.t).delivered==21,"audition off/on and restoration");
    const auto old=status(o.t).delivered;
    p.seek_step=4; ++p.position_revision; check(coda_transport_publish(o.t,&p)==1,"seek"); run(o.t,1);
    check(status(o.t).delivered==old+6 && status(o.t).step==4,"seek release/reconstruct");
    p.count=0; check(coda_transport_publish(o.t,&p)==1,"empty replacement"); run(o.t,20000);
    check(status(o.t).delivered==old+9,"empty spans don't retrigger stale events");
    p=plan(); p.playback_revision=4; p.position_revision=2; p.looping=0; check(coda_transport_publish(o.t,&p)==1,"nonloop"); run(o.t,7000);
    s=status(o.t); check(!s.playing,"nonloop ends"); run(o.t,7000);
    check(status(o.t).delivered==s.delivered,"end cannot leave pending notes");
    p=plan(); p.playback_revision=5; p.position_revision=3; p.seek_step=0;
    check(coda_transport_publish(o.t,&p)==1,"restart after end"); run(o.t,1);
    check(status(o.t).playing && status(o.t).delivered==s.delivered+3,"restart onsets");
}
// Twelve-note chords exercise the actual maximum transition group (24/sample).
static CodaPlan endpointPlan(double step) {
    auto p=plan(step); p.looping=0; p.count=0;
    for(uint8_t r=0;r<12;++r) p.events[p.count++]={0,0,1,uint8_t(48+r),r,0};
    for(uint8_t r=0;r<12;++r) p.events[p.count++]={8,0,0,uint8_t(48+r),r,0};
    for(uint8_t r=0;r<12;++r) p.events[p.count++]={8,1,1,uint8_t(60+r),r,0};
    for(uint8_t r=0;r<12;++r) p.events[p.count++]={16,1,0,uint8_t(60+r),r,0};
    return p;
}
static uint64_t hashChord(uint64_t hash,uint64_t sample,uint32_t region,uint8_t kind) {
    for(int r=0;r<12;++r) hash=hashEvent(hash,sample,region,kind);
    return hash;
}
static void nonloopBoundaries() {
    for(double step:{400.02,400.04}) for(uint32_t block:{1u,17u,257u,1024u}) {
        Owner o; auto p=endpointPlan(step);
        const auto middle=uint32_t(std::round(8*step)), end=uint32_t(std::round(16*step));
        check(coda_transport_publish(o.t,&p)==1,"nonloop fractional endpoint plan");
        run(o.t,end,block);
        auto hash=hashChord(1469598103934665603ULL,0,1,1);
        hash=hashChord(hash,middle,1,0); hash=hashChord(hash,middle,2,1);
        check(status(o.t).hash==hash && status(o.t).delivered==36 && status(o.t).playing,
              "pre-end exact region hash and middle off-before-on");
        run(o.t,1); hash=hashChord(hash,end,2,0);
        const auto stopped=status(o.t);
        check(stopped.hash==hash && stopped.delivered==48 && !stopped.playing && stopped.region==2,
              "rounded nonloop endpoint releases exactly once");
        run(o.t,end+100,block);
        check(status(o.t).hash==hash && status(o.t).delivered==48 && status(o.t).region==2,
              "no held events or new identities after nonloop completion");
    }
}
static void auditionAtEnd() {
    for(double step:{400.02,400.04}) for(int scenario=0;scenario<3;++scenario) {
        Owner o; auto p=endpointPlan(step);
        const auto middle=uint32_t(std::round(8*step)), end=uint32_t(std::round(16*step));
        check(coda_transport_publish(o.t,&p)==1,"audition endpoint plan");
        const auto start=end-3;
        run(o.t,start);
        uint8_t pitches[12]; for(unsigned r=0;r<12;++r) pitches[r]=uint8_t(72+r);
        const uint32_t frames=scenario==1?3:6;
        check(coda_transport_audition(o.t,pitches,12,frames)==1,"endpoint audition admitted");
        auto hash=hashChord(1469598103934665603ULL,0,1,1);
        hash=hashChord(hash,middle,1,0); hash=hashChord(hash,middle,2,1);
        hash=hashChord(hash,start,2,0); hash=hashChord(hash,start,3,1);
        run(o.t,3);
        check(status(o.t).hash==hash && status(o.t).delivered==60,"audition replaces transport with exactly 24 events");
        if(scenario==2) {
            p.seek_step=0;
            check(coda_transport_publish(o.t,&p)==1,"plan replacement simultaneous with end");
        }
        run(o.t,1);
        if(scenario!=0) hash=hashChord(hash,end,3,0);
        check(!status(o.t).playing && status(o.t).hash==hash,
              "natural end never restores transport over audition or replacement");
        if(scenario==0) {
            check(status(o.t).delivered==60,"independent audition spans natural end");
            run(o.t,2);
            check(status(o.t).hash==hash,"audition held until exact independent expiry");
            run(o.t,1); hash=hashChord(hash,start+frames,3,0);
        }
        run(o.t,1000);
        check(status(o.t).hash==hash && status(o.t).delivered==72 && status(o.t).region==3,
              "expiry/cancellation releases exactly once and never restores stopped chord");
    }
}
// Production snapshots carry cumulative intent even when intermediate plans
// are skipped. Configuration never advances either command revision.
static void durableIntent() {
    Owner o; auto p=plan(400.04); p.looping=0;
    check(coda_transport_publish(o.t,&p)==1,"intent initial play"); run(o.t,7000);
    auto ended=status(o.t); check(!ended.playing,"intent natural completion");
    p.samples_per_step=800.08;
    check(coda_transport_publish(o.t,&p)==1,"completed tempo snapshot"); run(o.t,1);
    check(!status(o.t).playing && status(o.t).hash==ended.hash,"configuration cannot restart completed audio");
    ++p.playback_revision;
    check(coda_transport_publish(o.t,&p)==1,"explicit play after completion"); run(o.t,1);
    check(status(o.t).playing && status(o.t).step==0 && status(o.t).delivered==ended.delivered+3,
          "new Play starts completed sequence at zero");
    run(o.t,6500);
    p.playing=0; ++p.playback_revision; p.seek_step=0; ++p.position_revision;
    check(coda_transport_publish(o.t,&p)==1,"stop at step eight");
    p.playing=1; ++p.playback_revision;
    check(coda_transport_publish(o.t,&p)==1,"play coalesces stop"); run(o.t,1);
    check(status(o.t).step==0 && status(o.t).playing,"stop position survives newer play");
    p.seek_step=10; ++p.position_revision;
    check(coda_transport_publish(o.t,&p)==1,"seek ten");
    p.samples_per_step=400.04;
    check(coda_transport_publish(o.t,&p)==1,"tempo after seek"); run(o.t,1);
    check(status(o.t).step==10,"seek survives tempo snapshot");
    run(o.t,500);
    check(coda_transport_publish(o.t,&p)==1,"consumed seek configuration"); run(o.t,1);
    check(status(o.t).step==11,"already consumed seek never replays");
    p.seek_step=2; ++p.position_revision;
    check(coda_transport_publish(o.t,&p)==1,"first seek");
    p.seek_step=7; ++p.position_revision;
    check(coda_transport_publish(o.t,&p)==1,"latest seek"); run(o.t,1);
    check(status(o.t).step==7,"multiple seeks last wins");
    p.seek_step=6; ++p.position_revision;
    check(coda_transport_publish(o.t,&p)==1,"seek before edit");
    p.count=0;
    check(coda_transport_publish(o.t,&p)==1,"edit snapshot after seek"); run(o.t,1);
    check(status(o.t).step==6,"seek survives event edit");
    check(coda_transport_prepare(o.t,8000),"fresh intent epoch");
    check(coda_transport_publish(o.t,&p)==1,"seed fresh epoch with retained revisions"); run(o.t,1);
    check(status(o.t).step==6 && status(o.t).playing,"fresh epoch consumes commands once");
    p.playback_revision=uint64_t(INT64_MAX); p.position_revision=UINT64_MAX; p.seek_step=3;
    check(coda_transport_publish(o.t,&p)==1,"last representable revisions"); run(o.t,1);
    check(coda_transport_publish(o.t,&p)==1,"exhausted revision configuration"); run(o.t,500);
    check(status(o.t).step==4,"maximum revision is not a recurring command");
    p.playback_revision=uint64_t(INT64_MAX)+1;
    check(coda_transport_publish(o.t,&p)==-1,"unrepresentable playback revision rejected");
}
static void fractionalPauseIntent() {
    Owner o; auto p=plan(400.137);
    const auto start=uint32_t(std::round(5*16*p.samples_per_step))+19;
    const auto end=uint32_t(std::round(6*16*p.samples_per_step));
    check(coda_transport_publish(o.t,&p)==1,"fractional intent initial"); run(o.t,start);
    p.playing=0; ++p.playback_revision;
    check(coda_transport_publish(o.t,&p)==1,"fractional pause"); run(o.t,31);
    check(coda_transport_publish(o.t,&p)==1,"paused ordinary edit snapshot"); run(o.t,17);
    p.playing=1; ++p.playback_revision;
    check(coda_transport_publish(o.t,&p)==1,"fractional resume");
    run(o.t,end-start);
    check(status(o.t).cycle==5,"pause/resume preserves substep and fractional cycle carry");
    run(o.t,1); check(status(o.t).cycle==6,"resumed boundary has original rounded sample spacing");
}
static void pressureAndValidation() {
    Owner o; auto p=plan();
    for(int i=0;i<3;++i) check(coda_transport_publish(o.t,&p)==1,"bounded snapshots");
    check(coda_transport_publish(o.t,&p)==0,"plan full observable"); run(o.t,1);
    check(status(o.t).delivered==3 && status(o.t).acknowledged==2,"superseded queued plans skipped and acknowledged");
    check(coda_transport_publish(o.t,&p)==1,"safe slot reclamation"); run(o.t,1);
    auto invalid=p; invalid.count=CODA_PLAN_EVENTS+1;
    check(coda_transport_publish(o.t,&invalid)==-1,"oversize");
    invalid=p; invalid.events[0].rank=12; check(coda_transport_publish(o.t,&invalid)==-1,"rank");
    invalid=p; invalid.events[0].kind=0; check(coda_transport_publish(o.t,&invalid)==-1,"unmatched off");
    invalid=p; invalid.samples_per_step=NAN; check(coda_transport_publish(o.t,&invalid)==-1,"nonfinite");
    invalid=p; invalid.events[3].step=0; check(coda_transport_publish(o.t,&invalid)==-1,"off after on at tie");
    invalid=p; invalid.events[1].pitch=invalid.events[0].pitch;
    check(coda_transport_publish(o.t,&invalid)==-1,"duplicate pitch ranks");
    CodaControls c{}; check(coda_dsp_default_controls(1,&c),"controls");
    for(int i=0;i<7;++i) {c.muted=i%2; c.preset=i%3; check(coda_transport_controls(o.t,&c)==1,"rapid control edges");}
    check(coda_transport_controls(o.t,&c)==0,"control full observable"); run(o.t,1);
    check(coda_transport_controls(o.t,&c)==1,"control recovery"); run(o.t,1);
    c.warmth=NAN; check(coda_transport_controls(o.t,&c)==-1,"invalid control");
    // Maximum plan density admitted by the actual music canvas: 128 adjacent
    // one-step, 12-note regions. 24 events/sample, far below DSP FIFO capacity.
    p={}; p.playback_revision=2; p.samples_per_step=400; p.length=128; p.playing=1; p.looping=1;
    for(uint16_t step=0;step<=128;++step) {
        if(step) for(uint8_t r=0;r<12;++r) p.events[p.count++]={step,uint16_t(step-1),0,uint8_t(48+r),r,0};
        if(step<128) for(uint8_t r=0;r<12;++r) p.events[p.count++]={step,step,1,uint8_t(48+r),r,0};
    }
    check(p.count==CODA_PLAN_EVENTS && coda_transport_publish(o.t,&p)==1,"maximum dense plan");
    run(o.t,102401);
    check(status(o.t).region>=257,"dense cycle identities");
    check(!coda_transport_prepare(o.t,0),"invalid prepare observable");
    check(coda_transport_publish(o.t,&p)==-1,"failed prepare prevents publication");
    check(coda_transport_prepare(o.t,48000),"failed prepare recoverable");
    p=plan(); p.count=0; check(coda_transport_publish(o.t,&p)==1,"fresh empty loop");
    float silence[1024]; coda_transport_render(o.t,silence,1024);
    for(float x:silence) check(x==0,"empty loop exact silence");
}
static void concurrencyAndReprepare() {
    Owner o; std::atomic<bool> done{false}; std::atomic<uint32_t> accepted{0};
    std::thread producer([&] {
        auto p=plan(); CodaControls c{}; coda_dsp_default_controls(0,&c);
        for(unsigned i=0;i<2000;) {
            p.position_revision=i+1; p.seek_step=uint16_t(i%16); p.events[0].pitch=uint8_t(48+i%12); p.events[3].pitch=p.events[0].pitch;
            const auto result=coda_transport_publish(o.t,&p); check(result>=0,"concurrent valid plan");
            if(result) {++i; ++accepted; c.muted=i%2; c.preset=i%3; coda_transport_controls(o.t,&c);}
            else std::this_thread::yield();
        }
        done=true;
    });
    while(!done.load()) run(o.t,17,17);
    producer.join(); run(o.t,33); check(accepted==2000,"all producer intents admitted with retry");
    for(double sr:{96000.,48000.,8000.,384000.,44100.}) {
        check(coda_transport_prepare(o.t,sr),"quiescent rate prepare");
        auto p=plan(sr*60/137.3/4); check(coda_transport_publish(o.t,&p)==1,"recompiled sample rate"); run(o.t,1024);
        check(status(o.t).clock==1024 && status(o.t).delivered==3,"clean reprepare epoch");
    }
    coda::RenderGate gate; gate.state=0; check(gate.enter(),"gate entered");
    std::atomic<bool> closing{false}, closed{false};
    std::thread closer([&] {closing=true; gate.close(); closed=true;});
    while(!closing.load() || !(gate.state.load()&coda::closedBit)) std::this_thread::yield();
    check(!closed.load() && !gate.enter(),"close excludes new callbacks and waits for in-flight reader");
    gate.leave(); closer.join(); check(closed.load() && !gate.enter(),"close joins reader before destruction");
}
#include "performance_tests.h"
static void multiLayerTransport() {
    Owner o(48000);
    // 1. Mixer controls validation & publication.
    auto m=coda_dsp_default_mixer_controls();
    m.delay_amount=0; m.reverb_amount=0;
    m.layers[CODA_LAYER_CHORDS].preset=CODA_PRESET_CURRENTS;
    m.layers[CODA_LAYER_BASS].preset=CODA_PRESET_WOBBLE;
    m.layers[CODA_LAYER_MELODY].preset=CODA_PRESET_WOBBLE;
    check(coda_transport_mixer_controls(o.t,&m)==1,"valid mixer controls accepted");
    auto badMixer=m; badMixer.layers[CODA_LAYER_BASS].cutoff=NAN;
    check(coda_transport_mixer_controls(o.t,&badMixer)==-1,"NaN mixer layer control rejected");
    badMixer=m; badMixer.layers[CODA_LAYER_MELODY].preset=3;
    check(coda_transport_mixer_controls(o.t,&badMixer)==-1,"invalid mixer preset rejected");
    badMixer=m; badMixer.tempo_bpm=10;
    check(coda_transport_mixer_controls(o.t,&badMixer)==-1,"invalid mixer tempo rejected");

    // 2. Multi-layer unison performance plan (same MIDI pitch 60 on Chords, Bass, Melody)
    //    plus windowed continuation across window boundary and seek/restore.
    auto p=std::make_unique<CodaPerformancePlan>();
    p->playback_revision=1; p->samples_per_step=400; p->length=32; p->window_steps=16;
    p->playing=1; p->looping=1;
    auto fillUnisonWindow=[&](CodaPerformanceCycle &c,uint64_t cyc,uint8_t flags) {
        c={}; c.cycle_index=cyc; c.sample_origin=cyc*16*400; c.sample_count=16*400; c.count=0;
        for(uint8_t L=0;L<CODA_LAYER_COUNT;++L) {
            CodaPerformanceEvent on{};
            on.sample_offset=0; on.owner.instance=10+L; on.harmonic_token=1;
            on.kind=CODA_EVENT_ON; on.pitch=60; on.voice_rank=0; on.layer=L;
            on.base_velocity=0.8f; on.effective_velocity=0.8f;
            on.continuation_id=100+L; on.continuation_flags=flags;
            c.events[c.count++]=on;
        }
        for(uint8_t L=0;L<CODA_LAYER_COUNT;++L) {
            CodaPerformanceEvent off=c.events[L];
            off.kind=CODA_EVENT_OFF; off.sample_offset=int64_t(c.sample_count);
            c.events[c.count++]=off;
        }
    };
    fillUnisonWindow(p->initial_cycle,0,2); // sustain into next window
    // Out-of-range layer must be rejected.
    auto badLayer=std::make_unique<CodaPerformancePlan>(*p);
    badLayer->initial_cycle.events[0].layer=CODA_LAYER_COUNT;
    uint64_t g=0;
    check(coda_transport_publish_performance(o.t,badLayer.get(),&g)==-1,"out-of-range layer rejected");
    // Same-layer duplicate pitch must still be rejected.
    auto dupSameLayer=std::make_unique<CodaPerformancePlan>(*p);
    dupSameLayer->initial_cycle.events[1].layer=CODA_LAYER_CHORDS;
    dupSameLayer->initial_cycle.events[4].layer=CODA_LAYER_CHORDS;
    check(coda_transport_publish_performance(o.t,dupSameLayer.get(),&g)==-1,"same-layer duplicate pitch rejected");

    // Cross-layer unison pitch 60 on all 3 layers is accepted.
    check(coda_transport_publish_performance(o.t,p.get(),&g)==1,"3-layer unison performance plan admitted");
    auto w1=std::make_unique<CodaPerformanceCycle>();
    fillUnisonWindow(*w1,1,1); // carry from previous window, end at boundary
    check(coda_transport_enqueue_performance_cycle(o.t,g,w1.get())==1,"window 1 unison carry queued");
    run(o.t,1000);
    check(status(o.t).delivered==3,"all 3 unison layers delivered");

    // Mute Chords & Bass; Melody unison must remain audible.
    m.layers[CODA_LAYER_CHORDS].muted=1;
    m.layers[CODA_LAYER_BASS].muted=1;
    m.layers[CODA_LAYER_MELODY].muted=0;
    check(coda_transport_mixer_controls(o.t,&m)==1,"mute chords+bass via transport");
    run(o.t,1200);
    float buf[1024]{};
    count_allocations=true;
    coda_transport_render(o.t,buf,1024);
    count_allocations=false;
    check(allocation_count==0 && deallocation_count==0,"3-layer mixer render zero allocations");
    double melEnergy=0;
    for(float x:buf) melEnergy+=double(x)*x;
    check(melEnergy>1e-5,"melody unison audible while chords+bass muted");

    // Advance across window boundary (6400 total samples in window 0); continuation keeps notes held without retriggering!
    const auto deliveredBeforeBoundary=status(o.t).delivered;
    run(o.t,uint32_t(6400-status(o.t).clock+10));
    check(performanceStatus(o.t).cycle==1 && status(o.t).delivered==deliveredBeforeBoundary,
          "3-layer unison continuation carries across window boundary without retrigger");

    // 3. Per-layer audition (Bass & Melody) with validation and zero allocations.
    const uint8_t bassPitch[]={40};
    const uint8_t melPitch[]={72};
    check(coda_transport_audition_layer(o.t,CODA_LAYER_COUNT,bassPitch,1,512)==-1,"invalid audition layer rejected");
    // Unmute Bass only and audition Bass layer.
    m.layers[CODA_LAYER_CHORDS].muted=1;
    m.layers[CODA_LAYER_BASS].muted=0;
    m.layers[CODA_LAYER_MELODY].muted=1;
    check(coda_transport_mixer_controls(o.t,&m)==1,"solo bass for audition");
    // Pause transport so only audition produces sound.
    p->playing=0; ++p->playback_revision;
    fillUnisonWindow(p->initial_cycle,1,0);
    check(coda_transport_publish_performance(o.t,p.get(),&g)==1,"pause before layer audition");
    run(o.t,1200);
    check(coda_transport_audition_layer(o.t,CODA_LAYER_BASS,bassPitch,1,1024)==1,"bass layer audition admitted");
    count_allocations=true;
    coda_transport_render(o.t,buf,1024);
    count_allocations=false;
    check(allocation_count==0 && deallocation_count==0,"bass audition render zero allocations");
    double bassAuditionEnergy=0;
    for(float x:buf) bassAuditionEnergy+=double(x)*x;
    check(bassAuditionEnergy>1e-5,"bass layer audition produces audible output");
    // Let audition expire and verify release.
    const auto beforeExpiry=status(o.t).delivered;
    run(o.t,10);
    check(status(o.t).delivered==beforeExpiry+1,"bass audition expiry releases cleanly");

    // Audition Melody layer while Bass is soloed (Melody muted) -> should be silent!
    check(coda_transport_audition_layer(o.t,CODA_LAYER_MELODY,melPitch,1,512)==1,"melody audition while muted admitted");
    run(o.t,2000);
    // Cancel audition explicitly with count 0.
    check(coda_transport_audition_layer(o.t,CODA_LAYER_MELODY,nullptr,0,0)==1,"cancel layer audition");
    run(o.t,10);
    check(status(o.t).failures==0,"zero transport failures across multi-layer tests");
}
int main() {
    std::setbuf(stderr,nullptr);
#if defined(__APPLE__)
    pthread_mutex_t calibrationMutex;check(pthread_mutex_init(&calibrationMutex,nullptr)==0,"lock calibration init");
    os_unfair_lock unfair=OS_UNFAIR_LOCK_INIT;
    coda_test_lock_begin();pthread_mutex_lock(&calibrationMutex);pthread_mutex_unlock(&calibrationMutex);coda_test_lock_end();
    const auto mutexCount=coda_test_lock_count();
    coda_test_lock_diagnostics("mutex",mutexCount,1,
        reinterpret_cast<const void *>(&pthread_mutex_lock),
        reinterpret_cast<const void *>(&os_unfair_lock_lock));
    coda_test_lock_begin();os_unfair_lock_lock(&unfair);os_unfair_lock_unlock(&unfair);coda_test_lock_end();
    const auto unfairCount=coda_test_lock_count();
    coda_test_lock_diagnostics("unfair",unfairCount,1,
        reinterpret_cast<const void *>(&pthread_mutex_lock),
        reinterpret_cast<const void *>(&os_unfair_lock_lock));
    coda_test_lock_begin();pthread_mutex_lock(&calibrationMutex);pthread_mutex_unlock(&calibrationMutex);
    os_unfair_lock_lock(&unfair);os_unfair_lock_unlock(&unfair);coda_test_lock_end();
    const auto combinedCount=coda_test_lock_count();
    coda_test_lock_diagnostics("combined",combinedCount,2,
        reinterpret_cast<const void *>(&pthread_mutex_lock),
        reinterpret_cast<const void *>(&os_unfair_lock_lock));
    check(mutexCount==1,"real mutex hook exact one");
    check(unfairCount==1,"real unfair hook exact one");
    check(combinedCount==2,"both real hooks exact two");
    pthread_mutex_destroy(&calibrationMutex);
#endif

    // A stuck production queue/gate fails deterministically instead of hanging CI.
    std::mutex mutex; std::condition_variable cv; bool finished=false;
    std::thread watchdog([&] {std::unique_lock lock(mutex);
        if(!cv.wait_for(lock,std::chrono::seconds(110),[&]{return finished;})) {
            std::fprintf(stderr,"FAIL: transport test timeout\n"); std::_Exit(2);
        }});
    // Calibrate both hooks outside the render count, preserving a zero baseline.
    void *(*volatile allocProbe)(std::size_t)=::operator new;
    void (*volatile freeProbe)(void *)=::operator delete;
    count_allocations=true; auto *probe=allocProbe(16); freeProbe(probe); count_allocations=false;
    check(allocation_count && deallocation_count,"allocation hooks calibrated"); allocation_count=deallocation_count=0;
    performanceModePhase();performanceBoundaryRejection();performanceConcurrentReconfiguration();
    performanceTransport(); performanceTransitions(); performanceAdmission(); performanceRetriggerAndAudio(); performanceConcurrentRefill(); performanceAbsoluteOrigins(); performanceNonzeroSeekAndConfiguration();
    multiLayerTransport();
    timing(); transitions(); nonloopBoundaries(); auditionAtEnd(); durableIntent(); fractionalPauseIntent(); pressureAndValidation(); concurrencyAndReprepare();
    {std::lock_guard lock(mutex); finished=true;} cv.notify_one(); watchdog.join();
    std::puts("PASS: production transport timing, transitions, publication, controls, concurrency, gate, reprepare; zero render new/delete");
}
