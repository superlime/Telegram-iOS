// MARK: Swiftgram
//
// VENDORED COPY of tgcalls/platform/darwin/VideoCameraCapturer.mm.
//
// The upstream file is excluded from the tgcalls glob in BUILD and replaced by
// this one, following the pattern already used there for VideoCameraCapturerMac
// and friends. It exists because live-translation subtitles have to be
// composited into the outgoing frame, and the tgcalls submodule points at
// TelegramMessenger/tgcalls — a repository we cannot push to, so a change made
// in place would leave the submodule pointer at an unreachable commit and break
// a fresh clone.
//
// Forked from tgcalls e3069322a3d1e16ecb11a5e302242e59ddd7f09e
//
// The divergences from upstream are all marked "MARK: Swiftgram":
//  - the live-translation subtitle blend;
//  - the cooler-video-call limits (SGCallVideoLimits): a smaller capture format,
//    a locked lower frame rate, a downscale folded into the NV12->I420
//    conversion, no conversion while paused, and live reconfiguration when the
//    limits change mid-call.
// When tgcalls updates this file, re-copy it and re-apply those blocks;
// Swiftgram/patches/tgcalls-subtitle-burn-in.patch and
// Swiftgram/patches/tgcalls-call-video-limits.patch hold the diffs.

#include "VideoCameraCapturer.h"

#import <AVFoundation/AVFoundation.h>
// MARK: Swiftgram
#import <TgVoipWebrtc/SGCallSubtitleRenderer.h>
#import <TgVoipWebrtc/SGCallVideoLimits.h>

#include "rtc_base/logging.h"
#import "base/RTCLogging.h"
#import "base/RTCVideoFrameBuffer.h"
#import "TGRTCCVPixelBuffer.h"
#import "sdk/objc/native/src/objc_video_track_source.h"
#import "sdk/objc/native/src/objc_frame_buffer.h"
#import "pc/video_track_source_proxy.h"

#import "helpers/UIDevice+RTCDevice.h"

#import "helpers/AVCaptureSession+DevicePosition.h"
#import "helpers/RTCDispatcher+Private.h"
#import "base/RTCVideoFrame.h"
#include "DarwinVideoSource.h"

#include "common_video/libyuv/include/webrtc_libyuv.h"
#include "rtc_base/checks.h"
#include "rtc_base/logging.h"
#include "third_party/libyuv/include/libyuv.h"
#include "api/video/i420_buffer.h"
#include "api/video/nv12_buffer.h"

#include "VideoCaptureView.h"

namespace {

static const int64_t kNanosecondsPerSecond = 1000000000;

static tgcalls::DarwinVideoTrackSource *getObjCVideoSource(const webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface> nativeSource) {
    webrtc::VideoTrackSourceProxy *proxy_source =
    static_cast<webrtc::VideoTrackSourceProxy *>(nativeSource.get());
    return static_cast<tgcalls::DarwinVideoTrackSource *>(proxy_source->internal());
}

static UIDeviceOrientation deviceOrientation(UIInterfaceOrientation orientation) {
    switch (orientation) {
        case UIInterfaceOrientationPortrait:
            return UIDeviceOrientationPortrait;
        case UIInterfaceOrientationPortraitUpsideDown:
            return UIDeviceOrientationPortraitUpsideDown;
        case UIInterfaceOrientationLandscapeLeft:
            return UIDeviceOrientationLandscapeRight;
        case UIInterfaceOrientationLandscapeRight:
            return UIDeviceOrientationLandscapeLeft;
        default:
            return UIDeviceOrientationPortrait;
    }
}

}

@interface VideoCameraCapturerPreviewRecord : NSObject

@property (nonatomic, weak) VideoCaptureView *view;

@end

@implementation VideoCameraCapturerPreviewRecord

- (instancetype)initWithCaptureView:(VideoCaptureView *)view {
    self = [super init];
    if (self != nil) {
        self.view = view;
    }
    return self;
}

@end

@interface VideoCameraCapturer () <AVCaptureVideoDataOutputSampleBufferDelegate> {
    webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface> _source;
    
    // Live on main thread.
    bool _isFrontCamera;
    bool _keepLandscape;
    
    dispatch_queue_t _frameQueue;

    // Live on RTCDispatcherTypeCaptureSession.
    AVCaptureDevice *_currentDevice;
    BOOL _hasRetriedOnFatalError;
    BOOL _isRunning;

	// Live on RTCDispatcherTypeCaptureSession and main thread.
	std::atomic<bool> _willBeRunning;
    
    AVCaptureVideoDataOutput *_videoDataOutput;
    AVCaptureSession *_captureSession;
    FourCharCode _preferredOutputPixelFormat;
    FourCharCode _outputPixelFormat;
    RTCVideoRotation _rotation;
    UIDeviceOrientation _orientation;
    bool _didReceiveOrientationUpdate;
    bool _rotationLock;
    
    // Live on mainThread.
    void (^_isActiveUpdated)(bool);
    bool _isActiveValue;
    bool _inForegroundValue;
    
    void (^_rotationUpdated)(int);
    
    // Live on frameQueue and main thread.
    std::atomic<bool> _isPaused;

    // Live on frameQueue.
    float _aspectRatio;
    std::vector<uint8_t> _croppingBuffer;
    std::weak_ptr<rtc::VideoSinkInterface<webrtc::VideoFrame>> _uncroppedSink;
    
    // Live on frameQueue and RTCDispatcherTypeCaptureSession.
    std::atomic<int> _warmupFrameCount;

    webrtc::NV12ToI420Scaler _nv12ToI420Scaler;

    NSMutableArray<VideoCameraCapturerPreviewRecord *> *_previews;
    std::vector<std::weak_ptr<rtc::VideoSinkInterface<webrtc::VideoFrame>>> _directSinks;

