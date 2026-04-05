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

// MetalDeviceManager — owns shared Metal state (device, queues, library,
// depth-stencil states, pipeline caches, MSAA sample count).
// Wx-free; lives in the core graphics layer so both desktop (wxMetalCanvas)
// and future iPad canvases can share the same Metal resources.

#include <atomic>
#include <map>
#include <string>

#ifdef __OBJC__
#import <Metal/Metal.h>
#endif

class MetalDeviceManager {
public:
    static MetalDeviceManager& instance();

    // Reference counting — call retain() when creating a canvas,
    // release() when destroying one.  Resources are created on first
    // retain and torn down on last release.
    void retain();
    void release();

#ifdef __OBJC__
    id<MTLDevice>              getMTLDevice()          const { return device; }
    id<MTLCommandQueue>        getMTLCommandQueue()    const { return commandQueue; }
    id<MTLCommandQueue>        getBltCommandQueue()    const { return bltCommandQueue; }
    id<MTLLibrary>             getMTLLibrary()         const { return defaultLibrary; }
    id<MTLDepthStencilState>   getDepthStencilStateLE() const { return depthStencilStateLE; }
    id<MTLDepthStencilState>   getDepthStencilStateL()  const { return depthStencilStateL; }
    int                        getMSAASampleCount()    const { return sampleCount; }

    // Pipeline state cache — keyed by name, with variants for 2D/3D
    // and blended/non-blended.
    id<MTLRenderPipelineState> getPipelineState(const std::string& name,
                                                const char* vShader,
                                                const char* fShader,
                                                bool blending,
                                                bool is3d,
                                                bool msaa,
                                                MTLPixelFormat colorPixelFormat);
#endif

    MetalDeviceManager(const MetalDeviceManager&) = delete;
    MetalDeviceManager& operator=(const MetalDeviceManager&) = delete;
    MetalDeviceManager(MetalDeviceManager&&) = delete;
    MetalDeviceManager& operator=(MetalDeviceManager&&) = delete;

private:
    MetalDeviceManager() = default;
    ~MetalDeviceManager() = default;

    void initResources();
    void teardownResources();

    std::atomic_int useCount{0};

#ifdef __OBJC__
    // Per-process shared Metal objects
    id<MTLDevice>            device            = nil;
    id<MTLCommandQueue>      commandQueue      = nil;
    id<MTLCommandQueue>      bltCommandQueue   = nil;
    id<MTLLibrary>           defaultLibrary    = nil;
    id<MTLDepthStencilState> depthStencilStateLE = nil;
    id<MTLDepthStencilState> depthStencilStateL  = nil;
    int                      sampleCount       = 1;

    struct PipelineInfo {
        id<MTLRenderPipelineState> state = nil;
    };

    std::map<std::string, PipelineInfo> pipelineStates2D;
    std::map<std::string, PipelineInfo> blendedPipelineStates2D;
    std::map<std::string, PipelineInfo> pipelineStates3D;
    std::map<std::string, PipelineInfo> blendedPipelineStates3D;
#endif
};
