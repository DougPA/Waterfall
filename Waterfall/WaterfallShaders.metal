//
//  WaterfallShaders.metal
//  xSDR6000
//
//  Created by Douglas Adams on 10/9/17.
//  Copyright © 2017 Douglas Adams. All rights reserved.
//

#include <metal_stdlib>
using namespace metal;

// --------------------------------------------------------------------------------
// MARK: - Shader structures
// --------------------------------------------------------------------------------

struct Vertex {
    float2  coord;                      // waterfall coordinates
    float2  texCoord;                   // texture coordinates
};

struct VertexOutput {                   // common vertex output
    float4  coord [[ position ]];       // vertex coordinates
    float2  texCoord;                   // texture coordinates
    float4  spectrumColor;              // color
};

// --------------------------------------------------------------------------------
// MARK: - Compute Shader for Gradient calculations
// --------------------------------------------------------------------------------

kernel void convert(texture2d<ushort, access::read> inTexture [[texture(0)]],
                    texture2d<float, access::write> outTexture [[texture(1)]],
                    uint2 gid [[thread_position_in_grid]])
{
    float4 colorAtPixel;
    
    ushort intensity = inTexture.read(gid).r;
    
    if (intensity >= 0 && intensity < 21845) {
        colorAtPixel = float4(0.0, 0.0, 0.0, 1.0);  // black
    }
    if (intensity >= 21845 && intensity < 43690) {
        colorAtPixel = float4(0.0, 1.0, 0.0, 1.0);  // green
    }
    if (intensity >= 43690 && intensity < 65535) {
        colorAtPixel = float4(1.0, 1.0, 0.0, 1.0);  // yellow
    }
    if (intensity == 65535) {
        colorAtPixel = float4(1.0, 0.0, 0.0, 1.0);  // red
    }
    
    outTexture.write(colorAtPixel, gid);
}
// --------------------------------------------------------------------------------
// MARK: - Shaders for Waterfall Spectrum draw calls
// --------------------------------------------------------------------------------

// Spectrum vertex shader
//
//  - Parameters:
//    - vertices:       an array of vertices at position 0 (in problem space, ushort i.e. 16-bit unsigned)
//    - vertexId:       a system generated vertex index
//    - uniforms:       the unifirm struct at position 1
//
//  - Returns:          a VertexOutput struct
//
vertex VertexOutput waterfall_vertex(const device Vertex* vertices [[ buffer(0) ]],
                                    unsigned int vertexId [[ vertex_id ]])
{
    VertexOutput v_out;
    
    v_out.coord = float4(vertices[vertexId].coord.xy, 0.0, 1.0);
    v_out.texCoord = float2(vertices[vertexId].texCoord.x, vertices[vertexId].texCoord.y);

    return v_out;
}

// Spectrum fragment shader
///
//  - Parameters:
//    - in:             VertexOutput struct
//  - Returns:          the fragment color
//
fragment float4 waterfall_fragment( VertexOutput in [[ stage_in ]],
                                   texture2d<float, access::sample> tex2d [[texture(0)]],
                                   sampler sampler2d [[sampler(0)]])
{
    // the texture color
    return float4( tex2d.sample(sampler2d, in.texCoord).rgba);
}

