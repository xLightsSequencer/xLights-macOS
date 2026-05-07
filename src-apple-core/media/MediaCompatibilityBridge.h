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

// Pure C++ ABI between the cross-platform `MediaCompatibility` class
// (in `src-core/media/`) and the Apple-only AVFoundation / AudioToolbox
// probes that back it. The src-core .cpp must not include AVFoundation
// or AudioToolbox headers directly; all of that lives behind this thin
// interface so the rest of `src-core/media/` stays buildable for the
// non-Apple toolchains.

#include <string>

namespace AppleMediaCompatibility {

// Returns "" if the file is decodable by AVFoundation (playable, at
// least one video track, AVAssetReader can decode the first frame).
// Otherwise returns a human-readable reason string. Empty input yields
// "" (caller is responsible for skipping empty paths).
[[nodiscard]] std::string CheckVideoFile(const std::string& filePath);

// Returns "" if the file opens with ExtAudioFileOpenURL and can be
// configured for PCM client output. Otherwise returns a human-readable
// reason string. Empty input yields "".
[[nodiscard]] std::string CheckAudioFile(const std::string& filePath);

} // namespace AppleMediaCompatibility
