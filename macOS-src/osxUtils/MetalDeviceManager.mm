//
//  MetalDeviceManager.mm
//  xLights
//

#include <Metal/Metal.h>
#include <MetalKit/MetalKit.h>

#include <log.h>

#include "MetalDeviceManager.h"

MetalDeviceManager& MetalDeviceManager::instance() {
    static MetalDeviceManager mgr;
    return mgr;
}

void MetalDeviceManager::retain() {
    if (useCount.fetch_add(1) == 0) {
        initResources();
    }
}

void MetalDeviceManager::release() {
    if (useCount.fetch_sub(1) == 1) {
        teardownResources();
    }
}

void MetalDeviceManager::initResources() {
    device = MTLCreateSystemDefaultDevice();
    commandQueue = [device newCommandQueue];
    [commandQueue setLabel:@"xLightsMetalCommandQueue"];
    bltCommandQueue = [device newCommandQueue];
    [bltCommandQueue setLabel:@"xLightsBltCommandQueue"];

    MTLDepthStencilDescriptor* depthDescriptor = [MTLDepthStencilDescriptor new];
    depthDescriptor.depthCompareFunction = MTLCompareFunctionLessEqual;
    depthDescriptor.depthWriteEnabled = YES;
    depthStencilStateLE = [device newDepthStencilStateWithDescriptor:depthDescriptor];
    [depthDescriptor release];

    depthDescriptor = [MTLDepthStencilDescriptor new];
    depthDescriptor.depthCompareFunction = MTLCompareFunctionLess;
    depthDescriptor.depthWriteEnabled = YES;
    depthStencilStateL = [device newDepthStencilStateWithDescriptor:depthDescriptor];
    [depthDescriptor release];

    if ([device supportsTextureSampleCount:2]) {
        sampleCount = 2;
    } else if ([device supportsTextureSampleCount:4]) {
        sampleCount = 4;
    } else if ([device supportsTextureSampleCount:8]) {
        sampleCount = 8;
    }
}

void MetalDeviceManager::teardownResources() {
    auto clearPipelineMap = [](std::map<std::string, PipelineInfo>& m) {
        for (auto& a : m) {
            [a.second.state release];
            a.second.state = nil;
        }
        m.clear();
    };

    clearPipelineMap(pipelineStates2D);
    clearPipelineMap(blendedPipelineStates2D);
    clearPipelineMap(pipelineStates3D);
    clearPipelineMap(blendedPipelineStates3D);

    if (depthStencilStateLE) {
        [depthStencilStateLE release];
        depthStencilStateLE = nil;
    }
    if (depthStencilStateL) {
        [depthStencilStateL release];
        depthStencilStateL = nil;
    }
    if (commandQueue) {
        [commandQueue release];
        commandQueue = nil;
    }
    if (bltCommandQueue) {
        [bltCommandQueue release];
        bltCommandQueue = nil;
    }
    if (defaultLibrary) {
        [defaultLibrary release];
        defaultLibrary = nil;
    }
    if (device) {
        [device release];
        device = nil;
    }

    sampleCount = 1;
}

