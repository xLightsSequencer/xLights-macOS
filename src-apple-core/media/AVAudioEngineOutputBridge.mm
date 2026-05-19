/***************************************************************
 * This source files comes from the xLights project
 * https://www.xlights.org
 * https://github.com/xLightsSequencer/xLights
 * See the github commit history for a record of contributing
 * developers.
 * Copyright claimed based on commit dates recorded in Github
 * License: https://github.com/xLightsSequencer/xLights/blob/master/License.txt
 **************************************************************/

// AVAudioEngine playback backend that backs
// `src-core/media/AVAudioEngineOutput.cpp`. The opaque `OutputHandle*`
// returned to src-core points at this file's `AVAudioEngineOutputImpl`,
// which owns the engine + per-track player nodes. Pure C++ ABI in/out.

#include "AVAudioEngineOutputBridge.h"

#import <AVFAudio/AVFAudio.h>

#include <algorithm>
#include <map>
#include <mutex>
#include <string>

#include <log.h>

namespace {

struct AudioTrack {
    int trackId;
    uint8_t* rawBuffer;       // borrowed from caller (AudioManager)
    long rawBufferLen;
    long trackSize;           // samples per channel
    long lengthMS;
    int rate;
    int volume = 100;         // 0-100
    bool paused = false;

    AVAudioPlayerNode* playerNode = nil;
    bool playing = false;

    long seekOffsetFrames = 0;      // frame offset from last schedule
    long scheduledFrameCount = 0;   // how many frames were scheduled
};

} // namespace

namespace AppleAudioOutputBridge {

struct OutputHandle {
    AVAudioEngine* engine = nil;
    AVAudioUnitTimePitch* timePitch = nil;
    AVAudioMixerNode* mixer = nil;
    float playbackRate = 1.0f;
    bool usingTimePitch = false;  // only insert timePitch when rate != 1.0
    std::string device;
    bool initialized = false;
    int globalVolume = 100;       // 0-100, combined with per-track volume

    std::map<int, AudioTrack*> tracks;
    std::mutex trackLock;
    int nextId = 0;

    ~OutputHandle() {
        if (engine && engine.isRunning) {
            [engine stop];
        }
        for (auto& [id, track] : tracks) {
            if (track->playerNode) {
                [track->playerNode stop];
                [track->playerNode release];
                track->playerNode = nil;
            }
            delete track;
        }
        tracks.clear();
        [timePitch release];
        timePitch = nil;
        [engine release];
        engine = nil;
    }

    AVAudioNode* playerTarget() {
        return usingTimePitch ? (AVAudioNode*)timePitch : (AVAudioNode*)mixer;
    }

    bool init() {
        if (initialized) return true;

        engine = [[AVAudioEngine alloc] init];
        timePitch = [[AVAudioUnitTimePitch alloc] init];
        timePitch.rate = playbackRate;
        mixer = engine.mainMixerNode;

        // At rate 1.0 connect playerNode -> mixer directly (lowest latency).
        // At other rates insert timePitch in the chain.
        if (playbackRate != 1.0f) {
            AVAudioFormat* fmt = [engine.outputNode inputFormatForBus:0];
            [engine attachNode:timePitch];
            [engine connect:timePitch to:mixer format:fmt];
            usingTimePitch = true;
        }

        NSError* error = nil;
        [engine startAndReturnError:&error];
        if (error) {
            spdlog::error("AVAudioEngine start failed: {}", error.localizedDescription.UTF8String);
            return false;
        }

        initialized = true;
        AVAudioFormat* fmt = [engine.outputNode inputFormatForBus:0];
        spdlog::debug("AVAudioEngine initialized for device '{}', format: {}Hz {}ch, timePitch: {}",
                       device, fmt.sampleRate, (int)fmt.channelCount,
                       usingTimePitch ? "active" : "bypassed");
        return true;
    }

    void ensureTimePitch(bool need) {
        if (need == usingTimePitch) return;
        if (!engine) return;

        bool wasRunning = engine.isRunning;
        if (wasRunning) [engine stop];

        for (auto& [id, track] : tracks) {
            if (track->playerNode) {
                [engine disconnectNodeOutput:track->playerNode];
            }
        }

        if (need && !usingTimePitch) {
            AVAudioFormat* fmt = [engine.outputNode inputFormatForBus:0];
            [engine attachNode:timePitch];
            [engine connect:timePitch to:mixer format:fmt];
            usingTimePitch = true;
        } else if (!need && usingTimePitch) {
            [engine disconnectNodeOutput:timePitch];
            [engine detachNode:timePitch];
            usingTimePitch = false;
            [timePitch release];
            timePitch = [[AVAudioUnitTimePitch alloc] init];
            timePitch.rate = playbackRate;
        }

        for (auto& [id, track] : tracks) {
            if (track->playerNode) {
                AVAudioFormat* nodeFormat = [[AVAudioFormat alloc]
                    initWithCommonFormat:AVAudioPCMFormatFloat32
                    sampleRate:track->rate
                    channels:2
                    interleaved:NO];
                [engine connect:track->playerNode to:playerTarget() format:nodeFormat];
                [nodeFormat release];
            }
        }

        if (wasRunning) {
            NSError* error = nil;
            [engine startAndReturnError:&error];
        }
    }

