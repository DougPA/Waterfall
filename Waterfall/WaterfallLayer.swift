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
    
    var line = [UInt32](repeating: WaterfallLayer.kGreenBGRA, count: kNumberOfBins)

    // constants
    fileprivate let kWaterfallVertex                = "waterfall_vertex"
    fileprivate let kWaterfallFragment              = "waterfall_fragment"

    static let kTextureWidth                        = 4096                      // must be >= max number of Bins
    static let kTextureHeight                       = 2048                      // must be >= max number of lines
    
    static let kFrameWidth                          = 480                       // frame width (pixels)
    static let kFrameHeight                         = 270                       // frame height (pixels)
    
    static let kNumberOfBins                        = 2048                      // number of stream samples
    static let kStartingBin                         = (kNumberOfBins -  kFrameWidth)  / 2       // first bin on screen
    static let kEndingBin                           = (kNumberOfBins - 1 - kStartingBin)        // last bin on screen

    static let kBlackBGRA                           : UInt32 = 0xFF000000   // Black color in BGRA format
    static let kRedBGRA                             : UInt32 = 0xFFFF0000   // Red color in BGRA format
    static let kGreenBGRA                           : UInt32 = 0xFF00FF00   // Green color in BGRA format
    static let kBlueBGRA                            : UInt32 = 0xFF0000FF   // Blue color in BGRA format

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
        
        // ----- draw the triangles with a texture -----

        // Create a Render encoder
        let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc)
        
        // set the pipeline state
        encoder.setRenderPipelineState(_waterfallPipelineState)

        // bind the bytes containing the vertices
        let size = MemoryLayout.stride(ofValue: _waterfallVertices[0])
        encoder.setVertexBytes(&_waterfallVertices, length: size * _waterfallVertices.count, at: 0)

        // bind the current texture
        let currentTexture = (_passIndex == 0 ? _texture0 : _texture1 )
        encoder.setFragmentTexture(currentTexture, at: 0)
        
        // bind the sampler state
        encoder.setFragmentSamplerState(_samplerState, at: 0)
        
        // Draw the triangles
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: _waterfallVertices.count)

        // finish using the Render encoder
        encoder.endEncoding()
        
        // ----- blit the framebuffer to a texture -----
        
        // Create a Blit encoder
        let blitEncoder = cmdBuffer.makeBlitCommandEncoder()

        // copy & scroll the current texture to the next texture
        let nextTexture = (_passIndex == 0 ? _texture1 : _texture0 )
        blitEncoder.copy(from: currentTexture!, sourceSlice: 0, sourceLevel: 0,
                         sourceOrigin: MTLOriginMake(0, 0, 0), sourceSize: MTLSizeMake(WaterfallLayer.kTextureWidth, WaterfallLayer.kTextureHeight-1, 1),
                         to: nextTexture!, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOriginMake(0, 1, 0))
        // make the texture available to the CPU
        blitEncoder.synchronize(resource: nextTexture!)
        
        // finish using the Blit encoder
        blitEncoder.endEncoding()
        
        // present the drawable to the screen
        cmdBuffer.present(drawable)
        
        // finalize rendering & push the command buffer to the GPU
        cmdBuffer.commit()
        
        // toggle the texture usage
        _passIndex = (_passIndex + 1) % 2
    }

    // ----------------------------------------------------------------------------
    // MARK: - Internal methods
    
    func loadTexture() {
        
        // load two textures
        let loader = MTKTextureLoader(device: device!)
        let texURL = Bundle.main.urlForImageResource("BlackTexture.png")!
        _texture0 = try! loader.newTexture(withContentsOf: texURL, options: [MTKTextureLoaderOptionSRGB: NSNumber(value: false)])
        _texture1 = try! loader.newTexture(withContentsOf: texURL, options: [MTKTextureLoaderOptionSRGB: NSNumber(value: false)])
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
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest
        
        // create the Sampler State
        _samplerState = device!.makeSamplerState(descriptor: samplerDescriptor)
        
        Swift.print("# bins = \(WaterfallLayer.kNumberOfBins), start = \(WaterfallLayer.kStartingBin), end = \(WaterfallLayer.kEndingBin), end - start + 1 = \(WaterfallLayer.kEndingBin - WaterfallLayer.kStartingBin + 1)")
        
        // make the middle of the line red so you can tell if the texture is correctly positioned
        for i in WaterfallLayer.kStartingBin + 1...WaterfallLayer.kEndingBin - 2 {
            
            line[i] = WaterfallLayer.kRedBGRA
        }
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
        
        for _ in 0..<300 {
        
            // recalc values initially or when center/bandwidth changes
            if updateNeeded {
                
                updateNeeded = false
                
                // set the texture left edge
                let leftSide = Float(WaterfallLayer.kStartingBin) / Float(WaterfallLayer.kTextureWidth)
                _waterfallVertices[0].texCoord.x = leftSide             // bottom
                _waterfallVertices[1].texCoord.x = leftSide             // top

                // set the texture right edge
                let rightSide = Float(WaterfallLayer.kEndingBin) / Float(WaterfallLayer.kTextureWidth)
                _waterfallVertices[2].texCoord.x = rightSide            // bottom
                _waterfallVertices[3].texCoord.x = rightSide            // top
                
                // set the texture bottom edge
                let bottomSide = Float(WaterfallLayer.kFrameHeight) / Float(WaterfallLayer.kTextureHeight)
                _waterfallVertices[0].texCoord.y = bottomSide           // left
                _waterfallVertices[2].texCoord.y = bottomSide           // right
            }
            
            // copy a dataframe line into the texture
            let uint8Ptr = UnsafeRawPointer(line).bindMemory(to: UInt8.self, capacity: WaterfallLayer.kNumberOfBins * 4)
            let region = MTLRegionMake2D(0, 0, WaterfallLayer.kNumberOfBins, 1)
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
