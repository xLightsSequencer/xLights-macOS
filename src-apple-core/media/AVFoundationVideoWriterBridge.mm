/***************************************************************
 * This source files comes from the xLights project
 * https://www.xlights.org
 * https://github.com/xLightsSequencer/xLights
 * See the github commit history for a record of contributing
 * developers.
 * Copyright claimed based on commit dates recorded in Github
 * License: https://github.com/xLightsSequencer/xLights/blob/master/License.txt
 **************************************************************/

// AVAssetWriter-backed implementation of the video-writer bridge ABI
// declared in AVFoundationVideoWriterBridge.h. All Apple SDK types stay
// confined to this .mm; the cross-platform AVFoundationVideoWriter only
// ever sees the pure-C++ namespace functions and an opaque WriterHandle.
//
// DRIVING MODEL. The non-real-time AVAssetWriter contract REQUIRES
// requestMediaDataWhenReadyOnQueue: — that is the mechanism that actually
// maintains isReadyForMoreMediaData. (Manually polling the flag from the
// caller's thread is unsupported and leaves it stuck NO, deadlocking the
// export.) So each input is fed from a block AVFoundation invokes on a
// dedicated serial queue whenever the input is ready. VIDEO frames come from
// a bounded queue the main-thread render loop fills (RequestPixelBuffer ->
// render -> AppendVideoFrame); the bound gives backpressure and rendering
// stays on the main thread (Metal/GL requirement). AUDIO is pull-driven: the
// request block pulls PCM straight from the caller's AudioPullFn (BeginAudio)
// so the audio supply never depends on the producer thread — AVAssetWriter
// interleaves, and it stops accepting video whenever it lacks the matching
// audio, so audio starvation deadlocks a backpressured producer.
//
// Request blocks must NEVER park on their serial queue: they run inside
// AVAssetWriter's per-input media-data requester, and blocking there wedges
// the writer's servicing of its other input and its readiness updates
// (observed: a parked audio block froze the video input's readiness with
// video frames queued and waiting).
//
// All Xcode targets compile with ARC: ObjC pointers held in the C++
// WriterHandle are __strong. CoreFoundation/CoreMedia types
// (CVPixelBufferRef, CMSampleBufferRef, ...) are NOT ARC-managed and use
// explicit CFRetain/CFRelease.

#include "media/AVFoundationVideoWriterBridge.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <VideoToolbox/VideoToolbox.h>

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <filesystem>
#include <mutex>
#include <vector>

#include <log.h>

namespace AppleAVFoundationVideoWriterBridge {

namespace {

#ifdef TARGET_OS_IPHONE
constexpr size_t kMaxQueuedItems = 8;          // video backpressure bound (~100 MB at 4K); audio is unbounded
#else
constexpr size_t kMaxQueuedItems = 16;         // video backpressure bound (~200 MB at 4K); audio is unbounded
#endif
constexpr int64_t kFinishTimeoutSecs = 120;   // hard cap so Finish can't hang forever
constexpr int kAudioPullChunkSamples = 16384; // ~0.37s at 44.1kHz per pulled sample buffer

std::string LowerExt(const std::string& path)
{
    std::string ext = std::filesystem::path(path).extension().string();
    if (!ext.empty() && ext[0] == '.') {
        ext.erase(0, 1);
    }
    std::transform(ext.begin(), ext.end(), ext.begin(),
                   [](unsigned char c) { return std::tolower(c); });
    return ext;
}

bool IsMovExt(const std::string& ext) { return ext == "mov" || ext == "qt"; }
bool IsMp4Ext(const std::string& ext) { return ext == "mp4" || ext == "m4v"; }

bool CodecIsHEVC(const std::string& c) { return c.find("H.265") != std::string::npos || c.find("HEVC") != std::string::npos || c.find("hevc") != std::string::npos; }
bool CodecIsH264(const std::string& c) { return c.find("H.264") != std::string::npos; }
bool CodecIsProRes(const std::string& c) { return c.find("ProRes") != std::string::npos || c.find("prores") != std::string::npos; }
bool CodecIsRaw(const std::string& c) { return c.find("rawvideo") != std::string::npos; }
// "Auto" / empty: the user's default Video Export codec. BuildWriter maps it to
// H.264, so AVFoundation can encode it — treat it as H.264-encodable so the
// House Preview export (which passes "Auto") uses AVFoundation rather than
// falling back to the much slower FFmpeg software encoder.
bool CodecIsAuto(const std::string& c) { return c.empty() || c.find("Auto") != std::string::npos || c.find("auto") != std::string::npos; }

struct VideoItem {
    CVPixelBufferRef pixbuf = nullptr;  // retained
    CMTime pts = kCMTimeZero;
};

} // namespace

struct WriterHandle {
    // --- configuration ---
    std::string path;
    std::string videoCodec;
    int width = 0;
    int height = 0;
    int fps = 30;
    int bitrateKbps = 0;
    double quality = 0.0;   // >0: AVVideoQualityKey constant-quality mode
    bool hasAudio = false;
    int sampleRate = 0;
    bool cpuFrames = false;   // true: frames arrive as CPU RGB/RGBA via FillPixelBufferRGB
    int inputChannels = 3;

