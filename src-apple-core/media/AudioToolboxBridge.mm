/***************************************************************
 * This source files comes from the xLights project
 * https://www.xlights.org
 * https://github.com/xLightsSequencer/xLights
 * See the github commit history for a record of contributing
 * developers.
 * Copyright claimed based on commit dates recorded in Github
 * License: https://github.com/xLightsSequencer/xLights/blob/master/License.txt
 **************************************************************/

// AVFoundation + AudioToolbox decode/encode that backs
// `src-core/media/AudioToolboxDecoder.cpp`. Pure C++ ABI in/out so
// this file owns every Apple SDK dependency and src-core stays
// Apple-framework-free. FFmpeg fallback is intentionally not here —
// see `AudioToolboxDecoder.cpp` for that policy.

#include "AudioToolboxBridge.h"

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>

#include <log.h>

#define PCMFUDGE 32768

namespace {

CFURLRef CreateCFURL(const std::string& path) {
    CFStringRef cfPath = CFStringCreateWithCString(kCFAllocatorDefault, path.c_str(), kCFStringEncodingUTF8);
    CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, cfPath, kCFURLPOSIXPathStyle, false);
    CFRelease(cfPath);
    return url;
}

bool DecodeWithAVAssetReader(const std::string& path,
                              long targetRate,
                              int extra,
                              AppleAudioToolboxBridge::DecodedInfo& info,
                              uint8_t*& pcmData, long& pcmDataSize,
                              float*& leftData, float*& rightData,
                              long& trackSize,
                              std::function<void(int pct)> progress) {
    @autoreleasepool {
        NSURL* nsURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
        AVAsset* asset = [AVAsset assetWithURL:nsURL];

        // Synchronous track access avoids priority-inversion warnings on the main thread
        // that the async load + semaphore pattern would trigger.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSArray<AVAssetTrack*>* audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
#pragma clang diagnostic pop
        if (audioTracks.count == 0) {
            spdlog::error("AudioToolboxBridge: No audio track in {}", path);
            return false;
        }

        AVAssetTrack* audioTrack = audioTracks[0];
        CMTime duration = asset.duration;
        double durationSec = CMTimeGetSeconds(duration);
        info.lengthMS = (long)(durationSec * 1000.0);

        NSArray* formatDescriptions = audioTrack.formatDescriptions;
        if (formatDescriptions.count > 0) {
            CMAudioFormatDescriptionRef desc = (__bridge CMAudioFormatDescriptionRef)formatDescriptions[0];
            const AudioStreamBasicDescription* asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc);
            if (asbd) {
                info.sampleRate = (long)asbd->mSampleRate;
                info.channels = asbd->mChannelsPerFrame;
                info.bitsPerSample = asbd->mBitsPerChannel / 8;
            }
        }
        if (info.sampleRate == 0) info.sampleRate = 44100;
        if (info.channels == 0) info.channels = 2;

        if (targetRate <= 0) targetRate = info.sampleRate;

        NSDictionary* outputSettings = @{
            AVFormatIDKey: @(kAudioFormatLinearPCM),
            AVSampleRateKey: @((double)targetRate),
            AVNumberOfChannelsKey: @2,
            AVLinearPCMBitDepthKey: @16,
            AVLinearPCMIsFloatKey: @NO,
            AVLinearPCMIsBigEndianKey: @NO,
            AVLinearPCMIsNonInterleaved: @NO
        };

        NSError* error = nil;
        AVAssetReader* reader = [[[AVAssetReader alloc] initWithAsset:asset error:&error] autorelease];
        if (error || !reader) {
            spdlog::error("AudioToolboxBridge: AVAssetReader failed: {}", error ? error.localizedDescription.UTF8String : "unknown");
            return false;
        }

        AVAssetReaderTrackOutput* output = [[[AVAssetReaderTrackOutput alloc] initWithTrack:audioTrack outputSettings:outputSettings] autorelease];
        [reader addOutput:output];

        if (![reader startReading]) {
            spdlog::error("AudioToolboxBridge: AVAssetReader startReading failed");
            return false;
        }

        trackSize = (long)(durationSec * targetRate);
        info.trackSize = trackSize;

        int outChannels = 2;
        long allocExtra = extra + 2048;
        long floatBufSize = sizeof(float) * (trackSize + allocExtra);
        leftData = (float*)calloc(floatBufSize, 1);
        if (!leftData) return false;

        if (info.channels >= 2) {
            rightData = (float*)calloc(floatBufSize, 1);
            if (!rightData) { free(leftData); leftData = nullptr; return false; }
        } else {
            rightData = leftData;
        }

        pcmDataSize = trackSize * outChannels * 2;
        pcmData = (uint8_t*)calloc(pcmDataSize + PCMFUDGE, 1);
        if (!pcmData) {
            if (rightData != leftData) free(rightData);
            free(leftData); leftData = nullptr; rightData = nullptr;
            pcmDataSize = 0;
            return false;
        }

        long read = 0;
        int lastpct = 0;
        UInt32 bytesPerFrame = outChannels * sizeof(int16_t);

        CMSampleBufferRef sampleBuffer;
        while ((sampleBuffer = [output copyNextSampleBuffer]) != NULL) {
            CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
            size_t length = 0;
            char* dataPtr = nullptr;
            CMBlockBufferGetDataPointer(blockBuffer, 0, nullptr, &length, &dataPtr);

            long framesRead = length / bytesPerFrame;

            if (read + framesRead > trackSize + allocExtra) {
                long newTrackSize = read + framesRead + 8192;
                long newFloatBufSize = sizeof(float) * (newTrackSize + allocExtra);
                leftData = (float*)realloc(leftData, newFloatBufSize);
                if (rightData != leftData) {
                    rightData = (float*)realloc(rightData, newFloatBufSize);
                }
                long newPcmSize = newTrackSize * outChannels * 2;
                pcmData = (uint8_t*)realloc(pcmData, newPcmSize + PCMFUDGE);
                trackSize = newTrackSize;
            }

            memcpy(pcmData + (read * bytesPerFrame), dataPtr, length);

            int16_t* src = (int16_t*)dataPtr;
            for (long i = 0; i < framesRead; i++) {
                leftData[read + i] = (float)src[i * outChannels] / 32768.0f;
                if (info.channels > 1) {
                    rightData[read + i] = (float)src[i * outChannels + 1] / 32768.0f;
                }
            }

            read += framesRead;
            CFRelease(sampleBuffer);

            if (progress && trackSize > 0) {
                int pct = (int)(read * 100 / trackSize);
                if (pct >= lastpct + 10) {
                    lastpct = pct / 10 * 10;
                    progress(lastpct);
                }
            }
        }

        trackSize = read;
        info.trackSize = trackSize;
        pcmDataSize = read * outChannels * 2;

        for (AVMetadataItem* item in asset.commonMetadata) {
            if ([item.commonKey isEqualToString:AVMetadataCommonKeyTitle]) {
                NSString* val = (NSString*)item.value;
                if ([val isKindOfClass:[NSString class]]) info.title = val.UTF8String;
            } else if ([item.commonKey isEqualToString:AVMetadataCommonKeyArtist]) {
                NSString* val = (NSString*)item.value;
                if ([val isKindOfClass:[NSString class]]) info.artist = val.UTF8String;
            } else if ([item.commonKey isEqualToString:AVMetadataCommonKeyAlbumName]) {
                NSString* val = (NSString*)item.value;
                if ([val isKindOfClass:[NSString class]]) info.album = val.UTF8String;
            }
        }

        spdlog::debug("AudioToolboxBridge: Decoded {} samples from {} via AVAssetReader", read, path);
        return true;
    }
}

} // namespace

