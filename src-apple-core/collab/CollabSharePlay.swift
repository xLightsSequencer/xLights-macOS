//
//  CollabSharePlay.swift
//  xLights-Apple-core
//
//  SharePlay (GroupActivities) for live collaboration sessions with people
//  who are not on the same network. This is only the platform plumbing:
//  the activity, the messenger and the journal. Hosting, ids, chunking and
//  file transfer are in src-core/collab (CollabGroup.h); the C++ side is
//  CollabSharePlayBridge.mm.
//
//  Everything here runs on the main actor, so every callback reaches C++ on
//  the main thread.
//

import Foundation
import Combine
import CoreTransferable
import UniformTypeIdentifiers
@_weakLinked @preconcurrency import GroupActivities

#if os(macOS)
import AppKit
// The sharing controller (macOS 13+) lives in this overlay; weak so the app
// still launches on macOS 12.
@_weakLinked import _GroupActivities_AppKit
#else
import UIKit
@_weakLinked import _GroupActivities_UIKit
#endif

struct XLightsCollabActivity: GroupActivity {
    // Fixed rather than derived from the type, so the desktop and iPad apps
    // offer and accept the same activity.
    static let activityIdentifier = "org.xlights.collab-session"

    var sessionId: String
    var sequenceName: String
    var hostName: String
    var deviceKind: String?
    var protocolVersion: Int?

    var metadata: GroupActivityMetadata {
        var m = GroupActivityMetadata()
        m.title = sequenceName
        m.subtitle = hostName.isEmpty ? "xLights live collaboration" : "xLights live collaboration with \(hostName)"
        m.type = .generic
        return m
    }
}

private func collabTempDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xLightsCollabSharePlay", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@available(macOS 14, iOS 17, *)
private struct CollabAttachmentFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .data) { file in
            SentTransferredFile(file.url)
        } importing: { received in
            // The received file is only valid during this closure.
            let dest = collabTempDirectory().appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return CollabAttachmentFile(url: dest)
        }
    }
}

private struct CollabAttachmentInfo: Codable {
    var key: String
    var from: String
}