    // --- AVFoundation objects (touched only on videoQ/audioQ) ---
    AVAssetWriter* writer = nil;
    AVAssetWriterInput* videoInput = nil;
    AVAssetWriterInputPixelBufferAdaptor* adaptor = nil;
    AVAssetWriterInput* audioInput = nil;
    CVPixelBufferPoolRef pool = nullptr;   // CF-retained; used by the producer

    // CPU-frame -> NV12 fill: RGB is copied into scratchBGRA, then CoreImage
    // renders that into the pool's full-range NV12 buffer. Going through a
    // CVPixelBuffer (not a raw bitmap) keeps the orientation 1:1.
    CVPixelBufferRef scratchBGRA = nullptr;
    CIContext* ciContext = nil;

    dispatch_queue_t videoQ = nil;
    dispatch_queue_t audioQ = nil;

    // --- bounded video source queue filled by the producer (main thread) ---
    std::mutex mtx;
    std::condition_variable cv;
    std::deque<VideoItem> videoItems;

    // --- pull-driven audio source (BeginAudio; touched only on audioQ after install) ---
    AudioPullFn audioPull;
    long long audioTotalSamples = 0;
    long long audioSamplesPulled = 0;
    std::vector<float> audioScratchL;
    std::vector<float> audioScratchR;

