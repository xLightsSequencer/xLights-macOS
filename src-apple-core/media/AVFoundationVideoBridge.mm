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
#include <map>
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

// Rawvideo support: rather than route through AVFoundation's QuickTime
// decoder or VTDecompressionSession (neither of which reliably handle
// `raw `-style codecs), we treat AVAssetReader as a pure demuxer
// (outputSettings = nil) and convert the sample bytes to BGRA ourselves.
// Works for any stride and on iPad (no FFmpeg fallback there).
enum class RawPixelLayout {
    None,
    RGB24,   // FFmpeg pix_fmt rgb24 → MOV FourCC 'raw ', depth=24
    BGR24,   // FFmpeg pix_fmt bgr24 → MOV FourCC '24BG'
    RGBA,    // FFmpeg pix_fmt rgba  → MOV FourCC 'RGBA'
    BGRA,    // FFmpeg pix_fmt bgra  → MOV FourCC 'BGRA'
    ARGB,    // FFmpeg pix_fmt argb  → MOV FourCC 'raw ', depth=32
    ABGR,    // FFmpeg pix_fmt abgr  → MOV FourCC 'ABGR'
};

const char* rawPixelLayoutName(RawPixelLayout l) {
    switch (l) {
    case RawPixelLayout::RGB24: return "RGB24";
    case RawPixelLayout::BGR24: return "BGR24";
    case RawPixelLayout::RGBA:  return "RGBA";
    case RawPixelLayout::BGRA:  return "BGRA";
    case RawPixelLayout::ARGB:  return "ARGB";
    case RawPixelLayout::ABGR:  return "ABGR";
    case RawPixelLayout::None:  return "none";
    }
    return "?";
}

int rawPixelBytesPerPixel(RawPixelLayout l) {
    switch (l) {
    case RawPixelLayout::RGB24:
    case RawPixelLayout::BGR24:
        return 3;
    case RawPixelLayout::RGBA:
    case RawPixelLayout::BGRA:
    case RawPixelLayout::ARGB:
    case RawPixelLayout::ABGR:
        return 4;
    case RawPixelLayout::None:
        return 0;
    }
    return 0;
}

RawPixelLayout detectRawPixelLayout(AVAssetTrack* track) {
    if (!track) return RawPixelLayout::None;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray* formatDescs = track.formatDescriptions;
#pragma clang diagnostic pop
    if (formatDescs.count == 0) return RawPixelLayout::None;
    CMVideoFormatDescriptionRef fd = (__bridge CMVideoFormatDescriptionRef)formatDescs[0];
    FourCharCode codec = CMFormatDescriptionGetMediaSubType((CMFormatDescriptionRef)fd);

    // AVFoundation normalizes MOV rawvideo codec tags to CoreVideo
    // pixel-format types: 'raw '+depth=24 surfaces as
    // kCVPixelFormatType_24RGB (0x00000018), 'raw '+depth=32 as
    // kCVPixelFormatType_32ARGB (0x00000020). The other layouts come
    // through with FourCC-valued kCVPixelFormatType_* constants
    // ('24BG', 'BGRA', 'RGBA', 'ABGR'), so the same switch handles both.
    switch (codec) {
    case kCVPixelFormatType_24RGB:  return RawPixelLayout::RGB24;
    case kCVPixelFormatType_24BGR:  return RawPixelLayout::BGR24;
    case kCVPixelFormatType_32RGBA: return RawPixelLayout::RGBA;
    case kCVPixelFormatType_32BGRA: return RawPixelLayout::BGRA;
    case kCVPixelFormatType_32ARGB: return RawPixelLayout::ARGB;
    case kCVPixelFormatType_32ABGR: return RawPixelLayout::ABGR;
    default:
        break;
    }
    
    // fallback if avfoudation decides to return the proper fourcc
    auto fcc = [](char a, char b, char c, char d) -> FourCharCode {
        return ((FourCharCode)(unsigned char)a << 24) |
               ((FourCharCode)(unsigned char)b << 16) |
               ((FourCharCode)(unsigned char)c << 8)  |
               ((FourCharCode)(unsigned char)d);
    };
    char tag[5] = { (char)((codec >> 24) & 0xff), (char)((codec >> 16) & 0xff),
                    (char)((codec >> 8) & 0xff),  (char)(codec & 0xff), 0 };
    spdlog::info("AVFoundationVideoBridge: track codec FourCC = '{}' (0x{:08x})", tag, codec);

    if (codec == fcc('2','4','B','G')) return RawPixelLayout::BGR24;
    if (codec == fcc('R','G','B','A')) return RawPixelLayout::RGBA;
    if (codec == fcc('B','G','R','A')) return RawPixelLayout::BGRA;
    if (codec == fcc('A','B','G','R')) return RawPixelLayout::ABGR;
    if (codec == fcc('r','a','w',' ')) {
        int depth = 0;
        CFNumberRef depthRef = (CFNumberRef)CMFormatDescriptionGetExtension(
            (CMFormatDescriptionRef)fd, kCMFormatDescriptionExtension_Depth);
        if (depthRef) CFNumberGetValue(depthRef, kCFNumberIntType, &depth);
        return (depth == 32) ? RawPixelLayout::ARGB : RawPixelLayout::RGB24;
    }
    return RawPixelLayout::None;
}