// One joined group session.
@MainActor
@objc(XLCollabGroupChannel)
public final class XLCollabGroupChannel: NSObject {
    // Documented as 256 KB since iOS 16 / macOS 13; the original limit was a
    // quarter of that. Stay at the lower one so macOS 12 and encoding
    // overhead never push a message over.
    @objc public static let maxMessageBytes: Int = 64 * 1024
    // The journal takes attachments of up to 100 MB; leave headroom for its
    // own metadata. Older systems have no journal and core chunks instead.
    @objc public static var maxAttachmentBytes: UInt64 {
        if #available(macOS 14, iOS 17, *) {
            return 64 * 1024 * 1024
        }
        return 0
    }

    @objc public var onMessage: ((String, Data) -> Void)?
    @objc public var onMembers: (([String]) -> Void)?
    @objc public var onAttachment: ((String, String, String) -> Void)?
    @objc public var onEnded: ((String) -> Void)?
    @objc public var onAttachFailed: ((String) -> Void)?
    // Asked with an attachment's key before downloading it: false skips it
    // (it is addressed to another member). Core owns the key format.
    @objc public var wantsAttachment: ((String) -> Bool)?

    @objc public let isInitiator: Bool
    @objc public var localId: String { session.localParticipant.id.uuidString }

    fileprivate let session: GroupSession<XLightsCollabActivity>
    private let messenger: GroupSessionMessenger
    private var journal: AnyObject?
    private var tasks: [Task<Void, Never>] = []
    private var closed = false
    private var ended = false
    private var joinedCallback: ((String?) -> Void)?
    private var seenAttachments = Set<UUID>()
    private var addedAttachments: [String: Any] = [:]
    private var detachRequested = Set<String>()

    fileprivate init(session: GroupSession<XLightsCollabActivity>, initiator: Bool) {
        self.session = session
        self.isInitiator = initiator
        if #available(macOS 13, iOS 16, *) {
            self.messenger = GroupSessionMessenger(session: session, deliveryMode: .reliable)
        } else {
            self.messenger = GroupSessionMessenger(session: session)
        }
        super.init()
        if #available(macOS 14, iOS 17, *) {
            journal = GroupSessionJournal(session: session)
        }
    }

    // Joins the session and calls `done` once it is joined (nil) or failed.
    fileprivate func join(_ done: @escaping (String?) -> Void) {
        joinedCallback = done
        observe()
        session.join()
    }

    private func observe() {
        let messages = messenger.messages(of: Data.self)
        tasks.append(Task { @MainActor [weak self] in
            for await (data, context) in messages {
                guard let self, !self.closed else { return }
                self.onMessage?(context.source.id.uuidString, data)
            }
        })
        let participants = session.$activeParticipants.values
        tasks.append(Task { @MainActor [weak self] in
            for await set in participants {
                guard let self, !self.closed else { return }
                self.reportMembers(set)
            }
        })
        let states = session.$state.values
        tasks.append(Task { @MainActor [weak self] in
            for await state in states {
                guard let self else { return }
                self.stateChanged(state)
            }
        })
        if #available(macOS 14, iOS 17, *), let journal = journal as? GroupSessionJournal {
            let attachments = journal.attachments
            tasks.append(Task { @MainActor [weak self] in
                for await list in attachments {
                    guard let self, !self.closed else { return }
                    self.attachmentsChanged(list)
                }
            })
        }
    }

    private func reportMembers(_ set: Set<Participant>) {
        var all = set
        all.insert(session.localParticipant)
        let ids = all.map { $0.id.uuidString }.sorted()
        onMembers?(ids)
    }

    private func stateChanged(_ state: GroupSession<XLightsCollabActivity>.State) {
        switch state {
        case .joined:
            if let cb = joinedCallback {
                joinedCallback = nil
                cb(nil)
                if !closed {
                    reportMembers(session.activeParticipants)
                }
            }
        case .invalidated(let reason):
            let text = reason.localizedDescription
            if let cb = joinedCallback {
                joinedCallback = nil
                cb(text)
            }
            if !ended {
                ended = true
                if !closed {
                    onEnded?(text)
                }
            }
            stopObserving()
        case .waiting:
            break
        @unknown default:
            break
        }
    }

    @objc public func send(_ data: Data, to: String) {
        guard !closed else { return }
        let target: Participants
        if to.isEmpty {
            target = .all
        } else if let p = session.activeParticipants.first(where: { $0.id.uuidString == to }) {
            target = .only(p)
        } else {
            return
        }
        // The completion form enqueues now, so messages keep the order Send
        // was called in.
        messenger.send(data, to: target) { error in
            if let error {
                NSLog("xLights SharePlay: send failed: %@", error.localizedDescription)
            }
        }
    }

    // Copies `path` now (the caller may delete it) and uploads the copy.
    @objc public func attach(_ key: String, path: String) -> Bool {
        guard !closed else { return false }
        guard #available(macOS 14, iOS 17, *), let journal = journal as? GroupSessionJournal else { return false }
        let copy = collabTempDirectory().appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: copy)
        } catch {
            return false
        }
        detachRequested.remove(key)
        let info = CollabAttachmentInfo(key: key, from: localId)
        Task { @MainActor [weak self] in
            defer { try? FileManager.default.removeItem(at: copy) }
            do {
                let attachment = try await journal.add(CollabAttachmentFile(url: copy), metadata: info)
                guard let self else { return }
                self.seenAttachments.insert(attachment.id)
                if self.detachRequested.remove(key) != nil || self.closed {
                    try? await journal.remove(attachment: attachment)
                } else {
                    self.addedAttachments[key] = attachment
                }
            } catch {
                NSLog("xLights SharePlay: attachment upload failed: %@", error.localizedDescription)
                guard let self, !self.closed else { return }
                self.detachRequested.remove(key)
                self.onAttachFailed?(key)
            }
        }
        return true
    }

    @objc public func detach(_ key: String) {
        guard #available(macOS 14, iOS 17, *), let journal = journal as? GroupSessionJournal else { return }
        guard let attachment = addedAttachments.removeValue(forKey: key) as? GroupSessionJournal.Attachment else {
            // Still uploading: removed when the upload finishes.
            detachRequested.insert(key)
            return
        }
        Task {
            try? await journal.remove(attachment: attachment)
        }
    }

    @available(macOS 14, iOS 17, *)
    private func attachmentsChanged(_ list: [GroupSessionJournal.Attachment]) {
        let me = localId
        for attachment in list where !seenAttachments.contains(attachment.id) {
            seenAttachments.insert(attachment.id)
            Task { @MainActor [weak self] in
                do {
                    let info = try await attachment.loadMetadata(of: CollabAttachmentInfo.self)
                    if info.from == me {
                        return
                    }
                    // Every member sees every attachment; download only ours.
                    guard let self, !self.closed, self.wantsAttachment?(info.key) ?? true else { return }
                    let file = try await attachment.load(CollabAttachmentFile.self)
                    defer { try? FileManager.default.removeItem(at: file.url) }
                    guard !self.closed else { return }
                    self.onAttachment?(info.from, info.key, file.url.path)
                } catch {
                    NSLog("xLights SharePlay: attachment download failed: %@", error.localizedDescription)
                }
            }
        }
    }

    // The current host's leaving ends the activity for everyone, so a stale
    // session is not left offered to the others. Anyone else only leaves:
    // after a host migration the device that started the activity may be a
    // client, and ending it then would end the new host's session too. Core
    // knows which this device is now, so it decides.
    @objc(leaveEndingForEveryone:) public func leave(endingForEveryone: Bool) {
        guard !closed else { return }
        closed = true
        joinedCallback = nil
        if endingForEveryone {
            session.end()
        } else {
            session.leave()
        }
    }

    // No callbacks after this; leaves the session (only this device) if still
    // in it.
    @objc public func close() {
        onMessage = nil
        onMembers = nil
        onAttachment = nil
        onEnded = nil
        onAttachFailed = nil
        wantsAttachment = nil
        leave(endingForEveryone: false)
        stopObserving()
    }

    private func stopObserving() {
        for t in tasks {
            t.cancel()
        }
        tasks.removeAll()
    }
}

