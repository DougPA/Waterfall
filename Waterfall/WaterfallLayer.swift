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
    
    // ----------------------------------------------------------------------------
    // MARK: - Public properties
    
    var updateNeeded                                = true
    
    // ----------------------------------------------------------------------------
    // MARK: - Private properties    

    //  Vertices    v1  (-1, 1)     |     ( 1, 1)  v3       Texture     v1  ( 0, 0) |---------  ( 1, 0)  v3
    //  (-1 to +1)                  |                       (0 to 1)                |
    //                          ----|----                                           |
    //                              |                                               |
    //              v0  (-1,-1)     |     ( 1,-1)  v2                   v0  ( 0, 1) |           ( 1, 1)  v2
    //
    fileprivate var _waterfallVertices              : [Vertex] = [
        Vertex(coord: float2(-1.0, -1.0), texCoord: float2( 0.0, 1.0)),         // v0 - bottom left
        Vertex(coord: float2(-1.0,  1.0), texCoord: float2( 0.0, 0.0)),         // v1 - top    left
        Vertex(coord: float2( 1.0, -1.0), texCoord: float2( 1.0, 1.0)),         // v2 - bottom right
        Vertex(coord: float2( 1.0,  1.0), texCoord: float2( 1.0, 0.0))          // v3 - top    right
    ]
    fileprivate var _waterfallPipelineState         : MTLRenderPipelineState!
    fileprivate var _linePipelineState              : MTLRenderPipelineState!

    fileprivate var _texture0                       : MTLTexture!
    fileprivate var _texture1                       : MTLTexture!
    fileprivate var _samplerState                   : MTLSamplerState!
    fileprivate var _commandQueue                   : MTLCommandQueue!
    fileprivate var _clearColor                     : MTLClearColor?

    fileprivate var _firstPass                      = true
    fileprivate var _passIndex                      = 0
    
    var line = [UInt32](repeating: WaterfallLayer.kGreenRGBA, count: WaterfallLayer.kTextureWidth)

    // constants
    fileprivate let kWaterfallVertex                = "waterfall_vertex"
    fileprivate let kWaterfallFragment              = "waterfall_fragment"

    static let kTextureWidth                        = 480                       // must be >= max number of Bins
    static let kTextureHeight                       = 270                       // must be >= max number of lines
    static let kBlackRGBA                           : UInt32 = 0xFF000000       // Black color in RGBA format
    static let kRedRGBA                             : UInt32 = 0xFF0000FF       // Red color in RGBA format
    static let kGreenRGBA                           : UInt32 = 0xFF00FF00       // Green color in RGBA format
    static let kBlueRGBA                            : UInt32 = 0xFFFF0000       // Blue color in RGBA format
    
    // ----------------------------------------------------------------------------
    // MARK: - Public methods
    
    /// Draw in a Metal layer
    ///
    public func render() {
        
        // obtain a drawable
        guard let drawable = nextDrawable() else { return }
        
        // create a command buffer
        let cmdBuffer = _commandQueue.makeCommandBuffer()
        
        // create a render pass descriptor
        let renderPassDesc = MTLRenderPassDescriptor()
        renderPassDesc.colorAttachments[0].texture = drawable.texture
        renderPassDesc.colorAttachments[0].loadAction = .clear

        
        // draw the triangles w/texture
        

        // Create a render encoder
        let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc)
        encoder.label = "WF Render encoder"
        

        // set the pipeline state
        encoder.setRenderPipelineState(_waterfallPipelineState)

        // bind the bytes containing the vertices
        let size = MemoryLayout.stride(ofValue: _waterfallVertices[0])
        encoder.setVertexBytes(&_waterfallVertices, length: size * _waterfallVertices.count, at: 0)

        // bind the texture
        if _passIndex == 0 {
            encoder.pushDebugGroup("WF Draw w/tex_0")

            encoder.setFragmentTexture(_texture0, at: 0)

        } else {
            encoder.pushDebugGroup("WF Draw w/tex_1")

            encoder.setFragmentTexture(_texture1, at: 0)
        }
        
        // bind the sampler state
        encoder.setFragmentSamplerState(_samplerState, at: 0)
        
        // Draw the triangles
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: _waterfallVertices.count)

        encoder.popDebugGroup()
        
        // finish using this encoder
        encoder.endEncoding()

        
        // blit the framebuffer to the texture

        
        let blitEncoder = cmdBuffer.makeBlitCommandEncoder()
        blitEncoder.label = "WF Blit encoder"

        if _passIndex == 0 {
            blitEncoder.pushDebugGroup("WF Copy tex 0 -> 1")

            blitEncoder.copy(from: _texture0, sourceSlice: 0, sourceLevel: 0,
                             sourceOrigin: MTLOriginMake(0, 0, 0), sourceSize: MTLSizeMake(WaterfallLayer.kTextureWidth, WaterfallLayer.kTextureHeight-1, 1),
                             to: _texture1, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOriginMake(0, 1, 0))
            blitEncoder.synchronize(resource: _texture1)

        } else {
            blitEncoder.pushDebugGroup("WF Copy tex 1 -> 0")

            blitEncoder.copy(from: _texture1, sourceSlice: 0, sourceLevel: 0,
                             sourceOrigin: MTLOriginMake(0, 0, 0), sourceSize: MTLSizeMake(WaterfallLayer.kTextureWidth, WaterfallLayer.kTextureHeight-1, 1),
                             to: _texture0, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOriginMake(0, 1, 0))
            blitEncoder.synchronize(resource: _texture0)
        }
        // finish using this encoder
        blitEncoder.endEncoding()
        
        
        

        // present the drawable to the screen
        cmdBuffer.present(drawable)
        
        // finalize rendering & push the command buffer to the GPU
        cmdBuffer.commit()
        
        _passIndex = (_passIndex + 1) % 2
    }

    // ----------------------------------------------------------------------------
    // MARK: - Internal methods
    
    func loadTexture() {
        
        // load the texture from a resource
        let loader = MTKTextureLoader(device: device!)
        var texURL = Bundle.main.urlForImageResource("BlackTexture_480x270.png")!
        _texture0 = try! loader.newTexture(withContentsOf: texURL, options: [
            MTKTextureLoaderOptionSRGB: NSNumber(value: false)])

        texURL = Bundle.main.urlForImageResource("RedTexture_480x270.png")!
        _texture1 = try! loader.newTexture(withContentsOf: texURL, options: [
            MTKTextureLoaderOptionSRGB: NSNumber(value: false)])
        _texture0.label = "Texture_0"
        _texture1.label = "Texture_1"
    }
    /// Setup persistent objects
    ///
    func setupPersistentObjects() {
        
        // get the Library (contains all compiled .metal files in this project)
        let library = device!.newDefaultLibrary()
        
        // create a Render Pipeline Descriptor for the Spectrum
        let waterfallPipelineDesc = MTLRenderPipelineDescriptor()
        waterfallPipelineDesc.vertexFunction = library?.makeFunction(name: kWaterfallVertex)
        waterfallPipelineDesc.fragmentFunction = library?.makeFunction(name: kWaterfallFragment)
        waterfallPipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        // create and save the Render Pipeline State object
        _waterfallPipelineState = try! device!.makeRenderPipelineState(descriptor: waterfallPipelineDesc)
        
        // create and save a Command Queue object
        _commandQueue = device!.makeCommandQueue()
        
        // create a Sampler Descriptor & set its parameters
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.tAddressMode = .repeat
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest
        
        // create the Sampler State
        _samplerState = device!.makeSamplerState(descriptor: samplerDescriptor)
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

    func waterfallStreamHandler() {
        
        for _ in 0..<100 {
        
            // recalc values initially or when center/bandwidth changes
            if updateNeeded {
                
                updateNeeded = false
                
            }
            
            // copy a colored line into the texture @ the texPosition
            let uint8Ptr = UnsafeRawPointer(line).bindMemory(to: UInt8.self, capacity: WaterfallLayer.kTextureWidth * 4)
            let region = MTLRegionMake2D(0, 0, WaterfallLayer.kTextureWidth, 1)
            if _passIndex == 0 {
                
                _texture0.replace(region: region, mipmapLevel: 0, withBytes: uint8Ptr, bytesPerRow: WaterfallLayer.kTextureWidth * 4)
            } else {
                
                _texture1.replace(region: region, mipmapLevel: 0, withBytes: uint8Ptr, bytesPerRow: WaterfallLayer.kTextureWidth * 4)
            }
            
            autoreleasepool {
                self.render()
            }
            usleep(100_000)
        }
    }


}
