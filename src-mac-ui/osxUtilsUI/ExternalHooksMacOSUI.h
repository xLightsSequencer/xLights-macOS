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

// Demote the process to a non-activating background app (no Dock icon, no menu
// bar, can't steal focus). Used by --headless so a background render doesn't
// disrupt the desktop. GPU/Metal/CGL offscreen rendering is unaffected.
void SetHeadlessNoDock();

#define __XL_EXTERNAL_HOOKS_UI__