// The process's view of SharePlay: whether a call is active, starting an
// activity, and the activity another member started.
@MainActor
@objc(XLCollabGroupSource)
public final class XLCollabGroupSource: NSObject {
    @objc public static let shared = XLCollabGroupSource()

    // An activity someone else started: (id, sequence, host, deviceKind,
    // protocol). An empty id: the offer went away.
    @objc public var onOffered: ((String, String, String, String, Int) -> Void)?

#if os(iOS)
    // Where the invite sheet is presented from; the frontmost view
    // controller of the key window when unset.
    @objc public var presenter: (() -> UIViewController?)?
#endif

    private var observer: GroupStateObserver?
    private var started = false
    private var pendingId: String?
    private var pendingCompletion: ((XLCollabGroupChannel?, String) -> Void)?
    private var pendingTimeout: Task<Void, Never>?
    private var offered: [String: GroupSession<XLightsCollabActivity>] = [:]
    private var currentOffer = ""

    @objc public var inGroup: Bool { observer?.isEligibleForGroupSession ?? false }

    @objc public func startObserving() {
        guard !started else { return }
        started = true
        observer = GroupStateObserver()
        Task { @MainActor [weak self] in
            for await session in XLightsCollabActivity.sessions() {
                guard let self else { return }
                self.sessionArrived(session)
            }
        }
    }

    private func sessionArrived(_ session: GroupSession<XLightsCollabActivity>) {
        let activity = session.activity
        if let id = pendingId, activity.sessionId == id, let completion = pendingCompletion {
            clearPending()
            let channel = XLCollabGroupChannel(session: session, initiator: true)
            channel.join { error in
                if let error {
                    completion(nil, error)
                } else {
                    completion(channel, "")
                }
            }
            return
        }
        offered[activity.sessionId] = session
        currentOffer = activity.sessionId
        onOffered?(activity.sessionId, activity.sequenceName, activity.hostName, activity.deviceKind ?? "", activity.protocolVersion ?? 0)
        let states = session.$state.values
        Task { @MainActor [weak self] in
            for await state in states {
                if case .invalidated = state {
                    self?.offerGone(activity.sessionId, session)
                    return
                }
            }
        }
    }

    private func offerGone(_ id: String, _ session: GroupSession<XLightsCollabActivity>) {
        guard let s = offered[id], s === session else { return }
        offered.removeValue(forKey: id)
        if currentOffer == id {
            currentOffer = ""
            onOffered?("", "", "", "", 0)
        }
    }

