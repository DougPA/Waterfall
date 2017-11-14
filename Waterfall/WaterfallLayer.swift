//
//  WaterfallLayer.swift
//  Waterfall
//
//  Created by Douglas Adams on 10/7/17.
//  Copyright © 2017 Douglas Adams. All rights reserved.
//

import Foundation
import MetalKit

public final class WaterfallLayer: CAMetalLayer, CALayerDelegate {
    
    //  NOTE:
    //
    //  The intensity values are expected to be UInt16's between zero and UInt16.max.
    //
    //  The Radio sends an array of size ??? (larger than frame.width). The portion of the
    //  data, corresponding to the starting through ending frequency, of the Panadapter is
    //  determined based on the dataFrame.firstBinFreq and the dataFrame.binBandwidth.
    //
    //  The intensity values (in _intensityTexture) are converted into color values
    //  derived from a color gradient and placed into the _drawtexture.
    //
    //  Two triangles are drawn to make a rectangle covering the waterfall and the _drawTexture
    //  is superimposed over that rectangle.
    //
    //  The texture (_intensityTexture) is then copied in such a way as to scroll down one line.
    //
    //  There are two _intensityTexture textures, 0 & 1 that the code alternates between.
    //
    //  All of the incoming intensity values are processed but only the visible portion is
    //  displayed because of the clip space conversion (texture values with coordinates outside
    //  of the -1 to +1 range are ignored).
    //
    
    struct Vertex {
        var coord                                   : float2                // waterfall coordinates
        var texCoord                                : float2                // texture coordinates
    }
    
    // ----------------------------------------------------------------------------
    // MARK: - Public properties
    
    var updateNeeded                                = true                  // true == recalc texture coords
    
    // ----------------------------------------------------------------------------
    // MARK: - Private properties    

    //  Vertices    v1  (-1, 1)     |     ( 1, 1)  v3       Texture     v1  ( 0, 0) |---------  ( 1, 0)  v3
    //  (-1 to +1)                  |                       (0 to 1)                |
    //                          ----|----                                           |
    //                              |                                               |
    //              v0  (-1,-1)     |     ( 1,-1)  v2                   v0  ( 0, 1) |           ( 1, 1)  v2
    //
    //  NOTE:   texture coords are recalculated based on screen size and startingBin / endingBin
    //
    fileprivate var _waterfallVertices              : [Vertex] = [
        Vertex(coord: float2(-1.0, -1.0), texCoord: float2( 0.0, 1.0)),     // v0 - bottom left
        Vertex(coord: float2(-1.0,  1.0), texCoord: float2( 0.0, 0.0)),     // v1 - top    left
        Vertex(coord: float2( 1.0, -1.0), texCoord: float2( 1.0, 1.0)),     // v2 - bottom right
        Vertex(coord: float2( 1.0,  1.0), texCoord: float2( 1.0, 0.0))      // v3 - top    right
    ]
    fileprivate var _waterfallPipelineState         : MTLRenderPipelineState!   // render pipeline state
    fileprivate var _computePipelineState           : MTLComputePipelineState!  // compute pipeline state

    fileprivate var _drawTexture                    : MTLTexture!           // overlay on waterfall draw
    fileprivate var _gradientTexture                : MTLTexture!           // color gradient
    fileprivate var _intensityTexture0              : MTLTexture!           // intensities
    fileprivate var _intensityTexture1              : MTLTexture!           //      "
    fileprivate var _samplerState                   : MTLSamplerState!      // sampler for draw texture
    fileprivate var _gradientSamplerState           : MTLSamplerState!      // sampler for gradient
    fileprivate var _commandQueue                   : MTLCommandQueue!      // Metal queue
    fileprivate var _clearColor                     : MTLClearColor?        // Metal clear color
    fileprivate var _region                         = MTLRegionMake2D(0, 0, WaterfallLayer.kNumberOfBins, 1)

    // arbitrary choice - may be tunable to improve performance on varios Mac hardware
    let _threadGroupCount = MTLSizeMake(16, 16, 1)
    lazy var _threadGroups: MTLSize = {
        MTLSizeMake(WaterfallLayer.kTextureWidth / self._threadGroupCount.width, WaterfallLayer.kTextureHeight / self._threadGroupCount.height, 1)
    }()

    fileprivate var _textureIndex                   = 0                     // 0 == Texture 0, 1 == Texture 1
    
    var _line = [UInt16](repeating: 0, count: WaterfallLayer.kTextureWidth) // line of intensity values

    // constants
    fileprivate let kWaterfallVertex                = "waterfall_vertex"    // name of waterfall vertex function
    fileprivate let kWaterfallFragment              = "waterfall_fragment"  // name of waterfall fragment function
    fileprivate let kComputeGradient                = "convert"             // name of waterfall kernel function

