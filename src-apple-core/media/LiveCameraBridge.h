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

// Pure C++ ABI between the cross-platform `LiveCameraCapture` (in
// `src-core/media/`) and the AVFoundation capture machinery that backs
// it on Apple. The AVCaptureSession, its video data output, the sample
// delegate and the latest-frame buffer all live behind an opaque handle
// owned by the Apple-side .mm. Mirrors the shape of the Media Foundation
// implementation in `LiveCameraCapture.cpp`, so the core sees one API.

#include <cstdint>
#include <string>
#include <vector>

namespace AppleLiveCameraBridge {

struct CaptureHandle;

struct DeviceInfo {
    std::string name;      // AVCaptureDevice.localizedName
    std::string uniqueID;  // AVCaptureDevice.uniqueID — reopens the device
};

// Video capture devices currently attached: built-in, USB/UVC, and
// (macOS 14+) Continuity Cameras. Safe to call repeatedly.
//
// Continuity devices only appear because the app's Info.plist carries
// NSCameraUseContinuityCameraDeviceType; without that key the discovery
// session silently omits them.
[[nodiscard]] std::vector<DeviceInfo> EnumerateDevices();

// Open `uniqueID` and start delivering frames on a background queue.
// Empty `uniqueID` picks the system default. Returns null if the device
// can't be opened or the user has denied camera access.
[[nodiscard]] CaptureHandle* Open(const std::string& uniqueID);

void Destroy(CaptureHandle* h);
[[nodiscard]] bool IsValid(CaptureHandle* h);

// Stop the session. Safe to call more than once; Destroy calls it too.
void Stop(CaptureHandle* h);

// Dark mode: lock exposure and white balance so the camera stops
// re-metering while the scan diffs frames against a fixed baseline.
//
// This is weaker than the Windows path deliberately, not by omission:
// setExposureModeCustomWithDuration:ISO: is API_UNAVAILABLE(macos), so
// there is no way to pin a short manual exposure or floor the gain the
// way IAMCameraControl / IAMVideoProcAmp can. Locking is what the
// platform offers. Passing false restores the previous modes.
void SetDarkMode(CaptureHandle* h, bool enabled);

// Non-destructive copy of the most recent frame as packed top-down
// RGB24. False when no frame has arrived yet.
//
// `generation` counts delivered frames. Pass the value from the previous
// call (0 first time); when it is unchanged, outRgb is left alone and the
// call still returns true - the caller already holds that frame, and at
// 30fps a full copy per poll is most of the cost of looking.
[[nodiscard]] bool TryGetLatestFrame(CaptureHandle* h, std::vector<uint8_t>& outRgb,
                                     int& outWidth, int& outHeight,
                                     uint64_t& generation);

} // namespace AppleLiveCameraBridge
