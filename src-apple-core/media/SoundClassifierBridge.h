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

// Pure C++ ABI between the cross-platform `ClassifySound` entry point
// (in `src-core/media/SoundClassifier.cpp`) and Apple's
// SoundAnalysis.framework SNClassifySoundRequest. The bridge runs the
// analyzer over a mono Float32 buffer and returns the raw per-class
// confidence curves; min-confidence filtering, max-classes truncation,
// and sorting all live in src-core (they're pure C++ and tied to
// `SoundClassifierOptions`).

#include <string>
#include <vector>

namespace AppleSoundClassifierBridge {

struct ClassResult {
    std::string name;
    std::vector<float> confidence;
};

struct ClassifyResult {
    std::vector<ClassResult> classes;
    bool didError = false;
};

// `samples` points to `frameCount` mono Float32 samples at `sampleRate`
// Hz. `windowSeconds` matches Apple's `SNClassifySoundRequest.windowDuration`
// (0 or negative → analyzer default, ~1.0s).
// Synchronous; fills the entire result before returning. On framework
// failure (analyzer creation, request init, observer error), returns
// `didError = true` and an empty `classes` vector.
[[nodiscard]] ClassifyResult ClassifyMono(const float* samples,
                                           long frameCount,
                                           double sampleRate,
                                           double windowSeconds);

} // namespace AppleSoundClassifierBridge
