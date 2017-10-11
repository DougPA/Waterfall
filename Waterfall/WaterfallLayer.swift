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

    fileprivate var _waterfallVertices              : [Vertex] = [
        Vertex(coord: float2(-0.8, -0.8), texCoord: float2( 0.0, 0.0)),
        Vertex(coord: float2(-0.8,  0.8), texCoord: float2( 0.0, 1.0)),
        Vertex(coord: float2( 0.8, -0.8), texCoord: float2( 0.0, 1.0)),
        Vertex(coord: float2( 0.8,  0.8), texCoord: float2( 1.0, 1.0))
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
    
    fileprivate let kTextureWidth                   = 4096                        // must be >= max number of Bins
    fileprivate let kTextureHeight                  = 2048                        // must be >= max number of lines
    fileprivate let kBlackRGBA                      : UInt32 = 0xFF000000         // Black color in RGBA format

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
    
    func loadTexture() {
        
        // load the texture from the assets.xcassets (all black)
        let loader = MTKTextureLoader(device: device!)
        _texture = try! loader.newTexture(name: "RedTexture", scaleFactor: 1.0, bundle: nil, options: nil)
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
        _samplerState = samplerState(forDevice: device!, sAddressMode: .clampToEdge, tAddressMode: .repeat, minFilter: .linear, maxFilter: .linear)

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
            
            self.render()
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
    
    // ----------------------------------------------------------------------------
    // MARK: - Class methods
    
    /// Create a Texture from an image in the Assets.xcassets
    ///
    /// - Parameters:
    ///   - name:       name of the asset
    ///   - device:     a Metal Device
    /// - Returns:      a MTLTexture
    /// - Throws:       Texture loader error
    ///
//    class func texture(forDevice device: MTLDevice, asset name: NSDataAsset.Name) throws -> MTLTexture {
//
//        // get a Texture loader
//        let textureLoader = MTKTextureLoader(device: device)
//
//        // identify the asset containing the image
//        let asset = NSDataAsset.init(name: name)
//
//        if let data = asset?.data {
//
//            // if found, create the texture
//            return try textureLoader.newTexture(data: data, options: nil)
//        } else {
//
//            // image not found
//            fatalError("Could not load image \(name) from an asset catalog in the main bundle")
//        }
//    }
    /// Create a Sampler State
    ///
    /// - Parameters:
    ///   - device:             a MTLDevice
    ///   - sAddressMode:       the desired Sampler address mode
    ///   - tAddressMode:       the desired Sampler address mode
    ///   - minFilter:          the desired Sampler filtering
    ///   - maxFilter:          the desired Sampler filtering
    /// - Returns:              a MTLSamplerState
    ///
    func samplerState(forDevice device: MTLDevice,
                      sAddressMode: MTLSamplerAddressMode,
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
        return device.makeSamplerState(descriptor: samplerDescriptor)!
    }
}
