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

#include "AVFoundationVideoBridge.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreImage/CoreImage.h>
#import <Accelerate/Accelerate.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <queue>
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

} // namespace

namespace AppleAVFoundationVideoBridge {

// __strong is explicit so ARC retains ObjC objects stored in this C++ struct.
struct VideoReaderHandle {
    __strong AVAsset* asset = nil;
    __strong AVAssetTrack* videoTrack = nil;
    __strong AVAssetReader* reader = nil;
    __strong AVAssetReaderTrackOutput* trackOutput = nil;
    VTPixelTransferSessionRef transferSession = nullptr;
    __strong CIContext* ciContext = nil;

    // Software-decode path: AVAssetReader is used for demux only (raw H.264
    // sample buffers), and we run our own VTDecompressionSession with HW
    // disabled. Used for streams that fail probeHardwareDecoderSupport().
    bool useSoftwareDecode = false;
    VTDecompressionSessionRef vtSession = nullptr;
    CMVideoFormatDescriptionRef cachedFormatDesc = nullptr; // retained
    int maxBFrameDelay = 2;                                  // queue depth = this + 1
    bool demuxAtEnd = false;
    std::mutex queueMutex;
    struct DecodedEntry {
        CVImageBufferRef image; // retained
        int64_t ptsMs;
        bool operator<(const DecodedEntry& o) const { return ptsMs > o.ptsMs; } // min-heap
    };
    std::priority_queue<DecodedEntry, std::vector<DecodedEntry>> ptsQueue;

    std::string filename;
    bool valid = false;
    bool atEnd = false;
    bool failed = false;
    bool wantAlpha = false;
    bool bgr = false;
    bool wantsHWType = false;
    ScaleAlgorithm scaleAlgorithm = ScaleAlgorithm::Default;

    int width = 0;          // output width
    int height = 0;         // output height
    int nativeWidth = 0;    // source width
    int nativeHeight = 0;   // source height
    double lengthMS = 0;
    long frames = 0;
    int frameMS = 50;
    int curPos = -1000;
    int firstFramePos = -1;

    PixelFormat outputFormat = PixelFormat::RGB24;

    // Double-buffered output frames (current + previous)
    uint8_t* frameBuffer1 = nullptr;
    uint8_t* frameBuffer2 = nullptr;
    int frameBufferSize = 0;

    FrameView frameView1;
    FrameView frameView2;
    bool frame1IsCurrent = true;

    CVPixelBufferRef scaledPixelBuffer = nullptr;

    FrameView& currentFrame() { return frame1IsCurrent ? frameView1 : frameView2; }
    FrameView& prevFrame() { return frame1IsCurrent ? frameView2 : frameView1; }
    uint8_t* currentBuffer() { return frame1IsCurrent ? frameBuffer1 : frameBuffer2; }
    void swapFrames() { frame1IsCurrent = !frame1IsCurrent; }

    ~VideoReaderHandle() {
        closeReader();
        if (transferSession) {
            VTPixelTransferSessionInvalidate(transferSession);
            CFRelease(transferSession);
            transferSession = nullptr;
        }
        if (scaledPixelBuffer) {
            CVPixelBufferRelease(scaledPixelBuffer);
            scaledPixelBuffer = nullptr;
        }
        if (cachedFormatDesc) {
            CFRelease(cachedFormatDesc);
            cachedFormatDesc = nullptr;
        }
        if (frameBuffer1) { free(frameBuffer1); frameBuffer1 = nullptr; }
        if (frameBuffer2) { free(frameBuffer2); frameBuffer2 = nullptr; }
        // ARC handles ObjC objects.
    }

    void closeReader() {
        closeVTSession();
        if (reader) {
            [reader cancelReading];
            reader = nil;
        }
        trackOutput = nil;
        demuxAtEnd = false;
    }

    void closeVTSession() {
        if (vtSession) {
            VTDecompressionSessionInvalidate(vtSession);
            CFRelease(vtSession);
            vtSession = nullptr;
        }
        std::lock_guard<std::mutex> lk(queueMutex);
        while (!ptsQueue.empty()) {
            CVBufferRelease(ptsQueue.top().image);
            ptsQueue.pop();
        }
    }

    static void vtOutputCallback(void* refCon, void* /*sourceFrameRefCon*/,
                                 OSStatus status, VTDecodeInfoFlags /*infoFlags*/,
                                 CVImageBufferRef imageBuffer,
                                 CMTime pts, CMTime /*duration*/) {
        if (status != noErr || imageBuffer == nullptr) return;
        VideoReaderHandle* self = static_cast<VideoReaderHandle*>(refCon);
        DecodedEntry entry;
        entry.image = (CVImageBufferRef)CVBufferRetain(imageBuffer);
        entry.ptsMs = CMTIME_IS_VALID(pts) ? (int64_t)(CMTimeGetSeconds(pts) * 1000.0) : 0;
        std::lock_guard<std::mutex> lk(self->queueMutex);
        self->ptsQueue.push(entry);
    }

