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

// Pure C++ ABI between the cross-platform `AVAudioEngineOutput`
// `IAudioOutput` subclass (in `src-core/media/`) and the AVAudioEngine
// machinery that backs it. Per-output state (engine, mixer, time-pitch
// unit, per-track player nodes) lives entirely behind an opaque handle
// owned by the Apple-side .mm so src-core stays Apple-framework-free.

#include <cstdint>
#include <string>

namespace AppleAudioOutputBridge {

struct OutputHandle;

[[nodiscard]] OutputHandle* CreateOutput(const std::string& device);
void DestroyOutput(OutputHandle* h);

[[nodiscard]] bool OpenDevice(OutputHandle* h);

// Adds a track. `buffer` is borrowed (caller retains ownership and must
// keep it alive until the matching RemoveAudio). Returns track id, or
// -1 on failure (engine couldn't initialise).
int AddAudio(OutputHandle* h, long len, uint8_t* buffer,
              int volume, int rate, long tracksize, long lengthMS);
void RemoveAudio(OutputHandle* h, int id);
[[nodiscard]] bool HasAudio(OutputHandle* h, int id);

void Play(OutputHandle* h);
void Stop(OutputHandle* h);
void PauseTrack(OutputHandle* h, int id, bool pause);
void Pause(OutputHandle* h);
void Unpause(OutputHandle* h);

[[nodiscard]] long Tell(OutputHandle* h, int id);
void Seek(OutputHandle* h, int id, long pos);
void SeekAndLimitPlayLength(OutputHandle* h, int id, long pos, long len);

void SetVolume(OutputHandle* h, int id, int volume);
[[nodiscard]] int GetVolume(OutputHandle* h, int id);
void SetGlobalVolume(OutputHandle* h, int volume);
void SetRate(OutputHandle* h, float rate);
void Reopen(OutputHandle* h);

} // namespace AppleAudioOutputBridge
