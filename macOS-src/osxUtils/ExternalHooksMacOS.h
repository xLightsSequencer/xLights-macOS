#pragma once

#include <functional>

class wxGLCanvas;
class wxWindow;
class wxString;

/* Various touch points that the OSX builds can use to
 * setup some various advanced functionality
 */

void xlSetRetinaCanvasViewport(wxGLCanvas &win, int &x, int &y, int &x2, int&y2);
double xlTranslateToRetina(const wxWindow &win, double x);
bool ObtainAccessToURL(const std::string &path);
void EnableSleepModes();
void DisableSleepModes();
bool IsMouseEventFromTouchpad();

void AddAudioDeviceChangeListener(std::function<void()> &&callback);
void RemoveAudioDeviceChangeListener();

void AdjustColorToDeviceColorspace(const wxColor &c, uint8_t &r, uint8_t &g, uint8_t &b, uint8_t &a);
bool IsFromAppStore();

bool DoInAppPurchases(wxWindow *w);
void WXGLUnsetCurrentContext();
wxString GetOSFormattedClipboardData();
double xlOSGetMainScreenContentScaleFactor();

void RunInAutoReleasePool(std::function<void()> &&f);
#define AdjustModalDialogParent(par) par = nullptr

#define __XL_EXTERNAL_HOOKS__