// Convert one frame from any supported rawvideo layout into BGRA.
// Source and destination strides are independent; both must be at least
// width * bytesPerPixel and width * 4 respectively.
void convertRawFrameToBGRA(RawPixelLayout layout,
                           const uint8_t* src, size_t srcStride,
                           uint8_t* dst, size_t dstStride,
                           int w, int h) {
    switch (layout) {
    case RawPixelLayout::RGB24:
        for (int y = 0; y < h; y++) {
            const uint8_t* s = src + y * srcStride;
            uint8_t* d = dst + y * dstStride;
            for (int x = 0; x < w; x++) {
                d[0] = s[2]; d[1] = s[1]; d[2] = s[0]; d[3] = 255;
                s += 3; d += 4;
            }
        }
        break;
    case RawPixelLayout::BGR24:
        for (int y = 0; y < h; y++) {
            const uint8_t* s = src + y * srcStride;
            uint8_t* d = dst + y * dstStride;
            for (int x = 0; x < w; x++) {
                d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = 255;
                s += 3; d += 4;
            }
        }
        break;
    case RawPixelLayout::RGBA: {
        vImage_Buffer s = { (void*)src, (vImagePixelCount)h, (vImagePixelCount)w, srcStride };
        vImage_Buffer d = { dst, (vImagePixelCount)h, (vImagePixelCount)w, dstStride };
        const uint8_t map[4] = { 2, 1, 0, 3 };
        vImagePermuteChannels_ARGB8888(&s, &d, map, kvImageNoFlags);
        break;
    }
    case RawPixelLayout::BGRA:
        if (srcStride == dstStride) {
            memcpy(dst, src, (size_t)dstStride * h);
        } else {
            for (int y = 0; y < h; y++) {
                memcpy(dst + y * dstStride, src + y * srcStride, (size_t)w * 4);
            }
        }
        break;
    case RawPixelLayout::ARGB: {
        vImage_Buffer s = { (void*)src, (vImagePixelCount)h, (vImagePixelCount)w, srcStride };
        vImage_Buffer d = { dst, (vImagePixelCount)h, (vImagePixelCount)w, dstStride };
        const uint8_t map[4] = { 3, 2, 1, 0 };
        vImagePermuteChannels_ARGB8888(&s, &d, map, kvImageNoFlags);
        break;
    }
    case RawPixelLayout::ABGR: {
        vImage_Buffer s = { (void*)src, (vImagePixelCount)h, (vImagePixelCount)w, srcStride };
        vImage_Buffer d = { dst, (vImagePixelCount)h, (vImagePixelCount)w, dstStride };
        const uint8_t map[4] = { 1, 2, 3, 0 };
        vImagePermuteChannels_ARGB8888(&s, &d, map, kvImageNoFlags);
        break;
    }
    case RawPixelLayout::None:
        break;
    }
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
constexpr int kCacheCapacity = 64;

// After serving the requested frame we opportunistically decode K more
// frames so the next forward request becomes a cache hit rather than
// triggering a fresh `copyNextSampleBuffer` cycle. With per-handle private
// caches in front of the shared cache, this also defines how many frames
// each consumer can pre-load on a single SharedDecoder mutex acquisition;
// bigger value = more work per acquisition but fewer acquisitions overall.
constexpr int kReadAheadFrames = 8;

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
    // outAtEnd when no more frames are available. `consumer` is the
    // calling client's identity (treated as opaque pointer); used to
    // record this client's current playback position for cache-eviction
    // accounting. Pass nullptr if there's no stable consumer identity.
    //
    // `outReadAhead` is populated with the read-ahead frames decoded as
    // a side effect of satisfying this call (retained; caller owns and
    // must CVBufferRelease each entry). The caller is expected to stash
    // these in its own private cache so subsequent forward calls don't
    // need to take the SharedDecoder mutex at all.
    struct ReadAheadFrame {
        int64_t ptsMs;
        CVPixelBufferRef pixelBuffer; // retained
    };
    CVPixelBufferRef obtainFrame(int timestampMS, int gracetimeMS,
                                 int& outPtsMs, int& outFirstFramePos,
                                 bool& outAtEnd, void* consumer,
                                 std::vector<ReadAheadFrame>& outReadAhead);

    // Remove a consumer from the position-tracking map. Called from
    // VideoReaderHandle destructor so we don't keep "ghost" consumers
    // pinning cache regions after they're gone.
    void forgetConsumer(void* consumer);

private:
    SharedDecoder() = default;
    SharedDecoder(const SharedDecoder&) = delete;
    SharedDecoder& operator=(const SharedDecoder&) = delete;

    bool open(const std::string& filename);

    struct Lane {
        AVAssetReader* reader = nil;
        AVAssetReaderTrackOutput* trackOutput = nil;
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
        CVPixelBufferRef decodeNextRaw(SharedDecoder* dec, int& outPtsMs);

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

    // Insert into cache, retaining. Evicts farthest-from-anchors when at
    // capacity. `anchors` is the precomputed set of "positions worth
    // keeping frames near" — every active consumer's tracked position
    // plus other lanes' curPos. The current insert's own ptsMs is added
    // implicitly so freshly inserted frames stay clustered.
    void cacheInsert(int64_t ptsMs, CVPixelBufferRef pixelBuffer,
                     const std::vector<int64_t>& anchors);

    // Walk cache forward from afterPtsMs, appending up to kReadAheadFrames
    // entries (retained) to out in pts order. Stops at the first gap
    // larger than 2 * frameMS or when entries get farther ahead than
    // 2 * kReadAheadFrames * frameMS — both bounds prevent stashing
    // far-future frames in the consumer's small private cache where they
    // would just consume slots without being requested soon.
    void populateReadAheadFromCache(int64_t afterPtsMs,
                                    std::vector<ReadAheadFrame>& out);

    std::mutex mutex;

    AVAsset* asset = nil;
    AVAssetTrack* videoTrack = nil;

    std::string filename;
    bool valid = false;
    bool openFailed = false;
    bool useSoftwareDecode = false;
    bool useRawDecode = false;
    RawPixelLayout rawLayout = RawPixelLayout::None;
    int rawBytesPerPixel = 0;

    // Pool of BGRA destination buffers for the rawvideo decode path.
    // Created once per SharedDecoder at known dimensions; reused across
    // frames so we don't pay CVPixelBufferCreate cost per frame.
    // No IOSurface backing: the buffer is read on the CPU by the
    // scaler/consumer; IOSurface allocation is ~24us/frame on macOS
    // for these small frame sizes.
    CVPixelBufferPoolRef rawBgraPool = nullptr;

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
        CVPixelBufferRef pixelBuffer = nullptr; // retained
        int64_t lastAccessTick = 0;
    };
    // Keyed on pts (milliseconds). Ordered map so cacheLookup is an
    // upper_bound walk and populateReadAheadFromCache iterates forward
    // from a single binary-search seek — both O(log n) regardless of
    // capacity. Eviction is still O(n × anchors), unaffected by the
    // container choice.
    std::map<int64_t, CacheEntry> cache;
    int64_t cacheTick = 0;

    // Map of active consumers (VideoReaderHandle*) to their most-recently
    // requested timestamp. The cache eviction policy uses these positions
    // to keep cached frames near every active consumer's playhead, not
    // just near the two lanes. Without this, when N>=3 consumers diverge
    // in playback speed, the cache thrashes as LRU evicts one consumer's
    // active frames in favor of read-ahead for another.
    std::unordered_map<void*, int64_t> consumerPositions;
};

