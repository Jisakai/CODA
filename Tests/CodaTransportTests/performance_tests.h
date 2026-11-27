#pragma once
#include <limits>
#include <memory>
// Included by the existing native executable; every render uses its calibrated
// allocation/deallocation hooks and existing finite-output/failure assertions.
static void fillPerformanceCycle(CodaPerformanceCycle &v,uint64_t c,double rate=400.137,bool up=false) {
    v.cycle_index=c;v.count=0;
    v.sample_origin=uint64_t(std::round(double(c*16)*rate));
    v.sample_count=uint64_t(std::round(double((c+1)*16)*rate))-v.sample_origin;
    for(unsigned i=0;i<12;++i) {
        const auto rank=up?11-i:i;
        CodaPerformanceEvent e{};e.sample_offset=7+i*3+c%3;e.owner.instance=rank+1;
        e.harmonic_token=71;e.kind=1;e.pitch=uint8_t(48+rank);e.voice_rank=uint8_t(rank);
        e.base_velocity=.7f;e.effective_velocity=.31f;e.detune_cents=3;e.filter_delta=-.02f;
        e.attack_mode=CODA_ATTACK_CHUCK;v.events[v.count++]=e;
    }
    for(unsigned i=0;i<12;++i) {auto e=v.events[i];e.kind=0;e.sample_offset=int64_t(v.sample_count);v.events[v.count++]=e;}
}
static std::unique_ptr<CodaPerformanceCycle> performanceCycle(uint64_t c=0,double rate=400.137,bool up=false) {
    auto v=std::make_unique<CodaPerformanceCycle>();fillPerformanceCycle(*v,c,rate,up);return v;
}
static std::unique_ptr<CodaPerformancePlan> performancePlan(bool up=false) {
    auto p=std::make_unique<CodaPerformancePlan>();p->playback_revision=1;p->samples_per_step=400.137;
    p->length=16;p->playing=1;p->looping=1;fillPerformanceCycle(p->initial_cycle,0,p->samples_per_step,up);return p;
}
static CodaPerformanceStatus performanceStatus(CodaTransport *t) {
    CodaPerformanceStatus s{};coda_transport_performance_status(t,&s);return s;
}
[[gnu::noinline]] static void performanceTransport() {
    for(bool up:{false,true}) {
        Owner o;auto pStorage=performancePlan(up);auto &p=*pStorage;uint64_t g=0;
        check(coda_transport_publish_performance(o.t,&p,&g)==1 && g,"performance publish assigns generation");
        run(o.t,7);check(status(o.t).delivered==0,"spread first sample exact");
        for(unsigned i=0;i<12;++i) {
            run(o.t,i?3:1);check(status(o.t).delivered==i+1,"spread each sample exact");
            CodaPerformanceVoiceDiagnostic d[12]{};coda_transport_inspect_performance(o.t,d);
            const auto rank=up?11-i:i;bool found=false;
            for(const auto &v:d) if(v.active && v.performance && v.owner.instance==rank+1) {
                found=true;check(v.owner.prepare_epoch==1 && v.owner.plan_generation==g && v.owner.cycle==0 && v.owner.activation,
                    "native exact ownership qualifications");
                check(v.pitch==48+rank && v.rank==rank && v.harmonic_token==71 && v.attack_mode==1 &&
                    v.base_velocity==.7f && v.effective_velocity==.31f && v.detune_cents==3 && v.filter_delta==-.02f,
                    "all actual DSP payload fields and independent rank");
            }
            check(found,"newly delivered instance found in actual DSP");
        }
        auto cStorage=performanceCycle(1,p.samples_per_step,!up);auto &c=*cStorage;
        check(coda_transport_enqueue_performance_cycle(o.t,g,&c)==1,"different cycle refill");
        const auto boundary=p.initial_cycle.sample_count;run(o.t,uint32_t(boundary-status(o.t).clock));
        run(o.t,1);check(status(o.t).delivered==24 && performanceStatus(o.t).cycle==1,"wrap exact terminal releases");
        run(o.t,7);check(status(o.t).delivered==24,"cycle one distinct supplied offset");
        run(o.t,1);check(status(o.t).delivered==25,"cycle one event not replay of cycle zero");
        run(o.t,uint32_t(c.sample_count-8));run(o.t,1);
        auto s=performanceStatus(o.t);check(s.underrun && s.underruns==1 && s.next_requested_cycle==2,"missing cycle pauses with observable underrun");
        const auto delivered=status(o.t).delivered;run(o.t,87);
        check(status(o.t).delivered==delivered && performanceStatus(o.t).underruns==1,"underrun releases once");
        fillPerformanceCycle(c,2,p.samples_per_step,up);
        check(coda_transport_enqueue_performance_cycle(o.t,g,&c)==1,"late exact cycle accepted");
        run(o.t,10);check(!performanceStatus(o.t).underrun && performanceStatus(o.t).cycle==2 && status(o.t).delivered==delivered+1,"late refill resumes sample spacing");
        check(coda_transport_prepare(o.t,8000),"performance repeated prepare");
        check(performanceStatus(o.t).prepare_epoch==2,"prepare epoch never resets");
        auto old=g;check(coda_transport_publish_performance(o.t,&p,&g)==1 && g>old,"generation survives prepare");
    }
}
[[gnu::noinline]] static void performanceTransitions() {
    Owner o;auto pStorage=performancePlan();auto &p=*pStorage;uint64_t g=0;
    check(coda_transport_publish_performance(o.t,&p,&g)==1,"transition initial");run(o.t,100);
    CodaPerformanceVoiceDiagnostic before[12]{};coda_transport_inspect_performance(o.t,before);
    p.playing=0;++p.playback_revision;
    check(coda_transport_publish_performance(o.t,&p,&g)==1,"performance pause");run(o.t,50);
    check(!status(o.t).playing && status(o.t).delivered==24,"pause exact releases");
    p.playing=1;++p.playback_revision;
    check(coda_transport_publish_performance(o.t,&p,&g)==1,"performance resume");run(o.t,1);
    check(status(o.t).delivered==36,"resume reconstructs held flat events");
    CodaPerformanceVoiceDiagnostic after[12]{};coda_transport_inspect_performance(o.t,after);
    for(const auto &v:after) if(v.active && v.performance && !v.releasing)
        check(v.owner.plan_generation==g && v.owner.activation>before[0].owner.activation,"restore fresh incarnation");
    const uint8_t pitches[]={72,76,79};check(coda_transport_audition(o.t,pitches,3,4)==1,"performance audition");
    run(o.t,1);check(status(o.t).delivered==51,"audition retires twelve, adds three");
    run(o.t,4);check(status(o.t).delivered==66,"expiry releases audition and restores twelve");
    check(coda_transport_audition(o.t,pitches,3,100)==1,"second audition");run(o.t,1);
    check(coda_transport_audition(o.t,nullptr,0,0)==1,"cancel audition");run(o.t,1);
    check(status(o.t).delivered==96,"cancel exact release restore");
    p.seek_step=1;++p.position_revision;
    check(coda_transport_publish_performance(o.t,&p,&g)==1,"seek flat reconstruction");run(o.t,1);
    check(status(o.t).step==1 && status(o.t).delivered==120,"seek retires and restores exact current notes");
    const auto old=g;auto legacy=plan();check(coda_transport_publish(o.t,&legacy)==1,"performance to legacy shared ordering");run(o.t,1);
    auto cStorage=performanceCycle(1);auto &c=*cStorage;check(coda_transport_enqueue_performance_cycle(o.t,old,&c)==-1,"legacy switch rejects old producer generation");
    check(performanceStatus(o.t).generation==0,"legacy mode visible");
}
[[gnu::noinline]] static void performanceRetriggerAndAudio() {
    Owner o;auto pStorage=performancePlan();auto &p=*pStorage;p.looping=0;p.initial_cycle.count=4;
    auto e=p.initial_cycle.events[0];e.sample_offset=0;e.attack_mode=0;e.owner.instance=41;
    p.initial_cycle.events[0]=e;e.kind=0;e.sample_offset=21;p.initial_cycle.events[1]=e;
    e.kind=1;e.owner.instance=42;p.initial_cycle.events[2]=e;
    e.kind=0;e.sample_offset=50;p.initial_cycle.events[3]=e;uint64_t g=0;
    check(coda_transport_publish_performance(o.t,&p,&g)==1,"same pitch exact retrigger admitted");
    run(o.t,22);check(status(o.t).delivered==3,"same sample off before replacement on");
    CodaPerformanceVoiceDiagnostic d[12]{};coda_transport_inspect_performance(o.t,d);
    bool replacement=false;for(const auto &v:d) if(v.active && !v.releasing && v.owner.instance==42) replacement=true;
    check(replacement,"replacement exact owner audible");run(o.t,29);
    coda_transport_inspect_performance(o.t,d);
    for(const auto &v:d) if(v.active && v.owner.instance==42) check(v.releasing,"exact scheduled off releases replacement");
    auto staleStorage=std::make_unique<CodaPerformancePlan>(p);auto &stale=*staleStorage;stale.initial_cycle.events[3].owner.instance=41;
    check(coda_transport_publish_performance(o.t,&stale,&g)==-1,"stale old off cannot release replacement");
    // Actual production render audio responds to effective velocity, retaining base.
    Owner a,b;auto paStorage=performancePlan();auto &pa=*paStorage;auto pbStorage=std::make_unique<CodaPerformancePlan>(pa);auto &pb=*pbStorage;
    for(uint32_t i=0;i<pb.initial_cycle.count;++i) pb.initial_cycle.events[i].effective_velocity=.8f;
    uint64_t ga=0,gb=0;check(coda_transport_publish_performance(a.t,&pa,&ga)==1 && coda_transport_publish_performance(b.t,&pb,&gb)==1,"audio payload plans");
    float aa[256]{},bb[256]{};count_allocations=true;
#if defined(__APPLE__)
    coda_test_lock_begin();
#endif
    coda_transport_render(a.t,aa,256);coda_transport_render(b.t,bb,256);count_allocations=false;
#if defined(__APPLE__)
    coda_test_lock_end();check(coda_test_lock_count()==0,"direct audio comparison zero render locks");
#endif
    double ea=0,eb=0;for(unsigned i=0;i<256;++i) {ea+=double(aa[i])*aa[i];eb+=double(bb[i])*bb[i];}
    check(ea>0 && eb>ea && allocation_count==0 && deallocation_count==0,"effective velocity changes actual transport audio without render heap work");
}
[[gnu::noinline]] static void performanceAdmission() {
    Owner o;auto pStorage=performancePlan();auto &p=*pStorage;uint64_t g=999;
    auto badStorage=std::make_unique<CodaPerformancePlan>(p);auto &bad=*badStorage;bad.initial_cycle.events[0].owner.activation=1;
    check(coda_transport_publish_performance(o.t,&bad,&g)==-1 && g==999,"caller runtime identity rejected atomically");
    bad=p;bad.initial_cycle.events[0].base_velocity=NAN;
    check(coda_transport_publish_performance(o.t,&bad,&g)==-1 && g==999,"nan invalid output untouched");
    bad=p;bad.initial_cycle.sample_count++;
    check(coda_transport_publish_performance(o.t,&bad,&g)==-1,"absolute boundary mismatch rejected");
    bad=p;bad.initial_cycle.events[12].owner.instance=900;
    check(coda_transport_publish_performance(o.t,&bad,&g)==-1,"stale off invalid before publish");
    bad=p;bad.initial_cycle.events[0].base_velocity=0;
    check(coda_transport_publish_performance(o.t,&bad,&g)==-1,"zero velocity rejected");
    bad=p;bad.initial_cycle.events[0].filter_delta=.0201f;
    check(coda_transport_publish_performance(o.t,&bad,&g)==-1,"modulation out of range rejected");
    bad=p;bad.initial_cycle.events[0].sample_offset=-1;
    check(coda_transport_publish_performance(o.t,&bad,&g)==-1,"negative timing rejected");
    bad=p;bad.initial_cycle.events[0].owner.instance=0;
    check(coda_transport_publish_performance(o.t,&bad,&g)==-1,"zero local instance rejected");
    bad=p;bad.initial_cycle.events[12]=bad.initial_cycle.events[0];
    bad.initial_cycle.events[12].owner.instance=99;bad.initial_cycle.events[12].pitch=80;bad.initial_cycle.events[12].sample_offset=41;
    check(coda_transport_publish_performance(o.t,&bad,&g)==-1,"thirteen concurrently held rejected");
    bad=p;bad.initial_cycle.count=3073;check(coda_transport_publish_performance(o.t,&bad,&g)==-1,"3073 rejected");
    bad=p;bad.initial_cycle.cycle_index=UINT64_MAX;check(coda_transport_publish_performance(o.t,&bad,&g)==-1,"cycle overflow rejected");
    check(coda_transport_publish_performance(nullptr,&p,&g)==-1 && coda_transport_publish_performance(o.t,nullptr,&g)==-1 &&
        coda_transport_publish_performance(o.t,&p,nullptr)==-1,"null contracts");
    for(int i=0;i<3;++i) check(coda_transport_publish_performance(o.t,&p,&g)==1,"performance config queue bound");
    const auto saved=g;check(coda_transport_publish_performance(o.t,&p,&g)==0 && g==saved,"full output unchanged");
    auto cStorage=performanceCycle(1);auto &c=*cStorage;check(coda_transport_enqueue_performance_cycle(o.t,g-1,&c)==1,"pending retained generation has independent refill lane");
    check(coda_transport_enqueue_performance_cycle(o.t,g,&c)==1,"cycle one queued");
    check(coda_transport_enqueue_performance_cycle(o.t,g,&c)==-1,"duplicate cycle rejected");
    for(uint64_t i=2;i<=3;++i) {fillPerformanceCycle(c,i);check(coda_transport_enqueue_performance_cycle(o.t,g,&c)==1,"small cycle queue capacity");}
    fillPerformanceCycle(c,4);check(coda_transport_enqueue_performance_cycle(o.t,g,&c)==0,"cycle queue full atomic");
    run(o.t,uint32_t(p.initial_cycle.sample_count+1));
    check(coda_transport_enqueue_performance_cycle(o.t,g,&c)==0,"active slot retained until next consumer ack");
    run(o.t,uint32_t(performanceCycle(1)->sample_count));
    check(coda_transport_enqueue_performance_cycle(o.t,g,&c)==1,"same full cycle retry succeeds without admission mutation");
    // Tiny positive Float is valid (Double conversion policy is session-owned).
    auto tinyStorage=std::make_unique<CodaPerformancePlan>(p);auto &tiny=*tinyStorage;++tiny.position_revision;for(uint32_t i=0;i<tiny.initial_cycle.count;++i) tiny.initial_cycle.events[i].base_velocity=tiny.initial_cycle.events[i].effective_velocity=std::numeric_limits<float>::min();
    check(coda_transport_publish_performance(o.t,&tiny,&g)==1,"tiny positive velocity admitted");run(o.t,1);
    // Dense actual 3072-event cycle, twelve held notes, many repeated ranks.
    check(coda_transport_prepare(o.t,8000),"dense prepare");p=*performancePlan();p.initial_cycle.count=0;
    for(unsigned group=0;group<128;++group) {
        for(unsigned r=0;r<12;++r) {CodaPerformanceEvent e{};e.owner.instance=group*12+r+1;e.harmonic_token=1;
            e.sample_offset=group*40;e.kind=1;e.pitch=uint8_t(48+r);e.voice_rank=uint8_t(r);e.base_velocity=e.effective_velocity=.5f;
            p.initial_cycle.events[p.initial_cycle.count++]=e;}
        for(unsigned r=0;r<12;++r) {auto e=p.initial_cycle.events[p.initial_cycle.count-12];e.kind=0;e.sample_offset=(group+1)*40;
            p.initial_cycle.events[p.initial_cycle.count++]=e;}
    }
    check(p.initial_cycle.count==3072 && coda_transport_publish_performance(o.t,&p,&g)==1,"3072 exact native admission");
    run(o.t,5121);check(status(o.t).delivered==3072,"3072 actual delivered exact lifecycle");
}

