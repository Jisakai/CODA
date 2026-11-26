#import <XCTest/XCTest.h>
#import "CodaAudioAdapter.h"
#include <memory>

@interface AudioAdapterTests : XCTestCase
@end
@implementation AudioAdapterTests
- (void)testPerformancePublicationLifecycleAndActualOfflineAudio {
    CodaAudioAdapter *adapter=[CodaAudioAdapter new];NSError *error=nil;
    auto storage=std::make_unique<CodaPerformancePlan>();auto &p=*storage;
    p.playback_revision=1;p.samples_per_step=6000;p.length=16;p.playing=1;
    auto &c=p.initial_cycle;c.sample_count=96000;c.count=2;
    auto &on=c.events[0];on.owner.instance=1;on.harmonic_token=1;on.kind=1;
    on.pitch=60;on.base_velocity=on.effective_velocity=.8f;
    c.events[1]=on;c.events[1].kind=0;c.events[1].sample_offset=24000;
    uint64_t generation=99;
    XCTAssertEqual([adapter publishPerformancePlan:&p generation:&generation],-1);
    XCTAssertEqual(generation,99u);
    XCTAssertEqual([adapter enqueuePerformanceCycle:&c generation:generation],-1);
    XCTAssertEqual([adapter performanceStatus].generation,0u);
    for(int iteration=0;iteration<2;++iteration) {
        XCTAssertTrue([adapter openOffline:YES error:&error],@"%@",error);
        XCTAssertEqual([adapter publishPerformancePlan:&p generation:&generation],1);
        XCTAssertTrue([adapter startWithError:&error],@"%@",error);
        double energy=0;
        XCTAssertTrue([adapter renderOfflineFrames:48000 energy:&energy error:&error],@"%@",error);
        XCTAssertGreaterThan(energy,.001);
        XCTAssertEqual([adapter performanceStatus].applied_generation,generation);
        XCTAssertEqual([adapter transportStatus].delivered,2u);
        [adapter close];[adapter close];
        XCTAssertEqual([adapter publishPerformancePlan:&p generation:&generation],-1);
        XCTAssertEqual([adapter enqueuePerformanceCycle:&c generation:generation],-1);
        XCTAssertEqual([adapter performanceStatus].generation,0u);
    }
}

- (void)testActualSourceNodeOfflineRenderAndRepeatedTeardown {
    for(int iteration=0;iteration<3;++iteration) {
        CodaAudioAdapter *adapter=[CodaAudioAdapter new]; NSError *error=nil;
        XCTAssertTrue([adapter openOffline:YES error:&error],@"%@",error);
        XCTAssertEqual(adapter.sampleRate,48000);
        CodaPlan plan{}; plan.playback_revision=1; plan.samples_per_step=6000; plan.length=16; plan.playing=1; plan.count=6;
        for(uint8_t r=0;r<3;++r) {
            plan.events[r]={0,0,1,uint8_t(60+r*3),r,0};
            plan.events[r+3]={4,0,0,uint8_t(60+r*3),r,0};
        }
        XCTAssertEqual([adapter publishPlan:&plan],1);
        XCTAssertTrue([adapter startWithError:&error],@"%@",error);
        double energy=0;
        XCTAssertTrue([adapter renderOfflineFrames:48000 energy:&energy error:&error],@"%@",error);
        XCTAssertGreaterThan(energy,0.001);
        auto status=[adapter transportStatus];
        XCTAssertEqual(status.delivered,6); XCTAssertEqual(status.late,0); XCTAssertEqual(status.failures,0);
        [adapter close]; [adapter close];
        XCTAssertEqual([adapter publishPlan:&plan],-1);
        XCTAssertTrue([adapter openOffline:YES error:&error],@"%@",error);
        XCTAssertTrue([adapter startWithError:&error],@"%@",error);
        XCTAssertTrue([adapter renderOfflineFrames:1024 energy:&energy error:&error],@"%@",error);
        XCTAssertEqual(energy,0);
        [adapter close];
    }
}
@end