    @objc public func start(sessionId: String, sequenceName: String, hostName: String, deviceKind: String, protocolVersion: Int,
                            completion: @escaping (XLCollabGroupChannel?, String) -> Void) {
        if let previous = pendingCompletion {
            clearPending()
            previous(nil, "Replaced by a newer request")
        }
        let activity = XLightsCollabActivity(sessionId: sessionId, sequenceName: sequenceName, hostName: hostName,
                                             deviceKind: deviceKind, protocolVersion: protocolVersion)
        pendingId = sessionId
        pendingCompletion = completion
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.inGroup {
                switch await activity.prepareForActivation() {
                case .activationPreferred:
                    do {
                        if try await activity.activate() {
                            self.waitForSession()
                        } else {
                            self.failPending(sessionId, "SharePlay did not start the session.")
                        }
                    } catch {
                        self.failPending(sessionId, error.localizedDescription)
                    }
                case .activationDisabled:
                    self.failPending(sessionId, "SharePlay is turned off on this device.")
                case .cancelled:
                    self.failPending(sessionId, "SharePlay was cancelled, so the session wasn't started.")
                @unknown default:
                    self.failPending(sessionId, "SharePlay did not start the session.")
                }
            } else {
                await self.invite(activity, sessionId)
            }
        }
    }

    private func invite(_ activity: XLightsCollabActivity, _ sessionId: String) async {
#if os(macOS)
        guard #available(macOS 13, *) else {
            failPending(sessionId, "Start a FaceTime call with the people to invite, then host again.")
            return
        }
        guard let parent = NSApp.keyWindow ?? NSApp.mainWindow else {
            failPending(sessionId, "No window to show the invitation in.")
            return
        }
        let controller: GroupActivitySharingController
        do {
            controller = try GroupActivitySharingController(activity)
        } catch {
            failPending(sessionId, error.localizedDescription)
            return
        }
        let sheet = NSWindow(contentViewController: controller)
        parent.beginSheet(sheet, completionHandler: nil)
        let result = await controller.result
        parent.endSheet(sheet)
        sheet.orderOut(nil)
#else
        guard let from = presenter?() ?? Self.frontmostViewController() else {
            failPending(sessionId, "No window to show the invitation in.")
            return
        }
        let controller: GroupActivitySharingController
        do {
            controller = try GroupActivitySharingController(activity)
        } catch {
            failPending(sessionId, error.localizedDescription)
            return
        }
        from.present(controller, animated: true)
        let result = await controller.result
#endif
        if result == .success {
            waitForSession()
        } else {
            failPending(sessionId, "The SharePlay invitation was cancelled, so the session wasn't started.")
        }
    }

#if os(iOS)
    // On top of whatever is presented (the Collaborate sheet included).
    private static func frontmostViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.keyWindow ?? scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        var vc = window?.rootViewController
        while let next = vc?.presentedViewController {
            vc = next
        }
        return vc
    }
#endif

    // The activity started; the session itself arrives through sessions().
    // Don't wait forever if it never does.
    private func waitForSession() {
        guard let id = pendingId else { return }
        pendingTimeout?.cancel()
        pendingTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            if !Task.isCancelled {
                self?.failPending(id, "SharePlay did not start the session.")
            }
        }
    }

    private func failPending(_ id: String, _ reason: String) {
        guard pendingId == id, let completion = pendingCompletion else { return }
        clearPending()
        completion(nil, reason)
    }

    private func clearPending() {
        pendingTimeout?.cancel()
        pendingTimeout = nil
        pendingId = nil
        pendingCompletion = nil
    }

    @objc public func joinOffered(_ sessionId: String, completion: @escaping (XLCollabGroupChannel?, String) -> Void) {
        guard let session = offered.removeValue(forKey: sessionId) else {
            completion(nil, "That SharePlay session has ended.")
            return
        }
        if currentOffer == sessionId {
            currentOffer = ""
        }
        let channel = XLCollabGroupChannel(session: session, initiator: false)
        channel.join { error in
            if let error {
                completion(nil, error)
            } else {
                completion(channel, "")
            }
        }
    }
}