[[gnu::noinline]] static void performanceConcurrentRefill() {
    Owner o;auto pStorage=performancePlan();auto &p=*pStorage;p.initial_cycle.count=0;uint64_t g=0;
    check(coda_transport_publish_performance(o.t,&p,&g)==1,"concurrent performance initial");
    std::atomic<bool> done{false};
    std::thread producer([&] {
        auto c=std::make_unique<CodaPerformanceCycle>();
        for(uint64_t i=1;i<=16;) {
            fillPerformanceCycle(*c,i,400.137);
            const int result=coda_transport_enqueue_performance_cycle(o.t,g,c.get());
            check(result>=0,"concurrent refill valid");
            if(result) ++i;else std::this_thread::yield();
        }
        done=true;
    });
    while(!done.load()) run(o.t,257);
    producer.join();
    while(performanceStatus(o.t).cycle<16) run(o.t,257);
    run(o.t,uint32_t(performanceCycle(16)->sample_count+1));
    check(status(o.t).delivered==16*24 && performanceStatus(o.t).generation==g,
        "concurrent immutable cycle payload survives slot reclamation with exact deliveries");
}

[[gnu::noinline]] static void performanceAbsoluteOrigins() {
    for(double rate:{400.02,400.04,44100.*60./137.3/4.,96000.*60./123.7/4.}) {
        Owner o;auto pStorage=performancePlan();auto &p=*pStorage;p.samples_per_step=rate;
        fillPerformanceCycle(p.initial_cycle,12345,rate);uint64_t g=0;
        check(coda_transport_publish_performance(o.t,&p,&g)==1,"awkward tempo absolute nonzero initial cycle");
        auto cStorage=performanceCycle(12346,rate);auto &c=*cStorage;
        check(p.initial_cycle.sample_origin+p.initial_cycle.sample_count==c.sample_origin &&
            coda_transport_enqueue_performance_cycle(o.t,g,&c)==1,"absolute rounding shared consecutive boundary");
        run(o.t,8);check(status(o.t).delivered==1 && performanceStatus(o.t).cycle==12345,"large absolute origin maps to exact current audio offset");
        CodaPerformanceVoiceDiagnostic d[12]{};coda_transport_inspect_performance(o.t,d);
        bool found=false;for(const auto &v:d) if(v.active && v.performance) {found=true;check(v.owner.cycle==12345,"native owner retains nonzero compiled cycle");}
        check(found,"nonzero cycle actual voice");
    }
}

