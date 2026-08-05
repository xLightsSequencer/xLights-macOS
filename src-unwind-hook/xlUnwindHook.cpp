/***************************************************************
 * This source file is part of the xLights Project
 * https://www.xlights.org
 * Copyright claim.  This source must be released with full
 * source code.
 * License: https://github.com/xLightsSequencer/xLights/blob/master/License.txt
 **************************************************************/

// Records where a foreign stack unwind was raised.
//
// A crash handler runs inside a catch handler, by which point every frame
// between the throw and the catch has been unwound - so the throwing stack
// cannot be recovered there, only here.  For exceptions the C++ runtime
// raised that does not matter, because the exception's type names the throw
// site well enough; for a foreign unwind nothing identifies it at all, which
// left "Exception from main loop" crash reports with no way to tell what had
// been unwinding.
//
// This has to be a separate dynamic library: dyld only honours a
// __DATA,__interpose section in a dylib, so the same code compiled into the
// main executable silently does nothing.
//
// Cost on the normal path is a load, a compare and a tail call - nothing is
// captured for exceptions raised by the C++ or Objective-C runtime.

#include <unwind.h>
#include <execinfo.h>

#include <cstdint>
#include <cstring>

namespace {

// libc++abi tags everything it raises - C++ throw and Objective-C @throw
// alike - with one of these two classes.  Anything else came from another
// runtime, or is a forced unwind (pthread_exit / cancellation).
constexpr uint64_t NATIVE_EXCEPTION_CLASS = 0x434C4E47432B2B00ULL;    // CLNGC++\0
constexpr uint64_t DEPENDENT_EXCEPTION_CLASS = 0x434C4E47432B2B01ULL; // CLNGC++\1

constexpr int MAX_FRAMES = 64;

thread_local uint64_t tlsExceptionClass = 0;
thread_local void* tlsFrames[MAX_FRAMES];
thread_local int tlsFrameCount = 0;

inline void CaptureIfForeign(_Unwind_Exception* e) {
    if (e == nullptr) {
        return;
    }
    uint64_t const cls = e->exception_class;
    if (cls == NATIVE_EXCEPTION_CLASS || cls == DEPENDENT_EXCEPTION_CLASS) {
        return;
    }
    tlsExceptionClass = cls;
    // backtrace() walks frame pointers rather than unwinding, so it cannot
    // re-enter the function we are standing in.
    tlsFrameCount = backtrace(tlsFrames, MAX_FRAMES);
}

} // namespace

extern "C" {

// The forwarding call MUST be a tail call.  The unwinder searches for a handler
// starting from the frame that called it, so an extra frame here changes what it
// walks - at -O0, where the compiler would not elide the frame on its own, it
// stops finding handlers at all and every ordinary throw in the process ends in
// __cxa_throw -> failed_throw -> terminate.  musttail makes the hook transparent
// by construction instead of leaving it to the optimizer.
_Unwind_Reason_Code xlUnwindHook_RaiseException(_Unwind_Exception* e) {
    CaptureIfForeign(e);
    [[clang::musttail]] return _Unwind_RaiseException(e);
}

_Unwind_Reason_Code xlUnwindHook_ForcedUnwind(_Unwind_Exception* e, _Unwind_Stop_Fn stop, void* parameter) {
    CaptureIfForeign(e);
    [[clang::musttail]] return _Unwind_ForcedUnwind(e, stop, parameter);
}

// Returns false when this thread has not seen a foreign unwind, so the caller
// can tell "nothing recorded" from "recorded a class of zero".
bool xlUnwindHook_GetLastForeign(uint64_t* outClass, void** outFrames, int maxFrames, int* outFrameCount) {
    if (tlsFrameCount == 0) {
        return false;
    }
    if (outClass != nullptr) {
        *outClass = tlsExceptionClass;
    }
    int const n = tlsFrameCount < maxFrames ? tlsFrameCount : maxFrames;
    if (outFrames != nullptr) {
        std::memcpy(outFrames, tlsFrames, n * sizeof(void*));
    }
    if (outFrameCount != nullptr) {
        *outFrameCount = n;
    }
    return true;
}

} // extern "C"

#define XL_DYLD_INTERPOSE(_replacement, _replacee)                          \
    __attribute__((used)) static struct {                                   \
        void const* replacement;                                            \
        void const* replacee;                                               \
    } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = { \
        (void const*)(unsigned long)&_replacement,                          \
        (void const*)(unsigned long)&_replacee                              \
    };

XL_DYLD_INTERPOSE(xlUnwindHook_RaiseException, _Unwind_RaiseException)
XL_DYLD_INTERPOSE(xlUnwindHook_ForcedUnwind, _Unwind_ForcedUnwind)