    bool openReader(CMTime startTime) {
        closeReader();

        // [AVAssetReader addOutput:] starts internal KVO observers that
        // autorelease NSStrings via -[NSString initWithFormat:]. Drain
        // those locally instead of letting them pile up on the render
        // thread's job-scoped pool, which only flushes when the whole
        // render finishes.
        @autoreleasepool {
            NSError* error = nil;
            reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
            if (!reader || error) {
                spdlog::error("AVFoundationVideoBridge: Failed to create AVAssetReader: {}",
                             error ? [[error localizedDescription] UTF8String] : "unknown error");
                return false;
            }

            // HW path: ask AVAssetReader to deliver decoded BGRA pixel buffers.
            // SW path: pass nil outputSettings so AVAssetReader becomes a pure
            // demuxer; we run our own VTDecompressionSession with HW disabled
            // for streams that fail the HW probe.
            NSDictionary* outputSettings = nil;
            if (!useSoftwareDecode) {
                outputSettings = @{
                    (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
                };
            }
            trackOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack
                                                           outputSettings:outputSettings];
            trackOutput.alwaysCopiesSampleData = NO;

            if (![reader canAddOutput:trackOutput]) {
                spdlog::error("AVFoundationVideoBridge: Cannot add track output to reader");
                reader = nil;
                trackOutput = nil;
                return false;
            }
            [reader addOutput:trackOutput];

            CMTime duration = asset.duration;
            CMTime rangeStart = startTime;
            CMTime rangeEnd = CMTimeSubtract(duration, startTime);
            if (CMTimeCompare(rangeEnd, kCMTimeZero) <= 0) {
                rangeEnd = kCMTimeZero;
            }
            reader.timeRange = CMTimeRangeMake(rangeStart, rangeEnd);

            if (![reader startReading]) {
                spdlog::error("AVFoundationVideoBridge: Failed to start reading: {}",
                             reader.error ? [[reader.error localizedDescription] UTF8String] : "unknown");
                reader = nil;
                trackOutput = nil;
                return false;
            }

            return true;
        }
    }

    // Build a fresh software-mode VTDecompressionSession bound to the given
    // format description. AVAssetReader can deliver samples whose format
    // description differs from the track's published one (or there can be
    // multiple in a track); the only way to be sure the session matches is
    // to construct it from the sample's own format description on first use,
    // and rebuild if it ever changes.
    bool ensureVTSession(CMVideoFormatDescriptionRef formatDesc) {
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
            .decompressionOutputCallback = &VideoReaderHandle::vtOutputCallback,
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

        swapFrames();
        copyPixelBufferToFrame(scaledPixelBuffer);
        return true;
    }

    void emitDecodedImage(CVImageBufferRef imageBuffer) {
        bool needsScale = ((int)CVPixelBufferGetWidth(imageBuffer) != width ||
                           (int)CVPixelBufferGetHeight(imageBuffer) != height);

        if (needsScale) {
            if (scaleAlgorithm != ScaleAlgorithm::Default) {
                if (ciFilterScale(imageBuffer)) return;
            } else {
                if (ensureTransferSession() && ensureScaledPixelBuffer()) {
                    OSStatus xferStatus = VTPixelTransferSessionTransferImage(transferSession,
                                                                              imageBuffer,
                                                                              scaledPixelBuffer);
                    if (xferStatus == noErr) {
                        swapFrames();
                        copyPixelBufferToFrame(scaledPixelBuffer);
                        return;
                    } else {
                        spdlog::warn("AVFoundationVideoBridge: VTPixelTransferSession failed ({}), falling back to unscaled", (int)xferStatus);
                    }
                }
            }
        }

        swapFrames();
        copyPixelBufferToFrame(imageBuffer);
    }

    bool decodeNextFrameHW() {
        @autoreleasepool {
            CMSampleBufferRef sampleBuffer = nullptr;

            @try {
                sampleBuffer = [trackOutput copyNextSampleBuffer];
            } @catch (NSException* exception) {
                spdlog::error("AVFoundationVideoBridge: Exception in copyNextSampleBuffer: {} - {}",
                             [[exception name] UTF8String], [[exception reason] UTF8String]);
                failed = true;
                return false;
            }

            if (!sampleBuffer) {
                if (reader.status != AVAssetReaderStatusReading) {
                    atEnd = true;
                }
                return false;
            }

            if (!CMSampleBufferIsValid(sampleBuffer)) {
                spdlog::warn("AVFoundationVideoBridge: Invalid sample buffer received");
                CFRelease(sampleBuffer);
                return false;
            }

            CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
            if (CMTIME_IS_VALID(pts)) {
                curPos = (int)(CMTimeGetSeconds(pts) * 1000.0);
            }
            if (firstFramePos == -1) {
                firstFramePos = curPos;
            }

            CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
            if (!imageBuffer) {
                CFRelease(sampleBuffer);
                return false;
            }

            emitDecodedImage(imageBuffer);
            CFRelease(sampleBuffer);
            return true;
        }
    }

