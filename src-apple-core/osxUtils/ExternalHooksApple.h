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

// Only meaningful from inside a catch handler; returns "" when the exception
// being handled is not an NSException.
std::string DescribeCurrentAppleException();

void SetThreadQOS(int i);

// Runs `body` inside an NSFileCoordinator replacing write of `path`, so iCloud
// Drive and other file presenters see one coordinated replace. `body` gets the
// path to write (the coordinator may hand back a different one) and a
// same-volume replacement directory outside the target's folder, or "" when
// none could be made. The directory is removed afterwards. If coordination
// itself fails, `body` runs uncoordinated.
//
// Never call this while the same thread already holds a coordinated access to
// `path` through another NSFileCoordinator: the nested request waits for the
// outer one forever.
bool CoordinatedFileReplace(const std::string& path, const std::function<bool(const std::string& target, const std::string& tempDir)>& body);

// Swaps `replacement` in for the existing `target` with
// -[NSFileManager replaceItemAtURL:...], which keeps the target's extended
// attributes, Finder tags, permissions and creation date.
bool ReplaceFileKeepingAttributes(const std::string& target, const std::string& replacement, std::string& error);

#define __XL_EXTERNAL_HOOKS__
