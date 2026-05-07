/***************************************************************
 * This source files comes from the xLights project
 * https://www.xlights.org
 * https://github.com/xLightsSequencer/xLights
 * See the github commit history for a record of contributing
 * developers.
 * Copyright claimed based on commit dates recorded in Github
 * License: https://github.com/xLightsSequencer/xLights/blob/master/License.txt
 **************************************************************/

// SoundAnalysis.framework SNClassifySoundRequest backing for
// `src-core/media/SoundClassifier.cpp`. Pure C++ ABI in/out so this
// file owns the SoundAnalysis dependency and src-core stays
// Apple-framework-free.

#include "SoundClassifierBridge.h"

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <SoundAnalysis/SoundAnalysis.h>

#include <algorithm>
#include <cstring>

@interface XLSoundClassifierObserver : NSObject<SNResultsObserving>
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSMutableArray<NSNumber*>*>* buckets;
@property(nonatomic, assign) BOOL didError;
@end

@implementation XLSoundClassifierObserver
- (instancetype)init {
    self = [super init];
    if (self) {
        _buckets = [NSMutableDictionary dictionary];
        _didError = NO;
    }
    return self;
}
- (void)request:(id<SNRequest>)request didProduceResult:(id<SNResult>)result {
    if (![result isKindOfClass:[SNClassificationResult class]]) return;
    SNClassificationResult* r = (SNClassificationResult*)result;
    for (SNClassification* c in r.classifications) {
        NSMutableArray<NSNumber*>* arr = self.buckets[c.identifier];
        if (!arr) {
            arr = [NSMutableArray array];
            self.buckets[c.identifier] = arr;
        }
        [arr addObject:@(c.confidence)];
    }
}
- (void)request:(id<SNRequest>)request didFailWithError:(NSError*)error {
    self.didError = YES;
}
- (void)requestDidComplete:(id<SNRequest>)request {
    // results were accumulated incrementally
}
@end

namespace {

// Copy `frames` samples into a fresh AVAudioPCMBuffer at `sampleRate`.
// The analyzer accepts mono float32 buffers.
AVAudioPCMBuffer* MakeMonoFloatBuffer(const float* samples, long startFrame, long frames, double sampleRate) {
    AVAudioFormat* fmt = [[AVAudioFormat alloc]
        initStandardFormatWithSampleRate:sampleRate
                                channels:1];
    AVAudioPCMBuffer* buf = [[AVAudioPCMBuffer alloc]
        initWithPCMFormat:fmt
           frameCapacity:(AVAudioFrameCount)frames];
    if (!buf) return nil;
    buf.frameLength = (AVAudioFrameCount)frames;
    float* dst = buf.floatChannelData[0];
    if (!dst) return nil;
    memcpy(dst, samples + startFrame, sizeof(float) * (size_t)frames);
    return buf;
}

} // namespace

namespace AppleSoundClassifierBridge {

ClassifyResult ClassifyMono(const float* samples,
                             long frameCount,
                             double sampleRate,
                             double windowSeconds) {
    ClassifyResult out;
    if (!samples || frameCount <= 0 || sampleRate <= 0) {
        out.didError = true;
        return out;
    }

    @autoreleasepool {
        NSError* err = nil;
        SNClassifySoundRequest* request = nil;
        if (@available(iOS 15.0, macOS 12.0, *)) {
            request = [[SNClassifySoundRequest alloc]
                initWithClassifierIdentifier:SNClassifierIdentifierVersion1
                                       error:&err];
        }
        if (!request || err) {
            out.didError = true;
            return out;
        }
        if (windowSeconds > 0) {
            if (@available(iOS 15.0, macOS 12.0, *)) {
                request.windowDuration = CMTimeMakeWithSeconds(windowSeconds, NSEC_PER_SEC);
            }
        }

        AVAudioFormat* fmt = [[AVAudioFormat alloc]
            initStandardFormatWithSampleRate:sampleRate
                                    channels:1];
        SNAudioStreamAnalyzer* analyzer = [[SNAudioStreamAnalyzer alloc] initWithFormat:fmt];
        if (!analyzer) {
            out.didError = true;
            return out;
        }

        XLSoundClassifierObserver* observer = [[XLSoundClassifierObserver alloc] init];
        if (![analyzer addRequest:request withObserver:observer error:&err]) {
            out.didError = true;
            return out;
        }

        // Feed in ~1 second chunks; the analyzer buffers internally so
        // smaller chunks would also work.
        const long chunkFrames = std::max<long>(1, (long)sampleRate);
        long pos = 0;
        while (pos < frameCount) {
            long n = std::min(chunkFrames, frameCount - pos);
            AVAudioPCMBuffer* pcm = MakeMonoFloatBuffer(samples, pos, n, sampleRate);
            if (!pcm) break;
            [analyzer analyzeAudioBuffer:pcm
                    atAudioFramePosition:(AVAudioFramePosition)pos];
            pos += n;
        }
        [analyzer completeAnalysis];
        if (observer.didError) {
            out.didError = true;
            return out;
        }

        out.classes.reserve(observer.buckets.count);
        for (NSString* key in observer.buckets) {
            NSArray<NSNumber*>* arr = observer.buckets[key];
            ClassResult r;
            r.name = [key UTF8String];
            r.confidence.reserve(arr.count);
            for (NSNumber* n in arr) {
                r.confidence.push_back(n.floatValue);
            }
            out.classes.push_back(std::move(r));
        }
    }
    return out;
}

} // namespace AppleSoundClassifierBridge