namespace AppleAudioToolboxBridge {

bool DecodeFile(const std::string& path,
                long targetRate,
                int extra,
                DecodedInfo& info,
                uint8_t*& pcmData, long& pcmDataSize,
                float*& leftData, float*& rightData,
                long& trackSize,
                std::function<void(int pct)> progress) {
    pcmData = nullptr;
    pcmDataSize = 0;
    leftData = nullptr;
    rightData = nullptr;
    trackSize = 0;

    CFURLRef fileURL = CreateCFURL(path);
    if (!fileURL) {
        spdlog::error("AudioToolboxBridge: Invalid path {}", path);
        return false;
    }

    ExtAudioFileRef audioFile = nullptr;
    OSStatus status = ExtAudioFileOpenURL(fileURL, &audioFile);
    CFRelease(fileURL);
    if (status != noErr || !audioFile) {
        // ExtAudioFile can't open this file — try AVAssetReader for video containers
        // (MP4, MOV, etc.). FFmpeg fallback (when needed) lives in src-core.
        spdlog::debug("AudioToolboxBridge: ExtAudioFile can't open {}, trying AVAssetReader", path);
        return DecodeWithAVAssetReader(path, targetRate, extra, info,
                                        pcmData, pcmDataSize,
                                        leftData, rightData, trackSize, progress);
    }

    AudioStreamBasicDescription srcFormat;
    UInt32 propSize = sizeof(srcFormat);
    status = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileDataFormat, &propSize, &srcFormat);
    if (status != noErr) {
        spdlog::error("AudioToolboxBridge: Can't get file format (status {})", (int)status);
        ExtAudioFileDispose(audioFile);
        return false;
    }

