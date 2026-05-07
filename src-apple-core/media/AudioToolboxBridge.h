#pragma once

/***************************************************************
 * This source files comes from the xLights project
 * https://www.xlights.org
 * https://github.com/xLightsSequencer/xLights
 * See the github commit history for a record of contributing
 * developers.
 * Copyright claimed based on commit dates recorded in Github
 * License: https://github.com/xLightsSequencer/xLights/blob/master/License.txt
 **************************************************************/

// Pure C++ ABI between the cross-platform `AudioToolboxDecoder`
// `IAudioDecoder` subclass (in `src-core/media/`) and the AVFoundation /
// AudioToolbox calls that back it. The bridge does NOT fall back to
// FFmpeg — that decision lives in src-core, where FFmpegAudioDecoder
// is reachable. Apple-side responsibility is just "try ExtAudioFile,
// then AVAssetReader; report success/failure".

#include <cstdint>
#include <functional>
#include <map>
#include <string>
#include <vector>

namespace AppleAudioToolboxBridge {

// Mirror of `DecodedAudioInfo` in `src-core/media/IAudioDecoder.h`. We
// duplicate the shape here (rather than including the src-core header)
// so this layer compiles without any src-core dependency. Caller copies
// fields back into the public type.
struct DecodedInfo {
    long sampleRate = 0;
    int channels = 0;
    long trackSize = 0;
    long lengthMS = 0;
    long bitRate = 0;
    int bitsPerSample = 0;
    std::string title;
    std::string artist;
    std::string album;
    std::map<std::string, std::string> metadata;
};

// Decode `path` to 16-bit stereo interleaved PCM at `targetRate`.
// On success: `pcmData`, `leftData`, `rightData` are malloc'd and the
// caller takes ownership (free with `free`; `rightData == leftData` for
// mono input — caller frees `right` only when distinct). On failure:
// returns false and leaves all out-pointers null. Tries ExtAudioFile
// first, then AVAssetReader; does NOT fall back to FFmpeg.
[[nodiscard]] bool DecodeFile(const std::string& path,
                              long targetRate,
                              int extra,
                              DecodedInfo& info,
                              uint8_t*& pcmData, long& pcmDataSize,
                              float*& leftData, float*& rightData,
                              long& trackSize,
                              std::function<void(int pct)> progress);

// Encode `left`/`right` float samples (already at `sampleRate`) to
// `filename`. Output container chosen by extension: ".m4a" → AAC in
// M4A, ".wav" → 16-bit PCM in WAV, otherwise MP3. Returns false on
// any failure (mismatched lengths, can't open output, encode error).
[[nodiscard]] bool EncodeToFile(const std::vector<float>& left,
                                 const std::vector<float>& right,
                                 size_t sampleRate,
                                 const std::string& filename);

// Returns audio data byte count from `kAudioFilePropertyAudioDataByteCount`.
// 0 on failure (file missing, unrecognized format, property unavailable).
[[nodiscard]] size_t GetAudioFileLength(const std::string& filename);

} // namespace AppleAudioToolboxBridge
