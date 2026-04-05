
#include "ExternalHooksMacOS.h"

#include <functional>

void RunInAutoReleasePool(std::function<void()> &&f) {
    @autoreleasepool {
        f();
    }
}
