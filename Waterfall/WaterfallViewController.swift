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
    
    fileprivate var _waterfallView          : WaterfallView!
    
    fileprivate var _waterfallLayer         : WaterfallLayer { return _waterfallView.waterfallLayer }

    fileprivate let _udpReceiveQ            = DispatchQueue(label: "Waterfall.udpReceiveQ")
    fileprivate var _streamTimer            : DispatchSourceTimer!      // periodic timer for stream activity

    fileprivate var _gradient               : NSGradient?
    
//    static let kBlackBGRA                           : UInt32 = 0xFF000000       // Black color in BGRA format
//    static let kRedBGRA                             : UInt32 = 0xFFFF0000       // Red color in BGRA format
//    static let kGreenBGRA                           : UInt32 = 0xFF00FF00       // Green color in BGRA format
//    static let kBlueBGRA                            : UInt32 = 0xFF0000FF       // Blue color in BGRA format

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
        
        if let array = loadGradient(name: "Grayscale") {
            _waterfallLayer.setGradient(array)
        } else {
            fatalError("Texture file not found")
        }

        setupTimer()
    }
    
    // ----------------------------------------------------------------------------
    // MARK: - Internal methods
    
    func frameDidChange() {
        
        _waterfallLayer.updateNeeded = true
    }

    func loadGradient(name: String) -> [UInt8]? {
        var file: FileHandle?

        var gradientArray = [UInt8](repeating: 0, count: WaterfallLayer.kSamplerSize * 4)

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

            // copy the dat into the gradientArray
            data.copyBytes(to: &gradientArray[0], count: WaterfallLayer.kSamplerSize * 4)

//        let gradientArray: [UInt8] = [
//            // b     g     r     a
//            0x00, 0x00, 0x00, 0xff,         // black
//            0x00, 0xff, 0x00, 0xff,         // green
//            0x00, 0xff, 0xff, 0xff,         // yellow
//            0x00, 0x00, 0xff, 0xff          // red
//        ]
        return gradientArray
        }
        return nil
    }
    
    // ----------------------------------------------------------------------------
    // MARK: - Private methods
    
    
    private func setupTimer() {
        
        // create the timer's dispatch source
        _streamTimer = DispatchSource.makeTimerSource(flags: [.strict], queue: _udpReceiveQ)
        
        // start the timer
        _streamTimer.schedule(deadline: DispatchTime.now(), repeating: .milliseconds(100), leeway: .milliseconds(10))      // Every second +/- 10%
        
        _streamTimer.resume()
        
        // set the event handler
        _streamTimer.setEventHandler { [ unowned self] in
            
            self._waterfallLayer.waterfallStreamHandler()
        }
        
    }
}