id<MTLRenderPipelineState> MetalDeviceManager::getPipelineState(const std::string& n,
                                                                 const char* vShader,
                                                                 const char* fShader,
                                                                 bool blending,
                                                                 bool is3d,
                                                                 bool msaa,
                                                                 MTLPixelFormat colorPixelFormat) {
    std::string name = n;
    if (!is3d && msaa) {
        name += "MSAA";
    }
    auto& a = is3d ? (blending ? blendedPipelineStates3D[name] : pipelineStates3D[name])
                   : (blending ? blendedPipelineStates2D[name] : pipelineStates2D[name]);
    if (a.state == nil) {
        if (defaultLibrary == nil) {
            defaultLibrary = [device newDefaultLibrary];
        }
        @autoreleasepool {
            MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
            [desc colorAttachments][0].pixelFormat = colorPixelFormat;
            if (blending) {
                [desc colorAttachments][0].blendingEnabled = true;
                [desc colorAttachments][0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
                [desc colorAttachments][0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                [desc colorAttachments][0].sourceAlphaBlendFactor = MTLBlendFactorOne;
                [desc colorAttachments][0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            }
            if (is3d) {
                [desc setDepthAttachmentPixelFormat:MTLPixelFormatDepth32Float];
            }
            if (msaa) {
                [desc setSampleCount:sampleCount];
            }
            NSString* nsVName = [[[NSString alloc] initWithUTF8String:vShader] autorelease];
            NSString* nsFName = [[[NSString alloc] initWithUTF8String:fShader] autorelease];

            desc.vertexFunction = [[defaultLibrary newFunctionWithName:nsVName] autorelease];
            desc.fragmentFunction = [[defaultLibrary newFunctionWithName:nsFName] autorelease];

            MTLVertexDescriptor* mtlVertexDescriptor = nil;
            if (n == "meshSolidProgram" || n == "meshTextureProgram" || n == "meshWireframeProgram") {
                mtlVertexDescriptor = [[MTLVertexDescriptor alloc] init];
                // Positions
                mtlVertexDescriptor.attributes[0].format = MTLVertexFormatFloat3;
                mtlVertexDescriptor.attributes[0].offset = 0;
                mtlVertexDescriptor.attributes[0].bufferIndex = 0;
                // Normals
                mtlVertexDescriptor.attributes[1].format = MTLVertexFormatFloat3;
                mtlVertexDescriptor.attributes[1].offset = 12;
                mtlVertexDescriptor.attributes[1].bufferIndex = 0;
                // Texture coordinates
                mtlVertexDescriptor.attributes[2].format = MTLVertexFormatFloat2;
                mtlVertexDescriptor.attributes[2].offset = 24;
                mtlVertexDescriptor.attributes[2].bufferIndex = 0;
                // Single interleaved buffer
                mtlVertexDescriptor.layouts[0].stride = 32;
                mtlVertexDescriptor.layouts[0].stepRate = 1;
                mtlVertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
                desc.vertexDescriptor = mtlVertexDescriptor;
            } else if (n == "indexedColorProgram" || n == "indexedColorPointsProgram") {
                mtlVertexDescriptor = [[MTLVertexDescriptor alloc] init];
                // Positions X
                mtlVertexDescriptor.attributes[0].format = MTLVertexFormatFloat;
                mtlVertexDescriptor.attributes[0].offset = 0;
                mtlVertexDescriptor.attributes[0].bufferIndex = 0;
                // Positions Y
                mtlVertexDescriptor.attributes[1].format = MTLVertexFormatFloat;
                mtlVertexDescriptor.attributes[1].offset = 4;
                mtlVertexDescriptor.attributes[1].bufferIndex = 0;
                // Positions Z
                mtlVertexDescriptor.attributes[2].format = MTLVertexFormatFloat;
                mtlVertexDescriptor.attributes[2].offset = 8;
                mtlVertexDescriptor.attributes[2].bufferIndex = 0;
                // Color index
                mtlVertexDescriptor.attributes[3].format = MTLVertexFormatUInt;
                mtlVertexDescriptor.attributes[3].offset = 12;
                mtlVertexDescriptor.attributes[3].bufferIndex = 0;
                // Single interleaved buffer
                mtlVertexDescriptor.layouts[0].stride = 16;
                mtlVertexDescriptor.layouts[0].stepRate = 1;
                mtlVertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
                desc.vertexDescriptor = mtlVertexDescriptor;
            }

            NSError* nserror;
            a.state = [[device newRenderPipelineStateWithDescriptor:desc error:&nserror] retain];
            [desc release];
            if (mtlVertexDescriptor != nil) {
                [mtlVertexDescriptor release];
            }
            if (nserror) {
                NSString* err = [NSString stringWithFormat:@"%@", nserror];
                spdlog::info("Could not create render pipeline for {}:  {}", name, [err UTF8String]);
                [nserror release];
            }
        }
    }
    return a.state;
}
