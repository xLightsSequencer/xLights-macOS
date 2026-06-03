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
// dedicated serial queue whenever the input is ready; the block pulls
// finished samples from a bounded queue that the main-thread render loop
// fills (RequestPixelBuffer -> render -> AppendVideoFrame/AppendAudio).
// The bounded queue gives backpressure; rendering stays on the main thread
// (Metal/GL requirement); the writer never touches the main thread.
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
constexpr size_t kMaxQueuedItems = 64;         // video backpressure bound (~0.5 GB at 4K); audio is unbounded
#else
constexpr size_t kMaxQueuedItems = 96;         // video backpressure bound (~0.7 GB at 4K); audio is unbounded
#endif
constexpr int64_t kFinishTimeoutSecs = 120;   // hard cap so Finish can't hang forever

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

    // --- bounded source queues filled by the producer (main thread) ---
    std::mutex mtx;
    std::condition_variable cv;
    std::deque<VideoItem> videoItems;
    std::deque<CMSampleBufferRef> audioItems;  // retained

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

            NSMutableDictionary* compression = [NSMutableDictionary dictionary];
            bool useQuality = (h->quality > 0.0) && !CodecIsProRes(h->videoCodec);
            auto quality = h->quality;
            // Auto (no explicit bitrate): default H.264/HEVC to constant-quality
            // so VideoToolbox picks a content-adaptive bitrate. NOT for ProRes —
            // it's a fixed-profile codec that takes neither AVVideoQualityKey nor
            // a bitrate (setting AVVideoQualityKey on it is invalid and can throw).
            if (!useQuality && h->bitrateKbps <= 0 && !CodecIsProRes(h->videoCodec)) {
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
            // problem, but the real cause was the desktop export blocking the
            // main thread (see AppendVideoFrame's run-loop pump) plus audio-queue
            // backpressure (see AppendAudio). With those fixed, the encoder
            // streams normally — and leaving B-frames / default lookahead on
            // gives noticeably better compression for the same quality.

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
                // Bounded wait — never park this requestMediaData invocation
                // indefinitely. A multi-input (audio + video) writer only
                // interleaves/advances while BOTH inputs' blocks keep
                // returning; the producer is a single thread that may be
                // backpressured on the OTHER input, so an indefinite park here
                // deadlocks the writer.
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
                return;  // no data yet — let AVFoundation re-invoke us / service audio
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

void InstallAudioRequest(WriterHandle* h)
{
    AVAssetWriterInput* input = h->audioInput;
    [input requestMediaDataWhenReadyOnQueue:h->audioQ usingBlock:^{
        while (input.isReadyForMoreMediaData) {
            CMSampleBufferRef sample = nullptr;
            bool have = false;
            bool finish = false;
            {
                std::unique_lock<std::mutex> lk(h->mtx);
                // Bounded wait — see InstallVideoRequest. Parking here stalls
                // the multi-input writer.
                h->cv.wait_for(lk, std::chrono::milliseconds(5),
                               [h] { return !h->audioItems.empty() || h->ended || h->cancelled; });
                if (h->cancelled) {
                    return;
                }
                if (!h->audioItems.empty()) {
                    sample = h->audioItems.front();
                    h->audioItems.pop_front();
                    have = true;
                } else if (h->ended) {
                    finish = true;
                }
            }
            h->cv.notify_all();

            if (finish) {
                InputFinished(h, input);
                return;
            }
            if (!have) {
                return;  // no data yet — let AVFoundation re-invoke us / service video
            }
            if (!input.isReadyForMoreMediaData) {
                std::lock_guard<std::mutex> lk(h->mtx);
                h->audioItems.push_front(sample);
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
        }
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
    // at large sizes now works after removing the audio-queue backpressure that
    // was deadlocking the single-threaded producer — see AppendAudio.)
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
    // Drain whatever is left in the queues.
    {
        std::lock_guard<std::mutex> lk(h->mtx);
        for (auto& it : h->videoItems) {
            if (it.pixbuf) CVPixelBufferRelease(it.pixbuf);
        }
        h->videoItems.clear();
        for (auto* s : h->audioItems) {
            if (s) CFRelease(s);
        }
        h->audioItems.clear();
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
        ok = BuildWriter(h);
    });
    if (!ok) {
        return false;
    }
    h->pendingInputs = h->audioInput != nil ? 2 : 1;
    InstallVideoRequest(h);
    if (h->audioInput != nil) {
        InstallAudioRequest(h);
    }
    return true;
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
    // Video backpressure. CRITICAL: the desktop House Preview export drives this
    // from the MAIN thread (the live Metal canvas render must run there). If we
    // *block* the main thread on a full queue, its run loop stops turning and
    // the encoder pipeline (CoreImage fill completion / CoreVideo / Metal work
    // serviced on the main thread) stalls — the video input never becomes ready
    // again and the export deadlocks (verified: videoReady=NO, status=Writing;
    // a giant queue only hid it by never blocking). So on the main thread we
    // PUMP the run loop briefly instead of parking — that keeps the encoder
    // draining, the consumer pops, and the queue clears in a few ms. Off-main
    // callers (iPad export, which runs on a background queue) wait normally.
    const bool onMainThread = ([NSThread isMainThread] != NO);
    while (h->videoItems.size() >= kMaxQueuedItems && !h->failed && !h->cancelled) {
        if (onMainThread) {
            lk.unlock();
            // Service the run loop so GPU/encoder completion work can run;
            // return as soon as one source is handled (or 4 ms elapses).
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

bool AppendAudio(WriterHandle* h, const float* left, const float* right,
                 int numSamples, long long sampleOffset)
{
    if (h == nullptr || !h->hasAudio || h->audioInput == nil || numSamples <= 0) {
        return true;  // nothing to do (video-only)
    }

    const int channels = 2;
    const size_t bytesPerFrame = channels * sizeof(float);
    const size_t byteCount = static_cast<size_t>(numSamples) * bytesPerFrame;

    std::vector<float> interleaved(static_cast<size_t>(numSamples) * channels);
    for (int i = 0; i < numSamples; ++i) {
        interleaved[2 * i] = left[i];
        interleaved[2 * i + 1] = right[i];
    }

    AudioStreamBasicDescription asbd = {};
    asbd.mSampleRate = h->sampleRate;
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
        return false;
    }

    CMBlockBufferRef blockBuffer = nullptr;
    st = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, byteCount, kCFAllocatorDefault,
                                            nullptr, 0, byteCount, kCMBlockBufferAssureMemoryNowFlag, &blockBuffer);
    if (st != noErr || blockBuffer == nullptr) {
        spdlog::error("AVFoundationVideoWriter: CMBlockBufferCreateWithMemoryBlock failed ({})", static_cast<int>(st));
        CFRelease(format);
        return false;
    }
    st = CMBlockBufferReplaceDataBytes(interleaved.data(), blockBuffer, 0, byteCount);
    if (st != noErr) {
        spdlog::error("AVFoundationVideoWriter: CMBlockBufferReplaceDataBytes failed ({})", static_cast<int>(st));
        CFRelease(blockBuffer);
        CFRelease(format);
        return false;
    }

    CMSampleTimingInfo timing;
    timing.duration = CMTimeMake(1, h->sampleRate);
    timing.presentationTimeStamp = CMTimeMake(sampleOffset, h->sampleRate);
    timing.decodeTimeStamp = kCMTimeInvalid;
    size_t sampleSize = bytesPerFrame;

    CMSampleBufferRef sampleBuffer = nullptr;
    st = CMSampleBufferCreate(kCFAllocatorDefault, blockBuffer, true, nullptr, nullptr, format,
                              numSamples, 1, &timing, 1, &sampleSize, &sampleBuffer);
    CFRelease(blockBuffer);
    CFRelease(format);
    if (st != noErr || sampleBuffer == nullptr) {
        spdlog::error("AVFoundationVideoWriter: CMSampleBufferCreate failed ({})", static_cast<int>(st));
        return false;
    }

    // NO backpressure on audio. The producer is single-threaded (the
    // main-thread render loop appends a video frame then its audio). If audio
    // blocked on a bounded queue, the producer could wedge there while the
    // video input sat empty and ready — the writer waits for video to interleave
    // but the producer can't supply it. Verified deadlock: videoQ=0/vinReady=1
    // while audioQ=24/ainReady=0. Audio packets are tiny (a few KB of PCM) and
    // bounded by the show length, so an unbounded audio queue is cheap; the
    // consumer drains it as the writer accepts audio. Video keeps its bound,
    // since video is the memory-heavy, rate-limiting input.
    std::unique_lock<std::mutex> lk(h->mtx);
    if (h->failed || h->cancelled) {
        lk.unlock();
        CFRelease(sampleBuffer);
        return false;
    }
    h->audioItems.push_back(sampleBuffer);  // +1; released by the consumer block
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
