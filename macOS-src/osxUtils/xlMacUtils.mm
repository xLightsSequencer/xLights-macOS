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
            NSString* dstr = [NSString stringWithUTF8String:data.c_str()];
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
            
            bool writable = true;
            bool ok = [fileURL startAccessingSecurityScopedResource];
            wxString f2 = f;
            if (wxDirExists(f) && !f.EndsWith("/")) {
                f2 += "/";
                NSString* fstr = [NSString stringWithUTF8String:f2.c_str()];
                writable = ![[NSFileManager defaultManager] isWritableFileAtPath:fstr];
            }
            if (ok && writable) {
                ACCESSIBLE_URLS.insert(f.ToStdString());
            } else {
                removes.push_back(f.ToStdString());
            }
            [nsdata release];
        } else {
            removes.push_back(f.ToStdString());
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
        grpRemoves.push_back(grp.ToStdString());
    }
}

static bool IsDirAccessible(const std::string &path, bool enforceWritable) {
    if (wxDir::Exists(path) && enforceWritable) {
        std::string p1 = path.ends_with("/") ? path : path + "/";
        NSString *nsfilePath = [NSString stringWithUTF8String:p1.c_str()];
        if (![[NSFileManager defaultManager] isWritableFileAtPath:nsfilePath]) {
            //not writable, need to remove the tokens
            ACCESSIBLE_URLS.erase(path);
            wxConfig *config = new wxConfig("xLights-Bookmarks");
            config->DeleteEntry(path, true);
            config->DeleteGroup(path);
            config->Flush();
            delete config;
            return false;
        }
    }
    return true;
}

bool ObtainAccessToURL(const std::string &path, bool enforceWritable) {
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
            return IsDirAccessible(path, enforceWritable);
        }
        NSString *nsfilePath = [NSString stringWithUTF8String:path.c_str()];
        bool exists = [[NSFileManager defaultManager] fileExistsAtPath:nsfilePath];
        if (!exists) {
            return false;
        }
        wxFileName fn(path);
        if (!fn.IsDir()) {
            wxFileName parent(fn.GetPath());
            wxString ps = parent.GetPath();
            while (ps != "" && ps != "/" && ACCESSIBLE_URLS.find(ps.ToStdString()) == ACCESSIBLE_URLS.end()) {
                parent.RemoveLastDir();
                ps = parent.GetPath();
            }

            if (ACCESSIBLE_URLS.find(ps.ToStdString()) != ACCESSIBLE_URLS.end() && IsDirAccessible(ps, enforceWritable)) {
                // file is in a directory we already have access to, don't need to record it
                ACCESSIBLE_URLS.insert(path);
                return IsDirAccessible(path, enforceWritable);
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
            
            bool write = true;
            if (wxDir::Exists(path)) {
                // don't save book marks to dirs
                std::string p1 = path.ends_with("/") ? path : path + "/";
                nsfilePath = [NSString stringWithUTF8String:p1.c_str()];
                write = [[NSFileManager defaultManager] isWritableFileAtPath:nsfilePath];
            }
            if (write) {
                const char *cstr = [base64 UTF8String];
                if (cstr != nullptr && *cstr) {
                    data = cstr;
                    config->Write(pathurl, data);
                    ACCESSIBLE_URLS.insert(pathurl);
                }
            }
        }
        delete config;

        if (data.length() > 0) {
            NSString* dstr = [NSString stringWithUTF8String:data.c_str()];
            NSData *nsdata = [[NSData alloc] initWithBase64EncodedString:dstr options:0];
            BOOL isStale = false;
        //options:(NSURLBookmarkResolutionOptions)options
        //relativeToURL:(NSURL *)relativeURL
            NSURL *fileURL = [NSURL URLByResolvingBookmarkData:nsdata
                                                 options:NSURLBookmarkResolutionWithoutUI | NSURLBookmarkResolutionWithSecurityScope
                                                 relativeToURL:nil
                                                 bookmarkDataIsStale:&isStale
                                                 error:&error];
            
            if (wxDir::Exists(path) && path.ends_with("/")) {
                std::string p1 = path + "/";
                nsfilePath = [NSString stringWithUTF8String:p1.c_str()];
            }

            if ([fileURL startAccessingSecurityScopedResource] == 0) {
                ACCESSIBLE_URLS.erase(path);
                return false;
            }
        }
        return data.length() > 0 && IsDirAccessible(path, enforceWritable);
    }
}

