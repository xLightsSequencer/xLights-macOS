/***************************************************************
 * This source files comes from the xLights project
 * https://www.xlights.org
 * https://github.com/xLightsSequencer/xLights
 * See the github commit history for a record of contributing
 * developers.
 * Copyright claimed based on commit dates recorded in Github
 * License: https://github.com/xLightsSequencer/xLights/blob/master/License.txt
 **************************************************************/

// AVFoundation + AudioToolbox probes that back
// `src-core/media/MediaCompatibility.cpp`'s Apple branch. Pure C++ ABI
// (std::string in / std::string out) so this file owns every Apple
// SDK dependency and src-core stays Apple-framework-free.

#include "MediaCompatibilityBridge.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMedia/CoreMedia.h>

#include <string>

namespace {
// AVFoundation's QuickTime decoder accepts rawvideo MOV (codec_tag='raw ')
// but only decodes it when the row stride is a multiple of 8 bytes — for
// rgb24 that means the width must be a multiple of 8. Otherwise
// AVAssetReader silently produces zero samples (no error). Detect this so
// MediaCompatibility::CheckVideoFile can flag the file for re-encoding
// instead of letting the user think the file is fine until playback.
bool IsRawvideoUnalignedStride(AVAssetTrack* track) {
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
    // Assume rgb24 (3 bpp); xLights only ever produced rawvideo MOV in this
    // layout. Other rawvideo flavors aren't handled here.
    return (dims.width * 3) % 8 != 0;
}
} // namespace

namespace AppleMediaCompatibility {

std::string CheckVideoFile(const std::string& filePath) {
    if (filePath.empty()) return "";

    @autoreleasepool {
        NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:filePath.c_str()]];
        AVURLAsset* asset = [AVURLAsset URLAssetWithURL:url options:nil];
        if (!asset) {
            return "Cannot open file";
        }

        if (!asset.playable) {
            return "File format not supported";
        }

        // tracksWithMediaType: deprecated in macOS 15 but replacement requires macOS 15+
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSArray<AVAssetTrack*>* videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
#pragma clang diagnostic pop
        if (videoTracks.count == 0) {
            return "No video tracks found";
        }

        if (IsRawvideoUnalignedStride(videoTracks[0])) {
            return "rawvideo .mov with row stride not a multiple of 8 — AVFoundation cannot decode";
        }

        NSError* error = nil;
        AVAssetReader* reader = [[[AVAssetReader alloc] initWithAsset:asset error:&error] autorelease];
        if (!reader || error) {
            return std::string("Cannot create decoder: ") +
                   (error ? [[error localizedDescription] UTF8String] : "unknown error");
        }

        NSDictionary* outputSettings = @{
            (NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
        };
        AVAssetReaderTrackOutput* output =
            [[[AVAssetReaderTrackOutput alloc] initWithTrack:videoTracks[0]
                                            outputSettings:outputSettings] autorelease];

        if (![reader canAddOutput:output]) {
            return "Video codec not supported for decoding";
        }

        [reader addOutput:output];

        if (![reader startReading]) {
            return std::string("Cannot start decoding: ") +
                   (reader.error ? [[reader.error localizedDescription] UTF8String] : "unknown");
        }

        @try {
            CMSampleBufferRef sample = [output copyNextSampleBuffer];
            if (sample) {
                CFRelease(sample);
            } else {
                // No sample on the first call after startReading is the
                // signature of AVFoundation's silent-fail decode (e.g. the
                // explicit rawvideo-unaligned-stride case is caught earlier,
                // but other edge cases land here). Surface as a decode
                // failure so the file gets routed through the conversion
                // dialog instead of looking fine until playback.
                if (reader.status == AVAssetReaderStatusFailed) {
                    return std::string("Decode failed: ") +
                           (reader.error ? [[reader.error localizedDescription] UTF8String] : "unknown");
                }
                return "Decoder produced no frames (file may be unreadable on this platform)";
            }
        } @catch (NSException* e) {
            return std::string("Decode error: ") + [[e reason] UTF8String];
        }

        [reader cancelReading];
    }
    return "";
}

std::string CheckAudioFile(const std::string& filePath) {
    if (filePath.empty()) return "";

    @autoreleasepool {
        NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:filePath.c_str()]];
        CFURLRef cfUrl = (__bridge CFURLRef)url;

        ExtAudioFileRef audioFile = nullptr;
        OSStatus status = ExtAudioFileOpenURL(cfUrl, &audioFile);
        if (status != noErr || !audioFile) {
            switch (status) {
                case kAudioFileUnsupportedFileTypeError:
                    return "Audio file format not supported by AudioToolbox";
                case kAudioFileUnsupportedDataFormatError:
                    return "Audio codec not supported by AudioToolbox";
                case kAudioFileFileNotFoundError:
                    return "Audio file not found";
                case kAudioFilePermissionsError:
                    return "Permission denied reading audio file";
                default:
                    return "Cannot open audio file (error " + std::to_string((int)status) + ")";
            }
        }

        // Confirm the codec actually decodes to PCM, not just that the container opened.
        AudioStreamBasicDescription clientFormat = {};
        clientFormat.mSampleRate = 44100;
        clientFormat.mFormatID = kAudioFormatLinearPCM;
        clientFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        clientFormat.mBitsPerChannel = 16;
        clientFormat.mChannelsPerFrame = 2;
        clientFormat.mFramesPerPacket = 1;
        clientFormat.mBytesPerFrame = 4;
        clientFormat.mBytesPerPacket = 4;

        status = ExtAudioFileSetProperty(audioFile,
                                          kExtAudioFileProperty_ClientDataFormat,
                                          sizeof(clientFormat),
                                          &clientFormat);
        ExtAudioFileDispose(audioFile);

        if (status != noErr) {
            return "Audio codec cannot be decoded to PCM by AudioToolbox (error " +
                   std::to_string((int)status) + ")";
        }
    }
    return "";
}

} // namespace AppleMediaCompatibility