    bool ended = false;            // producer has handed off all samples
    bool cancelled = false;        // abort requested
    bool failed = false;           // an append failed
    int pendingInputs = 0;         // inputs not yet markAsFinished
    bool finishTriggered = false;  // finishWriting / cancelWriting issued once
    bool finalSuccess = false;
    dispatch_semaphore_t finishSem = nil;
};

bool CanExport(const std::string& outPath, const std::string& videoCodec)
{
    const std::string ext = LowerExt(outPath);
    if (!IsMovExt(ext) && !IsMp4Ext(ext)) {
        return false;
    }
    if (CodecIsRaw(videoCodec)) {
        return IsMovExt(ext);  // uncompressed BGRA passthrough — QuickTime only (no AVI)
    }
    if (CodecIsProRes(videoCodec)) {
        return IsMovExt(ext);  // ProRes belongs in a QuickTime container
    }
    // "Auto" is encodable — CreateWriter maps it to HEVC.
    return CodecIsH264(videoCodec) || CodecIsHEVC(videoCodec) || CodecIsAuto(videoCodec);
}

namespace {

// Issue finishWriting (or cancelWriting) exactly once and signal finishSem
// from its completion. Caller must hold no lock affecting AVFoundation.
void TriggerFinish(WriterHandle* h, bool cancel)
{
    {
        std::lock_guard<std::mutex> lk(h->mtx);
        if (h->finishTriggered) {
            return;
        }
        h->finishTriggered = true;
    }
    if (cancel) {
        [h->writer cancelWriting];
        NSURL* url = h->writer.outputURL;
        if (url != nil) {
            [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        }
        {
            std::lock_guard<std::mutex> lk(h->mtx);
            h->finalSuccess = false;
        }
        dispatch_semaphore_signal(h->finishSem);
        return;
    }
    [h->writer finishWritingWithCompletionHandler:^{
        bool s = (h->writer.status == AVAssetWriterStatusCompleted);
        if (!s) {
            spdlog::error("AVFoundationVideoWriter: finishWriting failed (status {}): {}",
                          static_cast<long>(h->writer.status),
                          h->writer.error ? [h->writer.error.localizedDescription UTF8String] : "?");
        }
        {
            std::lock_guard<std::mutex> lk(h->mtx);
            h->finalSuccess = s;
        }
        dispatch_semaphore_signal(h->finishSem);
    }];
}

// One input has exhausted its data; mark it finished and, when all inputs are
// done, finish the file.
void InputFinished(WriterHandle* h, AVAssetWriterInput* input)
{
    [input markAsFinished];
    bool last = false;
    {
        std::lock_guard<std::mutex> lk(h->mtx);
        if (--h->pendingInputs <= 0) {
            last = true;
        }
    }
    if (last) {
        TriggerFinish(h, false /*cancel*/);
    }
}

void FailWriter(WriterHandle* h, const char* what)
{
    spdlog::error("AVFoundationVideoWriter: {}: {}", what,
                  h->writer.error ? [h->writer.error.localizedDescription UTF8String] : "?");
    {
        std::lock_guard<std::mutex> lk(h->mtx);
        h->failed = true;
        h->cancelled = true;
    }
    h->cv.notify_all();  // release any producer blocked on backpressure
    TriggerFinish(h, true /*cancel*/);
}

// Constant-quality encoding is an encoder capability, not a codec one: Apple
// Silicon's H.264/HEVC encoders take AVVideoQualityKey, the Intel hardware H.264
// encoder does not and raises NSInvalidArgumentException the moment it's handed
// one. Ask VideoToolbox what this machine's encoder actually supports rather
// than inferring it from the codec or the CPU.
bool EncoderSupportsQuality(CMVideoCodecType codec, int32_t width, int32_t height)
{
    CFDictionaryRef props = nullptr;
    CFStringRef encoderId = nullptr;
    const OSStatus st = VTCopySupportedPropertyDictionaryForEncoder(width, height, codec,
                                                                    nullptr, &encoderId, &props);
    if (encoderId != nullptr) {
        CFRelease(encoderId);
    }
    if (st != noErr || props == nullptr) {
        if (props != nullptr) {
            CFRelease(props);
        }
        return false;
    }
    const bool supported = CFDictionaryContainsKey(props, kVTCompressionPropertyKey_Quality);
    CFRelease(props);
    return supported;
}

bool BuildWriter(WriterHandle* h)
{
    @autoreleasepool {
        const std::string ext = LowerExt(h->path);
        AVFileType fileType = IsMovExt(ext) ? AVFileTypeQuickTimeMovie : AVFileTypeMPEG4;

        NSString* nsPath = [NSString stringWithUTF8String:h->path.c_str()];
        NSURL* url = [NSURL fileURLWithPath:nsPath];
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];

        NSError* err = nil;
        AVAssetWriter* writer = [AVAssetWriter assetWriterWithURL:url fileType:fileType error:&err];
        if (writer == nil) {
            spdlog::error("AVFoundationVideoWriter: failed to create AVAssetWriter for {}: {}",
                          h->path, err ? [err.localizedDescription UTF8String] : "?");
            return false;
        }

        const bool isRaw = CodecIsRaw(h->videoCodec);
        AVAssetWriterInput* videoInput = nil;

        if (isRaw) {
            // Uncompressed passthrough: no encoder. A BGRA sourceFormatHint with
            // outputSettings:nil stores the raw pixel bytes bit-exact, at any
            // dimensions and preserving alpha. The CPU-frame path already fills
            // BGRA pool buffers, so nothing else changes.
            CVPixelBufferRef sample = nullptr;
            NSDictionary* sopts = @{ (NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{} };
            CVPixelBufferCreate(kCFAllocatorDefault, h->width, h->height, kCVPixelFormatType_32BGRA,
                                (__bridge CFDictionaryRef)sopts, &sample);
            CMVideoFormatDescriptionRef fd = nullptr;
            if (sample != nullptr) {
                CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, sample, &fd);
                CVPixelBufferRelease(sample);
            }
            if (fd == nullptr) {
                spdlog::error("AVFoundationVideoWriter: could not build raw passthrough format description");
                return false;
            }
            videoInput = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo
                                                        outputSettings:nil
                                                      sourceFormatHint:fd];
            CFRelease(fd);
        } else {
            NSString* codecKey = AVVideoCodecTypeH264;
            if (CodecIsHEVC(h->videoCodec)) {
                codecKey = AVVideoCodecTypeHEVC;
            } else if (CodecIsProRes(h->videoCodec)) {
                codecKey = AVVideoCodecTypeAppleProRes4444;
            }

            const CMVideoCodecType codecType = CodecIsHEVC(h->videoCodec)   ? kCMVideoCodecType_HEVC
                                             : CodecIsProRes(h->videoCodec) ? kCMVideoCodecType_AppleProRes4444
                                                                            : kCMVideoCodecType_H264;
            // Encoders without a constant-quality mode (notably Intel H.264) throw
            // rather than ignore AVVideoQualityKey, so they take the average-bitrate
            // path below instead.
            const bool canUseQuality = !CodecIsProRes(h->videoCodec)
                                       && EncoderSupportsQuality(codecType, h->width, h->height);
            if (h->quality > 0.0 && !canUseQuality && !CodecIsProRes(h->videoCodec)) {
                spdlog::info("AVFoundationVideoWriter: encoder for codec {} has no constant-quality mode; using average bitrate instead", h->videoCodec);
            }

            NSMutableDictionary* compression = [NSMutableDictionary dictionary];
            bool useQuality = (h->quality > 0.0) && canUseQuality;
            auto quality = h->quality;
            // Auto (no explicit bitrate): default H.264/HEVC to constant-quality
            // so VideoToolbox picks a content-adaptive bitrate. NOT for ProRes —
            // it's a fixed-profile codec that takes neither AVVideoQualityKey nor
            // a bitrate (setting AVVideoQualityKey on it is invalid and can throw).
            if (!useQuality && h->bitrateKbps <= 0 && canUseQuality) {
                useQuality = true;
                quality = 0.80;
                if (@available(macOS 11.0, iOS 14.0, *)) {
                    compression[(__bridge NSString*)kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality] = @YES;
                }
            }
            if (useQuality) {
                // Constant-quality mode (AVVideoQualityKey, 0..1) — crisper than
                // any average-bitrate target for easy content, which VideoToolbox
                // undershoots.
                compression[AVVideoQualityKey] = @(quality > 1.0 ? 1.0 : quality);
                compression[AVVideoExpectedSourceFrameRateKey] = @(h->fps);
            } else if (!CodecIsProRes(h->videoCodec)) {
                // Average-bitrate mode. When the user didn't pick a bitrate
                // (Preferences → Video Export Settings, 0 = Auto), target a
                // sensible quality/size default. The previous defaults were
                // ~2x too high (HEVC came out larger than a typical H.264).
                long long bps;
                if (h->bitrateKbps > 0) {
                    bps = static_cast<long long>(h->bitrateKbps) * 1000;
                } else {
                    // bits per pixel per frame. HEVC is ~40% more efficient than
                    // H.264, so it gets the lower bpp; both produce good quality
                    // for LED/preview content while keeping files reasonable
                    // (e.g. 3456x2120@40 → ~20 Mbps HEVC). Bump the bitrate in
                    // preferences for archival-grade output.
                    const double bpp = CodecIsHEVC(h->videoCodec) ? 0.07 : 0.11;
                    bps = static_cast<long long>(static_cast<double>(h->width) * h->height * h->fps * bpp);
                    if (bps < 2000000) {
                        bps = 2000000;  // floor for tiny / low-fps exports
                    }
                }
                compression[AVVideoAverageBitRateKey] = @(bps);
                // Offline export: bias VideoToolbox toward throughput (prio_speed=1),
                // the way the FFmpeg path did. AVAssetWriter forwards raw VT keys here.
                if (@available(macOS 11.0, iOS 14.0, *)) {
                    compression[(__bridge NSString*)kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality] = @YES;
                }
                compression[AVVideoExpectedSourceFrameRateKey] = @(h->fps);
            }

            // NOTE: we intentionally do NOT disable frame reordering or cap the
            // frame-delay count for HEVC. An earlier "encoder hoards ~46 frames
            // and never becomes ready" stall looked like an unlimited-frame-delay
            // problem, but the real cause was audio starvation: the writer sits
            // on the encoder's ~46-frame warm-up window and stops accepting
            // video until it has the audio to interleave, and audio used to be
            // produced by the same (video-backpressured) thread. Audio is now
            // pull-driven (see InstallAudioRequest), so the encoder streams
            // normally — and leaving B-frames / default lookahead on gives
            // noticeably better compression for the same quality. The lookahead
            // does pin ~46 source frames inside VideoToolbox; cap
            // kVTCompressionPropertyKey_MaxFrameDelayCount here if that memory
            // ever needs to shrink.

            NSMutableDictionary* videoSettings = [NSMutableDictionary dictionary];
            videoSettings[AVVideoCodecKey] = codecKey;
            videoSettings[AVVideoWidthKey] = @(h->width);
            videoSettings[AVVideoHeightKey] = @(h->height);
            if (compression.count > 0) {
                videoSettings[AVVideoCompressionPropertiesKey] = compression;
            }
            videoSettings[AVVideoColorPropertiesKey] = @{
                AVVideoColorPrimariesKey : AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey : AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey : AVVideoYCbCrMatrix_ITU_R_709_2,
            };

            videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                           outputSettings:videoSettings];
        }
        videoInput.expectsMediaDataInRealTime = NO;
        if (![writer canAddInput:videoInput]) {
            spdlog::error("AVFoundationVideoWriter: cannot add video input (codec {})", h->videoCodec);
            return false;
        }
        [writer addInput:videoInput];

