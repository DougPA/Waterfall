//
//  WaterfallLayer.swift
//  xSDR6000
//
//  Created by Douglas Adams on 10/7/17.
//  Copyright © 2017 Douglas Adams. All rights reserved.
//

import Foundation
import MetalKit

public final class WaterfallLayer: CAMetalLayer, CALayerDelegate {
    
    //  NOTE:
    //
    //  As input, the renderer expects an array of UInt16 intensity values. The intensity values are
    //  scaled by the radio to be between zero and UInt16.max.
    //  The Waterfall sends an array of size ??? (larger than frame.width). Only the usable portion
    //  is displayed because of the clip space conversion (values outside of -1 to +1 are ignored).
    //
    
    struct Vertex {
        var coord                                   : float2    // waterfall coordinates
        var texCoord                                : float2    // texture coordinates
    }
    
    struct Uniforms {
        var numberOfBins                            : Float     // # of bins in stream width
        var numberOfDisplayBins                     : Float     // # of bins in display width
        var halfBinWidth                            : Float     // clip space x offset (half of a bin)
    }
    
    static let kMaxIntensities                      = 8         // max number of intensity values (bins)

    // ----------------------------------------------------------------------------
    // MARK: - Public properties
    
    // ----------------------------------------------------------------------------
    // MARK: - Private properties    

    //  Vertices    v1  (-1, 1)     |     ( 1, 1)  v3       Texture     v1  ( 0, 1) |           ( 1, 1)  v3
    //  (-1 to +1)                  |                       (0 to 1)                |
    //                          ----|----                                           |
    //                              |                                               |
    //              v0  (-1,-1)     |     ( 1,-1)  v2                   v0  ( 0, 0) |---------  ( 1, 0)  v2
    //
    fileprivate var _waterfallVertices              : [Vertex] = [
        Vertex(coord: float2(-1.0, -1.0), texCoord: float2( 0.0, 0.0)),         // v0
        Vertex(coord: float2(-1.0,  1.0), texCoord: float2( 0.0, 1.0)),         // v1
        Vertex(coord: float2( 1.0, -1.0), texCoord: float2( 1.0, 0.0)),         // v2
        Vertex(coord: float2( 1.0,  1.0), texCoord: float2( 1.0, 1.0))          // v3
    ]
    fileprivate var _waterfallVerticesBuffer        :MTLBuffer!
    fileprivate var _waterfallPipelineState         :MTLRenderPipelineState!
    
    fileprivate var _uniforms                       :Uniforms!
    fileprivate var _uniformsBuffer                 :MTLBuffer?
    fileprivate var _texture                        :MTLTexture!
    fileprivate var _samplerState                   :MTLSamplerState!
    fileprivate var _commandQueue                   :MTLCommandQueue!
    fileprivate var _clearColor                     :MTLClearColor?

    fileprivate var _numberOfBins                   : Int = 0
    fileprivate var _binWidthHz                     : CGFloat = 0.0
    fileprivate var _firstPass                      = true
    
    fileprivate var _texDuration                    = 0                         // seconds
    fileprivate var _waterfallDuration              = 0                         // seconds
    fileprivate var _lineDuration                   = 100                       // milliseconds
    fileprivate var _texPosition                    = 2048 - 1                   // current "top" line

    fileprivate var _yOffset                        : Float = 0.0               // tex vertical offset
    fileprivate var _stepValue                      : Float = 0.0               // tex
    fileprivate var _heightPercent                  : Float = 0.0               // tex
    fileprivate var _startBinNumber                 = 1808
    fileprivate var _endBinNumber                   = 2288

    fileprivate let kTextureWidth                   = 4096                      // must be >= max number of Bins
    fileprivate let kTextureHeight                  = 2048                      // must be >= max number of lines
    fileprivate let kBlackRGBA                      : UInt32 = 0xFF000000       // Black color in RGBA format
    fileprivate let kRedRGBA                        : UInt32 = 0xFF0000FF       // Red color in RGBA format
    fileprivate let kGreenRGBA                      : UInt32 = 0xFF00FF00       // Green color in RGBA format
    fileprivate let kBlueRGBA                       : UInt32 = 0xFFFF0000       // Blue color in RGBA format

    var lines = [[UInt32](repeating: 0xFF0000FF, count: 4096), [UInt32](repeating: 0xFF00FF00, count: 4096), [UInt32](repeating: 0xFFFF0000, count: 4096)]

    // constants
    fileprivate let _log                            = (NSApp.delegate as! AppDelegate)
    fileprivate let kWaterfallVertex                = "waterfall_vertex"
    fileprivate let kWaterfallFragment              = "waterfall_fragment"

    // ----------------------------------------------------------------------------
    // MARK: - Public methods
    
    /// Draw in a Metal layer
    ///
    public func render() {

        // obtain a drawable
        guard let drawable = nextDrawable() else { return }
        
        // create a command buffer
        let cmdBuffer = _commandQueue.makeCommandBuffer()
        
        // Draw the Spectrum
        drawSpectrum(with: drawable, cmdBuffer: cmdBuffer!)
        
        // add a final command to present the drawable to the screen
        cmdBuffer!.present(drawable)
        
        // finalize rendering & push the command buffer to the GPU
        cmdBuffer!.commit()
    }
    
