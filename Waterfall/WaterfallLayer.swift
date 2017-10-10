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
    
    struct SpectrumValue {
        var i                                       : ushort    // intensity
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

    fileprivate var _spectrumValues                 : [UInt16] = [
        16_000, 48_000, 32_000, 0, 65_000, 32_000, 48_000, 16_000
    ]
    fileprivate var _spectrumValuesCount            = WaterfallLayer.kMaxIntensities
    fileprivate var _spectrumValuesBuffer           :MTLBuffer!
    fileprivate var _spectrumPipelineState          :MTLRenderPipelineState!
    
    fileprivate var _uniforms                       :Uniforms!
    fileprivate var _uniformsBuffer                 :MTLBuffer?
    fileprivate var _texture                        :MTLTexture!
    fileprivate var _samplerState                   :MTLSamplerState!
    fileprivate var _commandQueue                   :MTLCommandQueue!
    fileprivate var _clearColor                     :MTLClearColor?

    fileprivate var _numberOfBins                   : Int = 0
    fileprivate var _binWidthHz                     : CGFloat = 0.0
    fileprivate var _firstPass                      = true
    
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
        let dataSize = _spectrumValues.count * MemoryLayout.stride(ofValue: _spectrumValues[0])
        _spectrumValuesBuffer = device!.makeBuffer(bytes: _spectrumValues, length: dataSize)
        
        // get the Library (contains all compiled .metal files in this project)
        let library = device!.makeDefaultLibrary()!
        
        // create a Render Pipeline Descriptor for the Spectrum
        let spectrumPipelineDesc = MTLRenderPipelineDescriptor()
        spectrumPipelineDesc.vertexFunction = library.makeFunction(name: kWaterfallVertex)
        spectrumPipelineDesc.fragmentFunction = library.makeFunction(name: kWaterfallFragment)
        spectrumPipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        // create and save the Render Pipeline State object
        _spectrumPipelineState = try! device!.makeRenderPipelineState(descriptor: spectrumPipelineDesc)
        
        // create and save a Command Queue object
        _commandQueue = device!.makeCommandQueue()
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
        renderPassDesc.colorAttachments[0].clearColor = _clearColor!
        renderPassDesc.colorAttachments[0].loadAction = .load
        
        // Create a render encoder
        let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc)
        
        encoder!.pushDebugGroup("Spectrum")
        
        // use the Spectrum pipeline state
        encoder!.setRenderPipelineState(_spectrumPipelineState)
        
        // bind the buffer containing the Spectrum vertices (position 0)
        encoder!.setVertexBuffer(_spectrumValuesBuffer, offset: 0, index: 0)
                
        // bind the buffer containing the Uniforms (position 1)
        encoder!.setVertexBuffer(_uniformsBuffer, offset: 0, index: 1)
        
        // Draw as a Line
        encoder!.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: _spectrumValuesCount)

        encoder!.popDebugGroup()
        
        // finish using this encoder
        encoder!.endEncoding()
    }
}
