//
//  MainRenderer.swift
//  LiDARScanningApp
//
//  Created by Philip Turner on 11/8/22.
//

import MetalKit
import ARKit

class MainRenderer {
  unowned let coordinator: Coordinator
  var session: ARSession
  var view: MTKView
  
  var device: MTLDevice
  var commandQueue: MTLCommandQueue
  var library: MTLLibrary
  
  static let numRenderBuffers = 3
  var renderIndex: Int = -1
  var renderSemaphore = DispatchSemaphore(value: numRenderBuffers)
  
  init(session: ARSession, view: MTKView, coordinator: Coordinator) {
    self.session = session
    self.view = view
    self.coordinator = coordinator
    
    self.device = view.device!
    self.commandQueue = device.makeCommandQueue()!
    self.library = device.makeDefaultLibrary()!
  }
}
