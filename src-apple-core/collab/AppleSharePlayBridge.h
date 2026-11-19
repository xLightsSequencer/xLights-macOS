#pragma once

/***************************************************************
 * This source files comes from the xLights project
 * https://www.xlights.org
 * https://github.com/xLightsSequencer/xLights
 * See the github commit history for a record of contributing
 * developers.
 * Copyright claimed based on commit dates recorded in Github
 * License: https://github.com/xLightsSequencer/xLights/blob/master/License.txt
 **************************************************************/

// Pure C++ ABI over the SharePlay (GroupActivities) Swift code in this
// folder, for src-core/collab/CollabGroupApple.mm, which adapts it to
// Collab::IGroupSessionSource. Only std types cross it.
//
// Call everything on the main thread; every callback arrives on the main
// thread too.

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace AppleSharePlay {

// What the activity carries: enough to list it before joining.
struct Offer {
    std::string id; // empty: the offer went away
    std::string sequenceName;
    std::string hostName;
    std::string deviceKind;
    int protocol = 0; // 0: not given
};

// One joined SharePlay session.
class Channel {
public:
    virtual ~Channel() = default; // leaves the session if still in it; no callbacks after

    virtual std::string LocalId() const = 0;
    virtual bool IsInitiator() const = 0;
    // `to` empty: every other member.
    virtual void Send(const std::string& to, const std::string& bytes) = 0;
    // Copies `path` before returning and uploads the copy to the journal.
    virtual bool Attach(const std::string& key, const std::string& path) = 0;
    virtual void Detach(const std::string& key) = 0;
    // `endForEveryone`: end the activity for the whole group (the current
    // host leaving); otherwise only this device leaves.
    virtual void Leave(bool endForEveryone) = 0;

    std::function<void(const std::string& from, const std::string& bytes)> onMessage;
    std::function<void(const std::vector<std::string>& memberIds)> onMembers; // including this device
    std::function<void(const std::string& from, const std::string& key, const std::string& path)> onAttachment;
    std::function<void(const std::string& reason)> onEnded;
    // A journal upload that Attach accepted failed.
    std::function<void(const std::string& key)> onAttachFailed;
    // Asked before downloading a journal attachment: false skips it.
    std::function<bool(const std::string& key)> wantsAttachment;
};

using Ready = std::function<void(std::unique_ptr<Channel> channel, const std::string& error)>;

size_t MaxMessageBytes();
uint64_t MaxAttachmentBytes(); // 0: no journal on this OS version

// The app is entitled to SharePlay. Nothing below touches GroupActivities
// when it is not.
bool Available();
// In a FaceTime call (or other group) that can start an activity now.
bool InGroup();

// Starts watching for activities (once). `onOffer` hears each activity
// another member starts, and an empty-id Offer when it goes away.
void Observe(std::function<void(const Offer&)> onOffer);

// Activates the activity, inviting through the share sheet when not in a
// call; `ready` gets this device's channel (initiator) or an error.
void Start(const Offer& advert, Ready ready);
void JoinOffered(const std::string& id, Ready ready);

} // namespace AppleSharePlay