[[gnu::noinline]] static void performanceNonzeroSeekAndConfiguration() {
    Owner o;auto pStorage=performancePlan();auto &p=*pStorage;p.samples_per_step=400.02;
    fillPerformanceCycle(p.initial_cycle,1,p.samples_per_step);p.position_revision=1;p.seek_step=9;
    // round(25*400.02)-round(16*400.02)=3601, versus local round(9*400.02)=3600.
    const auto local=uint64_t(std::round(25*p.samples_per_step))-p.initial_cycle.sample_origin;
    check(local==3601,"regression fixture exposes one sample absolute rounding");
    p.initial_cycle.count=2;auto e=p.initial_cycle.events[0];e.sample_offset=int64_t(local+2);
    p.initial_cycle.events[0]=e;e.kind=0;e.sample_offset=int64_t(local+4);p.initial_cycle.events[1]=e;
    uint64_t g=0;check(coda_transport_publish_performance(o.t,&p,&g)==1,"nonzero absolute seek accepted");
    run(o.t,2);check(status(o.t).delivered==0,"seek leaves exact two sample gap");
    run(o.t,1);check(status(o.t).delivered==1,"nonzero seek onset exact absolute rounding");
    p.playing=0;++p.playback_revision;
    check(coda_transport_publish_performance(o.t,&p,&g)==1,"pause later cycle");run(o.t,1);
    auto wrongStorage=std::make_unique<CodaPerformancePlan>(p);auto &wrong=*wrongStorage;fillPerformanceCycle(wrong.initial_cycle,0,p.samples_per_step);const auto saved=g;
    check(coda_transport_publish_performance(o.t,&wrong,&g)==1 && g!=saved,"wrong-cycle update queued asynchronously");
    run(o.t,1);check(performanceStatus(o.t).rejected_generation==g && performanceStatus(o.t).generation==saved,
        "consumer rejects wrong cycle without changing active generation");
    p.samples_per_step=401.137;fillPerformanceCycle(p.initial_cycle,1,p.samples_per_step);p.initial_cycle.count=0;
    check(coda_transport_publish_performance(o.t,&p,&g)==1,"paused later cycle tempo update");run(o.t,1);
    check(performanceStatus(o.t).cycle==1 && status(o.t).step==9 && !status(o.t).playing,"tempo preserves paused later cycle position");
    p.playing=1;++p.playback_revision;
    check(coda_transport_publish_performance(o.t,&p,&g)==1,"restart later cycle");run(o.t,1);
    check(performanceStatus(o.t).cycle==1 && status(o.t).step==9 && status(o.t).playing,"resume retains later cycle and position");
    ++p.position_revision;p.seek_step=127;
    check(coda_transport_publish_performance(o.t,&p,&g)==1,"nonzero cycle endpoint seek accepted");run(o.t,1);
    check(performanceStatus(o.t).cycle==1 && status(o.t).step==15,"endpoint seek clamps within selected cycle");
}