    bool decodeNextFrameSW() {
        const int threshold = maxBFrameDelay + 1;

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
                    failed = true;
                    return false;
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
                    spdlog::error("AVFoundationVideoBridge: ensureVTSession failed for {} (sample format desc {}); aborting SW reader",
                                 filename, (void*)sampleFormat);
                    CFRelease(sample);
                    failed = true;
                    return false;
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
            atEnd = true;
            return false;
        }

        curPos = (int)entry.ptsMs;
        if (firstFramePos == -1) firstFramePos = curPos;

        emitDecodedImage(entry.image);
        CVBufferRelease(entry.image);
        return true;
    }

    int queueSize() {
        std::lock_guard<std::mutex> lk(queueMutex);
        return (int)ptsQueue.size();
    }

    bool decodeNextFrame() {
        if (!reader) {
            return false;
        }
        if (!useSoftwareDecode) {
            AVAssetReaderStatus readerStatus = reader.status;
            if (readerStatus != AVAssetReaderStatusReading) {
                if (readerStatus == AVAssetReaderStatusFailed) {
                    spdlog::error("AVFoundationVideoBridge: Reader failed: {}",
                                 reader.error ? [[reader.error localizedDescription] UTF8String] : "unknown");
                }
                atEnd = true;
                return false;
            }
            return decodeNextFrameHW();
        }
        return decodeNextFrameSW();
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

    // [AVURLAsset URLAssetWithURL:] internally autoreleases NSArrays/NSStrings
    // via AVCMNotificationDispatcher when registering FigAsset notification
    // listeners. Drain locally so they don't accumulate on the render-job pool.
    @autoreleasepool {
        NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:filename.c_str()]];
        AVURLAsset* urlAsset = [AVURLAsset URLAssetWithURL:url options:nil];
        h->asset = urlAsset;
        if (!h->asset) {
            spdlog::error("AVFoundationVideoBridge: Failed to create AVAsset for {}", filename);
            return h;
        }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSArray<AVAssetTrack*>* tracks = [h->asset tracksWithMediaType:AVMediaTypeVideo];
#pragma clang diagnostic pop
        if (tracks.count == 0) {
            spdlog::error("AVFoundationVideoBridge: No video tracks in {}", filename);
            return h;
        }
        h->videoTrack = tracks[0];

        // Files that fail HW probe — typically H.264 High@L1.0 with B-frames at
        // very small resolutions — cause AVAssetReader's HW decoder to silently
        // wedge mid-stream. Route them through a manual VTDecompressionSession
        // with HW disabled instead.
        h->useSoftwareDecode = !probeHardwareDecoderSupport(h->videoTrack);
        if (h->useSoftwareDecode) {
            spdlog::info("AVFoundationVideoBridge: HW decode unsupported for {}; using software VTDecompressionSession path", filename);
        }

        CGSize naturalSize = h->videoTrack.naturalSize;

        // Apply rotation transform to get correct dimensions.
        CGAffineTransform transform = h->videoTrack.preferredTransform;
        CGSize transformedSize = CGSizeApplyAffineTransform(naturalSize, transform);
        h->nativeWidth = (int)fabs(transformedSize.width);
        h->nativeHeight = (int)fabs(transformedSize.height);

        if (h->nativeWidth == 0 || h->nativeHeight == 0) {
            spdlog::error("AVFoundationVideoBridge: Invalid video dimensions for {}", filename);
            return h;
        }

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

        CMTime duration = h->asset.duration;
        h->lengthMS = CMTimeGetSeconds(duration) * 1000.0;

        float nominalFrameRate = h->videoTrack.nominalFrameRate;
        if (nominalFrameRate > 0) {
            h->frames = (long)((h->lengthMS / 1000.0) * nominalFrameRate);
            h->frameMS = (int)(1000.0 / nominalFrameRate);
        } else {
            CMTime minFrameDuration = h->videoTrack.minFrameDuration;
            if (CMTIME_IS_VALID(minFrameDuration) && CMTimeGetSeconds(minFrameDuration) > 0) {
                double fps = 1.0 / CMTimeGetSeconds(minFrameDuration);
                h->frames = (long)((h->lengthMS / 1000.0) * fps);
                h->frameMS = (int)(CMTimeGetSeconds(minFrameDuration) * 1000.0);
            } else {
                h->frames = (long)(h->lengthMS / 50.0); // assume 20 fps
                h->frameMS = 50;
            }
        }

