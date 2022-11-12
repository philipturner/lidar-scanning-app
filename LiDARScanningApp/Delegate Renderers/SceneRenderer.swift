//
//  SceneRenderer.swift
//  LiDARScanningApp
//
//  Created by Philip Turner on 11/9/22.
//

import Metal
import ARKit

class SceneRenderer: DelegateRenderer {
  unowned let renderer: MainRenderer
  
  var cameraPlaneDepth: Float = 2
  var triangleCount: Int = 0
  var lineCount: Int { 3 * triangleCount }
  var projectionTransform = simd_float4x4(1)
  var reducedVertexBuffer: MTLBuffer!
  var reducedIndexBuffer: MTLBuffer!
  
  var zPrePassPipelineState: MTLRenderPipelineState
  var scene2DPipelineState: MTLRenderPipelineState
  var sceneMeshLinePipelineState: MTLRenderPipelineState
  // [Cancelled] sceneMeshTrianglePipelineState
  
  // Triple-buffered to make handling discrepancies between frames simpler.
  var lineIndexBuffer: MTLBuffer
  var lineIndexOffset: Int { (lineIndexBuffer.length / 3) * renderIndex }
  var triangleIndexBuffer: MTLBuffer
  var triangleIndexOffset: Int { (triangleIndexBuffer.length / 3) * renderIndex }
  
  var prepareMeshIndicesPipelineState: MTLComputePipelineState
  
  var depthStencilState1: MTLDepthStencilState
  var depthStencilState2: MTLDepthStencilState
  var depthStencilState3: MTLDepthStencilState
  
  init(renderer: MainRenderer, library: MTLLibrary) {
    self.renderer = renderer
    let device = renderer.device
    
    // MARK: - Render Pipeline States
    
    let desc = MTLRenderPipelineDescriptor()
    desc.rasterSampleCount = 1//4//1
    desc.depthAttachmentPixelFormat = .depth32Float
    desc.inputPrimitiveTopology = .triangle
    // descriptor has no color attachments
    
    desc.vertexFunction = library.makeFunction(name: "lidarMeshVertexTransform")!
    desc.label = "Z Pre-Pass Render Pipeline"
    self.zPrePassPipelineState = try!
      renderer.device.makeRenderPipelineState(descriptor: desc)
    
    desc.reset() // Reset everything
    desc.rasterSampleCount = 1//4
    desc.depthAttachmentPixelFormat = .depth32Float
    desc.inputPrimitiveTopology = .triangle
    desc.colorAttachments[0].pixelFormat = .bgra10_xr
    
    desc.vertexFunction = library.makeFunction(name: "scene2DVertexTransform")!
    desc.fragmentFunction = library.makeFunction(name: "scene2DFragmentShader")!
    desc.label = "Scene 2D Render Pipeline"
    self.scene2DPipelineState = try!
      renderer.device.makeRenderPipelineState(descriptor: desc)
    
    desc.reset() // Reset everything
    desc.rasterSampleCount = 1//4
    desc.depthAttachmentPixelFormat = .depth32Float
    desc.inputPrimitiveTopology = .line
    desc.colorAttachments[0].pixelFormat = .bgra10_xr
    
    desc.vertexFunction = library.makeFunction(name: "lidarMeshVertexTransform")!
    desc.fragmentFunction = library.makeFunction(name: "lidarMeshLineFragmentShader")!
    desc.label = "Scene Mesh Line Render Pipeline"
    self.sceneMeshLinePipelineState = try!
      renderer.device.makeRenderPipelineState(descriptor: desc)
    
    // MARK: - Compute Pipeline States
    
    // Making these small to debug them.
    let lineCapacity = 128
    let triangleCapacity = 128
    
    let lineIndexBufferSize = 3
      * lineCapacity * MemoryLayout<simd_uint2>.stride
    let triangleIndexBufferSize =
      3 * triangleCapacity * MemoryLayout<simd_packed_uint3>.stride
    self.lineIndexBuffer = device.makeBuffer(
      length: lineIndexBufferSize, options: .storageModeShared)!
    self.triangleIndexBuffer = device.makeBuffer(
      length: triangleIndexBufferSize, options: .storageModeShared)!
    self.lineIndexBuffer.label = "Mesh Line Index Buffer"
    self.triangleIndexBuffer.label = "Mesh Triangle Index Buffer"
    
    let prepareMeshIndicesFunction =
      library.makeFunction(name: "prepareMeshIndices")!
    self.prepareMeshIndicesPipelineState = try!
      device.makeComputePipelineState(function: prepareMeshIndicesFunction)
    
    // MARK: - Depth-Stencil Pipeline States
    
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
    
    depthStencilDescriptor.depthCompareFunction = .greaterEqual
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
  // - [Cancelled] Render visible triangles in a transparent green, in a second
  //   render pass.
  // - Render wireframe as red and dimmer, when occluded by furniture.
  
  func updateResources(frame: ARFrame) {
    let sceneMeshReducer = renderer.sceneMeshReducer!
    if let numTriangles = sceneMeshReducer.preCullTriangleCount {
      self.triangleCount = numTriangles
    } else {
      self.triangleCount = 0
    }
    self.projectionTransform =
      worldToScreenClipTransform * sceneMeshReducer.meshToWorldTransform
    
    self.reducedVertexBuffer = sceneMeshReducer.reducedVertexBuffer
    self.reducedIndexBuffer = sceneMeshReducer.reducedIndexBuffer
    self.ensureBufferCapacity(type: .triangle, capacity: triangleCount)
  }
  
  // Prepares mesh indices and renders to the Z buffer.
  // [Cancelled] Problems with fragment shader prevent me from doing these
  // fancy rendering effects. However, I still rely on the compute pass that
  // transforms indices.
  func drawZBuffer(commandBuffer: MTLCommandBuffer) {
    guard let vertexBuffer = self.reducedVertexBuffer,
          let indexBuffer = self.reducedIndexBuffer,
          triangleCount > 0 else {
      // Cannot render scene mesh.
      return
    }
    
    let computeEncoder = commandBuffer.makeComputeCommandEncoder()!
    computeEncoder.setComputePipelineState(prepareMeshIndicesPipelineState)
    computeEncoder.setBuffer(indexBuffer, offset: 0, index: 0)
    computeEncoder.setBuffer(
      lineIndexBuffer, offset: lineIndexOffset, index: 1)
    computeEncoder.setBuffer(
      triangleIndexBuffer, offset: triangleIndexOffset, index: 2)
    computeEncoder.dispatchThreads([ lineCount ], threadsPerThreadgroup: 1)
    computeEncoder.endEncoding()
    
    let renderPassDescriptor = MTLRenderPassDescriptor()
    renderPassDescriptor.defaultRasterSampleCount = 1//4//1
    renderPassDescriptor.depthAttachment.texture = renderer.intermediateDepthTexture
    renderPassDescriptor.depthAttachment.clearDepth = 0
    // Need to store the depths for further use.
    renderPassDescriptor.depthAttachment.storeAction = .store

    // Don't cull any triangles; backwards-facing ones should still be red.
    let renderEncoder = commandBuffer.makeRenderCommandEncoder(
      descriptor: renderPassDescriptor)!
    renderEncoder.setFrontFacing(.counterClockwise)
    renderEncoder.setCullMode(.none)
    renderEncoder.setRenderPipelineState(zPrePassPipelineState)
    renderEncoder.setDepthStencilState(depthStencilState1)

    renderEncoder.setVertexBytes(
      &self.projectionTransform, length: MemoryLayout<simd_float4x4>.stride, index: 0)
    renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 1)

    renderEncoder.drawIndexedPrimitives(
      type: .triangle,
      indexCount: self.triangleCount * 3,
      indexType: .uint32,
      indexBuffer: self.triangleIndexBuffer,
      indexBufferOffset: self.triangleIndexOffset,
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
    performThirdPass(renderEncoder: renderEncoder)
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
    guard let vertexBuffer = self.reducedVertexBuffer,
          let indexBuffer = self.reducedIndexBuffer,
          triangleCount > 0 else {
      // Cannot render scene mesh.
      return
    }
    
    renderEncoder.setRenderPipelineState(sceneMeshLinePipelineState)
    renderEncoder.setDepthStencilState(depthStencilState3)
    
    renderEncoder.setVertexBytes(
      &self.projectionTransform, length: MemoryLayout<simd_float4x4>.stride, index: 0)
    renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 1)
    renderEncoder.setFragmentTexture(renderer.intermediateDepthTexture, index: 0)
    
    renderEncoder.drawIndexedPrimitives(
      type: .line,
      indexCount: self.lineCount * 2,
      indexType: .uint32,
      indexBuffer: self.lineIndexBuffer,
      indexBufferOffset: self.lineIndexOffset,
      instanceCount: 1)
  }
  
