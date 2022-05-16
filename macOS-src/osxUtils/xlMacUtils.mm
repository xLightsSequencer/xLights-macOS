//
//  xlMacUtils.m
//  xLights
//
//

#import <Foundation/Foundation.h>
#include <Cocoa/Cocoa.h>
#import <AppKit/NSOpenGL.h>
#import <AppKit/NSOpenGLView.h>

#include <wx/config.h>
#include <wx/menu.h>
#include <wx/colour.h>
#include <wx/app.h>
#include <wx/glcanvas.h>
#include <wx/button.h>
#include <wx/dir.h>

#include <list>
#include <set>
#include <mutex>
#include <functional>
#include <thread>
#include <chrono>

#include <CoreAudio/CoreAudio.h>
#include <CoreServices/CoreServices.h>

#include "ExternalHooksMacOS.h"

static std::set<std::string> ACCESSIBLE_URLS;
static std::mutex URL_LOCK;
static int OSX_STATUS = -1;
static uint64_t OPTIONFLAGS = 0;

static void LoadGroupEntries(wxConfig *config, const wxString &grp, std::list<std::string> &removes, std::list<std::string> &grpRemoves) {
    wxString ent;
    long index = 0;
    bool cont = config->GetFirstEntry(ent, index);
    bool hasItem = false;
    while (cont) {
        hasItem = true;
        wxString f = grp + ent;
        if (wxFileExists(f) || wxDirExists(f)) {
            wxString data = config->Read(ent);
            NSString* dstr = [NSString stringWithCString:data.c_str()
                                                    encoding:[NSString defaultCStringEncoding]];
            NSData *nsdata = [[NSData alloc] initWithBase64EncodedString:dstr options:0];
            BOOL isStale = false;
            //options:(NSURLBookmarkResolutionOptions)options
            //relativeToURL:(NSURL *)relativeURL
            NSError *error;
            NSURL *fileURL = [NSURL URLByResolvingBookmarkData:nsdata
                                                     options:NSURLBookmarkResolutionWithoutUI | NSURLBookmarkResolutionWithSecurityScope
                                                     relativeToURL:nil
                                                     bookmarkDataIsStale:&isStale
                                                     error:&error];
            bool ok = [fileURL startAccessingSecurityScopedResource];
            if (ok) {
                ACCESSIBLE_URLS.insert(f);
            } else {
                removes.push_back(f);
            }
            [nsdata release];
        } else {
            removes.push_back(f);
        }
        cont = config->GetNextEntry(ent, index);
    }
    index = 0;
    ent = "";
    cont = config->GetFirstGroup(ent, index);
    while (cont) {
        hasItem = true;
        wxString p = config->GetPath();
        config->SetPath(ent + "/");
        LoadGroupEntries(config, p + "/" + ent + "/", removes, grpRemoves);
        config->SetPath(p);
        cont = config->GetNextGroup(ent, index);
    }
    if (!hasItem) {
        grpRemoves.push_back(grp);
    }
}

