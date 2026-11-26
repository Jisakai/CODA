#include "coda_dsp.h"
#include "dsp_units.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <new>
#include <string>
#include <thread>
#include <vector>

static thread_local bool count_allocations=false;
static thread_local uint64_t allocation_count=0, deallocation_count=0;
static void *allocate(std::size_t n,std::size_t alignment=0) {
    if(count_allocations)++allocation_count;
    n=std::max<std::size_t>(n,1);
    void *p=alignment?std::aligned_alloc(alignment,((n+alignment-1)/alignment)*alignment):std::malloc(n);
    if(!p)throw std::bad_alloc();return p;
}
static void deallocate(void *p) noexcept {if(p&&count_allocations)++deallocation_count;std::free(p);}
void *operator new(std::size_t n){return allocate(n);}
void *operator new[](std::size_t n){return allocate(n);}
void *operator new(std::size_t n,std::align_val_t a){return allocate(n,static_cast<std::size_t>(a));}
void *operator new[](std::size_t n,std::align_val_t a){return allocate(n,static_cast<std::size_t>(a));}
void *operator new(std::size_t n,const std::nothrow_t&) noexcept {try{return allocate(n);}catch(...){return nullptr;}}
void *operator new[](std::size_t n,const std::nothrow_t&) noexcept {try{return allocate(n);}catch(...){return nullptr;}}
void *operator new(std::size_t n,std::align_val_t a,const std::nothrow_t&) noexcept {try{return allocate(n,static_cast<std::size_t>(a));}catch(...){return nullptr;}}
void *operator new[](std::size_t n,std::align_val_t a,const std::nothrow_t&) noexcept {try{return allocate(n,static_cast<std::size_t>(a));}catch(...){return nullptr;}}
void operator delete(void *p) noexcept {deallocate(p);}
void operator delete[](void *p) noexcept {deallocate(p);}
void operator delete(void *p,std::size_t) noexcept {deallocate(p);}
void operator delete[](void *p,std::size_t) noexcept {deallocate(p);}
void operator delete(void *p,std::align_val_t) noexcept {deallocate(p);}
void operator delete[](void *p,std::align_val_t) noexcept {deallocate(p);}
void operator delete(void *p,std::size_t,std::align_val_t) noexcept {deallocate(p);}
void operator delete[](void *p,std::size_t,std::align_val_t) noexcept {deallocate(p);}
void operator delete(void *p,const std::nothrow_t&) noexcept {deallocate(p);}
void operator delete[](void *p,const std::nothrow_t&) noexcept {deallocate(p);}
void operator delete(void *p,std::align_val_t,const std::nothrow_t&) noexcept {deallocate(p);}
void operator delete[](void *p,std::align_val_t,const std::nothrow_t&) noexcept {deallocate(p);}

