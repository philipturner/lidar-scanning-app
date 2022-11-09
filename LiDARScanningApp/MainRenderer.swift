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
  
  // Resources for rendering
  
  var colorTextureY: MTLTexture!
  var colorTextureCbCr: MTLTexture!
  var sceneDepthTexture: MTLTexture!
  var segmentationTexture: MTLTexture!
  var textureCache: CVMetalTextureCache
  
  var msaaTexture: MTLTexture
  // renderPipelineState
  var depthStencilTexture: MTLTexture
  var depthStencilState: MTLDepthStencilState
  
  // Delegates
  
  var userSettings: UserSettings!
  var cameraMeasurements: CameraMeasurements { userSettings.cameraMeasurements }
  
  init(session: ARSession, view: MTKView, coordinator: Coordinator) {
    self.session = session
    self.view = view
    self.coordinator = coordinator
    
    self.device = view.device!
    self.commandQueue = device.makeCommandQueue()!
    self.library = device.makeDefaultLibrary()!
    
    self.textureCache = CVMetalTextureCache?(
      nil,    [kCVMetalTextureCacheMaximumTextureAgeKey : 1e-5],
                                                device, [kCVMetalTextureUsage : MTLTextureUsage.shaderRead.rawValue])!
    
    let textureDescriptor = MTLTextureDescriptor()
    let bounds = UIScreen.main.nativeBounds
    textureDescriptor.width  = Int(bounds.height)
    textureDescriptor.height = Int(bounds.width)
    
    textureDescriptor.usage = .renderTarget
    textureDescriptor.textureType = .type2DMultisample
    textureDescriptor.storageMode = .memoryless
    textureDescriptor.sampleCount = 4
    
    textureDescriptor.pixelFormat = view.colorPixelFormat
    msaaTexture = device.makeTexture(descriptor: textureDescriptor)!
    msaaTexture.label = "MSAA Texture"
    
    textureDescriptor.pixelFormat = .depth32Float_stencil8
    depthStencilTexture = device.makeTexture(descriptor: textureDescriptor)!
    depthStencilTexture.label = "Depth-Stencil Texture"
    
    let depthStencilDescriptor = MTLDepthStencilDescriptor()
    depthStencilDescriptor.depthCompareFunction = .greater
    depthStencilDescriptor.isDepthWriteEnabled = true
    depthStencilDescriptor.label = "Render Depth-Stencil State"
    depthStencilState = device.makeDepthStencilState(descriptor: depthStencilDescriptor)!
    
    // Delegates
    
    self.userSettings = UserSettings(renderer: self, library: library)
  }
}

extension MainRenderer {
  func update() {
    renderSemaphore.wait()
    guard let frame = session.currentFrame else {
      renderSemaphore.signal()
      return
    }
    
    updateTextures(frame: frame)
    renderSemaphore.signal()
  }
  
  func updateUniforms(frame: ARFrame) {
    renderIndex = (renderIndex + 1) % 3
    cameraMeasurements.updateResources(frame: frame)
  }
  
  func updateTextures(frame: ARFrame) {
    func bind(
      _ pixelBuffer: CVPixelBuffer?,
      to reference: inout MTLTexture!,
      _ label: String,
      _ pixelFormat: MTLPixelFormat,
      _ width: Int,
      _ height: Int,
      _ planeIndex: Int = 0
    ) {
      guard let pixelBuffer = pixelBuffer else {
          reference = nil
          return
      }
      reference = textureCache.createMTLTexture(
        pixelBuffer, pixelFormat, width, height, planeIndex)!
      reference.label = label
    }
    
    bind(
      frame.segmentationBuffer, to: &segmentationTexture,
      "Segmentation Texture", .r8Unorm, 256, 192)
    bind(
      frame.sceneDepth?.depthMap, to: &sceneDepthTexture,
      "Scene Depth Texture", .r32Float, 256, 192)
    
    let width  = Int(cameraMeasurements.imageResolution.width)
    let height = Int(cameraMeasurements.imageResolution.height)
    bind(
      frame.capturedImage, to: &colorTextureY,
      "Color Texture (Y)", .r8Unorm, width, height, 0)
    bind(
      frame.capturedImage, to: &colorTextureCbCr,
      "Color Texture (CbCr)", .rg8Unorm, width >> 1, height >> 1, 1)
  }
}
