/***************************************************************
 * This source files comes from the xLights project
 * https://www.xlights.org
 * https://github.com/xLightsSequencer/xLights
 * See the github commit history for a record of contributing
 * developers.
 * Copyright claimed based on commit dates recorded in Github
 * License: https://github.com/xLightsSequencer/xLights/blob/master/License.txt
 **************************************************************/

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <TargetConditionals.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#endif

#include "AppleSharePlayBridge.h"
#include "CollabEntitlements.h"
#include "xLights_Apple_core-Swift.h"

namespace AppleSharePlay {
namespace {

std::string ToStd(NSString* s) {
    return s != nil ? std::string([s UTF8String] ?: "") : std::string();
}

NSString* ToNS(const std::string& s) {
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @"";
}

class SwiftChannel : public Channel {
public:
    explicit SwiftChannel(XLCollabGroupChannel* channel) :
        _channel(channel) {
        // The Swift side calls these on the main thread, and the destructor
        // (also on the main thread) clears them, so `self` is valid whenever
        // one runs. Each copies the std::function first: the handler may
        // destroy this channel.
        SwiftChannel* self = this;
        _channel.onMessage = ^(NSString* from, NSData* data) {
            auto fn = self->onMessage;
            if (fn) {
                fn(ToStd(from), std::string(static_cast<const char*>(data.bytes), data.length));
            }
        };
        _channel.onMembers = ^(NSArray<NSString*>* ids) {
            auto fn = self->onMembers;
            if (fn) {
                std::vector<std::string> members;
                members.reserve(ids.count);
                for (NSString* i in ids) {
                    members.push_back(ToStd(i));
                }
                fn(members);
            }
        };
        _channel.onAttachment = ^(NSString* from, NSString* key, NSString* path) {
            auto fn = self->onAttachment;
            if (fn) {
                fn(ToStd(from), ToStd(key), ToStd(path));
            }
        };
        _channel.onEnded = ^(NSString* reason) {
            auto fn = self->onEnded;
            if (fn) {
                fn(ToStd(reason));
            }
        };
        _channel.onAttachFailed = ^(NSString* key) {
            auto fn = self->onAttachFailed;
            if (fn) {
                fn(ToStd(key));
            }
        };
        _channel.wantsAttachment = ^BOOL(NSString* key) {
            auto fn = self->wantsAttachment;
            return !fn || fn(ToStd(key));
        };
    }
    ~SwiftChannel() override {
        [_channel close];
    }

    std::string LocalId() const override { return ToStd(_channel.localId); }
    bool IsInitiator() const override { return _channel.isInitiator; }
    void Send(const std::string& to, const std::string& bytes) override {
        [_channel send:[NSData dataWithBytes:bytes.data() length:bytes.size()] to:ToNS(to)];
    }
    bool Attach(const std::string& key, const std::string& path) override {
        return [_channel attach:ToNS(key) path:ToNS(path)];
    }
    void Detach(const std::string& key) override { [_channel detach:ToNS(key)]; }
    void Leave(bool endForEveryone) override { [_channel leaveEndingForEveryone:endForEveryone]; }

private:
    XLCollabGroupChannel* _channel;
};

void (^ReadyBlock(Ready ready))(XLCollabGroupChannel*, NSString*) {
    return ^(XLCollabGroupChannel* channel, NSString* error) {
        if (channel != nil) {
            ready(std::make_unique<SwiftChannel>(channel), std::string());
        } else {
            std::string e = ToStd(error);
            ready(nullptr, e.empty() ? std::string("SharePlay did not start the session.") : e);
        }
    };
}

const char* kUnavailable = "SharePlay is not available in this build of xLights.";

} // namespace

size_t MaxMessageBytes() {
    return (size_t)XLCollabGroupChannel.maxMessageBytes;
}

uint64_t MaxAttachmentBytes() {
    return XLCollabGroupChannel.maxAttachmentBytes;
}

bool Available() {
    // Without the entitlement GroupActivities is never touched: the app is
    // not allowed to use it, and how it then fails is undocumented.
    static const bool entitled = AppleCollab::HasEntitlement("com.apple.developer.group-session");
    return entitled;
}

bool InGroup() {
    return Available() && XLCollabGroupSource.shared.inGroup;
}

void Observe(std::function<void(const Offer&)> onOffer) {
    if (!Available()) {
        return;
    }
    XLCollabGroupSource* source = XLCollabGroupSource.shared;
    source.onOffered = ^(NSString* sid, NSString* sequence, NSString* host, NSString* kind, NSInteger protocol) {
        if (onOffer) {
            Offer o;
            o.id = ToStd(sid);
            o.sequenceName = ToStd(sequence);
            o.hostName = ToStd(host);
            o.deviceKind = ToStd(kind);
            o.protocol = (int)protocol;
            onOffer(o);
        }
    };
    [source startObserving];
}

void Start(const Offer& advert, Ready ready) {
    if (!Available()) {
        ready(nullptr, kUnavailable);
        return;
    }
    std::string sid = advert.id.empty() ? ToStd([[NSUUID UUID] UUIDString]) : advert.id;
    [XLCollabGroupSource.shared startWithSessionId:ToNS(sid)
                                      sequenceName:ToNS(advert.sequenceName)
                                          hostName:ToNS(advert.hostName)
                                        deviceKind:ToNS(advert.deviceKind)
                                   protocolVersion:advert.protocol
                                        completion:ReadyBlock(std::move(ready))];
}

void JoinOffered(const std::string& id, Ready ready) {
    if (!Available()) {
        ready(nullptr, kUnavailable);
        return;
    }
    [XLCollabGroupSource.shared joinOffered:ToNS(id) completion:ReadyBlock(std::move(ready))];
}

} // namespace AppleSharePlay