    // MARK: Swiftgram
    // What upstream asked for, kept so that when the limits are relaxed
    // mid-call the camera goes back to exactly that. Live on
    // RTCDispatcherTypeCaptureSession.
    AVCaptureDeviceFormat *_sgRequestedFormat;
    NSInteger _sgRequestedFps;
    // SGCallVideoLimits.generation that the current camera configuration
    // reflects. Written on frameQueue and RTCDispatcherTypeCaptureSession.
    std::atomic<int64_t> _sgAppliedGeneration;
}

@end

@implementation VideoCameraCapturer

- (instancetype)initWithSource:(webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface>)source useFrontCamera:(bool)useFrontCamera keepLandscape:(bool)keepLandscape isActiveUpdated:(void (^)(bool))isActiveUpdated rotationUpdated:(void (^)(int))rotationUpdated {
    self = [super init];
    if (self != nil) {
        _source = source;
        _isFrontCamera = useFrontCamera;
        _keepLandscape = keepLandscape;
        _isActiveValue = true;
        _inForegroundValue = true;
        _isPaused = false;
        _isActiveUpdated = [isActiveUpdated copy];
        _rotationUpdated = [rotationUpdated copy];
        
        _warmupFrameCount = 100;

        _previews = [[NSMutableArray alloc] init];
        
        if (![self setupCaptureSession:[[AVCaptureSession alloc] init]]) {
            return nil;
        }
        
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        _orientation = deviceOrientation([[UIApplication sharedApplication] statusBarOrientation]);
#pragma clang diagnostic pop
        _rotation = RTCVideoRotation_90;
        
        switch (_orientation) {
            case UIDeviceOrientationPortrait:
                _rotation = RTCVideoRotation_90;
                break;
            case UIDeviceOrientationPortraitUpsideDown:
                _rotation = RTCVideoRotation_270;
                break;
            case UIDeviceOrientationLandscapeLeft:
                _rotation = useFrontCamera ? RTCVideoRotation_180 : RTCVideoRotation_0;
                break;
            case UIDeviceOrientationLandscapeRight:
                _rotation = useFrontCamera ? RTCVideoRotation_0 : RTCVideoRotation_180;
                break;
            case UIDeviceOrientationFaceUp:
            case UIDeviceOrientationFaceDown:
            case UIDeviceOrientationUnknown:
                // Ignore.
                break;
        }
        
        if (_rotationUpdated) {
            int angle = 0;
            switch (_rotation) {
                case RTCVideoRotation_0: {
                    angle = 0;
                    break;
                }
                case RTCVideoRotation_90: {
                    angle = 90;
                    break;
                }
                case RTCVideoRotation_180: {
                    angle = 180;
                    break;
                }
                case RTCVideoRotation_270: {
                    angle = 270;
                    break;
                }
                default: {
                    break;
                }
            }
            _rotationUpdated(angle);
        }
        [center addObserver:self
                   selector:@selector(deviceOrientationDidChange:)
                       name:UIDeviceOrientationDidChangeNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(handleCaptureSessionInterruption:)
                       name:AVCaptureSessionWasInterruptedNotification
                     object:_captureSession];
        [center addObserver:self
                   selector:@selector(handleCaptureSessionInterruptionEnded:)
                       name:AVCaptureSessionInterruptionEndedNotification
                     object:_captureSession];
        [center addObserver:self
                   selector:@selector(handleApplicationDidBecomeActive:)
                       name:UIApplicationDidBecomeActiveNotification
                     object:[UIApplication sharedApplication]];
        [center addObserver:self
            selector:@selector(handleApplicationWillEnterForeground:)
                name:UIApplicationWillEnterForegroundNotification
              object:[UIApplication sharedApplication]];
        [center addObserver:self
                   selector:@selector(handleCaptureSessionRuntimeError:)
                       name:AVCaptureSessionRuntimeErrorNotification
                     object:_captureSession];
        [center addObserver:self
                   selector:@selector(handleCaptureSessionDidStartRunning:)
                       name:AVCaptureSessionDidStartRunningNotification
                     object:_captureSession];
        [center addObserver:self
                   selector:@selector(handleCaptureSessionDidStopRunning:)
                       name:AVCaptureSessionDidStopRunningNotification
                     object:_captureSession];
    }
    return self;
}

- (void)dealloc {
    NSAssert(!_willBeRunning, @"Session was still running in RTCCameraVideoCapturer dealloc. Forgot to call stopCapture?");
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
+ (NSArray<AVCaptureDevice *> *)captureDevices {
    if (@available(iOS 10.0, *)) {
        AVCaptureDeviceDiscoverySession *session = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera] mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionUnspecified];
        return session.devices;
    } else {
        NSMutableArray<AVCaptureDevice *> *result = [[NSMutableArray alloc] init];
        for (AVCaptureDevice *device in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
            if (device.position == AVCaptureDevicePositionFront || device.position == AVCaptureDevicePositionBack) {
                [result addObject:device];
            }
        }
        return result;
    }
}
#pragma clang diagnostic pop

+ (NSArray<AVCaptureDeviceFormat *> *)supportedFormatsForDevice:(AVCaptureDevice *)device {
  // Support opening the device in any format. We make sure it's converted to a format we
  // can handle, if needed, in the method `-setupVideoDataOutput`.
  return device.formats;
}

- (FourCharCode)preferredOutputPixelFormat {
  return _preferredOutputPixelFormat;
}

- (void)startCaptureWithDevice:(AVCaptureDevice *)device
                        format:(AVCaptureDeviceFormat *)format
                           fps:(NSInteger)fps {
  [self startCaptureWithDevice:device format:format fps:fps completionHandler:nil];
}

- (void)stopCapture {
  _isActiveUpdated = nil;
  [self stopCaptureWithCompletionHandler:nil];
}

