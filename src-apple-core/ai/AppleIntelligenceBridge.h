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

// Pure C++ ABI between the cross-platform `AppleIntelligence` aiBase
// subclass (in `src-core/ai/`) and the Apple-only Swift / CoreGraphics
// machinery in this folder. The src-core .cpp must not include
// Swift-generated headers or pull in CoreGraphics types directly; all
// of that lives behind this thin interface so the C++ class can be
// compiled by the wx-free `xLights-core` target.

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace AppleAIBridge {

// Run the on-device LLM (FoundationModels.LanguageModelSession) and
// return the response text. Returns an empty string on failure or
// when the OS doesn't support FoundationModels (caller should
// already have gated availability via __builtin_available).
[[nodiscard]] std::string CallLLM(const std::string& prompt);

// Same model, schema-constrained generation for an 8-color palette.
// Returns the JSON-stringified response (or `{"error": "..."}` JSON
// if the underlying API throws). Empty string means the OS is too
// old or the call couldn't be initiated at all.
[[nodiscard]] std::string GenerateColorPaletteJSON(const std::string& prompt);

// Asynchronous image generation via ImagePlayground.ImageCreator.
// `callback` fires exactly once with PNG bytes (`png` non-empty) or
// an error message (`error` non-empty), never both. The callback may
// fire on any thread — the caller is responsible for marshalling
// onto the thread it wants. `style` matches one of ImageCreator's
// available styles ("animation", "illustration", "sketch", "emoji").
struct ImageResult {
    std::vector<uint8_t> png;
    std::string error;
};
void GenerateImage(const std::string& prompt,
                   const std::string& fullInstructions,
                   const std::string& style,
                   std::function<void(ImageResult)> callback);

// SFSpeechRecognizer-based audio transcription. `audioPath` is the
// absolute path of an audio file readable by AVAudioFile (anything
// AVFoundation knows how to decode — m4a, wav, mp3, …). The
// recognizer is forced to on-device mode for privacy and to avoid
// sending audio to Apple's servers.
//
// SFSpeechRecognizer's own per-request limit is one minute, so the
// implementation reads `audioPath` in chunks of ~45 s and time-shifts
// each chunk's word segments. Permission is requested on first call;
// the caller must have `NSSpeechRecognitionUsageDescription` in
// Info.plist or the prompt won't appear and the call will fail.
//
// Callback fires once on a private queue with either a non-empty
// `lyrics` vector + empty `error` (success) or empty `lyrics` +
// non-empty `error`. Caller marshals to its preferred queue.
struct LyricSegment {
    std::string word;
    int startMS = 0;
    int endMS   = 0;
};
struct LyricResult {
    std::vector<LyricSegment> lyrics;
    std::string error;
};
void GenerateLyricTrack(const std::string& audioPath,
                        std::function<void(LyricResult)> callback);

} // namespace AppleAIBridge
