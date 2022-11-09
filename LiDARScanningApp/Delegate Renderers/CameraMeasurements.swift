//
//  CameraMeasurements.swift
//  ARHeadsetKit
//
//  Created by Philip Turner on 8/11/21.
//

import ARKit
import UIKit
import DeviceKit

final class CameraMeasurements: DelegateUserSettings {
    unowned let userSettings: UserSettings
    
    enum FlyingPerspectiveAdjustMode {
        case none
        case move
        case start
    }
    
    var flyingPerspectiveAdjustMode: FlyingPerspectiveAdjustMode = .none
    
    var deviceSize: simd_double3
    var screenSize: simd_double2
    var wideCameraOffset: simd_double3
    
    @usableFromInline var imageResolution: CGSize
    var aspectRatio: Float
    var cameraToScreenAspectRatioMultiplier: Float
    var cameraSpaceScreenCenter: simd_double3
    
    @usableFromInline var cameraToWorldTransform = simd_float4x4(1)
    @usableFromInline var worldToCameraTransform = simd_float4x4(1)
    @usableFromInline var flyingPerspectiveToWorldTransform = simd_float4x4(1)
    @usableFromInline var worldToFlyingPerspectiveTransform = simd_float4x4(1)
    
    @usableFromInline var worldToScreenClipTransform = simd_float4x4(1)
    @usableFromInline var worldToHeadsetModeCullTransform = simd_float4x4(1)
    @usableFromInline var worldToLeftClipTransform = simd_float4x4(1)
    @usableFromInline var worldToRightClipTransform = simd_float4x4(1)
    
    @inlinable @inline(__always)
    var handheldEyePosition: simd_float3 {
        let usingFlyingMode = false//renderer.usingFlyingMode
        return simd_make_float3(usingFlyingMode ? flyingPerspectiveToWorldTransform[3] : cameraToWorldTransform[3])
    }
    
    var flyingPerspectivePosition: simd_float3!
    var cameraSpaceRotationCenter = simd_float3.zero
    var cameraSpaceHeadPosition = simd_float3.zero
    @usableFromInline var interfaceCenter = simd_float3.zero
    @usableFromInline var leftEyePosition = simd_float3.zero
    @usableFromInline var rightEyePosition = simd_float3.zero
    
    @usableFromInline var cameraSpaceLeftEyePosition = simd_float3.zero
    @usableFromInline var cameraSpaceRightEyePosition = simd_float3.zero
    var cameraSpaceBetweenEyesPosition = simd_float3.zero
    @usableFromInline var cameraSpaceHeadsetModeCullOrigin = simd_float3.zero
    
    var headsetProjectionTransform: simd_float4x4!
    @usableFromInline var cameraToLeftClipTransform = simd_float4x4(1)
    @usableFromInline var cameraToRightClipTransform = simd_float4x4(1)
    @usableFromInline var cameraToHeadsetModeCullTransform = simd_float4x4(1)
    
    var cameraPlaneWidthSum: Double = 0
    var cameraPlaneWidthSampleCount: Int = -12
    var currentPixelWidth: Double = 0
    
    init(userSettings: UserSettings, library: MTLLibrary) {
        self.userSettings = userSettings
        
        imageResolution = ARWorldTrackingConfiguration.supportedVideoFormats.first!.imageResolution
        aspectRatio = Float(imageResolution.width / imageResolution.height)
        
        var device = Device.current
        let possibleDeviceSize = device.deviceSize
        
        let nativeBounds = UIScreen.main.nativeBounds
        let screenBounds = CGSize(width: nativeBounds.height, height: nativeBounds.width)
        cameraToScreenAspectRatioMultiplier = aspectRatio * Float(screenBounds.height / screenBounds.width)
        
        if possibleDeviceSize == nil, UIDevice.current.userInterfaceIdiom == .phone {
            var device: FutureDevice
            
            if screenBounds.width >= 2778 || screenBounds.height >= 1284 {
                device = .iPhone14ProMax
            } else if screenBounds.width >= 2532 || screenBounds.height >= 1170 {
                if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                    device = .iPhone14Pro
                } else {
                    device = .iPhone14
                }
            } else {
                device = .iPhoneSE3
            }
            
            deviceSize = device.deviceSize
            screenSize = device.screenSize
            wideCameraOffset = device.wideCameraOffset
        } else {
            if let possibleDeviceSize = possibleDeviceSize {
                deviceSize = possibleDeviceSize
            } else {
                if screenBounds.width >= 2732 || screenBounds.height >= 2048 {
                    device = .iPadPro12Inch5
                } else if screenBounds.width >= 2388 || screenBounds.height >= 1668 {
                    device = .iPadPro11Inch3
                } else if screenBounds.width >= 2360 || screenBounds.height >= 1640 {
                    device = .iPadAir4
                } else if screenBounds.width >= 2266 || screenBounds.height < 1620 {
                    device = .iPadMini6
                } else {
                    device = .iPad9
                }
                
                deviceSize = device.deviceSize
            }
            
            screenSize = device.screenSize
            wideCameraOffset = device.wideCameraOffset
        }
        
