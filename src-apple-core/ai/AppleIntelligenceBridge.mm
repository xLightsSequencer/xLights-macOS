/***************************************************************
 * This source files comes from the xLights project
 * https://www.xlights.org
 * https://github.com/xLightsSequencer/xLights
 * See the github commit history for a record of contributing
 * developers.
 * Copyright claimed based on commit dates recorded in Github
 * License: https://github.com/xLightsSequencer/xLights/blob/master/License.txt
 **************************************************************/

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "AppleIntelligenceBridge.h"
#include "xLights_Apple_core-Swift.h"

namespace {

// Encode a CGImage to an in-memory PNG byte buffer. Returns empty on
// failure. ImageIO is the cleanest path that doesn't pull in UIImage
// (iOS) or NSImage (macOS), so the bridge stays platform-neutral.
//
// The @available gate is for the desktop's macOS 10.15 deployment
// floor — UTTypePNG (and its `identifier` accessor) come from the
// UniformTypeIdentifiers framework introduced in macOS 11. The
// caller chain only reaches this on a path that already requires
// macOS 15.4+ (ImagePlayground.ImageCreator), so the runtime check
// always succeeds in practice; it's there to satisfy the static
// availability checker.
std::vector<uint8_t> CGImageToPNGBytes(CGImageRef image) {
    std::vector<uint8_t> bytes;
    if (!image) return bytes;
    if (@available(macOS 11.0, iOS 14.0, *)) {
        CFMutableDataRef data = CFDataCreateMutable(nullptr, 0);
        if (!data) return bytes;

        CGImageDestinationRef dest = CGImageDestinationCreateWithData(
            data, (__bridge CFStringRef)UTTypePNG.identifier, 1, nullptr);
        if (!dest) {
            CFRelease(data);
            return bytes;
        }
        CGImageDestinationAddImage(dest, image, nullptr);
        if (CGImageDestinationFinalize(dest)) {
            const uint8_t* p = CFDataGetBytePtr(data);
            CFIndex len = CFDataGetLength(data);
            bytes.assign(p, p + len);
        }
        CFRelease(dest);
        CFRelease(data);
    }
    return bytes;
}

} // namespace

namespace AppleAIBridge {

std::string CallLLM(const std::string& prompt) {
    return xLights_Apple_core::RunAppleIntelligencePrompt(prompt);
}

std::string GenerateColorPaletteJSON(const std::string& prompt) {
    return xLights_Apple_core::RunAppleIntelligenceGeneratePalette(prompt);
}

void GenerateLyricTrack(const std::string& audioPath,
                        std::function<void(LyricResult)> callback) {
    if (audioPath.empty()) {
        if (callback) {
            LyricResult r;
            r.error = "Audio path is empty";
            callback(std::move(r));
        }
        return;
    }

    NSString* path = @(audioPath.c_str());

    // Locale is hard-coded en-US for now. Future: thread the user's
    // preferred sequence-locale through here. SFSpeech supports a
    // dozen-plus locales but each ships its own on-device model.
    [AppleSpeechRecognizer recognizeAudioFileAtPath:path
                                    localeIdentifier:@"en-US"
                                          completion:^(NSArray<NSString*>* words,
                                                       NSArray<NSNumber*>* starts,
                                                       NSArray<NSNumber*>* ends,
                                                       NSString* err) {
        LyricResult r;
        if (err.length > 0) {
            r.error = std::string([err UTF8String]);
        } else {
            const NSUInteger n = words.count;
            r.lyrics.reserve(n);
            for (NSUInteger i = 0; i < n; ++i) {
                LyricSegment seg;
                seg.word    = std::string([words[i] UTF8String] ?: "");
                seg.startMS = i < starts.count ? [starts[i] intValue] : 0;
                seg.endMS   = i < ends.count   ? [ends[i]   intValue] : 0;
                r.lyrics.push_back(std::move(seg));
            }
        }
        if (callback) callback(std::move(r));
    }];
}

void GenerateImage(const std::string& prompt,
                   const std::string& fullInstructions,
                   const std::string& style,
                   std::function<void(ImageResult)> callback) {
    NSString* p     = @(prompt.c_str());
    NSString* full  = @(fullInstructions.c_str());
    NSString* sty   = @(style.c_str());
    ImagesAsyncCaller* caller = [[ImagesAsyncCaller alloc] init];

    [caller generateImagesWithPrompt:p
                     fullInstructions:full
                                style:sty
                    completionHandler:^(CGImage* result, NSString* errString) {
        ImageResult r;
        std::string err = errString ? std::string([errString UTF8String]) : std::string();
        if (!err.empty()) {
            r.error = err;
        } else {
            r.png = CGImageToPNGBytes(result);
            if (r.png.empty()) {
                r.error = "Failed to encode generated image to PNG";
            }
        }
        if (callback) callback(std::move(r));
    }];
}

} // namespace AppleAIBridge
