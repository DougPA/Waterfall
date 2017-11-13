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
    fileprivate var _computePipelineState           : MTLComputePipelineState!

    fileprivate var _drawTexture                    : MTLTexture!
    fileprivate var _gradientTexture                : MTLTexture!
    fileprivate var _intensityTexture0              : MTLTexture!
    fileprivate var _intensityTexture1              : MTLTexture!
    fileprivate var _samplerState                   : MTLSamplerState!
    fileprivate var _gradientSamplerState           : MTLSamplerState!
    fileprivate var _commandQueue                   : MTLCommandQueue!
    fileprivate var _clearColor                     : MTLClearColor?
    fileprivate var _region                         = MTLRegionMake2D(0, 0, WaterfallLayer.kNumberOfBins, 1)

    let _threadGroupCount = MTLSizeMake(16, 16, 1)
    
    lazy var _threadGroups: MTLSize = {
        MTLSizeMake(WaterfallLayer.kTextureWidth / self._threadGroupCount.width, WaterfallLayer.kTextureHeight / self._threadGroupCount.height, 1)
    }()

    fileprivate var _passIndex                      = 0
    
    var _line = [UInt16](repeating: 0, count: WaterfallLayer.kTextureWidth)          // intensity

    // constants
    fileprivate let kWaterfallVertex                = "waterfall_vertex"
    fileprivate let kWaterfallFragment              = "waterfall_fragment"

    // statics
    static let kTextureWidth                        = 3360                      // must be >= max number of Bins
    static let kTextureHeight                       = 1024                      // must be >= max number of lines
    
    static let kFrameWidth                          = 480                       // frame width (pixels)
    static let kFrameHeight                         = 270                       // frame height (pixels)
    
    static let kNumberOfBins                        = 2048                      // number of stream samples
    static let kStartingBin                         = (kNumberOfBins -  kFrameWidth)  / 2       // first bin on screen
    static let kEndingBin                           = (kNumberOfBins - 1 - kStartingBin)        // last bin on screen

    static let kBlackBGRA                           : UInt32 = 0xFF000000       // Black color in BGRA format
    static let kRedBGRA                             : UInt32 = 0xFFFF0000       // Red color in BGRA format
    static let kGreenBGRA                           : UInt32 = 0xFF00FF00       // Green color in BGRA format
    static let kBlueBGRA                            : UInt32 = 0xFF0000FF       // Blue color in BGRA format

    static let kBlackRGBA                           : UInt32 = 0xFF000000   // Black color in RGBA format
    static let kRedRGBA                             : UInt32 = 0xFF0000FF   // Red color in RGBA format
    static let kGreenRGBA                           : UInt32 = 0xFF00FF00   // Green color in RGBA format
    static let kBlueRGBA                            : UInt32 = 0xFFFF0000   // Blue color in RGBA format

    static let kSamplerSize                         = 256

    // ----------------------------------------------------------------------------
    // MARK: - Public methods
    
    /// Draw in a Metal layer
    ///
    public func render() {
        
        // ----- convert the intensities to gradient colors -----
        
        // create a command buffer
        var cmdBuffer = _commandQueue.makeCommandBuffer()!
        cmdBuffer.label = "Compute buffer"
        
        let computeEncoder = cmdBuffer.makeComputeCommandEncoder()!
        computeEncoder.label = "Compute encoder"
        
        computeEncoder.pushDebugGroup("Compute")
        
        computeEncoder.setComputePipelineState(_computePipelineState)
        
        // choose and bind the input Texture
        let currentTexture = (_passIndex == 0 ? _intensityTexture0 : _intensityTexture1 )
        computeEncoder.setTexture(currentTexture, index: 0)
        
        // bind the output Texture
        computeEncoder.setTexture(_drawTexture, index: 1)
        
        // bind the Gradient texture
        computeEncoder.setTexture(_gradientTexture, index: 2)

        // bind the sampler state for the Gradient
        computeEncoder.setSamplerState(_gradientSamplerState, index: 0)

        computeEncoder.dispatchThreadgroups(_threadGroups, threadsPerThreadgroup: _threadGroupCount)
        
        computeEncoder.popDebugGroup()
        
        computeEncoder.endEncoding()
        
        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()

        // ----- prepare to draw -----

        // obtain a drawable
        guard let drawable = nextDrawable() else { return }
        
        // create another command buffer
        cmdBuffer = _commandQueue.makeCommandBuffer()!
        cmdBuffer.label = "Render buffer"
        
        // create a render pass descriptor
        let renderPassDesc = MTLRenderPassDescriptor()
        renderPassDesc.colorAttachments[0].texture = drawable.texture
        renderPassDesc.colorAttachments[0].loadAction = .clear
        
        // ----- draw the triangles overlaid with the current texture -----

        // Create a Render encoder
        let renderEncoder = cmdBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc)!
        renderEncoder.label = "Render encoder"
        
        // set the pipeline state
        renderEncoder.setRenderPipelineState(_waterfallPipelineState)

        // bind the bytes containing the vertices
        let size = MemoryLayout.stride(ofValue: _waterfallVertices[0])
        renderEncoder.setVertexBytes(&_waterfallVertices, length: size * _waterfallVertices.count, index: 0)

        // bind the Draw texture
        renderEncoder.setFragmentTexture(_drawTexture, index: 0)
        
        // bind the sampler state
        renderEncoder.setFragmentSamplerState(_samplerState, index: 0)
        
        // Draw the triangles
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: _waterfallVertices.count)

        // finish using the Render encoder
        renderEncoder.endEncoding()
        
        // ----- blit the current texture to the next texture (scrolls the texture down one line) -----
        
        // Create a Blit encoder
        let blitEncoder = cmdBuffer.makeBlitCommandEncoder()!
        blitEncoder.label = "Blit encoder"

        // copy & scroll the current texture to the next texture
        let nextTexture = (_passIndex == 0 ? _intensityTexture1 : _intensityTexture0 )
        blitEncoder.copy(from: currentTexture!, sourceSlice: 0, sourceLevel: 0,
                         sourceOrigin: MTLOriginMake(0, 0, 0), sourceSize: MTLSizeMake(WaterfallLayer.kTextureWidth, WaterfallLayer.kTextureHeight-1, 1),
                         to: nextTexture!, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOriginMake(0, 1, 0))
        
        // make the next texture available to the CPU
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
    
    /// Setup persistent objects & state
    ///
    func setupPersistentObjects() {
        
        // drawable texture is used only as a framebuffer
        framebufferOnly = true
        
        // setup the clear color
        setClearColor(NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 1.0))

        // setup a 1D texture as a Gradient
        let gradientTextureDescriptor = MTLTextureDescriptor()
        gradientTextureDescriptor.pixelFormat = .bgra8Unorm
        gradientTextureDescriptor.width = WaterfallLayer.kSamplerSize
        gradientTextureDescriptor.usage = [.shaderRead]
        gradientTextureDescriptor.mipmapLevelCount = 1
        gradientTextureDescriptor.textureType = .type1D
        _gradientTexture = device!.makeTexture(descriptor: gradientTextureDescriptor)

        
        // setup a 2D texture for drawing
        let drawTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                         width: WaterfallLayer.kTextureWidth,
                                                                         height: WaterfallLayer.kTextureHeight,
                                                                         mipmapped: false)
        drawTextureDescriptor.usage = [.shaderRead, .shaderWrite]
        _drawTexture = device!.makeTexture(descriptor: drawTextureDescriptor)

        
        // setup two 2D textures for intensity processing
        let intensityTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Uint,
                                                                         width: WaterfallLayer.kTextureWidth,
                                                                         height: WaterfallLayer.kTextureHeight,
                                                                         mipmapped: false)
        intensityTextureDescriptor.usage = [.shaderRead, .shaderWrite]
        _intensityTexture0 = device!.makeTexture(descriptor: intensityTextureDescriptor)
        _intensityTexture1 = device!.makeTexture(descriptor: intensityTextureDescriptor)

        // get the Library (contains all compiled .metal files in this project)
        let library = device!.makeDefaultLibrary()
        
        // create a Render Pipeline Descriptor for the Waterfall
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
        
        // create and save a Sampler State
        _samplerState = device!.makeSamplerState(descriptor: samplerDescriptor)
        
        // create and save the Compute Pipeline State object
        if let kernelFunction = library!.makeFunction(name: "convert") {
            _computePipelineState = try! device!.makeComputePipelineState(function: kernelFunction)
        }

        // create a Sampler Descriptor & set its parameters
        let gradientSamplerDescriptor = MTLSamplerDescriptor()
        gradientSamplerDescriptor.sAddressMode = .clampToEdge
        gradientSamplerDescriptor.tAddressMode = .clampToEdge
        gradientSamplerDescriptor.minFilter = .nearest
        gradientSamplerDescriptor.magFilter = .nearest
        
        // create and save a Gradient Sampler State
        _gradientSamplerState = device!.makeSamplerState(descriptor: gradientSamplerDescriptor)

        let incr = UInt16.max/100
        
        // make the middle of the line red so you can tell if the texture is correctly positioned
        for i in WaterfallLayer.kStartingBin + 20..<WaterfallLayer.kStartingBin + 80 {
            
            _line[i] = incr * 15        // blue
        }
        for i in WaterfallLayer.kStartingBin + 80..<WaterfallLayer.kStartingBin + 160 {
            
            _line[i] = incr * 25        // cyan
        }
        for i in WaterfallLayer.kStartingBin + 160..<WaterfallLayer.kStartingBin + 240 {
            
            _line[i] = incr * 35        // green
        }
        for i in WaterfallLayer.kStartingBin + 240..<WaterfallLayer.kStartingBin + 300 {
            
            _line[i] = incr * 55        // yellow
        }
        for i in WaterfallLayer.kStartingBin + 300..<WaterfallLayer.kStartingBin + 360 {
            
            _line[i] = incr * 90        // red
        }
        for i in WaterfallLayer.kStartingBin + 360..<WaterfallLayer.kStartingBin + 420 {
            
            _line[i] = UInt16.max       // white
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
    
    func setGradient(_ gradient: [UInt8]) {
//        // get a pointer to the gradient data
//        let uint8Ptr = UnsafeRawPointer(gradient).bindMemory(to: UInt8.self, capacity: WaterfallLayer.kSamplerSize * 4)
        
        let region = MTLRegionMake1D(0, WaterfallLayer.kSamplerSize)
        // copy the Gradient into the current texture
        _gradientTexture!.replace(region: region, mipmapLevel: 0, withBytes: gradient, bytesPerRow: WaterfallLayer.kSamplerSize * 4)
    }
    
    func redraw() {

        waterfallStreamHandler()
    }

    // ----------------------------------------------------------------------------
    // MARK: - Private methods

    func waterfallStreamHandler() {
        
        // recalc values initially or when center/bandwidth changes
        if updateNeeded {
            
            updateNeeded = false
            
            // calculate the portion of the texture in use
            _region = MTLRegionMake2D(0, 0, WaterfallLayer.kNumberOfBins, 1)
            
            // set the texture left edge
            let leftSide = Float(WaterfallLayer.kStartingBin) / Float(WaterfallLayer.kTextureWidth)
            _waterfallVertices[0].texCoord.x = leftSide             // bottom
            _waterfallVertices[1].texCoord.x = leftSide             // top
            
            // set the texture right edge
            let rightSide = Float(WaterfallLayer.kEndingBin) / Float(WaterfallLayer.kTextureWidth)
            _waterfallVertices[2].texCoord.x = rightSide            // bottom
            _waterfallVertices[3].texCoord.x = rightSide            // top
            
            // set the texture bottom edge
            let bottomSide = Float(frame.height) / Float(WaterfallLayer.kTextureHeight)
            _waterfallVertices[0].texCoord.y = bottomSide           // left
            _waterfallVertices[2].texCoord.y = bottomSide           // right
        }
        
        // get a pointer to the dataFrame bins
        let uint8Ptr = UnsafeRawPointer(_line).bindMemory(to: UInt8.self, capacity: WaterfallLayer.kNumberOfBins * 2)
        
        // copy the dataFrame bins (intensities) into the current texture
        let currentTexture = (_passIndex == 0 ? _intensityTexture0 : _intensityTexture1 )
        currentTexture!.replace(region: _region, mipmapLevel: 0, withBytes: uint8Ptr, bytesPerRow: WaterfallLayer.kTextureWidth * 2)
        
        autoreleasepool {
            self.render()
        }
    }
}
