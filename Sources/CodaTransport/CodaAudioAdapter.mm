#import "CodaAudioAdapter.h"
#import <AVFoundation/AVFoundation.h>
#include "RenderGate.h"
#include <atomic>
#include <memory>
#include <mutex>
#include <thread>
#include <cstring>
#include <cmath>
#include <algorithm>

namespace {
constexpr uint32_t manualBlock=512, maxOfflineFrames=48000*10;
using coda::RenderGate;
NSError *adapterError(NSString *text) {
    return [NSError errorWithDomain:@"CodaAudio" code:1 userInfo:@{NSLocalizedDescriptionKey:text}];
}
}
@implementation CodaAudioAdapter {
    std::mutex _producer;
    std::shared_ptr<RenderGate> _gate;
    AVAudioEngine *_engine;
    AVAudioSourceNode *_source;
    double _sampleRate;
    BOOL _offline;
    BOOL _sessionActive;
}
- (NSObject *)configurationOwner {std::lock_guard<std::mutex> lock(_producer); return _engine;}
- (BOOL)configurationInvalidated {
    std::lock_guard<std::mutex> lock(_producer);
    if(!_engine) return NO;
    // Configuration notifications can arrive after startup has already settled.
    // Only invalidate this live adapter if the engine stopped or its negotiated
    // output rate no longer matches the prepared transport. Never reopen here.
    return !_engine.isRunning || (!_offline &&
        [_engine.outputNode outputFormatForBus:0].sampleRate!=_sampleRate);
}
- (double)sampleRate {std::lock_guard<std::mutex> lock(_producer); return _sampleRate;}
- (void)closeLocked {
    // Producer mutex excludes ALL publications and lifecycle methods. Closing
    // the gate atomically excludes new render entries, then joins existing ones.
    // Engine stop/pause is deliberately not used as proof of quiescence.
    if(_gate) _gate->close();
    [_engine stop];
    if(_source) [_engine detachNode:_source];
    _source=nil; _engine=nil;
    if(_gate) {coda_transport_destroy(_gate->transport); _gate->transport=nullptr;}
    _gate.reset(); _sampleRate=0;
    if(_sessionActive) {
        [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
        _sessionActive=NO;
    }
}
- (void)close {std::lock_guard<std::mutex> lock(_producer); [self closeLocked];}
- (void)dealloc {[self close];}
- (BOOL)openOffline:(BOOL)offline error:(NSError **)error {
    std::lock_guard<std::mutex> lock(_producer);
    [self closeLocked]; _offline=offline;
    if(!offline) {
        AVAudioSession *session=[AVAudioSession sharedInstance];
        if(![session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:error] ||
           ![session setActive:YES error:error]) return NO;
        _sessionActive=YES;
    }
    _engine=[AVAudioEngine new];
    double rate=offline?48000:[_engine.outputNode outputFormatForBus:0].sampleRate;
    if(!std::isfinite(rate) || rate<8000 || rate>384000) {
        if(error) *error=adapterError(@"Output audio format unavailable"); [self closeLocked]; return NO;
    }
    AVAudioFormat *format=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:1];
    _gate=std::make_shared<RenderGate>();
    _gate->transport=coda_transport_create();
    if(!_gate->transport || !coda_transport_prepare(_gate->transport,rate)) {
        if(error) *error=adapterError(@"Audio preparation failed"); [self closeLocked]; return NO;
    }
    // C++ shared ownership is copied ONLY while constructing/copying/destroying
    // the framework block. Invocation accesses it by const reference; no ARC,
    // shared_ptr copies, Objective-C messaging or Swift call inside the block.
    const auto gate=_gate;
    _source=[[AVAudioSourceNode alloc] initWithFormat:format renderBlock:
        ^OSStatus(BOOL *silence,const AudioTimeStamp *,AVAudioFrameCount frames,AudioBufferList *buffers) {
            if(!gate->enter()) {
                for(UInt32 b=0;b<buffers->mNumberBuffers;++b)
                    if(buffers->mBuffers[b].mData) std::memset(buffers->mBuffers[b].mData,0,buffers->mBuffers[b].mDataByteSize);
                *silence=YES; return noErr;
            }
            // Explicit mono/noninterleaved source format. Reject unexpected
            // layout rather than writing beyond framework-owned storage.
            if(buffers->mNumberBuffers!=1 || buffers->mBuffers[0].mNumberChannels!=1 ||
               !buffers->mBuffers[0].mData || buffers->mBuffers[0].mDataByteSize<frames*sizeof(float)) {
                gate->leave(); return kAudio_ParamError;
            }
            coda_transport_render(gate->transport,static_cast<float *>(buffers->mBuffers[0].mData),frames);
            *silence=NO; gate->leave(); return noErr;
        }];
    [_engine attachNode:_source];
    [_engine connect:_source to:_engine.mainMixerNode format:format];
    if(offline && ![_engine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline
        format:format maximumFrameCount:manualBlock error:error]) {[self closeLocked]; return NO;}
    _sampleRate=rate; _gate->state.store(0,std::memory_order_release); return YES;
}
- (BOOL)startWithError:(NSError **)error {
    std::lock_guard<std::mutex> lock(_producer);
    if(!_engine) {if(error) *error=adapterError(@"Audio is not open"); return NO;}
    if(![_engine startAndReturnError:error]) {[self closeLocked]; return NO;}
    return YES;
}
- (int)publishPlan:(const CodaPlan *)plan {
    std::lock_guard<std::mutex> lock(_producer);
    return _gate?coda_transport_publish(_gate->transport,plan):-1;
}
- (int)publishPerformancePlan:(const CodaPerformancePlan *)plan generation:(uint64_t *)generation {
    std::lock_guard<std::mutex> lock(_producer);
    return _gate?coda_transport_publish_performance(_gate->transport,plan,generation):-1;
}
- (int)enqueuePerformanceCycle:(const CodaPerformanceCycle *)cycle generation:(uint64_t)generation {
    std::lock_guard<std::mutex> lock(_producer);
    return _gate?coda_transport_enqueue_performance_cycle(_gate->transport,generation,cycle):-1;
}
- (CodaPerformanceStatus)performanceStatus {
    std::lock_guard<std::mutex> lock(_producer); CodaPerformanceStatus s{};
    if(_gate) coda_transport_performance_status(_gate->transport,&s); return s;
}
- (int)publishControls:(const CodaControls *)controls {
    std::lock_guard<std::mutex> lock(_producer);
    return _gate?coda_transport_controls(_gate->transport,controls):-1;
}
- (int)auditionPitches:(const uint8_t *)pitches count:(uint32_t)count frames:(uint32_t)frames {
    std::lock_guard<std::mutex> lock(_producer);
    return _gate?coda_transport_audition(_gate->transport,pitches,count,frames):-1;
}
- (CodaTransportStatus)transportStatus {
    std::lock_guard<std::mutex> lock(_producer); CodaTransportStatus s{};
    if(_gate) coda_transport_status(_gate->transport,&s); return s;
}
- (BOOL)renderOfflineFrames:(uint32_t)frames energy:(double *)energy error:(NSError **)error {
    std::lock_guard<std::mutex> lock(_producer);
    if(!_engine || !_offline || !frames || frames>maxOfflineFrames) {
        if(error) *error=adapterError(@"Invalid offline render request"); return NO;
    }
    AVAudioPCMBuffer *buffer=[[AVAudioPCMBuffer alloc] initWithPCMFormat:_engine.manualRenderingFormat frameCapacity:manualBlock];
    *energy=0;
    for(uint32_t at=0;at<frames;) {
        const auto n=std::min(manualBlock,frames-at);
        if([_engine renderOffline:n toBuffer:buffer error:error]!=AVAudioEngineManualRenderingStatusSuccess) {
            if(error && !*error) *error=adapterError(@"Manual render did not succeed"); return NO;
        }
        for(uint32_t i=0;i<buffer.frameLength;++i) {
            const double x=buffer.floatChannelData[0][i];
            if(!std::isfinite(x)) {if(error) *error=adapterError(@"Nonfinite audio"); return NO;}
            *energy+=x*x;
        }
        if(buffer.frameLength!=n) {if(error) *error=adapterError(@"Short manual render"); return NO;}
        at+=n;
    }
    return YES;
}
@end
