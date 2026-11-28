// Tests call the same production units used by coda_dsp_process.
static CodaDSPDiagnostics inspect(CodaDSP *d) {CodaDSPDiagnostics x{};coda_dsp_inspect(d,&x);return x;}
static void frames(CodaDSP *d,int n) {float x[256];while(n){int k=std::min(n,256);require(coda_dsp_process(d,x,k),"render frames");n-=k;}}
static void event(CodaDSP *d,int64_t t,uint32_t region,uint8_t kind,uint8_t pitch,uint8_t rank=0) {
    CodaNoteEvent e{t,region,kind,pitch,rank,0};require(coda_dsp_push_event(d,&e),"admit event");
}
static void test_envelopes() {
    for(double rate:{44100.,48000.,96000.})for(int preset=0;preset<3;preset++) {
        const double attack[]={.003,.42,.012},decay[]={.1,.6,.18},sustain[]={0,.78,.72},release[]={.2,1.8,.55};
        coda::Envelope e;e.on();
        for(int i=0;i<static_cast<int>(std::ceil(rate*attack[preset]))+1;i++)e.tick(rate,attack[preset],decay[preset],sustain[preset],release[preset]);
        require(e.stage==coda::Stage::decay && e.level>.999,"persistent attack->decay");
        for(int i=0;i<static_cast<int>(std::ceil(rate*decay[preset]))+2;i++)e.tick(rate,attack[preset],decay[preset],sustain[preset],release[preset]);
        require(std::abs(e.level-sustain[preset])<1e-7,"known sustain level");
        require(e.stage==(preset?coda::Stage::sustain:coda::Stage::idle),"zero sustain becomes idle");
        for(int cut:{1,2}) {
            e.on();const int n=static_cast<int>(rate*(cut==1?attack[preset]*.4:attack[preset]+decay[preset]*.4));
            for(int i=0;i<n;i++)e.tick(rate,attack[preset],decay[preset],sustain[preset],release[preset]);
            const double start=e.level;e.off();require(e.level==start,"off continuous from current level");
            const int half=static_cast<int>(rate*release[preset]/2);
            for(int i=0;i<half;i++)e.tick(rate,attack[preset],decay[preset],sustain[preset],release[preset]);
            require(std::abs(e.level-start*.5)<start*2/(rate*release[preset]),"linear release half time");
            for(int i=half;i<static_cast<int>(std::ceil(rate*release[preset]))+2;i++)e.tick(rate,attack[preset],decay[preset],sustain[preset],release[preset]);
            require(e.stage==coda::Stage::idle && e.level==0,"finite release duration");
        }
        e.on();for(int i=0;i<100;i++)e.tick(rate,1,.5,.7,1);
        double before=e.level;e.tick(rate,2,.5,.7,2);
        require(e.stage==coda::Stage::attack && std::abs(e.level-before-1/(2*rate))<1e-12,"shape timing changes without stage restart");
    }
    // Actual voice wiring, captured preset policy, and reset.
    for(int p=0;p<3;p++) {
        CodaDSP *d=coda_dsp_create();require(coda_dsp_prepare(d,48000,256),"envelope production prepare");
        auto c=controls(p);c.shape=1.f/3;require(coda_dsp_publish_controls(d,&c),"env controls");
        frames(d,24000);event(d,24000,1,CODA_EVENT_ON,60);frames(d,1);
        auto x=inspect(d);bool attack=false;for(auto v:x.voices)if(v.active)attack|=v.stage==1&&v.amplitude>0&&v.preset==p;
        require(attack,"production voice calls envelope");
        c.preset=static_cast<uint8_t>((p+1)%3);require(coda_dsp_publish_controls(d,&c),"switch preset");frames(d,576);
        for(auto v:inspect(d).voices)if(v.active)require(v.preset==p,"active voice retains ADSR/oscillator preset");
        frames(d,96000);bool held=false;for(auto v:inspect(d).voices)held|=v.active;
        require(held==(p!=0),"production pluck idle / sustained pad and lead");
        coda_dsp_reset(d);for(auto v:inspect(d).voices)require(!v.active&&v.stage==0,"reset envelope state");coda_dsp_destroy(d);
    }
}
template<class EQ> static double gain(EQ &eq,double rate,double hz) {
    eq.reset();double in=0,out=0;
    const int n=static_cast<int>(rate);
    for(int i=0;i<n;i++){float x=static_cast<float>(std::sin(2*coda::pi*hz*i/rate));float y=eq.tick(x);if(i>n/2){in+=x*x;out+=y*y;}}
    return std::sqrt(out/in);
}
static void test_eq_units() {
    for(double rate:{44100.,48000.,96000.}) {
        coda::ChordsEQ chords;chords.prepare(rate);
        float end=0;for(int i=0;i<rate;i++)end=chords.tick(1);
        require(std::abs(end)<1e-7,"Chords DC step decays to zero");
        const double low=gain(chords,rate,30),mid=gain(chords,rate,1000),high=gain(chords,rate,15000);
        require(low<.08 && mid>.97 && high<.5,"Chords HP120/LP9k sine response");
        coda::BassEQ bassEq;bassEq.prepare(rate);
        const double bSub=gain(bassEq,rate,10),bFund=gain(bassEq,rate,100),bHigh=gain(bassEq,rate,8000);
        require(bSub<.15 && bFund>.95 && bHigh<.15,"Bass HP35/LP2.5k sine response");
        coda::MelodyEQ melEq;melEq.prepare(rate);
        const double mLow=gain(melEq,rate,40),mMid=gain(melEq,rate,800),mDip=gain(melEq,rate,3000),mHigh=gain(melEq,rate,8000);
        require(mLow<.08 && mMid>.93 && mDip<.80 && mDip>.68 && mHigh>mDip,"Melody HP200/-2.5dB@3k sine response");
        coda::MasterEQ master;master.prepare(rate);
        double bass=gain(master,rate,100),dip=gain(master,rate,3000),outside=gain(master,rate,700),upper=gain(master,rate,6000),top=gain(master,rate,18000);
        require(bass>.99&&outside>.95&&dip>.73&&dip<.82,"localized broad master dip");
        require(upper>dip&&top<bass*.8,"master returns above dip and attenuates highs");
        // State reset must be real, not coefficient reconfiguration.
        chords.reset();bassEq.reset();melEq.reset();master.reset();
        for(int i=0;i<100;i++)require(chords.tick(0)==0&&bassEq.tick(0)==0&&melEq.tick(0)==0&&master.tick(0)==0,"filter reset silence");
    }
}
static void test_production_reset_wiring() {
    CodaDSP *warm=coda_dsp_create(),*fresh=coda_dsp_create();
    require(coda_dsp_prepare(warm,48000,256)&&coda_dsp_prepare(fresh,48000,256),"reset wiring prepare");
    auto c=controls(2);c.delay_amount=c.reverb_amount=1;
    require(coda_dsp_publish_controls(warm,&c),"warm filter/FX controls");
    event(warm,0,99,CODA_EVENT_ON,60);frames(warm,48000);coda_dsp_reset(warm);
    for(auto d:{warm,fresh}){require(coda_dsp_publish_controls(d,&c),"reset comparison controls");event(d,0,1,CODA_EVENT_ON,67);event(d,2000,1,CODA_EVENT_OFF,67);}
    float a[256],b[256];
    for(int block=0;block<400;block++) {
        require(coda_dsp_process(warm,a,256)&&coda_dsp_process(fresh,b,256),"reset production comparison");
        for(int i=0;i<256;i++)require(a[i]==b[i],"actual EQ/FDN/delay/voice reset matches fresh production core");
    }
    coda_dsp_destroy(warm);coda_dsp_destroy(fresh);
}
static void test_hall_unit() {
    for(double rate:{44100.,48000.,96000.}) {
        const uint32_t n=static_cast<uint32_t>(rate*.06)+1,pn=static_cast<uint32_t>(rate*.025)+1;
        std::vector<std::array<float,4>> lines(n);std::vector<uint64_t> tags(n),pt(pn);std::vector<float> pre(pn);
        coda::Hall h;h.prepare(rate,lines.data(),tags.data(),n,pre.data(),pt.data(),pn);
        double early=0,late=0,veryLate=0;int nonzero=0;
        for(int i=0;i<static_cast<int>(rate*8);i++) {
            float y=h.tick(i==0?1.f:0.f);require(std::isfinite(y)&&std::abs(y)<1,"hall finite bounded impulse");
            if(i<static_cast<int>(rate*.02))require(y==0,"no wet before predelay");
            if(i>rate*.1&&i<rate*.5){early+=y*y;if(std::abs(y)>1e-8)nonzero++;}
            if(i>rate*1&&i<rate*1.4)late+=y*y;
            if(i>rate*6&&i<rate*6.4)veryLate+=y*y;
        }
        require(nonzero>rate*.25,"diffuse tail rather than isolated echo taps");
        require(late>1e-12&&late<early*.4&&late>early*1e-6,"measurable long decaying hall tail");
        require(veryLate<late*1e-5,"hall eventually decays");
        h.reset();for(int i=0;i<rate;i++)require(h.tick(0)==0,"hall generation reset invalidates all delayed taps");
        double mean=0;for(int i=0;i<rate*4;i++){float y=h.tick(.1f);require(std::isfinite(y)&&std::abs(y)<1,"DC stable feedback");if(i>rate*3)mean+=y;}
        require(std::abs(mean/rate)<.5,"no DC runaway");
        const auto generation=h.generation;
        h.prepare(rate,lines.data(),tags.data(),n,pre.data(),pt.data(),pn);
        require(h.write==0&&h.preWrite==0&&h.diffWrite[0]==0&&h.diffWrite[1]==0,"hall prepare reinitializes every cursor");
        require(h.generation==generation+1,"hall prepare preserves generation invalidation");
        for(float x:h.lp)require(x==0,"hall prepare clears damping state");
    }
}
static void test_public_reprepare() {
    struct Case {uint32_t from,to;int warm,action;};
    const Case cases[]={
        {96000,48000,2048,0},       // Original eight-block predelay overflow.
        {96000,48000,192013,0},     // Old FDN cursor > new 144000-cell ring.
        {48000,96000,48013,0},
        {48000,48000,48013,0},
        {96000,48000,192013,1},     // Reset while cursors are nonzero, then reprepare.
        {96000,48000,192013,2},     // Stop, then prepare must resume at zero.
        {384000,8000,32013,0},      // Valid extremes; old FDN cursor > new 24000.
        {8000,384000,8013,1}
    };
    // All production, publication and lifecycle calls are serial on this thread:
    // both producer and render are fully quiescent at every lifecycle boundary.
    for(const auto &test:cases) {
        CodaDSP *d=coda_dsp_create();require(coda_dsp_prepare(d,test.from,256),"reprepare initial prepare");
        auto c=controls(CODA_PRESET_WOBBLE);c.delay_amount=c.reverb_amount=1;
        for(int repeat=0;repeat<2;repeat++) {
            require(coda_dsp_publish_controls(d,&c),"reprepare warm controls");
            event(d,0,1,CODA_EVENT_ON,60);frames(d,test.warm);
            // Include queued future work: successful prepare must discard it.
            event(d,test.warm+17,2,CODA_EVENT_ON,67);
            if(test.action==1)coda_dsp_reset(d);
            if(test.action==2)coda_dsp_stop(d);
            require(coda_dsp_prepare(d,test.to,256),"same-object public reprepare");
            const auto state=inspect(d);
            require(state.sample_clock==0&&state.delivered==0,"reprepare resets timeline and delivery");
            for(auto v:state.voices)require(!v.active,"reprepare discards old voices");
            float out[256];
            // Process one sample first to expose the retained write immediately;
            // continue through all wet tap times without publishing any notes.
            require(coda_dsp_process(d,out,1)&&std::isfinite(out[0])&&out[0]==0,"first reprepare sample silent and finite");
            for(uint32_t at=1;at<test.to+257;) {
                const uint32_t n=std::min(256u,test.to+257-at);
                require(coda_dsp_process(d,out,n),"reprepare silent render");
                for(uint32_t i=0;i<n;i++)require(std::isfinite(out[i])&&out[i]==0,"no stale voice or wet output after reprepare");
                at+=n;
            }
            require(inspect(d).delivered==0,"reprepare discards queued notes");
            require(coda_dsp_publish_controls(d,&c),"reprepare playback controls");
            const auto start=inspect(d).sample_clock;
            event(d,static_cast<int64_t>(start),3,CODA_EVENT_ON,64);
            double energy=0;
            for(uint32_t at=0;at<test.to;) {
                const uint32_t n=std::min(256u,test.to-at);
                require(coda_dsp_process(d,out,n),"reprepare playback render");
                for(uint32_t i=0;i<n;i++){require(std::isfinite(out[i]),"reprepare playback finite");energy+=out[i]*out[i];}
                at+=n;
            }
            require(energy>.001&&inspect(d).delivered==1&&inspect(d).late==0,"reprepare accepts audible sample-accurate new events");
            coda_dsp_reset(d); // Next iteration repeats prepare at the target rate.
        }
        coda_dsp_destroy(d);
    }
}
static void test_admission_delivery_stop() {
    for(int limit:{int(CODA_DSP_MAX_EVENTS_PER_SAMPLE)-1,int(CODA_DSP_MAX_EVENTS_PER_SAMPLE),int(CODA_DSP_MAX_EVENTS_PER_SAMPLE)+1}) {
        CodaDSP *d=coda_dsp_create();require(coda_dsp_prepare(d,48000,256),"admission prepare");
        for(int i=0;i<limit;i++){CodaNoteEvent e{17,1,CODA_EVENT_OFF,60,0,0};require(bool(coda_dsp_push_event(d,&e))==(i<CODA_DSP_MAX_EVENTS_PER_SAMPLE),"limit-1/limit/limit+1 admission");}
        frames(d,17);require(inspect(d).delivered==0,"no early delivery");frames(d,1);
        require(inspect(d).delivered==static_cast<uint64_t>(std::min(limit,int(CODA_DSP_MAX_EVENTS_PER_SAMPLE)))&&inspect(d).late==0,"all accepted offsets exact");
        coda_dsp_reset(d);event(d,0,1,CODA_EVENT_OFF,60);event(d,0,2,CODA_EVENT_ON,64);
        CodaNoteEvent bad{0,1,CODA_EVENT_OFF,60,0,0};require(!coda_dsp_push_event(d,&bad),"off-after-on rejected");
        bad={1,1,CODA_EVENT_ON,60,12,0};require(!coda_dsp_push_event(d,&bad),"invalid rank rejected");
        bad={-1,1,CODA_EVENT_ON,60,0,0};require(!coda_dsp_push_event(d,&bad),"invalid offset rejected");
        frames(d,1);require(inspect(d).delivered==2&&inspect(d).late==0,"off before on delivery");
        event(d,100,3,CODA_EVENT_ON,67);auto c=controls();require(coda_dsp_publish_controls(d,&c),"queued controls before stop");
        coda_dsp_stop(d);float stoppedOutput[256];require(coda_dsp_process(d,stoppedOutput,256),"stopped process succeeds");
        for(float y:stoppedOutput)require(y==0,"stop immediately silences voices and tails");
        require(!coda_dsp_publish_controls(d,&c),"stop rejects controls until reset");
        require(inspect(d).delivered==0,"stop discards queued events");
        bad={0,1,CODA_EVENT_ON,60,0,0};require(!coda_dsp_push_event(d,&bad),"stopped admission rejected");
        coda_dsp_reset(d);event(d,0,4,CODA_EVENT_ON,72);frames(d,1);require(inspect(d).delivered==1&&inspect(d).late==0,"reset resumes from zero");coda_dsp_destroy(d);
    }
    CodaDSP *d=coda_dsp_create();require(coda_dsp_prepare(d,48000,256),"full queue prepare");
    constexpr int cap=CODA_DSP_QUEUE_CAPACITY-1;
    for(int i=0;i<cap;i++)event(d,i,1,i%2?CODA_EVENT_ON:CODA_EVENT_OFF,60);
    CodaNoteEvent e{cap,1,CODA_EVENT_OFF,60,0,0};require(!coda_dsp_push_event(d,&e),"full queue rejects");
    frames(d,cap);require(inspect(d).delivered==static_cast<uint64_t>(cap)&&inspect(d).late==0,"full queue delivered in order at exact offsets");
    require(coda_dsp_push_event(d,&e),"full queue recovers");frames(d,1);require(inspect(d).delivered==static_cast<uint64_t>(cap+1)&&inspect(d).late==0,"recovery event exact");coda_dsp_destroy(d);
}
static void test_glide_predecessor() {
    for(int preset=0;preset<3;preset++) {
        CodaDSP *d=coda_dsp_create();require(coda_dsp_prepare(d,48000,256),"rank glide prepare");auto c=controls(preset);c.glide=1;c.shape=1;
        require(coda_dsp_publish_controls(d,&c),"rank glide controls");frames(d,24000);
        event(d,24000,1,CODA_EVENT_ON,48,0);event(d,24000,1,CODA_EVENT_ON,60,1);
        event(d,24010,1,CODA_EVENT_OFF,48,0);event(d,24010,1,CODA_EVENT_OFF,60,1);event(d,24010,2,CODA_EVENT_ON,55,0);
        event(d,24020,2,CODA_EVENT_OFF,55,0);event(d,24020,3,CODA_EVENT_ON,67,0);event(d,24020,3,CODA_EVENT_ON,79,1);
        event(d,24021,1,CODA_EVENT_OFF,60,1);frames(d,22);
        bool rank0=false,rank1=false;for(auto v:inspect(d).voices)if(v.region==3&&v.active){
            if(v.rank==0){rank0=true;require(v.frequency<v.target_frequency*.8f,"rank zero glides from immediate predecessor");}
            if(v.rank==1){rank1=true;require(v.frequency==v.target_frequency&&v.stage==1,"missing preceding rank starts at target; stale off ignored");}
        }require(rank0&&rank1,"new chord voices present");coda_dsp_destroy(d);
    }
}
static void test_quick_mute() {
    for(int sameBlock=0;sameBlock<2;sameBlock++) {
        CodaDSP *d=coda_dsp_create(),*ref=coda_dsp_create();
        require(coda_dsp_prepare(d,48000,256)&&coda_dsp_prepare(ref,48000,256),"mute comparison prepare");
        auto c=controls();c.delay_amount=1;c.reverb_amount=1;
        for(auto core:{d,ref}){require(coda_dsp_publish_controls(core,&c),"wet controls");event(core,0,1,CODA_EVENT_ON,60);event(core,300,1,CODA_EVENT_OFF,60);frames(core,24000);}
        c.muted=1;require(coda_dsp_publish_controls(d,&c),"latch mute");
        if(!sameBlock) {frames(d,1);frames(ref,1);}
        c.muted=0;require(coda_dsp_publish_controls(d,&c),"quick unmute");
        auto generation=inspect(d).effect_generation;
        float a[256],b[256];double referenceEnergy=0,delta=0;
        // Both dry voices are idle. Output during fade must equal reference *
        // fade before nonlinear master; compare first samples at low signal.
        require(coda_dsp_process(d,a,256)&&coda_dsp_process(ref,b,256),"mute reference process");
        for(int i=0;i<256;i++){referenceEnergy+=b[i]*b[i];delta+=std::abs(a[i]-b[i]);
            if(i<8)require(std::abs(a[i]-b[i])<std::abs(b[i])*.05f+1e-7f,"wet path continuous during mute fade");}
        require(referenceEnergy>1e-12&&delta>1e-8,"audible wet tail and measurable fade");
        frames(d,512);require(inspect(d).effect_generation==generation+1,"quick unmute cannot cancel invalidation");
        float peak=0;for(int block=0;block<600;block++){require(coda_dsp_process(d,a,256),"long post-unmute render");for(float y:a)peak=std::max(peak,std::abs(y));}
        require(peak<1e-7,"no stale tail at old delayed taps after unmute");
        require(inspect(d).mute_gain==1,"pending unmute fades back up");coda_dsp_destroy(d);coda_dsp_destroy(ref);
    }
}
static uint64_t hash_event(uint64_t h,const CodaNoteEvent &e){h=(h^static_cast<uint64_t>(e.sample_offset))*1099511628211ull;h=(h^e.region_id)*1099511628211ull;return (h^e.kind)*1099511628211ull;}
static void test_allocations_and_concurrency() {
    // Self-test every instrumented family, including over-aligned CodaDSP.
    allocation_count=deallocation_count=0;count_allocations=true;
    void *p=::operator new(17);::operator delete(p);p=::operator new[](19);::operator delete[](p);
    p=::operator new(64,std::align_val_t(64));::operator delete(p,std::align_val_t(64));
    p=::operator new[](128,std::align_val_t(64));::operator delete[](p,std::align_val_t(64));count_allocations=false;
    require(allocation_count==4&&deallocation_count==4,"allocator hook calibration incl aligned arrays");
    CodaDSP *d=coda_dsp_create();require(coda_dsp_prepare(d,48000,256),"allocation core prepare");auto c=controls(1);c.delay_amount=c.reverb_amount=1;
    for(int block=0;block<20;block++) {
        c.muted=block==6||block==7;c.warmth=block%2;c.preset=block%3;require(coda_dsp_publish_controls(d,&c),"allocation control changes");
        if(block)for(int i=0;i<12;i++)event(d,block*256,block,CODA_EVENT_OFF,48+i,i);
        for(int i=0;i<12;i++)event(d,block*256,block+1,CODA_EVENT_ON,48+i,i);
        allocation_count=deallocation_count=0;float out[256];count_allocations=true;
        int ok=coda_dsp_process(d,out,256);count_allocations=false;
        require(ok&&allocation_count==0&&deallocation_count==0,"active FX/stealing/controls/mute invalidation allocates and frees nothing");
    }coda_dsp_destroy(d);
    // Handshake keeps each immutable group published BEFORE its render block.
    // Pre-fill to capacity to force actual full/recovery while preserving timing.
    // After publishing group 0, producer refills future groups concurrently with
    // rendering; ready prevents the consumer entering an incompletely published group.
    d=coda_dsp_create();require(coda_dsp_prepare(d,48000,256),"concurrent prepare");
    std::atomic<int> ready{0};std::atomic<bool> producerOK{true};uint64_t expectedHash=1469598103934665603ull;
    constexpr int groups=8,groupSize=CODA_DSP_QUEUE_CAPACITY-1;
    std::thread producer([&]{
        for(int group=0;group<groups;group++) {
            for(int i=0;i<groupSize;i++) {
                int64_t t=group*CODA_DSP_QUEUE_CAPACITY+i;CodaNoteEvent e{t,static_cast<uint32_t>(group*CODA_DSP_QUEUE_CAPACITY+i/2+1),static_cast<uint8_t>(i%2?CODA_EVENT_OFF:CODA_EVENT_ON),60,0,0};
                while(!coda_dsp_push_event(d,&e))std::this_thread::yield();expectedHash=hash_event(expectedHash,e);
            }
            if(group==0){CodaNoteEvent full{groupSize,1,CODA_EVENT_OFF,60,0,0};if(coda_dsp_push_event(d,&full))producerOK=false;}
            auto ctrl=controls(group%3);for(int i=0;i<7;i++)while(!coda_dsp_publish_controls(d,&ctrl))std::this_thread::yield();
            if(group==0&&coda_dsp_publish_controls(d,&ctrl))producerOK=false;
            ready.store(group+1,std::memory_order_release);
        }
    });
    for(int group=0;group<groups;group++) {
        while(ready.load(std::memory_order_acquire)<group+1)std::this_thread::yield();
        frames(d,CODA_DSP_QUEUE_CAPACITY);auto x=inspect(d);require(x.delivered==static_cast<uint64_t>((group+1)*groupSize)&&x.late==0,"concurrent exact delivery and full recovery");
    }
    producer.join();require(producerOK.load()&&inspect(d).event_hash==expectedHash,"concurrent note on/off order/hash and control storms");coda_dsp_destroy(d);
}
static void test_pass2() {test_envelopes();test_eq_units();test_production_reset_wiring();test_hall_unit();test_public_reprepare();test_admission_delivery_stop();test_glide_predecessor();test_quick_mute();test_allocations_and_concurrency();}
