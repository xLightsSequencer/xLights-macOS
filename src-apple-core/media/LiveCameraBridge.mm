/***************************************************************
 * This source files comes from the xLights project
 * https://www.xlights.org
 * https://github.com/xLightsSequencer/xLights
 * See the github commit history for a record of contributing
 * developers.
 * Copyright claimed based on commit dates recorded in Github
 * License: https://github.com/xLightsSequencer/xLights/blob/master/License.txt
 **************************************************************/

#import "LiveCameraBridge.h"

#import <TargetConditionals.h>

// Desktop only. This group IS synchronized into the iPad target (the .o is
// built for iphoneos), so the guard is what keeps the capture stack out of
// an app whose only camera feature is KLightMapper's own scan.
#if !TARGET_OS_IPHONE

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include <mutex>

// Latest-frame store shared between the capture queue (writer) and the
// UI thread (reader). Only ever holds one frame: the consumer polls,
// and an unbounded queue would grow for as long as the dialog is open.
namespace {

struct LatestFrame {
    std::mutex mutex;
    std::vector<uint8_t> rgb;   // packed RGB24, top-down
    int width = 0;
    int height = 0;
    uint64_t generation = 0;
    bool valid = false;
};

} // namespace

// Sample delegate. Converts BGRA -> packed RGB24 on the capture queue so
// the UI thread only ever memcpys.
@interface XLLiveCameraDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic, assign) LatestFrame* store;
@end

@implementation XLLiveCameraDelegate

- (void)captureOutput:(AVCaptureOutput*)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection*)connection {
    LatestFrame* store = self.store;
    if (store == nullptr) return;

    CVImageBufferRef image = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (image == nullptr) return;

    CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
    const uint8_t* src = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(image));
    const size_t stride = CVPixelBufferGetBytesPerRow(image);
    const int w = static_cast<int>(CVPixelBufferGetWidth(image));
    const int h = static_cast<int>(CVPixelBufferGetHeight(image));

    if (src != nullptr && w > 0 && h > 0) {
        std::vector<uint8_t> rgb(static_cast<size_t>(w) * h * 3);
        for (int y = 0; y < h; ++y) {
            const uint8_t* s = src + static_cast<size_t>(y) * stride;
            uint8_t* d = rgb.data() + static_cast<size_t>(y) * w * 3;
            for (int x = 0; x < w; ++x) {
                // kCVPixelFormatType_32BGRA is B,G,R,A in memory order.
                d[0] = s[2];
                d[1] = s[1];
                d[2] = s[0];
                d += 3;
                s += 4;
            }
        }
        std::lock_guard<std::mutex> lk(store->mutex);
        store->rgb.swap(rgb);
        store->width = w;
        store->height = h;
        ++store->generation;
        store->valid = true;
    }
    CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
}

@end

namespace AppleLiveCameraBridge {

struct CaptureHandle {
    AVCaptureSession* session = nil;
    AVCaptureDevice* device = nil;
    AVCaptureVideoDataOutput* output = nil;
    XLLiveCameraDelegate* delegate = nil;
    dispatch_queue_t queue = nullptr;
    LatestFrame frame;