        // H.264/H.265 feed full-range BT.709 NV12 (color_range=pc) — both the GPU
        // house preview (canvas renders into it) and the CPU-frame callers
        // (FillPixelBufferRGB renders RGB into it via CoreImage). ProRes /
        // rawvideo feed BGRA: ProRes 4444 must keep the alpha, and rawvideo is a
        // bit-exact BGRA passthrough.
        const OSType pixFmt = (CodecIsProRes(h->videoCodec) || CodecIsRaw(h->videoCodec))
                                  ? kCVPixelFormatType_32BGRA
                                  : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
        NSDictionary* pbAttrs = @{
            (NSString*)kCVPixelBufferPixelFormatTypeKey : @(pixFmt),
            (NSString*)kCVPixelBufferWidthKey : @(h->width),
            (NSString*)kCVPixelBufferHeightKey : @(h->height),
            (NSString*)kCVPixelBufferMetalCompatibilityKey : @YES,
            (NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{},
        };
        AVAssetWriterInputPixelBufferAdaptor* adaptor =
            [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:videoInput
                                                                            sourcePixelBufferAttributes:pbAttrs];

        AVAssetWriterInput* audioInput = nil;
        if (h->hasAudio && h->sampleRate > 0) {
            NSDictionary* audioSettings = @{
                AVFormatIDKey : @(kAudioFormatMPEG4AAC),
                AVNumberOfChannelsKey : @(2),
                AVSampleRateKey : @(h->sampleRate),
                AVEncoderBitRateKey : @(128000),
            };
            audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                           outputSettings:audioSettings];
            audioInput.expectsMediaDataInRealTime = NO;
            if ([writer canAddInput:audioInput]) {
                [writer addInput:audioInput];
            } else {
                spdlog::warn("AVFoundationVideoWriter: cannot add audio input; exporting video only");
                audioInput = nil;
            }
        }

