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

struct SpectrumValue {                  
    ushort  i;                          // intensity
};

struct Uniforms {                       
    float   numberOfBins;               // # of bins in stream width
    float   numberOfDisplayBins;        // # of bins in display width
    float   halfBinWidth;               // clip space x offset (half of a bin)
};

struct VertexOutput {                   // common vertex output
    float4  coord [[ position ]];       // vertex coordinates
    float4  spectrumColor;              // color
};

// --------------------------------------------------------------------------------
// MARK: - Shaders for Waterfall Spectrum draw calls
// --------------------------------------------------------------------------------

// Spectrum vertex shader
//
//  Parameters:
//      vertices:       an array of vertices at position 0 (in problem space, ushort i.e. 16-bit unsigned)
//      vertexId:       a system generated vertex index
//      uniforms:       the unifirm struct at position 1
//
//  Returns:
//      a VertexOutput struct
//
vertex VertexOutput waterfall_vertex(const device SpectrumValue* intensities [[ buffer(0) ]],
                                    unsigned int vertexId [[ vertex_id ]],
                                    constant Uniforms &uniforms [[ buffer(1) ]])
{
    VertexOutput v_out;
    float xCoord;
    float intensity;
    
    // get the intensity
    intensity = float(intensities[vertexId].i) / 65535.0 ;
    
    // calculate the x coordinate (in clip space)
    xCoord = uniforms.halfBinWidth + (2.0 * float(vertexId) / uniforms.numberOfDisplayBins) - (1.0 * (uniforms.numberOfBins / uniforms.numberOfDisplayBins));

    // send the clip space coords to the fragment shader
    v_out.coord = float4( xCoord, 0.0, 0.0, 1.0);
    
    // pass the color to the fragment shader
    v_out.spectrumColor = float4(1.0, 0.0, 0.0, 1.0);
    
    return v_out;
}

// Spectrum fragment shader
//  Parameters:
//      in:         VertexOutput struct
//
//  Returns:
//      the fragment color
//
fragment float4 waterfall_fragment( VertexOutput in [[ stage_in ]])
{
    // the calculated color
    return in.spectrumColor;
}