    // Saved so dark mode can be undone; only set on the first override,
    // so a repeated SetDarkMode(true) can't save our own value over the
    // user's original.
    AVCaptureExposureMode savedExposure = AVCaptureExposureModeContinuousAutoExposure;
    AVCaptureWhiteBalanceMode savedWhiteBalance = AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance;
    bool darkApplied = false;
};

namespace {

NSArray<AVCaptureDeviceType>* discoveryTypes() {
    NSMutableArray<AVCaptureDeviceType>* types = [NSMutableArray array];
    [types addObject:AVCaptureDeviceTypeBuiltInWideAngleCamera];
    if (@available(macOS 14.0, *)) {
        // Continuity (an iPhone acting as a webcam) and the modern
        // external/UVC type. Both are 14.0+; older systems fall back to
        // the deprecated externalUnknown below.
        [types addObject:AVCaptureDeviceTypeExternal];
        [types addObject:AVCaptureDeviceTypeContinuityCamera];
    } else {
        // Pre-14 fallback. Deprecated in 14.0 in favour of the type above,
        // which is exactly why it's in the else branch.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [types addObject:AVCaptureDeviceTypeExternalUnknown];
#pragma clang diagnostic pop
    }
    return types;
}

} // namespace

std::vector<DeviceInfo> EnumerateDevices() {
    std::vector<DeviceInfo> out;
    @autoreleasepool {
        AVCaptureDeviceDiscoverySession* discovery =
            [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:discoveryTypes()
                                                                   mediaType:AVMediaTypeVideo
                                                                    position:AVCaptureDevicePositionUnspecified];
        for (AVCaptureDevice* dev in discovery.devices) {
            DeviceInfo info;
            info.name = dev.localizedName.UTF8String ? dev.localizedName.UTF8String : "";
            info.uniqueID = dev.uniqueID.UTF8String ? dev.uniqueID.UTF8String : "";
            if (!info.uniqueID.empty()) out.push_back(std::move(info));
        }
    }
    return out;
}

CaptureHandle* Open(const std::string& uniqueID) {
    @autoreleasepool {
        AVCaptureDevice* device = nil;
        if (!uniqueID.empty()) {
            device = [AVCaptureDevice deviceWithUniqueID:[NSString stringWithUTF8String:uniqueID.c_str()]];
        }
        if (device == nil) {
            AVCaptureDeviceDiscoverySession* discovery =
                [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:discoveryTypes()
                                                                       mediaType:AVMediaTypeVideo
                                                                        position:AVCaptureDevicePositionUnspecified];
            device = discovery.devices.firstObject;
        }
        if (device == nil) return nullptr;

        NSError* error = nil;
        AVCaptureDeviceInput* input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
        if (input == nil) return nullptr;

        AVCaptureSession* session = [[AVCaptureSession alloc] init];
        if (![session canAddInput:input]) return nullptr;
        [session beginConfiguration];
        // 720p keeps the per-frame BGRA->RGB24 conversion and the
        // dialog's blob search cheap enough to run every timer tick;
        // node detection doesn't benefit from more pixels.
        if ([session canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
            session.sessionPreset = AVCaptureSessionPreset1280x720;
        }
        [session addInput:input];

        AVCaptureVideoDataOutput* output = [[AVCaptureVideoDataOutput alloc] init];
        output.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) };
        // Only the newest frame matters — the consumer polls for "what
        // does the camera see now", so a backlog is pure latency.
        output.alwaysDiscardsLateVideoFrames = YES;
        if (![session canAddOutput:output]) {
            [session commitConfiguration];
            return nullptr;
        }
        [session addOutput:output];
        [session commitConfiguration];

        CaptureHandle* h = new CaptureHandle();
        h->session = session;
        h->device = device;
        h->output = output;
        h->queue = dispatch_queue_create("xlights.livecamera", DISPATCH_QUEUE_SERIAL);
        h->delegate = [[XLLiveCameraDelegate alloc] init];
        h->delegate.store = &h->frame;
        [output setSampleBufferDelegate:h->delegate queue:h->queue];

        [session startRunning];
        return h;
    }
}

void Stop(CaptureHandle* h) {
    if (h == nullptr) return;
    @autoreleasepool {
        SetDarkMode(h, false);
        if (h->session != nil && h->session.running) [h->session stopRunning];
        if (h->output != nil) {
            // Drop the delegate before the handle (and the LatestFrame it
            // owns) can go away underneath an in-flight callback.
            [h->output setSampleBufferDelegate:nil queue:nullptr];
        }
        if (h->delegate != nil) h->delegate.store = nullptr;
    }
}

void Destroy(CaptureHandle* h) {
    if (h == nullptr) return;
    Stop(h);
    delete h;
}

bool IsValid(CaptureHandle* h) {
    return h != nullptr && h->session != nil;
}

void SetDarkMode(CaptureHandle* h, bool enabled) {
    if (h == nullptr || h->device == nil) return;
    if (enabled == h->darkApplied) return;
    @autoreleasepool {
        AVCaptureDevice* dev = h->device;
        NSError* error = nil;
        if (![dev lockForConfiguration:&error]) return;

        if (enabled) {
            h->savedExposure = dev.exposureMode;
            h->savedWhiteBalance = dev.whiteBalanceMode;
            if ([dev isExposureModeSupported:AVCaptureExposureModeLocked]) {
                dev.exposureMode = AVCaptureExposureModeLocked;
            }
            if ([dev isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeLocked]) {
                dev.whiteBalanceMode = AVCaptureWhiteBalanceModeLocked;
            }
            h->darkApplied = true;
        } else {
            if ([dev isExposureModeSupported:h->savedExposure]) {
                dev.exposureMode = h->savedExposure;
            }
            if ([dev isWhiteBalanceModeSupported:h->savedWhiteBalance]) {
                dev.whiteBalanceMode = h->savedWhiteBalance;
            }
            h->darkApplied = false;
        }
        [dev unlockForConfiguration];
    }
}

bool TryGetLatestFrame(CaptureHandle* h, std::vector<uint8_t>& outRgb,
                       int& outWidth, int& outHeight, uint64_t& generation) {
    if (h == nullptr) return false;
    std::lock_guard<std::mutex> lk(h->frame.mutex);
    if (!h->frame.valid) return false;
    if (generation != h->frame.generation) {
        outRgb = h->frame.rgb;
        outWidth = h->frame.width;
        outHeight = h->frame.height;
        generation = h->frame.generation;
    }
    return true;
}

} // namespace AppleLiveCameraBridge

#endif // !TARGET_OS_IPHONE
