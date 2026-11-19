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

#include "CollabEntitlements.h"

#include <cstdint>
#include <cstring>

#include <mach-o/dyld.h>
#include <mach-o/loader.h>

namespace {

// Code signature blobs are big-endian.
uint32_t BE32(const uint8_t* p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

constexpr uint32_t kSuperBlobMagic = 0xfade0cc0;
constexpr uint32_t kEntitlementsMagic = 0xfade7171;
constexpr uint32_t kEntitlementsSlot = 5;

// The XML entitlements plist of the main executable, nil when it has none.
NSData* MainExecutableEntitlements() {
    const mach_header* header = _dyld_get_image_header(0);
    if (header == nullptr || header->magic != MH_MAGIC_64) {
        return nil;
    }
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    const auto* h64 = reinterpret_cast<const mach_header_64*>(header);
    const uint8_t* cmd = reinterpret_cast<const uint8_t*>(h64 + 1);
    const segment_command_64* linkedit = nullptr;
    const linkedit_data_command* signature = nullptr;
    for (uint32_t i = 0; i < h64->ncmds; ++i) {
        const auto* lc = reinterpret_cast<const load_command*>(cmd);
        if (lc->cmd == LC_SEGMENT_64) {
            const auto* seg = reinterpret_cast<const segment_command_64*>(lc);
            if (strncmp(seg->segname, SEG_LINKEDIT, sizeof(seg->segname)) == 0) {
                linkedit = seg;
            }
        } else if (lc->cmd == LC_CODE_SIGNATURE) {
            signature = reinterpret_cast<const linkedit_data_command*>(lc);
        }
        cmd += lc->cmdsize;
    }
    if (linkedit == nullptr || signature == nullptr || signature->dataoff < linkedit->fileoff ||
        (uint64_t)signature->dataoff + signature->datasize > linkedit->fileoff + linkedit->filesize || signature->datasize < 12) {
        return nil;
    }
    const uint8_t* blob = reinterpret_cast<const uint8_t*>(linkedit->vmaddr + slide + (signature->dataoff - linkedit->fileoff));
    const uint32_t size = signature->datasize;
    if (BE32(blob) != kSuperBlobMagic) {
        return nil;
    }
    uint32_t count = BE32(blob + 8);
    if (12 + (uint64_t)count * 8 > size) {
        return nil;
    }
    for (uint32_t i = 0; i < count; ++i) {
        const uint8_t* index = blob + 12 + i * 8;
        if (BE32(index) != kEntitlementsSlot) {
            continue;
        }
        uint32_t offset = BE32(index + 4);
        if ((uint64_t)offset + 8 > size) {
            return nil;
        }
        const uint8_t* ent = blob + offset;
        uint32_t length = BE32(ent + 4);
        if (BE32(ent) != kEntitlementsMagic || length < 8 || (uint64_t)offset + length > size) {
            return nil;
        }
        return [NSData dataWithBytes:ent + 8 length:length - 8];
    }
    return nil;
}

} // namespace

namespace AppleCollab {

bool HasEntitlement(const char* key) {
    @autoreleasepool {
        NSData* data = MainExecutableEntitlements();
        if (data == nil) {
            return false;
        }
        id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil];
        if (![plist isKindOfClass:[NSDictionary class]]) {
            return false;
        }
        id value = ((NSDictionary*)plist)[@(key)];
        return [value isKindOfClass:[NSNumber class]] && [(NSNumber*)value boolValue];
    }
}

} // namespace AppleCollab