        cameraSpaceScreenCenter = simd_double3(fma(simd_double2(deviceSize.x, deviceSize.y), [0.5, -0.5],
                                                   simd_double2(-wideCameraOffset.x, wideCameraOffset.y)), wideCameraOffset.z)
    }
}

extension CameraMeasurements {
    
    func updateResources(frame: ARFrame) {
        currentPixelWidth = simd_fast_recip(Double(frame.camera.intrinsics[0][0]))
        cameraPlaneWidthSampleCount += 1
        
        if cameraPlaneWidthSampleCount > 0 {
            cameraPlaneWidthSum = fma(Double(imageResolution.width), currentPixelWidth, cameraPlaneWidthSum)
        }
        
      var headsetProjectionScale: Float!
      let storedSettings = userSettings.lensDistortionSettings
      let pendingStoredSettings = storedSettings
        
        @inline(__always)
        func generateHeadsetProjectionScale() {
            let headsetPlaneSize = tan(degreesToRadians(storedSettings.headsetFOV) * 0.5)
            headsetProjectionScale = Float(simd_fast_recip(headsetPlaneSize))
        }
        
        if headsetProjectionTransform == nil {
            let cameraSpaceHeadsetOrigin = simd_float3(.init(
                (deviceSize.x * 0.5) - wideCameraOffset.x,
                -deviceSize.y + wideCameraOffset.y - storedSettings.caseThickness,
                wideCameraOffset.z + storedSettings.caseProtrusionDepth
            ))
            
            let bezelSize = (deviceSize.y - screenSize.y) * 0.5
            let viewCenterToMiddleDistance = pendingStoredSettings.eyeOffsetX
            let viewCenterToBottomDistance = pendingStoredSettings.eyeOffsetY - bezelSize - pendingStoredSettings.caseThickness
            
//            let pixelsPerMeter = lensDistortionCorrector.pixelsPerMeter
//            lensDistortionCorrector.viewCenterToMiddleDistance = Int(viewCenterToMiddleDistance * pixelsPerMeter)
//            lensDistortionCorrector.viewCenterToBottomDistance = Int(viewCenterToBottomDistance * pixelsPerMeter)
            
//            var viewSideLength = ~1 & (Int(round(pendingStoredSettings.viewportDiameter * pixelsPerMeter)) + 1)
//            viewSideLength = min(2048, viewSideLength)
//            lensDistortionCorrector.viewSideLength = viewSideLength
            
//            let viewTopToBottomDistance = viewSideLength >> 1 + lensDistortionCorrector.viewCenterToBottomDistance
//            let dispatchSizeY = min(viewSideLength, viewTopToBottomDistance)
//            lensDistortionCorrector.correctLensDistortionDispatchSize = [ viewSideLength, dispatchSizeY ]
            
            var headsetSpaceEyePosition = simd_float3(.init(
                pendingStoredSettings.eyeOffsetX,
                pendingStoredSettings.eyeOffsetY,
                pendingStoredSettings.eyeOffsetZ
            ))
            
            cameraSpaceRightEyePosition = cameraSpaceHeadsetOrigin + headsetSpaceEyePosition
            
            headsetSpaceEyePosition.x = -headsetSpaceEyePosition.x
            var cameraSpaceEyePosition = cameraSpaceHeadsetOrigin + headsetSpaceEyePosition
            cameraSpaceLeftEyePosition = cameraSpaceEyePosition
            
            
            
            cameraSpaceEyePosition.x = cameraSpaceHeadsetOrigin.x
            cameraSpaceBetweenEyesPosition = cameraSpaceEyePosition
            
            generateHeadsetProjectionScale()
            cameraSpaceEyePosition.z = fma(headsetProjectionScale, -headsetSpaceEyePosition.x, cameraSpaceEyePosition.z)
            cameraSpaceHeadsetModeCullOrigin = cameraSpaceEyePosition
        }
        
        if !pendingStoredSettings.intermediateTextureMatches(storedSettings) || headsetProjectionTransform == nil {
            if headsetProjectionTransform != nil {
//                lensDistortionCorrector.updatingIntermediateTexture = true
            }
            
            if headsetProjectionScale == nil { generateHeadsetProjectionScale() }
            headsetProjectionTransform = matrix4x4_perspective(xs: headsetProjectionScale,
                                                               ys: headsetProjectionScale, nearZ: 1000, farZ: 0.001)
        }
        
        if headsetProjectionScale != nil {
            cameraToLeftClipTransform        = headsetProjectionTransform.prependingTranslation(-cameraSpaceLeftEyePosition)
            cameraToRightClipTransform       = headsetProjectionTransform.prependingTranslation(-cameraSpaceRightEyePosition)
            cameraToHeadsetModeCullTransform = headsetProjectionTransform.prependingTranslation(-cameraSpaceHeadsetModeCullOrigin)
        }
        
        
        
        cameraToWorldTransform = frame.camera.transform
        worldToCameraTransform = cameraToWorldTransform.inverseRotationTranslation
        
        var cameraSpaceInterfaceCenter: simd_float4
        
//        if usingHeadsetMode {
//            cameraSpaceRotationCenter = cameraSpaceBetweenEyesPosition
//            cameraSpaceRotationCenter.z += 0.023
//            cameraSpaceHeadPosition = cameraSpaceRotationCenter
//
//            cameraSpaceInterfaceCenter = .init(cameraSpaceHeadPosition, 1)
//        } else {
            cameraSpaceRotationCenter = simd_float3(cameraSpaceScreenCenter + .init(0, 0, 0.25))
            cameraSpaceHeadPosition = [0, 0, 0]
            
            cameraSpaceInterfaceCenter = .init(0, 0, cameraSpaceRotationCenter.z, 1)
//        }
        
        interfaceCenter = simd_make_float3(cameraToWorldTransform * cameraSpaceInterfaceCenter)
        
        
        
//        if usingFlyingMode {
//            switch flyingPerspectiveAdjustMode {
//            case .none:
//                break
//            case .move:
//                let delta = cameraToWorldTransform[2] * (renderer.flyingDirectionIsForward ? -1.0 / 60 : 1.0 / 60)
//                flyingPerspectivePosition += simd_make_float3(delta)
//            case .start:
//                flyingPerspectivePosition = simd_make_float3(cameraToWorldTransform * .init(cameraSpaceRotationCenter, 1))
//            }
//
//            flyingPerspectiveAdjustMode = .none
//
//            flyingPerspectiveToWorldTransform = cameraToWorldTransform.replacingTranslation(with: flyingPerspectivePosition)
//            flyingPerspectiveToWorldTransform = flyingPerspectiveToWorldTransform.prependingTranslation(-cameraSpaceRotationCenter)
//
//            worldToFlyingPerspectiveTransform = flyingPerspectiveToWorldTransform.inverseRotationTranslation
//        } else {
//            flyingPerspectivePosition = nil
//        }
        
        
        
        let worldToCameraTransform = //usingFlyingMode ? worldToFlyingPerspectiveTransform
                                                      self.worldToCameraTransform
        
//        if usingHeadsetMode {
//            worldToHeadsetModeCullTransform = cameraToHeadsetModeCullTransform * worldToCameraTransform
//            worldToLeftClipTransform        = cameraToLeftClipTransform        * worldToCameraTransform
//            worldToRightClipTransform       = cameraToRightClipTransform       * worldToCameraTransform
//
//            let cameraToWorldTransform = usingFlyingMode ? flyingPerspectiveToWorldTransform
//                                                         : self.cameraToWorldTransform
//
//            leftEyePosition  = simd_make_float3(cameraToWorldTransform * .init(cameraSpaceLeftEyePosition,  1))
//            rightEyePosition = simd_make_float3(cameraToWorldTransform * .init(cameraSpaceRightEyePosition, 1))
//        } else {
            var screenProjectionTransform = frame.camera.projectionMatrix(for: .landscapeRight,
                                                                          viewportSize: imageResolution,
                                                                          zNear: 1000, zFar: 0.001)
            screenProjectionTransform[0] *= cameraToScreenAspectRatioMultiplier
            
            worldToScreenClipTransform = screenProjectionTransform * worldToCameraTransform
//        }
    }
    
}
