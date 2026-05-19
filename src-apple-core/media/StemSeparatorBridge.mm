/***************************************************************
 * This source files comes from the xLights project
 * https://www.xlights.org
 * https://github.com/xLightsSequencer/xLights
 * See the github commit history for a record of contributing
 * developers.
 * Copyright claimed based on commit dates recorded in Github
 * License: https://github.com/xLightsSequencer/xLights/blob/master/License.txt
 **************************************************************/

// CoreML HTDemucs model loader + per-chunk inference. Caller (in
// `src-core/media/StemSeparator.cpp`) owns the chunk loop, STFT scratch
// buffers, and crossfade — those are shared with the OpenVINO / ONNX
// backends and don't need to know about Apple frameworks.

#include "StemSeparatorBridge.h"

#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>

#include <cstring>

namespace AppleStemSeparatorBridge {

struct ModelHandle {
    MLModel* model = nil;
};

ModelHandle* LoadModel(const std::string& modelPath) {
    if (modelPath.empty()) return nullptr;

    // HTDemucs uses Float16 MLMultiArray I/O — requires macOS 12 / iOS 15.
    if (@available(macOS 12.0, iOS 15.0, *)) {
        // ok
    } else {
        NSLog(@"StemSeparatorBridge: requires macOS 12 / iOS 15 or newer");
        return nullptr;
    }

    auto* h = new ModelHandle();
    @autoreleasepool {
        NSString* path = [NSString stringWithUTF8String:modelPath.c_str()];
        NSURL* url = [NSURL fileURLWithPath:path];
        NSError* err = nil;

        // `compileModelAtURL` caches the compiled artifact alongside the
        // app sandbox.
        NSURL* compiledURL = nil;
        if ([path hasSuffix:@".mlmodelc"]) {
            compiledURL = url;
        } else {
            compiledURL = [MLModel compileModelAtURL:url error:&err];
            if (!compiledURL || err) {
                NSLog(@"StemSeparatorBridge: compile failed: %@", err);
                delete h;
                return nullptr;
            }
        }
        MLModelConfiguration* cfg = [[[MLModelConfiguration alloc] init] autorelease];
        cfg.computeUnits = MLComputeUnitsAll;
        h->model = [[MLModel modelWithContentsOfURL:compiledURL
                                      configuration:cfg
                                              error:&err] retain];
        if (!h->model || err) {
            NSLog(@"StemSeparatorBridge: model load failed: %@", err);
            delete h;
            return nullptr;
        }
    }
    return h;
}

void DestroyModel(ModelHandle* m) {
    if (!m) return;
    [m->model release];
    m->model = nil;
    delete m;
}

bool RunChunk(ModelHandle* m,
              const float* waveform, long waveformSize,
              const float* spectral, long spectralSize,
              float* timeOutput, long timeOutputSize) {
    if (!m || !m->model || !waveform || !spectral || !timeOutput) return false;
    if (waveformSize <= 0 || spectralSize <= 0 || timeOutputSize <= 0) return false;

    // Bake-in shape constants must match the model's converted I/O.
    // Caller's waveform is [2, chunkFrames]; spectral is [4, 2048, 336].
    constexpr long kSpectralChannels = 4;
    constexpr long kSpectralBins = 2048;
    constexpr long kSpectralFrames = 336;
    constexpr long kSpectralExpected = kSpectralChannels * kSpectralBins * kSpectralFrames;
    constexpr long kWaveformChannels = 2;
    constexpr long kOutputChannels = 8;

    if (spectralSize != kSpectralExpected) {
        NSLog(@"StemSeparatorBridge: spectral size %ld != expected %ld",
              spectralSize, kSpectralExpected);
        return false;
    }
    if (waveformSize % kWaveformChannels != 0) {
        NSLog(@"StemSeparatorBridge: waveform size %ld not divisible by %ld",
              waveformSize, kWaveformChannels);
        return false;
    }
    long chunkFrames = waveformSize / kWaveformChannels;
    if (timeOutputSize < kOutputChannels * chunkFrames) {
        NSLog(@"StemSeparatorBridge: timeOutput size %ld too small for %ld frames",
              timeOutputSize, chunkFrames);
        return false;
    }

    @autoreleasepool {
        NSError* err = nil;

        MLMultiArray* waveformArr = nil;
        MLMultiArray* spectralArr = nil;
        if (@available(macOS 12.0, iOS 15.0, *)) {
            waveformArr = [[[MLMultiArray alloc]
                initWithShape:@[@1, @(kWaveformChannels), @(chunkFrames)]
                     dataType:MLMultiArrayDataTypeFloat16
                        error:&err] autorelease];
            if (!waveformArr || err) {
                NSLog(@"StemSeparatorBridge: waveform alloc failed: %@", err);
                return false;
            }
            spectralArr = [[[MLMultiArray alloc]
                initWithShape:@[@1, @(kSpectralChannels), @(kSpectralBins), @(kSpectralFrames)]
                     dataType:MLMultiArrayDataTypeFloat16
                        error:&err] autorelease];
            if (!spectralArr || err) {
                NSLog(@"StemSeparatorBridge: spectral alloc failed: %@", err);
                return false;
            }
        } else {
            return false;  // already gated in LoadModel
        }

        // Float32 → Float16 input copy.
        __fp16* wfData = (__fp16*)waveformArr.dataPointer;
        for (long i = 0; i < waveformSize; i++) {
            wfData[i] = (__fp16)waveform[i];
        }
        __fp16* spData = (__fp16*)spectralArr.dataPointer;
        for (long i = 0; i < spectralSize; i++) {
            spData[i] = (__fp16)spectral[i];
        }

        MLDictionaryFeatureProvider* input =
            [[[MLDictionaryFeatureProvider alloc]
                initWithDictionary:@{@"audio_waveform": waveformArr,
                                     @"spectral_magnitude": spectralArr}
                              error:&err] autorelease];
        if (!input || err) {
            NSLog(@"StemSeparatorBridge: input provider failed: %@", err);
            return false;
        }

        // CoreML can raise an NSException from internal Metal/MPS layers on
        // specific input shapes or compute-unit fallback failures (the public
        // `error:` parameter doesn't always catch them). Letting it unwind
        // through C++ frames hits std::terminate — see crash report from
        // 2026.08 where this thread aborted at this exact call site.
        id<MLFeatureProvider> output = nil;
        @try {
            output = [m->model predictionFromFeatures:input error:&err];
        } @catch (NSException* e) {
            NSLog(@"StemSeparatorBridge: prediction raised %@: %@", e.name, e.reason);
            return false;
        }
        if (!output || err) {
            NSLog(@"StemSeparatorBridge: inference failed: %@", err);
            return false;
        }

        MLFeatureValue* timeValue = [output featureValueForName:@"time_output"];
        if (!timeValue || timeValue.type != MLFeatureTypeMultiArray) {
            NSLog(@"StemSeparatorBridge: missing time_output tensor");
            return false;
        }
        MLMultiArray* timeArr = timeValue.multiArrayValue;
        // Need shape[0..2] AND strides[0..2]; checking shape.count alone
        // doesn't guarantee strides has the same dimensionality on every
        // CoreML build. Reading strides[1] below would throw NSRangeException
        // otherwise.
        if (timeArr.shape.count < 3 || timeArr.strides.count < 3 ||
            timeArr.shape[1].longValue != kOutputChannels) {
            NSLog(@"StemSeparatorBridge: unexpected output shape %@ strides %@",
                  timeArr.shape, timeArr.strides);
            return false;
        }

        // Float16 → Float32 output copy. Walk channels via stride[1] so we
        // don't assume contiguous layout. Output written as 8 × chunkFrames
        // contiguous in caller's buffer (channel-major to match the
        // OpenVINO/ONNX backends' wire format).
        const __fp16* outData = (__fp16*)timeArr.dataPointer;
        const long outChannels = timeArr.shape[1].longValue;
        const long outFrames = timeArr.shape[2].longValue;
        const long strideCh = timeArr.strides[1].longValue;
        const long emit = (outFrames < chunkFrames) ? outFrames : chunkFrames;
        std::memset(timeOutput, 0, sizeof(float) * (size_t)(kOutputChannels * chunkFrames));
        for (long ch = 0; ch < outChannels; ch++) {
            const __fp16* row = outData + ch * strideCh;
            float* dst = timeOutput + ch * chunkFrames;
            for (long i = 0; i < emit; i++) {
                dst[i] = float(row[i]);
            }
        }
        return true;
    }
}

} // namespace AppleStemSeparatorBridge
