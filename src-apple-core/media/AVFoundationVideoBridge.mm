/***************************************************************
 * This source files comes from the xLights project
 * https://www.xlights.org
 * https://github.com/xLightsSequencer/xLights
 * See the github commit history for a record of contributing
 * developers.
 * Copyright claimed based on commit dates recorded in Github
 * License: https://github.com/xLightsSequencer/xLights/blob/master/License.txt
 **************************************************************/

// AVFoundation + VideoToolbox + CoreImage + Accelerate decode that
// backs `src-core/media/AVFoundationVideoReader.cpp`. All Apple SDK
// dependencies are isolated here so src-core stays
// Apple-framework-free.
//
// Concurrency design: VideoEffect's "Per Model" render style on a group
// causes one VideoReader per child model. Before this layer, each
// reader held its own AVAssetReader + VTDecompressionSession for the
// lifetime of the effect — a group of 50 models meant 50 decoder
// sessions held simultaneously, which exhausts macOS's VideoToolbox
// session budget and stalls the render. We collapse that here:
//   * One `SharedDecoder` per resolved file path, refcounted across
//     all `VideoReaderHandle` clients that reference the same file.
//   * SharedDecoder owns a small pool of "lanes" (AVAssetReader +
//     optional VTDecompressionSession). Default 2 per file; LRU-evicted
//     when all lanes are positioned far from a new request.
//   * SharedDecoder maintains a small LRU cache of decoded frames at
//     native resolution (BGRA CVPixelBuffer). PerModel siblings at the
//     same timeline frame all want the same source frame — first
//     client decodes, the rest hit cache.
//   * VideoReaderHandle is now a thin per-client shell: it holds the
//     scale-target size, per-client output buffer, and a per-client
//     scaler (VTPixelTransferSession or CIContext). The handle pulls a
//     native-resolution frame from SharedDecoder and scales/converts
//     it into the requested output format. Scaling is done outside the
//     SharedDecoder mutex so per-client work runs in parallel.

#include "AVFoundationVideoBridge.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreImage/CoreImage.h>
#import <Accelerate/Accelerate.h>

#include <algorithm>
#include <array>
#include <climits>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <queue>
#include <unordered_map>
#include <vector>

#include <log.h>

namespace {

// Mirror of FFmpeg's videotoolbox hwaccel init probe. Some H.264 streams
// (notably High@L1.0 with B-frames at very small resolutions) pass
// AVAssetReader's setup but cause its internal HW decoder to silently
// wedge mid-stream. This probe asks VideoToolbox if it can hardware-decode
// the format description; if not, we route the file through a manual
// VTDecompressionSession with HW disabled.
bool probeHardwareDecoderSupport(AVAssetTrack* track) {
    if (!track) return false;
    NSArray* formatDescs = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    formatDescs = track.formatDescriptions;
#pragma clang diagnostic pop
    if (formatDescs.count == 0) return true;

    CMVideoFormatDescriptionRef formatDesc = (__bridge CMVideoFormatDescriptionRef)formatDescs[0];

    NSDictionary* spec = @{
        (NSString*)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @YES
    };
    NSDictionary* dstAttrs = @{
        (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };

    VTDecompressionSessionRef session = nullptr;
    OSStatus status = VTDecompressionSessionCreate(
        kCFAllocatorDefault,
        formatDesc,
        (__bridge CFDictionaryRef)spec,
        (__bridge CFDictionaryRef)dstAttrs,
        nullptr,
        &session);

    if (session) {
        VTDecompressionSessionInvalidate(session);
        CFRelease(session);
    }
    return status == noErr;
}

// AVFoundation's QuickTime decoder accepts rawvideo MOV with codec_tag='raw '
// but only decodes it when the row stride is a multiple of 8 bytes. For rgb24
// (3 bpp) that means width must be a multiple of 8. Otherwise AVAssetReader
// silently produces zero samples (no error). Detect this so the caller can
// route around AVFoundation — on desktop the FFmpeg fallback in
// VideoReader.cpp handles rawvideo natively; on iPad the caller will surface
// "video unreadable" which is honest about the platform constraint.
bool isRawvideoUnalignedStride(AVAssetTrack* track) {
    if (!track) return false;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray* formatDescs = track.formatDescriptions;
#pragma clang diagnostic pop
    if (formatDescs.count == 0) return false;
    CMVideoFormatDescriptionRef fd = (__bridge CMVideoFormatDescriptionRef)formatDescs[0];
    FourCharCode codec = CMFormatDescriptionGetMediaSubType((CMFormatDescriptionRef)fd);
    constexpr FourCharCode kRawTag = ('r' << 24) | ('a' << 16) | ('w' << 8) | ' ';
    if (codec != kRawTag) return false;
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(fd);
    return (dims.width * 3) % 8 != 0;
}

} // namespace

namespace AppleAVFoundationVideoBridge {

namespace {

// Lane budget per file. Two lanes lets two effects on the same file at
// different timeline positions coexist without thrashing AVAssetReader;
// for the common PerModel case (N clients at the same timestamp) one
// lane is enough and the second stays inactive.
constexpr int kLanesPerFile = 2;

// Native-resolution frame cache capacity per file. With a single video
// being shared by PerModel siblings, the cache typically holds
// (current frame + read-ahead) — a few frames is plenty. Bigger caches
// just trade memory for tolerance to wider playhead spread.
constexpr int kCacheCapacity = 8;

// After serving the requested frame we opportunistically decode K more
// frames into the cache so the next forward request becomes a cache hit
// rather than triggering a fresh `copyNextSampleBuffer` cycle.
constexpr int kReadAheadFrames = 4;

// AVAssetReader is forward-only. If a new request is more than this far
// ahead of an active lane, recreating the reader at the target is
// cheaper than decoding-and-discarding everything in between. Matches
// the legacy GetNextFrame threshold.
constexpr int kForwardSkipMS = 1000;

// Match the legacy max-B-frame-delay assumption: VT can hold up to this
// many out-of-order frames before we can pop the next in PTS order.
constexpr int kMaxBFrameDelay = 2;

class SharedDecoder {
public:
    static std::shared_ptr<SharedDecoder> acquire(const std::string& filename);

    ~SharedDecoder();

    bool isValid() const { return valid && !openFailed; }

    int getNativeWidth() const { return nativeWidth; }
    int getNativeHeight() const { return nativeHeight; }
    double getLengthMS() const { return lengthMS; }
    long getFrameCount() const { return frames; }
    int getFrameMS() const { return frameMS; }
    float getNominalFrameRate() const { return nominalFrameRate; }
    const std::string& getFilename() const { return filename; }

    // Returns the frame at or just before timestampMS as a retained
    // CVPixelBufferRef at native resolution. Caller owns the retain and
    // must CVBufferRelease when done. Writes the frame's actual ptsMs
    // and the file's firstFramePos (-1 until known) on success. Sets
    // outAtEnd when no more frames are available.
    CVPixelBufferRef obtainFrame(int timestampMS, int gracetimeMS,
                                 int& outPtsMs, int& outFirstFramePos,
                                 bool& outAtEnd);

private:
    SharedDecoder() = default;
    SharedDecoder(const SharedDecoder&) = delete;
    SharedDecoder& operator=(const SharedDecoder&) = delete;