        if (h->lengthMS <= 0 || h->frames <= 0) {
            spdlog::warn("AVFoundationVideoBridge: Could not determine video length for {}", filename);
            return h;
        }

        int channels = wantAlpha ? 4 : 3;
        h->frameBufferSize = h->width * h->height * channels;
        h->frameBuffer1 = (uint8_t*)calloc(1, h->frameBufferSize);
        h->frameBuffer2 = (uint8_t*)calloc(1, h->frameBufferSize);

        int stride = h->width * channels;
        h->frameView1 = { h->frameBuffer1, stride, h->width, h->height, h->outputFormat };
        h->frameView2 = { h->frameBuffer2, stride, h->width, h->height, h->outputFormat };

        if (!h->openReader(kCMTimeZero)) {
            return h;
        }

        h->valid = true;

        spdlog::info("AVFoundationVideoBridge: Loaded {}", filename);
        spdlog::info("      Length MS: {}", h->lengthMS);
        spdlog::info("      Source size: {}x{}", h->nativeWidth, h->nativeHeight);
        spdlog::info("      Output size: {}x{}", h->width, h->height);
        spdlog::info("      Frames: {} @ {}fps", h->frames, nominalFrameRate);
        spdlog::info("      Frame ms: {}", h->frameMS);
        if (wantAlpha) spdlog::info("      Alpha: TRUE");

        h->decodeNextFrame();
    }

    return h;
}

void DestroyReader(VideoReaderHandle* h) {
    delete h;
}

bool IsValid(VideoReaderHandle* h) { return h && h->valid && !h->failed; }
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
    if (!h || !h->valid) return false;
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

    // The cached scaled pixel buffer is sized to the old dimensions;
    // ensureScaledPixelBuffer() will lazily reallocate on the next decode.
    if (h->scaledPixelBuffer) {
        CVPixelBufferRelease(h->scaledPixelBuffer);
        h->scaledPixelBuffer = nullptr;
    }

    // Force the next GetNextFrame() to actually decode rather than returning
    // current/prev (whose backing storage is freshly-allocated zeroed buffers).
    h->curPos = -1000;

    return true;
}

void Seek(VideoReaderHandle* h, int timestampMS, bool readFrame) {
    if (!h || !h->valid) return;

    if (timestampMS >= h->lengthMS) {
        h->atEnd = true;
        return;
    }

    h->atEnd = false;

    // AVAssetReader is forward-only; recreate at the new position.
    CMTime seekTime = CMTimeMakeWithSeconds(timestampMS / 1000.0, 600);
    if (!h->openReader(seekTime)) {
        spdlog::error("AVFoundationVideoBridge: Seek to {} failed", timestampMS);
        return;
    }

    h->curPos = -1000;
    if (readFrame) {
        (void)GetNextFrame(h, timestampMS, 0);
    }
}

const FrameView* GetNextFrame(VideoReaderHandle* h, int timestampMS, int gracetime) {
    if (!h || !h->valid || h->frames == 0) {
        return nullptr;
    }

    if (timestampMS > h->lengthMS) {
        h->atEnd = true;
        return nullptr;
    }

    int currenttime = h->curPos;
    int timeOfNextFrame = currenttime + h->frameMS;
    int timeOfPrevFrame = currenttime - h->frameMS;

    if (h->firstFramePos >= timestampMS) {
        timestampMS = h->firstFramePos;
    }

    if (timestampMS >= currenttime && timestampMS < timeOfNextFrame) {
        return &h->currentFrame();
    }
    if (timestampMS >= timeOfPrevFrame - 1 && timestampMS < currenttime) {
        return &h->prevFrame();
    }

    if (currenttime > timestampMS + gracetime || timestampMS - currenttime > 1000) {
        Seek(h, timestampMS, false);
        currenttime = h->curPos;
    }

    if (timestampMS <= h->lengthMS) {
        bool firstframe = (currenttime <= 0 && timestampMS == 0);

        while (firstframe || ((currenttime + (h->frameMS / 2.0)) < timestampMS)) {
            if (!h->decodeNextFrame()) {
                break;
            }
            firstframe = false;
            currenttime = h->curPos;
            if (currenttime > h->lengthMS) break;
        }
    } else {
        h->atEnd = true;
        return nullptr;
    }

    if (h->currentFrame().data == nullptr || currenttime > h->lengthMS) {
        h->atEnd = true;
        return nullptr;
    }

    if (timestampMS >= h->curPos) {
        return &h->currentFrame();
    }
    return &h->prevFrame();
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