        if (![writer startWriting]) {
            spdlog::error("AVFoundationVideoWriter: startWriting failed: {}",
                          writer.error ? [writer.error.localizedDescription UTF8String] : "?");
            return false;
        }
        [writer startSessionAtSourceTime:kCMTimeZero];

        CVPixelBufferPoolRef pool = adaptor.pixelBufferPool;
        if (pool != nullptr) {
            h->pool = (CVPixelBufferPoolRef)CFRetain(pool);
        }

        h->writer = writer;
        h->videoInput = videoInput;
        h->adaptor = adaptor;
        h->audioInput = audioInput;
        h->hasAudio = (audioInput != nil);

        spdlog::info("AVFoundationVideoWriter: started writer (codec {}, {}x{} @ {}fps, audio={}); status {}",
                     h->videoCodec, h->width, h->height, h->fps, h->hasAudio, static_cast<long>(writer.status));
        return true;
    }
}

void InstallVideoRequest(WriterHandle* h)
{
    AVAssetWriterInput* input = h->videoInput;
    AVAssetWriterInputPixelBufferAdaptor* adaptor = h->adaptor;
    [input requestMediaDataWhenReadyOnQueue:h->videoQ usingBlock:^{
        while (input.isReadyForMoreMediaData) {
            VideoItem item;
            bool have = false;
            bool finish = false;
            {
                std::unique_lock<std::mutex> lk(h->mtx);
                // Bounded wait only — NEVER park here. This block runs inside
                // AVAssetWriter's per-input media-data requester; parking it
                // wedges the writer's servicing of its other input and its
                // readiness updates (observed: a parked audio block froze the
                // video input's readiness while video frames sat queued).
                // Returning empty-handed is fine; the requester re-invokes.
                h->cv.wait_for(lk, std::chrono::milliseconds(5),
                               [h] { return !h->videoItems.empty() || h->ended || h->cancelled; });
                if (h->cancelled) {
                    return;
                }
                if (!h->videoItems.empty()) {
                    item = h->videoItems.front();
                    h->videoItems.pop_front();
                    have = true;
                } else if (h->ended) {
                    finish = true;
                }
            }
            h->cv.notify_all();  // wake a producer blocked on backpressure

            if (finish) {
                InputFinished(h, input);
                return;
            }
            if (!have) {
                return;  // no data yet — the requester will re-invoke us
            }
            if (!input.isReadyForMoreMediaData) {
                std::lock_guard<std::mutex> lk(h->mtx);
                h->videoItems.push_front(item);  // try again on next ready callback
                return;
            }
            BOOL ok = NO;
            @try {
                ok = [adaptor appendPixelBuffer:item.pixbuf withPresentationTime:item.pts];
            } @catch (NSException* e) {
                spdlog::error("AVFoundationVideoWriter: appendPixelBuffer threw: {}",
                              e.reason ? [e.reason UTF8String] : "?");
                ok = NO;
            }
            CVPixelBufferRelease(item.pixbuf);
            if (!ok) {
                FailWriter(h, "video append failed");
                return;
            }
        }
    }];
}

// Build a stereo float PCM CMSampleBuffer at presentation time
// sampleOffset/sampleRate from planar left/right data. Returns +1 (caller
// releases) or nullptr on failure.
CMSampleBufferRef MakeAudioSampleBuffer(int sampleRate, const float* left, const float* right,
                                        int numSamples, long long sampleOffset)
{
    const int channels = 2;
    const size_t bytesPerFrame = channels * sizeof(float);
    const size_t byteCount = static_cast<size_t>(numSamples) * bytesPerFrame;

    std::vector<float> interleaved(static_cast<size_t>(numSamples) * channels);
    for (int i = 0; i < numSamples; ++i) {
        interleaved[2 * i] = left[i];
        interleaved[2 * i + 1] = right[i];
    }

    AudioStreamBasicDescription asbd = {};
    asbd.mSampleRate = sampleRate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    asbd.mBytesPerPacket = static_cast<UInt32>(bytesPerFrame);
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = static_cast<UInt32>(bytesPerFrame);
    asbd.mChannelsPerFrame = channels;
    asbd.mBitsPerChannel = 32;

    CMAudioFormatDescriptionRef format = nullptr;
    OSStatus st = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, nullptr, 0, nullptr, nullptr, &format);
    if (st != noErr || format == nullptr) {
        spdlog::error("AVFoundationVideoWriter: CMAudioFormatDescriptionCreate failed ({})", static_cast<int>(st));
        return nullptr;
    }

    CMBlockBufferRef blockBuffer = nullptr;
    st = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, byteCount, kCFAllocatorDefault,
                                            nullptr, 0, byteCount, kCMBlockBufferAssureMemoryNowFlag, &blockBuffer);
    if (st != noErr || blockBuffer == nullptr) {
        spdlog::error("AVFoundationVideoWriter: CMBlockBufferCreateWithMemoryBlock failed ({})", static_cast<int>(st));
        CFRelease(format);
        return nullptr;
    }
    st = CMBlockBufferReplaceDataBytes(interleaved.data(), blockBuffer, 0, byteCount);
    if (st != noErr) {
        spdlog::error("AVFoundationVideoWriter: CMBlockBufferReplaceDataBytes failed ({})", static_cast<int>(st));
        CFRelease(blockBuffer);
        CFRelease(format);
        return nullptr;
    }

    CMSampleTimingInfo timing;
    timing.duration = CMTimeMake(1, sampleRate);
    timing.presentationTimeStamp = CMTimeMake(sampleOffset, sampleRate);
    timing.decodeTimeStamp = kCMTimeInvalid;
    size_t sampleSize = bytesPerFrame;

    CMSampleBufferRef sampleBuffer = nullptr;
    st = CMSampleBufferCreate(kCFAllocatorDefault, blockBuffer, true, nullptr, nullptr, format,
                              numSamples, 1, &timing, 1, &sampleSize, &sampleBuffer);
    CFRelease(blockBuffer);
    CFRelease(format);
    if (st != noErr || sampleBuffer == nullptr) {
        spdlog::error("AVFoundationVideoWriter: CMSampleBufferCreate failed ({})", static_cast<int>(st));
        return nullptr;
    }
    return sampleBuffer;
}