    bool open(const std::string& filename);

    struct Lane {
        __strong AVAssetReader* reader = nil;
        __strong AVAssetReaderTrackOutput* trackOutput = nil;
        VTDecompressionSessionRef vtSession = nullptr;
        CMVideoFormatDescriptionRef cachedFormatDesc = nullptr;

        struct DecodedEntry {
            CVImageBufferRef image; // retained
            int64_t ptsMs;
            bool operator<(const DecodedEntry& o) const { return ptsMs > o.ptsMs; }
        };
        std::priority_queue<DecodedEntry, std::vector<DecodedEntry>> ptsQueue;
        std::mutex queueMutex;

        bool demuxAtEnd = false;
        bool active = false;
        int curPos = -1000;
        int64_t lastUsedTick = 0;

        ~Lane() { close(); }

        void close();
        bool openAt(SharedDecoder* dec, int timestampMS);

        // Returns retained CVPixelBufferRef + ptsMs of the next frame in
        // pts order. Returns nullptr when no more frames (sets
        // demuxAtEnd or leaves it false on transient failures).
        CVPixelBufferRef decodeNext(SharedDecoder* dec, int& outPtsMs);

    private:
        CVPixelBufferRef decodeNextHW(SharedDecoder* dec, int& outPtsMs);
        CVPixelBufferRef decodeNextSW(SharedDecoder* dec, int& outPtsMs);

        bool ensureVTSession(CMVideoFormatDescriptionRef formatDesc);

        static void vtOutputCallback(void* refCon, void* sourceFrameRefCon,
                                     OSStatus status, VTDecodeInfoFlags infoFlags,
                                     CVImageBufferRef imageBuffer,
                                     CMTime pts, CMTime duration);

        int queueSize() {
            std::lock_guard<std::mutex> lk(queueMutex);
            return (int)ptsQueue.size();
        }
    };

    Lane* selectLane(int targetMS, int gracetimeMS);

    // Cache lookup: return retained pixel buffer (and its pts) for the
    // frame whose [pts, pts+frameMS) interval contains targetMS, or
    // nullptr on miss. Touches LRU tick on hit.
    CVPixelBufferRef cacheLookup(int targetMS, int& outPtsMs);

    // Insert into cache, retaining. Evicts LRU when at capacity.
    void cacheInsert(int64_t ptsMs, CVPixelBufferRef pixelBuffer);

    std::mutex mutex;

    __strong AVAsset* asset = nil;
    __strong AVAssetTrack* videoTrack = nil;

    std::string filename;
    bool valid = false;
    bool openFailed = false;
    bool useSoftwareDecode = false;

    int nativeWidth = 0;
    int nativeHeight = 0;
    double lengthMS = 0;
    long frames = 0;
    int frameMS = 50;
    float nominalFrameRate = 0;
    int firstFramePos = -1;

    std::array<Lane, kLanesPerFile> lanes;
    int64_t laneTick = 0;

    struct CacheEntry {
        int64_t ptsMs = -1;
        CVPixelBufferRef pixelBuffer = nullptr; // retained
        int64_t lastAccessTick = 0;
    };
    std::vector<CacheEntry> cache;
    int64_t cacheTick = 0;
};

// Global path → SharedDecoder weak registry. Refcounted via shared_ptr
// held by every VideoReaderHandle that uses the file; the last release
// drops the decoder and its lanes/sessions.
std::mutex g_decodersMutex;
std::unordered_map<std::string, std::weak_ptr<SharedDecoder>> g_decoders;

std::shared_ptr<SharedDecoder> SharedDecoder::acquire(const std::string& filename) {
    std::lock_guard<std::mutex> lk(g_decodersMutex);
    auto it = g_decoders.find(filename);
    if (it != g_decoders.end()) {
        if (auto sp = it->second.lock()) {
            return sp;
        }
        g_decoders.erase(it);
    }
    auto sp = std::shared_ptr<SharedDecoder>(new SharedDecoder());
    if (!sp->open(filename)) {
        // Don't cache failures — let the next attempt re-probe in case
        // the file becomes readable.
        return sp;
    }
    g_decoders[filename] = sp;
    return sp;
}

SharedDecoder::~SharedDecoder() {
    // Lanes destruct in array destruction; each calls close() which
    // releases its reader, VT session, format desc, and any queued
    // decoded frames.
    for (auto& e : cache) {
        if (e.pixelBuffer) {
            CVBufferRelease(e.pixelBuffer);
            e.pixelBuffer = nullptr;
        }
    }
    cache.clear();

    // Remove ourselves from the registry. The weak_ptr would expire
    // naturally on the next lookup but cleaning up keeps the table
    // small for long-running sessions.
    std::lock_guard<std::mutex> lk(g_decodersMutex);
    auto it = g_decoders.find(filename);
    if (it != g_decoders.end() && it->second.expired()) {
        g_decoders.erase(it);
    }
}

bool SharedDecoder::open(const std::string& fname) {
    filename = fname;

    @autoreleasepool {
        NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:fname.c_str()]];
        AVURLAsset* urlAsset = [AVURLAsset URLAssetWithURL:url options:nil];
        asset = urlAsset;
        if (!asset) {
            spdlog::error("AVFoundationVideoBridge: Failed to create AVAsset for {}", fname);
            openFailed = true;
            return false;
        }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSArray<AVAssetTrack*>* tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
#pragma clang diagnostic pop
        if (tracks.count == 0) {
            spdlog::error("AVFoundationVideoBridge: No video tracks in {}", fname);
            openFailed = true;
            return false;
        }
        videoTrack = tracks[0];

        if (isRawvideoUnalignedStride(videoTrack)) {
            spdlog::info("AVFoundationVideoBridge: rawvideo MOV with unaligned row stride for {}; "
                         "AVFoundation cannot decode — invalidating reader (desktop will fall back to FFmpeg)",
                         fname);
            openFailed = true;
            return false;
        }

        useSoftwareDecode = !probeHardwareDecoderSupport(videoTrack);
        if (useSoftwareDecode) {
            spdlog::info("AVFoundationVideoBridge: HW decode unsupported for {}; using software VTDecompressionSession path", fname);
        }

        CGSize naturalSize = videoTrack.naturalSize;
        CGAffineTransform transform = videoTrack.preferredTransform;
        CGSize transformedSize = CGSizeApplyAffineTransform(naturalSize, transform);
        nativeWidth = (int)fabs(transformedSize.width);
        nativeHeight = (int)fabs(transformedSize.height);

        if (nativeWidth == 0 || nativeHeight == 0) {
            spdlog::error("AVFoundationVideoBridge: Invalid video dimensions for {}", fname);
            openFailed = true;
            return false;
        }

        CMTime duration = asset.duration;
        lengthMS = CMTimeGetSeconds(duration) * 1000.0;

        nominalFrameRate = videoTrack.nominalFrameRate;
        if (nominalFrameRate > 0) {
            frames = (long)((lengthMS / 1000.0) * nominalFrameRate);
            frameMS = (int)(1000.0 / nominalFrameRate);
        } else {
            CMTime minFrameDuration = videoTrack.minFrameDuration;
            if (CMTIME_IS_VALID(minFrameDuration) && CMTimeGetSeconds(minFrameDuration) > 0) {
                double fps = 1.0 / CMTimeGetSeconds(minFrameDuration);
                frames = (long)((lengthMS / 1000.0) * fps);
                frameMS = (int)(CMTimeGetSeconds(minFrameDuration) * 1000.0);
            } else {
                frames = (long)(lengthMS / 50.0);
                frameMS = 50;
            }
        }

