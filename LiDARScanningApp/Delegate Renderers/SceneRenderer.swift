//
//  SceneRenderer.swift
//  LiDARScanningApp
//
//  Created by Philip Turner on 11/9/22.
//

import Metal
import simd

class SceneRenderer: DelegateRenderer {
  unowned let renderer: MainRenderer
  
  init(renderer: MainRenderer, library: MTLLibrary) {
    self.renderer = renderer
  }
}

extension SceneRenderer {
  // Need multiple render passes to display the mesh.
  // - Start with a depth pass that calculates occlusion.
  // - Then, render the 2D camera image to an empty texture.
  // - Finally, render the mesh according to visibility.
  //
  // Regarding the last step:
  // - Render wireframe as green and bright, when visible IRL.
  // - Render visible triangles in a transparent green, in a second render pass.
  // - Render wireframe as red and dimmer, when occluded by furniture.
  func drawGeometry(renderEncoder: MTLRenderCommandEncoder) {
    
  }
}
