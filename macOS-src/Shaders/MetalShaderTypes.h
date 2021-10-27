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
} BufferIndex;

// Structures shared between shader and C code to ensure the layout of per frame data
//    accessed in Metal shaders matches the layout of fra data set in C code
//    Data constant across all threads, vertices, and fragments
struct FrameData
{
    // Per Frame Uniforms
    simd::float4x4 MVP;
    uint RenderType;

    simd::float4 fragmentColor;

    float PointSmoothMin;
    float PointSmoothMax;

};