    float effectiveVolume(int trackVolume) {
        int v = (std::max(0, std::min(100, trackVolume)) * std::max(0, std::min(100, globalVolume))) / 100;
        return v / 100.0f;
    }

    void updateAllTrackVolumes() {
        for (auto& [id, track] : tracks) {
            if (track->playerNode) {
                track->playerNode.volume = effectiveVolume(track->volume);
            }
        }
    }

    AVAudioPCMBuffer* createFloat32Buffer(AudioTrack* track, long frameOffset, long frameCount) {
        long totalFrames = track->rawBufferLen / (2 * sizeof(int16_t));
        if (frameCount <= 0) {
            frameCount = totalFrames - frameOffset;
        }
        if (frameOffset + frameCount > totalFrames) {
            frameCount = totalFrames - frameOffset;
        }
        if (frameCount <= 0) return nil;

        AVAudioFormat* trackFormat = [[AVAudioFormat alloc]
            initWithCommonFormat:AVAudioPCMFormatFloat32
            sampleRate:track->rate
            channels:2
            interleaved:NO];

        AVAudioPCMBuffer* pcmBuf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:trackFormat
                                                                 frameCapacity:(AVAudioFrameCount)frameCount];
        [trackFormat release];
        pcmBuf.frameLength = (AVAudioFrameCount)frameCount;

        // Int16 interleaved -> Float32 non-interleaved.
        int16_t* src = (int16_t*)(track->rawBuffer) + frameOffset * 2;
        float* leftDst = pcmBuf.floatChannelData[0];
        float* rightDst = pcmBuf.floatChannelData[1];

        for (long i = 0; i < frameCount; i++) {
            leftDst[i] = (float)src[i * 2] / 32768.0f;
            rightDst[i] = (float)src[i * 2 + 1] / 32768.0f;
        }

        return [pcmBuf autorelease];
    }

    void scheduleTrack(AudioTrack* track, long frameOffset, long frameCount) {
        if (!engine || !track->playerNode) return;

        AVAudioPCMBuffer* pcmBuf = createFloat32Buffer(track, frameOffset, frameCount);
        if (!pcmBuf) return;

        track->seekOffsetFrames = frameOffset;
        track->scheduledFrameCount = pcmBuf.frameLength;

        [track->playerNode scheduleBuffer:pcmBuf completionHandler:nil];
    }
};

OutputHandle* CreateOutput(const std::string& device) {
    auto* h = new OutputHandle();
    h->device = device;
    return h;
}

void DestroyOutput(OutputHandle* h) {
    delete h;
}

bool OpenDevice(OutputHandle* h) {
    return h->init();
}

int AddAudio(OutputHandle* h, long len, uint8_t* buffer,
              int volume, int rate, long tracksize, long lengthMS) {
    if (!h->init()) return -1;

    std::lock_guard<std::mutex> lock(h->trackLock);

    auto* track = new AudioTrack();
    track->trackId = h->nextId++;
    track->rawBuffer = buffer;
    track->rawBufferLen = len;
    track->trackSize = tracksize;
    track->lengthMS = lengthMS;
    track->rate = rate;
    track->volume = volume;

    track->playerNode = [[AVAudioPlayerNode alloc] init];
    [h->engine attachNode:track->playerNode];

    AVAudioFormat* nodeFormat = [[AVAudioFormat alloc]
        initWithCommonFormat:AVAudioPCMFormatFloat32
        sampleRate:rate
        channels:2
        interleaved:NO];
    [h->engine connect:track->playerNode to:h->playerTarget() format:nodeFormat];
    [nodeFormat release];

    track->playerNode.volume = h->effectiveVolume(volume);

    h->tracks[track->trackId] = track;

    spdlog::debug("AVAudioEngine: AddAudio id={}, rate={}, len={}, lengthMS={}", track->trackId, rate, len, lengthMS);
    return track->trackId;
}

void RemoveAudio(OutputHandle* h, int id) {
    std::lock_guard<std::mutex> lock(h->trackLock);
    auto it = h->tracks.find(id);
    if (it == h->tracks.end()) return;

    auto* track = it->second;
    if (track->playerNode) {
        [track->playerNode stop];
        [h->engine detachNode:track->playerNode];
        [track->playerNode release];
        track->playerNode = nil;
    }
    h->tracks.erase(it);
    delete track;
    spdlog::debug("AVAudioEngine: RemoveAudio id={}", id);
}

bool HasAudio(OutputHandle* h, int id) {
    std::lock_guard<std::mutex> lock(h->trackLock);
    return h->tracks.count(id) > 0;
}

