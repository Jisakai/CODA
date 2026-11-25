#import <XCTest/XCTest.h>
#import "CodaAudioAdapter.h"

@interface AudioAdapterTests : XCTestCase
@end
@implementation AudioAdapterTests
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