// Global path → SharedDecoder weak registry. Refcounted via shared_ptr
// held by every VideoReaderHandle that uses the file; the last release
// drops the decoder and its lanes/sessions.
std::mutex g_decodersMutex;
std::unordered_map<std::string, std::weak_ptr<SharedDecoder>> g_decoders;

std::shared_ptr<SharedDecoder> SharedDecoder::acquire(const std::string& filename) {
    if ([NSThread isMainThread]) {
        // On the main thread, create a dedicated decoder to not interfere with the render threads
        auto sp = std::shared_ptr<SharedDecoder>(new SharedDecoder());
        sp->open(filename);
        return sp;
    }
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

void SharedDecoder::forgetConsumer(void* consumer) {
    if (!consumer) return;
    std::lock_guard<std::mutex> lk(mutex);
    consumerPositions.erase(consumer);
}

SharedDecoder::~SharedDecoder() {
    // Lanes destruct in array destruction; each calls close() which
    // releases its reader, VT session, format desc, and any queued
    // decoded frames.
    for (auto& [_, e] : cache) {
        if (e.pixelBuffer) {
            CVBufferRelease(e.pixelBuffer);
            e.pixelBuffer = nullptr;
        }
    }
    cache.clear();

    if (rawBgraPool) {
        CVPixelBufferPoolRelease(rawBgraPool);
        rawBgraPool = nullptr;
    }

    videoTrack = nil;
    asset = nil;

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

        rawLayout = detectRawPixelLayout(videoTrack);
        if (rawLayout != RawPixelLayout::None) {
            useRawDecode = true;
            rawBytesPerPixel = rawPixelBytesPerPixel(rawLayout);
            spdlog::info("AVFoundationVideoBridge: rawvideo ({}) for {}; using direct demux + manual BGRA conversion",
                         rawPixelLayoutName(rawLayout), fname);
        } else if (isRawvideoUnalignedStride(videoTrack)) {
            // Defensive: detectRawPixelLayout already covers 'raw ' codec,
            // so this branch should be unreachable. Kept as a backstop in
            // case a future codec tag escapes the detector.
            spdlog::info("AVFoundationVideoBridge: rawvideo MOV with unaligned row stride for {}; "
                         "AVFoundation cannot decode — invalidating reader (desktop will fall back to FFmpeg)",
                         fname);
            openFailed = true;
            return false;
        } else {
            useSoftwareDecode = !probeHardwareDecoderSupport(videoTrack);
            if (useSoftwareDecode) {
                spdlog::info("AVFoundationVideoBridge: HW decode unsupported for {}; using software VTDecompressionSession path", fname);
            }
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

        // For rawvideo we own the BGRA buffer; build a no-IOSurface pool
        // so per-frame allocation is just a refcount bump for buffers that
        // have already cycled out of the cache. IOSurface backing would
        // add ~24us per frame on these small frame sizes for no benefit —
        // downstream reads on the CPU via vImage/Lock+BaseAddress.
        if (useRawDecode) {
            NSDictionary* pbAttrs = @{
                (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                (NSString*)kCVPixelBufferWidthKey: @(nativeWidth),
                (NSString*)kCVPixelBufferHeightKey: @(nativeHeight),
            };
            NSDictionary* poolAttrs = @{
                (NSString*)kCVPixelBufferPoolMinimumBufferCountKey: @(4),
            };
            CVReturn pr = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                                   (__bridge CFDictionaryRef)poolAttrs,
                                                   (__bridge CFDictionaryRef)pbAttrs,
                                                   &rawBgraPool);
            if (pr != kCVReturnSuccess) {
                spdlog::warn("AVFoundationVideoBridge: rawvideo BGRA pool create failed ({}); will fall back to CVPixelBufferCreate per frame",
                             (int)pr);
                rawBgraPool = nullptr;
            }
        }

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
        // buffers at the track's native resolution. SW path and raw
        // path: nil outputSettings makes AVAssetReader a pure demuxer;
        // SW runs its own VTDecompressionSession, raw converts the
        // bytes to BGRA directly.
        NSDictionary* outputSettings = nil;
        if (!dec->useSoftwareDecode && !dec->useRawDecode) {
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
        //
        // Exception: the rawvideo decode path immediately copies the
        // sample bytes into its own pooled BGRA CVPixelBuffer (see
        // decodeNextRaw) and releases the source sample before the next
        // copyNextSampleBuffer call — so the pool-reuse hazard doesn't
        // apply and the per-frame copy is wasted work (~30us/frame on
        // these small frames). Skip the copy in that case.
        trackOutput.alwaysCopiesSampleData = dec->useRawDecode ? NO : YES;

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
    if (dec->useRawDecode) {
        AVAssetReaderStatus readerStatus = reader.status;
        if (readerStatus != AVAssetReaderStatusReading) {
            if (readerStatus == AVAssetReaderStatusFailed) {
                spdlog::error("AVFoundationVideoBridge: Reader failed (raw): {}",
                             reader.error ? [[reader.error localizedDescription] UTF8String] : "unknown");
            }
            demuxAtEnd = true;
            return nullptr;
        }
        return decodeNextRaw(dec, outPtsMs);
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

CVPixelBufferRef SharedDecoder::Lane::decodeNextRaw(SharedDecoder* dec, int& outPtsMs) {
    @autoreleasepool {
        CMSampleBufferRef sample = nullptr;
        @try {
            sample = [trackOutput copyNextSampleBuffer];
        } @catch (NSException* exception) {
            spdlog::error("AVFoundationVideoBridge: Exception in copyNextSampleBuffer (raw): {} - {}",
                         [[exception name] UTF8String], [[exception reason] UTF8String]);
            demuxAtEnd = true;
            return nullptr;
        }
        if (!sample) {
            if (reader.status != AVAssetReaderStatusReading) {
                demuxAtEnd = true;
            }
            return nullptr;
        }
        if (!CMSampleBufferIsValid(sample)) {
            CFRelease(sample);
            return nullptr;
        }

        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
        int ptsMs = CMTIME_IS_VALID(pts) ? (int)(CMTimeGetSeconds(pts) * 1000.0) : 0;

        // For uncompressed (rawvideo) tracks AVAssetReader hands us the
        // frame as a CVPixelBufferRef on the sample's image buffer, not
        // as a CMBlockBuffer. Empty preface samples (image buffer == nil)
        // do show up occasionally on lane open — skip them; the caller
        // will retry.
        CVImageBufferRef srcImage = CMSampleBufferGetImageBuffer(sample);
        if (!srcImage) {
            CFRelease(sample);
            return nullptr;
        }
        CVPixelBufferRetain(srcImage);
        CFRelease(sample);

        // Fast path: if AVAssetReader already gave us BGRA, hand it back
        // directly (no manual conversion needed).
        OSType srcFmt = CVPixelBufferGetPixelFormatType(srcImage);
        if (srcFmt == kCVPixelFormatType_32BGRA) {
            outPtsMs = ptsMs;
            return srcImage;
        }

        const int w = (int)CVPixelBufferGetWidth(srcImage);
        const int h = (int)CVPixelBufferGetHeight(srcImage);

        CVPixelBufferRef bgra = nullptr;
        // Fast path: pull a recycled buffer from the SharedDecoder pool.
        // The pool is sized so cycled-out cache entries refill it
        // without an actual allocation per frame.
        if (dec->rawBgraPool) {
            CVReturn pr = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                              dec->rawBgraPool, &bgra);
            if (pr != kCVReturnSuccess) {
                spdlog::warn("AVFoundationVideoBridge: rawvideo pool exhausted ({}); falling back to direct create",
                             (int)pr);
                bgra = nullptr;
            }
        }
        if (!bgra) {
            // Fallback: direct create, no IOSurface (downstream reads on CPU).
            CVReturn r = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                              kCVPixelFormatType_32BGRA,
                                              nullptr, &bgra);
            if (r != kCVReturnSuccess || !bgra) {
                spdlog::error("AVFoundationVideoBridge: CVPixelBufferCreate (raw) failed: {}", (int)r);
                CVPixelBufferRelease(srcImage);
                return nullptr;
            }
        }

        CVPixelBufferLockBaseAddress(srcImage, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferLockBaseAddress(bgra, 0);

        const uint8_t* srcBytes = (const uint8_t*)CVPixelBufferGetBaseAddress(srcImage);
        const size_t srcStride = CVPixelBufferGetBytesPerRow(srcImage);
        uint8_t* dst = (uint8_t*)CVPixelBufferGetBaseAddress(bgra);
        const size_t dstStride = CVPixelBufferGetBytesPerRow(bgra);

        convertRawFrameToBGRA(dec->rawLayout, srcBytes, srcStride, dst, dstStride, w, h);

        CVPixelBufferUnlockBaseAddress(bgra, 0);
        CVPixelBufferUnlockBaseAddress(srcImage, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(srcImage);

        outPtsMs = ptsMs;
        return bgra;
    }
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
    // upper_bound returns the first entry with pts > targetMS; step back
    // to the candidate whose [pts, pts+frameMS) interval may contain it.
    auto it = cache.upper_bound((int64_t)targetMS);
    if (it == cache.begin()) return nullptr;
    --it;
    if ((int64_t)targetMS >= it->first + frameMS) return nullptr;
    if (!it->second.pixelBuffer) return nullptr;
    it->second.lastAccessTick = ++cacheTick;
    outPtsMs = (int)it->first;
    CVBufferRetain(it->second.pixelBuffer);
    return it->second.pixelBuffer;
}

void SharedDecoder::cacheInsert(int64_t ptsMs, CVPixelBufferRef pixelBuffer,
                                 const std::vector<int64_t>& anchors) {
    // Dedupe — same pts replaces existing entry.
    auto existing = cache.find(ptsMs);
    if (existing != cache.end() && existing->second.pixelBuffer) {
        if (existing->second.pixelBuffer != pixelBuffer) {
            CVBufferRelease(existing->second.pixelBuffer);
            CVBufferRetain(pixelBuffer);
            existing->second.pixelBuffer = pixelBuffer;
        }
        existing->second.lastAccessTick = ++cacheTick;
        return;
    }

    if ((int)cache.size() >= kCacheCapacity) {
        // Pick the eviction victim: the entry whose pts is farthest from
        // every anchor (active consumers' tracked positions + other lanes'
        // curPos + this insert's own pts). With multiple consumers reading
        // the same file at different positions, pure LRU evicts still-
        // needed frames in one consumer's region to make room for read-
        // ahead in another's — even though re-decoding those evicted
        // frames is far more expensive than the few KB we'd keep. Anchor-
        // distance eviction protects the union of "near-active-position"
        // corridors instead.
        auto victim = cache.end();
        int64_t bestMaxMinDist = INT64_MIN;
        for (auto it = cache.begin(); it != cache.end(); ++it) {
            int64_t minDist = std::abs(it->first - ptsMs);
            for (int64_t a : anchors) {
                int64_t d = std::abs(it->first - a);
                if (d < minDist) minDist = d;
            }
            if (minDist > bestMaxMinDist) {
                bestMaxMinDist = minDist;
                victim = it;
            }
        }
        if (victim != cache.end()) {
            if (victim->second.pixelBuffer) {
                CVBufferRelease(victim->second.pixelBuffer);
            }
            cache.erase(victim);
        }
    }

    CacheEntry e;
    e.pixelBuffer = (CVPixelBufferRef)CVBufferRetain(pixelBuffer);
    e.lastAccessTick = ++cacheTick;
    cache.emplace(ptsMs, e);
}

void SharedDecoder::populateReadAheadFromCache(int64_t afterPtsMs,
                                                std::vector<ReadAheadFrame>& out) {
    // Hard cap on how far ahead we will reach into the cache. Past this
    // the consumer's small private cache wastes slots on frames it will
    // not request soon — they would just rotate out before being read.
    const int64_t maxPts = afterPtsMs + (int64_t)kReadAheadFrames * frameMS * 2;
    // Stop at the first gap larger than ~2 frames. Past a gap the
    // consumer has to re-enter obtainFrame to fill it anyway, so cached
    // frames beyond the gap don't avoid mutex acquisitions; they would
    // just consume privCache slots.
    const int64_t maxGap = (int64_t)frameMS * 2;

    out.reserve(out.size() + kReadAheadFrames);
    int64_t prevPts = afterPtsMs;
    int n = 0;
    for (auto it = cache.upper_bound(afterPtsMs);
         it != cache.end() && n < kReadAheadFrames;
         ++it) {
        if (it->first > maxPts) break;
        if (it->first - prevPts > maxGap) break;
        if (!it->second.pixelBuffer) continue;
        it->second.lastAccessTick = ++cacheTick;
        CVBufferRetain(it->second.pixelBuffer);
        out.push_back({it->first, it->second.pixelBuffer});
        prevPts = it->first;
        ++n;
    }
}

CVPixelBufferRef SharedDecoder::obtainFrame(int timestampMS, int gracetimeMS,
                                             int& outPtsMs, int& outFirstFramePos,
                                             bool& outAtEnd, void* consumer,
                                             std::vector<ReadAheadFrame>& outReadAhead) {
    std::lock_guard<std::mutex> lk(mutex);
    outAtEnd = false;
    outFirstFramePos = firstFramePos;
    outPtsMs = 0;
    outReadAhead.clear();
    if (consumer) {
        // Initial pin — updated below on success to (last pts handed back
        // + frameMS), i.e. the next pts the consumer will request from
        // shared cache. Anchoring eviction on that, rather than on
        // timestampMS, protects the *next* frames the consumer will need
        // from the shared cache; the frames it just received already live
        // in its private cache and won't re-enter obtainFrame.
        consumerPositions[consumer] = timestampMS;
    }

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
        populateReadAheadFromCache(outPtsMs, outReadAhead);
        if (consumer) {
            // The consumer now holds [outPtsMs, ..., outReadAhead.back().ptsMs]
            // in its private cache; the next shared-cache request will be
            // for the frame after that, so anchor eviction on that pts.
            int64_t lastHeld = outReadAhead.empty()
                ? (int64_t)outPtsMs
                : outReadAhead.back().ptsMs;
            consumerPositions[consumer] = lastHeld + frameMS;
        }
        return hit;
    }

    Lane* lane = selectLane(targetMS, gracetimeMS);
    if (!lane) {
        outAtEnd = true;
        return nullptr;
    }

    // Precompute the static anchor set used by cacheInsert's eviction
    // policy. These don't change across the catch-up + read-ahead inserts
    // within a single obtainFrame: consumerPositions is updated only at
    // the very end, and other lanes' curPos is only advanced by their own
    // obtainFrame calls (which are serialized behind our mutex). The
    // active lane's moving curPos is added implicitly by cacheInsert via
    // the per-insert ptsMs anchor (lane->curPos == pts at each insert).
    std::vector<int64_t> evAnchors;
    evAnchors.reserve(1 + consumerPositions.size());
    for (auto& l : lanes) {
        if (&l != lane && l.active && !l.demuxAtEnd) {
            evAnchors.push_back(l.curPos);
        }
    }
    for (auto& [_, pos] : consumerPositions) {
        evAnchors.push_back(pos);
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
        cacheInsert(pts, pb, evAnchors);
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

    // Read ahead so the next forward requests become cache hits. We also
    // hand each read-ahead frame back to the caller (retained) so it can
    // populate its own private lock-free cache; this is the primary
    // mechanism for keeping the SharedDecoder mutex from serializing
    // multiple consumers stepping through the same file.
    outReadAhead.reserve(kReadAheadFrames);
    for (int i = 0; i < kReadAheadFrames; ++i) {
        int aheadPts = 0;
        CVPixelBufferRef aheadPb = lane->decodeNext(this, aheadPts);
        if (!aheadPb) break;
        lane->curPos = aheadPts;
        // cacheInsert adds its own retain; the caller takes ownership of
        // the +1 retain `decodeNext` gave us.
        cacheInsert(aheadPts, aheadPb, evAnchors);
        outReadAhead.push_back({aheadPts, aheadPb});
    }

    if (consumer) {
        int64_t lastHeld = outReadAhead.empty()
            ? (int64_t)resultPts
            : outReadAhead.back().ptsMs;
        consumerPositions[consumer] = lastHeld + frameMS;
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
    CIContext* ciContext = nil;
    CVPixelBufferRef scaledPixelBuffer = nullptr;

    // Per-client private look-ahead cache. Each obtainFrame call returns
    // the requested frame *and* up to kPerHandleReadAhead extra read-ahead
    // frames (decoded as a side effect on the shared lane). The extras
    // are deposited here so subsequent GetNextFrame calls for forward
    // timestamps hit the private cache without taking the SharedDecoder
    // mutex. This is the primary contention-reduction lever for the
    // multi-reader-per-file render scenario: when N consumers diverge in
    // playback speed, each one's near-future frames live in its own
    // cache and can't be evicted by the others.
    static constexpr int kPerHandleCacheSize = 16;
    struct PrivateCacheEntry {
        int64_t ptsMs = -1;
        CVPixelBufferRef pixelBuffer = nullptr; // retained
    };
    std::array<PrivateCacheEntry, kPerHandleCacheSize> privCache{};
    int privCacheNextSlot = 0; // round-robin replacement

    FrameView& currentFrame() { return frame1IsCurrent ? frameView1 : frameView2; }
    FrameView& prevFrame() { return frame1IsCurrent ? frameView2 : frameView1; }
    uint8_t* currentBuffer() { return frame1IsCurrent ? frameBuffer1 : frameBuffer2; }
    void swapFrames() { frame1IsCurrent = !frame1IsCurrent; }

    ~VideoReaderHandle() {
        // Forget this handle's tracked position before the shared_ptr
        // drops — otherwise an evict-anchor entry persists for a dead
        // consumer and skews future eviction decisions until the
        // SharedDecoder itself goes away.
        if (decoder) decoder->forgetConsumer(this);

        for (auto& e : privCache) {
            if (e.pixelBuffer) CVBufferRelease(e.pixelBuffer);
        }

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
        ciContext = nil;
        // shared_ptr decrements the SharedDecoder refcount; last
        // release tears down the file's lanes and frame cache.
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
    // Drop the private cache: a backward seek would otherwise return
    // a still-cached future frame from before the seek.
    for (auto& e : h->privCache) {
        if (e.pixelBuffer) { CVBufferRelease(e.pixelBuffer); e.pixelBuffer = nullptr; }
        e.ptsMs = -1;
    }
    h->privCacheNextSlot = 0;

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

    // Per-handle private cache hit: serve the frame without taking the
    // SharedDecoder mutex at all. Populated by previous obtainFrame
    // calls' read-ahead. This is the contention-busting fast path for
    // multi-reader scenarios — when several VideoReaders pull from the
    // same file in parallel, each one ploughs through its own private
    // 16-frame buffer between mutex acquisitions, so the shared decoder
    // mutex serializes a 16x lower rate than per-call.
    int pts = 0;
    CVPixelBufferRef pb = nullptr;
    for (auto& e : h->privCache) {
        if (e.pixelBuffer && e.ptsMs <= timestampMS && timestampMS < e.ptsMs + h->frameMS) {
            pts = (int)e.ptsMs;
            pb = (CVPixelBufferRef)CVBufferRetain(e.pixelBuffer);
            break;
        }
    }

    if (!pb) {
        int firstFramePos = h->firstFramePos;
        bool atEnd = false;
        std::vector<SharedDecoder::ReadAheadFrame> readAhead;
        pb = h->decoder->obtainFrame(timestampMS, gracetime, pts, firstFramePos,
                                      atEnd, h, readAhead);

        if (h->firstFramePos < 0 && firstFramePos >= 0) {
            h->firstFramePos = firstFramePos;
        }
        if (!pb) {
            // We took ownership of any returned read-ahead frames; release.
            for (auto& f : readAhead) if (f.pixelBuffer) CVBufferRelease(f.pixelBuffer);
            if (atEnd) h->atEnd = true;
            return nullptr;
        }

        // Stash the read-ahead frames in the private cache. Round-robin
        // replacement keeps the cache fresh; older entries (consumed or
        // skipped over) get overwritten by the next batch's results.
        for (auto& f : readAhead) {
            auto& slot = h->privCache[h->privCacheNextSlot];
            h->privCacheNextSlot = (h->privCacheNextSlot + 1) %
                                    VideoReaderHandle::kPerHandleCacheSize;
            if (slot.pixelBuffer) CVBufferRelease(slot.pixelBuffer);
            slot.ptsMs = f.ptsMs;
            slot.pixelBuffer = f.pixelBuffer; // ownership transferred
        }
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