    info.sampleRate = (long)srcFormat.mSampleRate;
    info.channels = srcFormat.mChannelsPerFrame;
    info.bitsPerSample = srcFormat.mBitsPerChannel / 8;

    SInt64 totalFrames = 0;
    propSize = sizeof(totalFrames);
    status = ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_FileLengthFrames, &propSize, &totalFrames);
    if (status != noErr) {
        spdlog::error("AudioToolboxBridge: Can't get file length (status {})", (int)status);
        ExtAudioFileDispose(audioFile);
        return false;
    }

    AudioFileID audioFileID = nullptr;
    propSize = sizeof(audioFileID);
    ExtAudioFileGetProperty(audioFile, kExtAudioFileProperty_AudioFile, &propSize, &audioFileID);
    if (audioFileID) {
        UInt32 bitRate = 0;
        propSize = sizeof(bitRate);
        if (AudioFileGetProperty(audioFileID, kAudioFilePropertyBitRate, &propSize, &bitRate) == noErr) {
            info.bitRate = bitRate;
        }
    }

    double lengthInSeconds = (double)totalFrames / srcFormat.mSampleRate;
    info.lengthMS = (long)floor(lengthInSeconds * 1000.0);

    if (targetRate <= 0) {
        targetRate = (long)srcFormat.mSampleRate;
    }

    trackSize = (long)((double)totalFrames * targetRate / srcFormat.mSampleRate);
    info.trackSize = trackSize;

    // ExtAudioFile resamples internally when ClientDataFormat differs.
    AudioStreamBasicDescription clientFormat = {};
    clientFormat.mSampleRate = targetRate;
    clientFormat.mFormatID = kAudioFormatLinearPCM;
    clientFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    clientFormat.mBitsPerChannel = 16;
    clientFormat.mChannelsPerFrame = 2;
    clientFormat.mFramesPerPacket = 1;
    clientFormat.mBytesPerFrame = clientFormat.mChannelsPerFrame * (clientFormat.mBitsPerChannel / 8);
    clientFormat.mBytesPerPacket = clientFormat.mBytesPerFrame;

    status = ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientDataFormat,
                                      sizeof(clientFormat), &clientFormat);
    if (status != noErr) {
        spdlog::error("AudioToolboxBridge: Can't set client format (status {})", (int)status);
        ExtAudioFileDispose(audioFile);
        return false;
    }

    int outChannels = 2;
    long allocExtra = extra + 2048;
    long floatBufSize = sizeof(float) * (trackSize + allocExtra);
    leftData = (float*)calloc(floatBufSize, 1);
    if (!leftData) {
        ExtAudioFileDispose(audioFile);
        spdlog::error("AudioToolboxBridge: Can't allocate left buffer");
        return false;
    }

    if (info.channels >= 2) {
        rightData = (float*)calloc(floatBufSize, 1);
        if (!rightData) {
            free(leftData); leftData = nullptr;
            ExtAudioFileDispose(audioFile);
            spdlog::error("AudioToolboxBridge: Can't allocate right buffer");
            return false;
        }
    } else {
        rightData = leftData;
    }

    pcmDataSize = trackSize * outChannels * 2;
    pcmData = (uint8_t*)calloc(pcmDataSize + PCMFUDGE, 1);
    if (!pcmData) {
        if (rightData != leftData) free(rightData);
        free(leftData); leftData = nullptr; rightData = nullptr;
        pcmDataSize = 0;
        ExtAudioFileDispose(audioFile);
        spdlog::error("AudioToolboxBridge: Can't allocate PCM buffer");
        return false;
    }

    const UInt32 chunkFrames = 8192;
    UInt32 bytesPerFrame = outChannels * sizeof(int16_t);
    auto* readBuffer = (int16_t*)malloc(chunkFrames * bytesPerFrame);
    long read = 0;
    int lastpct = 0;

    while (true) {
        AudioBufferList bufList;
        bufList.mNumberBuffers = 1;
        bufList.mBuffers[0].mNumberChannels = outChannels;
        bufList.mBuffers[0].mDataByteSize = chunkFrames * bytesPerFrame;
        bufList.mBuffers[0].mData = readBuffer;

        UInt32 framesRead = chunkFrames;
        status = ExtAudioFileRead(audioFile, &framesRead, &bufList);
        if (status != noErr) {
            spdlog::error("AudioToolboxBridge: ExtAudioFileRead failed (status {})", (int)status);
            break;
        }
        if (framesRead == 0) break;

        if (read + (long)framesRead > trackSize) {
            allocExtra -= (read + framesRead - trackSize);
            trackSize = read + framesRead;
        }

        long bytesToCopy = framesRead * bytesPerFrame;
        memcpy(pcmData + (read * bytesPerFrame), readBuffer, bytesToCopy);

        for (UInt32 i = 0; i < framesRead; i++) {
            leftData[read + i] = (float)readBuffer[i * outChannels] / 32768.0f;
            if (info.channels > 1) {
                rightData[read + i] = (float)readBuffer[i * outChannels + 1] / 32768.0f;
            }
        }

        read += framesRead;

        if (progress && trackSize > 0) {
            int pct = (int)(read * 100 / trackSize);
            if (pct >= lastpct + 10) {
                lastpct = pct / 10 * 10;
                progress(lastpct);
            }
        }
    }

    free(readBuffer);
    ExtAudioFileDispose(audioFile);

    trackSize = read;
    info.trackSize = trackSize;
    pcmDataSize = read * outChannels * 2;

    @autoreleasepool {
        NSURL* nsURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
        AVAsset* asset = [AVAsset assetWithURL:nsURL];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (AVMetadataItem* item in asset.commonMetadata) {
#pragma clang diagnostic pop
            if ([item.commonKey isEqualToString:AVMetadataCommonKeyTitle]) {
                NSString* val = (NSString*)item.value;
                if ([val isKindOfClass:[NSString class]]) info.title = val.UTF8String;
            } else if ([item.commonKey isEqualToString:AVMetadataCommonKeyArtist]) {
                NSString* val = (NSString*)item.value;
                if ([val isKindOfClass:[NSString class]]) info.artist = val.UTF8String;
            } else if ([item.commonKey isEqualToString:AVMetadataCommonKeyAlbumName]) {
                NSString* val = (NSString*)item.value;
                if ([val isKindOfClass:[NSString class]]) info.album = val.UTF8String;
            }
        }
    }

    spdlog::debug("AudioToolboxBridge: Decoded {} samples from {}", read, path);
    return true;
}