void Play(OutputHandle* h) {
    if (!h->engine) return;

    if (!h->engine.isRunning) {
        NSError* error = nil;
        [h->engine startAndReturnError:&error];
        if (error) {
            spdlog::error("AVAudioEngine: Failed to start: {}", error.localizedDescription.UTF8String);
            return;
        }
    }

    std::lock_guard<std::mutex> lock(h->trackLock);
    for (auto& [id, track] : h->tracks) {
        if (!track->paused && track->playerNode) {
            [track->playerNode play];
            track->playing = true;
        }
    }
}

void Stop(OutputHandle* h) {
    std::lock_guard<std::mutex> lock(h->trackLock);
    for (auto& [id, track] : h->tracks) {
        if (track->playerNode) {
            [track->playerNode stop];
            track->playing = false;
        }
    }
}

void PauseTrack(OutputHandle* h, int id, bool pause) {
    std::lock_guard<std::mutex> lock(h->trackLock);
    auto it = h->tracks.find(id);
    if (it == h->tracks.end()) return;
    it->second->paused = pause;
    if (pause && it->second->playerNode) {
        [it->second->playerNode pause];
    } else if (!pause && it->second->playerNode) {
        [it->second->playerNode play];
    }
}

void Pause(OutputHandle* h) {
    if (h->engine) {
        [h->engine pause];
    }
}

void Unpause(OutputHandle* h) {
    if (h->engine && !h->engine.isRunning) {
        NSError* error = nil;
        [h->engine startAndReturnError:&error];
    }
    std::lock_guard<std::mutex> lock(h->trackLock);
    for (auto& [id, track] : h->tracks) {
        if (!track->paused && track->playerNode) {
            [track->playerNode play];
        }
    }
}

long Tell(OutputHandle* h, int id) {
    std::lock_guard<std::mutex> lock(h->trackLock);
    auto it = h->tracks.find(id);
    if (it == h->tracks.end()) return 0;
    auto* track = it->second;

    if (!track->playerNode || !track->playing) return 0;

    AVAudioTime* nodeTime = track->playerNode.lastRenderTime;
    if (!nodeTime || !nodeTime.isSampleTimeValid) return 0;

    AVAudioTime* playerTime = [track->playerNode playerTimeForNodeTime:nodeTime];
    if (!playerTime) return 0;

    long framePlayed = (long)playerTime.sampleTime + track->seekOffsetFrames;
    if (framePlayed < 0) framePlayed = 0;
    if (track->trackSize <= 0) return 0;

    long pos = (framePlayed * track->lengthMS) / track->trackSize;
    return pos;
}

void Seek(OutputHandle* h, int id, long pos) {
    std::lock_guard<std::mutex> lock(h->trackLock);
    auto it = h->tracks.find(id);
    if (it == h->tracks.end()) return;
    auto* track = it->second;

    bool wasPlaying = track->playing;
    if (track->playerNode) {
        [track->playerNode stop];
    }

    long frameOffset = (pos * track->rate) / 1000;
    h->scheduleTrack(track, frameOffset, -1);

    if (wasPlaying && !track->paused) {
        [track->playerNode play];
        track->playing = true;
    }
}

void SeekAndLimitPlayLength(OutputHandle* h, int id, long pos, long len) {
    std::lock_guard<std::mutex> lock(h->trackLock);
    auto it = h->tracks.find(id);
    if (it == h->tracks.end()) return;
    auto* track = it->second;

    if (track->playerNode) {
        [track->playerNode stop];
    }

    long frameOffset = (pos * track->rate) / 1000;
    long frameCount = (len * track->rate) / 1000;
    h->scheduleTrack(track, frameOffset, frameCount);
}

void SetVolume(OutputHandle* h, int id, int volume) {
    std::lock_guard<std::mutex> lock(h->trackLock);
    auto it = h->tracks.find(id);
    if (it == h->tracks.end()) return;
    it->second->volume = volume;
    if (it->second->playerNode) {
        it->second->playerNode.volume = h->effectiveVolume(volume);
    }
}

int GetVolume(OutputHandle* h, int id) {
    std::lock_guard<std::mutex> lock(h->trackLock);
    auto it = h->tracks.find(id);
    if (it == h->tracks.end()) return 0;
    return it->second->volume;
}

void SetGlobalVolume(OutputHandle* h, int volume) {
    std::lock_guard<std::mutex> lock(h->trackLock);
    h->globalVolume = volume;
    h->updateAllTrackVolumes();
}

void SetRate(OutputHandle* h, float rate) {
    h->playbackRate = rate;
    h->timePitch.rate = rate;
    h->ensureTimePitch(rate != 1.0f);
}

void Reopen(OutputHandle* /*h*/) {
    // AVAudioEngine handles device changes automatically.
    spdlog::debug("AVAudioEngine: Reopen (no-op, engine handles device changes)");
}

} // namespace AppleAudioOutputBridge