- (void)setIsEnabled:(bool)isEnabled {
    _isPaused = !isEnabled;
    [self updateIsActiveValue];
}

- (void)setUncroppedSink:(std::shared_ptr<rtc::VideoSinkInterface<webrtc::VideoFrame>>)sink {
	dispatch_async(self.frameQueue, ^{
		_uncroppedSink = sink;
	});
}

- (int)getRotation {
    switch (_rotation) {
        case RTCVideoRotation_0:
            return 0;
        case RTCVideoRotation_90:
            return 90;
        case RTCVideoRotation_180:
            return 180;
        case RTCVideoRotation_270:
            return 270;
        default:
            return 0;
    }
}

- (void)addPreviewView:(VideoCaptureView *)previewView {
    [_previews addObject:[[VideoCameraCapturerPreviewRecord alloc] initWithCaptureView:previewView]];
    [previewView previewLayer].session = _captureSession;
}

- (void)addDirectSink:(std::weak_ptr<rtc::VideoSinkInterface<webrtc::VideoFrame>>)directSink {
    _directSinks.push_back(directSink);
}

- (void)setPreferredCaptureAspectRatio:(float)aspectRatio {
	dispatch_async(self.frameQueue, ^{
		_aspectRatio = aspectRatio;
	});
}

- (void)startCaptureWithDevice:(AVCaptureDevice *)device
                        format:(AVCaptureDeviceFormat *)format
                           fps:(NSInteger)fps
             completionHandler:(nullable void (^)(NSError *))completionHandler {
  _willBeRunning = true;
  [RTCDispatcher
      dispatchAsyncOnType:RTCDispatcherTypeCaptureSession
   block:^{
      RTCLogInfo("startCaptureWithDevice %@ @ %ld fps", format, (long)fps);
      
      dispatch_async(dispatch_get_main_queue(), ^{
          [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
      });
      
      _currentDevice = device;

      // MARK: Swiftgram
      // Swap in a smaller format and lower frame rate when the call video is
      // limited. A smaller sensor format is cheaper at every later stage: the
      // ISP, the CPU colour conversion, the encoder and the radio.
      _sgRequestedFormat = format;
      _sgRequestedFps = fps;
      _sgAppliedGeneration = [SGCallVideoLimits shared].generation;
      AVCaptureDeviceFormat *sgFormat = format;
      NSInteger sgFps = fps;
      [self sgApplyLimitsToFormat:&sgFormat fps:&sgFps device:device];

      NSError *error = nil;
      if (![_currentDevice lockForConfiguration:&error]) {
          RTCLogError(@"Failed to lock device %@. Error: %@",
                      _currentDevice,
                      error.userInfo);
          if (completionHandler) {
              completionHandler(error);
          }
          _willBeRunning = false;
          return;
      }
      [self reconfigureCaptureSessionInput];
      // MARK: Swiftgram
      [self updateDeviceCaptureFormat:sgFormat fps:sgFps];
      [self updateVideoDataOutputPixelFormat:sgFormat];
      [_captureSession startRunning];
      [_currentDevice unlockForConfiguration];
      _isRunning = YES;
      if (completionHandler) {
          completionHandler(nil);
      }
  }];
}

- (void)stopCaptureWithCompletionHandler:(nullable void (^)(void))completionHandler {
  _willBeRunning = false;
  [RTCDispatcher
   dispatchAsyncOnType:RTCDispatcherTypeCaptureSession
   block:^{
      RTCLogInfo("Stop");
      _currentDevice = nil;
      for (AVCaptureDeviceInput *oldInput in [_captureSession.inputs copy]) {
          [_captureSession removeInput:oldInput];
      }
      [_captureSession stopRunning];
      
      dispatch_async(dispatch_get_main_queue(), ^{
          [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
      });
      _isRunning = NO;
      if (completionHandler) {
          completionHandler();
      }
  }];
}

#pragma mark iOS notifications

#if TARGET_OS_IPHONE
- (void)deviceOrientationDidChange:(NSNotification *)notification {
    [RTCDispatcher dispatchAsyncOnType:RTCDispatcherTypeCaptureSession block:^{
        _didReceiveOrientationUpdate = true;
        [self updateOrientation];
    }];
}
#endif

#pragma mark AVCaptureVideoDataOutputSampleBufferDelegate

- (webrtc::scoped_refptr<webrtc::VideoFrameBuffer>)prepareI420Buffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) {
        return nullptr;
    }

    const OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);

    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    // MARK: Swiftgram
    // Fold the call-video resolution limit into the conversion that happens
    // anyway: NV12ToI420Scale converts and downscales in one pass. This covers
    // limits with no matching native camera format (e.g. 640x360 taken from a
    // 960x540 format).
    const int sgSourceWidth = (int)CVPixelBufferGetWidth(pixelBuffer);
    const int sgSourceHeight = (int)CVPixelBufferGetHeight(pixelBuffer);
    int sgResultWidth = sgSourceWidth;
    int sgResultHeight = sgSourceHeight;
    const int32_t sgMaxShortSide = [SGCallVideoLimits shared].maxShortSide;
    const int sgSourceShortSide = MIN(sgSourceWidth, sgSourceHeight);
    if (sgMaxShortSide > 0 && sgSourceShortSide > sgMaxShortSide) {
        const double scale = (double)sgMaxShortSide / (double)sgSourceShortSide;
        sgResultWidth = MAX(2, ((int)(sgSourceWidth * scale)) & ~1);
        sgResultHeight = MAX(2, ((int)(sgSourceHeight * scale)) & ~1);
    }

    auto resultBuffer = rtc::make_ref_counted<webrtc::I420Buffer>(sgResultWidth, sgResultHeight);

    switch (pixelFormat) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: {
            const uint8_t* srcY =
            static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0));
            const int srcYStride = (int)CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
            const uint8_t* srcUV =
            static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1));
            const int srcUVStride = (int)CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);

            // TODO(magjed): Use a frame buffer pool.
            // MARK: Swiftgram: source size is the pixel buffer's, not the
            // (possibly smaller) destination's.
            _nv12ToI420Scaler.NV12ToI420Scale(srcY,
                                             srcYStride,
                                             srcUV,
                                             srcUVStride,
                                             sgSourceWidth,
                                             sgSourceHeight,
                                             resultBuffer->MutableDataY(),
                                             resultBuffer->StrideY(),
                                             resultBuffer->MutableDataU(),
                                             resultBuffer->StrideU(),
                                             resultBuffer->MutableDataV(),
                                             resultBuffer->StrideV(),
                                             resultBuffer->width(),
                                             resultBuffer->height());
            break;
        }
        case kCVPixelFormatType_32BGRA:
        case kCVPixelFormatType_32ARGB: {
            return nullptr;
        }
        default: { RTC_DCHECK_NOTREACHED() << "Unsupported pixel format."; }
    }

    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    return resultBuffer;
}