// Queue at the exact end before the consumer advances; no observer admits it.
[[gnu::noinline]] static void performanceBoundaryRejection() {
    Owner o;auto pStorage=performancePlan();auto &p=*pStorage;uint64_t active=0,pending=0;
    check(coda_transport_publish_performance(o.t,&p,&active)==1,"race initial queued");
    auto nextStorage=performanceCycle(1);auto &next=*nextStorage;check(coda_transport_enqueue_performance_cycle(o.t,active,&next)==1,"active refill before pending");
    run(o.t,uint32_t(p.initial_cycle.sample_count));
    auto replacementStorage=std::make_unique<CodaPerformancePlan>(p);auto &replacement=*replacementStorage;replacement.playing=0;++replacement.playback_revision;
    replacement.samples_per_step=401.137;fillPerformanceCycle(replacement.initial_cycle,0,replacement.samples_per_step);
    check(coda_transport_publish_performance(o.t,&replacement,&pending)==1,"boundary stale snapshot queues");
    auto pendingRefill=std::make_unique<CodaPerformanceCycle>();fillPerformanceCycle(*pendingRefill,2,400.137);
    check(coda_transport_enqueue_performance_cycle(o.t,active,pendingRefill.get())==1,"prior ACTIVE refill while replacement pending");
    run(o.t,50);auto s=performanceStatus(o.t);
    check(s.rejected_generation==pending && s.required_cycle==1 && s.generation==active && s.cycle==1,
        "consumer boundary rejection never replays cycle zero");
    check(status(o.t).playing && status(o.t).playback_revision==1 && status(o.t).delivered==36,
        "rejected pause tempo preserves revisions and current notes");
    auto cStorage=performanceCycle(3);auto &c=*cStorage;check(coda_transport_enqueue_performance_cycle(o.t,active,&c)==1,"old active refill after rejection");
    check(coda_transport_enqueue_performance_cycle(o.t,pending,&c)==-1,"rejected lane retired safely");
    fillPerformanceCycle(replacement.initial_cycle,1,replacement.samples_per_step);
    check(coda_transport_publish_performance(o.t,&replacement,&pending)==1,"same cumulative pause tempo retry");run(o.t,1);
    check(performanceStatus(o.t).applied_generation==pending && !status(o.t).playing && status(o.t).playback_revision==2,
        "retry consumes cumulative pause only on application");
    replacement.playing=1;++replacement.playback_revision;++replacement.position_revision;replacement.seek_step=9;
    fillPerformanceCycle(replacement.initial_cycle,3,replacement.samples_per_step);
    check(coda_transport_publish_performance(o.t,&replacement,&pending)==1,"explicit cumulative seek resume");run(o.t,1);
    check(status(o.t).playing && status(o.t).step==9 && performanceStatus(o.t).cycle==3,"seek explicitly authorizes cycle selection");
    check(coda_transport_enqueue_performance_cycle(o.t,active,&c)==-1,"old active retired after apply and slot reuse");
}
[[gnu::noinline]] static void performanceConcurrentReconfiguration() {
    Owner o;auto pStorage=performancePlan();auto &p=*pStorage;uint64_t initial=0;
    check(coda_transport_publish_performance(o.t,&p,&initial)==1,"threaded reconfig initial");run(o.t,100);
    std::atomic<bool> done{false};
    std::thread producer([&] {
        uint64_t g=initial, nextRefill=2;
        auto refill=std::make_unique<CodaPerformanceCycle>();
        auto candidate=std::make_unique<CodaPerformancePlan>();
        fillPerformanceCycle(*refill,1,400.137);
        check(coda_transport_enqueue_performance_cycle(o.t,g,refill.get())==1,"threaded producer refills real active notes before reconfiguration");
        for(unsigned i=0;i<24;++i) {
            auto state=performanceStatus(o.t);
            candidate->playback_revision=1;candidate->samples_per_step=400.137;candidate->length=16;
            candidate->playing=1;candidate->looping=1;
            fillPerformanceCycle(candidate->initial_cycle,state.cycle,candidate->samples_per_step,i%2);
            uint64_t queued=0;
            while(!coda_transport_publish_performance(o.t,candidate.get(),&queued)) std::this_thread::yield();
            fillPerformanceCycle(*refill,nextRefill,400.137);
            // Real notes for the prior active lane even with replacement pending.
            const int result=coda_transport_enqueue_performance_cycle(o.t,g,refill.get());
            if(result==-1) {
                const auto ack=performanceStatus(o.t);
                check(ack.applied_generation==queued || ack.rejected_generation==queued,
                    "retirement acquire observes replacement application or rejection ACK");
            } else {
                check(result==0 || result==1,"retained lane refill backpressure/success");
                if(result==1) ++nextRefill;
            }
            do {state=performanceStatus(o.t);std::this_thread::yield();}
            while(state.applied_generation!=queued && state.rejected_generation!=queued);
            if(state.applied_generation==queued) {
                g=queued;nextRefill=candidate->initial_cycle.cycle_index+1;
            }
        }
        done=true;
    });
    while(!done.load()) run(o.t,17);producer.join();
    check(status(o.t).delivered>12 && status(o.t).failures==0,"real notes survive concurrent configuration and lane retirement");
}

