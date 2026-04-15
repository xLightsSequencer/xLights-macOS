//
//  xlAppleUtils.swift
//  xLights-Apple-core
//
//  Core-safe Apple platform utilities.  No AppKit UI types (NSApp, NSScreen, etc.)
//  Shared by macOS and iOS.  UI-specific utilities live in xlMacUtilsUI.swift.
//

import Foundation
#if canImport(CoreAudio)
import CoreAudio
#endif
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

/// Returns true if the path is inside the app container's temporary directory.
/// Bookmarks for such paths are unnecessary (the sandbox already grants access)
/// and waste space in UserDefaults.
private func isInTemporaryDirectory(_ path: String) -> Bool {
    let tmpDir = NSTemporaryDirectory()
    return path.hasPrefix(tmpDir)
}

/// Removes all stored bookmarks whose keys point into the container tmp directory.
/// Called once at startup to reclaim space from previously-stored tmp bookmarks.
@xLightsUtilsActor
private func purgeTemporaryBookmarks() {
    let tmpDir = NSTemporaryDirectory()
    let dict = xLightsUtilsState.shared.config.dictionaryRepresentation()
    for key in dict.keys {
        if key.hasPrefix(tmpDir) {
            xLightsUtilsState.shared.config.removeObject(forKey: key)
        }
    }
}

/// Returns true if any ancestor directory of `path` already has a stored
/// bookmark. When it does, the ancestor's security scope already covers this
/// path, so we don't need a separate bookmark — saving one would just waste
/// space in the (size-limited) UserDefaults plist.
@xLightsUtilsActor
private func findAncestorBookmark(_ path: String) -> String? {
    let config = xLightsUtilsState.shared.config
    var parent = (path as NSString).deletingLastPathComponent
    while !parent.isEmpty && parent != "/" {
        if config.string(forKey: parent) != nil {
            return parent
        }
        let next = (parent as NSString).deletingLastPathComponent
        if next == parent { break }
        parent = next
    }
    return nil
}

/// Removes any stored bookmark whose path is already covered by an ancestor
/// directory bookmark. Called once at startup to reclaim space from previous
/// versions that bookmarked every file inside the show/media folders.
@xLightsUtilsActor
private func purgeRedundantBookmarks() {
    let config = xLightsUtilsState.shared.config
    let dict = config.dictionaryRepresentation()
    // Sort shortest-first so ancestors are decided before their descendants.
    let keys = dict.keys.sorted { $0.count < $1.count }
    var keep = Set<String>()
    for key in keys {
        var covered = false
        var parent = (key as NSString).deletingLastPathComponent
        while !parent.isEmpty && parent != "/" {
            if keep.contains(parent) {
                covered = true
                break
            }
            let next = (parent as NSString).deletingLastPathComponent
            if next == parent { break }
            parent = next
        }
        if covered {
            config.removeObject(forKey: key)
        } else {
            keep.insert(key)
        }
    }
}

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
    // If an ancestor directory already has a stored bookmark, its security
    // scope covers this path. Resolve+activate the ancestor (so its scope is
    // started in this process) and skip creating a redundant bookmark for the
    // child — UserDefaults is size-limited and bookmarking every file inside
    // a bookmarked folder blew past that limit.
    if let ancestor = findAncestorBookmark(path) {
        let ancestorOK = obtainAccessToURLInternal(ancestor, enforceWritable: enforceWritable)
        if xLightsUtilsState.shared.config.string(forKey: path) != nil {
            xLightsUtilsState.shared.config.removeObject(forKey: path)
        }
        if !ancestorOK {
            return false
        }
        return isDirAccessible(path, enforceWritable: enforceWritable)
    }
    let val = xLightsUtilsState.shared.config.string(forKey: path);
    if val != nil {
        let bookmarkData = Data(base64Encoded: val!)
        var isStale = false
        do {
#if os(iOS)
             let resolvedURL = try URL(resolvingBookmarkData: bookmarkData!,
                                     options: [],
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &isStale)
#else
             let resolvedURL = try URL(resolvingBookmarkData: bookmarkData!,
                                     options: [.withoutUI, .withSecurityScope],
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &isStale)
#endif

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
#if os(iOS)
        let bookmarkData = try url.bookmarkData(options: [],
                                              includingResourceValuesForKeys: nil,
                                              relativeTo: nil)
#else
        let bookmarkData = try url.bookmarkData(options: .withSecurityScope,
                                              includingResourceValuesForKeys: nil,
                                              relativeTo: nil)
#endif
        let base64String = bookmarkData.base64EncodedString()

        var shouldSave = !isInTemporaryDirectory(path)
        if shouldSave && url.hasDirectoryPath {
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


class AsyncBoolResult: @unchecked Sendable {
    var result: Bool = false


}

// MARK: - Public Functions
public func purgeTemporaryBookmarksSync() {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        defer { semaphore.signal() }
        await purgeTemporaryBookmarks()
    }
    semaphore.wait()
}

public func purgeRedundantBookmarksSync() {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        defer { semaphore.signal() }
        await purgeRedundantBookmarks()
    }
    semaphore.wait()
}

public func obtainAccessToURL(_ path: String, enforceWritable: Bool)  -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    let result: AsyncBoolResult = .init()
    Task {
        defer {
            semaphore.signal()
        }
        result.result = await obtainAccessToURLInternal(path, enforceWritable: enforceWritable);
    }
    semaphore.wait()
    return result.result;
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

#if !os(iOS)
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
#endif
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


#if !os(iOS)
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

        let ccTmp = (signingInfo as NSDictionary)[kSecCodeInfoCertificates];
        if (ccTmp == nil) {
            return false;
        }
        let certChain = ccTmp as! [SecCertificate];
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
#endif
public func isFromAppStore() -> Bool {
#if os(iOS)
    // iOS apps are always from the AppStore
    return true
#else
    let semaphore = DispatchSemaphore(value: 0)
    let result: AsyncBoolResult = .init();
    Task {
        defer {
            semaphore.signal()
        }
        result.result = await isFromAppStoreInternal();
    }
    semaphore.wait()
    return result.result;
#endif
}