- (webrtc::scoped_refptr<webrtc::VideoFrameBuffer>)prepareNV12Buffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) {
        return nullptr;
    }

    const OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);

    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

    switch (pixelFormat) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: {
            const uint8_t* srcY =
            static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0));
            const int srcYStride = (int)CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
            const uint8_t* srcUV =
            static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1));
            const int srcUVStride = (int)CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);

            const int srcWidth = (int)CVPixelBufferGetWidth(pixelBuffer);
            const int srcHeight = (int)CVPixelBufferGetHeight(pixelBuffer);

            int resultWidth = (int)(srcWidth * 0.8f);
            resultWidth &= ~1;
            int resultHeight = (int)(srcHeight * 0.8f);
            resultHeight &= ~1;

            webrtc::scoped_refptr<webrtc::NV12Buffer> resultBuffer = rtc::make_ref_counted<webrtc::NV12Buffer>(resultWidth, resultHeight, srcYStride, srcUVStride);

            libyuv::NV12Scale(srcY, srcYStride, srcUV, srcUVStride,
                                        resultWidth, resultHeight, resultBuffer->MutableDataY(),
                                        resultBuffer->StrideY(), resultBuffer->MutableDataUV(), resultBuffer->StrideUV(), resultBuffer->width(),
                                        resultBuffer->height(), libyuv::kFilterBilinear);

            CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

            return resultBuffer;
        }
        case kCVPixelFormatType_32BGRA:
        case kCVPixelFormatType_32ARGB: {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
            return nullptr;
        }
        default: { RTC_DCHECK_NOTREACHED() << "Unsupported pixel format."; }
    }

    return nullptr;
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
    NSParameterAssert(captureOutput == _videoDataOutput);
    
    int minWarmupFrameCount = 12;
    _warmupFrameCount++;
    if (_warmupFrameCount < minWarmupFrameCount) {
        return;
    }

    // MARK: Swiftgram
    // Limits changed mid-call (settings, or the thermal governor): reconfigure
    // the camera. One atomic compare per frame when nothing changed.
    const int64_t sgGeneration = [SGCallVideoLimits shared].generation;
    if (sgGeneration != _sgAppliedGeneration.load()) {
        _sgAppliedGeneration = sgGeneration;
        [self sgReapplyLimits];
    }
    
    if (CMSampleBufferGetNumSamples(sampleBuffer) != 1 || !CMSampleBufferIsValid(sampleBuffer) ||
        !CMSampleBufferDataIsReady(sampleBuffer)) {
        return;
    }
    
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (pixelBuffer == nil) {
        return;
    }
    
    // Default to portrait orientation on iPhone.
    BOOL usingFrontCamera = NO;
    // Check the image's EXIF for the camera the image came from as the image could have been
    // delayed as we set alwaysDiscardsLateVideoFrames to NO.
    AVCaptureDevicePosition cameraPosition =
    [AVCaptureSession devicePositionForSampleBuffer:sampleBuffer];
    if (cameraPosition != AVCaptureDevicePositionUnspecified) {
        usingFrontCamera = AVCaptureDevicePositionFront == cameraPosition;
    } else {
        AVCaptureDeviceInput *deviceInput =
        (AVCaptureDeviceInput *)((AVCaptureInputPort *)connection.inputPorts.firstObject).input;
        usingFrontCamera = AVCaptureDevicePositionFront == deviceInput.device.position;
    }
    int deviceRelativeVideoRotation = usingFrontCamera ? RTCVideoRotation_90 : RTCVideoRotation_90;
    if (!_rotationLock) {
        RTCVideoRotation updatedRotation = _rotation;
        switch (_orientation) {
            case UIDeviceOrientationPortrait:
                updatedRotation = RTCVideoRotation_90;
                break;
            case UIDeviceOrientationPortraitUpsideDown:
                updatedRotation = RTCVideoRotation_270;
                break;
            case UIDeviceOrientationLandscapeLeft:
                updatedRotation = usingFrontCamera ? RTCVideoRotation_180 : RTCVideoRotation_0;
                break;
            case UIDeviceOrientationLandscapeRight:
                updatedRotation = usingFrontCamera ? RTCVideoRotation_0 : RTCVideoRotation_180;
                break;
            case UIDeviceOrientationFaceUp:
            case UIDeviceOrientationFaceDown:
            case UIDeviceOrientationUnknown:
                // Ignore.
                break;
        }
        if (_rotation != updatedRotation) {
            _rotation = updatedRotation;
            if (_rotationUpdated) {
                int angle = 0;
                switch (_rotation) {
                    case RTCVideoRotation_0: {
                        angle = 0;
                        break;
                    }
                    case RTCVideoRotation_90: {
                        angle = 90;
                        break;
                    }
                    case RTCVideoRotation_180: {
                        angle = 180;
                        break;
                    }
                    case RTCVideoRotation_270: {
                        angle = 270;
                        break;
                    }
                    default: {
                        break;
                    }
                }
                _rotationUpdated(angle);
            }
        }
    }
    
    TGRTCCVPixelBuffer *rtcPixelBuffer = [[TGRTCCVPixelBuffer alloc] initWithPixelBuffer:pixelBuffer];
    rtcPixelBuffer.shouldBeMirrored = usingFrontCamera;
    rtcPixelBuffer.deviceRelativeVideoRotation = deviceRelativeVideoRotation;
    
    TGRTCCVPixelBuffer *uncroppedRtcPixelBuffer = rtcPixelBuffer;

    CGSize initialSize = CGSizeMake(uncroppedRtcPixelBuffer.width, uncroppedRtcPixelBuffer.height);
    
    if (_aspectRatio > FLT_EPSILON) {
        float aspect = 1.0f / _aspectRatio;
        
        int width = rtcPixelBuffer.width;
        int height = rtcPixelBuffer.height;
        
        int cropX = 0;
        int cropY = 0;
        
        if (_keepLandscape && width > height) {
            float aspectWidth = 404.0f;
            float aspectHeight = 720.0f;
            cropX = (int)((width - aspectWidth) / 2.0f);
            cropY = (int)((height - aspectHeight) / 2.0f);
            width = aspectWidth;
            height = aspectHeight;
        } else {
            float aspectWidth = width;
            float aspectHeight = ((float)(width)) / aspect;
            cropX = (int)((width - aspectWidth) / 2.0f);
            cropY = (int)((height - aspectHeight) / 2.0f);
            width = (int)aspectWidth;
            width &= ~1;
            height = (int)aspectHeight;
            height &= ~1;
        }
        
        height = MIN(rtcPixelBuffer.height, height + 16);
        
        if (width < rtcPixelBuffer.width || height < rtcPixelBuffer.height) {
            rtcPixelBuffer = [[TGRTCCVPixelBuffer alloc] initWithPixelBuffer:pixelBuffer adaptedWidth:width adaptedHeight:height cropWidth:width cropHeight:height cropX:cropX cropY:cropY];
            rtcPixelBuffer.shouldBeMirrored = usingFrontCamera;
            rtcPixelBuffer.deviceRelativeVideoRotation = deviceRelativeVideoRotation;
            
            CVPixelBufferRef outputPixelBufferRef = NULL;
            OSType pixelFormat = CVPixelBufferGetPixelFormatType(rtcPixelBuffer.pixelBuffer);
            CVPixelBufferCreate(NULL, width, height, pixelFormat, NULL, &outputPixelBufferRef);
            if (outputPixelBufferRef) {
                int bufferSize = [rtcPixelBuffer bufferSizeForCroppingAndScalingToWidth:width height:height];
                if (_croppingBuffer.size() < bufferSize) {
                    _croppingBuffer.resize(bufferSize);
                }
                if ([rtcPixelBuffer cropAndScaleTo:outputPixelBufferRef withTempBuffer:_croppingBuffer.data()]) {
                    rtcPixelBuffer = [[TGRTCCVPixelBuffer alloc] initWithPixelBuffer:outputPixelBufferRef];
                    rtcPixelBuffer.shouldBeMirrored = usingFrontCamera;
                    rtcPixelBuffer.deviceRelativeVideoRotation = deviceRelativeVideoRotation;
                }
                CVPixelBufferRelease(outputPixelBufferRef);
            }
        }
    }
    
    int64_t timeStampNs = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * kNanosecondsPerSecond;

    //RTCVideoFrame *videoFrame = [[RTCVideoFrame alloc] initWithBuffer:rtcPixelBuffer rotation:_rotation timeStampNs:timeStampNs];

    //RTCVideoFrame *videoFrame = [[RTCVideoFrame alloc] initWithBuffer:(id<RTCVideoFrameBuffer>)[rtcPixelBuffer toI420] rotation:_rotation timeStampNs:timeStampNs];

    webrtc::VideoRotation rotation = static_cast<webrtc::VideoRotation>(_rotation);

    int previewRotation = 0;
    CGSize previewSize = initialSize;
    if (rotation == 90 || rotation == 270) {
        previewSize = CGSizeMake(previewSize.height, previewSize.width);
    }

    for (VideoCameraCapturerPreviewRecord *record in _previews) {
        dispatch_async(dispatch_get_main_queue(), ^{
            VideoCaptureView *captureView = record.view;
            [captureView onFrameGenerated:previewSize isMirrored:true rotation:previewRotation];
        });
    }

    // MARK: Swiftgram
    // Upstream converted every frame even while the outgoing video is paused
    // and the result is thrown away. Nothing below uses the buffer when paused.
    webrtc::scoped_refptr<webrtc::VideoFrameBuffer> i420Buffer;
    if (!_isPaused) {
        i420Buffer = [self prepareI420Buffer:[rtcPixelBuffer pixelBuffer]];
    }
    
    // MARK: Swiftgram
    // Burn live-translation subtitles into the outgoing frame.
    //
    // This has to happen in the capture path rather than as an overlay on the
    // local call screen: the person who needs to read the translation is the one
    // on the other end. Drawing it locally would show it only to the person who
    // does not need it.
    //
    // prepareI420Buffer either returns nullptr or the I420Buffer it allocated,
    // so the cast is safe, and the buffer is ours alone here — nothing else
    // holds a reference yet.
    if (i420Buffer && [[SGCallSubtitleRenderer shared] hasContent]) {
        auto *mutableBuffer = static_cast<webrtc::I420Buffer *>(i420Buffer.get());
        [[SGCallSubtitleRenderer shared] blendIntoY:mutableBuffer->MutableDataY()
                                            strideY:mutableBuffer->StrideY()
                                                  u:mutableBuffer->MutableDataU()
                                            strideU:mutableBuffer->StrideU()
                                                  v:mutableBuffer->MutableDataV()
                                            strideV:mutableBuffer->StrideV()
                                              width:mutableBuffer->width()
                                             height:mutableBuffer->height()
                                           rotation:(int)rotation];
    }
    
    if (!_isPaused && i420Buffer) {
        auto videoFrame = webrtc::VideoFrame::Builder()
            .set_video_frame_buffer(i420Buffer)
            .set_rotation(rotation)
            .set_timestamp_us(timeStampNs)
            .build();

        if (getObjCVideoSource(_source)->OnCapturedFrame(videoFrame)) {
            if (!_directSinks.empty()) {
                for (const auto &it : _directSinks) {
                    if (const auto value = it.lock()) {
                        value->OnFrame(videoFrame);
                    }
                }
            }
        }
        
        if (uncroppedRtcPixelBuffer) {
            const auto uncroppedSink = _uncroppedSink.lock();
            if (uncroppedSink) {
                int64_t timeStampNs = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) *
                kNanosecondsPerSecond;
                RTCVideoFrame *frame = [[RTCVideoFrame alloc] initWithBuffer:uncroppedRtcPixelBuffer rotation:_rotation timeStampNs:timeStampNs];
                
                const int64_t timestamp_us = frame.timeStampNs / rtc::kNumNanosecsPerMicrosec;

                webrtc::scoped_refptr<webrtc::VideoFrameBuffer> buffer;
                buffer = new rtc::RefCountedObject<webrtc::ObjCFrameBuffer>(frame.buffer);
                
                webrtc::VideoRotation rotation = static_cast<webrtc::VideoRotation>(frame.rotation);
                
                uncroppedSink->OnFrame(webrtc::VideoFrame::Builder()
                        .set_video_frame_buffer(buffer)
                        .set_rotation(rotation)
                        .set_timestamp_us(timestamp_us)
                        .build());
            }
        }
    }
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
    didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection {
  NSString *droppedReason =
      (__bridge NSString *)CMGetAttachment(sampleBuffer, kCMSampleBufferAttachmentKey_DroppedFrameReason, nil);
  RTCLogError(@"Dropped sample buffer. Reason: %@", droppedReason);
}

