#pragma once

#include <functional>

#include "../../xLights-macOSLib.build/DerivedSources/xLights_macOSLib-Swift.h"
#include <wx/osx/core/private.h>

class wxGLCanvas;
class wxWindow;
class wxString;
class wxFileName;
class wxColor;
class wxArrayString;
class wxButton;
class wxColour;

/* Various touch points that the OSX builds can use to
 * setup some various advanced functionality
 */

bool ObtainAccessToURL(const std::string &path, bool enforceWritable = false);

inline bool FileExists(const std::string &s, bool waitForDownload = true) {
    return xLights_macOSLib::fileExists(s, waitForDownload);
}

inline bool FileExists(const wxFileName &fn, bool waitForDownload = true) {
    return FileExists(fn.GetFullPath().ToStdString(), waitForDownload);
}
inline bool FileExists(const wxString &s, bool waitForDownload = true) {
    return FileExists(s.ToStdString(), waitForDownload);
}
void GetAllFilesInDir(const wxString &dir, wxArrayString &filesOut, const wxString &filespec, int flags = -1);

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

void AddAudioDeviceChangeListener(std::function<void()> &&callback);
void RemoveAudioDeviceChangeListener();

inline void AdjustColorToDeviceColorspace(const wxColor &c, uint8_t &r, uint8_t &g, uint8_t &b, uint8_t &a) {
    uint32_t ret = xLights_macOSLib::adjustColorToDeviceColorspace(c.OSXGetNSColor());
    a = (ret >> 24) & 0xFF;
    r = (ret >> 16) & 0xFF;
    g = (ret >> 8) & 0xFF;
    b = ret & 0xFF;
}

inline bool IsFromAppStore() {
    return xLights_macOSLib::isFromAppStore();
}

bool DoInAppPurchases(wxWindow *w);
inline wxString GetOSFormattedClipboardData() {
    std::string s = xLights_macOSLib::getOSFormattedClipboardData();
    return wxString(s);
}
inline double xlOSGetMainScreenContentScaleFactor() {
    return xLights_macOSLib::xlOSGetMainScreenContentScaleFactor();
}

inline void RunInAutoReleasePool(std::function<void()> &&f) {
    wxMacAutoreleasePool pool;
    f();
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
inline void WXGLUnsetCurrentContext() {
    xLights_macOSLib::WXGLUnsetCurrentContext();
}
#pragma clang diagnostic pop

#define AdjustModalDialogParent(par) par = nullptr

inline void SetThreadQOS(int i) {
    xLights_macOSLib::setThreadQOS(i);
}
inline void SetButtonBackground(wxButton *b, const wxColour &c, int bgType = 0) {
    xLights_macOSLib::setButtonBackground((NSButton*)(b->GetHandle()), c.OSXGetNSColor(), c == wxTransparentColor, bgType);
}



#define __XL_EXTERNAL_HOOKS__
