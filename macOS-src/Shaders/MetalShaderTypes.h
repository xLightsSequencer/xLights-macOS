//
//  MetalShaderTypes.h
//  xLights-macOSLib
//
//  Created by Daniel Kulp on 10/27/21.
//  Copyright © 2021 Daniel Kulp. All rights reserved.
//

#pragma once

#include <simd/simd.h>

// Buffer index values shared between shader and C code to ensure Metal shader buffer inputs match
//   Metal API buffer set calls
typedef enum BufferIndex
{
    BufferIndexMeshPositions     = 0,
    BufferIndexMeshColors        = 1,
    BufferIndexFrameData         = 2,
    BufferIndexTexturePositions  = 3
} BufferIndex;

typedef enum RenderType {
    RenderTypeNormal        = 0,
    RenderTypePoints        = 1,
    RenderTypePointsSmooth  = 2,
    RenderTypeTexture       = 3
} RenderType;

typedef enum TextureIndex {
    TextureIndexBase            = 0,
} TextureIndex;

// Structures shared between shader and C code to ensure the layout of per frame data
//    accessed in Metal shaders matches the layout of fra data set in C code
//    Data constant across all threads, vertices, and fragments
struct FrameData
{
    simd::float4x4 MVP;
    simd::float4x4 modelMatrix;
    simd::float4x4 viewMatrix;
    simd::float4x4 perspectiveMatrix;

    int renderType;

    simd::float4 fragmentColor;
    float brightness;
    bool  applyShading;

    // for points, we need the size and the smoothness
    float pointSize;
    float pointSmoothMin;
    float pointSmoothMax;
    
};
