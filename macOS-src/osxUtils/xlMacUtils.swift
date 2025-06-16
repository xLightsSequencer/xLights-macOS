//
//  xlMacUtils.swift
//  xLights
//
//

import Foundation
import AppKit
import CoreAudio
import CoreServices
import Security

// MARK: - Global Variables

@globalActor
actor xLightsUtilsActor {
    static let shared = xLightsUtilsActor()
};

@xLightsUtilsActor
class xLightsUtilsState {
    static let shared = xLightsUtilsState()
    
    func addAccessibleURL(path: String, data: String) -> Void {
        let cv = config.string(forKey: path);
        if (cv == nil) {
            config.set(data, forKey: path);
        }
    }
    
    let config = UserDefaults(suiteName: "xLights-Bookmarks") ?? UserDefaults.standard
    
    // Application from app store or not?
    var osxStatus = -1
    var optionFlags: ProcessInfo.ActivityOptions = []
};

// MARK: - Utility Functions
@xLightsUtilsActor
private func isDirAccessible(_ path: String, enforceWritable: Bool) -> Bool {
    if FileManager.default.fileExists(atPath: path) && enforceWritable {
        let pathToCheck = path.hasSuffix("/") ? path : path + "/"
        if !FileManager.default.isWritableFile(atPath: pathToCheck) {
            // Not writable, need to remove the tokens
            xLightsUtilsState.shared.config.removeObject(forKey: path)
            return false
        }
    }
    return true
}

@xLightsUtilsActor
private func obtainAccessToURLInternal(_ path: String, enforceWritable: Bool) -> Bool {
    if path.isEmpty {
        return true
    }
    let val = xLightsUtilsState.shared.config.string(forKey: path);
    if val != nil {
        let bookmarkData = Data(base64Encoded: val!)
        var isStale = false
        do {
             let resolvedURL = try URL(resolvingBookmarkData: bookmarkData!,
                                     options: [.withoutUI, .withSecurityScope],
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &isStale)
             
             if !resolvedURL.startAccessingSecurityScopedResource() {
                 xLightsUtilsState.shared.config.removeObject(forKey: path);
                 return false;
             }
         } catch {
             xLightsUtilsState.shared.config.removeObject(forKey: path);
             return false
         }
        
        return isDirAccessible(path, enforceWritable: enforceWritable)
    }
    
    if !FileManager.default.fileExists(atPath: path) {
        return false
    }
    
    let url = URL(fileURLWithPath: path)
    // Create new bookmark
    do {
        let bookmarkData = try url.bookmarkData(options: .withSecurityScope,
                                              includingResourceValuesForKeys: nil,
                                              relativeTo: nil)
        let base64String = bookmarkData.base64EncodedString()
        
        var shouldSave = true
        if url.hasDirectoryPath {
            let pathToCheck = path.hasSuffix("/") ? path : path + "/"
            shouldSave = FileManager.default.isWritableFile(atPath: pathToCheck)
        }
        
        if shouldSave && !base64String.isEmpty {
            xLightsUtilsState.shared.config.set(base64String, forKey: path)
        }
        
        return isDirAccessible(path, enforceWritable: enforceWritable)
    } catch {
        return false
    }
}
// MARK: - Public Functions
public func obtainAccessToURL(_ path: String, enforceWritable: Bool)  -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Bool = false
    Task {
        defer {
            semaphore.signal()
        }
        result = await obtainAccessToURLInternal(path, enforceWritable: enforceWritable);
    }
    semaphore.wait()
    return result;
}
public func addAccessibleURL(path: String, data: String) -> Void {
    Task {
        await xLightsUtilsState.shared.addAccessibleURL(path: path, data: data);
    }
}

