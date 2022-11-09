//
//  DelegateRenderer.swift
//  LiDARScanningApp
//
//  Created by Philip Turner on 11/9/22.
//

import ARKit

protocol DelegateRenderer {
  @inlinable var renderer: MainRenderer { get }
}

extension DelegateRenderer {
  @inlinable var device: MTLDevice { renderer.device }
  @inlinable var renderIndex: Int { renderer.renderIndex }
  
  @inlinable var interfaceCenter: simd_float3 { renderer.cameraMeasurements.interfaceCenter }
  @inlinable var leftEyePosition: simd_float3 { renderer.cameraMeasurements.leftEyePosition }
  @inlinable var rightEyePosition: simd_float3 { renderer.cameraMeasurements.rightEyePosition }
  @inlinable var handheldEyePosition: simd_float3 { renderer.cameraMeasurements.handheldEyePosition }
  
  internal var colorTextureY: MTLTexture! { renderer.colorTextureY }
  internal var colorTextureCbCr: MTLTexture! { renderer.colorTextureCbCr }
  internal var sceneDepthTexture: MTLTexture! { renderer.sceneDepthTexture }
  internal var segmentationTexture: MTLTexture! { renderer.segmentationTexture }
}

extension DelegateRenderer {
  @inlinable var imageResolution: CGSize { renderer.cameraMeasurements.imageResolution }
  
  @inlinable var cameraToWorldTransform: simd_float4x4 { renderer.cameraMeasurements.cameraToWorldTransform }
  @inlinable var worldToCameraTransform: simd_float4x4 { renderer.cameraMeasurements.worldToCameraTransform }
  @inlinable var flyingPerspectiveToWorldTransform: simd_float4x4 { renderer.cameraMeasurements.flyingPerspectiveToWorldTransform }
  @inlinable var worldToFlyingPerspectiveTransform: simd_float4x4 { renderer.cameraMeasurements.worldToFlyingPerspectiveTransform }
  
  @inlinable var worldToScreenClipTransform: simd_float4x4 { renderer.cameraMeasurements.worldToScreenClipTransform }
  @inlinable var worldToHeadsetModeCullTransform: simd_float4x4 { renderer.cameraMeasurements.worldToHeadsetModeCullTransform }
  @inlinable var worldToLeftClipTransform: simd_float4x4 { renderer.cameraMeasurements.worldToLeftClipTransform }
  @inlinable var worldToRightClipTransform: simd_float4x4 { renderer.cameraMeasurements.worldToRightClipTransform }
  
  @inlinable var cameraSpaceLeftEyePosition: simd_float3 { renderer.cameraMeasurements.cameraSpaceLeftEyePosition }
  @inlinable var cameraSpaceRightEyePosition: simd_float3 { renderer.cameraMeasurements.cameraSpaceRightEyePosition }
  @inlinable var cameraSpaceHeadsetModeCullOrigin: simd_float3 { renderer.cameraMeasurements.cameraSpaceHeadsetModeCullOrigin }
  
  @inlinable var cameraToLeftClipTransform: simd_float4x4 { renderer.cameraMeasurements.cameraToLeftClipTransform }
  @inlinable var cameraToRightClipTransform: simd_float4x4 { renderer.cameraMeasurements.cameraToRightClipTransform }
  @inlinable var cameraToHeadsetModeCullTransform: simd_float4x4 { renderer.cameraMeasurements.cameraToHeadsetModeCullTransform }
}
