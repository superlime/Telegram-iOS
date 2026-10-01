#ifndef SGCallVideoLimits_h
#define SGCallVideoLimits_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: Swiftgram
/// Process-wide ceilings on the outgoing call video, used to keep a phone cool
/// on long video calls.
///
/// Swift sets these from the user's settings and the device thermal state (see
/// SGCallThermal). They are read by the vendored capturer (capture format, frame
/// rate, I420 downscale), by the vendored DarwinInterface (adaptation request)
/// and by its encoder wrapper (bitrate). A value of 0 means "no limit", which is
/// stock Telegram behaviour.
///
/// Every property is safe to read from any thread. Reads are a single atomic
/// load, so the capture path can check them once per frame.
@interface SGCallVideoLimits : NSObject

@property (class, nonatomic, readonly, strong) SGCallVideoLimits *shared;

/// Largest short side of the outgoing video in pixels, or 0.
@property (nonatomic, readonly) int32_t maxShortSide;
/// Highest outgoing frame rate, or 0.
@property (nonatomic, readonly) int32_t maxFps;
/// Highest total encoder bitrate in kbit/s, or 0.
@property (nonatomic, readonly) int32_t maxBitrateKbps;
/// Incremented whenever any limit changes. The capturer compares it per frame
/// to notice that the camera has to be reconfigured.
@property (nonatomic, readonly) int64_t generation;

/// Replace all three limits at once. Does nothing (and does not bump
/// `generation`) when the values are unchanged.
- (void)setMaxShortSide:(int32_t)maxShortSide maxFps:(int32_t)maxFps maxBitrateKbps:(int32_t)maxBitrateKbps;

@end

NS_ASSUME_NONNULL_END

#endif /* SGCallVideoLimits_h */
