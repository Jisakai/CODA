#import <Foundation/Foundation.h>
#import "coda_transport.h"
NS_ASSUME_NONNULL_BEGIN
/* Every method is control-side, serialized internally. Never called by render.
   The source block captures only native gate storage, never this Objective-C owner. */
@interface CodaAudioAdapter : NSObject
@property(nonatomic, readonly) double sampleRate;
/* Identity for object-scoped engine configuration notifications; control only. */
@property(nonatomic, readonly, nullable) NSObject *configurationOwner;
@property(nonatomic, readonly) BOOL configurationInvalidated;
- (BOOL)openOffline:(BOOL)offline error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(open(offline:));
- (BOOL)startWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(start());
- (void)close;
- (int)publishPlan:(const CodaPlan *)plan NS_SWIFT_NAME(publish(plan:));
- (int)publishPlan:(const CodaPlan *)plan generation:(uint64_t *)generation NS_SWIFT_NAME(publish(plan:generation:));
- (int)publishPerformancePlan:(const CodaPerformancePlan *)plan generation:(uint64_t *)generation NS_SWIFT_NAME(publish(performancePlan:generation:));
- (int)enqueuePerformanceCycle:(const CodaPerformanceCycle *)cycle generation:(uint64_t)generation NS_SWIFT_NAME(enqueue(performanceCycle:generation:));
- (CodaPerformanceStatus)performanceStatus;
- (int)publishControls:(const CodaControls *)controls NS_SWIFT_NAME(publish(controls:));
- (int)publishMixerControls:(CodaMixerControls)controls NS_SWIFT_NAME(publish(mixerControls:));
- (int)publishTrackControls:(CodaLayerControls)controls forTrack:(uint8_t)trackIndex eqProfile:(uint8_t)eqProfile NS_SWIFT_NAME(publish(trackControls:forTrack:eqProfile:));
- (int)auditionPitches:(const uint8_t * _Nullable)pitches count:(uint32_t)count frames:(uint32_t)frames NS_SWIFT_NAME(audition(pitches:count:frames:));
- (int)auditionLayer:(uint8_t)layer pitches:(const uint8_t * _Nullable)pitches count:(uint32_t)count frames:(uint32_t)frames NS_SWIFT_NAME(audition(layer:pitches:count:frames:));
- (CodaTransportStatus)transportStatus;
/* Bounded actual AVAudioEngine manual rendering; no hardware or timer. */
- (BOOL)renderOfflineFrames:(uint32_t)frames energy:(double *)energy error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(renderOffline(frames:energy:));
/* Renders stereo interleaved Float32 PCM frames offline for WAV bounce. */
- (nullable NSData *)renderOfflineStereoFloatFrames:(uint32_t)frames error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(renderOfflineStereoFloat(frames:));
@end
NS_ASSUME_NONNULL_END