        if (lengthMS <= 0 || frames <= 0) {
            spdlog::warn("AVFoundationVideoBridge: Could not determine video length for {}", fname);
            openFailed = true;
            return false;
        }

        cache.reserve(kCacheCapacity);

        valid = true;

        spdlog::info("AVFoundationVideoBridge: Loaded {}", fname);
        spdlog::info("      Length MS: {}", lengthMS);
        spdlog::info("      Source size: {}x{}", nativeWidth, nativeHeight);
        spdlog::info("      Frames: {} @ {}fps", frames, nominalFrameRate);
        spdlog::info("      Frame ms: {}", frameMS);

        // Eagerly open lane 0 at timestamp 0. AVAssetReader retains
        // AVAsset's internal CoreMedia (FigAsset) state for its
        // lifetime; without at least one live reader, AVFoundation
        // invalidates that state in the gap between AVAsset
        // construction and first use, and the next AVAssetReader init
        // crashes in objc_retain on the stale internal pointer. The
        // legacy per-handle code happened to avoid this by opening
        // its reader during construction and never letting it lapse;
        // we restore the same invariant here at the SharedDecoder
        // level so PerModel siblings (and any later-arriving handle)
        // find a warm asset.
        if (!lanes[0].openAt(this, 0)) {
            spdlog::error("AVFoundationVideoBridge: Failed to open initial AVAssetReader for {}", fname);
            openFailed = true;
            valid = false;
            return false;
        }
    }

