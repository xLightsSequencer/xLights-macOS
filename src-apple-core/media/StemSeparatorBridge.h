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

// Pure C++ ABI between the cross-platform `SeparateStems` orchestration
// (in `src-core/media/StemSeparator.cpp`) and Apple's CoreML-backed
// HTDemucs model. The bridge owns model loading + per-chunk inference;
// STFT, chunking, and crossfade live in src-core (shared with the
// OpenVINO / ONNX backends).

#include <string>

namespace AppleStemSeparatorBridge {

struct ModelHandle;

// Compile (if needed) and load the HTDemucs model at `modelPath`. Pass
// either a `.mlpackage` directory (will be compiled to `.mlmodelc` next
// to it) or a pre-compiled `.mlmodelc`. Returns null on compile / load
// failure or when CoreML Float16 multi-arrays aren't available
// (macOS < 12 / iOS < 15).
[[nodiscard]] ModelHandle* LoadModel(const std::string& modelPath);
void DestroyModel(ModelHandle* m);

// Run a single chunk through the model.
//   waveform: 2 × chunkFrames floats, channel-major (L then R)
//   spectral: 4 × 2048 × 336 floats, channel-major
//             (L_real, L_imag, R_real, R_imag) × bins × frames
//   timeOutput: caller-allocated 8 × chunkFrames float buffer.
//             The HTDemucs output channel order is drums L/R, bass L/R,
//             vocals L/R, other L/R (NOT drums/bass/other/vocals as the
//             john-rocky model card claims — verified empirically).
// Returns false on inference failure or shape mismatch; on failure the
// timeOutput contents are unspecified.
[[nodiscard]] bool RunChunk(ModelHandle* m,
                            const float* waveform, long waveformSize,
                            const float* spectral, long spectralSize,
                            float* timeOutput, long timeOutputSize);

} // namespace AppleStemSeparatorBridge