bool ObtainAccessToURL(const std::string &path) {
    if ("" == path) {
        return true;
    }
    std::unique_lock<std::mutex> lock(URL_LOCK);
    @autoreleasepool {
        if (ACCESSIBLE_URLS.empty()) {
            std::list<std::string> removes;
            std::list<std::string> grpRemoves;
            wxConfig *config = new wxConfig("xLights-Bookmarks");
            LoadGroupEntries(config, "/", removes, grpRemoves);
            if (!removes.empty() || !grpRemoves.empty()) {
                for (auto &a : removes) {
                    if (a.rfind("/Volumes/", 0) != 0) {
                        // don't remove entries that start with /Volumes as its likely just an SD card
                        // that isn't mounted right now.   It might be there later
                        config->DeleteEntry(a, true);
                    }
                }
                for (auto &a : grpRemoves) {
                    config->DeleteGroup(a);
                }
                config->Flush();
            }
            delete config;
        }
        if (ACCESSIBLE_URLS.find(path) != ACCESSIBLE_URLS.end()) {
            return true;
        }
        NSString *nsfilePath = [NSString stringWithCString:path.c_str()
                                                encoding:[NSString defaultCStringEncoding]];
        bool exists = [[NSFileManager defaultManager] fileExistsAtPath:nsfilePath];
        if (!exists) {
            return false;
        }
        wxFileName fn(path);
        if (!fn.IsDir()) {
            wxFileName parent(fn.GetPath());
            wxString ps = parent.GetPath();
            while (ps != "" && ps != "/" && ACCESSIBLE_URLS.find(ps) == ACCESSIBLE_URLS.end()) {
                parent.RemoveLastDir();
                ps = parent.GetPath();
            }

            if (ACCESSIBLE_URLS.find(ps) != ACCESSIBLE_URLS.end()) {
                // file is in a directory we already have access to, don't need to record it
                ACCESSIBLE_URLS.insert(path);
                return true;
            }
        }

        std::string pathurl = path;
        wxConfig *config = new wxConfig("xLights-Bookmarks");
        wxString data = config->Read(pathurl);
        NSError *error = nil;
        if ("" == data) {
            NSURL *fileURL = [NSURL fileURLWithPath:nsfilePath];

            NSData * newData = [fileURL bookmarkDataWithOptions: NSURLBookmarkCreationWithSecurityScope
                                 includingResourceValuesForKeys: nil
                                                  relativeToURL: nil
                                                          error: &error];
            NSString *base64 = [newData base64EncodedStringWithOptions:0];
            const char *cstr = [base64 UTF8String];
            if (cstr != nullptr && *cstr) {
                data = cstr;
                config->Write(pathurl, data);
                ACCESSIBLE_URLS.insert(pathurl);
            }
        }

        if (data.length() > 0) {
            NSString* dstr = [NSString stringWithCString:data.c_str()
                                                encoding:[NSString defaultCStringEncoding]];
            NSData *nsdata = [[NSData alloc] initWithBase64EncodedString:dstr options:0];
            BOOL isStale = false;
        //options:(NSURLBookmarkResolutionOptions)options
        //relativeToURL:(NSURL *)relativeURL
            NSURL *fileURL = [NSURL URLByResolvingBookmarkData:nsdata
                                                 options:NSURLBookmarkResolutionWithoutUI | NSURLBookmarkResolutionWithSecurityScope
                                                 relativeToURL:nil
                                                 bookmarkDataIsStale:&isStale
                                                 error:&error];
            [fileURL startAccessingSecurityScopedResource];
        }
        delete config;
        return data.length() > 0;
    }
}

bool FileExists(const std::string &path, bool waitForDownload) {
    @autoreleasepool {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *nsfilePath = [NSString stringWithCString:path.c_str()
                                                encoding:[NSString defaultCStringEncoding]];
        bool exists = [fileManager fileExistsAtPath:nsfilePath];
        if (!exists) {
            NSURL *fileURL = [NSURL fileURLWithPath:nsfilePath];
            exists = [fileManager isUbiquitousItemAtURL:fileURL];
            if (exists) {
                //doesn't actually exist locally, but does exist in the cloud, trigger a download and wait
                exists = [fileManager startDownloadingUbiquitousItemAtURL:fileURL error:nil];
                if (exists && waitForDownload) {
                    //download started OK
                    //NSMetadataUbiquitousItemDownloadingStatusKey
                    NSString *value = nil;
                    NSError *error = nil;
                    [fileURL getResourceValue:&value forKey:NSURLUbiquitousItemDownloadingStatusKey error:&error];
                    int count = 0;
                    while (![value isEqualToString:NSURLUbiquitousItemDownloadingStatusCurrent] && (count < 6000)) {
                        std::this_thread::sleep_for(std::chrono::milliseconds(10));
                        count++;
                        fileURL = [NSURL fileURLWithPath:nsfilePath];
                        [fileURL getResourceValue:&value forKey:NSURLUbiquitousItemDownloadingStatusKey error:&error];
                    }
                    exists = [fileManager fileExistsAtPath:nsfilePath];
                }
            }
        }

        return exists;
    }
}
bool FileExists(const wxFileName &fn, bool waitForDownload) {
   return FileExists(fn.GetFullPath().ToStdString(), waitForDownload);
}
bool FileExists(const wxString &s, bool waitForDownload) {
    return FileExists(s.ToStdString(), waitForDownload);
}

static bool endsWith(const wxString &str, const wxString &suffix) {
    return str.size() >= suffix.size() && 0 == str.compare(str.size()-suffix.size(), suffix.size(), suffix);
}
void GetAllFilesInDir(const wxString &dir, wxArrayString &files, const wxString &filespec, int flags) {
    if (flags == -1) {
        flags = wxDIR_FILES;
    }
    flags |= wxDIR_HIDDEN;
    static std::string iCloudExt = ".icloud";
    wxArrayString f2;
    std::set<wxString> allFiles;
    wxDir::GetAllFiles(dir, &f2, filespec, flags);
    if (filespec != "") {
        wxDir::GetAllFiles(dir, &f2, filespec + iCloudExt, flags);
    }
    for (auto &a : f2) {
        // this will remove duplicates that match both ext
        allFiles.insert(a);
    }
    for (auto &f : allFiles) {
        if (endsWith(f, iCloudExt)) {
            int pos = f.find_last_of('/');
            wxString n = f.substr(0, pos + 1);
            n += f.substr(pos + 2, f.size() - 9 - pos);
            files.push_back(n);
        } else {
            files.push_back(f);
        }
    }
}



