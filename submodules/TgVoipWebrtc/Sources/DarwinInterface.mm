// MARK: Swiftgram
//
// VENDORED COPY of tgcalls/platform/darwin/DarwinInterface.mm.
//
// The upstream file is excluded from the tgcalls glob in BUILD and replaced by
// this one, for the same reason as the vendored VideoCameraCapturer.mm: the
// tgcalls submodule points at TelegramMessenger/tgcalls, which we cannot push
// to.
//
// Forked from tgcalls e3069322a3d1e16ecb11a5e302242e59ddd7f09e
//
// The divergences, all marked "MARK: Swiftgram", apply SGCallVideoLimits (the
// cooler-video-call settings and thermal governor):
//  - adaptVideoSource clamps the adapter request, so a rotation does not put
//    720p/25fps back;
//  - makeVideoEncoderFactory wraps every encoder so SetRates never asks for
//    more than the bitrate limit. tgcalls has no hook for the bitrate cap
//    (InstanceV2Impl hard-codes 1000 kbit/s), and every instance version gets
//    its encoders from here, so this is the one place that covers all of them.
// When tgcalls updates this file, re-copy it and re-apply those blocks;
// Swiftgram/patches/tgcalls-call-video-limits.patch holds the diff.

#include "DarwinInterface.h"

#include "VideoCapturerInterfaceImpl.h"
#include "sdk/objc/native/src/objc_video_track_source.h"
#include "sdk/objc/native/api/network_monitor_factory.h"

#include "media/base/media_constants.h"
#include "TGRTCDefaultVideoEncoderFactory.h"
#include "TGRTCDefaultVideoDecoderFactory.h"
#include "sdk/objc/native/api/video_encoder_factory.h"
#include "sdk/objc/native/api/video_decoder_factory.h"
#include "pc/video_track_source_proxy.h"
#import "base/RTCLogging.h"
#include "AudioDeviceModuleIOS.h"
#include "AudioDeviceModuleMacos.h"
#include "DarwinVideoSource.h"
#include "objc_video_encoder_factory.h"
#include "objc_video_decoder_factory.h"
#include "sdk/objc/native/src/objc_frame_buffer.h"
#import "sdk/objc/components/video_frame_buffer/RTCCVPixelBuffer.h"

#import "DarwinFFMpeg.h"

#ifdef WEBRTC_IOS
#include "platform/darwin/iOS/RTCAudioSession.h"
#include "platform/darwin/iOS/RTCAudioSessionConfiguration.h"
#import <UIKit/UIKit.h>
#endif // WEBRTC_IOS

#import <AVFoundation/AVFoundation.h>

#include <sys/sysctl.h>

// MARK: Swiftgram
#import <TgVoipWebrtc/SGCallVideoLimits.h>
#include "api/video/video_codec_constants.h"
#include "api/video/video_bitrate_allocation.h"
#include "api/video_codecs/video_codec.h"
#include "api/video_codecs/video_encoder.h"
#include "api/video_codecs/video_encoder_factory.h"

namespace tgcalls {

std::unique_ptr<webrtc::VideoDecoderFactory> CustomObjCToNativeVideoDecoderFactory(
    id<RTC_OBJC_TYPE(RTCVideoDecoderFactory)> objc_video_decoder_factory) {
    return std::make_unique<webrtc::CustomObjCVideoDecoderFactory>(objc_video_decoder_factory);
}

static DarwinVideoTrackSource *getObjCVideoSource(const webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface> nativeSource) {
    webrtc::VideoTrackSourceProxy *proxy_source =
    static_cast<webrtc::VideoTrackSourceProxy *>(nativeSource.get());
    return static_cast<DarwinVideoTrackSource *>(proxy_source->internal());
}

[[maybe_unused]] static NSString *getPlatformInfo() {
    const char *typeSpecifier = "hw.machine";
    
    size_t size;
    sysctlbyname(typeSpecifier, NULL, &size, NULL, 0);
    
    char *answer = (char *)malloc(size);
    sysctlbyname(typeSpecifier, answer, &size, NULL, 0);
    
    NSString *results = [NSString stringWithCString:answer encoding:NSUTF8StringEncoding];
    
    free(answer);
    return results;
}

std::unique_ptr<rtc::NetworkMonitorFactory> DarwinInterface::createNetworkMonitorFactory() {
    return webrtc::CreateNetworkMonitorFactory();
}

void DarwinInterface::configurePlatformAudio(int numChanels) {
}

// MARK: Swiftgram
namespace {

/// Forwards everything to the wrapped encoder, except that SetRates is scaled
/// down to SGCallVideoLimits.maxBitrateKbps / maxFps. Reads the limits on each
/// call, and re-applies the last rates from Encode when they change, so a new
/// limit takes effect on the next frame instead of the next bandwidth update.
class SGLimitingVideoEncoder : public webrtc::VideoEncoder {
public:
    explicit SGLimitingVideoEncoder(std::unique_ptr<webrtc::VideoEncoder> encoder) : _encoder(std::move(encoder)) {
    }

