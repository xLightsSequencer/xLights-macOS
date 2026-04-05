#pragma once

// UI-specific macOS hooks that depend on wxWidgets types or are only
// used from the UI layer.  Core-layer code must NOT include this header.
//
// Functions like FileExists(wxString), GetAllFilesInDir, SetButtonBackground,
// AdjustColorToDeviceColorspace are declared in ui/wxUtilities.h (cross-platform)
// and implemented in xlMacUtilsCppUI.cpp / ExternalHooksMacOS.mm on macOS.
// They are NOT re-declared here to avoid duplicate-default-argument errors.

#include "ExternalHooksMacOS.h"

inline bool IsMouseEventFromTouchpad() {
    return xLights_macOSLib::isMouseEventFromTouchpad();
}

inline bool hasFullDiskAccess() {
    return xLights_macOSLib::hasFullDiskAccess();
}

inline double xlOSGetMainScreenContentScaleFactor() {
    return xLights_macOSLib::xlOSGetMainScreenContentScaleFactor();
}


#define __XL_EXTERNAL_HOOKS_UI__