    // statics, values chosen to accomodate the lrgest possible waterfall
    static let kTextureWidth                        = 3360                  // must be >= max number of Bins
    static let kTextureHeight                       = 1024                  // must be >= max number of lines
    
    // static, arbitrary choice of a reasonable number of color gradations for the waterfall
    static let kGradientSize                        = 256                   // number of colors in a gradient

    // statics here, in real waterfall they are properties that change
    static let kFrameWidth                          = 480                   // frame width (pixels)
    static let kFrameHeight                         = 270                   // frame height (pixels)
    static let kNumberOfBins                        = 2048                  // number of stream samples
    static let kStartingBin                         = (kNumberOfBins -  kFrameWidth)  / 2   // first bin on screen
    static let kEndingBin                           = (kNumberOfBins - 1 - kStartingBin)    // last bin on screen

    // ----------------------------------------------------------------------------
    // MARK: - Public methods
    
    /// Draw in a Metal layer
    ///
    public func render() {
        
        // ----- use the GPU to convert the intensities to gradient colors -----
        
        // create a command buffer
        var cmdBuffer = _commandQueue.makeCommandBuffer()!
        cmdBuffer.label = "Compute buffer"
        
        // create a Compute encoder
        let computeEncoder = cmdBuffer.makeComputeCommandEncoder()!
        computeEncoder.label = "Compute encoder"
        
        computeEncoder.pushDebugGroup("Compute")
        
        // set the pipeline state
        computeEncoder.setComputePipelineState(_computePipelineState)
        
        // choose and bind the input Texture
        let currentTexture = (_textureIndex == 0 ? _intensityTexture0 : _intensityTexture1 )
        computeEncoder.setTexture(currentTexture, index: 0)
        
        // bind the output Texture
        computeEncoder.setTexture(_drawTexture, index: 1)
        
        // bind the Gradient texture
        computeEncoder.setTexture(_gradientTexture, index: 2)

        // bind the sampler state for the Gradient
        computeEncoder.setSamplerState(_gradientSamplerState, index: 0)

        // perform the computation
        computeEncoder.dispatchThreadgroups(_threadGroups, threadsPerThreadgroup: _threadGroupCount)
        
        computeEncoder.popDebugGroup()
        
        // finish using the Compute encoder
        computeEncoder.endEncoding()
        
        // start the computation & wait for it's completion
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
        
        // ----- use the GPU to draw the triangles overlaid with the current texture -----

        // create a Render encoder
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
        
        // ----- use the GPU to copy the current texture to the next texture (scrolls the texture down one line) -----
        
        // Create a Blit encoder
        let blitEncoder = cmdBuffer.makeBlitCommandEncoder()!
        blitEncoder.label = "Blit encoder"

        // copy & scroll the current texture to the next texture
        let nextTexture = (_textureIndex == 0 ? _intensityTexture1 : _intensityTexture0 )
        blitEncoder.copy(from: currentTexture!, sourceSlice: 0, sourceLevel: 0,
                         sourceOrigin: MTLOriginMake(0, 0, 0), sourceSize: MTLSizeMake(WaterfallLayer.kTextureWidth, WaterfallLayer.kTextureHeight-1, 1),
                         to: nextTexture!, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOriginMake(0, 1, 0))
        
        // make the nextTexture's changes visible to the CPU
        blitEncoder.synchronize(resource: nextTexture!)
        
        // finish using the Blit encoder
        blitEncoder.endEncoding()
        
        // present the drawable to the screen
        cmdBuffer.present(drawable)
        
        // finalize rendering & push the command buffer to the GPU
        cmdBuffer.commit()
        
        // -------------------------------------------------------------------

        // toggle the texture usage
        _textureIndex = (_textureIndex + 1) % 2
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

        // setup a 1D texture for a Gradient
        let gradientTextureDescriptor = MTLTextureDescriptor()
        gradientTextureDescriptor.pixelFormat = .bgra8Unorm
        gradientTextureDescriptor.width = WaterfallLayer.kGradientSize
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
        
        // are the vertex & fragment shaders in the Library?
        if let waterfallVertex = library?.makeFunction(name: kWaterfallVertex), let waterfallFragment = library?.makeFunction(name: kWaterfallFragment) {
            
            // YES, create a Render Pipeline Descriptor for the Waterfall
            let waterfallPipelineDesc = MTLRenderPipelineDescriptor()
            waterfallPipelineDesc.vertexFunction = waterfallVertex
            waterfallPipelineDesc.fragmentFunction = waterfallFragment
            waterfallPipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm

            // create and save the Render Pipeline State object
            _waterfallPipelineState = try! device!.makeRenderPipelineState(descriptor: waterfallPipelineDesc)
        
        } else {
            
            // NO, crash
            fatalError("Unable to find shader function(s) - \(kWaterfallVertex) or \(kWaterfallFragment)")
        }
        
        // create and save a Command Queue object
        _commandQueue = device!.makeCommandQueue()
        
        // create a waterfall Sampler Descriptor & set its parameters
        let waterfallSamplerDescriptor = MTLSamplerDescriptor()
        waterfallSamplerDescriptor.sAddressMode = .clampToEdge
        waterfallSamplerDescriptor.tAddressMode = .clampToEdge
        waterfallSamplerDescriptor.minFilter = .nearest
        waterfallSamplerDescriptor.magFilter = .nearest
        
        // create and save a Sampler State
        _samplerState = device!.makeSamplerState(descriptor: waterfallSamplerDescriptor)
        
        // is the compute shader in the Library
        if let kernelFunction = library?.makeFunction(name: kComputeGradient) {
            
            // YES, create and save the Compute Pipeline State object
            _computePipelineState = try! device!.makeComputePipelineState(function: kernelFunction)
        
        } else {
            
            // NO, crash
            fatalError("Unable to find shader function - \(kComputeGradient)")
        }

        // create a gradient Sampler Descriptor & set its parameters
        let gradientSamplerDescriptor = MTLSamplerDescriptor()
        gradientSamplerDescriptor.sAddressMode = .clampToEdge
        gradientSamplerDescriptor.tAddressMode = .clampToEdge
        gradientSamplerDescriptor.minFilter = .nearest
        gradientSamplerDescriptor.magFilter = .nearest
        
        // create and save a Gradient Sampler State
        _gradientSamplerState = device!.makeSamplerState(descriptor: gradientSamplerDescriptor)

        let incr = UInt16.max/100
        
        // NOTE:    This is just to make the gradient visible for this test
        
        // vary the middle of the line to see all values of a texture and to see it is correctly positioned
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
    /// Copy a gradient array to the gradient Texture
    ///
    /// - Parameter gradient:   an array of BGRA8Unorm values
    ///
    func setGradient(_ gradient: [UInt8]) {
        
        // make a region that encompasses the gradient
        let region = MTLRegionMake1D(0, WaterfallLayer.kGradientSize)
        
        // copy the Gradient into the current texture
        _gradientTexture!.replace(region: region, mipmapLevel: 0, withBytes: gradient, bytesPerRow: WaterfallLayer.kGradientSize * MemoryLayout<Float>.size)
    }
    
    // ----------------------------------------------------------------------------
    // MARK: - Private methods

    /// Simulation of a Waterfall stream handler
    //
    func waterfallStreamHandler() {
        
        // recalc values initially or when parameters change
        if updateNeeded {
            
            updateNeeded = false
            
            // calculate the region of the texture being used
            _region = MTLRegionMake2D(0, 0, WaterfallLayer.kNumberOfBins, 1)
            
            // set the texture left edge (in clip space, i.e. 0.0 to 1.0)
            let leftSide = Float(WaterfallLayer.kStartingBin) / Float(WaterfallLayer.kTextureWidth)
            _waterfallVertices[0].texCoord.x = leftSide             // bottom
            _waterfallVertices[1].texCoord.x = leftSide             // top
            
            // set the texture right edge (in clip space, i.e. 0.0 to 1.0)
            let rightSide = Float(WaterfallLayer.kEndingBin) / Float(WaterfallLayer.kTextureWidth)
            _waterfallVertices[2].texCoord.x = rightSide            // bottom
            _waterfallVertices[3].texCoord.x = rightSide            // top
            
            // set the texture bottom edge (in clip space, i.e. 0.0 to 1.0)
            let bottomSide = Float(frame.height) / Float(WaterfallLayer.kTextureHeight)
            _waterfallVertices[0].texCoord.y = bottomSide           // left
            _waterfallVertices[2].texCoord.y = bottomSide           // right
        }
        
        // get a pointer to the line of data (intensities)
        let uint8Ptr = UnsafeRawPointer(_line).bindMemory(to: UInt8.self, capacity: WaterfallLayer.kNumberOfBins * MemoryLayout<UInt16>.size)
        
        // copy the data (intensities) into the current texture
        let currentTexture = (_textureIndex == 0 ? _intensityTexture0 : _intensityTexture1 )
        currentTexture!.replace(region: _region, mipmapLevel: 0, withBytes: uint8Ptr, bytesPerRow: WaterfallLayer.kTextureWidth * MemoryLayout<UInt16>.size)
        
        autoreleasepool {
            self.render()
        }
    }
}