    void SetFecControllerOverride(webrtc::FecControllerOverride *fec_controller_override) override {
        _encoder->SetFecControllerOverride(fec_controller_override);
    }

    int32_t InitEncode(const webrtc::VideoCodec *codec_settings, int32_t number_of_cores, size_t max_payload_size) override {
        return _encoder->InitEncode(codec_settings, number_of_cores, max_payload_size);
    }

    int InitEncode(const webrtc::VideoCodec *codec_settings, const webrtc::VideoEncoder::Settings &settings) override {
        return _encoder->InitEncode(codec_settings, settings);
    }

    int32_t RegisterEncodeCompleteCallback(webrtc::EncodedImageCallback *callback) override {
        return _encoder->RegisterEncodeCompleteCallback(callback);
    }

    int32_t Release() override {
        _hasRates = false;
        return _encoder->Release();
    }

    int32_t Encode(const webrtc::VideoFrame &frame, const std::vector<webrtc::VideoFrameType> *frame_types) override {
        if (_hasRates && [SGCallVideoLimits shared].generation != _appliedGeneration) {
            applyRates();
        }
        return _encoder->Encode(frame, frame_types);
    }

    void SetRates(const webrtc::VideoEncoder::RateControlParameters &parameters) override {
        _lastRates = parameters;
        _hasRates = true;
        applyRates();
    }

    void OnPacketLossRateUpdate(float packet_loss_rate) override {
        _encoder->OnPacketLossRateUpdate(packet_loss_rate);
    }

    void OnRttUpdate(int64_t rtt_ms) override {
        _encoder->OnRttUpdate(rtt_ms);
    }

    void OnLossNotification(const webrtc::VideoEncoder::LossNotification &loss_notification) override {
        _encoder->OnLossNotification(loss_notification);
    }

    webrtc::VideoEncoder::EncoderInfo GetEncoderInfo() const override {
        return _encoder->GetEncoderInfo();
    }

private:
    static webrtc::VideoBitrateAllocation scaled(const webrtc::VideoBitrateAllocation &allocation, double factor) {
        webrtc::VideoBitrateAllocation result = allocation;
        for (size_t spatial = 0; spatial < webrtc::kMaxSpatialLayers; spatial++) {
            for (size_t temporal = 0; temporal < webrtc::kMaxTemporalStreams; temporal++) {
                if (allocation.HasBitrate(spatial, temporal)) {
                    result.SetBitrate(spatial, temporal, (uint32_t)(allocation.GetBitrate(spatial, temporal) * factor));
                }
            }
        }
        return result;
    }

    void applyRates() {
        SGCallVideoLimits *limits = [SGCallVideoLimits shared];
        _appliedGeneration = limits.generation;
        const int32_t maxKbps = limits.maxBitrateKbps;
        const int32_t maxFps = limits.maxFps;

        webrtc::VideoEncoder::RateControlParameters rates = _lastRates;
        const uint32_t requestedBps = rates.bitrate.get_sum_bps();
        uint32_t appliedBps = requestedBps;
        if (maxKbps > 0) {
            const uint32_t capBps = (uint32_t)maxKbps * 1000;
            if (rates.bitrate.get_sum_bps() > capBps) {
                rates.bitrate = scaled(rates.bitrate, (double)capBps / (double)rates.bitrate.get_sum_bps());
            }
            if (rates.target_bitrate.get_sum_bps() > capBps) {
                rates.target_bitrate = scaled(rates.target_bitrate, (double)capBps / (double)rates.target_bitrate.get_sum_bps());
            }
            appliedBps = rates.bitrate.get_sum_bps();
        }
        if (maxFps > 0 && rates.framerate_fps > (double)maxFps) {
            rates.framerate_fps = (double)maxFps;
        }

        // Log only when the clamp starts, stops, or the cap changes; SetRates
        // runs on every bandwidth-estimate update.
        const bool isClamped = appliedBps < requestedBps;
        if (isClamped != _wasClamped || (isClamped && maxKbps != _loggedCapKbps)) {
            _wasClamped = isClamped;
            _loggedCapKbps = maxKbps;
            if (isClamped) {
                NSLog(@"[SGCallVideoLimits] encoder bitrate clamped %u -> %u kbit/s (cap %d)", requestedBps / 1000, appliedBps / 1000, maxKbps);
            } else {
                NSLog(@"[SGCallVideoLimits] encoder bitrate unclamped at %u kbit/s", requestedBps / 1000);
            }
        }

        _encoder->SetRates(rates);
    }

