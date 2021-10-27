//
//  MetalShaders.metal
//
//  Copyright © 2021 Daniel Kulp. All rights reserved.
//

#include <metal_stdlib>
#include <simd/simd.h>

#include "MetalShaderTypes.h"

using namespace metal;


//Vertex Function (Shader)
vertex float4 singleColorVertexShader(const device float4 *vertices  [[buffer(BufferIndexMeshPositions)]],
                                      constant FrameData  &frameData [[ buffer(BufferIndexFrameData) ]],
                                      uint vid [[vertex_id]]){
    return frameData.MVP * vertices[vid];
}

//Fragment Function (Shader)
fragment float4 singleColorFragmentShader(float4 in [[stage_in]],
                                          float2 pointCoord  [[point_coord]],
                                          constant FrameData  &frameData [[ buffer(BufferIndexFrameData) ]]){

    if (frameData.RenderType == 0) {
        return frameData.fragmentColor;
    } else {
        float dist = distance(pointCoord, float2(0.5));
        float alpha = 1.0 - smoothstep(frameData.PointSmoothMin, frameData.PointSmoothMax, dist);
        if (alpha == 0.0) discard_fragment();
        alpha = alpha * frameData.fragmentColor.a;
        return float4(frameData.fragmentColor.rgb, alpha);
    }
}