#pragma mark - AVCaptureSession notifications

- (void)handleCaptureSessionInterruption:(NSNotification *)notification {
    NSString *reasonString = nil;
    NSNumber *reason = notification.userInfo[AVCaptureSessionInterruptionReasonKey];
    if (reason) {
        switch (reason.intValue) {
            case AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableInBackground:
                reasonString = @"VideoDeviceNotAvailableInBackground";
                break;
            case AVCaptureSessionInterruptionReasonAudioDeviceInUseByAnotherClient:
                reasonString = @"AudioDeviceInUseByAnotherClient";
                break;
            case AVCaptureSessionInterruptionReasonVideoDeviceInUseByAnotherClient:
                reasonString = @"VideoDeviceInUseByAnotherClient";
                break;
            case AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableWithMultipleForegroundApps:
                reasonString = @"VideoDeviceNotAvailableWithMultipleForegroundApps";
                break;
        }
    }
    RTCLog(@"Capture session interrupted: %@", reasonString);
}

- (void)handleCaptureSessionInterruptionEnded:(NSNotification *)notification {
    RTCLog(@"Capture session interruption ended.");
}

- (void)handleCaptureSessionRuntimeError:(NSNotification *)notification {
    NSError *error = [notification.userInfo objectForKey:AVCaptureSessionErrorKey];
    RTCLogError(@"Capture session runtime error: %@", error);

    [RTCDispatcher dispatchAsyncOnType:RTCDispatcherTypeCaptureSession
                                 block:^{
        if (error.code == AVErrorMediaServicesWereReset) {
            [self handleNonFatalError];
        } else {
            [self handleFatalError];
        }
    }];
}