    return true;
}

void SharedDecoder::Lane::close() {
    if (vtSession) {
        VTDecompressionSessionInvalidate(vtSession);
        CFRelease(vtSession);
        vtSession = nullptr;
    }
    if (cachedFormatDesc) {
        CFRelease(cachedFormatDesc);
        cachedFormatDesc = nullptr;
    }
    {
        std::lock_guard<std::mutex> lk(queueMutex);
        while (!ptsQueue.empty()) {
            CVBufferRelease(ptsQueue.top().image);
            ptsQueue.pop();
        }
    }
    if (reader) {
        [reader cancelReading];
        reader = nil;
    }
    trackOutput = nil;
    demuxAtEnd = false;
    active = false;
    curPos = -1000;
}

bool SharedDecoder::Lane::openAt(SharedDecoder* dec, int timestampMS) {
    close();

    // [AVAssetReader addOutput:] starts internal KVO observers that
    // autorelease NSStrings via -[NSString initWithFormat:]. Drain those
    // locally instead of letting them pile up on the render thread's
    // job-scoped pool, which only flushes when the whole render finishes.
    @autoreleasepool {
        // Pin the SharedDecoder's asset / video track into local strong
        // references for the duration of this call. The members are
        // already __strong on the SharedDecoder, but capturing them
        // locally (a) keeps them alive across the AVAssetReader init
        // path even if something elsewhere were to clear the member,
        // and (b) crashes here at the load — with a clean stack — if
        // the underlying object is already dangling.
        AVAsset* localAsset = dec->asset;
        AVAssetTrack* localTrack = dec->videoTrack;
        if (!localAsset || !localTrack) {
            spdlog::error("AVFoundationVideoBridge: openAt called with asset={} track={} for {}",
                         fmt::ptr((__bridge void*)localAsset), fmt::ptr((__bridge void*)localTrack), dec->filename);
            return false;
        }

        NSError* error = nil;
        reader = [[AVAssetReader alloc] initWithAsset:localAsset error:&error];
        if (!reader || error) {
            spdlog::error("AVFoundationVideoBridge: Failed to create AVAssetReader: {}",
                         error ? [[error localizedDescription] UTF8String] : "unknown error");
            reader = nil;
            return false;
        }

        // HW path: ask AVAssetReader to deliver decoded BGRA pixel
        // buffers at the track's native resolution. SW path: nil
        // outputSettings makes AVAssetReader a pure demuxer; we run our
        // own VTDecompressionSession with HW disabled.
        NSDictionary* outputSettings = nil;
        if (!dec->useSoftwareDecode) {
            outputSettings = @{
                (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
            };
        }
        trackOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:localTrack
                                                       outputSettings:outputSettings];
        // Caching pixel buffers across render cycles means each one
        // outlives the CMSampleBuffer that originally referenced it.
        // With `alwaysCopiesSampleData = NO`, AVAssetReader hands us a
        // thin wrapper around a buffer-pool IOSurface; even with our
        // CVBufferRetain, the pool can decode a later frame back into
        // that surface — producing the "leftover blotches" artifact
        // where stale pixels from a previous frame bleed into what
        // should be a freshly-decoded one. Forcing copies here gives
        // us an independent buffer per decode that the pool can't
        // reuse. (The legacy per-handle code got away with `= NO`
        // because it only used the buffer transiently within the same
        // decode call and never retained it.)
        trackOutput.alwaysCopiesSampleData = YES;

        if (![reader canAddOutput:trackOutput]) {
            spdlog::error("AVFoundationVideoBridge: Cannot add track output to reader");
            reader = nil;
            trackOutput = nil;
            return false;
        }
        [reader addOutput:trackOutput];

        CMTime startTime = CMTimeMakeWithSeconds(timestampMS / 1000.0, 600);
        CMTime duration = dec->asset.duration;
        CMTime rangeEnd = CMTimeSubtract(duration, startTime);
        if (CMTimeCompare(rangeEnd, kCMTimeZero) <= 0) {
            rangeEnd = kCMTimeZero;
        }
        reader.timeRange = CMTimeRangeMake(startTime, rangeEnd);

        if (![reader startReading]) {
            spdlog::error("AVFoundationVideoBridge: Failed to start reading: {}",
                         reader.error ? [[reader.error localizedDescription] UTF8String] : "unknown");
            reader = nil;
            trackOutput = nil;
            return false;
        }

        demuxAtEnd = false;
        active = true;
        // curPos isn't known until the first decoded frame's pts arrives;
        // store the seek target as a lower-bound placeholder so lane
        // selection treats this lane as "near targetMS" rather than at 0.
        curPos = timestampMS - 1;
        return true;
    }
}

void SharedDecoder::Lane::vtOutputCallback(void* refCon, void* /*sourceFrameRefCon*/,
                                            OSStatus status, VTDecodeInfoFlags /*infoFlags*/,
                                            CVImageBufferRef imageBuffer,
                                            CMTime pts, CMTime /*duration*/) {
    if (status != noErr || imageBuffer == nullptr) return;
    Lane* self = static_cast<Lane*>(refCon);
    DecodedEntry entry;
    entry.image = (CVImageBufferRef)CVBufferRetain(imageBuffer);
    entry.ptsMs = CMTIME_IS_VALID(pts) ? (int64_t)(CMTimeGetSeconds(pts) * 1000.0) : 0;
    std::lock_guard<std::mutex> lk(self->queueMutex);
    self->ptsQueue.push(entry);
}

bool SharedDecoder::Lane::ensureVTSession(CMVideoFormatDescriptionRef formatDesc) {
    if (!formatDesc) return false;
    if (vtSession && cachedFormatDesc &&
        CMFormatDescriptionEqual((CMFormatDescriptionRef)cachedFormatDesc,
                                 (CMFormatDescriptionRef)formatDesc)) {
        return true;
    }

    if (vtSession) {
        VTDecompressionSessionInvalidate(vtSession);
        CFRelease(vtSession);
        vtSession = nullptr;
    }
    if (cachedFormatDesc) {
        CFRelease(cachedFormatDesc);
        cachedFormatDesc = nullptr;
    }
    cachedFormatDesc = (CMVideoFormatDescriptionRef)CFRetain(formatDesc);

    NSDictionary* spec = @{
        (NSString*)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: @NO,
        (NSString*)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @NO
    };
    NSDictionary* dstAttrs = @{
        (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };

    VTDecompressionOutputCallbackRecord cb = {
        .decompressionOutputCallback = &Lane::vtOutputCallback,
        .decompressionOutputRefCon = this
    };

    OSStatus status = VTDecompressionSessionCreate(
        kCFAllocatorDefault,
        cachedFormatDesc,
        (__bridge CFDictionaryRef)spec,
        (__bridge CFDictionaryRef)dstAttrs,
        &cb,
        &vtSession);

    if (status != noErr) {
        spdlog::error("AVFoundationVideoBridge: VTDecompressionSessionCreate (SW) failed: {}", (int)status);
        vtSession = nullptr;
        return false;
    }
    return true;
}

CVPixelBufferRef SharedDecoder::Lane::decodeNext(SharedDecoder* dec, int& outPtsMs) {
    if (!reader) {
        return nullptr;
    }
    if (!dec->useSoftwareDecode) {
        AVAssetReaderStatus readerStatus = reader.status;
        if (readerStatus != AVAssetReaderStatusReading) {
            if (readerStatus == AVAssetReaderStatusFailed) {
                spdlog::error("AVFoundationVideoBridge: Reader failed: {}",
                             reader.error ? [[reader.error localizedDescription] UTF8String] : "unknown");
            }
            demuxAtEnd = true;
            return nullptr;
        }
        return decodeNextHW(dec, outPtsMs);
    }
    return decodeNextSW(dec, outPtsMs);
}

CVPixelBufferRef SharedDecoder::Lane::decodeNextHW(SharedDecoder* /*dec*/, int& outPtsMs) {
    @autoreleasepool {
        CMSampleBufferRef sampleBuffer = nullptr;

        @try {
            sampleBuffer = [trackOutput copyNextSampleBuffer];
        } @catch (NSException* exception) {
            spdlog::error("AVFoundationVideoBridge: Exception in copyNextSampleBuffer: {} - {}",
                         [[exception name] UTF8String], [[exception reason] UTF8String]);
            demuxAtEnd = true;
            return nullptr;
        }

        if (!sampleBuffer) {
            if (reader.status != AVAssetReaderStatusReading) {
                demuxAtEnd = true;
            }
            return nullptr;
        }

        if (!CMSampleBufferIsValid(sampleBuffer)) {
            spdlog::warn("AVFoundationVideoBridge: Invalid sample buffer received");
            CFRelease(sampleBuffer);
            return nullptr;
        }

        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        int ptsMs = CMTIME_IS_VALID(pts) ? (int)(CMTimeGetSeconds(pts) * 1000.0) : 0;

        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (!imageBuffer) {
            CFRelease(sampleBuffer);
            return nullptr;
        }
        CVBufferRetain(imageBuffer);
        CFRelease(sampleBuffer);
        outPtsMs = ptsMs;
        return imageBuffer;
    }
}

CVPixelBufferRef SharedDecoder::Lane::decodeNextSW(SharedDecoder* /*dec*/, int& outPtsMs) {
    const int threshold = kMaxBFrameDelay + 1;

    while (!demuxAtEnd && queueSize() < threshold) {
        if (reader.status != AVAssetReaderStatusReading) {
            demuxAtEnd = true;
            break;
        }
        @autoreleasepool {
            CMSampleBufferRef sample = nullptr;
            @try {
                sample = [trackOutput copyNextSampleBuffer];
            } @catch (NSException* exception) {
                spdlog::error("AVFoundationVideoBridge: Exception in copyNextSampleBuffer (SW): {} - {}",
                             [[exception name] UTF8String], [[exception reason] UTF8String]);
                demuxAtEnd = true;
                return nullptr;
            }
            if (!sample) {
                demuxAtEnd = true;
                break;
            }

            CMVideoFormatDescriptionRef sampleFormat =
                (CMVideoFormatDescriptionRef)CMSampleBufferGetFormatDescription(sample);
            if (!sampleFormat) {
                spdlog::debug("AVFoundationVideoBridge: SW sample with no format description, skipping");
                CFRelease(sample);
                continue;
            }
            if (!ensureVTSession(sampleFormat)) {
                spdlog::error("AVFoundationVideoBridge: ensureVTSession failed (sample format desc {}); aborting SW lane",
                             (void*)sampleFormat);
                CFRelease(sample);
                demuxAtEnd = true;
                return nullptr;
            }

            VTDecodeFrameFlags flags = 0;
            VTDecodeInfoFlags info = 0;
            OSStatus status = VTDecompressionSessionDecodeFrame(vtSession, sample, flags, nullptr, &info);
            CFRelease(sample);
            if (status != noErr) {
                spdlog::warn("AVFoundationVideoBridge: VTDecompressionSessionDecodeFrame failed: {}", (int)status);
            }
        }
    }

    // At end-of-stream, drain anything VT still has buffered for B-frame
    // reordering before declaring the queue authoritative.
    if (demuxAtEnd && vtSession && queueSize() < threshold) {
        VTDecompressionSessionFinishDelayedFrames(vtSession);
        VTDecompressionSessionWaitForAsynchronousFrames(vtSession);
    }

    DecodedEntry entry{};
    bool got = false;
    {
        std::lock_guard<std::mutex> lk(queueMutex);
        if (!ptsQueue.empty()) {
            entry = ptsQueue.top();
            ptsQueue.pop();
            got = true;
        }
    }
    if (!got) {
        return nullptr;
    }

    outPtsMs = (int)entry.ptsMs;
    // Pass ownership of the retained CVImageBufferRef to caller.
    return entry.image;
}

SharedDecoder::Lane* SharedDecoder::selectLane(int targetMS, int gracetimeMS) {
    Lane* best = nullptr;
    int bestGap = INT_MAX;
    Lane* oldestActive = nullptr;
    int64_t oldestTick = INT64_MAX;
    Lane* firstInactive = nullptr;

    // Lane 0 is the anchor: opened eagerly at construction time so
    // AVAsset's internal CoreMedia state stays pinned by at least one
    // live AVAssetReader for the SharedDecoder's lifetime. It can be
    // *used* for decode (and advanced forward) like any other lane,
    // but never closed-and-reopened for an LRU recreate — that would
    // open a gap where no AVAssetReader exists and AVFoundation can
    // invalidate the asset, causing later AVAssetReader inits to
    // crash. Pick a non-anchor lane for eviction instead.
    for (size_t i = 0; i < lanes.size(); ++i) {
        auto& lane = lanes[i];
        if (!lane.active) {
            if (!firstInactive) firstInactive = &lane;
            continue;
        }
        if (!lane.demuxAtEnd && lane.curPos <= targetMS) {
            int gap = targetMS - lane.curPos;
            if (gap <= kForwardSkipMS + gracetimeMS) {
                if (gap < bestGap) {
                    bestGap = gap;
                    best = &lane;
                }
            }
        }
        if (i != 0 && lane.lastUsedTick < oldestTick) {
            oldestTick = lane.lastUsedTick;
            oldestActive = &lane;
        }
    }

    if (best) {
        best->lastUsedTick = ++laneTick;
        return best;
    }

    Lane* lane = firstInactive ? firstInactive : oldestActive;
    if (!lane) return nullptr;

    int openAt = std::max(0, targetMS - frameMS);
    if (!lane->openAt(this, openAt)) {
        return nullptr;
    }
    lane->lastUsedTick = ++laneTick;
    return lane;
}

CVPixelBufferRef SharedDecoder::cacheLookup(int targetMS, int& outPtsMs) {
    int64_t bestPts = -1;
    size_t bestIdx = (size_t)-1;
    for (size_t i = 0; i < cache.size(); ++i) {
        const auto& e = cache[i];
        if (!e.pixelBuffer) continue;
        if (e.ptsMs <= targetMS && targetMS < e.ptsMs + frameMS) {
            if (e.ptsMs > bestPts) {
                bestPts = e.ptsMs;
                bestIdx = i;
            }
        }
    }
    if (bestIdx == (size_t)-1) return nullptr;
    cache[bestIdx].lastAccessTick = ++cacheTick;
    outPtsMs = (int)bestPts;
    CVBufferRetain(cache[bestIdx].pixelBuffer);
    return cache[bestIdx].pixelBuffer;
}

void SharedDecoder::cacheInsert(int64_t ptsMs, CVPixelBufferRef pixelBuffer) {
    // Dedupe — same pts replaces existing entry.
    for (auto& e : cache) {
        if (e.ptsMs == ptsMs && e.pixelBuffer) {
            if (e.pixelBuffer != pixelBuffer) {
                CVBufferRelease(e.pixelBuffer);
                CVBufferRetain(pixelBuffer);
                e.pixelBuffer = pixelBuffer;
            }
            e.lastAccessTick = ++cacheTick;
            return;
        }
    }

    if ((int)cache.size() >= kCacheCapacity) {
        // Evict LRU entry.
        size_t evictIdx = 0;
        int64_t evictTick = cache[0].lastAccessTick;
        for (size_t i = 1; i < cache.size(); ++i) {
            if (cache[i].lastAccessTick < evictTick) {
                evictTick = cache[i].lastAccessTick;
                evictIdx = i;
            }
        }
        if (cache[evictIdx].pixelBuffer) {
            CVBufferRelease(cache[evictIdx].pixelBuffer);
        }
        cache[evictIdx].ptsMs = ptsMs;
        cache[evictIdx].pixelBuffer = (CVPixelBufferRef)CVBufferRetain(pixelBuffer);
        cache[evictIdx].lastAccessTick = ++cacheTick;
        return;
    }

    CacheEntry e;
    e.ptsMs = ptsMs;
    e.pixelBuffer = (CVPixelBufferRef)CVBufferRetain(pixelBuffer);
    e.lastAccessTick = ++cacheTick;
    cache.push_back(e);
}

CVPixelBufferRef SharedDecoder::obtainFrame(int timestampMS, int gracetimeMS,
                                             int& outPtsMs, int& outFirstFramePos,
                                             bool& outAtEnd) {
    std::lock_guard<std::mutex> lk(mutex);
    outAtEnd = false;
    outFirstFramePos = firstFramePos;
    outPtsMs = 0;

    if (!valid || openFailed) {
        outAtEnd = true;
        return nullptr;
    }
    if (timestampMS > lengthMS) {
        outAtEnd = true;
        return nullptr;
    }

    int targetMS = timestampMS;
    if (firstFramePos >= 0 && targetMS < firstFramePos) {
        targetMS = firstFramePos;
    }

    // Fast path: serve from cache.
    if (CVPixelBufferRef hit = cacheLookup(targetMS, outPtsMs)) {
        outFirstFramePos = firstFramePos;
        return hit;
    }

    Lane* lane = selectLane(targetMS, gracetimeMS);
    if (!lane) {
        outAtEnd = true;
        return nullptr;
    }

    // Decode forward until we cross the target frame boundary.
    CVPixelBufferRef result = nullptr;
    int resultPts = -1;

    // Bound the inner loop so a pathological file can't wedge the
    // decoder. The lane only advances by one source frame per decode;
    // 100k frames is well past any sane forward-decode distance.
    int safety = 100000;
    while (safety-- > 0) {
        int pts = 0;
        CVPixelBufferRef pb = lane->decodeNext(this, pts);
        if (!pb) {
            if (lane->demuxAtEnd) {
                outAtEnd = true;
            }
            break;
        }
        lane->curPos = pts;
        if (firstFramePos < 0) {
            firstFramePos = pts;
        }
        cacheInsert(pts, pb);
        if (pts + (frameMS / 2) >= targetMS) {
            result = pb; // hand off the retain to caller
            resultPts = pts;
            break;
        }
        CVBufferRelease(pb);
    }

    if (!result) {
        outFirstFramePos = firstFramePos;
        return nullptr;
    }

    // Read ahead a few frames so the next forward request becomes a
    // cache hit.
    for (int i = 0; i < kReadAheadFrames; ++i) {
        int aheadPts = 0;
        CVPixelBufferRef aheadPb = lane->decodeNext(this, aheadPts);
        if (!aheadPb) break;
        lane->curPos = aheadPts;
        cacheInsert(aheadPts, aheadPb);
        CVBufferRelease(aheadPb);
    }

    outPtsMs = resultPts;
    outFirstFramePos = firstFramePos;
    return result;
}

} // anonymous namespace inside AppleAVFoundationVideoBridge

// Per-client handle. Each VideoReader instance in src-core/ maps to one
// of these. Holds the per-client scale target (output width/height,
// alpha/bgr selection, scaling algorithm) plus a double-buffered output
// (current + previous frame, ready-to-consume in the requested pixel
// format) so adjacent same-frame requests don't re-scale. The actual
// source decode is delegated to a SharedDecoder shared across all
// handles for the same file.
struct VideoReaderHandle {
    std::shared_ptr<SharedDecoder> decoder;

