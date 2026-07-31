
// CoreGraphics types (CGImageRef etc) are referenced in the
// auto-generated `xLights_Apple_core-Swift.h` because Swift sources
// expose @objc methods with CGImage parameters (see
// AppleIntelligenceUtils.ImagesAsyncCaller). Import the framework
// here so the generated header parses cleanly.
#import <CoreGraphics/CoreGraphics.h>

#include "ExternalHooksApple.h"
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

