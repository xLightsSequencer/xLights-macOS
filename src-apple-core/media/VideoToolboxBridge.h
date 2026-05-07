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

// VideoToolbox helpers used from `src-core/media/FFmpegVideoReader.cpp`
// to set up Apple HW-accelerated decode + scaling. The five functions
// below take only FFmpeg types — `AVCodecContext*`, `AVFrame*`, plus
// primitive cache pointer/scale-algorithm enum — so they can live
// behind a clean C++ namespace ABI without dragging Apple SDK types
// into src-core.
//
// The two graphics-side helpers (`VideoToolboxCreateFrame`,
// `VideoToolboxCopyToTexture`) take Apple-only types in their
// signatures (`CIImage*`, `id<MTLTexture>`, `id<MTLDevice>`) and are
// called only from Apple-only `.mm` files in `graphics/metal/` —
// they intentionally stay as bare `extern` declarations there.

struct AVCodecContext;
struct AVFrame;

namespace AppleVideoToolboxBridge {

// Initialise the shared CIContext / colour-flip kernel used by
// VideoToolboxScaleImage. Safe to call repeatedly; no-op after the
// first successful init.
void InitVideoToolboxAcceleration();

// Configure `s` to negotiate VideoToolbox HW decode. Returns false
// when `enabled` is false (signalling the caller should not enable
// HW decode for this context).
[[nodiscard]] bool SetupVideoToolboxAcceleration(AVCodecContext* s, bool enabled);

// Release any per-codec scratch (currently the cached scaled
// CVPixelBuffer). Safe to call with `cache == nullptr`.
void CleanupVideoToolbox(AVCodecContext* s, void* cache);

// True when `frame` carries a VideoToolbox-decoded CVPixelBuffer in
// `data[3]` (and no software planes). Cheap field check, no syscalls.
[[nodiscard]] bool IsVideoToolboxAcceleratedFrame(AVFrame* frame);

// Scale a VideoToolbox-decoded frame into `dstFrame`, populating
// `dstFrame->data[0]` with the requested pixel format. `cache` is
// caller-owned per-codec scratch (allocated lazily, freed by
// CleanupVideoToolbox). `scaleAlgorithm` is the FFmpeg `SWS_*`
// constant chosen by the caller. Returns false on any failure
// (no CIContext, missing CVPixelBuffer, allocation failure).
[[nodiscard]] bool VideoToolboxScaleImage(AVCodecContext* codecContext,
                                            AVFrame* frame,
                                            AVFrame* dstFrame,
                                            void*& cache,
                                            int scaleAlgorithm);

} // namespace AppleVideoToolboxBridge
