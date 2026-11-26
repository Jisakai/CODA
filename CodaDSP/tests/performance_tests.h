// Included in the EXISTING production DSP executable, including sanitizer runs.
#if defined(__APPLE__)
#include <pthread.h>
#include <os/lock.h>
#include "lock_hooks.h"
#endif
static CodaPerformanceEvent performance(int64_t t=0,uint8_t pitch=60,uint8_t rank=0) {
    CodaPerformanceEvent e{};e.sample_offset=t;e.owner={1,1,0,1,static_cast<uint64_t>(rank)+1};
    e.harmonic_token=1;e.kind=CODA_EVENT_ON;e.pitch=pitch;e.voice_rank=rank;
    e.base_velocity=e.effective_velocity=.8f;return e;
}
static void push_performance(CodaDSP *d,const CodaPerformanceEvent &e) {
    require(coda_dsp_push_performance_event(d,&e),"performance admission");
}
static CodaDSP *performance_core(int preset=1) {
    auto d=coda_dsp_create();require(d&&coda_dsp_prepare(d,48000,256),"performance prepare");
    auto c=controls(preset);c.delay_amount=c.reverb_amount=0;
    require(coda_dsp_publish_controls(d,&c),"performance controls");frames(d,24000);return d;
}
static int held_performance(CodaDSP *d) {
    CodaPerformanceVoiceDiagnostic v[12];coda_dsp_inspect_performance(d,v);int n=0;
    for(auto x:v)n+=x.active&&x.performance&&!x.releasing;return n;
}
static void test_performance_ownership() {
    for(int field=0;field<5;field++) {
        auto d=performance_core();auto on=performance(24000);push_performance(d,on);frames(d,256);
        auto off=on;off.kind=CODA_EVENT_OFF;off.sample_offset=24256;
        switch(field){case 0:++off.owner.prepare_epoch;break;case 1:++off.owner.plan_generation;break;
            case 2:++off.owner.cycle;break;case 3:++off.owner.activation;break;case 4:++off.owner.instance;break;}
        push_performance(d,off);frames(d,1);require(held_performance(d)==1,"stale exact owner cannot release");
        off=on;off.kind=CODA_EVENT_OFF;off.sample_offset=24257;off.harmonic_token=9;off.voice_rank=11;
        push_performance(d,off);frames(d,1);require(held_performance(d)==0,"off ownership ignores harmonic and rank");
        bool tail=false;for(auto v:inspect(d).voices)tail|=v.active&&v.stage==4;
        require(tail,"exact off retains release tail");coda_dsp_destroy(d);
    }
    for(bool reverse:{false,true}) {
        auto d=performance_core();for(int i=0;i<12;i++) {
            int rank=reverse?11-i:i;auto e=performance(24000+i,48+rank,rank);push_performance(d,e);
        }
        frames(d,128);require(held_performance(d)==12,"staggered ranks retained in either direction");
        auto e=performance(24128,80);e.harmonic_token=2;push_performance(d,e);frames(d,1);
        require(held_performance(d)==12,"harmonic transition only steals one bounded voice");coda_dsp_destroy(d);
    }
    auto d=performance_core();auto first=performance(24000);push_performance(d,first);frames(d,256);
    auto second=first;second.sample_offset=24256;++second.owner.instance;push_performance(d,second);frames(d,1);
    auto off=first;off.kind=CODA_EVENT_OFF;off.sample_offset=24257;push_performance(d,off);
    event(d,24257,0,CODA_EVENT_OFF,60);frames(d,1);
    require(held_performance(d)==1,"same pitch replacement survives old and legacy offs");
    event(d,24258,0,CODA_EVENT_ON,60);frames(d,1);off=second;off.sample_offset=24259;off.kind=CODA_EVENT_OFF;
    push_performance(d,off);frames(d,1);bool legacy=false;
    CodaPerformanceVoiceDiagnostic voices[12];coda_dsp_inspect_performance(d,voices);
    for(auto v:voices)legacy|=v.active&&!v.performance&&!v.releasing;
    require(legacy&&held_performance(d)==0,"performance off cannot release legacy");coda_dsp_destroy(d);
}
static void test_performance_admission() {
    auto d=performance_core();auto good=performance(24000);
    for(int kind=0;kind<2;kind++)for(int bad=0;bad<26;bad++) {
        auto e=good;e.kind=kind;e.sample_offset=30000;
        switch(bad){case 0:e.base_velocity=NAN;break;case 1:e.effective_velocity=NAN;break;
        case 2:e.detune_cents=NAN;break;case 3:e.filter_delta=NAN;break;case 4:e.base_velocity=0;break;
        case 5:e.effective_velocity=0;break;case 6:e.base_velocity=1.01f;break;case 7:e.effective_velocity=1.01f;break;
        case 8:e.detune_cents=3.01f;break;case 9:e.detune_cents=-3.01f;break;
        case 10:e.filter_delta=.0201f;break;case 11:e.filter_delta=-.0201f;break;case 12:e.kind=2;break;
        case 13:e.pitch=128;break;case 14:e.voice_rank=12;break;case 15:e.attack_mode=2;break;
        case 16:e.owner.prepare_epoch=0;break;case 17:e.owner.plan_generation=0;break;
        case 18:e.owner.activation=0;break;case 19:e.owner.instance=0;break;case 20:e.harmonic_token=0;break;
        case 21:e.sample_offset=-1;break;case 22:e.base_velocity=INFINITY;break;
        case 23:e.effective_velocity=-.1f;break;case 24:e.detune_cents=INFINITY;break;
        case 25:e.filter_delta=-INFINITY;break;}
        require(!coda_dsp_push_performance_event(d,&e),"reject malformed on AND off");
    }
    require(inspect(d).delivered==0&&held_performance(d)==0,"invalid admission leaves render untouched");
    // Invalid future events must not change ordering/count admission.
    for(int i=0;i<32;i++)if(i%2)push_performance(d,good);else event(d,24000,1,CODA_EVENT_ON,61);
    require(!coda_dsp_push_performance_event(d,&good),"mixed 33rd same sample rejected");
    CodaNoteEvent legacy{24000,1,CODA_EVENT_ON,61,0,0};require(!coda_dsp_push_event(d,&legacy),"same shared limit for legacy");
    frames(d,1);require(inspect(d).delivered==32&&inspect(d).late==0,"mixed FIFO delivered at exact sample");
    coda_dsp_reset(d);good=performance();
    for(int i=0;i<1023;i++){good.sample_offset=i;if(i%2)push_performance(d,good);else event(d,i,1,CODA_EVENT_ON,60);}
    good.sample_offset=1023;require(!coda_dsp_push_performance_event(d,&good),"shared queue full");
    frames(d,256);push_performance(d,good);frames(d,768);
    require(inspect(d).delivered==1024,"mixed FIFO backpressure recovery");
    good.sample_offset=1024;push_performance(d,good);good.kind=CODA_EVENT_OFF;
    require(!coda_dsp_push_performance_event(d,&good),"off after on tie rejected");coda_dsp_destroy(d);
}
static std::vector<float> performance_audio(int preset,int attack,float velocity,float detune=0,float filter=0,int gate=1920,float effective=-1) {
    auto d=performance_core(preset);auto e=performance(24000);e.attack_mode=attack;
    e.base_velocity=velocity;e.effective_velocity=effective<0?velocity:effective;e.detune_cents=detune;e.filter_delta=filter;
    push_performance(d,e);e.sample_offset+=gate;e.kind=CODA_EVENT_OFF;push_performance(d,e);
    std::vector<float> out(24000);
    for(int i=0;i<24000;i+=256){int n=std::min(256,24000-i);
        allocation_count=deallocation_count=0;count_allocations=true;
#if defined(__APPLE__)
        coda_test_lock_begin();
#endif
        int ok=coda_dsp_process(d,out.data()+i,n);count_allocations=false;
#if defined(__APPLE__)
        coda_test_lock_end();
#endif
        require(ok&&allocation_count==0&&deallocation_count==0,"performance render allocates/frees nothing");
#if defined(__APPLE__)
        require(coda_test_lock_count()==0,"performance render takes no mutex/unfair locks");
#endif
    }
    for(float x:out)require(std::isfinite(x)&&std::abs(x)<.73f,"performance finite bounded audio");
    coda_dsp_destroy(d);return out;
}
static double energy(const std::vector<float>&x,int begin,int end) {
    double sum=0;for(int i=begin;i<end;i++)sum+=double(x[i])*x[i];return sum;
}
static double difference(const std::vector<float>&a,const std::vector<float>&b) {
    double sum=0;for(size_t i=0;i<a.size();i++)sum+=std::abs(a[i]-b[i]);return sum;
}
static void test_performance_signal() {
    double prior=0;
    for(int level=1;level<=10;level++) {
        auto d=performance_core(0);auto e=performance(24000);e.base_velocity=level/10.f;
        e.effective_velocity=e.base_velocity;push_performance(d,e);frames(d,1);
        CodaPerformanceVoiceDiagnostic v[12];coda_dsp_inspect_performance(d,v);bool found=false;
        for(auto x:v)if(x.active){found=true;require(x.base_velocity==e.base_velocity&&x.effective_velocity==e.effective_velocity,"all ten exact velocity levels in voice");}
        require(found,"velocity voice exists");coda_dsp_destroy(d);
        auto audio=performance_audio(0,0,level/10.f);double value=energy(audio,0,24000);
        require(value>prior,"all ten levels increase actual output energy");prior=value;
    }
    auto velocityCore=performance_core();auto varied=performance(24000);
    varied.base_velocity=.7f;varied.effective_velocity=.31f;push_performance(velocityCore,varied);frames(velocityCore,1);
    CodaPerformanceVoiceDiagnostic variedVoices[12];coda_dsp_inspect_performance(velocityCore,variedVoices);
    require(variedVoices[0].base_velocity==.7f&&variedVoices[0].effective_velocity==.31f,"effective gain does not overwrite base");
    coda_dsp_destroy(velocityCore);
    auto effectiveAudio=performance_audio(1,0,.7f,0,0,1920,.31f);
    auto effectiveReference=performance_audio(1,0,.31f);
    auto baseReference=performance_audio(1,0,.7f);
    require(difference(effectiveAudio,effectiveReference)==0,
        "actual gain follows effective velocity with different unchanged base");
    require(difference(effectiveAudio,baseReference)>.001&&
        energy(effectiveAudio,0,24000)<energy(baseReference,0,24000),
        "effective velocity changes actual audio gain independently of base");
    auto d=performance_core();auto tiny=performance(24000);tiny.attack_mode=CODA_ATTACK_CHUCK;
    tiny.base_velocity=tiny.effective_velocity=1.e-30f;push_performance(d,tiny);frames(d,1);
    CodaPerformanceVoiceDiagnostic v[12];coda_dsp_inspect_performance(d,v);
    require(v[0].effective_velocity==1.e-30f,"tiny continuous chuck is not clamped");coda_dsp_destroy(d);
    require(difference(performance_audio(0,1,.12345f),performance_audio(0,1,.12346f))>0,
        "continuous chuck gain is not quantized to arrow levels");
    for(int p=0;p<3;p++) {
        auto ordinary=performance_audio(p,0,.8f),chuck=performance_audio(p,1,.8f);
        auto repeated=performance_audio(p,1,.8f),held=performance_audio(p,1,.8f,0,0,20000);
        auto early=performance_audio(p,1,.8f,0,0,480);
        require(energy(chuck,0,1920)>1.e-7,"chuck has measurable audible-scale energy on every preset");
        require(difference(chuck,ordinary)>.01,"chuck differs from ordinary on every preset");
        require(difference(chuck,repeated)==0,"chuck noise deterministic per voice");
        require(energy(held,9600,12000)<energy(held,0,1920)*.02,"chuck decays despite held gate");
        require(difference(chuck,early)>.001,"chuck off actually changes release");
        require(energy(early,480,1000)>0,"chuck off is a tail, not a hard cut");
    }
    auto low=performance_audio(0,0,.8f,-3,-.02f),high=performance_audio(0,0,.8f,3,.02f);
    require(difference(low,high)>.01,"modulation endpoints change real rendering");
    auto no=performance_audio(0,0,.8f);
    require(difference(no,performance_audio(0,0,.8f,3,0))>.001,"detune independently affects audio");
    require(difference(no,performance_audio(0,0,.8f,0,.02f))>.001,"filter independently affects audio");
}
static void test_performance_glide() {
    auto d=performance_core(2);auto c=controls(2);c.glide=1;require(coda_dsp_publish_controls(d,&c),"performance glide controls");
    frames(d,24000);
    for(int rank=0;rank<3;rank++){auto e=performance(48000,48+rank*4,rank);push_performance(d,e);}
    frames(d,256);
    // Different note instances in one harmonic must not move the predecessor
    // snapshot between staggered attacks, even when onset order is descending.
    for(int i=0;i<3;i++) {int rank=2-i;auto e=performance(48256+i*32,60+rank*4,rank);
        e.harmonic_token=2;e.owner.instance+=10;push_performance(d,e);}
    frames(d,65);
    int checked=0;for(auto v:inspect(d).voices)if(v.active&&v.target_frequency>260) {
        const float old=440.f*std::pow(2.f,(48+v.rank*4-69)/12.f);
        require(v.frequency>=old&&v.frequency<old*1.03f,"staggered harmonic retains sorted predecessor glide");++checked;
    }
    require(checked==3&&held_performance(d)==6,"harmonic change retains old held notes");coda_dsp_destroy(d);
}
static void test_performance() {
#if defined(__APPLE__)
    pthread_mutex_t mutex;
    require(pthread_mutex_init(&mutex,nullptr)==0,"calibration mutex initialization");
    os_unfair_lock unfair=OS_UNFAIR_LOCK_INIT;
    coda_test_lock_begin();count_allocations=true;
    pthread_mutex_lock(&mutex);pthread_mutex_unlock(&mutex);count_allocations=false;coda_test_lock_end();
    require(coda_test_lock_count()==1,"mutex interposition calibration");
    coda_test_lock_begin();count_allocations=true;
    os_unfair_lock_lock(&unfair);os_unfair_lock_unlock(&unfair);count_allocations=false;coda_test_lock_end();
    require(coda_test_lock_count()==1,"unfair lock interposition calibration");
    coda_test_lock_begin();count_allocations=true;
    const int lockResult=pthread_mutex_lock(&mutex);
    if(lockResult==0)pthread_mutex_unlock(&mutex);
    os_unfair_lock_lock(&unfair);os_unfair_lock_unlock(&unfair);
    count_allocations=false;coda_test_lock_end();
    require(lockResult==0,"combined calibration mutex lock");
    require(coda_test_lock_count()==2,"both real lock hooks increase render_locks by exactly two");
    require(pthread_mutex_destroy(&mutex)==0,"calibration mutex destruction");
#endif
    test_performance_ownership();test_performance_admission();test_performance_signal();test_performance_glide();
}