// Pull-driven audio: whenever the audio input wants data, synthesize the next
// chunk directly from the caller's pull callback. The audio supply therefore
// never depends on the (possibly backpressured) producer thread — essential,
// because AVAssetWriter only keeps accepting video while it has the audio it
// needs to interleave; starving this input was the sub-48-frame-queue hang.
// The block always either appends or finishes — it never exits empty while
// the input is still ready, and it never waits.
void InstallAudioRequest(WriterHandle* h)
{
    AVAssetWriterInput* input = h->audioInput;
    [input requestMediaDataWhenReadyOnQueue:h->audioQ usingBlock:^{
        while (input.isReadyForMoreMediaData) {
            {
                std::lock_guard<std::mutex> lk(h->mtx);
                if (h->cancelled || h->failed) {
                    return;
                }
            }
            const long long remaining = h->audioTotalSamples - h->audioSamplesPulled;
            if (remaining <= 0) {
                InputFinished(h, input);
                return;
            }
            const int chunk = static_cast<int>(std::min<long long>(remaining, kAudioPullChunkSamples));
            h->audioScratchL.assign(static_cast<size_t>(chunk), 0.0f);
            h->audioScratchR.assign(static_cast<size_t>(chunk), 0.0f);
            h->audioPull(h->audioScratchL.data(), h->audioScratchR.data(), chunk);

            CMSampleBufferRef sample = MakeAudioSampleBuffer(h->sampleRate,
                                                             h->audioScratchL.data(), h->audioScratchR.data(),
                                                             chunk, h->audioSamplesPulled);
            if (sample == nullptr) {
                FailWriter(h, "audio sample creation failed");
                return;
            }
            BOOL ok = NO;
            @try {
                ok = [input appendSampleBuffer:sample];
            } @catch (NSException* e) {
                spdlog::error("AVFoundationVideoWriter: appendSampleBuffer threw: {}",
                              e.reason ? [e.reason UTF8String] : "?");
                ok = NO;
            }
            CFRelease(sample);
            if (!ok) {
                FailWriter(h, "audio append failed");
                return;
            }
            h->audioSamplesPulled += chunk;
        }
        // Exits only when the input is no longer ready (or finished/failed);
        // AVFoundation re-invokes on the next ready transition.
    }];
}

} // namespace

WriterHandle* CreateWriter(const std::string& outPath,
                           const std::string& videoCodec,
                           int width, int height, int fps,
                           int bitrateKbps, double quality,
                           bool hasAudio, int audioSampleRate,
                           bool cpuFrames, int inputChannels)
{
    if (!CanExport(outPath, videoCodec)) {
        return nullptr;
    }
    WriterHandle* h = new WriterHandle();
    h->path = outPath;
    // "Auto" -> HEVC on Apple: hardware-accelerated, ~40% smaller than H.264 at
    // equal quality, and the natural default for Mac/iPad export. (HEVC + audio
    // at large sizes now works because audio is pull-driven and can never
    // starve the interleaving writer — see InstallAudioRequest.)
    h->videoCodec = CodecIsAuto(videoCodec) ? "H.265" : videoCodec;
    h->width = width;
    h->height = height;
    h->fps = fps > 0 ? fps : 30;
    h->bitrateKbps = bitrateKbps;
    h->quality = quality;
    h->hasAudio = hasAudio && audioSampleRate > 0;
    h->sampleRate = audioSampleRate;
    h->cpuFrames = cpuFrames;
    h->inputChannels = inputChannels;
    h->videoQ = dispatch_queue_create("org.xlights.videowriter.video", DISPATCH_QUEUE_SERIAL);
    h->audioQ = dispatch_queue_create("org.xlights.videowriter.audio", DISPATCH_QUEUE_SERIAL);
    h->finishSem = dispatch_semaphore_create(0);
    return h;
}

