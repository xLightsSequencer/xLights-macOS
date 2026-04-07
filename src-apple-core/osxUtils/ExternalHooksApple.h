#pragma once

// Core-safe Apple platform hooks.  No wxWidgets types in the interface.
// Shared by macOS and iOS via the xLights-Apple-core target.
// UI-specific hooks live in ExternalHooksMacOSUI.h (macOS-only).
//
// Implementations live in ExternalHooksAppleCore.mm (compiled in the
// xLights-Apple-core target, which has access to the generated Swift
// interop header).  This header is pure C++ — no Swift or ObjC includes.

#include <cstdint>
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

// Returns the Metal device registry ID used by the compute effects pipeline.
// Used to force ANGLE onto the same GPU for zero-copy texture sharing.
// Returns 0 if Metal compute is not available.
uint64_t GetMetalComputeDeviceRegistryID();

#define __XL_EXTERNAL_HOOKS__