public func fileExists(_ path: String, waitForDownload: Bool) -> Bool {
    if path.isEmpty {
        return false
    }
    
    let fileManager = FileManager.default
    let url = URL(fileURLWithPath: path)
    
    var exists = fileManager.fileExists(atPath: path)
    if (exists && fileManager.isUbiquitousItem(at: url)) {
        var status: AnyObject?
        try? (url as NSURL).getResourceValue(&status, forKey: .ubiquitousItemDownloadingStatusKey)
        if (status as? URLUbiquitousItemDownloadingStatus) != URLUbiquitousItemDownloadingStatus.current {
            exists = false;
        }
    }
    
    
    if !exists {
        do {
            var isUbiquitous: AnyObject?
            try (url as NSURL).getResourceValue(&isUbiquitous, forKey: .ubiquitousItemDownloadingStatusKey)
            
            if isUbiquitous != nil {
                exists = true
                if waitForDownload {
                    try fileManager.startDownloadingUbiquitousItem(at: url)
                    
                    var downloadStatus: URLUbiquitousItemDownloadingStatus?
                    var count = 0
                    
                    repeat {
                        Thread.sleep(forTimeInterval: 0.01)
                        count += 1
                        
                        var status: AnyObject?
                        let newurl = URL(fileURLWithPath: path)
                        try? (newurl as NSURL).getResourceValue(&status, forKey: .ubiquitousItemDownloadingStatusKey)
                        downloadStatus = status as? URLUbiquitousItemDownloadingStatus
                        
                    } while downloadStatus != .current && count < 6000
                    
                    exists = fileManager.fileExists(atPath: path)
                }
            }
        } catch {
            // Handle error if needed
        }
    }
    
    return exists
}

public func markNewFileRevision(_ path: String, retainMax: Int) {
    if path.isEmpty { return }
    
    autoreleasepool {
        let url = URL(fileURLWithPath: path)
        do {
            let version = try NSFileVersion.addOfItem(at: url, withContentsOf: url, options: [])
            version.isDiscardable = true
            
            let versions = NSFileVersion.otherVersionsOfItem(at: url)
            let versionsToRemove = max(0, (versions?.count ?? 10) - retainMax)
            
            for i in 0..<versionsToRemove {
                try versions?[i].remove()
            }
        } catch {
            // Handle error if needed
        }
    }
}

public func getFileRevisions(_ path: String) -> [String] {
    var revisions: [String] = []
    
    if !path.isEmpty {
        autoreleasepool {
            let url = URL(fileURLWithPath: path)

            let versions = NSFileVersion.otherVersionsOfItem(at: url)
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .short
            dateFormatter.timeStyle = .long
            
            for version in versions! {
                let dateString = dateFormatter.string(from: version.modificationDate!);
                revisions.insert(String(data: dateString.data(using: .utf8)!,  encoding: .utf8)!, at: 0)
            }
        }
    }
    
    return revisions
}

public func getURLForRevision(_ path: String, revision: String) -> String {
    if !path.isEmpty {
        let url = URL(fileURLWithPath: path)
        do {
            let versions = NSFileVersion.otherVersionsOfItem(at: url)
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .short
            dateFormatter.timeStyle = .long
            
            for version in versions! {
                let dateString = dateFormatter.string(from: version.modificationDate!)
                if dateString == revision {
                    let tempPath = path + "_REV_" + String(Int.random(in: 0...Int.max))
                    do {
                        try FileManager.default.copyItem(at: version.url, to: URL(fileURLWithPath: tempPath))
                    } catch {
                        // handle error
                    }
                    return tempPath
                }
            }
        }
    }
    
    return path
}

public func xlOSGetMainScreenContentScaleFactor() -> Double {
    var maxScale: Double = 1.0
    
    for screen in NSScreen.screens {
        let scale = Double(screen.backingScaleFactor)
        if scale > maxScale {
            maxScale = scale
        }
    }
    
    return maxScale
}

private func adjustColorToDeviceColorspaceInternal(_ color: NSColor) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
    let formerAppearance : NSAppearance =  NSAppearance.current;
    MainActor.assumeIsolated {
        NSAppearance.current = NSApp.effectiveAppearance
    }
    
    defer { NSAppearance.current = formerAppearance }
    if let deviceColor = color.usingColorSpace(.deviceRGB) {
        let r = UInt8(deviceColor.redComponent * 255)
        let g = UInt8(deviceColor.greenComponent * 255)
        let b = UInt8(deviceColor.blueComponent * 255)
        let a = UInt8(deviceColor.alphaComponent * 255)
        return (r, g, b, a)
    } else {
        // Fallback to original color components
        let r = UInt8(color.redComponent * 255)
        let g = UInt8(color.greenComponent * 255)
        let b = UInt8(color.blueComponent * 255)
        let a = UInt8(color.alphaComponent * 255)
        return (r, g, b, a)
    }
}
public func adjustColorToDeviceColorspace(_ color: NSColor) -> UInt32{
    let result = adjustColorToDeviceColorspaceInternal(color);
    var r : UInt32;
    r = UInt32(result.blue)
    r |= UInt32(result.alpha) << 24
    r |= UInt32(result.red) << 16
    r |= UInt32(result.green) << 8
    return r;
}