    std::unique_ptr<webrtc::VideoEncoder> _encoder;
    webrtc::VideoEncoder::RateControlParameters _lastRates;
    bool _hasRates = false;
    int64_t _appliedGeneration = -1;
    bool _wasClamped = false;
    int32_t _loggedCapKbps = 0;
};

class SGLimitingVideoEncoderFactory : public webrtc::VideoEncoderFactory {
public:
    explicit SGLimitingVideoEncoderFactory(std::unique_ptr<webrtc::VideoEncoderFactory> factory) : _factory(std::move(factory)) {
    }

    std::vector<webrtc::SdpVideoFormat> GetSupportedFormats() const override {
        return _factory->GetSupportedFormats();
    }

    std::vector<webrtc::SdpVideoFormat> GetImplementations() const override {
        return _factory->GetImplementations();
    }

    webrtc::VideoEncoderFactory::CodecSupport QueryCodecSupport(const webrtc::SdpVideoFormat &format, absl::optional<std::string> scalability_mode) const override {
        return _factory->QueryCodecSupport(format, scalability_mode);
    }

    std::unique_ptr<webrtc::VideoEncoder> CreateVideoEncoder(const webrtc::SdpVideoFormat &format) override {
        auto encoder = _factory->CreateVideoEncoder(format);
        if (!encoder) {
            return nullptr;
        }
        return std::make_unique<SGLimitingVideoEncoder>(std::move(encoder));
    }

