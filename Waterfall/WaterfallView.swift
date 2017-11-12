//
//  WaterfallView.swift
//  xSDR6000
//
//  Created by Douglas Adams on 10/7/17.
//  Copyright © 2017 Douglas Adams. All rights reserved.
//

import Cocoa

final public class WaterfallView: NSView, CALayerDelegate {

    // ----------------------------------------------------------------------------
    // MARK: - Internal properties
    
    var delegate                            : WaterfallViewController!
    var rootLayer                           : CALayer!              // layers
    var waterfallLayer                      : WaterfallLayer!
    
    // ----------------------------------------------------------------------------
    // MARK: - Private properties
    
    fileprivate var _minY                   : CAConstraint!
    fileprivate var _minX                   : CAConstraint!
    fileprivate var _maxY                   : CAConstraint!
    fileprivate var _maxX                   : CAConstraint!

    // constants
    fileprivate let kRightButton            = 0x02
    fileprivate let kRootLayer              = "root"                // layer names
    fileprivate let kWaterfallLayer         = "waterfall"
    
    // ----------------------------------------------------------------------------
    // MARK: - Initialization
    
    public override func awakeFromNib() {
        super.awakeFromNib()
        
        createLayers()        
    }
    
    // ----------------------------------------------------------------------------
    // MARK: - Public methods
    
    
    // ----------------------------------------------------------------------------
    // MARK: - Private methods
    
    /// Create the Layers and setup relationships to each other
    ///
    fileprivate func createLayers() {
        
        // layer constraints
        _minY = CAConstraint(attribute: .minY, relativeTo: "superlayer", attribute: .minY)
        _maxY = CAConstraint(attribute: .maxY, relativeTo: "superlayer", attribute: .maxY)
        _minX = CAConstraint(attribute: .minX, relativeTo: "superlayer", attribute: .minX)
        _maxX = CAConstraint(attribute: .maxX, relativeTo: "superlayer", attribute: .maxX)
        
        // ***** Root layer *****
        rootLayer = CALayer()
        rootLayer.name = kRootLayer
        rootLayer.layoutManager = CAConstraintLayoutManager()
        rootLayer.frame = frame
        layerUsesCoreImageFilters = true
        
        // make this a layer-hosting view
        layer = rootLayer
        wantsLayer = true
        
        // select a compositing filter
        // possible choices - CIExclusionBlendMode, CIDifferenceBlendMode, CIMaximumCompositing
        guard let compositingFilter = CIFilter(name: "CIDifferenceBlendMode") else {
            fatalError("Unable to create compositing filter")
        }
        // ***** Waterfall layer *****
        waterfallLayer = WaterfallLayer()
        
        // get the Metal device
        waterfallLayer.device = MTLCreateSystemDefaultDevice()
        guard waterfallLayer.device != nil else {
            fatalError("Metal is not supported on this Mac")
        }
        waterfallLayer.name = kWaterfallLayer
        waterfallLayer.frame = frame
        waterfallLayer.addConstraint(_minX)
        waterfallLayer.addConstraint(_maxX)
        waterfallLayer.addConstraint(_minY)
        waterfallLayer.addConstraint(_maxY)
        waterfallLayer.pixelFormat = .bgra8Unorm
        waterfallLayer.framebufferOnly = true
        waterfallLayer.delegate = waterfallLayer
        
        // layer hierarchy
        rootLayer.addSublayer(waterfallLayer)
    }
    
    // ----------------------------------------------------------------------------
    // MARK: - Notification Methods
    
    /// Add subsciptions to Notifications
    ///     (as of 10.11, subscriptions are automatically removed on deinit when using the Selector-based approach)
    ///
    fileprivate func addNotifications() {
        
        NotificationCenter.default.addObserver(self, selector: #selector(frameDidChange(_:)), name: NSView.frameDidChangeNotification, object: self)
        
    }
    /// Process .frameDidChange Notification
    ///
    /// - Parameter note:       a Notification instance
    ///
    @objc fileprivate func frameDidChange(_ note: Notification) {
        
        delegate?.frameDidChange()
    }
}