public func isMouseEventFromTouchpad() -> Bool {
    MainActor.assumeIsolated {
        guard let event = NSApp.currentEvent else { return false }
        return event.momentumPhase != []
            || event.phase != []
    }
}

// MARK: - App Nap Management
@xLightsUtilsActor
private class AppNapSuspender {
    static let shared = AppNapSuspender()
    private var activityId: NSObjectProtocol?
    private var isSuspended = false
    
    func suspend() async {
        if !isSuspended {
            let optionFlags = xLightsUtilsState.shared.optionFlags;
            activityId = ProcessInfo.processInfo.beginActivity(options: optionFlags, reason: "Outputting to lights")
            isSuspended = true
        }
    }
    
    func resume() async {
        if isSuspended, let activity = activityId {
            ProcessInfo.processInfo.endActivity(activity)
            activityId = nil
            isSuspended = false
        }
    }
}


public func enableSleepModes() {
    Task {
        await AppNapSuspender.shared.resume()
    }
}

public func disableSleepModes() {
    Task {
        await AppNapSuspender.shared.suspend()
    }
}

public func getOSFormattedClipboardData() -> String {
    let pasteboard = NSPasteboard.general
    
    if let string = pasteboard.string(forType: .string) {
        return string
    }
    
    return ""
}


// MARK: - Audio Device Management
@_extern(c, "AudioDeviceChangedCallback")
func AudioDeviceChangedCallback() -> Void


private func deviceListChanged(objectID: AudioObjectID, numAddresses: UInt32, addresses: UnsafePointer<AudioObjectPropertyAddress>, userData: UnsafeMutableRawPointer?) -> OSStatus {
    AudioDeviceChangedCallback()
    return noErr
}


public func addAudioDeviceChangeListener() {
    var devListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMaster
    )
    
    var defaultDevAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    
    AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &devListAddress, deviceListChanged, nil)
    AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &defaultDevAddress, deviceListChanged, nil)
}

public func removeAudioDeviceChangeListener() {
    var devListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMaster
    )
    
    var defaultDevAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    
    AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &devListAddress, deviceListChanged, nil)
    AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &defaultDevAddress, deviceListChanged, nil)
}

@xLightsUtilsActor private func isFromAppStoreInternal() -> Bool {
    if xLightsUtilsState.shared.osxStatus == -1 {
        xLightsUtilsState.shared.osxStatus = 0
        
        let bundleURL = Bundle.main.bundleURL;
        
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode)
        
        guard status == errSecSuccess, let code = staticCode else { return false }
        
        var info: CFDictionary?
        status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        
        guard status == errSecSuccess, let signingInfo = info else { return false }
        
        let certChain = (signingInfo as NSDictionary)[kSecCodeInfoCertificates] as! [SecCertificate];
        let cert = certChain.first
        
        var commonName: CFString?
        status = SecCertificateCopyCommonName(cert!, &commonName)
        
        guard status == errSecSuccess, let cn = commonName as String? else { return false }
        
        if !cn.hasPrefix("Apple Mac OS") && !cn.hasPrefix("TestFlight") {
            return false
        }
        
        xLightsUtilsState.shared.optionFlags = [.latencyCritical, .userInitiated]
        xLightsUtilsState.shared.osxStatus = 1
    }
    
    return xLightsUtilsState.shared.osxStatus == 1
}
public func isFromAppStore() -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    var result = false;
    Task {
        defer {
            semaphore.signal()
        }
        result = await isFromAppStoreInternal();
        
    }
    semaphore.wait()
    return result;
}

@available(*, deprecated)
public func WXGLUnsetCurrentContext() {
    NSOpenGLContext.clearCurrentContext();
}

public func setThreadQOS(_ priority: Int) {
    let qosClass: qos_class_t = priority != 0 ? QOS_CLASS_USER_INITIATED : QOS_CLASS_BACKGROUND
    pthread_set_qos_class_self_np(qosClass, 0)
}

public func setButtonBackground(_ button: NSButton, color: NSColor, transparent: Bool, bgType: Int) {
    MainActor.assumeIsolated {
        if transparent {
            button.bezelStyle = .push
            button.bezelColor = nil
        } else {
            button.bezelStyle = .push
            
            if bgType == 1 {
                button.isBordered = false
                button.wantsLayer = true
                
                if let layer = button.layer {
                    layer.backgroundColor = color.cgColor
                    layer.cornerRadius = 6
                    layer.borderWidth = 1
                    layer.borderColor = color.cgColor
                }
            } else {
                button.bezelColor = color
            }
        }
        
        button.needsDisplay = true
    }
}