  // [Cancelled]
  // Needed a memory barrier to preserve opacity. Apple GPUs cannot have a
  // fragment-to-fragment barriers. A raster order group might be acceptable,
  // except you must pass the framebuffer as a shader argument. It's easier to
  // just create a new render pass.
  func finishRenderPass(renderEncoder: MTLRenderCommandEncoder) {
    guard let vertexBuffer = self.reducedVertexBuffer,
          let indexBuffer = self.reducedIndexBuffer,
          triangleCount > 0 else {
      // Cannot render scene mesh.
      return
    }
    
    // Do not let back-facing triangles interfere.
    renderEncoder.setCullMode(.back)
  }
}

extension SceneRenderer: BufferExpandable {
  
  enum BufferType: CaseIterable {
    case triangle
  }
  
  func ensureBufferCapacity(type: BufferType, capacity: Int) {
    let newCapacity = roundUpToPowerOf2(capacity)
    
    switch type {
    case .triangle: ensureTriangleCapacity(capacity: newCapacity)
    }
  }
  
  private func ensureTriangleCapacity(capacity: Int) {
    let lineIndexBufferSize = 3 * 3 * capacity * MemoryLayout<simd_uint2>.stride
    if lineIndexBuffer.length < lineIndexBufferSize {
      lineIndexBuffer = device.makeBuffer(
        length: lineIndexBufferSize, options: .storageModeShared)!
      lineIndexBuffer.label = "Mesh Line Index Buffer"
    }
    
    let triangleIndexBufferSize = 3 * capacity * MemoryLayout<simd_uint3>.stride
    if triangleIndexBuffer.length < triangleIndexBufferSize {
      triangleIndexBuffer = device.makeBuffer(
        length: lineIndexBufferSize, options: .storageModeShared)!
      triangleIndexBuffer.label = "Mesh Triangle Index Buffer"
    }
  }
  
}
