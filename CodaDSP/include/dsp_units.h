#ifndef CODA_DSP_UNITS_H
#define CODA_DSP_UNITS_H
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
namespace coda {
constexpr double pi=3.14159265358979323846;
constexpr float muteSeconds=0.012f;
inline float clean(float x) noexcept { return std::abs(x)<1.e-20f?0.f:x; }
enum class Stage : uint8_t { idle, attack, decay, sustain, release };
struct Envelope {
    Stage stage=Stage::idle;
    double level=0, releaseStart=0, releaseProgress=0;
    void on() noexcept { stage=Stage::attack; level=0; releaseProgress=0; }
    void off() noexcept {
        if(stage!=Stage::idle && stage!=Stage::release) {
            stage=Stage::release; releaseStart=level; releaseProgress=0;
        }
    }
    float tick(double rate, double attack, double decay, double sustain, double release) noexcept {
        switch(stage) {
        case Stage::attack:
            level=std::min(1.0,level+1.0/std::max(1.0,attack*rate));
            if(level>=1.0) stage=Stage::decay;
            break;
        case Stage::decay:
            level=std::max(sustain,level-(1.0-sustain)/std::max(1.0,decay*rate));
            if(level<=sustain) stage=sustain>0?Stage::sustain:Stage::idle;
            break;
        case Stage::sustain: level=sustain; break;
        case Stage::release:
            releaseProgress=std::min(1.0,releaseProgress+1.0/std::max(1.0,release*rate));
            level=releaseStart*(1.0-releaseProgress);
            if(releaseProgress>=1.0) {level=0;stage=Stage::idle;}
            break;
        case Stage::idle: level=0; break;
        }
        return static_cast<float>(level);
    }
};
// RBJ Audio EQ Cookbook, normalized direct form II transposed; coefficients
// prepared outside render. Double state avoids near-DC cancellation loss.
struct Biquad {
    double b0=1,b1=0,b2=0,a1=0,a2=0,z1=0,z2=0;
    void reset() noexcept {z1=z2=0;}
    float tick(float x) noexcept {
        double y=b0*x+z1;
        z1=b1*x-a1*y+z2;z2=b2*x-a2*y;
        if(std::abs(z1)<1.e-20)z1=0;
        if(std::abs(z2)<1.e-20)z2=0;
        return static_cast<float>(y);
    }
    void set(double B0,double B1,double B2,double A0,double A1,double A2) {
        b0=B0/A0;b1=B1/A0;b2=B2/A0;a1=A1/A0;a2=A2/A0;reset();
    }
    void pass(double rate,double hz,bool high) {
        double w=2*pi*std::min(hz,rate*.42)/rate,c=std::cos(w),s=std::sin(w),a=s/(2*std::sqrt(.5));
        double b=(1+(high?c:-c))*.5;
        set(b,(high?-2:2)*b,b,1+a,-2*c,1-a);
    }
    void peak(double rate,double hz,double db,double q) {
        double w=2*pi*std::min(hz,rate*.42)/rate,c=std::cos(w),a=std::sin(w)/(2*q),A=std::pow(10,db/40);
        set(1+a*A,-2*c,1-a*A,1+a/A,-2*c,1-a/A);
    }
    void shelf(double rate,double hz,double db) {
        double w=2*pi*std::min(hz,rate*.42)/rate,c=std::cos(w),A=std::pow(10,db/40);
        double t=std::sin(w)*std::sqrt(2*A);
        set(A*((A+1)+(A-1)*c+t),-2*A*((A-1)+(A+1)*c),A*((A+1)+(A-1)*c-t),
            (A+1)-(A-1)*c+t,2*((A-1)-(A+1)*c),(A+1)-(A-1)*c-t);
    }
};
struct ChordsEQ {
    Biquad hp,lp;
    void prepare(double rate){hp.pass(rate,120,true);lp.pass(rate,9000,false);}
    void reset() noexcept {hp.reset();lp.reset();}
    float tick(float x) noexcept {return lp.tick(hp.tick(x));}
};
struct BassEQ {
    Biquad hp,lp;
    void prepare(double rate){hp.pass(rate,35,true);lp.pass(rate,2500,false);}
    void reset() noexcept {hp.reset();lp.reset();}
    float tick(float x) noexcept {return lp.tick(hp.tick(x));}
};
struct MelodyEQ {
    Biquad hp,dip;
    void prepare(double rate){hp.pass(rate,200,true);dip.peak(rate,3000,-2.5,0.85);}
    void reset() noexcept {hp.reset();dip.reset();}
    float tick(float x) noexcept {return dip.tick(hp.tick(x));}
};
struct MasterEQ {
    Biquad shelf,dip;
    void prepare(double rate){shelf.shelf(rate,9000,-3);dip.peak(rate,3000,-2,0.85);}
    void reset() noexcept {shelf.reset();dip.reset();}
    float tick(float sum) noexcept {return dip.tick(shelf.tick(sum));}
};
// Four-line modulated orthogonal Hadamard FDN, ~2.9 s warm RT60. Two Schroeder
// allpasses diffuse the predelayed input, with gentle LFO delay-line modulation
// to eliminate metallic ringing and a pre-HPF to keep low-end clean. Memory and
// generation tags are owned by CodaDSP; reset invalidates in O(1), never clears
// a delay line in render.
struct Hall {
    std::array<float,4>* lines=nullptr; uint64_t* tags=nullptr;
    float* pre=nullptr; uint64_t* preTags=nullptr;
    uint32_t size=0,preSize=0,write=0,preWrite=0,preTap=0,taps[4]{};
    uint64_t generation=1;
    float damping=0,lp[4]{},feedback[4]{};
    float hpCoeff=0,hpState=0,modPhase[4]{},modInc[4]{},modDepth=0;
    std::array<std::array<float,4096>,2> diffusion{};
    std::array<std::array<uint64_t,4096>,2> diffusionTags{};
    uint32_t diffWrite[2]{},diffTap[2]{};
    void prepare(double rate,std::array<float,4>* l,uint64_t* t,uint32_t n,float* p,uint64_t* pt,uint32_t pn) {
        lines=l;tags=t;size=n;pre=p;preTags=pt;preSize=pn;
        // Newly bound rings/tap lengths cannot reuse cursors from a prior rate.
        write=preWrite=0;diffWrite[0]=diffWrite[1]=0;
        constexpr double times[]={.0297,.0371,.0411,.0533};
        constexpr double lfoHz[]={0.31,0.43,0.57,0.71};
        for(int i=0;i<4;i++) {
            taps[i]=static_cast<uint32_t>(rate*times[i]);
            feedback[i]=static_cast<float>(std::pow(.001,taps[i]/(rate*2.85)));
            modInc[i]=static_cast<float>(2*pi*lfoHz[i]/rate);
        }
        modDepth=static_cast<float>(std::min(12.0,rate*0.00022));
        preTap=static_cast<uint32_t>(rate*.020);
        diffTap[0]=std::max(1u,static_cast<uint32_t>(rate*.0047));diffTap[1]=std::max(1u,static_cast<uint32_t>(rate*.0061));
        damping=static_cast<float>(1-std::exp(-2*pi*3200/rate));
        hpCoeff=static_cast<float>(1-std::exp(-2*pi*160/rate));
        reset();
    }
    void reset() noexcept {
        ++generation;
        for(auto &x:lp)x=0;
        hpState=0;
        for(auto &p:modPhase)p=0;
    }
    float tick(float input) noexcept {
        uint32_t r=(preWrite+preSize-preTap)%preSize;
        float x=preTags[r]==generation?pre[r]:0;
        pre[preWrite]=input;preTags[preWrite]=generation;preWrite=(preWrite+1)%preSize;
        // Gentle input HPF keeps bass/sub energy from muddying the hall tail.
        hpState=clean(hpState+hpCoeff*(x-hpState));
        x-=hpState;
        for(int i=0;i<2;i++) {
            uint32_t at=diffWrite[i];float delayed=diffusionTags[i][at]==generation?diffusion[i][at]:0;
            float y=delayed-.62f*x;diffusion[i][at]=clean(x+.62f*y);diffusionTags[i][at]=generation;
            diffWrite[i]=(at+1)%diffTap[i];x=y;
        }
        float v[4];
        for(int i=0;i<4;i++) {
            modPhase[i]+=modInc[i];
            if(modPhase[i]>=static_cast<float>(2*pi)) modPhase[i]-=static_cast<float>(2*pi);
            float tapF=static_cast<float>(taps[i])+modDepth*std::sin(modPhase[i]);
            if(tapF<1.f) tapF=1.f;
            if(tapF>static_cast<float>(size-2)) tapF=static_cast<float>(size-2);
            uint32_t tap0=static_cast<uint32_t>(tapF);
            float frac=tapF-static_cast<float>(tap0);
            uint32_t at0=(write+size-tap0)%size;
            uint32_t at1=(at0+size-1)%size;
            float y0=tags[at0]==generation?lines[at0][i]:0;
            float y1=tags[at1]==generation?lines[at1][i]:0;
            float y=y0+(y1-y0)*frac;
            lp[i]=clean(lp[i]+damping*(y-lp[i]));v[i]=lp[i]*feedback[i];
        }
        const float h[4]={(v[0]+v[1]+v[2]+v[3])*.5f,(v[0]-v[1]+v[2]-v[3])*.5f,
                         (v[0]+v[1]-v[2]-v[3])*.5f,(v[0]-v[1]-v[2]+v[3])*.5f};
        for(int i=0;i<4;i++)lines[write][i]=clean(h[i]+x*.25f);
        tags[write]=generation;write=(write+1)%size;
        return (v[0]+v[1]+v[2]+v[3])*.25f;
    }
};
}
#endif