[[gnu::noinline]] static void performanceModeAbsoluteRounding() {
    for(double rate:{400.137,400.021}) {
        Owner o;auto storage=performancePlan();auto &p=*storage;
        constexpr uint64_t cycle=12345;
        fillPerformanceCycle(p.initial_cycle,cycle,p.samples_per_step);p.initial_cycle.count=0;
        uint64_t local=1;
        if(rate!=p.samples_per_step) {
            for(;local<1500;++local) {
                const double step=double(local)/p.samples_per_step;
                if(uint64_t(std::round((double(cycle*16)+step)*rate))!=
                   uint64_t(std::round(double(cycle*16)*rate))+uint64_t(std::round(step*rate))) break;
            }
            check(local<1500,"fractional mode regression exercises split-round discrepancy");
        }
        uint64_t g=0;check(coda_transport_publish_performance(o.t,&p,&g)==1,"fractional mode initial");
        run(o.t,uint32_t(local));
        auto legacy=plan(rate);legacy.count=2;
        legacy.events[0]={4,0,1,60,0,0};legacy.events[1]={16,0,0,60,0,0};
        const auto position=rate==p.samples_per_step?p.initial_cycle.sample_origin+local:
            uint64_t(std::round((double(cycle*16)+double(local)/p.samples_per_step)*rate));
        const auto onset=uint64_t(std::round(double(cycle*16+4)*rate));
        check(onset>position,"fractional mode onset remains ahead of converted position");
        check(coda_transport_publish(o.t,&legacy)==1,"fractional performance to legacy queues");
        run(o.t,uint32_t(onset-position));
        check(status(o.t).cycle==cycle && status(o.t).delivered==0,"mode transition has no one-sample early phase drift");
        run(o.t,1);check(status(o.t).delivered==1,"mode transition onset exact after unchanged timing or rate change");
    }
}
[[gnu::noinline]] static void performanceModePhase() {
    performanceModeAbsoluteRounding();
    for(bool changeRange:{false,true}) {
        Owner o;auto legacy=plan(400);uint64_t g=0;
        check(coda_transport_publish(o.t,&legacy)==1,"mode legacy initial");
        run(o.t,2*6400+1000);const auto delivered=status(o.t).delivered;
        auto storage=std::make_unique<CodaPerformancePlan>();auto &p=*storage;
        p.playback_revision=1;p.samples_per_step=600;p.length=changeRange?32:16;
        p.playing=p.looping=1;
        auto &c=p.initial_cycle;c.cycle_index=2;c.sample_origin=2*p.length*600;
        c.sample_count=p.length*600;c.count=2;
        auto &on=c.events[0];on.owner.instance=1;on.harmonic_token=1;on.kind=1;
        on.pitch=60;on.base_velocity=on.effective_velocity=.7f;
        c.events[1]=on;c.events[1].kind=0;c.events[1].sample_offset=c.sample_count;
        check(coda_transport_publish_performance(o.t,&p,&g)==1,"mode apply pattern queues");run(o.t,1);
        check(performanceStatus(o.t).applied_generation==g && status(o.t).cycle==2 && status(o.t).step==2,
            "legacy to pattern preserves nonzero cycle phase across tempo and range");
        check(status(o.t).delivered==delivered+4,"pattern restores real held note without beginning replay");
        legacy.samples_per_step=500;legacy.length=changeRange?16:32;legacy.events[3].step=legacy.length;
        legacy.events[4].step=legacy.length;legacy.events[5].step=legacy.length;
        uint64_t legacyGeneration=0;
        check(coda_transport_publish_generation(o.t,&legacy,&legacyGeneration)==1 && legacyGeneration>g,
            "mode remove pattern queues explicit generation");
        check(performanceStatus(o.t).applied_generation==g,"legacy queue success does not acknowledge retirement");
        run(o.t,1);
        check(performanceStatus(o.t).applied_generation==legacyGeneration,"legacy explicit applied acknowledgement");
        check(status(o.t).cycle==2 && status(o.t).step==2 && status(o.t).delivered==delivered+8,
            "pattern to legacy preserves phase and restores real chord across tempo and range");
    }
    Owner o;auto legacy=plan(400);uint64_t g=0;
    check(coda_transport_publish(o.t,&legacy)==1,"legacy endpoint initial");run(o.t,6400);
    auto storage=performancePlan();auto &p=*storage;
    p.samples_per_step=400;fillPerformanceCycle(p.initial_cycle,0,400);
    check(coda_transport_publish_performance(o.t,&p,&g)==1,"stale endpoint queues");run(o.t,1);
    check(performanceStatus(o.t).rejected_generation==g && performanceStatus(o.t).required_cycle==1,
        "legacy endpoint requires actual next cycle");
    fillPerformanceCycle(p.initial_cycle,1,400);
    check(coda_transport_publish_performance(o.t,&p,&g)==1,"endpoint retry queues");run(o.t,1);
    check(performanceStatus(o.t).applied_generation==g && status(o.t).cycle==1,
        "endpoint retry applies in actual cycle");
}
