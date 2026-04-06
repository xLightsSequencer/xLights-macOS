
#include "ExternalHooksApple.h"
#include "xLights_Apple_core-Swift.h"

#include <functional>

void RunInAutoReleasePool(std::function<void()> &&f) {
    @autoreleasepool {
        f();
    }
}

bool FileExists(const std::string &s, bool waitForDownload) {
    return xLights_Apple_core::fileExists(s, waitForDownload);
}

void MarkNewFileRevision(const std::string &path, int retainMax) {
    xLights_Apple_core::markNewFileRevision(path, retainMax);
}

std::string GetURLForRevision(const std::string &path, const std::string &rev) {
    return xLights_Apple_core::getURLForRevision(path, rev);
}

void EnableSleepModes() {
    xLights_Apple_core::enableSleepModes();
}

void DisableSleepModes() {
    xLights_Apple_core::disableSleepModes();
}

bool IsFromAppStore() {
    return xLights_Apple_core::isFromAppStore();
}
