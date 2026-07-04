
#include "ExternalHooksMacOSUI.h"

#import <AppKit/AppKit.h>
#include "xLights_macOSLib_UI-Swift.h"

#include <wx/colour.h>
#include <wx/button.h>
#include <wx/window.h>

bool IsMouseEventFromTouchpad() {
    return xLights_macOSLib_UI::isMouseEventFromTouchpad();
}

bool hasFullDiskAccess() {
    return xLights_macOSLib_UI::hasFullDiskAccess();
}

double xlOSGetMainScreenContentScaleFactor() {
    return xLights_macOSLib_UI::xlOSGetMainScreenContentScaleFactor();
}

void SetHeadlessNoDock() {
    @autoreleasepool {
        // Accessory (not Prohibited) demotes to a background app with no Dock
        // icon / menu bar while still allowing offscreen render work. AppKit
        // reliably honors Regular -> Accessory at runtime; Regular -> Prohibited
        // is often rejected once the process has launched, leaving the Dock icon.
        [NSApplication.sharedApplication setActivationPolicy:NSApplicationActivationPolicyAccessory];
    }
}

void AdjustColorToDeviceColorspace(const wxColor &c, uint8_t &r, uint8_t &g, uint8_t &b, uint8_t &a) {
    uint32_t ret = xLights_macOSLib_UI::adjustColorToDeviceColorspace(c.OSXGetNSColor());
    a = (ret >> 24) & 0xFF;
    r = (ret >> 16) & 0xFF;
    g = (ret >> 8) & 0xFF;
    b = ret & 0xFF;
}

void SetButtonBackground(wxButton *b, const wxColour &c, int bgType) {
    xLights_macOSLib_UI::setButtonBackground((NSButton*)(b->GetHandle()), c.OSXGetNSColor(), c == wxTransparentColor, bgType);
}
