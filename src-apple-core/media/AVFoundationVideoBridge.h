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

// Pure C++ ABI between the cross-platform `AVFoundationVideoReader`
// `VideoReaderImpl` subclass (in `src-core/media/`) and the
// AVFoundation / VideoToolbox / CoreImage / Accelerate machinery that
// backs it. All decoder state — AVAssetReader, VTDecompressionSession,
// pixel-transfer session, double-buffered frames, B-frame queue —
// lives behind an opaque handle owned by the Apple-side .mm.

#include <cstdint>
#include <string>

namespace AppleAVFoundationVideoBridge {

// Mirror of `VideoPixelFormat` in `src-core/media/VideoFrame.h`. We
// duplicate the shape (rather than including the src-core header) so
// this layer compiles without any src-core dependency. Caller maps to
// the public enum.
enum class PixelFormat {
    RGB24,
    BGR24,
    RGBA,
    BGRA,
};

// Mirror of `VideoScaleAlgorithm` in the same header.
enum class ScaleAlgorithm {
    Default,
    Bicubic,
    Lanczos,
    Area,
    Point,
};

struct VideoReaderHandle;

// View into the current decoded frame. `data` points into a buffer
// owned by the handle and is only valid until the next mutating call
// (GetNextFrame / Seek / Resize / Destroy). Returned by GetNextFrame
// as `const FrameView*`; null means decode failure / end of stream.
struct FrameView {
    uint8_t* data = nullptr;
    int linesize = 0;
    int width = 0;
    int height = 0;
    PixelFormat format = PixelFormat::RGB24;
};

[[nodiscard]] VideoReaderHandle* CreateReader(const std::string& filename,
                                               int maxwidth, int maxheight,
                                               bool keepaspectratio,
                                               bool usenativeresolution,
                                               bool wantAlpha,
                                               bool bgr,
                                               bool wantsHWType);
void DestroyReader(VideoReaderHandle* h);

[[nodiscard]] bool IsValid(VideoReaderHandle* h);
// True when GetNextFrame(t) is a pure function of (file, t) AND the decoder
// tolerates many consumers at arbitrary positions (pts-indexed shared decoder,
// random-access lanes). False for rawvideo-demux files: AVAssetReader cannot
// start mid-chunk on them, so repositioning is a full re-demux and heavy
// multi-position access storms MediaToolbox ("Cannot Complete Action").
[[nodiscard]] bool IsFrameIndependent(VideoReaderHandle* h);
[[nodiscard]] int GetLengthMS(VideoReaderHandle* h);
[[nodiscard]] int GetWidth(VideoReaderHandle* h);
[[nodiscard]] int GetHeight(VideoReaderHandle* h);
[[nodiscard]] bool AtEnd(VideoReaderHandle* h);
[[nodiscard]] int GetPos(VideoReaderHandle* h);
[[nodiscard]] int GetPixelChannels(VideoReaderHandle* h);

void Seek(VideoReaderHandle* h, int timestampMS, bool readFrame);

// Returns null at EOF or on decode failure. On success, the returned
// pointer is valid until the next call on the same handle.
[[nodiscard]] const FrameView* GetNextFrame(VideoReaderHandle* h, int timestampMS, int gracetime);

[[nodiscard]] bool Resize(VideoReaderHandle* h, int width, int height);
// Corridor identity for decoder chain affinity: handles serving the same
// row/effect stream share a group; the shared decoder keeps one forward
// decode chain per group instead of stealing chains across corridors.
void SetStreamGroup(VideoReaderHandle* h, uint64_t group);
void SetScaleAlgorithm(VideoReaderHandle* h, ScaleAlgorithm algorithm);

// Stateless helper — opens the file just enough to read the duration.
[[nodiscard]] long GetVideoLengthStatic(const std::string& filename);

} // namespace AppleAVFoundationVideoBridge