double xlOSGetMainScreenContentScaleFactor()
{
    double displayScale = 1.0;
    NSArray *screens = [NSScreen screens];
    for (int i = 0; i < [screens count]; i++) {
        float s = [[screens objectAtIndex:i] backingScaleFactor];
        if (s > displayScale)
            displayScale = s;
    }
    return displayScale;
}

class xlOSXEffectiveAppearanceSetter
{
public:
    xlOSXEffectiveAppearanceSetter() {
        formerAppearance = NSAppearance.currentAppearance;
        NSAppearance.currentAppearance = NSApp.effectiveAppearance;
    }
    ~xlOSXEffectiveAppearanceSetter() {
        NSAppearance.currentAppearance = formerAppearance;
    }
private:
    NSAppearance *formerAppearance = nil;
};

void AdjustColorToDeviceColorspace(const wxColor &c, uint8_t &r1, uint8_t &g1, uint8_t &b1, uint8_t &a1) {
    xlOSXEffectiveAppearanceSetter helper;
    NSColor *nc = c.OSXGetNSColor();
    NSColor *ncrgbd = [nc colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
    if (ncrgbd != nil) {

        float r = [ncrgbd redComponent] * 255;
        float g = [ncrgbd greenComponent] * 255;
        float b = [ncrgbd blueComponent] * 255;
        float a = [ncrgbd alphaComponent] * 255;

        r1 = r;
        g1 = g;
        b1 = b;
        a1 = a;
    } else {
        r1 = c.Red();
        g1 = c.Green();
        b1 = c.Blue();
        a1 = c.Alpha();
    }
}

void xlSetRetinaCanvasViewport(wxGLCanvas &win, int &x, int &y, int &x2, int&y2) {
    NSOpenGLView *glView = (NSOpenGLView*)win.GetHandle();
    
    NSPoint pt;
    pt.x = x;
    pt.y = y;
    NSPoint pt2 = [glView convertPointToBacking: pt];
    x = pt2.x;
    y = pt2.y;
    
    pt.x = x2;
    pt.y = y2;
    pt2 = [glView convertPointToBacking: pt];
    x2 = pt2.x;
    y2 = pt2.y;
}

double xlTranslateToRetina(const wxWindow &win, double x) {
    NSView *view = (NSView*)win.GetHandle();
    NSSize pt;
    pt.width = x;
    pt.height = 0;
    NSSize pt2 = [view convertSizeToBacking: pt];
    return pt2.width;
}

bool IsMouseEventFromTouchpad() {
    NSEvent *theEvent = (__bridge NSEvent*)wxTheApp->MacGetCurrentEvent();
    return (([theEvent momentumPhase] != NSEventPhaseNone) || ([theEvent phase] != NSEventPhaseNone));
}

class AppNapSuspender {
public:
    AppNapSuspender() : isSuspended(false), activityId(nullptr) {}
    ~AppNapSuspender() {}
    
    void suspend() {
        if (!isSuspended) {
            activityId = [[[NSProcessInfo processInfo ] beginActivityWithOptions: OPTIONFLAGS
                                                                            reason:@"Outputting to lights"] retain];
            isSuspended = true;
        }
    }
    void resume() {
        if (isSuspended) {
            [[NSProcessInfo processInfo ] endActivity:activityId];
            [activityId release];
            activityId = nullptr;
            isSuspended = false;
        }
    }
private:
    id<NSObject> activityId;
    bool isSuspended;
};

static AppNapSuspender sleepData;
void EnableSleepModes()
{
    sleepData.resume();
}
void DisableSleepModes()
{
    sleepData.suspend();
}

wxString GetOSFormattedClipboardData() {

    NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
    NSArray *classArray = [NSArray arrayWithObject:[NSString class]];
    NSDictionary *options = [NSDictionary dictionary];
    
    BOOL ok = [pasteboard canReadObjectForClasses:classArray options:options];
    if (ok) {
        NSArray *objectsToPaste = [pasteboard readObjectsForClasses:classArray options:options];
        NSString *dts = [objectsToPaste objectAtIndex:0];
        return wxString([dts UTF8String], wxConvUTF8);
    }
    return "";
}

void WXGLUnsetCurrentContext() {
    [NSOpenGLContext clearCurrentContext];
}

static const AudioObjectPropertyAddress devlist_address = {
    kAudioHardwarePropertyDevices,
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMaster
};
static const AudioObjectPropertyAddress defaultdev_address = {
    kAudioHardwarePropertyDefaultOutputDevice,
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMaster
};

/* this is called when the system's list of available audio devices changes. */
static std::function<void()> AUDIO_CALLBACK;

static OSStatus device_list_changed(AudioObjectID systemObj, UInt32 num_addr, const AudioObjectPropertyAddress *addrs, void *data) {
    wxTheApp->CallAfter([]() {AUDIO_CALLBACK();});
    return 0;
}
void AddAudioDeviceChangeListener(std::function<void()> &&cb) {
    AUDIO_CALLBACK = cb;
    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &devlist_address, device_list_changed, &AUDIO_CALLBACK);
    AudioObjectAddPropertyListener(kAudioObjectSystemObject, &defaultdev_address, device_list_changed, &AUDIO_CALLBACK);
}
void RemoveAudioDeviceChangeListener() {
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &devlist_address, device_list_changed, &AUDIO_CALLBACK);
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &defaultdev_address, device_list_changed, &AUDIO_CALLBACK);
}

