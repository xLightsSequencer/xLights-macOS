//
//  MetalShaders.metal
//
//  Copyright © 2021 Daniel Kulp. All rights reserved.
//

#include <metal_stdlib>
#include <simd/simd.h>

#include "MetalShaderTypes.h"

using namespace metal;

struct ColorVertexData {
    float4 vert [[position]];
    float4 color;
};

vertex ColorVertexData singleColorVertexShader(const device float3 *vertices  [[buffer(BufferIndexMeshPositions)]],
                                      constant FrameData  &frameData [[ buffer(BufferIndexFrameData) ]],
                                      uint vid [[vertex_id]]){
    return {frameData.MVP * float4(vertices[vid], 1.0), frameData.fragmentColor };
}
fragment float4 singleColorFragmentShader(ColorVertexData in [[stage_in]]){
    return in.color;
}

vertex ColorVertexData multiColorVertexShader(const device float3 *vertices  [[buffer(BufferIndexMeshPositions)]],
                                              const device uchar4 *colors  [[buffer(BufferIndexMeshColors)]],
                                              constant FrameData  &frameData [[ buffer(BufferIndexFrameData) ]],
                                              uint vid [[vertex_id]]){
    float4 color = float4(colors[vid].r, colors[vid].g, colors[vid].b, colors[vid].a);
    color /= 255.0f;
    return { frameData.MVP * float4(vertices[vid], 1.0), color };
}
fragment float4 multiColorFragmentShader(ColorVertexData in [[stage_in]]){
    return in.color;
}


struct TextureVertexData {
    float4 vert [[position]];;
    float2 texPosition;
    float4 forceColor;
};
vertex TextureVertexData textureVertexShader(const device float3 *vertices  [[buffer(BufferIndexMeshPositions)]],
                                             const device float2 *tvertices  [[buffer(BufferIndexTexturePositions)]],
                                             constant FrameData  &frameData [[ buffer(BufferIndexFrameData) ]],
                                             uint vid [[vertex_id]]){
    TextureVertexData d = { frameData.MVP * float4(vertices[vid], 1.0), tvertices[vid] , frameData.fragmentColor};
    return d;
}
fragment float4 textureFragmentShader(TextureVertexData in [[stage_in]],
                                      texture2d<float>  texture [[ texture(TextureIndexBase) ]]) {
    constexpr sampler linearSampler(mip_filter::none,
                                    mag_filter::linear,
                                    min_filter::linear);

    float4 sample = texture.sample(linearSampler, in.texPosition);
    return sample;
}
fragment float4 textureNearestFragmentShader(TextureVertexData in [[stage_in]],
                                             texture2d<float, access::sample>  texture [[ texture(TextureIndexBase) ]]) {
    constexpr sampler nearestSampler(mip_filter::none,
                                    mag_filter::nearest,
                                    min_filter::linear);

    float4 sample = texture.sample(nearestSampler, in.texPosition);
    return sample;
}
fragment float4 textureColorFragmentShader(TextureVertexData in [[stage_in]],
                                      texture2d<float>  texture [[ texture(TextureIndexBase) ]]) {
    constexpr sampler linearSampler(mip_filter::none,
                                    mag_filter::linear,
                                    min_filter::linear);

    float4 sample = texture.sample(linearSampler, in.texPosition);
    return float4(in.forceColor.rgb, sample.a * in.forceColor.a);;
}