    std::string filename;
    bool wantAlpha = false;
    bool bgr = false;
    bool wantsHWType = false;
    bool atEnd = false;
    bool failed = false;
    ScaleAlgorithm scaleAlgorithm = ScaleAlgorithm::Default;
    PixelFormat outputFormat = PixelFormat::RGB24;

    int width = 0;       // output width
    int height = 0;      // output height
    int nativeWidth = 0;
    int nativeHeight = 0;
    double lengthMS = 0;
    long frames = 0;
    int frameMS = 50;

    // The pts of the frame currently in `currentBuffer()`. -1000 means
    // "no decoded frame yet" so the first GetNextFrame always falls
    // through to the SharedDecoder.
    int curPos = -1000;
    int prevPos = -1000;
    int firstFramePos = -1;

    // Per-client double-buffered output frames in the requested pixel
    // format. Adjacent same-frame requests return without consulting
    // SharedDecoder at all.
    uint8_t* frameBuffer1 = nullptr;
    uint8_t* frameBuffer2 = nullptr;
    int frameBufferSize = 0;

    FrameView frameView1;
    FrameView frameView2;
    bool frame1IsCurrent = true;

    // Per-client scaler. The cached native-resolution frame goes
    // through this (or memcpy if no scaling needed) into scaledPixelBuffer,
    // then gets format-converted into the current frame buffer.
    VTPixelTransferSessionRef transferSession = nullptr;
    __strong CIContext* ciContext = nil;
    CVPixelBufferRef scaledPixelBuffer = nullptr;