void DestroyWriter(WriterHandle* h)
{
    if (h == nullptr) {
        return;
    }
    // If still running (e.g. an exception aborted the export before Finish),
    // cancel and let the writer tear down.
    {
        std::lock_guard<std::mutex> lk(h->mtx);
        h->cancelled = true;
    }
    h->cv.notify_all();  // wake any request block blocked in cv.wait so it returns
    if (h->writer != nil && !h->finishTriggered) {
        TriggerFinish(h, true /*cancel*/);
    }
    // Flush the per-input queues so no requestMediaDataWhenReadyOnQueue block is
    // still touching `h` when we delete it. The blocks observe `cancelled` and
    // return, then these empty barriers run after them on the serial queues.
    if (h->videoQ != nil) {
        dispatch_sync(h->videoQ, ^{});
    }
    if (h->audioQ != nil) {
        dispatch_sync(h->audioQ, ^{});
    }
    // Drain whatever is left in the video queue.
    {
        std::lock_guard<std::mutex> lk(h->mtx);
        for (auto& it : h->videoItems) {
            if (it.pixbuf) CVPixelBufferRelease(it.pixbuf);
        }
        h->videoItems.clear();
    }
    if (h->pool != nullptr) {
        CFRelease(h->pool);
        h->pool = nullptr;
    }
    if (h->scratchBGRA != nullptr) {
        CVPixelBufferRelease(h->scratchBGRA);
        h->scratchBGRA = nullptr;
    }
    delete h;  // ARC releases the strong ObjC ivars
}

bool IsValid(WriterHandle* h)
{
    return h != nullptr;
}

bool Start(WriterHandle* h)
{
    if (h == nullptr) {
        return false;
    }
    __block bool ok = false;
    dispatch_sync(h->videoQ, ^{
        // AVAssetWriter/AVAssetWriterInput raise NSInvalidArgumentException for
        // output settings the encoder won't take. An NSException is not a
        // std::exception, so it would sail straight through the catch in
        // AVFoundationVideoWriter::initialize and terminate rather than let
        // VideoWriter::initialize fall back to the FFmpeg writer.
        @try {
            ok = BuildWriter(h);
        } @catch (NSException* exception) {
            NSString* reason = [exception reason];
            spdlog::error("AVFoundationVideoWriter: exception building writer: {} - {}",
                          [[exception name] UTF8String],
                          reason ? [reason UTF8String] : "?");
            ok = false;
        }
    });
    if (!ok) {
        return false;
    }
    h->pendingInputs = h->audioInput != nil ? 2 : 1;
    InstallVideoRequest(h);
    return true;
}

void BeginAudio(WriterHandle* h, AudioPullFn pull, long long totalSamples)
{
    if (h == nullptr || h->audioInput == nil) {
        return;
    }
    h->audioPull = std::move(pull);
    h->audioTotalSamples = totalSamples > 0 ? totalSamples : 0;
    h->audioSamplesPulled = 0;
    if (h->audioTotalSamples <= 0 || h->audioPull == nullptr) {
        // Nothing to supply — finish the input so the writer doesn't wait on it.
        AVAssetWriterInput* input = h->audioInput;
        dispatch_async(h->audioQ, ^{
            InputFinished(h, input);
        });
        return;
    }
    InstallAudioRequest(h);
}

void* RequestPixelBuffer(WriterHandle* h)
{
    if (h == nullptr || h->pool == nullptr) {
        spdlog::error("AVFoundationVideoWriter: pixel buffer pool unavailable");
        return nullptr;
    }
    CVPixelBufferRef buf = nullptr;
    CVReturn r = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, h->pool, &buf);
    if (r != kCVReturnSuccess || buf == nullptr) {
        spdlog::error("AVFoundationVideoWriter: CVPixelBufferPoolCreatePixelBuffer failed ({})", static_cast<int>(r));
        return nullptr;
    }
    // Tag BT.709 so CoreImage renders RGB into the buffer with the right matrix
    // and VideoToolbox encodes/tags the stream as full-range BT.709.
    CVBufferSetAttachment(buf, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buf, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buf, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    return (void*)buf;  // +1 retain; ownership passes to the queue via AppendVideoFrame
}

