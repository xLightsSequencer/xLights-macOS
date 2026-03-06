
#include "../../xLights-macOSLib.build/DerivedSources/xLights_macOSLib-Swift.h"
#include "ExternalHooksMacOS.h"



void AdjustColorToDeviceColorspace(const wxColor &c, uint8_t &r, uint8_t &g, uint8_t &b, uint8_t &a) {
    uint32_t ret = xLights_macOSLib::adjustColorToDeviceColorspace(c.OSXGetNSColor());
    a = (ret >> 24) & 0xFF;
    r = (ret >> 16) & 0xFF;
    g = (ret >> 8) & 0xFF;
    b = ret & 0xFF;
}


void SetButtonBackground(wxButton *b, const wxColour &c, int bgType) {
    xLights_macOSLib::setButtonBackground((NSButton*)(b->GetHandle()), c.OSXGetNSColor(), c == wxTransparentColor, bgType);
}
