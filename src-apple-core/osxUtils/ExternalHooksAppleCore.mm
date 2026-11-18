
// CoreGraphics types (CGImageRef etc) are referenced in the
// auto-generated `xLights_Apple_core-Swift.h` because Swift sources
// expose @objc methods with CGImage parameters (see
// AppleIntelligenceUtils.ImagesAsyncCaller). Import the framework
// here so the generated header parses cleanly.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#include "ExternalHooksApple.h"
#include <spdlog/spdlog.h>
#include "xLights_Apple_core-Swift.h"

bool FileExists(const std::string &s, bool waitForDownload) {
    return xLights_Apple_core::fileExists(s, waitForDownload);
}

void MarkNewFileRevision(const std::string &path, int retainMax) {
    xLights_Apple_core::markNewFileRevision(path, retainMax);
}

std::string GetURLForRevision(const std::string &path, const std::string &rev) {
    return xLights_Apple_core::getURLForRevision(path, rev);
}

void EnableSleepModes() {
    xLights_Apple_core::enableSleepModes();
}

void DisableSleepModes() {
    xLights_Apple_core::disableSleepModes();
}

bool IsFromAppStore() {
    return xLights_Apple_core::isFromAppStore();
}

std::string DescribeCurrentAppleException() {
    // Must be called from inside a catch handler; the rethrow recovers the type.
    // An NSException raised by Cocoa/AVFoundation/Metal unwinds as a plain
    // ObjC pointer, so a C++-only handler can only report it as "unknown".
    try {
        throw;
    } catch (NSException *e) {
        std::string res = "Objective-C exception \"";
        res += (e.name != nil) ? e.name.UTF8String : "(no name)";
        res += "\": \"";
        res += (e.reason != nil) ? e.reason.UTF8String : "(no reason)";
        res += "\".";
        NSArray<NSString *> *frames = e.callStackSymbols;
        if (frames.count > 0) {
            res += " Raised at:";
            for (NSUInteger i = 0; i < frames.count && i < 12; ++i) {
                res += "\n    ";
                res += frames[i].UTF8String;
            }
        }
        return res;
    } catch (...) {
        return "";
    }
}

namespace {
NSURL* FileURLFor(const std::string& path) {
    NSString* s = [NSString stringWithUTF8String:path.c_str()];
    return s ? [NSURL fileURLWithPath:s] : nil;
}

std::string DescribeFileError(NSError* err) {
    if (err == nil) {
        return "unknown error";
    }
    const char* d = err.localizedDescription.UTF8String;
    return d ? std::string(d) : std::string("unknown error");
}
} // namespace

bool CoordinatedFileReplace(const std::string& path, const std::function<bool(const std::string& target, const std::string& tempDir)>& body) {
    NSURL* url = FileURLFor(path);
    if (url == nil) {
        return body(path, "");
    }

    __block bool result = false;
    __block bool ran = false;
    void (^accessor)(NSURL*) = ^(NSURL* newURL) {
        ran = true;
        NSURL* dest = newURL ?: url;
        NSFileManager* fm = [NSFileManager defaultManager];
        NSError* dirErr = nil;
        NSURL* dir = [fm URLForDirectory:NSItemReplacementDirectory
                                inDomain:NSUserDomainMask
                       appropriateForURL:dest
                                  create:YES
                                   error:&dirErr];
        if (dir == nil) {
            spdlog::debug("ShowFileGuard: no replacement directory for '{}' ({})", path, DescribeFileError(dirErr));
        }
        const char* destPath = dest.path.fileSystemRepresentation;
        const char* dirPath = dir ? dir.path.fileSystemRepresentation : nullptr;
        result = body(destPath ? std::string(destPath) : path, dirPath ? std::string(dirPath) : std::string());
        if (dir != nil) {
            [fm removeItemAtURL:dir error:nil];
        }
    };

    NSFileCoordinator* coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    NSError* coordErr = nil;
    [coordinator coordinateWritingItemAtURL:url
                                    options:NSFileCoordinatorWritingForReplacing
                                      error:&coordErr
                                 byAccessor:accessor];
    if (!ran) {
        spdlog::warn("ShowFileGuard: could not coordinate writing '{}' ({}); writing it uncoordinated", path, DescribeFileError(coordErr));
        accessor(url);
    }
    return result;
}

bool ReplaceFileKeepingAttributes(const std::string& target, const std::string& replacement, std::string& error) {
    NSURL* t = FileURLFor(target);
    NSURL* r = FileURLFor(replacement);
    if (t == nil || r == nil) {
        error = "path is not valid UTF-8";
        return false;
    }
    NSError* err = nil;
    NSURL* resulting = nil;
    if ([[NSFileManager defaultManager] replaceItemAtURL:t
                                           withItemAtURL:r
                                          backupItemName:nil
                                                 options:0
                                        resultingItemURL:&resulting
                                                   error:&err]) {
        return true;
    }
    error = DescribeFileError(err);
    return false;
}