bool FillPixelBufferRGB(WriterHandle* h, void* pb,
                        const unsigned char* rgb, int channels,
                        int width, int height)
{
    CVPixelBufferRef buf = (CVPixelBufferRef)pb;
    if (h == nullptr || buf == nullptr || rgb == nullptr || (channels != 3 && channels != 4)) {
        return false;
    }

    // Copy the RGB(A) rows into a 32BGRA CVPixelBuffer.
    auto fillBGRA = [&](CVPixelBufferRef dst) -> bool {
        if (CVPixelBufferLockBaseAddress(dst, 0) != kCVReturnSuccess) {
            return false;
        }
        uint8_t* base = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(dst));
        const size_t rowBytes = CVPixelBufferGetBytesPerRow(dst);
        if (base == nullptr || static_cast<int>(CVPixelBufferGetWidth(dst)) != width ||
            static_cast<int>(CVPixelBufferGetHeight(dst)) != height) {
            CVPixelBufferUnlockBaseAddress(dst, 0);
            return false;
        }
        for (int y = 0; y < height; ++y) {
            const uint8_t* src = rgb + static_cast<size_t>(y) * width * channels;
            uint8_t* d = base + static_cast<size_t>(y) * rowBytes;
            for (int x = 0; x < width; ++x) {
                d[0] = src[2];  // B
                d[1] = src[1];  // G
                d[2] = src[0];  // R
                d[3] = (channels == 4) ? src[3] : 0xFF;  // A
                src += channels;
                d += 4;
            }
        }
        CVPixelBufferUnlockBaseAddress(dst, 0);
        return true;
    };

    // ProRes / rawvideo use a BGRA pool — fill it directly.
    if (CVPixelBufferGetPixelFormatType(buf) == kCVPixelFormatType_32BGRA) {
        return fillBGRA(buf);
    }

    // H.264/H.265 use a full-range BT.709 NV12 pool (for color_range=pc). Fill a
    // scratch BGRA buffer, then let CoreImage do the RGB->full-range-YUV
    // conversion into the NV12 buffer. Going BGRA-CVPixelBuffer -> CIImage ->
    // NV12-CVPixelBuffer keeps the orientation 1:1 (a raw-bitmap CIImage would
    // flip it).
    if (h->scratchBGRA == nullptr) {
        NSDictionary* opts = @{ (NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{} };
        if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                (__bridge CFDictionaryRef)opts, &h->scratchBGRA) != kCVReturnSuccess) {
            return false;
        }
    }
    if (!fillBGRA(h->scratchBGRA)) {
        return false;
    }
    @autoreleasepool {
        if (h->ciContext == nil) {
            h->ciContext = [CIContext contextWithOptions:nil];
        }
        CIImage* img = [CIImage imageWithCVPixelBuffer:h->scratchBGRA];
        [h->ciContext render:img toCVPixelBuffer:buf];
    }
    return true;
}

bool AppendVideoFrame(WriterHandle* h, void* pixelBuffer, int frameIndex)
{
    CVPixelBufferRef buf = (CVPixelBufferRef)pixelBuffer;
    if (h == nullptr || buf == nullptr) {
        if (buf != nullptr) CVPixelBufferRelease(buf);
        return false;
    }
    VideoItem item;
    item.pixbuf = buf;  // already +1 from RequestPixelBuffer
    item.pts = CMTimeMake(frameIndex, h->fps);

    std::unique_lock<std::mutex> lk(h->mtx);
    // Video backpressure. The desktop House Preview export drives this from the
    // MAIN thread (the live Metal canvas render must run there), so instead of
    // parking it — which would freeze the progress dialog/UI — pump the run
    // loop in short slices while waiting for the consumer to drain. Off-main
    // callers (iPad export, which runs on a background queue) wait normally.
    //
    // Escape valve: with audio pull-driven (BeginAudio) the writer can always
    // interleave, so this queue should always drain. If it ever stops draining
    // for several seconds anyway, exceed the bound rather than hang — worst
    // case is extra transient memory, never a wedged export.
    const bool onMainThread = ([NSThread isMainThread] != NO);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (h->videoItems.size() >= kMaxQueuedItems && !h->failed && !h->cancelled) {
        if (std::chrono::steady_clock::now() >= deadline) {
            break;
        }
        if (onMainThread) {
            lk.unlock();
            // Service the run loop so UI/timer work can run; return as soon
            // as one source is handled (or 4 ms elapses).
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.004, true);
            lk.lock();
        } else {
            h->cv.wait_for(lk, std::chrono::milliseconds(50),
                           [h] { return h->videoItems.size() < kMaxQueuedItems || h->failed || h->cancelled; });
        }
    }
    if (h->failed || h->cancelled) {
        lk.unlock();
        CVPixelBufferRelease(buf);
        return false;
    }
    h->videoItems.push_back(item);
    lk.unlock();
    h->cv.notify_all();
    return true;
}

bool Finish(WriterHandle* h, bool cancel)
{
    if (h == nullptr) {
        return false;
    }
    {
        std::lock_guard<std::mutex> lk(h->mtx);
        if (cancel) {
            h->cancelled = true;
        } else {
            h->ended = true;
        }
    }
    h->cv.notify_all();

    if (cancel) {
        TriggerFinish(h, true /*cancel*/);
    }

    // Wait (bounded) for the writer's completion handler to fire.
    long timedOut = dispatch_semaphore_wait(h->finishSem,
                                            dispatch_time(DISPATCH_TIME_NOW, kFinishTimeoutSecs * NSEC_PER_SEC));
    if (timedOut != 0) {
        spdlog::error("AVFoundationVideoWriter: timed out waiting for the writer to finish");
        return false;
    }

    std::lock_guard<std::mutex> lk(h->mtx);
    return cancel ? true : h->finalSuccess;
}

} // namespace AppleAVFoundationVideoWriterBridge