    std::unique_ptr<webrtc::VideoEncoderFactory::EncoderSelectorInterface> GetEncoderSelector() const override {
        return _factory->GetEncoderSelector();
    }

private:
    std::unique_ptr<webrtc::VideoEncoderFactory> _factory;
};

}

static std::unique_ptr<webrtc::VideoEncoderFactory> sgMakeUpstreamVideoEncoderFactory(bool preferHardwareEncoding, bool isScreencast);

std::unique_ptr<webrtc::VideoEncoderFactory> DarwinInterface::makeVideoEncoderFactory(bool preferHardwareEncoding, bool isScreencast) {
    // MARK: Swiftgram: screencasts keep upstream behaviour; the limits are
    // about the camera.
    if (!isScreencast) {
        return std::make_unique<SGLimitingVideoEncoderFactory>(sgMakeUpstreamVideoEncoderFactory(preferHardwareEncoding, isScreencast));
    }
    return sgMakeUpstreamVideoEncoderFactory(preferHardwareEncoding, isScreencast);
}

// MARK: Swiftgram: upstream's makeVideoEncoderFactory body, unchanged.
static std::unique_ptr<webrtc::VideoEncoderFactory> sgMakeUpstreamVideoEncoderFactory(bool preferHardwareEncoding, bool isScreencast) {
    auto nativeFactory = std::make_unique<webrtc::CustomObjCVideoEncoderFactory>([[TGRTCDefaultVideoEncoderFactory alloc] initWithPreferHardwareH264:preferHardwareEncoding preferX264:false]);
    if (!preferHardwareEncoding) {
        auto nativeHardwareFactory = std::make_unique<webrtc::CustomObjCVideoEncoderFactory>([[TGRTCDefaultVideoEncoderFactory alloc] initWithPreferHardwareH264:!isScreencast preferX264:false]);
        return std::make_unique<webrtc::SimulcastVideoEncoderFactory>(std::move(nativeFactory), std::move(nativeHardwareFactory));
    }
    return nativeFactory;
}

std::unique_ptr<webrtc::VideoDecoderFactory> DarwinInterface::makeVideoDecoderFactory() {
    return CustomObjCToNativeVideoDecoderFactory([[TGRTCDefaultVideoDecoderFactory alloc] init]);
}

bool DarwinInterface::supportsEncoding(const std::string &codecName) {
    if (false) {
    }
#ifndef WEBRTC_DISABLE_H265
    else if (codecName == cricket::kH265CodecName) {
#ifdef WEBRTC_IOS
		if (@available(iOS 11.0, *)) {
			return [[AVAssetExportSession allExportPresets] containsObject:AVAssetExportPresetHEVCHighestQuality];
		}
#elif defined WEBRTC_MAC // WEBRTC_IOS
        
#ifdef __x86_64__
        return NO;
#else
        return YES;
#endif
#endif // WEBRTC_IOS || WEBRTC_MAC
    }
#endif
    else if (codecName == cricket::kH264CodecName) {
#ifdef __x86_64__
        return YES;
#else
        return NO;
#endif
    } else if (codecName == cricket::kVp8CodecName) {
        return true;
    } else if (codecName == cricket::kVp9CodecName) {
        return true;
    }
    return false;
}

webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface> DarwinInterface::makeVideoSource(rtc::Thread *signalingThread, rtc::Thread *workerThread) {
    webrtc::scoped_refptr<tgcalls::DarwinVideoTrackSource> objCVideoTrackSource(new rtc::RefCountedObject<tgcalls::DarwinVideoTrackSource>());
    return webrtc::VideoTrackSourceProxy::Create(signalingThread, workerThread, objCVideoTrackSource);
}

void DarwinInterface::adaptVideoSource(webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface> videoSource, int width, int height, int fps) {
    // MARK: Swiftgram
    // VideoCaptureInterfaceImpl re-requests 720x1280 @ 25 on every rotation;
    // keep the request inside SGCallVideoLimits so that does not undo them.
    SGCallVideoLimits *limits = [SGCallVideoLimits shared];
    const int32_t maxShortSide = limits.maxShortSide;
    const int32_t maxFps = limits.maxFps;
    const int shortSide = MIN(width, height);
    if (maxShortSide > 0 && shortSide > maxShortSide) {
        const double scale = (double)maxShortSide / (double)shortSide;
        width = ((int)(width * scale)) & ~1;
        height = ((int)(height * scale)) & ~1;
    }
    if (maxFps > 0 && fps > maxFps) {
        fps = maxFps;
    }
    getObjCVideoSource(videoSource)->OnOutputFormatRequest(width, height, fps);
}

std::unique_ptr<VideoCapturerInterface> DarwinInterface::makeVideoCapturer(webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface> source, std::string deviceId, std::function<void(VideoState)> stateUpdated, std::function<void(PlatformCaptureInfo)> captureInfoUpdated, std::shared_ptr<PlatformContext> platformContext, std::pair<int, int> &outResolution) {
    return std::make_unique<VideoCapturerInterfaceImpl>(source, deviceId, stateUpdated, captureInfoUpdated, outResolution);
}

webrtc::scoped_refptr<WrappedAudioDeviceModule> DarwinInterface::wrapAudioDeviceModule(webrtc::scoped_refptr<webrtc::AudioDeviceModule> module) {
#ifdef WEBRTC_IOS
    return rtc::make_ref_counted<AudioDeviceModuleIOS>(module);
#else
    return rtc::make_ref_counted<AudioDeviceModuleMacos>(module);
#endif
}

void DarwinInterface::setupVideoDecoding(AVCodecContext *codecContext) {
    return setupDarwinVideoDecoding(codecContext);
}

webrtc::scoped_refptr<webrtc::VideoFrameBuffer> DarwinInterface::createPlatformFrameFromData(AVFrame const *frame) {
    return createDarwinPlatformFrameFromData(frame);
}

std::unique_ptr<PlatformInterface> CreatePlatformInterface() {
	return std::make_unique<DarwinInterface>();
}

DarwinVideoFrame::DarwinVideoFrame(CVPixelBufferRef pixelBuffer) {
    _pixelBuffer = CVPixelBufferRetain(pixelBuffer);
}

DarwinVideoFrame::~DarwinVideoFrame() {
    if (_pixelBuffer) {
        CVPixelBufferRelease(_pixelBuffer);
    }
}

} // namespace tgcalls
