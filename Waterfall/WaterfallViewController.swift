//
//  WaterfallViewController.swift
//  xSDR6000
//
//  Created by Douglas Adams on 6/15/17.
//  Copyright © 2017 Douglas Adams. All rights reserved.
//

import Cocoa
import MetalKit

class WaterfallViewController: NSViewController {
    
    // ----------------------------------------------------------------------------
    // MARK: - Internal properties
    
    // ----------------------------------------------------------------------------
    // MARK: - Private properties
    
    fileprivate var _waterfallView      : WaterfallView!
    
    fileprivate var _waterfallLayer     : WaterfallLayer { return _waterfallView.waterfallLayer }

    // constants
    
    // ----------------------------------------------------------------------------
    // MARK: - Overridden methods
    
    /// the View has loaded
    ///
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // make the view controller the delegate for the view
        _waterfallView = self.view as! WaterfallView
        _waterfallView.delegate = self

        _waterfallLayer.loadTexture()
        
        // setup Waterfall Layer
        setupWaterfallLayer()
        
        // draw waterfall
        _waterfallLayer.redraw()
    }
    
    // ----------------------------------------------------------------------------
    // MARK: - Private methods
    
    /// Setup Panadapter layer buffers & parameters
    ///
    private func setupWaterfallLayer() {
        
        // setup buffers
        _waterfallLayer.setupBuffers()
        
        // setup the spectrum background color
        _waterfallLayer.setClearColor(NSColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 1.0))

        let halfBinWidthPixels = Float( (1.0 / (8.0/480.0)) / 2.0 )
        let halfBin = halfBinWidthPixels / 480.0
        let halfBinWidthCS = 2.0 * halfBin

        _waterfallLayer.populateUniforms(numberOfBins: 8, numberOfDisplayBins: 8, halfBinWidthCS: halfBinWidthCS)
        _waterfallLayer.updateUniformsBuffer()        
    }
}
