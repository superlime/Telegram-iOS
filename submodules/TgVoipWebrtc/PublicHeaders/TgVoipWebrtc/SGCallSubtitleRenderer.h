#ifndef SGCallSubtitleRenderer_h
#define SGCallSubtitleRenderer_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: Swiftgram
/// Burns translated subtitles into the outgoing video.
///
/// The point of doing this in the capture path rather than as an overlay view
/// is that the remote party is the one who needs to read them — an overlay on
/// the local screen would show the subtitles to the only person who does not
/// need them.
///
/// Text is rasterised to an 8-bit coverage mask once per change and then
/// blended into the luma plane of each frame. Working in I420 directly avoids a
/// colour-space round trip per frame, and subtitles are white-on-shadow, which
/// is exactly what luma encodes.
@interface SGCallSubtitleRenderer : NSObject

@property (class, nonatomic, readonly, strong) SGCallSubtitleRenderer *shared;

/// Replace the visible subtitle lines, oldest first. Safe from any thread.
/// Pass an empty array to clear.
- (void)setLines:(NSArray<NSString *> *)lines;

- (BOOL)hasContent;

/// Blend the current subtitles into an I420 frame in place.
///
/// `rotation` is the WebRTC rotation the receiver will apply (0/90/180/270).
/// Text is pre-rotated by its inverse so it lands upright on their screen —
/// without this, subtitles appear sideways on every portrait call.
- (void)blendIntoY:(uint8_t *)dataY
           strideY:(int)strideY
                 u:(uint8_t *)dataU
           strideU:(int)strideU
                 v:(uint8_t *)dataV
           strideV:(int)strideV
             width:(int)width
            height:(int)height
          rotation:(int)rotation;

@end

NS_ASSUME_NONNULL_END

#endif /* SGCallSubtitleRenderer_h */
