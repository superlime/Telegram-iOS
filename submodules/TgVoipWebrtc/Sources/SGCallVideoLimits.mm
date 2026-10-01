#import <TgVoipWebrtc/SGCallVideoLimits.h>

#include <atomic>

// MARK: Swiftgram

@interface SGCallVideoLimits () {
    std::atomic<int32_t> _maxShortSide;
    std::atomic<int32_t> _maxFps;
    std::atomic<int32_t> _maxBitrateKbps;
    std::atomic<int64_t> _generation;
}
@end

@implementation SGCallVideoLimits

+ (SGCallVideoLimits *)shared {
    static SGCallVideoLimits *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SGCallVideoLimits alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _maxShortSide.store(0);
        _maxFps.store(0);
        _maxBitrateKbps.store(0);
        _generation.store(0);
    }
    return self;
}

- (int32_t)maxShortSide {
    return _maxShortSide.load(std::memory_order_relaxed);
}

- (int32_t)maxFps {
    return _maxFps.load(std::memory_order_relaxed);
}

- (int32_t)maxBitrateKbps {
    return _maxBitrateKbps.load(std::memory_order_relaxed);
}

- (int64_t)generation {
    return _generation.load(std::memory_order_acquire);
}

- (void)setMaxShortSide:(int32_t)maxShortSide maxFps:(int32_t)maxFps maxBitrateKbps:(int32_t)maxBitrateKbps {
    maxShortSide = MAX(0, maxShortSide);
    maxFps = MAX(0, maxFps);
    maxBitrateKbps = MAX(0, maxBitrateKbps);
    @synchronized (self) {
        if (_maxShortSide.load() == maxShortSide && _maxFps.load() == maxFps && _maxBitrateKbps.load() == maxBitrateKbps) {
            return;
        }
        _maxShortSide.store(maxShortSide);
        _maxFps.store(maxFps);
        _maxBitrateKbps.store(maxBitrateKbps);
        _generation.fetch_add(1, std::memory_order_release);
    }
    NSLog(@"[SGCallVideoLimits] maxShortSide=%d maxFps=%d maxBitrateKbps=%d", maxShortSide, maxFps, maxBitrateKbps);
}

@end