bool EncodeToFile(const std::vector<float>& left,
                   const std::vector<float>& right,
                   size_t sampleRate,
                   const std::string& filename) {
    if (left.size() != right.size()) {
        spdlog::error("AudioToolboxBridge: Left and right channel sizes don't match");
        return false;
    }

    spdlog::debug("AudioToolboxBridge: Encoding {} samples to {} at rate {}", left.size(), filename, sampleRate);

    AudioFileTypeID fileType = kAudioFileMP3Type;
    AudioFormatID formatID = kAudioFormatMPEGLayer3;

    bool isM4A = filename.size() >= 4 && filename.substr(filename.size() - 3) == "m4a";
    bool isWAV = filename.size() >= 4 && filename.substr(filename.size() - 3) == "wav";

    if (isM4A) {
        fileType = kAudioFileM4AType;
        formatID = kAudioFormatMPEG4AAC;
    } else if (isWAV) {
        fileType = kAudioFileWAVEType;
        formatID = kAudioFormatLinearPCM;
    }

    AudioStreamBasicDescription srcFormat = {};
    srcFormat.mSampleRate = sampleRate;
    srcFormat.mFormatID = kAudioFormatLinearPCM;
    srcFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    srcFormat.mBitsPerChannel = 16;
    srcFormat.mChannelsPerFrame = 2;
    srcFormat.mFramesPerPacket = 1;
    srcFormat.mBytesPerFrame = 4;
    srcFormat.mBytesPerPacket = 4;

    AudioStreamBasicDescription dstFormat = {};
    dstFormat.mSampleRate = sampleRate;
    dstFormat.mFormatID = formatID;
    dstFormat.mChannelsPerFrame = 2;

    if (formatID == kAudioFormatLinearPCM) {
        dstFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        dstFormat.mBitsPerChannel = 16;
        dstFormat.mFramesPerPacket = 1;
        dstFormat.mBytesPerFrame = 4;
        dstFormat.mBytesPerPacket = 4;
    }

    CFURLRef fileURL = CreateCFURL(filename);
    if (!fileURL) {
        spdlog::error("AudioToolboxBridge: Invalid output path {}", filename);
        return false;
    }

    ExtAudioFileRef outFile = nullptr;
    OSStatus status = ExtAudioFileCreateWithURL(fileURL, fileType, &dstFormat, nullptr,
                                                 kAudioFileFlags_EraseFile, &outFile);
    CFRelease(fileURL);
    if (status != noErr || !outFile) {
        spdlog::error("AudioToolboxBridge: Can't create output file (status {})", (int)status);
        return false;
    }

    status = ExtAudioFileSetProperty(outFile, kExtAudioFileProperty_ClientDataFormat,
                                      sizeof(srcFormat), &srcFormat);
    if (status != noErr) {
        spdlog::error("AudioToolboxBridge: Can't set client format for encoding (status {})", (int)status);
        ExtAudioFileDispose(outFile);
        return false;
    }

    const UInt32 chunkFrames = 8192;
    size_t totalSamples = left.size();
    auto* writeBuf = (int16_t*)malloc(chunkFrames * 4);
    size_t pos = 0;

    while (pos < totalSamples) {
        UInt32 toWrite = (UInt32)std::min((size_t)chunkFrames, totalSamples - pos);

        for (UInt32 i = 0; i < toWrite; i++) {
            float l = std::max(-1.0f, std::min(1.0f, left[pos + i]));
            float r = std::max(-1.0f, std::min(1.0f, right[pos + i]));
            writeBuf[i * 2] = (int16_t)(l * 32767.0f);
            writeBuf[i * 2 + 1] = (int16_t)(r * 32767.0f);
        }

        AudioBufferList bufList;
        bufList.mNumberBuffers = 1;
        bufList.mBuffers[0].mNumberChannels = 2;
        bufList.mBuffers[0].mDataByteSize = toWrite * 4;
        bufList.mBuffers[0].mData = writeBuf;

        status = ExtAudioFileWrite(outFile, toWrite, &bufList);
        if (status != noErr) {
            spdlog::error("AudioToolboxBridge: ExtAudioFileWrite failed (status {})", (int)status);
            free(writeBuf);
            ExtAudioFileDispose(outFile);
            return false;
        }

        pos += toWrite;
    }

    free(writeBuf);
    ExtAudioFileDispose(outFile);

    spdlog::debug("AudioToolboxBridge: Encoded {} samples to {}", totalSamples, filename);
    return true;
}

size_t GetAudioFileLength(const std::string& filename) {
    CFURLRef fileURL = CreateCFURL(filename);
    if (!fileURL) return 0;

    AudioFileID audioFile = nullptr;
    OSStatus status = AudioFileOpenURL(fileURL, kAudioFileReadPermission, 0, &audioFile);
    CFRelease(fileURL);
    if (status != noErr || !audioFile) return 0;

    UInt64 dataSize = 0;
    UInt32 propSize = sizeof(dataSize);
    status = AudioFileGetProperty(audioFile, kAudioFilePropertyAudioDataByteCount, &propSize, &dataSize);
    AudioFileClose(audioFile);

    if (status != noErr) return 0;
    return (size_t)dataSize;
}

} // namespace AppleAudioToolboxBridge