bool IsFromAppStore() {
    if (OSX_STATUS == -1)  {
        OSX_STATUS = 0;
        NSURL *bundleURL = [[NSBundle mainBundle] bundleURL];
           
        SecStaticCodeRef staticCode = NULL;
        OSStatus status = SecStaticCodeCreateWithPath((__bridge CFURLRef)bundleURL, kSecCSDefaultFlags, &staticCode);
        if (status != errSecSuccess) {
            return false;
        }
        NSString *requirementText = @"anchor apple generic";   // For code signed by Apple
        SecRequirementRef requirement = NULL;
        status = SecRequirementCreateWithString((__bridge CFStringRef)requirementText, kSecCSDefaultFlags, &requirement);
        if (status != errSecSuccess) {
            if (staticCode) {
                CFRelease(staticCode);
            }
            return false;
        }
        
        status = SecStaticCodeCheckValidity(staticCode, kSecCSDefaultFlags, requirement);
        if (status != errSecSuccess) {
            if (staticCode) {
                CFRelease(staticCode);
            }
            if (requirement) {
                CFRelease(requirement);
            }
            return false;
        }
        if (staticCode) CFRelease(staticCode);
        if (requirement) CFRelease(requirement);
        OPTIONFLAGS = NSActivityLatencyCritical | NSActivityUserInitiated;
        OSX_STATUS = 1;
    }
    return OSX_STATUS == 1;
}


void RunInAutoReleasePool(std::function<void()> &&f) {
    @autoreleasepool {
        f();
    }
}
void SetThreadQOS(int i) {
    if (i) {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
    } else {
        pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0);
    }
}



static NSColor *GetColorForButtonBg(int i) {
    if (i == 2) {
        return [NSColor windowBackgroundColor]; // Preview Save Button
    }
    if (wxSystemSettings::GetAppearance().IsDark()) {
        if (i == 0) {
            //Controller tab save button
            NSColor *c = [[NSColor unemphasizedSelectedContentBackgroundColor] colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
            c = [NSColor colorWithHue:[c hueComponent]
                           saturation:[c saturationComponent]
                           brightness:[c brightnessComponent] * 0.80
                                alpha:1.0];
            return c;
        } else if (i == 1) {
            return [NSColor underPageBackgroundColor]; // Color manager buttons
        }
    }
    if (i == 0) {
        //Controller tab save button
        NSColor *c = [[NSColor windowBackgroundColor] colorUsingColorSpace:[NSColorSpace deviceRGBColorSpace]];
        c = [NSColor colorWithHue:[c hueComponent]
                       saturation:[c saturationComponent]
                       brightness:[c brightnessComponent] * 0.97
                            alpha:1.0];
        return c;
    }
    return [NSColor windowBackgroundColor]; // Color manager buttons

}

void SetButtonBackground(wxButton *b, const wxColour &c, int bgType) {
    CGColorRef nsc = c.GetCGColor();
    b->SetBackgroundColour(c);
    if (c == wxTransparentColour) {
        NSButton *nsb = (NSButton*)b->GetHandle();
        [nsb setBordered:YES];
        [nsb setWantsLayer:YES];
        [nsb setBezelStyle:NSBezelStyleRounded];
        [[nsb layer] setBackgroundColor:nsc];
        
        [[nsb layer] setCornerRadius:0];
        [[nsb layer] setBorderWidth:0];
        [[nsb layer] setBorderColor:wxTransparentColor.GetCGColor()];
    } else {
        NSButton *nsb = (NSButton*)b->GetHandle();
        [nsb setBordered:NO];
        [nsb setWantsLayer:YES];
        [nsb setBezelStyle:NSBezelStyleRounded];
        [[nsb layer] setBackgroundColor:nsc];
        [[nsb layer] setCornerRadius:10];
        [[nsb layer] setBorderWidth:6];
        [[nsb layer] setBorderColor:[GetColorForButtonBg(bgType) CGColor]];
    }
    b->Refresh();
}
