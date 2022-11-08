//
//  Coordinator.swift
//  LiDARScanningApp
//
//  Created by Philip Turner on 11/8/22.
//

import SwiftUI
import MetalKit

class Coordinator: NSObject, ObservableObject {
  var view: MTKView!
  
  override init() {
    print("Hello world, this succeeded.")
    super.init()
  }
}

