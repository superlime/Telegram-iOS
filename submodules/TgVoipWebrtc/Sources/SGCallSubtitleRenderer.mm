#import <TgVoipWebrtc/SGCallSubtitleRenderer.h>

#import <TargetConditionals.h>
#import <os/lock.h>

#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#endif

// MARK: Swiftgram

/// Cached rasterisation of one particular (text, size, rotation) combination.
@interface SGSubtitleMask : NSObject
@property (nonatomic, strong) NSArray<NSString *> *lines;
@property (nonatomic, assign) int width;
@property (nonatomic, assign) int height;
@property (nonatomic, assign) int rotation;
/// 8-bit coverage, `width` * `height`, laid out in frame-buffer space.
@property (nonatomic, assign) uint8_t *coverage;
@end

@implementation SGSubtitleMask
- (void)dealloc {
    if (_coverage != NULL) {
        free(_coverage);
        _coverage = NULL;
    }
}
@end

@interface SGCallSubtitleRenderer () {
    os_unfair_lock _lock;
    NSArray<NSString *> *_lines;
    SGSubtitleMask *_mask;
}
@end

@implementation SGCallSubtitleRenderer

+ (SGCallSubtitleRenderer *)shared {
    static SGCallSubtitleRenderer *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SGCallSubtitleRenderer alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _lines = @[];
    }
    return self;
}

- (void)setLines:(NSArray<NSString *> *)lines {
    NSArray<NSString *> *copied = [lines copy] ?: @[];
    os_unfair_lock_lock(&_lock);
    if (![_lines isEqualToArray:copied]) {
        _lines = copied;
        // Drop the cache; the next frame re-rasterises.
        _mask = nil;
    }
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)hasContent {
    os_unfair_lock_lock(&_lock);
    BOOL result = _lines.count > 0;
    os_unfair_lock_unlock(&_lock);
    return result;
}

