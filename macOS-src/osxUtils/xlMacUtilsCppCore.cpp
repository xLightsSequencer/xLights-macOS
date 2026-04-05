//
//  xlMacUtilsCppCore.cpp
//  xLights-macOSLib
//
//  Core-safe macOS utility implementations.  No wxWidgets dependencies.
//

#include <cstdio>
#include <fstream>
#include <mutex>
#include <string>

#include "../../xLights-macOSLib.build/DerivedSources/xLights_macOSLib-Swift.h"
#include "ExternalHooksMacOS.h"

// ---------------------------------------------------------------------------
// Legacy bookmark migration — parse the wxConfig INI file without wxWidgets.
// Format: [Section/Path] groups with Key=Base64Value entries.
// ---------------------------------------------------------------------------
static void loadLegacyBookmarks() {
    // Resolve ~/Library/Containers/org.xlights/Data/Library/Preferences/xLights-Bookmarks Preferences
    const char* home = std::getenv("HOME");
    if (!home) return;
    std::string path = std::string(home)
        + "/Library/Containers/org.xlights/Data/Library/Preferences/xLights-Bookmarks Preferences";

    std::ifstream in(path);
    if (!in.is_open()) return;

    std::string currentGroup;
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty()) continue;
        if (line.front() == '[' && line.back() == ']') {
            // Group header — becomes the path prefix
            currentGroup = line.substr(1, line.size() - 2);
        } else {
            // Key=Value entry
            auto eq = line.find('=');
            if (eq == std::string::npos) continue;
            std::string key = line.substr(0, eq);
            std::string value = line.substr(eq + 1);
            std::string fullPath = "/" + currentGroup + "/" + key;
            xLights_macOSLib::addAccessibleURL(fullPath, value);
        }
    }
}

bool ObtainAccessToURL(const std::string &path, bool enforceWritable) {
    static bool oldPrefsChecked = false;
    if (!oldPrefsChecked) {
        static std::mutex oldLock;
        std::unique_lock<std::mutex> lock(oldLock);
        if (!oldPrefsChecked) {
            loadLegacyBookmarks();
        }
        oldPrefsChecked = true;
    }
    return xLights_macOSLib::obtainAccessToURL(path, enforceWritable);
}


std::list<std::string> GetFileRevisions(const std::string &path) {
    swift::Array<swift::String> a = xLights_macOSLib::getFileRevisions(path);
    std::list<std::string> ret;
    for (int x = a.getStartIndex(); x < a.getEndIndex(); x++) {
        swift::String s = a[x];
        std::string s2 = s;
        ret.push_back(s2);
    }
    return ret;
}


extern "C" {
void AudioDeviceChangedCallback();
}

static std::function<void()> AUDIO_CALLBACK;
void AudioDeviceChangedCallback() {
    if (AUDIO_CALLBACK) {
        AUDIO_CALLBACK();
    }
}

void AddAudioDeviceChangeListener(std::function<void()> &&cb) {
    AUDIO_CALLBACK = cb;
    xLights_macOSLib::addAudioDeviceChangeListener();
}
void RemoveAudioDeviceChangeListener() {
    xLights_macOSLib::removeAudioDeviceChangeListener();
    AUDIO_CALLBACK = {};
}

void SetThreadQOS(int i) {
    if (i) {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
    } else {
        pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0);
    }
}