- (void)handleCaptureSessionDidStartRunning:(NSNotification *)notification {
    RTCLog(@"Capture session started.");
    
    [RTCDispatcher dispatchAsyncOnType:RTCDispatcherTypeCaptureSession
                                 block:^{
        // If we successfully restarted after an unknown error,
        // allow future retries on fatal errors.
        _hasRetriedOnFatalError = NO;
    }];
    
    _inForegroundValue = true;
    [self updateIsActiveValue];
}

- (void)handleCaptureSessionDidStopRunning:(NSNotification *)notification {
  RTCLog(@"Capture session stopped.");
    _inForegroundValue = false;
    [self updateIsActiveValue];
}

- (void)updateIsActiveValue {
    bool isActive = _inForegroundValue && !_isPaused;
    if (isActive != _isActiveValue) {
        _isActiveValue = isActive;
        if (_isActiveUpdated) {
            _isActiveUpdated(_isActiveValue);
        }
    }
}

- (void)handleFatalError {
    [RTCDispatcher
     dispatchAsyncOnType:RTCDispatcherTypeCaptureSession
     block:^{
        if (!_hasRetriedOnFatalError) {
            RTCLogWarning(@"Attempting to recover from fatal capture error.");
            [self handleNonFatalError];
            _hasRetriedOnFatalError = YES;
        } else {
            RTCLogError(@"Previous fatal error recovery failed.");
        }
    }];
}

- (void)handleNonFatalError {
    [RTCDispatcher dispatchAsyncOnType:RTCDispatcherTypeCaptureSession
                                 block:^{
        RTCLog(@"Restarting capture session after error.");
        if (_isRunning) {
            [_captureSession startRunning];
        }
    }];
}

