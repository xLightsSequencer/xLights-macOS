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
    half4 color;

    int renderType;
    float  pointSize [[point_size]];
    float  pointSmoothMin;
    float  pointSmoothMax;
};

vertex ColorVertexData singleColorVertexShader(const device float3 *vertices  [[buffer(BufferIndexMeshPositions)]],
                                      constant FrameData  &frameData [[ buffer(BufferIndexFrameData) ]],
                                      uint vid [[vertex_id]]){
    return {
            frameData.MVP * float4(vertices[vid], 1.0), half4(frameData.fragmentColor),
            frameData.renderType, frameData.pointSize, frameData.pointSmoothMin, frameData.pointSmoothMax
    };
}

vertex ColorVertexData multiColorVertexShader(const device float3 *vertices  [[buffer(BufferIndexMeshPositions)]],
                                              const device uchar4 *colors  [[buffer(BufferIndexMeshColors)]],
                                              constant FrameData  &frameData [[ buffer(BufferIndexFrameData) ]],
                                              uint vid [[vertex_id]]){
    half4 color = half4(colors[vid].r, colors[vid].g, colors[vid].b, colors[vid].a);
    color /= 255.0f;
    return {
        frameData.MVP * float4(vertices[vid], 1.0), color,
        frameData.renderType, frameData.pointSize, frameData.pointSmoothMin, frameData.pointSmoothMax
    };
}

struct IndexedColorData {
    float positionx [[attribute(0)]];
    float positiony [[attribute(1)]];
    float positionz [[attribute(2)]];
    uint32_t colorIndex [[attribute(3)]];
};
vertex ColorVertexData indexedColorVertexShader(IndexedColorData vertices [[stage_in]],
                                                const device uchar4 *colors  [[buffer(BufferIndexMeshColors)]],
                                                constant FrameData  &frameData [[ buffer(BufferIndexFrameData) ]]){
    uint32_t cidx = vertices.colorIndex;
    half4 color = half4(colors[cidx].r, colors[cidx].g, colors[cidx].b, colors[cidx].a);
    color /= 255.0f;
    return {
        frameData.MVP * float4(vertices.positionx, vertices.positiony, vertices.positionz, 1.0), color,
        frameData.renderType, frameData.pointSize, frameData.pointSmoothMin, frameData.pointSmoothMax
    };
}

fragment half4 colorFragmentShader(ColorVertexData in [[stage_in]],
                                    float2 pointCoord [[point_coord]]){
    return in.color;
}
fragment half4 pointSmoothFragmentShader(ColorVertexData in [[stage_in]],
                                          float2 pointCoord [[point_coord]]){
    float dist = length(pointCoord - float2(0.5));
    half4 out_color = in.color;
    out_color.a *= 1.0 - smoothstep(in.pointSmoothMin, in.pointSmoothMax, dist);
    if (out_color.a == 0) discard_fragment();
    return out_color;
}


struct TextureVertexData {
    float4 vert [[position]];;
    float2 texPosition;
    half4 forceColor;
};
vertex TextureVertexData textureVertexShader(const device float3 *vertices  [[buffer(BufferIndexMeshPositions)]],
                                             const device float2 *tvertices  [[buffer(BufferIndexTexturePositions)]],
                                             constant FrameData  &frameData [[ buffer(BufferIndexFrameData) ]],
                                             uint vid [[vertex_id]]){
    TextureVertexData d = { frameData.MVP * float4(vertices[vid], 1.0), tvertices[vid] , half4(frameData.fragmentColor)};
    return d;
}
fragment half4 textureFragmentShader(TextureVertexData in [[stage_in]],
                                      texture2d<half>  texture [[ texture(TextureIndexBase) ]]) {
    constexpr sampler linearSampler(mip_filter::none,
                                    mag_filter::linear,
                                    min_filter::linear);

    half4 sample = texture.sample(linearSampler, in.texPosition);
    return sample * in.forceColor;
}
fragment half4 textureNearestFragmentShader(TextureVertexData in [[stage_in]],
                                             texture2d<half, access::sample>  texture [[ texture(TextureIndexBase) ]]) {
    constexpr sampler nearestSampler(mip_filter::none,
                                    mag_filter::nearest,
                                    min_filter::linear);

    half4 sample = texture.sample(nearestSampler, in.texPosition);
    return sample * in.forceColor;
}
fragment half4 textureColorFragmentShader(TextureVertexData in [[stage_in]],
                                      texture2d<float>  texture [[ texture(TextureIndexBase) ]]) {
    constexpr sampler linearSampler(mip_filter::none,
                                    mag_filter::linear,
                                    min_filter::linear);

    float4 sample = texture.sample(linearSampler, in.texPosition);
    return half4(in.forceColor.rgb, sample.a * in.forceColor.a);;
}





