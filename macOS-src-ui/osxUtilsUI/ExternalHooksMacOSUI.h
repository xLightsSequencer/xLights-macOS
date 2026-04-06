#pragma once

// UI-specific macOS hooks that depend on wxWidgets types or are only
// used from the UI layer.  Core-layer code must NOT include this header.
//
// Functions like FileExists(wxString), GetAllFilesInDir, SetButtonBackground,
// AdjustColorToDeviceColorspace are declared in ui/wxUtilities.h (cross-platform)
// and implemented in xlMacUtilsCppUI.mm / ExternalHooksMacOSUI.mm on macOS.
// They are NOT re-declared here to avoid duplicate-default-argument errors.
//
// Implementations live in ExternalHooksMacOSUI.mm (compiled in the
// xLights-macOSLib-UI target).

#include "ExternalHooksApple.h"

bool IsMouseEventFromTouchpad();
bool hasFullDiskAccess();
double xlOSGetMainScreenContentScaleFactor();

#define __XL_EXTERNAL_HOOKS_UI__