    FrameView& currentFrame() { return frame1IsCurrent ? frameView1 : frameView2; }
    FrameView& prevFrame() { return frame1IsCurrent ? frameView2 : frameView1; }
    uint8_t* currentBuffer() { return frame1IsCurrent ? frameBuffer1 : frameBuffer2; }
    void swapFrames() { frame1IsCurrent = !frame1IsCurrent; }

    ~VideoReaderHandle() {
        if (transferSession) {
            VTPixelTransferSessionInvalidate(transferSession);
            CFRelease(transferSession);
            transferSession = nullptr;
        }
        if (scaledPixelBuffer) {
            CVPixelBufferRelease(scaledPixelBuffer);
            scaledPixelBuffer = nullptr;
        }
        if (frameBuffer1) { free(frameBuffer1); frameBuffer1 = nullptr; }
        if (frameBuffer2) { free(frameBuffer2); frameBuffer2 = nullptr; }
        // ARC handles ObjC objects. The shared_ptr decrements the
        // SharedDecoder refcount; last release tears down the file's
        // lanes and frame cache.
    }

    bool ensureTransferSession() {
        if (transferSession) return true;
        OSStatus status = VTPixelTransferSessionCreate(kCFAllocatorDefault, &transferSession);
        if (status != noErr) {
            spdlog::error("AVFoundationVideoBridge: VTPixelTransferSessionCreate failed: {}", (int)status);
            return false;
        }
        return true;
    }

