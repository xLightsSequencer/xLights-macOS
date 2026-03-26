#pragma once

#include <filesystem>
#include <functional>
#include <string>
#include <list>

#include "../../xLights-macOSLib.build/DerivedSources/xLights_macOSLib-Swift.h"

/* Various touch points that the OSX builds can use to
 * setup some various advanced functionality
 */

bool ObtainAccessToURL(const std::string &path, bool enforceWritable = false);

inline bool FileExists(const std::string &s, bool waitForDownload = true) {
    return xLights_macOSLib::fileExists(s, waitForDownload);
}

inline void MarkNewFileRevision(const std::string &path, int retainMax = 15) {
    xLights_macOSLib::markNewFileRevision(path, retainMax);
}

std::list<std::string> GetFileRevisions(const std::string &path);

inline std::string GetURLForRevision(const std::string &path, const std::string &rev) {
    return xLights_macOSLib::getURLForRevision(path, rev);
}

inline void EnableSleepModes() {
    xLights_macOSLib::enableSleepModes();
}
inline void DisableSleepModes() {
    xLights_macOSLib::disableSleepModes();
}
inline bool IsMouseEventFromTouchpad() {
    return xLights_macOSLib::isMouseEventFromTouchpad();
}
inline bool hasFullDiskAccess() {
    return xLights_macOSLib::hasFullDiskAccess();
}

void AddAudioDeviceChangeListener(std::function<void()> &&callback);
void RemoveAudioDeviceChangeListener();

inline bool IsFromAppStore() {
    return xLights_macOSLib::isFromAppStore();
}

inline double xlOSGetMainScreenContentScaleFactor() {
    return xLights_macOSLib::xlOSGetMainScreenContentScaleFactor();
}

void RunInAutoReleasePool(std::function<void()> &&f);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
inline void WXGLUnsetCurrentContext() {
    xLights_macOSLib::WXGLUnsetCurrentContext();
}
#pragma clang diagnostic pop

void SetThreadQOS(int i);

#define __XL_EXTERNAL_HOOKS__
