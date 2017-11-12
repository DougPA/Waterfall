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

    fileprivate let _udpReceiveQ            = DispatchQueue(label: "Waterfall.udpReceiveQ")
    fileprivate var _streamTimer            : DispatchSourceTimer!      // periodic timer for stream activity

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

        // setup Waterfall Layer
        _waterfallLayer.setupPersistentObjects()

        setupTimer()
    }
    
    // ----------------------------------------------------------------------------
    // MARK: - Internal methods
    
    func frameDidChange() {
        
        _waterfallLayer.updateNeeded = true
    }

    // ----------------------------------------------------------------------------
    // MARK: - Private methods
    
    
    private func setupTimer() {
        
        // create the timer's dispatch source
        _streamTimer = DispatchSource.makeTimerSource(flags: [.strict], queue: _udpReceiveQ)
        
        // start the timer
        _streamTimer.scheduleRepeating(deadline: DispatchTime.now(), interval: .milliseconds(17), leeway: .milliseconds(10))      // Every second +/- 10%
        
        _streamTimer.resume()
        
        // set the event handler
        _streamTimer.setEventHandler { [ unowned self] in
            
            self._waterfallLayer.waterfallStreamHandler()
        }
        
    }
}