#pragma mark - UIApplication notifications

- (void)handleApplicationDidBecomeActive:(NSNotification *)notification {
    [RTCDispatcher dispatchAsyncOnType:RTCDispatcherTypeCaptureSession
                                 block:^{
        if (_isRunning && !_captureSession.isRunning) {
            RTCLog(@"Restarting capture session on active.");
            _warmupFrameCount = 0;
            [_captureSession startRunning];
        }
    }];
}

- (void)handleApplicationWillEnterForeground:(NSNotification *)notification {
    [RTCDispatcher dispatchAsyncOnType:RTCDispatcherTypeCaptureSession
                                 block:^{
        RTCLog(@"Resetting warmup due to backgrounding.");
        _warmupFrameCount = 0;
    }];
}

#pragma mark - Private

- (dispatch_queue_t)frameQueue {
    if (!_frameQueue) {
        _frameQueue =
        dispatch_queue_create("org.webrtc.cameravideocapturer.video", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_frameQueue,
                                  dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
    }
    return _frameQueue;
}

- (BOOL)setupCaptureSession:(AVCaptureSession *)captureSession {
    NSAssert(_captureSession == nil, @"Setup capture session called twice.");
    _captureSession = captureSession;
    _captureSession.sessionPreset = AVCaptureSessionPresetInputPriority;
    _captureSession.usesApplicationAudioSession = true;
    if (@available(iOS 16.0, *)) {
        if (_captureSession.isMultitaskingCameraAccessSupported) {
            _captureSession.multitaskingCameraAccessEnabled = true;
        }
    }
    [self setupVideoDataOutput];
    // Add the output.
    if (![_captureSession canAddOutput:_videoDataOutput]) {
        RTCLogError(@"Video data output unsupported.");
        return NO;
    }
    [_captureSession addOutput:_videoDataOutput];
    
    return YES;
}

- (void)setupVideoDataOutput {
    NSAssert(_videoDataOutput == nil, @"Setup video data output called twice.");
    AVCaptureVideoDataOutput *videoDataOutput = [[AVCaptureVideoDataOutput alloc] init];
    
    // `videoDataOutput.availableVideoCVPixelFormatTypes` returns the pixel formats supported by the
    // device with the most efficient output format first. Find the first format that we support.
    NSSet<NSNumber *> *supportedPixelFormats = [TGRTCCVPixelBuffer supportedPixelFormats];
    NSMutableOrderedSet *availablePixelFormats =
    [NSMutableOrderedSet orderedSetWithArray:videoDataOutput.availableVideoCVPixelFormatTypes];
    [availablePixelFormats intersectSet:supportedPixelFormats];
    NSNumber *pixelFormat = availablePixelFormats.firstObject;
    NSAssert(pixelFormat, @"Output device has no supported formats.");
    
    _preferredOutputPixelFormat = [pixelFormat unsignedIntValue];
    _outputPixelFormat = _preferredOutputPixelFormat;
    videoDataOutput.videoSettings = @{(NSString *)kCVPixelBufferPixelFormatTypeKey : pixelFormat};
    videoDataOutput.alwaysDiscardsLateVideoFrames = NO;
    [videoDataOutput setSampleBufferDelegate:self queue:self.frameQueue];
    _videoDataOutput = videoDataOutput;
}

- (void)updateVideoDataOutputPixelFormat:(AVCaptureDeviceFormat *)format {
    FourCharCode mediaSubType = CMFormatDescriptionGetMediaSubType(format.formatDescription);
    if (![[TGRTCCVPixelBuffer supportedPixelFormats] containsObject:@(mediaSubType)]) {
        mediaSubType = _preferredOutputPixelFormat;
    }
    
    if (mediaSubType != _outputPixelFormat) {
        _outputPixelFormat = mediaSubType;
        _videoDataOutput.videoSettings =
        @{ (NSString *)kCVPixelBufferPixelFormatTypeKey : @(mediaSubType) };
    }
}

#pragma mark - Private, called inside capture queue

- (void)updateDeviceCaptureFormat:(AVCaptureDeviceFormat *)format fps:(NSInteger)fps {
    NSAssert([RTCDispatcher isOnQueueForType:RTCDispatcherTypeCaptureSession],
             @"updateDeviceCaptureFormat must be called on the capture queue.");
    @try {
        _currentDevice.activeFormat = format;
        _currentDevice.activeVideoMinFrameDuration = CMTimeMake(1, (int32_t)fps);
        // MARK: Swiftgram
        // Upstream only floors the frame duration. When the call video is
        // limited, also lock the ceiling so the camera really runs at `fps`
        // instead of whatever it prefers. kCMTimeInvalid restores the default.
        if ([SGCallVideoLimits shared].maxFps > 0) {
            _currentDevice.activeVideoMaxFrameDuration = CMTimeMake(1, (int32_t)fps);
        } else {
            _currentDevice.activeVideoMaxFrameDuration = kCMTimeInvalid;
        }
    } @catch (NSException *exception) {
        RTCLogError(@"Failed to set active format!\n User info:%@", exception.userInfo);
        return;
    }
}

// MARK: Swiftgram
/// Replace `format` and `fps` with the smallest format and frame rate that
/// satisfy SGCallVideoLimits. Leaves them alone when nothing is limited.
- (void)sgApplyLimitsToFormat:(AVCaptureDeviceFormat * __strong *)format fps:(NSInteger *)fps device:(AVCaptureDevice *)device {
    SGCallVideoLimits *limits = [SGCallVideoLimits shared];
    const int32_t maxShortSide = limits.maxShortSide;
    const int32_t maxFps = limits.maxFps;

    NSInteger targetFps = *fps;
    if (maxFps > 0 && targetFps > maxFps) {
        targetFps = maxFps;
    }

    AVCaptureDeviceFormat *requested = *format;
    AVCaptureDeviceFormat *selected = requested;
    if (maxShortSide > 0 && requested != nil) {
        const CMVideoDimensions requestedDimensions = CMVideoFormatDescriptionGetDimensions(requested.formatDescription);
        const int requestedShortSide = MIN(requestedDimensions.width, requestedDimensions.height);
        const int requestedLongSide = MAX(requestedDimensions.width, requestedDimensions.height);
        const FourCharCode requestedSubtype = CMFormatDescriptionGetMediaSubType(requested.formatDescription);
        const double requestedAspect = requestedShortSide > 0 ? (double)requestedLongSide / (double)requestedShortSide : 0.0;

        if (requestedShortSide > maxShortSide) {
            AVCaptureDeviceFormat *bestMatchingAspect = nil;
            int bestMatchingAspectShortSide = INT_MAX;
            AVCaptureDeviceFormat *bestAnyAspect = nil;
            int bestAnyAspectShortSide = INT_MAX;

            for (AVCaptureDeviceFormat *candidate in device.formats) {
                if (CMFormatDescriptionGetMediaSubType(candidate.formatDescription) != requestedSubtype) {
                    continue;
                }
                const CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(candidate.formatDescription);
                const int shortSide = MIN(dimensions.width, dimensions.height);
                const int longSide = MAX(dimensions.width, dimensions.height);
                // Only ever go smaller than upstream's choice, and never below
                // the limit: the rest is done by the I420 downscale.
                if (shortSide < maxShortSide || shortSide >= requestedShortSide) {
                    continue;
                }
                bool supportsFps = false;
                for (AVFrameRateRange *range in candidate.videoSupportedFrameRateRanges) {
                    if (range.maxFrameRate + 0.5 >= (double)targetFps && range.minFrameRate - 0.5 <= (double)targetFps) {
                        supportsFps = true;
                        break;
                    }
                }
                if (!supportsFps) {
                    continue;
                }
                const double aspect = (double)longSide / (double)shortSide;
                if (fabs(aspect - requestedAspect) < 0.02) {
                    if (shortSide < bestMatchingAspectShortSide) {
                        bestMatchingAspect = candidate;
                        bestMatchingAspectShortSide = shortSide;
                    }
                } else if (shortSide < bestAnyAspectShortSide) {
                    bestAnyAspect = candidate;
                    bestAnyAspectShortSide = shortSide;
                }
            }
            if (bestMatchingAspect != nil) {
                selected = bestMatchingAspect;
            } else if (bestAnyAspect != nil) {
                selected = bestAnyAspect;
            }
        }
    }

    // Keep the frame rate inside what the chosen format supports.
    if (selected != nil) {
        double lowest = DBL_MAX;
        double highest = 0.0;
        for (AVFrameRateRange *range in selected.videoSupportedFrameRateRanges) {
            lowest = MIN(lowest, range.minFrameRate);
            highest = MAX(highest, range.maxFrameRate);
        }
        if (highest > 0.0) {
            targetFps = MAX((NSInteger)ceil(lowest), MIN(targetFps, (NSInteger)floor(highest)));
        }
    }

    if (selected != requested || targetFps != *fps) {
        const CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(selected.formatDescription);
        NSLog(@"[SGCallVideoLimits] capture %dx%d @ %ld fps (limits: shortSide=%d fps=%d)", dimensions.width, dimensions.height, (long)targetFps, maxShortSide, maxFps);
    }

    *format = selected;
    *fps = targetFps;
}

// MARK: Swiftgram
/// Re-run format and frame-rate selection on the running camera after
/// SGCallVideoLimits changed.
- (void)sgReapplyLimits {
    [RTCDispatcher dispatchAsyncOnType:RTCDispatcherTypeCaptureSession block:^{
        if (!_isRunning || _currentDevice == nil || _sgRequestedFormat == nil) {
            return;
        }
        AVCaptureDeviceFormat *format = _sgRequestedFormat;
        NSInteger fps = _sgRequestedFps;
        [self sgApplyLimitsToFormat:&format fps:&fps device:_currentDevice];

        NSError *error = nil;
        if (![_currentDevice lockForConfiguration:&error]) {
            RTCLogError(@"[SGCallVideoLimits] failed to lock device: %@", error.userInfo);
            return;
        }
        [_captureSession beginConfiguration];
        [self updateDeviceCaptureFormat:format fps:fps];
        [self updateVideoDataOutputPixelFormat:format];
        [_captureSession commitConfiguration];
        [_currentDevice unlockForConfiguration];
    }];
}

- (void)reconfigureCaptureSessionInput {
    NSAssert([RTCDispatcher isOnQueueForType:RTCDispatcherTypeCaptureSession],
             @"reconfigureCaptureSessionInput must be called on the capture queue.");
    NSError *error = nil;
    AVCaptureDeviceInput *input =
    [AVCaptureDeviceInput deviceInputWithDevice:_currentDevice error:&error];
    if (!input) {
        RTCLogError(@"Failed to create front camera input: %@", error.localizedDescription);
        return;
    }
    [_captureSession beginConfiguration];
    for (AVCaptureDeviceInput *oldInput in [_captureSession.inputs copy]) {
        [_captureSession removeInput:oldInput];
    }
    if ([_captureSession canAddInput:input]) {
        [_captureSession addInput:input];
    } else {
        RTCLogError(@"Cannot add camera as an input to the session.");
    }
    [_captureSession commitConfiguration];
}

- (void)updateOrientation {
    NSAssert([RTCDispatcher isOnQueueForType:RTCDispatcherTypeCaptureSession],
             @"updateOrientation must be called on the capture queue.");
    if (_didReceiveOrientationUpdate) {
        _orientation = [UIDevice currentDevice].orientation;
    }
}

@end
//