// Variables in constant address space.
constant float3 lightDirection = float3(0.1, 0.1, 1);

// Per-vertex input structure
struct MeshVertexInput {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 texcoord [[attribute(2)]];
};

// Per-vertex output and per-fragment input
typedef struct {
    float4 position [[position]];
    half4 color;
    float2 texcoord;
    int    renderType;
    float  brightness;
    float  cosTheta;
} MeshShaderInOut;

// Vertex shader function
vertex MeshShaderInOut meshVertexShader(MeshVertexInput     in [[stage_in]],
                                        constant FrameData  &frameData [[ buffer(BufferIndexFrameData) ]]) {
    MeshShaderInOut out;
    
    //1. Vertex projection and translation
    float4 in_position = float4(in.position, 1.0);
    out.position = frameData.MVP * in_position;
    
    if (frameData.fragmentColor.a == 1.0 && frameData.applyShading) {
        // Normal of the the vertex, in world space
        float3 normal_cameraspace = ( frameData.viewMatrix * frameData.modelMatrix * float4(in.normal,0)).xyz;

        // Normal of the computed fragment, in camera space
        float3 n = normalize( normal_cameraspace );
        // Direction of the light (from the fragment to the light)
        float3 l = normalize( lightDirection );
        float cosTheta = abs(clamp(dot( n, l ), -1.0, 1.0));

        float4 color = float4(cosTheta, cosTheta, cosTheta, 1.0);
        out.color = half4(frameData.fragmentColor * color)*0.75 + half4(frameData.fragmentColor*0.25);
        out.cosTheta = cosTheta;
    } else {
        out.color = half4(frameData.fragmentColor);
        out.cosTheta = 1.0f;
    }
    
    // Pass through texture coordinate
    out.texcoord = in.texcoord;
    out.renderType = frameData.renderType;
    out.brightness = frameData.brightness;
    return out;
}

vertex MeshShaderInOut meshWireframeVertexShader(MeshVertexInput     in [[stage_in]],
                                                 constant FrameData  &frameData [[ buffer(BufferIndexFrameData) ]]) {
    MeshShaderInOut out;
    
    //1. Vertex projection and translation
    float4 in_position = float4(in.position, 1.0);
    out.position = frameData.MVP * in_position;
    
    out.color = half4(frameData.fragmentColor);
    
    // Pass through texture coordinate
    out.texcoord = in.texcoord;
    out.renderType = frameData.renderType;
    out.brightness = frameData.brightness;
    return out;
}

// Fragment shader function
fragment half4 meshTextureFragmentShader(MeshShaderInOut in [[stage_in]],
                                   texture2d<half>  diffuseTexture [[ texture(BufferIndexTexturePositions) ]]) {
    constexpr sampler defaultSampler(coord::normalized,
                                     address::repeat,
                                     filter::linear);
    
    // Blend texture color with input color and output to framebuffer
    //float4 color =  diffuseTexture.sample(defaultSampler, float2(in.texcoord)) * in.color;
    half4 color =  diffuseTexture.sample(defaultSampler, float2(in.texcoord));
    //float4 color =  float4(1, 0, 0, 1);
    //float4 color =  in.color;
    color = half4( color.r * in.brightness, color.g * in.brightness, color.b * in.brightness, color.a );
    if (in.cosTheta != 1.0) {
        half3 c3 = half3(in.cosTheta * color.rgb)*0.75 + half3(color.rgb*0.25);
        color = half4(c3, color.a);
    }
    return color;
}
// Fragment shader function for the mesh solids
fragment half4 meshSolidFragmentShader(MeshShaderInOut in [[stage_in]]) {
    half4 color = in.color;
    //float4 color =  float4(1, 0, 0, 1);
    //float4 color =  in.color;
    return half4( color.r * in.brightness, color.g * in.brightness, color.b * in.brightness, color.a );
}
