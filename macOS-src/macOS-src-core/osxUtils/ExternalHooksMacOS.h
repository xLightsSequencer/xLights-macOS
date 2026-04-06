#pragma once

// Core-safe macOS hooks.  No wxWidgets types in the interface.
// UI-specific hooks live in ExternalHooksMacOSUI.h.
//
// Implementations live in ExternalHooksMacOSCore.mm (compiled in the
// xLights-macOSLib-core target, which has access to the generated Swift
// interop header).  This header is pure C++ — no Swift or ObjC includes.

#include <functional>
#include <string>
#include <list>

bool ObtainAccessToURL(const std::string &path, bool enforceWritable = false);
bool FileExists(const std::string &s, bool waitForDownload = true);
void MarkNewFileRevision(const std::string &path, int retainMax = 15);
std::list<std::string> GetFileRevisions(const std::string &path);
std::string GetURLForRevision(const std::string &path, const std::string &rev);
void EnableSleepModes();
void DisableSleepModes();
bool IsFromAppStore();

void RunInAutoReleasePool(std::function<void()> &&f);
void SetThreadQOS(int i);

#define __XL_EXTERNAL_HOOKS__
