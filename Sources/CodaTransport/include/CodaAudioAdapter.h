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
- (int)publishControls:(const CodaControls *)controls NS_SWIFT_NAME(publish(controls:));
- (int)auditionPitches:(const uint8_t * _Nullable)pitches count:(uint32_t)count frames:(uint32_t)frames NS_SWIFT_NAME(audition(pitches:count:frames:));
- (CodaTransportStatus)transportStatus;
/* Bounded actual AVAudioEngine manual rendering; no hardware or timer. */
- (BOOL)renderOfflineFrames:(uint32_t)frames energy:(double *)energy error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(renderOffline(frames:energy:));
@end
NS_ASSUME_NONNULL_END