- (void)blendIntoY:(uint8_t *)dataY
           strideY:(int)strideY
                 u:(uint8_t *)dataU
           strideU:(int)strideU
                 v:(uint8_t *)dataV
           strideV:(int)strideV
             width:(int)width
            height:(int)height
          rotation:(int)rotation {
    if (dataY == NULL || width <= 0 || height <= 0) {
        return;
    }

    os_unfair_lock_lock(&_lock);
    NSArray<NSString *> *lines = _lines;
    SGSubtitleMask *mask = _mask;
    if (lines.count == 0) {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    BOOL needsRender = (mask == nil
                        || mask.width != width
                        || mask.height != height
                        || mask.rotation != rotation
                        || ![mask.lines isEqualToArray:lines]);
    os_unfair_lock_unlock(&_lock);

    if (needsRender) {
        SGSubtitleMask *rendered = [self renderMaskForLines:lines width:width height:height rotation:rotation];
        os_unfair_lock_lock(&_lock);
        // Only install if the text has not changed underneath us.
        if ([_lines isEqualToArray:lines]) {
            _mask = rendered;
        }
        mask = rendered;
        os_unfair_lock_unlock(&_lock);
    }

    if (mask == nil || mask.coverage == NULL) {
        return;
    }

    const uint8_t *coverage = mask.coverage;
    // Rec.601 studio range: 235 is white, 128 is neutral chroma. Pushing U and V
    // toward neutral in proportion to coverage keeps the text white instead of
    // letting it take on the tint of whatever is behind it.
    for (int y = 0; y < height; y++) {
        const uint8_t *maskRow = coverage + (size_t)y * (size_t)width;
        uint8_t *rowY = dataY + (size_t)y * (size_t)strideY;
        for (int x = 0; x < width; x++) {
            const uint8_t a = maskRow[x];
            if (a == 0) {
                continue;
            }
            // Coverage encodes both the glyph (bright) and its shadow (dark):
            // values above 128 paint toward white, below toward black.
            int target = (a > 128) ? 235 : 16;
            int alpha = (a > 128) ? (a - 128) * 2 : (128 - a) * 2;
            if (alpha > 255) {
                alpha = 255;
            }
            rowY[x] = (uint8_t)((rowY[x] * (255 - alpha) + target * alpha) / 255);
        }
    }

    if (dataU != NULL && dataV != NULL) {
        const int chromaWidth = (width + 1) / 2;
        const int chromaHeight = (height + 1) / 2;
        for (int y = 0; y < chromaHeight; y++) {
            const uint8_t *maskRow = coverage + (size_t)(y * 2) * (size_t)width;
            uint8_t *rowU = dataU + (size_t)y * (size_t)strideU;
            uint8_t *rowV = dataV + (size_t)y * (size_t)strideV;
            for (int x = 0; x < chromaWidth; x++) {
                const uint8_t a = maskRow[x * 2];
                if (a == 0) {
                    continue;
                }
                int alpha = (a > 128) ? (a - 128) * 2 : (128 - a) * 2;
                if (alpha > 255) {
                    alpha = 255;
                }
                rowU[x] = (uint8_t)((rowU[x] * (255 - alpha) + 128 * alpha) / 255);
                rowV[x] = (uint8_t)((rowV[x] * (255 - alpha) + 128 * alpha) / 255);
            }
        }
    }
}

/// Rasterise the subtitle block into frame-buffer space.
///
/// The frame buffer is stored pre-rotation, so the text is drawn into a canvas
/// oriented the way the *viewer* will see it and then mapped back through the
/// rotation. Otherwise every portrait call shows subtitles running up the side.
- (SGSubtitleMask *)renderMaskForLines:(NSArray<NSString *> *)lines
                                 width:(int)width
                                height:(int)height
                              rotation:(int)rotation {
#if !TARGET_OS_IOS
    // Text rasterisation here is UIKit-based. The macOS build of tgcalls does
    // not carry this feature, so it degrades to drawing nothing rather than
    // failing to compile.
    return nil;
#else
    const BOOL swapsAxes = (rotation == 90 || rotation == 270);
    const int canvasWidth = swapsAxes ? height : width;
    const int canvasHeight = swapsAxes ? width : height;
    if (canvasWidth <= 0 || canvasHeight <= 0) {
        return nil;
    }

    const CGFloat fontSize = MAX(12.0, floor(canvasHeight * 0.038));
    UIFont *font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightSemibold];
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = NSTextAlignmentCenter;
    paragraph.lineBreakMode = NSLineBreakByWordWrapping;

    // Drawn as a grey ramp, not colour: 255 is glyph, 0 is shadow, 128 is
    // "leave the frame alone". blendIntoY reads it back with that meaning.
    NSDictionary *glyphAttributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:1.0],
        NSParagraphStyleAttributeName: paragraph
    };
    NSDictionary *shadowAttributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: [UIColor colorWithWhite:0.0 alpha:1.0],
        NSParagraphStyleAttributeName: paragraph
    };

    NSString *text = [lines componentsJoinedByString:@"\n"];
    const CGFloat horizontalInset = floor(canvasWidth * 0.06);
    const CGFloat bottomInset = floor(canvasHeight * 0.07);
    const CGFloat maxTextWidth = canvasWidth - horizontalInset * 2.0;
    if (maxTextWidth <= 0.0) {
        return nil;
    }

    CGRect bounds = [text boundingRectWithSize:CGSizeMake(maxTextWidth, canvasHeight * 0.5)
                                       options:(NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading)
                                    attributes:glyphAttributes
                                       context:nil];
    const CGFloat textHeight = ceil(bounds.size.height);
    if (textHeight <= 0.0) {
        return nil;
    }
    const CGRect textRect = CGRectMake(horizontalInset,
                                       canvasHeight - bottomInset - textHeight,
                                       maxTextWidth,
                                       textHeight);

    const size_t canvasBytes = (size_t)canvasWidth * (size_t)canvasHeight;
    uint8_t *canvas = (uint8_t *)calloc(canvasBytes, 1);
    if (canvas == NULL) {
        return nil;
    }
    // 128 means "no change" to the blend.
    memset(canvas, 128, canvasBytes);

    CGColorSpaceRef grey = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(canvas,
                                                 (size_t)canvasWidth,
                                                 (size_t)canvasHeight,
                                                 8,
                                                 (size_t)canvasWidth,
                                                 grey,
                                                 (CGBitmapInfo)kCGImageAlphaNone);
    CGColorSpaceRelease(grey);
    if (context == NULL) {
        free(canvas);
        return nil;
    }

    UIGraphicsPushContext(context);
    // CoreGraphics is bottom-left origin; UIKit text drawing expects top-left.
    CGContextTranslateCTM(context, 0.0, canvasHeight);
    CGContextScaleCTM(context, 1.0, -1.0);

    // Shadow first, offset in each direction, so white text stays legible over
    // a bright background — which on a video call is most of the time.
    const CGFloat outline = MAX(1.0, floor(fontSize * 0.08));
    for (CGFloat dx = -outline; dx <= outline; dx += outline) {
        for (CGFloat dy = -outline; dy <= outline; dy += outline) {
            if (dx == 0.0 && dy == 0.0) {
                continue;
            }
            [text drawInRect:CGRectOffset(textRect, dx, dy) withAttributes:shadowAttributes];
        }
    }
    [text drawInRect:textRect withAttributes:glyphAttributes];
    UIGraphicsPopContext();
    CGContextRelease(context);

    // Map the canvas into frame-buffer space.
    uint8_t *coverage = (uint8_t *)malloc((size_t)width * (size_t)height);
    if (coverage == NULL) {
        free(canvas);
        return nil;
    }
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            int cx, cy;
            switch (rotation) {
                case 90:
                    // The viewer rotates the frame 90 clockwise to display it,
                    // so display(x', y') = buffer(x, y) with x' = H-1-y, y' = x.
                    // Inverting that gives the canvas coordinate for this pixel.
                    // Getting this backwards puts the subtitles upside down at
                    // the top of the remote party's screen, which is why it is
                    // spelled out rather than eyeballed.
                    cx = canvasWidth - 1 - y;
                    cy = x;
                    break;
                case 180:
                    cx = canvasWidth - 1 - x;
                    cy = canvasHeight - 1 - y;
                    break;
                case 270:
                    cx = y;
                    cy = canvasHeight - 1 - x;
                    break;
                default:
                    cx = x;
                    cy = y;
                    break;
            }
            uint8_t value = 128;
            if (cx >= 0 && cx < canvasWidth && cy >= 0 && cy < canvasHeight) {
                value = canvas[(size_t)cy * (size_t)canvasWidth + (size_t)cx];
            }
            // 128 means untouched; store 0 there so the blend can skip fast.
            coverage[(size_t)y * (size_t)width + (size_t)x] = (value == 128) ? 0 : value;
        }
    }
    free(canvas);

    SGSubtitleMask *mask = [[SGSubtitleMask alloc] init];
    mask.lines = lines;
    mask.width = width;
    mask.height = height;
    mask.rotation = rotation;
    mask.coverage = coverage;
    return mask;
#endif
}

@end