    bool ensureScaledPixelBuffer() {
        if (scaledPixelBuffer) {
            size_t w = CVPixelBufferGetWidth(scaledPixelBuffer);
            size_t h = CVPixelBufferGetHeight(scaledPixelBuffer);
            if ((int)w == width && (int)h == height) return true;
            CVPixelBufferRelease(scaledPixelBuffer);
            scaledPixelBuffer = nullptr;
        }

        NSDictionary* attrs = @{
            (NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        CVReturn ret = CVPixelBufferCreate(kCFAllocatorDefault,
                                           width, height,
                                           kCVPixelFormatType_32BGRA,
                                           (__bridge CFDictionaryRef)attrs,
                                           &scaledPixelBuffer);
        if (ret != kCVReturnSuccess) {
            spdlog::error("AVFoundationVideoBridge: CVPixelBufferCreate failed: {}", (int)ret);
            return false;
        }
        return true;
    }

    // BGRA → target format conversion using Accelerate.framework.
    void copyPixelBufferToFrame(CVPixelBufferRef pixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

        uint8_t* src = (uint8_t*)CVPixelBufferGetBaseAddress(pixelBuffer);
        size_t srcStride = CVPixelBufferGetBytesPerRow(pixelBuffer);
        size_t srcWidth = CVPixelBufferGetWidth(pixelBuffer);
        size_t srcHeight = CVPixelBufferGetHeight(pixelBuffer);

        uint8_t* dst = currentBuffer();
        int channels = wantAlpha ? 4 : 3;
        int dstStride = width * channels;

        int copyWidth = std::min((int)srcWidth, width);
        int copyHeight = std::min((int)srcHeight, height);

        vImage_Buffer srcBuf = { src, (vImagePixelCount)copyHeight, (vImagePixelCount)copyWidth, srcStride };
        vImage_Buffer dstBuf = { dst, (vImagePixelCount)copyHeight, (vImagePixelCount)copyWidth, (size_t)dstStride };

        if (wantAlpha) {
            if (bgr) {
                // BGRA → BGRA: direct copy
                for (int y = 0; y < copyHeight; y++) {
                    memcpy(dst + y * dstStride, src + y * srcStride, copyWidth * 4);
                }
            } else {
                // BGRA → RGBA: permute via NEON-accelerated vImage
                const uint8_t permuteMap[4] = { 2, 1, 0, 3 };
                vImagePermuteChannels_ARGB8888(&srcBuf, &dstBuf, permuteMap, kvImageNoFlags);
            }
        } else {
            if (bgr) {
                // BGRA → BGR24: permute BGRA → XBGR, then drop X.
                size_t tmpStride = copyWidth * 4;
                size_t tmpSize = tmpStride * copyHeight;
                uint8_t stackBuf[64 * 1024];
                uint8_t* tmpData = (tmpSize <= sizeof(stackBuf)) ? stackBuf : (uint8_t*)malloc(tmpSize);
                vImage_Buffer tmpBuf = { tmpData, (vImagePixelCount)copyHeight, (vImagePixelCount)copyWidth, tmpStride };
                const uint8_t permuteMap[4] = { 3, 0, 1, 2 };
                vImagePermuteChannels_ARGB8888(&srcBuf, &tmpBuf, permuteMap, kvImageNoFlags);
                vImageConvert_ARGB8888toRGB888(&tmpBuf, &dstBuf, kvImageNoFlags);
                if (tmpData != stackBuf) free(tmpData);
            } else {
                // BGRA → RGB24: permute BGRA → XRGB, then drop X.
                size_t tmpStride = copyWidth * 4;
                size_t tmpSize = tmpStride * copyHeight;
                uint8_t stackBuf[64 * 1024];
                uint8_t* tmpData = (tmpSize <= sizeof(stackBuf)) ? stackBuf : (uint8_t*)malloc(tmpSize);
                vImage_Buffer tmpBuf = { tmpData, (vImagePixelCount)copyHeight, (vImagePixelCount)copyWidth, tmpStride };
                const uint8_t permuteMap[4] = { 3, 2, 1, 0 };
                vImagePermuteChannels_ARGB8888(&srcBuf, &tmpBuf, permuteMap, kvImageNoFlags);
                vImageConvert_ARGB8888toRGB888(&tmpBuf, &dstBuf, kvImageNoFlags);
                if (tmpData != stackBuf) free(tmpData);
            }
        }

        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

        // Snap uniformly-near-black pixels to exact (0,0,0). H.264
        // compression artifacts in dark source regions show up as
        // pixels like (2,0,2) — sum = 4, just one over a typical
        // TransparentBlack threshold of 3. FFmpeg's swscale bicubic
        // happens to clip those during scaling (bicubic overshoot
        // clamped to 0) but vImage's Lanczos preserves them. Without
        // this snap, those pixels render as faint visible blotches in
        // areas the user expects to be cleanly transparent. We only
        // snap when *all three* channels are <= 4, which leaves
        // intentionally-dark single-channel content (e.g. RGB(0,0,10)
        // dark blue) untouched.
        for (int y = 0; y < copyHeight; y++) {
            uint8_t* row = dst + y * dstStride;
            for (int x = 0; x < copyWidth; x++) {
                uint8_t* px = row + x * channels;
                if (px[0] <= 4 && px[1] <= 4 && px[2] <= 4) {
                    px[0] = px[1] = px[2] = 0;
                }
            }
        }

        FrameView& vf = currentFrame();
        vf.data = dst;
        vf.linesize = dstStride;
        vf.width = width;
        vf.height = height;
        vf.format = outputFormat;
    }

    bool ciFilterScale(CVImageBufferRef imageBuffer) {
        if (!ciContext) {
            ciContext = [[CIContext alloc] initWithOptions:@{
                (id)kCIContextUseSoftwareRenderer: @NO,
                (id)kCIContextOutputPremultiplied: @NO,
                (id)kCIContextHighQualityDownsample: @YES,
                (id)kCIContextCacheIntermediates: @NO,
                (id)kCIContextAllowLowPower: @YES,
            }];
            if (!ciContext) return false;
        }
        if (!ensureScaledPixelBuffer()) return false;

        @autoreleasepool {
            CIImage* image = [CIImage imageWithCVImageBuffer:imageBuffer];
            if (!image) return false;

            float w = (float)width / (float)CVPixelBufferGetWidth(imageBuffer);
            float h = (float)height / (float)CVPixelBufferGetHeight(imageBuffer);

            CIImage* scaled = nil;
            switch (scaleAlgorithm) {
            case ScaleAlgorithm::Bicubic: {
                CIFilter* f = [CIFilter filterWithName:@"CIBicubicScaleTransform"];
                [f setValue:@(h) forKey:@"inputScale"];
                [f setValue:@(w / h) forKey:@"inputAspectRatio"];
                [f setValue:@(0.0f) forKey:@"inputB"];
                [f setValue:@(0.75f) forKey:@"inputC"];
                [f setValue:image forKey:@"inputImage"];
                scaled = [f valueForKey:@"outputImage"];
                break;
            }
            case ScaleAlgorithm::Lanczos: {
                CIFilter* f = [CIFilter filterWithName:@"CILanczosScaleTransform"];
                [f setValue:@(h) forKey:@"inputScale"];
                [f setValue:@(w / h) forKey:@"inputAspectRatio"];
                [f setValue:image forKey:@"inputImage"];
                scaled = [f valueForKey:@"outputImage"];
                break;
            }
            case ScaleAlgorithm::Area:
                scaled = [image imageByApplyingTransform:CGAffineTransformMakeScale(w, h)
                                   highQualityDownsample:YES];
                break;
            case ScaleAlgorithm::Point:
                scaled = [image imageByApplyingTransform:CGAffineTransformMakeScale(w, h)
                                   highQualityDownsample:NO];
                break;
            default:
                break;
            }
            if (!scaled) return false;

            [ciContext render:scaled toCVPixelBuffer:scaledPixelBuffer];
        }

        copyPixelBufferToFrame(scaledPixelBuffer);
        return true;
    }

    // Scale via vImage's high-quality resampler. Stays in encoded
    // sRGB byte space (no gamma round-trip) which matches FFmpeg's
    // swscale behavior — the prior CIContext and VTPixelTransferSession
    // paths scaled in linear-light, brightening non-black source pixels
    // by ~10% and shifting near-black source values away from RGB=0.
    // For xLights's VideoEffect "TransparentBlack" rendering (which
    // treats R+G+B > threshold as opaque content) that brightening
    // turned near-transparent pixels into visible dark blotches.
    bool vImageScale(CVPixelBufferRef src) {
        if (!ensureScaledPixelBuffer()) return false;

        CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferLockBaseAddress(scaledPixelBuffer, 0);

        vImage_Buffer srcBuf;
        srcBuf.data = CVPixelBufferGetBaseAddress(src);
        srcBuf.width = CVPixelBufferGetWidth(src);
        srcBuf.height = CVPixelBufferGetHeight(src);
        srcBuf.rowBytes = CVPixelBufferGetBytesPerRow(src);

        vImage_Buffer dstBuf;
        dstBuf.data = CVPixelBufferGetBaseAddress(scaledPixelBuffer);
        dstBuf.width = (vImagePixelCount)width;
        dstBuf.height = (vImagePixelCount)height;
        dstBuf.rowBytes = CVPixelBufferGetBytesPerRow(scaledPixelBuffer);

        vImage_Error err = vImageScale_ARGB8888(&srcBuf, &dstBuf, NULL,
                                                kvImageNoFlags);

        CVPixelBufferUnlockBaseAddress(scaledPixelBuffer, 0);
        CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);

        if (err != kvImageNoError) {
            spdlog::warn("AVFoundationVideoBridge: vImageScale_ARGB8888 failed: {}", (int)err);
            return false;
        }
        return true;
    }

    // Take a native-resolution BGRA CVPixelBufferRef from SharedDecoder,
    // scale + convert into the per-client current frame buffer. The
    // input pixel buffer is borrowed (caller retains ownership).
    void emitDecodedImage(CVImageBufferRef imageBuffer) {
        swapFrames();

        bool needsScale = ((int)CVPixelBufferGetWidth(imageBuffer) != width ||
                           (int)CVPixelBufferGetHeight(imageBuffer) != height);

        if (needsScale) {
            // Default path: vImage's encoded-space scaling, which
            // matches FFmpeg's swscale output byte-for-byte on flat
            // regions and avoids the linear-light brightening that
            // CIContext / VTPixelTransferSession introduce.
            if (scaleAlgorithm == ScaleAlgorithm::Default) {
                if (vImageScale(imageBuffer)) {
                    copyPixelBufferToFrame(scaledPixelBuffer);
                    return;
                }
            } else {
                // Non-Default algorithms (Bicubic/Lanczos/Area/Point)
                // go through Core Image so the user-selectable filter
                // names map onto their CIFilter counterparts.
                if (ciFilterScale(imageBuffer)) return;
            }

            // Fallback: VTPixelTransferSession. Keeps the user moving
            // (with slight near-black brightening) rather than dropping
            // to the unscaled-crop fallback below.
            if (ensureTransferSession() && ensureScaledPixelBuffer()) {
                OSStatus xferStatus = VTPixelTransferSessionTransferImage(transferSession,
                                                                          imageBuffer,
                                                                          scaledPixelBuffer);
                if (xferStatus == noErr) {
                    copyPixelBufferToFrame(scaledPixelBuffer);
                    return;
                } else {
                    spdlog::warn("AVFoundationVideoBridge: VTPixelTransferSession failed ({}), falling back to unscaled", (int)xferStatus);
                }
            }
        }

        copyPixelBufferToFrame(imageBuffer);
    }
};

VideoReaderHandle* CreateReader(const std::string& filename, int maxwidth, int maxheight,
                                 bool keepaspectratio, bool usenativeresolution,
                                 bool wantAlpha, bool bgr, bool wantsHWType) {
    auto* h = new VideoReaderHandle();
    h->filename = filename;
    h->wantAlpha = wantAlpha;
    h->bgr = bgr;
    h->wantsHWType = wantsHWType;

    if (wantAlpha) {
        h->outputFormat = bgr ? PixelFormat::BGRA : PixelFormat::RGBA;
    } else {
        h->outputFormat = bgr ? PixelFormat::BGR24 : PixelFormat::RGB24;
    }

    h->decoder = SharedDecoder::acquire(filename);
    if (!h->decoder || !h->decoder->isValid()) {
        h->failed = true;
        return h;
    }

    h->nativeWidth = h->decoder->getNativeWidth();
    h->nativeHeight = h->decoder->getNativeHeight();
    h->lengthMS = h->decoder->getLengthMS();
    h->frames = h->decoder->getFrameCount();
    h->frameMS = h->decoder->getFrameMS();

    if (usenativeresolution) {
        h->width = h->nativeWidth;
        h->height = h->nativeHeight;
    } else if (keepaspectratio) {
        float shrink = std::min((float)maxwidth / (float)h->nativeWidth,
                                (float)maxheight / (float)h->nativeHeight);
        h->width = (int)((float)h->nativeWidth * shrink);
        h->height = (int)((float)h->nativeHeight * shrink);
    } else {
        h->width = maxwidth;
        h->height = maxheight;
    }

    int channels = wantAlpha ? 4 : 3;
    h->frameBufferSize = h->width * h->height * channels;
    h->frameBuffer1 = (uint8_t*)calloc(1, h->frameBufferSize);
    h->frameBuffer2 = (uint8_t*)calloc(1, h->frameBufferSize);

    int stride = h->width * channels;
    h->frameView1 = { h->frameBuffer1, stride, h->width, h->height, h->outputFormat };
    h->frameView2 = { h->frameBuffer2, stride, h->width, h->height, h->outputFormat };

    spdlog::info("AVFoundationVideoBridge: Reader created for {}", filename);
    spdlog::info("      Output size: {}x{}", h->width, h->height);
    if (wantAlpha) spdlog::info("      Alpha: TRUE");

    return h;
}

void DestroyReader(VideoReaderHandle* h) {
    delete h;
}

bool IsValid(VideoReaderHandle* h) { return h && h->decoder && h->decoder->isValid() && !h->failed; }
int GetLengthMS(VideoReaderHandle* h) { return h ? (int)h->lengthMS : 0; }
int GetWidth(VideoReaderHandle* h) { return h ? h->width : 0; }
int GetHeight(VideoReaderHandle* h) { return h ? h->height : 0; }
bool AtEnd(VideoReaderHandle* h) { return h ? h->atEnd : true; }
int GetPos(VideoReaderHandle* h) { return h ? h->curPos : 0; }
int GetPixelChannels(VideoReaderHandle* h) { return h && h->wantAlpha ? 4 : 3; }

void SetScaleAlgorithm(VideoReaderHandle* h, ScaleAlgorithm algorithm) {
    if (h) h->scaleAlgorithm = algorithm;
}

bool Resize(VideoReaderHandle* h, int width, int height) {
    if (!h || !IsValid(h)) return false;
    if (width <= 0 || height <= 0) return false;
    if (h->width == width && h->height == height) return true;

    int channels = h->wantAlpha ? 4 : 3;
    int newSize = width * height * channels;

    if (h->frameBuffer1) { free(h->frameBuffer1); h->frameBuffer1 = nullptr; }
    if (h->frameBuffer2) { free(h->frameBuffer2); h->frameBuffer2 = nullptr; }
    h->frameBuffer1 = (uint8_t*)calloc(1, newSize);
    h->frameBuffer2 = (uint8_t*)calloc(1, newSize);
    if (!h->frameBuffer1 || !h->frameBuffer2) return false;

    h->frameBufferSize = newSize;
    h->width = width;
    h->height = height;

    int stride = width * channels;
    h->frameView1 = { h->frameBuffer1, stride, width, height, h->outputFormat };
    h->frameView2 = { h->frameBuffer2, stride, width, height, h->outputFormat };

    // Per-client scaler sized to the old dimensions; lazily reallocate.
    if (h->scaledPixelBuffer) {
        CVPixelBufferRelease(h->scaledPixelBuffer);
        h->scaledPixelBuffer = nullptr;
    }

    // Force the next GetNextFrame() to re-pull from SharedDecoder rather
    // than returning a frame whose backing storage is freshly-allocated
    // zeroed buffers.
    h->curPos = -1000;
    h->prevPos = -1000;

    return true;
}

void Seek(VideoReaderHandle* h, int timestampMS, bool readFrame) {
    if (!h || !IsValid(h)) return;

    if (timestampMS >= h->lengthMS) {
        h->atEnd = true;
        return;
    }

    h->atEnd = false;
    // Invalidate per-client double buffer — caller will re-pull through
    // SharedDecoder. SharedDecoder lanes are managed lazily, so an
    // explicit "seek the underlying reader" is unnecessary here; the
    // next obtainFrame() with the new timestamp drives lane selection.
    h->curPos = -1000;
    h->prevPos = -1000;

    if (readFrame) {
        (void)GetNextFrame(h, timestampMS, 0);
    }
}

const FrameView* GetNextFrame(VideoReaderHandle* h, int timestampMS, int gracetime) {
    if (!h || !IsValid(h) || h->frames == 0) {
        return nullptr;
    }

    if (timestampMS > h->lengthMS) {
        h->atEnd = true;
        return nullptr;
    }

    int currenttime = h->curPos;
    int timeOfNextFrame = currenttime + h->frameMS;
    int prevtime = h->prevPos;

    if (h->firstFramePos >= 0 && h->firstFramePos >= timestampMS) {
        timestampMS = h->firstFramePos;
    }

    // Per-client double-buffer hit: avoid re-pulling and re-scaling for
    // adjacent same-frame requests.
    if (currenttime != -1000 && timestampMS >= currenttime && timestampMS < timeOfNextFrame) {
        return &h->currentFrame();
    }
    if (prevtime != -1000 && timestampMS >= prevtime - 1 && timestampMS < currenttime) {
        return &h->prevFrame();
    }

    int pts = 0;
    int firstFramePos = h->firstFramePos;
    bool atEnd = false;
    CVPixelBufferRef pb = h->decoder->obtainFrame(timestampMS, gracetime, pts, firstFramePos, atEnd);

    if (h->firstFramePos < 0 && firstFramePos >= 0) {
        h->firstFramePos = firstFramePos;
    }

    if (!pb) {
        if (atEnd) h->atEnd = true;
        return nullptr;
    }

    // Take the native-resolution frame and scale + convert it into the
    // per-client buffer. This runs outside the SharedDecoder mutex.
    h->prevPos = h->curPos;
    h->curPos = pts;
    h->emitDecodedImage(pb);
    CVBufferRelease(pb);

    return &h->currentFrame();
}

long GetVideoLengthStatic(const std::string& filename) {
    @autoreleasepool {
        NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:filename.c_str()]];
        AVURLAsset* asset = [AVURLAsset URLAssetWithURL:url options:nil];
        if (!asset) return 0;

        // Accessing .duration triggers synchronous loading.
        CMTime duration = asset.duration;
        if (!CMTIME_IS_VALID(duration)) return 0;

        return (long)(CMTimeGetSeconds(duration) * 1000.0);
    }
}

} // namespace AppleAVFoundationVideoBridge
