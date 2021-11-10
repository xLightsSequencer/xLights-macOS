//
//  MetalShaders.metal
//
//  Copyright © 2021 Daniel Kulp. All rights reserved.
//

#include <metal_stdlib>
#include <simd/simd.h>

#include "MetalShaderTypes.h"

using namespace metal;


vertex float4 singleColorVertexShader(const device float3 *vertices  [[buffer(BufferIndexMeshPositions)]],
                                      constant FrameData  &frameData [[ buffer(BufferIndexFrameData) ]],
                                      uint vid [[vertex_id]]){
    return frameData.MVP * float4(vertices[vid], 1.0);
}
fragment float4 singleColorFragmentShader(float4 in [[stage_in]],
                                          constant FrameData  &frameData [[ buffer(BufferIndexFrameData) ]]){

    return frameData.fragmentColor;
}

struct MultiVertexData {
    float4 vert [[position]];
    float4 color;
};
vertex MultiVertexData multiColorVertexShader(const device float3 *vertices  [[buffer(BufferIndexMeshPositions)]],
                                              const device uchar4 *colors  [[buffer(BufferIndexMeshColors)]],
                                              constant FrameData  &frameData [[ buffer(BufferIndexFrameData) ]],
                                              uint vid [[vertex_id]]){
    float4 color = float4(colors[vid].r, colors[vid].g, colors[vid].b, colors[vid].a);
    color /= 255.0f;
    MultiVertexData d = { frameData.MVP * float4(vertices[vid], 1.0), color };
    return d;
}
fragment float4 multiColorFragmentShader(MultiVertexData in [[stage_in]],
                                         constant FrameData  &frameData [[ buffer(BufferIndexFrameData) ]]){
    return in.color;
}


struct TextureVertexData {
    float4 vert [[position]];;
    float2 texPosition;
};
vertex TextureVertexData textureVertexShader(const device float3 *vertices  [[buffer(BufferIndexMeshPositions)]],
                                             const device float2 *tvertices  [[buffer(BufferIndexTexturePositions)]],
                                             constant FrameData  &frameData [[ buffer(BufferIndexFrameData) ]],
                                             uint vid [[vertex_id]]){
    TextureVertexData d = { frameData.MVP * float4(vertices[vid], 1.0), tvertices[vid] };
    return d;
}
fragment float4 textureFragmentShader(TextureVertexData in [[stage_in]],
                                      texture2d<float>  texture [[ texture(TextureIndexBase) ]],
                                      constant FrameData  &frameData [[ buffer(BufferIndexFrameData) ]]) {
    constexpr sampler linearSampler(mip_filter::none,
                                    mag_filter::linear,
                                    min_filter::linear);

    float4 sample = texture.sample(linearSampler, in.texPosition);
    return sample;
}
fragment float4 textureNearestFragmentShader(TextureVertexData in [[stage_in]],
                                             texture2d<float, access::sample>  texture [[ texture(TextureIndexBase) ]],
                                             constant FrameData  &frameData [[ buffer(BufferIndexFrameData) ]]) {
    constexpr sampler nearestSampler(mip_filter::none,
                                    mag_filter::nearest,
                                    min_filter::linear);

    float4 sample = texture.sample(nearestSampler, in.texPosition);
    return sample;
}
fragment float4 textureColorFragmentShader(TextureVertexData in [[stage_in]],
                                      texture2d<float>  texture [[ texture(TextureIndexBase) ]],
                                      constant FrameData  &frameData [[ buffer(BufferIndexFrameData) ]]) {
    constexpr sampler linearSampler(mip_filter::none,
                                    mag_filter::linear,
                                    min_filter::linear);

    float4 sample = texture.sample(linearSampler, in.texPosition);
    return float4(frameData.fragmentColor.rgb, sample.a * frameData.fragmentColor.a);;
}
