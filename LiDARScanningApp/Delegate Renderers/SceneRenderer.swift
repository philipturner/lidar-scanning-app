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
  
  var cameraPlaneDepth: Float = 2
  
  var scene2DPipelineState: MTLRenderPipelineState
  var depthStencilState2: MTLDepthStencilState
  
  init(renderer: MainRenderer, library: MTLLibrary) {
    self.renderer = renderer
    let device = renderer.device
    
    let desc = MTLRenderPipelineDescriptor()
    desc.rasterSampleCount = 4
    desc.depthAttachmentPixelFormat = .depth32Float
    desc.inputPrimitiveTopology = .triangle
    desc.colorAttachments[0].pixelFormat = .bgra10_xr
    
    desc.vertexFunction = library.makeFunction(name: "scene2DVertexTransform")!
    desc.fragmentFunction = library.makeFunction(name: "scene2DFragmentShader")!
    desc.label = "Scene 2D Render Pipeline"
    
    self.scene2DPipelineState = try!
      renderer.device.makeRenderPipelineState(descriptor: desc)
    
    let depthStencilDescriptor = MTLDepthStencilDescriptor()
    depthStencilDescriptor.depthCompareFunction = .always
    depthStencilDescriptor.isDepthWriteEnabled = false
    depthStencilDescriptor.label = "Scene 2D Depth-Stencil State"
    self.depthStencilState2 = device.makeDepthStencilState(descriptor: depthStencilDescriptor)!
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
    // Ensure vertices are oriented in the right order.
    renderEncoder.setCullMode(.back)
    
    performSecondPass(renderEncoder: renderEncoder)
  }
  
  func performSecondPass(renderEncoder: MTLRenderCommandEncoder) {
    // TODO: Always remember to set the depth-stencil state during each pass.
    renderEncoder.setRenderPipelineState(scene2DPipelineState)
    renderEncoder.setDepthStencilState(depthStencilState2)
    
    struct VertexUniforms {
      var projectionTransform: simd_float4x4
      var cameraPlaneDepth: Float
      var imageBounds: simd_float2
    }
    
    let projectionTransform = worldToScreenClipTransform * cameraToWorldTransform
    let pixelWidthHalf = Float(renderer.cameraMeasurements.currentPixelWidth) * 0.5
    let imageBounds = simd_float2(
        Float(imageResolution.width) * pixelWidthHalf,
        Float(imageResolution.height) * pixelWidthHalf
    )
//    print(pixelWidthHalf)
//    print(imageBounds)
    
    var vertexUniforms = VertexUniforms(
      projectionTransform: projectionTransform,
      cameraPlaneDepth: -cameraPlaneDepth,
      imageBounds: imageBounds * cameraPlaneDepth)
    renderEncoder.setVertexBytes(
      &vertexUniforms, length: MemoryLayout<VertexUniforms>.stride, index: 0)
    
    renderEncoder.setFragmentTexture(colorTextureY,    index: 0)
    renderEncoder.setFragmentTexture(colorTextureCbCr, index: 1)
    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
  }
}