bool FileExists(const std::string &path, bool waitForDownload) {
    if (path.empty()) {
        return false;
    }
    @autoreleasepool {
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *nsfilePath = [NSString stringWithUTF8String:path.c_str()];
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

void MarkNewFileRevision(const std::string &path, int retainMax) {
    if (path.empty()) {
        return;
    }
    @autoreleasepool {
        NSString *nsfilePath = [NSString stringWithUTF8String:path.c_str()];
        NSURL *fileURL = [NSURL fileURLWithPath:nsfilePath];
        NSError *error = nil;
        NSFileVersion *v = [NSFileVersion addVersionOfItemAtURL:fileURL withContentsOfURL:fileURL options:0 error:&error];
        v.discardable = YES;
        
        NSArray<NSFileVersion*> *versions = [NSFileVersion otherVersionsOfItemAtURL:fileURL];
        int size = [versions count] - retainMax;
        while (size > 0) {
            size--;
            NSFileVersion *fv2 = versions[size];
            NSError *error = nil;
            [fv2 removeAndReturnError:&error];
        }
    }
}

//static std::map<std::string, NSArray<NSFileVersion *>*> remotes;
std::list<std::string> GetFileRevisions(const std::string &path) {
    std::list<std::string> ret;
    if (!path.empty()) {
        @autoreleasepool {
            NSString *nsfilePath = [NSString stringWithUTF8String:path.c_str()];
            NSURL *fileURL = [NSURL fileURLWithPath:nsfilePath];
            
            /*
            volatile bool doneRemote = false;
            NSArray<NSFileVersion*> *conflicts = [NSFileVersion unresolvedConflictVersionsOfItemAtURL:fileURL];
            for (NSFileVersion *c in conflicts) {
                c.resolved = true;
            }
            if (remotes.find(path) == remotes.end()) {
                [NSFileVersion getNonlocalVersionsOfItemAtURL:fileURL completionHandler:[&](NSArray<NSFileVersion *> * _Nullable nonlocalFileVersions, NSError * _Nullable) {
                    remotes[path] = nonlocalFileVersions;
                    [nonlocalFileVersions retain];
                    doneRemote = true;
                }];
            } else {
                doneRemote = true;
            }
            */
            
            NSArray<NSFileVersion*> *versions = [NSFileVersion otherVersionsOfItemAtURL:fileURL];
            for (NSFileVersion *fv2 in versions) {
                NSString *dateString = [NSDateFormatter localizedStringFromDate:fv2.modificationDate
                                                                      dateStyle:NSDateFormatterShortStyle
                                                                      timeStyle:NSDateFormatterLongStyle];
                std::string str = [dateString UTF8String];
                ret.push_front(str);
            }
            /*
            while (!doneRemote) {
                wxMilliSleep(10);
            }
            for (NSFileVersion *fv2 in remotes[path]) {
                NSString *dateString = [NSDateFormatter localizedStringFromDate:fv2.modificationDate
                                                                      dateStyle:NSDateFormatterShortStyle
                                                                      timeStyle:NSDateFormatterLongStyle];
                std::string str = [dateString UTF8String];
                str += " (iCloud)";
                ret.push_front(str);
            }
             */
        }
    }
    return ret;
}
std::string GetURLForRevision(const std::string &path, const std::string &rev) {
    if (!path.empty()) {
        @autoreleasepool {
            NSString *nsfilePath = [NSString stringWithUTF8String:path.c_str()];
            NSURL *fileURL = [NSURL fileURLWithPath:nsfilePath];
            
            NSArray<NSFileVersion*> *versions = [NSFileVersion otherVersionsOfItemAtURL:fileURL];
            for (NSFileVersion *fv2 in versions) {
                NSString *dateString = [NSDateFormatter localizedStringFromDate:fv2.modificationDate
                                                                      dateStyle:NSDateFormatterShortStyle
                                                                      timeStyle:NSDateFormatterLongStyle];
                
                std::string str = [dateString UTF8String];
                if (str == rev) {
                    NSFileManager *fileManager = [NSFileManager defaultManager];
                    NSError *error;
                    std::string p2 = path + "_REV_" + std::to_string(std::rand());
                    NSString *toPath = [NSString stringWithUTF8String:p2.c_str()];
                    [fileManager copyItemAtPath:[fv2.URL path] toPath:toPath error:&error];
                    return p2;
                }
            }
            /*
             //this is downloading the revision, but then creating a new local revisition with the current timestamp
             //instead of the original modifcation date which then screws up the local modifications
             //need to investigate more
            for (NSFileVersion *fv2 in remotes[path]) {
                NSString *dateString = [NSDateFormatter localizedStringFromDate:fv2.modificationDate
                                                                      dateStyle:NSDateFormatterShortStyle
                                                                      timeStyle:NSDateFormatterLongStyle];
                std::string str = [dateString UTF8String];
                str += " (iCloud)";
                if (str == rev) {
                    NSError *error;
                    std::string p2 = path + "_REV_" + std::to_string(std::rand());
                    NSString *toPath = [NSString stringWithUTF8String:p2.c_str()];
                    
                    NSFileCoordinator *fileCoordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
                    [fileCoordinator coordinateReadingItemAtURL:fv2.URL options:NSFileCoordinatorReadingWithoutChanges error:&error byAccessor:^(NSURL * _Nonnull newURL) {
                        NSError *error;
                        //[fv2 replaceItemAtURL:[NSURL fileURLWithPath:toPath] options:0 error:&error];
                        NSFileManager *fileManager = [NSFileManager defaultManager];
                        [fileManager copyItemAtPath:[newURL path] toPath:toPath error:&error];
                        remotes.erase(path);
                    }];
                    
                    //[fileManager copyItemAtPath:[fv2.URL path] toPath:toPath error:&error];
                    return p2;
                }
            }
            */
        }
    }
    return path;
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

// OpenGL is marked deprecated in OSX so we'll turn off the deprecation warnings for this file
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
void WXGLUnsetCurrentContext() {
    [NSOpenGLContext clearCurrentContext];
}
#pragma clang diagnostic pop


static const AudioObjectPropertyAddress devlist_address = {
    kAudioHardwarePropertyDevices,
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMaster
};
static const AudioObjectPropertyAddress defaultdev_address = {
    kAudioHardwarePropertyDefaultOutputDevice,
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMain
};

/* this is called when the system's list of available audio devices changes. */
static std::function<void()> AUDIO_CALLBACK;

static OSStatus device_list_changed(AudioObjectID systemObj, UInt32 num_addr, const AudioObjectPropertyAddress *addrs, void *data) {
    AUDIO_CALLBACK();
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
        
        CFDictionaryRef info;
        status = SecCodeCopySigningInformation(staticCode, kSecCSSigningInformation, &info);
        if (status != errSecSuccess) {
            return false;
        }

        CFArrayRef certChain = (CFArrayRef)CFDictionaryGetValue(info, kSecCodeInfoCertificates);
        SecCertificateRef cert = SecCertificateRef(CFArrayGetValueAtIndex(certChain, 0));
        
        CFStringRef cn;
        SecCertificateCopyCommonName(cert, &cn);
        NSString *cnnss = (NSString *)cn;
        std::string c = [cnnss UTF8String];
        if (staticCode) {
            CFRelease(staticCode);
        }
        if (!c.starts_with("Apple Mac OS") && !c.starts_with("TestFlight")) {
            return false;
        }
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


void SetButtonBackground(wxButton *b, const wxColour &c, int bgType) {
    if (c == wxTransparentColour) {
        NSButton *nsb = (NSButton*)b->GetHandle();
        [nsb setBezelStyle:NSBezelStylePush];
        [nsb setBezelColor:nil];
    } else {
        NSButton *nsb = (NSButton*)b->GetHandle();
        [nsb setBezelStyle:NSBezelStylePush];
        if (bgType == 1) {
            CGColorRef cgc = c.GetCGColor();
            [nsb setBordered:NO];
            [nsb setWantsLayer:YES];
            
            [[nsb layer] setBackgroundColor:cgc];
            [[nsb layer] setCornerRadius:6];
            [[nsb layer] setBorderWidth:1];
            [[nsb layer] setBorderColor:cgc];
        } else {
            NSColor *nsc = c.OSXGetNSColor();
            [nsb setBezelColor:nsc];
        }
    }
    b->Refresh();
}