    // ----------------------------------------------------------------------------
    // MARK: - Internal methods
    
    func updateTexCoords(_ linesIndex: Int) {

        // calculate texture duration (seconds)
        _texDuration = (_lineDuration * kTextureHeight) / 1_000
        
        // copy a colored line into the texture @ the texPosition
        let uint8Ptr = UnsafeRawPointer(lines[linesIndex]).bindMemory(to: UInt8.self, capacity: kTextureWidth * 4)
        let region = MTLRegionMake2D(0, _texPosition, kTextureWidth, 1)
        _texture.replace(region: region, mipmapLevel: 0, withBytes: uint8Ptr, bytesPerRow: kTextureWidth * 4)
        
        Swift.print("_pos = \(_texPosition)")
        
        // calculate waterfall duration (seconds)
        _waterfallDuration = Int( (CGFloat(_lineDuration) * frame.height ) / 1_000 )
        
        // calculate texture coordinate adjustments
        _yOffset = Float(_texPosition) / Float(kTextureHeight - 1)          // % texture height from texPosition 0
        _stepValue = 1.0 / Float(kTextureHeight - 1)                        // dist between lines
        _heightPercent = Float(_waterfallDuration) / Float(_texDuration)    // % waterfall duration of texture duration
        
        // texture y coordinates (clip space)
//        _waterfallVertices[3].texCoord.y = (1 + _yOffset - _stepValue)
//        _waterfallVertices[2].texCoord.y = (1 + _yOffset - _heightPercent)
//        _waterfallVertices[1].texCoord.y = (1 + _yOffset - _stepValue)
//        _waterfallVertices[0].texCoord.y = (1 + _yOffset - _heightPercent)
        _waterfallVertices[3].texCoord.y = _waterfallVertices[3].texCoord.y +  Float( 1.0 / (Float(kTextureHeight) - 1.0))
        _waterfallVertices[2].texCoord.y = _waterfallVertices[2].texCoord.y +  Float( 1.0 / (Float(kTextureHeight) - 1.0))
        _waterfallVertices[1].texCoord.y = _waterfallVertices[1].texCoord.y +  Float( 1.0 / (Float(kTextureHeight) - 1.0))
        _waterfallVertices[0].texCoord.y = _waterfallVertices[0].texCoord.y +  Float( 1.0 / (Float(kTextureHeight) - 1.0))

        // texture x coordinates (clip space)
        _waterfallVertices[3].texCoord.x = Float(_endBinNumber) / Float(kTextureWidth - 1)
        _waterfallVertices[2].texCoord.x = Float(_endBinNumber) / Float(kTextureWidth - 1)
        _waterfallVertices[1].texCoord.x = Float(_startBinNumber) / Float(kTextureWidth)
        _waterfallVertices[0].texCoord.x = Float(_startBinNumber) / Float(kTextureWidth)

//        Swift.print("\(_waterfallVertices)")
        
        // update the Waterfall vertices buffer
        let size = MemoryLayout.stride(ofValue: _waterfallVertices[0])
        let bufferPtr = _waterfallVerticesBuffer!.contents()
        memcpy(bufferPtr, &_waterfallVertices, size * _waterfallVertices.count)

//        Swift.print("x0=\(_waterfallVertices[0].texCoord.x),y0=\(_waterfallVertices[0].texCoord.y) x1=\(_waterfallVertices[1].texCoord.x),y1=\(_waterfallVertices[1].texCoord.y) x2=\(_waterfallVertices[2].texCoord.x),y2=\(_waterfallVertices[2].texCoord.y) x3=\(_waterfallVertices[3].texCoord.x),y3=\(_waterfallVertices[3].texCoord.y)")
        
        
        _texPosition = (_texPosition + 1) % kTextureHeight
//        // decrement the position in the texture (wraps)
//        if _texPosition == 0 {
//            _texPosition = kTextureHeight - 1
//        } else {
//            _texPosition -= 1
//        }
    }
    
    func loadTexture() {
        
        // load the texture from the assets.xcassets (all black)
        let loader = MTKTextureLoader(device: device!)
        _texture = try! loader.newTexture(name: "BlackTexture", scaleFactor: 1.0, bundle: nil, options: nil)
    }
    
    /// Populate Uniform values
    ///
    func populateUniforms(numberOfBins: Int, numberOfDisplayBins: Int, halfBinWidthCS: Float) {
        
        // set the uniforms
        _uniforms = Uniforms(numberOfBins: Float(numberOfBins),
                             numberOfDisplayBins: Float(numberOfDisplayBins),
                             halfBinWidth: halfBinWidthCS)
    }
    
