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
  
  var zPrePassPipelineState: MTLRenderPipelineState
  var scene2DPipelineState: MTLRenderPipelineState
  // sceneMeshLinePipelineState
  // sceneMeshTrianglePipelineState
  
  var depthStencilState1: MTLDepthStencilState
  var depthStencilState2: MTLDepthStencilState
  var depthStencilState3: MTLDepthStencilState
  
  init(renderer: MainRenderer, library: MTLLibrary) {
    self.renderer = renderer
    let device = renderer.device
    
    let desc = MTLRenderPipelineDescriptor()
    desc.rasterSampleCount = 1
    desc.depthAttachmentPixelFormat = .depth32Float
    desc.inputPrimitiveTopology = .triangle
    // descriptor has no color attachments
    
    desc.vertexFunction = library.makeFunction(name: "lidarMeshVertexTransform")!
    desc.label = "Z Pre-Pass Render Pipeline"
    self.zPrePassPipelineState = try!
      renderer.device.makeRenderPipelineState(descriptor: desc)
    
    desc.reset() // Reset everything
    desc.rasterSampleCount = 4
    desc.depthAttachmentPixelFormat = .depth32Float
    desc.inputPrimitiveTopology = .triangle
    desc.colorAttachments[0].pixelFormat = .bgra10_xr
    
    desc.vertexFunction = library.makeFunction(name: "scene2DVertexTransform")!
    desc.fragmentFunction = library.makeFunction(name: "scene2DFragmentShader")!
    desc.label = "Scene 2D Render Pipeline"
    self.scene2DPipelineState = try!
      renderer.device.makeRenderPipelineState(descriptor: desc)
    
    desc.reset() // Reset everything
    
    let depthStencilDescriptor = MTLDepthStencilDescriptor()
    depthStencilDescriptor.depthCompareFunction = .greater
    depthStencilDescriptor.isDepthWriteEnabled = true
    depthStencilDescriptor.label = "Z Pre-Pass Depth-Stencil State"
    self.depthStencilState1 = device.makeDepthStencilState(
      descriptor: depthStencilDescriptor)!
    
    depthStencilDescriptor.depthCompareFunction = .always
    depthStencilDescriptor.isDepthWriteEnabled = false
    depthStencilDescriptor.label = "Scene 2D Depth-Stencil State"
    self.depthStencilState2 = device.makeDepthStencilState(
      descriptor: depthStencilDescriptor)!
    
    depthStencilDescriptor.depthCompareFunction = .always
    depthStencilDescriptor.isDepthWriteEnabled = false
    depthStencilDescriptor.label = "Scene Mesh Depth-Stencil State"
    self.depthStencilState3 = device.makeDepthStencilState(
      descriptor: depthStencilDescriptor)!
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
  func drawZBuffer(commandBuffer: MTLCommandBuffer) {
    guard let vertexBuffer = renderer.sceneMeshReducer.reducedVertexBuffer,
          let indexBuffer = renderer.sceneMeshReducer.reducedIndexBuffer else {
      // Cannot render scene mesh.
      return
    }
    
    let renderPassDescriptor = MTLRenderPassDescriptor()
    renderPassDescriptor.defaultRasterSampleCount = 1
    renderPassDescriptor.depthAttachment.texture = renderer.intermediateDepthTexture
    renderPassDescriptor.depthAttachment.clearDepth = 0
    
    // Don't cull any triangles; backwards-facing ones should still be red.
    let renderEncoder = commandBuffer.makeRenderCommandEncoder(
      descriptor: renderPassDescriptor)!
    renderEncoder.setFrontFacing(.counterClockwise)
    renderEncoder.setCullMode(.none)
    renderEncoder.setRenderPipelineState(zPrePassPipelineState)
    renderEncoder.setDepthStencilState(depthStencilState1)
    
    var projectionTransform = worldToScreenClipTransform * cameraToWorldTransform
    renderEncoder.setVertexBytes(
      &projectionTransform, length: MemoryLayout<simd_float4x4>.stride, index: 0)
    renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 1)
    
    renderEncoder.drawIndexedPrimitives(
      type: .triangle,
      indexCount: renderer.sceneMeshReducer.preCullTriangleCount * 3,
      indexType: .uint32,
      indexBuffer: indexBuffer,
      indexBufferOffset: 0,
      instanceCount: 1)
    renderEncoder.endEncoding()
  }
  
  func drawGeometry(renderEncoder: MTLRenderCommandEncoder) {
    // Ensure vertices are oriented in the right order.
    renderEncoder.setCullMode(.back)
    performSecondPass(renderEncoder: renderEncoder)
    
    // Allow back-facing lines to render.
    renderEncoder.setCullMode(.none)
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
  
  func performThirdPass(renderEncoder: MTLRenderCommandEncoder) {
    guard let vertexBuffer = renderer.sceneMeshReducer.reducedVertexBuffer,
          let indexBuffer = renderer.sceneMeshReducer.reducedIndexBuffer else {
      // Cannot render scene mesh.
      return
    }
  }
  
  // Needed a memory barrier to preserve opacity. Apple GPUs cannot have a
  // fragment-to-fragment barriers. A raster order group might be acceptable,
  // except you must pass the framebuffer as a shader argument. It's easier to
  // just create a new render pass.
  func finishRenderPass(renderEncoder: MTLRenderCommandEncoder) {
    guard let vertexBuffer = renderer.sceneMeshReducer.reducedVertexBuffer,
          let indexBuffer = renderer.sceneMeshReducer.reducedIndexBuffer else {
      // Cannot render scene mesh.
      return
    }
    
    // Do not let back-facing triangles interfere.
    renderEncoder.setCullMode(.back)
  }
}
