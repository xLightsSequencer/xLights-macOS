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

// Pure C++ ABI between the cross-platform `AVFoundationVideoWriter`
// `VideoWriterImpl` subclass (in `src-core/media/`) and the
// AVAssetWriter / AVAssetWriterInputPixelBufferAdaptor / CoreMedia
// machinery that backs it. All writer state — the AVAssetWriter, video
// and audio inputs, the pixel-buffer pool — lives behind an opaque
// handle owned by the Apple-side .mm. Mirrors the shape of
// `AVFoundationVideoBridge.h` (the reader side).

#include <string>

namespace AppleAVFoundationVideoWriterBridge {

struct WriterHandle;

// Capability probe — opens nothing. True when AVFoundation can encode
// `videoCodec` ("H.264" / "H.265" / "ProRes") into the container implied
// by `outPath`'s extension (.mp4 / .m4v / .mov).
[[nodiscard]] bool CanExport(const std::string& outPath, const std::string& videoCodec);

// Create (but do not start) an AVAssetWriter for the given output. An
// existing file at `outPath` is removed first (AVAssetWriter refuses to
// overwrite). `bitrateKbps` == 0 selects a quality-based default.
// Returns null on failure.
[[nodiscard]] WriterHandle* CreateWriter(const std::string& outPath,
                                         const std::string& videoCodec,
                                         int width, int height, int fps,
                                         int bitrateKbps, double quality,
                                         bool hasAudio, int audioSampleRate,
                                         bool cpuFrames, int inputChannels);

void DestroyWriter(WriterHandle* h);

[[nodiscard]] bool IsValid(WriterHandle* h);

// startWriting + startSessionAtSourceTime:kCMTimeZero. Returns false on
// failure (inspect log for the AVAssetWriter error).
[[nodiscard]] bool Start(WriterHandle* h);

// Vend a pool-allocated CVPixelBufferRef (returned as void*) for the
// renderer to fill (e.g. via CoreImage). The buffer must be handed back
// to AppendVideoFrame, which releases the extra retain. Returns null on
// failure. Blocks until the video input is ready for more data.
[[nodiscard]] void* RequestPixelBuffer(WriterHandle* h);

// Copy a CPU RGB24 (channels==3) / RGBA (channels==4) frame into the pool
// pixel buffer `pb` (vended by RequestPixelBuffer). Used by the CPU-frame
// callers (model export, transcoder) instead of rendering a Metal texture.
// `width`/`height` must match the buffer. Returns false on failure.
[[nodiscard]] bool FillPixelBufferRGB(WriterHandle* h, void* pb,
                                      const unsigned char* rgb, int channels,
                                      int width, int height);

// Append a filled pixel buffer at presentation time frameIndex/fps.
// Releases `pixelBuffer`'s retain from RequestPixelBuffer.
[[nodiscard]] bool AppendVideoFrame(WriterHandle* h, void* pixelBuffer, int frameIndex);

// Append one block of stereo audio (planar float L/R, `numSamples` per
// channel) at presentation time sampleOffset/audioSampleRate. Blocks
// until the audio input is ready for more data.
[[nodiscard]] bool AppendAudio(WriterHandle* h, const float* left, const float* right,
                               int numSamples, long long sampleOffset);

// Mark inputs finished and wait (synchronously) for the writer to flush.
// When `cancel` is true, cancels and removes the partial file.
// Returns false on a writer failure.
[[nodiscard]] bool Finish(WriterHandle* h, bool cancel);

} // namespace AppleAVFoundationVideoWriterBridge