    /// Copy uniforms data to the Uniforms Buffer (create Buffer if needed)
    ///
    func updateUniformsBuffer() {
        
        let uniformSize = MemoryLayout.stride(ofValue: _uniforms)
        
        // has the Uniforms buffer been created?
        if _uniformsBuffer == nil {
            
            // NO, create one
            _uniformsBuffer = device!.makeBuffer(length: uniformSize)
        }
        // update the Uniforms buffer
        let bufferPtr = _uniformsBuffer!.contents()
        memcpy(bufferPtr, &_uniforms, uniformSize)
    }
    /// Setup Buffers & State
    ///
    func setupBuffers() {
        
        // create and save a Buffer for Spectrum Values
        let dataSize = _waterfallVertices.count * MemoryLayout.stride(ofValue: _waterfallVertices[0])
        _waterfallVerticesBuffer = device!.makeBuffer(bytes: _waterfallVertices, length: dataSize)
        
        // get the Library (contains all compiled .metal files in this project)
        let library = device!.makeDefaultLibrary()!
        
        // create a Render Pipeline Descriptor for the Spectrum
        let waterfallPipelineDesc = MTLRenderPipelineDescriptor()
        waterfallPipelineDesc.vertexFunction = library.makeFunction(name: kWaterfallVertex)
        waterfallPipelineDesc.fragmentFunction = library.makeFunction(name: kWaterfallFragment)
        waterfallPipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        // create and save the Render Pipeline State object
        _waterfallPipelineState = try! device!.makeRenderPipelineState(descriptor: waterfallPipelineDesc)
        
        // create and save a Command Queue object
        _commandQueue = device!.makeCommandQueue()
        
        // create a texture sampler
        _samplerState = samplerState(sAddressMode: .repeat, tAddressMode: .repeat, minFilter: .linear, maxFilter: .linear)

    }
    /// Set the Metal clear color
    ///
    /// - Parameter color:      an NSColor
    ///
    func setClearColor(_ color: NSColor) {
        _clearColor = MTLClearColor(red: Double(color.redComponent),
                                    green: Double(color.greenComponent),
                                    blue: Double(color.blueComponent),
                                    alpha: Double(color.alphaComponent))
    }
    func redraw() {

        DispatchQueue.main.async {

//            self.render()
            self.waterfallStreamHandler()
        }
    }

    // ----------------------------------------------------------------------------
    // MARK: - Private methods
    
    /// Draw the Spectrum
    ///
    /// - Parameters:
    ///   - drawable:       a drawable
    ///   - cmdBuffer:      the active command buffer
    ///
    private func drawSpectrum(with drawable: CAMetalDrawable, cmdBuffer: MTLCommandBuffer) {
        
        // setup a render pass descriptor
        let renderPassDesc = MTLRenderPassDescriptor()
        renderPassDesc.colorAttachments[0].texture = drawable.texture
        renderPassDesc.colorAttachments[0].loadAction = .clear
        
        // Create a render encoder
        let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc)
        
        encoder!.pushDebugGroup("Spectrum")
        
        // use the Spectrum pipeline state
        encoder!.setRenderPipelineState(_waterfallPipelineState)
        
        // bind the buffer containing the Spectrum vertices (position 0)
        encoder!.setVertexBuffer(_waterfallVerticesBuffer, offset: 0, index: 0)
                
        // bind the Spectrum texture for the Fragment shader
        encoder!.setFragmentTexture(_texture, index: 0)
        
        // bind the sampler state for the Fragment shader
        encoder!.setFragmentSamplerState(_samplerState, index: 0)

        // bind the buffer containing the Uniforms (position 1)
        encoder!.setVertexBuffer(_uniformsBuffer, offset: 0, index: 1)
        
        // Draw as a Line
        encoder!.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: _waterfallVertices.count)

        encoder!.popDebugGroup()
        
        // finish using this encoder
        encoder!.endEncoding()
    }
    /// Create a Sampler State
    ///
    /// - Parameters:
    ///   - sAddressMode:       s-axis address mode
    ///   - tAddressMode:       t-axis address mode
    ///   - minFilter:          min filtering
    ///   - maxFilter:          max filtering
    /// - Returns:              a MTLSamplerState
    ///
    func samplerState(sAddressMode: MTLSamplerAddressMode,
                      tAddressMode: MTLSamplerAddressMode,
                      minFilter: MTLSamplerMinMagFilter,
                      maxFilter: MTLSamplerMinMagFilter) -> MTLSamplerState {
        
        // create a Sampler Descriptor
        let samplerDescriptor = MTLSamplerDescriptor()
        
        // set its parameters
        samplerDescriptor.sAddressMode = sAddressMode
        samplerDescriptor.tAddressMode = tAddressMode
        samplerDescriptor.minFilter = minFilter
        samplerDescriptor.magFilter = maxFilter
        
        // return the Sampler State
        return device!.makeSamplerState(descriptor: samplerDescriptor)!
    }


    func waterfallStreamHandler() {
        
        var linesIndex = 0
        
        for i in 0..<200 {
            
//            _lineDuration = 100
//            _startBinNumber = 0
//            _endBinNumber = 479
            
            updateTexCoords(linesIndex)

            // every 50 lines, change color
            if i > 0 && i % 50 == 0 {
                linesIndex = (linesIndex + 1) % 3
            }
            
            
            render()
            
            usleep(100_000)
        }
    }


}
