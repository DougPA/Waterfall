//
//  WaterfallViewController.swift
//  Waterfall
//
//  Created by Douglas Adams on 6/15/17.
//  Copyright © 2017 Douglas Adams. All rights reserved.
//

import Cocoa
import MetalKit

class WaterfallViewController: NSViewController {
    
    // ----------------------------------------------------------------------------
    // MARK: - Private properties
    
    fileprivate var _waterfallView          : WaterfallView!
    fileprivate var _waterfallLayer         : WaterfallLayer { return _waterfallView.waterfallLayer }
    fileprivate let _udpReceiveQ            = DispatchQueue(label: "Waterfall.udpReceiveQ")
    fileprivate var _streamTimer            : DispatchSourceTimer!          // periodic timer for stream activity

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
        
        // get a gradient
        if let array = loadGradient(name: "Basic") {
            _waterfallLayer.setGradient(array)
        } else {
            fatalError("Texture file not found")
        }

        // make a timer to simulate incoming Vita packets
        setupTimer()
    }
    
    // ----------------------------------------------------------------------------
    // MARK: - Internal methods
    
    func frameDidChange() {
        
        // something changed
        _waterfallLayer.updateNeeded = true
    }

    /// Load a gradient from the named file
    ///
    func loadGradient(name: String) -> [UInt8]? {
        var file: FileHandle?

        var gradientArray = [UInt8](repeating: 0, count: WaterfallLayer.kGradientSize * MemoryLayout<Float>.size)

        if let texURL = Bundle.main.url(forResource: name, withExtension: "tex") {
            do {
                file = try FileHandle(forReadingFrom: texURL)
            } catch {
                return nil
            }
            // Read all the data
            let data = file!.readDataToEndOfFile()

            // Close the file
            file!.closeFile()

            // copy the data into the gradientArray
            data.copyBytes(to: &gradientArray[0], count: WaterfallLayer.kGradientSize * MemoryLayout<Float>.size)

            return gradientArray
        }
        // resource not found
        return nil
    }
    
    // ----------------------------------------------------------------------------
    // MARK: - Private methods
    
    /// Simulate waterfall stream handler at 100 ms interval
    ///
    private func setupTimer() {
        
        // create the timer's dispatch source
        _streamTimer = DispatchSource.makeTimerSource(flags: [.strict], queue: _udpReceiveQ)
        
        // start the timer
        _streamTimer.schedule(deadline: DispatchTime.now(), repeating: .milliseconds(100), leeway: .milliseconds(10))      // Every 100ms +/- 10%
        
        _streamTimer.resume()
        
        // set the event handler
        _streamTimer.setEventHandler { [ unowned self] in
            
            self._waterfallLayer.waterfallStreamHandler()
        }
        
    }
}