static void require(bool ok,const char *message) { if(!ok){std::fprintf(stderr,"FAIL: %s\n",message);std::exit(1);} }
static CodaControls controls(int preset=0) {
    CodaControls c{};require(coda_dsp_default_controls(static_cast<uint8_t>(preset),&c),"preset defaults");
    c.cutoff=.72f;c.resonance=.2f;c.shape=.4f;c.detune=.24f;c.delay_amount=.18f;c.reverb_amount=.16f;return c;
}
static std::vector<float> render(int preset,uint32_t block,float cutoff=.72f,uint32_t seconds=1,uint32_t rate=48000,const CodaControls *overrideControls=nullptr) {
    CodaDSP *d=coda_dsp_create();require(d!=nullptr,"create");require(coda_dsp_prepare(d,rate,block),"prepare");
    auto c=overrideControls?*overrideControls:controls(preset);c.preset=static_cast<uint8_t>(preset);c.cutoff=cutoff;
    require(coda_dsp_publish_controls(d,&c),"controls");
    for(uint8_t p=48;p<55;p++) { CodaNoteEvent e{0,1,CODA_EVENT_ON,p,static_cast<uint8_t>(p-48),0};require(coda_dsp_push_event(d,&e),"push note on"); }
    std::vector<float> out(rate*seconds);uint32_t at=0;
    while(at<out.size()) { const uint32_t n=std::min<uint32_t>(block,static_cast<uint32_t>(out.size()-at));require(coda_dsp_process(d,out.data()+at,n),"process");at+=n; }
    coda_dsp_destroy(d);return out;
}
static void write_wav(const char *path,const std::vector<float> &data) {
    std::ofstream f(path,std::ios::binary);uint32_t bytes=static_cast<uint32_t>(data.size()*2),rate=48000;
    auto u16=[&](uint16_t x){f.put(x&255);f.put((x>>8)&255);};auto u32=[&](uint32_t x){for(int i=0;i<4;i++)f.put((x>>(i*8))&255);};
    f.write("RIFF",4);u32(36+bytes);f.write("WAVEfmt ",8);u32(16);u16(1);u16(1);u32(rate);u32(rate*2);u16(2);u16(16);f.write("data",4);u32(bytes);
    for(float x:data){int16_t s=static_cast<int16_t>(std::lrint(std::clamp(x,-1.0f,1.0f)*32767));u16(static_cast<uint16_t>(s));}
}
static void test_core(int preset) {
    auto a=render(preset,64), b=render(preset,257);
    double energy=0;float peak=0;size_t nonzero=0;
    for(float x:a){require(std::isfinite(x),"finite output");energy+=x*x;peak=std::max(peak,std::abs(x));if(std::abs(x)>1e-6f)nonzero++;}
    require(energy>0.01,"non-silent");require(peak<.73f,"bounded peak");require(nonzero>1000,"audible envelope and tail");
    double delta=0;for(size_t i=0;i<a.size();i++)delta+=std::abs(a[i]-b[i]);
    require(delta<0.0001,"block-size invariant");
}
static void test_release_and_events() {
    CodaDSP *d=coda_dsp_create();require(coda_dsp_prepare(d,48000,128),"prepare release");
    auto c=controls();require(coda_dsp_publish_controls(d,&c),"controls release");
    CodaNoteEvent on{0,77,CODA_EVENT_ON,60,0,0}, off{64,77,CODA_EVENT_OFF,60,0,0};
    require(coda_dsp_push_event(d,&on)&&coda_dsp_push_event(d,&off),"event pair");
    float out[128];require(coda_dsp_process(d,out,128),"event process");
    float first=0,last=0;for(int i=0;i<64;i++)first+=std::abs(out[i]);for(int i=64;i<128;i++)last+=std::abs(out[i]);
    require(first>0&&last>0,"onset and release tail");coda_dsp_destroy(d);
}
static void test_validation_and_queue() {
    CodaDSP *d=coda_dsp_create();require(coda_dsp_prepare(d,44100,256),"prepare validation");
    auto c=controls();c.wobble=NAN;require(!coda_dsp_publish_controls(d,&c),"reject nonfinite control");
    c=controls();require(coda_dsp_publish_controls(d,&c),"publish valid");
    CodaNoteEvent e{0,1,CODA_EVENT_ON,60,0,0};int accepted=0;for(int i=0;i<CODA_DSP_QUEUE_CAPACITY;i++){e.sample_offset=i;if(coda_dsp_push_event(d,&e))accepted++;else break;}
    require(accepted==CODA_DSP_QUEUE_CAPACITY-1,"bounded queue capacity");
    require(!coda_dsp_push_event(d,&e),"observable full queue");
    float out[256];require(coda_dsp_process(d,out,256),"drain events");coda_dsp_destroy(d);
}
static void test_controls_change_signal() {
    auto dark=render(CODA_PRESET_PLUCK,128,.16f), bright=render(CODA_PRESET_PLUCK,128,.9f);
    double delta=0;for(size_t i=0;i<dark.size();i++)delta+=std::abs(dark[i]-bright[i]);
    require(delta>0.1,"cutoff changes signal");
}
static void test_control_endpoints_and_sample_rates() {
    const float expectedGlide[]={0.0f,0.0f,0.35f};
    for(uint8_t p=0;p<3;p++){CodaControls defaults{};require(coda_dsp_default_controls(p,&defaults),"get preset defaults");
      require(std::abs(defaults.glide-expectedGlide[p])<1e-6f,"preset glide default");}
    auto baseline=controls(CODA_PRESET_PLUCK);
    const CodaControls variants[]={
        []{auto c=controls(CODA_PRESET_PLUCK);c.resonance=.7f;return c;}(),
        []{auto c=controls(CODA_PRESET_PLUCK);c.warmth=1;return c;}(),
        []{auto c=controls(CODA_PRESET_PLUCK);c.wobble=1;return c;}(),
        []{auto c=controls(CODA_PRESET_PLUCK);c.detune=1;return c;}(),
        []{auto c=controls(CODA_PRESET_PLUCK);c.shape=1;return c;}(),
        []{auto c=controls(CODA_PRESET_PLUCK);c.delay_amount=1;return c;}(),
        []{auto c=controls(CODA_PRESET_PLUCK);c.reverb_amount=1;return c;}(),
        []{auto c=controls(CODA_PRESET_PLUCK);c.chord_level=.35f;return c;}()
    };
    auto reference=render(CODA_PRESET_PLUCK,128,.72f,1,48000,&baseline);
    for(const auto &variant:variants) {
        auto changed=render(CODA_PRESET_PLUCK,128,.72f,1,48000,&variant);double delta=0;
        for(size_t i=0;i<reference.size();i++)delta+=std::abs(reference[i]-changed[i]);
        require(delta>0.01,"control endpoint changes signal");
    }
    for(uint32_t rate:{44100u,48000u,96000u}) {
        auto output=render(CODA_PRESET_CURRENTS,128,.72f,1,rate);
        double energy=0;for(float sample:output){require(std::isfinite(sample),"sample-rate finite");energy+=sample*sample;}
        require(energy>0.01,"sample-rate non-silent");
    }
    auto glideRender=[](int preset,float amount) {
        CodaDSP *d=coda_dsp_create();require(coda_dsp_prepare(d,48000,128),"prepare glide");
        auto c=controls(preset);c.glide=amount;require(coda_dsp_publish_controls(d,&c),"glide controls");
        const CodaNoteEvent events[]={{0,1,CODA_EVENT_ON,60,0,0},{1000,1,CODA_EVENT_OFF,60,0,0},
            {1000,2,CODA_EVENT_ON,72,0,0},{5000,2,CODA_EVENT_OFF,72,0,0}};
        for(const auto &event:events)require(coda_dsp_push_event(d,&event),"glide event");
        std::vector<float> samples(10000);for(size_t at=0;at<samples.size();at+=128) {
            uint32_t count=static_cast<uint32_t>(std::min<size_t>(128,samples.size()-at));require(coda_dsp_process(d,samples.data()+at,count),"glide process");
        }
        coda_dsp_destroy(d);return samples;
    };
    for(int preset=0;preset<3;preset++) {
      const auto noGlide=glideRender(preset,0), withGlide=glideRender(preset,1);double glideDelta=0;
      for(size_t i=0;i<noGlide.size();i++)glideDelta+=std::abs(noGlide[i]-withGlide[i]);
      require(glideDelta>0.01,"glide amount works for every preset");
    }
}
static void test_mute_tail() {
    CodaDSP *d=coda_dsp_create();require(coda_dsp_prepare(d,48000,256),"prepare mute");
    auto c=controls();c.delay_amount=1;c.reverb_amount=1;require(coda_dsp_publish_controls(d,&c),"mute controls");
    CodaNoteEvent on{0,2,CODA_EVENT_ON,60,0,0},off{64,2,CODA_EVENT_OFF,60,0,0};
    require(coda_dsp_push_event(d,&on)&&coda_dsp_push_event(d,&off),"mute event");
    float block[256];for(int i=0;i<120;i++)require(coda_dsp_process(d,block,256),"warm tails");
    c.muted=1;require(coda_dsp_publish_controls(d,&c),"mute publish");
    for(int i=0;i<20;i++)require(coda_dsp_process(d,block,256),"muted fade");
    float peak=0;for(float x:block)peak=std::max(peak,std::abs(x));require(peak<1e-5f,"muted output including tails");
    c.muted=0;require(coda_dsp_publish_controls(d,&c),"unmute publish");require(coda_dsp_process(d,block,256),"unmute render");
    peak=0;for(float x:block)peak=std::max(peak,std::abs(x));require(peak<1e-5f,"stale wet audio does not return");coda_dsp_destroy(d);
}
static void test_dense_voice_stealing() {
    CodaDSP *d=coda_dsp_create();require(coda_dsp_prepare(d,48000,128),"prepare dense");
    auto c=controls(CODA_PRESET_WOBBLE);c.glide=.5f;require(coda_dsp_publish_controls(d,&c),"dense controls");
    for(uint32_t i=0;i<24;i++){CodaNoteEvent e{static_cast<int64_t>(i/12),i/12+1,CODA_EVENT_ON,static_cast<uint8_t>(48+i),static_cast<uint8_t>(i%12),0};require(coda_dsp_push_event(d,&e),"dense onset");}
    float out[128];require(coda_dsp_process(d,out,64),"dense render");
    double energy=0;for(int i=0;i<64;i++){require(std::isfinite(out[i]),"dense finite");energy+=out[i]*out[i];}
    require(energy>0.001,"dense notes audible");
    for(uint32_t i=0;i<24;i++){CodaNoteEvent e{64,i/12+1,CODA_EVENT_OFF,static_cast<uint8_t>(48+i),static_cast<uint8_t>(i%12),0};require(coda_dsp_push_event(d,&e),"dense release");}
    require(coda_dsp_process(d,out,128),"dense release render");
    for(float x:out)require(std::isfinite(x),"dense release finite");coda_dsp_destroy(d);
}
static std::vector<float> render_progression(int preset,uint32_t block) {
    constexpr uint32_t rate=48000;
    CodaDSP *d=coda_dsp_create();require(d&&coda_dsp_prepare(d,rate,block),"prepare progression");
    auto c=controls(preset);c.wobble=.32f;c.warmth=.38f;require(coda_dsp_publish_controls(d,&c),"progression controls");
    const uint8_t chords[4][6]={{48,51,55,58,0,0},{44,48,51,55,0,0},{41,44,48,51,55,0},{43,47,51,53,56,58}};
    const uint8_t counts[4]={4,4,5,6};
    const double samplesPerBeat=rate*60.0/124.0;
    std::vector<CodaNoteEvent> events;
    for(uint32_t r=0;r<4;r++)for(uint8_t rank=0;rank<counts[r];rank++) {
        const uint32_t start=static_cast<uint32_t>(std::llround(r*4.0*samplesPerBeat));
        const uint32_t end=static_cast<uint32_t>(std::llround((r+1)*4.0*samplesPerBeat));
        CodaNoteEvent on{static_cast<int64_t>(start),r+1,CODA_EVENT_ON,chords[r][rank],rank,0};
        CodaNoteEvent off{static_cast<int64_t>(end),r+1,CODA_EVENT_OFF,chords[r][rank],rank,0};
        events.push_back(on);events.push_back(off);
    }
    std::sort(events.begin(),events.end(),[](const CodaNoteEvent &a,const CodaNoteEvent &b){
        if(a.sample_offset!=b.sample_offset)return a.sample_offset<b.sample_offset;
        if(a.kind!=b.kind)return a.kind<b.kind;
        if(a.voice_rank!=b.voice_rank)return a.voice_rank<b.voice_rank;
        return a.pitch<b.pitch;
    });
    for(const auto &event:events)require(coda_dsp_push_event(d,&event),"progression events");
    const uint32_t total=static_cast<uint32_t>(std::llround(16.0*samplesPerBeat))+static_cast<uint32_t>(rate*2.0);std::vector<float> out(total);uint32_t at=0;
    while(at<total){uint32_t n=std::min(block,total-at);require(coda_dsp_process(d,out.data()+at,n),"progression process");at+=n;}
    coda_dsp_destroy(d);return out;
}
#include "pass2_tests.h"
#include "performance_tests.h"

int main(int argc,char **argv) {
    test_performance();
    test_core(CODA_PRESET_PLUCK);test_core(CODA_PRESET_CURRENTS);test_core(CODA_PRESET_WOBBLE);
    test_release_and_events();test_pass2();test_validation_and_queue();test_controls_change_signal();test_control_endpoints_and_sample_rates();test_mute_tail();test_dense_voice_stealing();
    const char *names[]={"Pluck","Currents","Wobble"};
    for(int preset=0;preset<3;preset++) {
        auto wav=render_progression(preset,128);
        double rms=0;float peak=0;for(float x:wav){rms+=x*x;peak=std::max(peak,std::abs(x));}
        const double value=std::sqrt(rms/wav.size());
        std::printf("%s four-bar Cm7/Abmaj7/Fm9/G7alt peak=%.6f RMS=%.6f\n",names[preset],peak,value);
        if(argc>1){std::string path=std::string(argv[1])+"-"+names[preset]+".wav";write_wav(path.c_str(),wav);}
    }
    std::puts("DSP tests passed");
    return 0;
}
