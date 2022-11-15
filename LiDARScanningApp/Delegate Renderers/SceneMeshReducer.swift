//
//  SceneMeshReducer.swift
//  ARHeadsetKit
//
//  Created by Philip Turner on 4/13/21.
//

import Metal
import ARKit

final class SceneMeshReducer: DelegateRenderer {
    unowned let renderer: MainRenderer
  
  // MARK: - SceneRenderer properties
  
  var currentlyMatchingMeshes = false
  var justCompletedMatching = false
  var completedMatchingBeforeLastFrame = false
  
  var meshToWorldTransform = simd_float4x4(1)
  
  var reducedVertexBuffer: MTLBuffer!
      var reducedNormalBuffer: MTLBuffer!
      var reducedColorBuffer: MTLBuffer! // NOTE: this buffer isn't used for this app
      var reducedIndexBuffer: MTLBuffer!
  
  func exportData() -> Data? {
    guard let reducedVertexBuffer = reducedVertexBuffer,
          let reducedIndexBuffer = reducedIndexBuffer,
          let reducedNormalBuffer = reducedNormalBuffer,
          let numVertices = preCullVertexCount,
          let numTriangles = preCullTriangleCount,
          let numNormals = preCullVertexCount else {
      return nil
    }
    
    // Headers + padding
    var memorySize = 3 * MemoryLayout<UInt32>.stride + 4
    precondition(memorySize == 16)
    memorySize += numVertices * MemoryLayout<SIMD3<Float>>.stride
    memorySize += numTriangles * MemoryLayout<SIMD3<UInt32>>.stride
    memorySize += numNormals * MemoryLayout<SIMD3<Float>>.stride
    
    // Create pointer
    var byteStream = malloc(memorySize)!
    let originalPointer = byteStream
    
    // Write headers
    let headersPointer = byteStream.assumingMemoryBound(to: UInt32.self)
    headersPointer[0] = UInt32(numVertices)
    headersPointer[1] = UInt32(numTriangles)
    headersPointer[2] = UInt32(numNormals)
    headersPointer[3] = UInt32(0)
    byteStream += 16
    
    // Exploits the fact that every section uses 16-byte elements
    func write(buffer: MTLBuffer, numElements: Int) {
      let src = buffer.contents()
      let dst = byteStream
      let len = numElements * 16
      memcpy(dst, src, len)
      byteStream += len
    }
    
    // Write data
    write(buffer: reducedVertexBuffer, numElements: numVertices)
    write(buffer: reducedIndexBuffer, numElements: numTriangles)
    write(buffer: reducedNormalBuffer, numElements: numNormals)
    
    // Validate and export
    precondition(byteStream - originalPointer == memorySize)
    precondition(headersPointer[0] = UInt32(numVertices))
    precondition(headersPointer[1] = UInt32(numTriangles))
    precondition(headersPointer[2] = UInt32(numNormals))
    precondition(headersPointer[3] = UInt32(0))
    return Data(
      bytesNoCopy: originalPointer, count: memorySize, deallocator: .free)
  }
  
  var preCullVertexCount: Int!
  var preCullTriangleCount: Int!
  var preCullVertexCountOffset: Int { renderIndex * MemoryLayout<UInt32>.stride }
  var preCullTriangleCountOffset: Int { renderIndex * MemoryLayout<UInt32>.stride }
  
  // MARK: - SceneMeshReducer properties
  
    var meshUpdateCounter: Int = 100_000_000
    var shouldUpdateMesh = false
    
    var meshUpdateRate: Int {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return 18 - 2
        case .fair:     return 36 - 2
        case .serious:  return 72
        case .critical: return 100_000_000
        @unknown default: fatalError("This thermal state is not possible!")
        }
    }
    
    private var _meshToWorldTransform = simd_float4x4(1)
    var submeshes: [ARMeshAnchor] = []
    
//    typealias SmallSectorHashLayer = SmallSectorLayer
//    var smallSectorHashBuffer: MTLLayeredBuffer<SmallSectorHashLayer> { sceneMeshMatcher.newSmallSectorBuffer }
    
    enum UniformLayer: UInt16, MTLBufferLayer {
        case numVertices
        case numTriangles
        case meshTranslation
        
        static let bufferLabel = "Scene Mesh Reducer Uniform Buffer"
        
        func getSize(capacity: Int) -> Int {
            switch self {
            case .numVertices:     return capacity * MemoryLayout<UInt32>.stride
            case .numTriangles:    return capacity * MemoryLayout<UInt32>.stride
            case .meshTranslation: return capacity * MemoryLayout<simd_float3>.stride
            }
        }
    }
    
    enum BridgeLayer: UInt16, MTLBufferLayer {
        case vertexMark
        case counts4
        case counts16
        case counts64
        case counts512
        case counts4096
        
        case offsets4096
        case offsets512
        case offsets64
        case offsets16
        case offsets4
        case vertexOffset
        
        static let bufferLabel = "Scene Mesh Reducer Bridge Buffer"
        
        func getSize(capacity: Int) -> Int {
            switch self {
            case .vertexMark:   return capacity       * MemoryLayout<UInt8>.stride
            case .counts4:      return capacity >>  2 * MemoryLayout<UInt8>.stride
            case .counts16:     return capacity >>  4 * MemoryLayout<UInt8>.stride
            case .counts64:     return capacity >>  6 * MemoryLayout<UInt8>.stride
            case .counts512:    return capacity >>  9 * MemoryLayout<UInt16>.stride
            case .counts4096:   return capacity >> 12 * MemoryLayout<UInt16>.stride
                
            case .offsets4096:  return capacity >> 12 * MemoryLayout<UInt32>.stride
            case .offsets512:   return capacity >>  9 * MemoryLayout<UInt32>.stride
            case .offsets64:    return capacity >>  6 * MemoryLayout<UInt32>.stride
            case .offsets16:    return capacity >>  4 * MemoryLayout<UInt32>.stride
            case .offsets4:     return capacity >>  2 * MemoryLayout<UInt32>.stride
            case .vertexOffset: return capacity       * MemoryLayout<UInt32>.stride
            }
        }
    }
    
    enum SectorIDLayer: UInt16, MTLBufferLayer {
        case triangleGroupMask
        case triangleGroup
        
        case vertexGroupMask
        case vertexGroup
        
        static let bufferLabel = "Scene Mesh Reducer Sector ID Buffer"
        
        func getSize(capacity: Int) -> Int {
            switch self {
            case .triangleGroupMask: return capacity >> 6 * MemoryLayout<UInt8>.stride
            case .triangleGroup:     return capacity >> 3 * MemoryLayout<UInt8>.stride
                
            case .vertexGroupMask:   return capacity >> 6 * MemoryLayout<UInt8>.stride
            case .vertexGroup:       return capacity >> 3 * MemoryLayout<UInt8>.stride
            }
        }
    }
    
    var uniformBuffer: MTLLayeredBuffer<UniformLayer>
    var bridgeBuffer: MTLLayeredBuffer<BridgeLayer>
    
    var currentSectorIDBuffer: MTLLayeredBuffer<SectorIDLayer>
    var pendingSectorIDBuffer: MTLLayeredBuffer<SectorIDLayer>
    var transientSectorIDBuffer: MTLBuffer
    
    private var _preCullVertexCount: Int!
    private var _preCullTriangleCount: Int!
    
    var currentReducedVertexBuffer: MTLBuffer
    var currentReducedNormalBuffer: MTLBuffer
    var currentReducedColorBuffer: MTLBuffer
    var currentReducedIndexBuffer: MTLBuffer
    
    var pendingReducedVertexBuffer: MTLBuffer
    var pendingReducedNormalBuffer: MTLBuffer
    var pendingReducedColorBuffer: MTLBuffer
    var pendingReducedIndexBuffer: MTLBuffer
    
    var markSubmeshVerticesPipelineState: MTLComputePipelineState
    var countSubmeshVertices4to64PipelineState: MTLComputePipelineState
    var countSubmeshVertices512PipelineState: MTLComputePipelineState
    var scanSubmeshVertices4096PipelineState: MTLComputePipelineState
    
    var markSubmeshVertexOffsets512PipelineState: MTLComputePipelineState
    var markSubmeshVertexOffsets64to16PipelineState: MTLComputePipelineState
    var markSubmeshVertexOffsets4PipelineState: MTLComputePipelineState
    var reduceSubmeshesPipelineState: MTLComputePipelineState
    
    var slowAssignVertexSectorIDs_8bitPipelineState: MTLComputePipelineState
    var fastAssignVertexSectorIDs_8bitPipelineState: MTLComputePipelineState
    var assignVertexSectorIDs_16bitPipelineState: MTLComputePipelineState
    
    var slowAssignTriangleSectorIDs_8bitPipelineState: MTLComputePipelineState
    var fastAssignTriangleSectorIDs_8bitPipelineState: MTLComputePipelineState
    var assignTriangleSectorIDs_16bitPipelineState: MTLComputePipelineState
    
    var poolVertexGroupSectorIDs_8bitPipelineState: MTLComputePipelineState
    var poolVertexGroupSectorIDs_16bitPipelineState: MTLComputePipelineState
    var poolTriangleGroupSectorIDs_8bitPipelineState: MTLComputePipelineState
    var poolTriangleGroupSectorIDs_16bitPipelineState: MTLComputePipelineState
    
    init(renderer: MainRenderer, library: MTLLibrary) {
        self.renderer = renderer
        let device = renderer.device
      
      // MARK: - SceneRenderer initialization
      
      // MARK: - SceneMeshReducer initialization
        
        let meshCapacity = 16
        let vertexCapacity = 32768
        let triangleCapacity = 65536
        
        uniformBuffer = device.makeLayeredBuffer(capacity: meshCapacity,   options: .storageModeShared)
        bridgeBuffer  = device.makeLayeredBuffer(capacity: vertexCapacity, options: .storageModeShared)
        
        currentSectorIDBuffer = device.makeLayeredBuffer(capacity: triangleCapacity)
        pendingSectorIDBuffer = device.makeLayeredBuffer(capacity: triangleCapacity)
        currentSectorIDBuffer.optLabel = "Scene Mesh Reducer Sector ID Buffer (Not Used Yet)"
        pendingSectorIDBuffer.optLabel = "Scene Mesh Reducer Sector ID Buffer (Pending)"
        
        let transientSectorIDBufferSize = triangleCapacity * MemoryLayout<UInt8>.stride
        transientSectorIDBuffer = device.makeBuffer(length: transientSectorIDBufferSize, options: .storageModeShared)!
        transientSectorIDBuffer.optLabel = "Scene Mesh Reducer Transient Sector ID Buffer"
        
        
        
        let reducedVertexBufferSize = vertexCapacity * MemoryLayout<simd_float3>.stride
        currentReducedVertexBuffer = device.makeBuffer(length: reducedVertexBufferSize, options: .storageModeShared)!
        pendingReducedVertexBuffer = device.makeBuffer(length: reducedVertexBufferSize, options: .storageModeShared)!
        currentReducedVertexBuffer.optLabel = "Scene Reduced Vertex Buffer (Not Used Yet)"
        pendingReducedVertexBuffer.optLabel = "Scene Reduced Vertex Buffer (Pending)"
        
        let reducedNormalBufferSize = vertexCapacity * MemoryLayout<simd_half3>.stride
        currentReducedNormalBuffer = device.makeBuffer(length: reducedNormalBufferSize, options: .storageModeShared)!
        pendingReducedNormalBuffer = device.makeBuffer(length: reducedNormalBufferSize, options: .storageModeShared)!
        currentReducedNormalBuffer.optLabel = "Scene Reduced Normal Buffer (Not Used Yet)"
        pendingReducedNormalBuffer.optLabel = "Scene Reduced Normal Buffer (Pending)"
        
        let reducedColorBufferSize = triangleCapacity * MemoryLayout<simd_uint4>.stride
        currentReducedColorBuffer = device.makeBuffer(length: reducedColorBufferSize, options: .storageModeShared)!
        pendingReducedColorBuffer = device.makeBuffer(length: reducedColorBufferSize, options: .storageModeShared)!
        currentReducedColorBuffer.optLabel = "Scene Reduced Color Buffer (Not Used Yet)"
        pendingReducedColorBuffer.optLabel = "Scene Reduced Color Buffer (Pending)"
        
        let reducedIndexBufferSize = triangleCapacity * MemoryLayout<simd_uint3>.stride
        currentReducedIndexBuffer = device.makeBuffer(length: reducedIndexBufferSize, options: .storageModeShared)!
        pendingReducedIndexBuffer = device.makeBuffer(length: reducedIndexBufferSize, options: .storageModeShared)!
        currentReducedIndexBuffer.optLabel = "Scene Reduced Index Buffer (Not Used Yet)"
        pendingReducedIndexBuffer.optLabel = "Scene Reduced Index Buffer (Pending)"
        
        
        
        markSubmeshVerticesPipelineState       = library.makeComputePipeline(Self.self, name: "markSubmeshVertices")
        countSubmeshVertices4to64PipelineState = library.makeComputePipeline(Self.self, name: "countSubmeshVertices4to64")
        countSubmeshVertices512PipelineState   = library.makeComputePipeline(Self.self, name: "countSubmeshVertices512")
        scanSubmeshVertices4096PipelineState   = library.makeComputePipeline(Self.self, name: "scanSubmeshVertices4096")
        
        markSubmeshVertexOffsets512PipelineState    = library.makeComputePipeline(Self.self, name: "markSubmeshVertexOffsets512")
        markSubmeshVertexOffsets64to16PipelineState = library.makeComputePipeline(Self.self, name: "markSubmeshVertexOffsets64to16")
        markSubmeshVertexOffsets4PipelineState      = library.makeComputePipeline(Self.self, name: "markSubmeshVertexOffsets4")
        reduceSubmeshesPipelineState                = library.makeComputePipeline(Self.self, name: "reduceSubmeshes_noRotation")
        
        
        
        let computePipelineDescriptor = MTLComputePipelineDescriptor()
        computePipelineDescriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = true
        
        let assignVertexSectorIDs_8bitFunction = library.makeFunction(name: "assignVertexSectorIDs_8bit")!
        slowAssignVertexSectorIDs_8bitPipelineState = library.makeComputePipeline(Self.self,
                                                                                  name: "Assign Vertex Sector IDs (8-bit, Slow)",
                                                                                  function: assignVertexSectorIDs_8bitFunction)
        
        computePipelineDescriptor.computeFunction = assignVertexSectorIDs_8bitFunction
        computePipelineDescriptor.optLabel = "Scene Mesh Reducer Assign Vertex Sector IDs (8-bit, Fast) Pipeline"
        fastAssignVertexSectorIDs_8bitPipelineState = device.makeComputePipelineState(descriptor: computePipelineDescriptor)
        
        computePipelineDescriptor.computeFunction =  library.makeFunction(name: "assignVertexSectorIDs_16bit")!
        computePipelineDescriptor.optLabel = "Scene Mesh Reducer Assign Vertex Sector IDs (16-bit) Pipeline"
        assignVertexSectorIDs_16bitPipelineState = device.makeComputePipelineState(descriptor: computePipelineDescriptor)
        
        
        
        let assignTriangleSectorIDs_8bitFunction = library.makeFunction(name: "assignTriangleSectorIDs_8bit")!
        slowAssignTriangleSectorIDs_8bitPipelineState = library.makeComputePipeline(Self.self,
                                                                                    name: "Assign Triangle Sector IDs (8-bit, Slow)",
                                                                                    function: assignTriangleSectorIDs_8bitFunction)
        
        computePipelineDescriptor.computeFunction = assignTriangleSectorIDs_8bitFunction
        computePipelineDescriptor.optLabel = "Scene Mesh Reducer Assign Triangle Sector IDs (8-bit, Fast) Pipeline"
        fastAssignTriangleSectorIDs_8bitPipelineState = device.makeComputePipelineState(descriptor: computePipelineDescriptor)
        
        computePipelineDescriptor.computeFunction = library.makeFunction(name: "assignTriangleSectorIDs_16bit")!
        computePipelineDescriptor.optLabel = "Scene Mesh Reducer Assign Triangle Sector IDs (16-bit) Pipeline"
        assignTriangleSectorIDs_16bitPipelineState = device.makeComputePipelineState(descriptor: computePipelineDescriptor)
        
        
        
        poolVertexGroupSectorIDs_8bitPipelineState    = library.makeComputePipeline(Self.self, name: "poolVertexGroupSectorIDs_8bit")
        poolVertexGroupSectorIDs_16bitPipelineState   = library.makeComputePipeline(Self.self, name: "poolVertexGroupSectorIDs_16bit")
        poolTriangleGroupSectorIDs_8bitPipelineState  = library.makeComputePipeline(Self.self, name: "poolTriangleGroupSectorIDs_8bit")
        poolTriangleGroupSectorIDs_16bitPipelineState = library.makeComputePipeline(Self.self, name: "poolTriangleGroupSectorIDs_16bit")
    }
    
}

//enum SmallSectorLayer: UInt16, MTLBufferLayer {
//  case mark
//  case hashes
//  case mappings
//  case sortedHashes
//  case sortedHashMappings
//
//  case numSectorsMinus1
//  case preCullVertexCount
//  case using8bitSmallSectorIDs
//  case shouldDoThirdMatch
//
//  static let bufferLabel = "Scene Mesh Matcher Small Sector Buffer"
//
//  func getSize(capacity: Int) -> Int {
//      switch self {
//      case .mark:                    return capacity * MemoryLayout<UInt32>.stride
//      case .hashes:                  return capacity * MemoryLayout<UInt32>.stride
//      case .mappings:                return capacity * MemoryLayout<UInt16>.stride
//      case .sortedHashes:            return capacity * MemoryLayout<UInt32>.stride
//      case .sortedHashMappings:      return capacity * MemoryLayout<UInt16>.stride
//
//      case .numSectorsMinus1:        return max(4, MemoryLayout<UInt16>.stride)
//      case .preCullVertexCount:      return        MemoryLayout<UInt32>.stride
//      case .using8bitSmallSectorIDs: return max(4, MemoryLayout<Bool>.stride)
//      case .shouldDoThirdMatch:      return        MemoryLayout<Bool>.stride
//
//      }
//  }
//}

// MARK: - SceneMeshReducerExtensions.swift

//
//  SceneMeshReducerExtensions.swift
//  ARHeadsetKit
//
//  Created by Philip Turner on 4/13/21.
//

import Metal
import ARKit

extension SceneMeshReducer {
  
  // Reproduces what the `SceneRenderer` does in ARHeadsetKit, in addition to
  // what the `SceneMeshReducer` does. Therefore, there's two `updateResources`
  // methods.
  func updateResources(frame: ARFrame) {
    self.meshUpdateCounter += 1
    self.shouldUpdateMesh = false
    
    if !currentlyMatchingMeshes {
        if justCompletedMatching {
            justCompletedMatching = false
            
            self.synchronizeData()
            
        } else if completedMatchingBeforeLastFrame {
            completedMatchingBeforeLastFrame = false
            
        } else {
            self._updateResources(frame: frame)
        }
    }
  }
    
    private func _updateResources(frame: ARFrame) {
        if meshUpdateCounter < meshUpdateRate {
            shouldUpdateMesh = false
        } else {
            let newSubmeshes = frame.anchors.compactMap{ $0 as? ARMeshAnchor }
            let submeshesAreEqual = submeshes.elementsEqual(newSubmeshes) {
                $0.geometry.vertices.buffer === $1.geometry.vertices.buffer
            }
            
            guard newSubmeshes.count > 0, !submeshesAreEqual else {
                shouldUpdateMesh = false
                return
            }
            
            self.currentlyMatchingMeshes = true
            shouldUpdateMesh = true
            
            meshUpdateCounter = 0
            submeshes = newSubmeshes
        }
    }
    
    func synchronizeData() {
        self.preCullVertexCount   = _preCullVertexCount
        self.preCullTriangleCount = _preCullTriangleCount
//
      self.meshToWorldTransform = _meshToWorldTransform
//        sceneCuller.octreeNodeCenters = sceneSorter.octreeAsArray.map{ $0.node.center }
        
        
        
        swap(&currentReducedVertexBuffer, &pendingReducedVertexBuffer)
        swap(&currentReducedNormalBuffer, &pendingReducedNormalBuffer)
        
        self.reducedVertexBuffer = currentReducedVertexBuffer
        self.reducedNormalBuffer = currentReducedNormalBuffer
        
        currentReducedVertexBuffer.optLabel = "Scene Reduced Vertex Buffer (Current)"
        pendingReducedVertexBuffer.optLabel = "Scene Reduced Vertex Buffer (Pending)"
            
        currentReducedNormalBuffer.optLabel = "Scene Reduced Normal Buffer (Current)"
        pendingReducedNormalBuffer.optLabel = "Scene Reduced Normal Buffer (Pending)"
        
        
        
        swap(&currentReducedColorBuffer, &pendingReducedColorBuffer)
        swap(&currentReducedIndexBuffer, &pendingReducedIndexBuffer)
        swap(&currentSectorIDBuffer,     &pendingSectorIDBuffer)
        
        self.reducedColorBuffer = currentReducedColorBuffer
        self.reducedIndexBuffer = currentReducedIndexBuffer
        
        currentReducedColorBuffer.optLabel = "Scene Reduced Color Buffer (Current)"
        pendingReducedColorBuffer.optLabel = "Scene Reduced Color Buffer (Pending)"
        
        currentReducedIndexBuffer.optLabel = "Scene Reduced Index Buffer (Current)"
        pendingReducedIndexBuffer.optLabel = "Scene Reduced Index Buffer (Pending)"
        
        currentSectorIDBuffer.optLabel = "Scene Mesh Reducer Sector ID Buffer (Current)"
        pendingSectorIDBuffer.optLabel = "Scene Mesh Reducer Sector ID Buffer (Pending)"
        
        
        
//        sceneRenderer.ensureBufferCapacity(type: .vertex,   capacity: preCullVertexCount)
//        sceneRenderer.ensureBufferCapacity(type: .triangle, capacity: preCullTriangleCount)
//
//        sceneCuller.ensureBufferCapacity(type: .sector,   capacity: sceneSorter.octreeAsArray.count)
//        sceneCuller.ensureBufferCapacity(type: .vertex,   capacity: preCullVertexCount)
//        sceneCuller.ensureBufferCapacity(type: .triangle, capacity: preCullTriangleCount)
//
//        sceneOcclusionTester.ensureBufferCapacity(type: .triangle, capacity: preCullTriangleCount)
    }
    
}

protocol BufferExpandable {
    associatedtype BufferType: CaseIterable
    @inlinable func ensureBufferCapacity(type: BufferType, capacity: Int)
}

extension BufferExpandable {
    @inlinable func ensureBufferCapacity<T: FixedWidthInteger>(type: BufferType, capacity: T) {
        ensureBufferCapacity(type: type, capacity: Int(capacity))
    }
}

extension SceneMeshReducer: BufferExpandable {
    
    enum BufferType: CaseIterable {
      // From SceneRenderer
      // decided not to implement any cases
      
      // From SceneMeshReducer
        case _mesh
        case _vertex
        case _triangle
        case _sectorID
    }
    
    func ensureBufferCapacity(type: BufferType, capacity: Int) {
        let newCapacity = roundUpToPowerOf2(capacity)
        
        switch type {
        case ._mesh:     uniformBuffer.ensureCapacity(device: device, capacity: newCapacity)
        case ._vertex:   ensureVertexCapacity(capacity: newCapacity)
        case ._triangle: ensureTriangleCapacity(capacity: newCapacity)
        case ._sectorID: ensureSectorIDCapacity(capacity: newCapacity)
        }
    }
    
    private func ensureVertexCapacity(capacity: Int) {
        let reducedVertexBufferSize = capacity * MemoryLayout<simd_float3>.stride
        if pendingReducedVertexBuffer.length < reducedVertexBufferSize {
            pendingReducedVertexBuffer = device.makeBuffer(length: reducedVertexBufferSize, options: .storageModeShared)!
            pendingReducedVertexBuffer.optLabel = "Scene Reduced Vertex Buffer (Pending)"
            
            let reducedNormalBufferSize = reducedVertexBufferSize >> 1
            pendingReducedNormalBuffer = device.makeBuffer(length: reducedNormalBufferSize, options: .storageModeShared)!
            pendingReducedNormalBuffer.optLabel = "Scene Reduced Normal Buffer (Pending)"
        }
        
        bridgeBuffer.ensureCapacity(device: device, capacity: capacity)
    }
    
    private func ensureTriangleCapacity(capacity: Int) {
        let reducedIndexBufferSize = capacity * MemoryLayout<simd_uint3>.stride
        if pendingReducedIndexBuffer.length < reducedIndexBufferSize {
            pendingReducedIndexBuffer = device.makeBuffer(length: reducedIndexBufferSize, options: .storageModeShared)!
            pendingReducedIndexBuffer.optLabel = "Scene Reduced Index Buffer (Pending)"
        }
        
        let reducedColorBufferSize = capacity * MemoryLayout<simd_uint4>.stride
        if pendingReducedColorBuffer.length < reducedColorBufferSize {
            pendingReducedColorBuffer = device.makeBuffer(length: reducedColorBufferSize, options: .storageModeShared)!
            pendingReducedColorBuffer.optLabel = "Scene Reduced Color Buffer (Pending)"
        }
    }
    
    private func ensureSectorIDCapacity(capacity: Int) {
        let transientSectorIDBufferSize = capacity * MemoryLayout<UInt8>.stride
        if transientSectorIDBuffer.length < transientSectorIDBufferSize {
            transientSectorIDBuffer = device.makeBuffer(length: transientSectorIDBufferSize, options: .storageModeShared)!
            transientSectorIDBuffer.optLabel = "Scene Mesh Reducer Transient Sector ID Buffer"
        }
        
        pendingSectorIDBuffer.ensureCapacity(device: device, capacity: capacity)
    }
    
}

fileprivate extension ARMeshAnchor {
    var vertexBuffer: MTLBuffer { geometry.vertices.buffer }
    var normalBuffer: MTLBuffer { geometry.normals.buffer }
    var indexBuffer: MTLBuffer { geometry.faces.buffer }
}

extension SceneMeshReducer {
  func reduceMeshes() {
         debugLabel {
             for i in 0..<submeshes.count {
                 submeshes[i].vertexBuffer.label = "Submesh \(i) Vertex Buffer"
                 submeshes[i].normalBuffer.label = "Submesh \(i) Normal Buffer"
                 submeshes[i].indexBuffer.label  = "Submesh \(i) Index Buffer"
             }
         }
         
         let vertexCounts = submeshes.map{ $0.vertexBuffer.length / MemoryLayout<simd_packed_float3>.stride }
         let triangleCounts = submeshes.map{ $0.indexBuffer.length / MemoryLayout<simd_packed_uint3>.stride }
         
         let preFilterVertexCount = vertexCounts.reduce(0, +)
         _preCullTriangleCount = triangleCounts.reduce(0, +)
         
         ensureBufferCapacity(type: ._mesh,     capacity: submeshes.count)
         ensureBufferCapacity(type: ._vertex,   capacity: preFilterVertexCount)
         ensureBufferCapacity(type: ._triangle, capacity: _preCullTriangleCount)
         
         let commandBuffer1 = renderer.commandQueue.makeDebugCommandBuffer()
         commandBuffer1.optLabel = "Scene Mesh Reduction Command Buffer 1"
         
         let blitEncoder = commandBuffer1.makeBlitCommandEncoder()!
         blitEncoder.optLabel = "Scene Mesh Reduction - Clear Vertex Mark Buffer"
         
         let expandedVertexCount = ~4095 & (preFilterVertexCount + 4095)
         let fillSize = expandedVertexCount * MemoryLayout<UInt8>.stride
         blitEncoder.fill(buffer: bridgeBuffer, layer: .vertexMark, range: 0..<fillSize, value: 0)
         
         blitEncoder.endEncoding()
         
         
         
         var computeEncoder = commandBuffer1.makeComputeCommandEncoder()!
         computeEncoder.optLabel = "Scene Mesh Reduction - Compute Pass 1"
         
         computeEncoder.pushOptDebugGroup("Mark Submesh Vertices")
         
         computeEncoder.setComputePipelineState(markSubmeshVerticesPipelineState)
         
         var vertexMarkOffset = 0
         
         for i in 0..<submeshes.count {
             computeEncoder.setBuffer(bridgeBuffer, layer: .vertexMark, offset: vertexMarkOffset, index: 0, bound: i != 0)
             computeEncoder.setBuffer(submeshes[i].indexBuffer,         offset: 0,                index: 1)
             computeEncoder.dispatchThreadgroups([ triangleCounts[i] ], threadsPerThreadgroup: 1)
             
             vertexMarkOffset += vertexCounts[i] * MemoryLayout<UInt8>.stride
         }
         
         if submeshes.count > 1 {
             computeEncoder.setBuffer(bridgeBuffer, layer: .vertexMark, offset: 0, index: 0, bound: true)
         }
         
         computeEncoder.popOptDebugGroup()
         computeEncoder.pushOptDebugGroup("Count Submesh Vertices")
         
         computeEncoder.setComputePipelineState(countSubmeshVertices4to64PipelineState)
         
         computeEncoder.setBuffer(bridgeBuffer, layer: .counts4, index: 1)
         computeEncoder.dispatchThreadgroups([ expandedVertexCount >> 2 ], threadsPerThreadgroup: 1)
         
         computeEncoder.setBuffer(bridgeBuffer, layer: .counts4,  index: 0, bound: true)
         computeEncoder.setBuffer(bridgeBuffer, layer: .counts16, index: 1, bound: true)
         computeEncoder.dispatchThreadgroups([ expandedVertexCount >> 4 ], threadsPerThreadgroup: 1)
         
         computeEncoder.setBuffer(bridgeBuffer, layer: .counts16, index: 0, bound: true)
         computeEncoder.setBuffer(bridgeBuffer, layer: .counts64, index: 1, bound: true)
         computeEncoder.dispatchThreadgroups([ expandedVertexCount >> 6 ], threadsPerThreadgroup: 1)
         
         computeEncoder.setComputePipelineState(countSubmeshVertices512PipelineState)
         computeEncoder.setBuffer(bridgeBuffer, layer: .counts512, index: 0, bound: true)
         computeEncoder.dispatchThreadgroups([ expandedVertexCount >> 9 ], threadsPerThreadgroup: 1)
         
         computeEncoder.setComputePipelineState(scanSubmeshVertices4096PipelineState)
         computeEncoder.setBuffer(bridgeBuffer, layer: .counts4096, index: 1, bound: true)
         computeEncoder.setBuffer(bridgeBuffer, layer: .offsets512, index: 2)
         computeEncoder.dispatchThreadgroups([ expandedVertexCount >> 12 ], threadsPerThreadgroup: 1)
         
         computeEncoder.popOptDebugGroup()
         computeEncoder.endEncoding()
         
         commandBuffer1.commit()
         
         
         
         let numVerticesPointer     = uniformBuffer[.numVertices].assumingMemoryBound(to: UInt32.self)
         let numTrianglesPointer    = uniformBuffer[.numTriangles].assumingMemoryBound(to: UInt32.self)
         let meshTranslationPointer = uniformBuffer[.meshTranslation].assumingMemoryBound(to: simd_float3.self)
         
         _meshToWorldTransform = submeshes[0].transform.replacingTranslation(with: .zero)
         let worldToMeshTransform = _meshToWorldTransform.inverseRotationTranslation
         
         for i in 0..<submeshes.count {
             numVerticesPointer[i]     = UInt32(vertexCounts[i])
             numTrianglesPointer[i]    = UInt32(triangleCounts[i])
             meshTranslationPointer[i] = simd_make_float3(worldToMeshTransform * submeshes[i].transform[3])
         }
         
         let commandBuffer2 = renderer.commandQueue.makeDebugCommandBuffer()
         commandBuffer2.optLabel = "Scene Mesh Reduction Command Buffer 2"
         
         computeEncoder = commandBuffer2.makeComputeCommandEncoder()!
         computeEncoder.optLabel = "Scene Mesh Reduction - Compute Pass 2"
         
         computeEncoder.pushOptDebugGroup("Mark Submesh Vertex Offsets")
         
         computeEncoder.setComputePipelineState(markSubmeshVertexOffsets512PipelineState)
         computeEncoder.setBuffer(bridgeBuffer, layer: .counts64,   index: 0)
         computeEncoder.setBuffer(bridgeBuffer, layer: .offsets64,  index: 1)
         computeEncoder.setBuffer(bridgeBuffer, layer: .offsets512, index: 2)
         computeEncoder.dispatchThreadgroups([ (preFilterVertexCount + 511) >> 9 ], threadsPerThreadgroup: 1)
         
         computeEncoder.setComputePipelineState(markSubmeshVertexOffsets64to16PipelineState)
         computeEncoder.setBuffer(bridgeBuffer, layer: .counts16,  index: 0, bound: true)
         computeEncoder.setBuffer(bridgeBuffer, layer: .offsets16, index: 2, bound: true)
         computeEncoder.dispatchThreadgroups([ (preFilterVertexCount + 63) >> 6 ], threadsPerThreadgroup: 1)
         
         computeEncoder.setBuffer(bridgeBuffer, layer: .counts4,   index: 0, bound: true)
         computeEncoder.setBuffer(bridgeBuffer, layer: .offsets16, index: 1, bound: true)
         computeEncoder.setBuffer(bridgeBuffer, layer: .offsets4,  index: 2, bound: true)
         computeEncoder.dispatchThreadgroups([ (preFilterVertexCount + 15) >> 4 ], threadsPerThreadgroup: 1)
         
         computeEncoder.setComputePipelineState(markSubmeshVertexOffsets4PipelineState)
         computeEncoder.setBuffer(bridgeBuffer, layer: .vertexMark,   index: 0, bound: true)
         computeEncoder.setBuffer(bridgeBuffer, layer: .vertexOffset, index: 1, bound: true)
         computeEncoder.setBuffer(bridgeBuffer, layer: .offsets4096,  index: 3)
         computeEncoder.dispatchThreadgroups([ (preFilterVertexCount + 3) >> 2 ], threadsPerThreadgroup: 1)
         
         computeEncoder.popOptDebugGroup()
         computeEncoder.pushOptDebugGroup("Reduce Submeshes")
         
         computeEncoder.setComputePipelineState(reduceSubmeshesPipelineState)
         computeEncoder.setBuffer(pendingReducedIndexBuffer,   offset: 0, index: 8)
         computeEncoder.setBuffer(pendingReducedVertexBuffer,  offset: 0, index: 9)
         computeEncoder.setBuffer(pendingReducedNormalBuffer,  offset: 0, index: 10)
         
         var vertexOffset = 0
         var triangleOffset = 0
         
         for i in 0..<submeshes.count {
             if i > 0 {
                 let vertexMarkOffset   = vertexOffset * MemoryLayout<UInt8>.stride
                 let vertexOffsetOffset = vertexOffset * MemoryLayout<UInt32>.stride
                 
                 computeEncoder.setBuffer(bridgeBuffer,  layer: .vertexMark,   offset: vertexMarkOffset,   index: 0, bound: true)
                 computeEncoder.setBuffer(bridgeBuffer,  layer: .vertexOffset, offset: vertexOffsetOffset, index: 1, bound: true)
                 computeEncoder.setBufferOffset(triangleOffset * MemoryLayout<simd_uint3>.stride,          index: 8)
             }
             
             let numVerticesOffset     = i * MemoryLayout<UInt32>.stride
             let numTrianglesOffset    = i * MemoryLayout<UInt32>.stride
             let meshTranslationOffset = i * MemoryLayout<simd_float3>.stride
             
             computeEncoder.setBuffer(uniformBuffer, layer: .numVertices,     offset: numVerticesOffset,     index: 2, bound: i > 0)
             computeEncoder.setBuffer(uniformBuffer, layer: .numTriangles,    offset: numTrianglesOffset,    index: 3, bound: i > 0)
             computeEncoder.setBuffer(uniformBuffer, layer: .meshTranslation, offset: meshTranslationOffset, index: 4, bound: i > 0)
             
             let submesh = submeshes[i]
             
             computeEncoder.setBuffer(submesh.indexBuffer,  offset: 0, index: 5)
             computeEncoder.setBuffer(submesh.vertexBuffer, offset: 0, index: 6)
             computeEncoder.setBuffer(submesh.normalBuffer, offset: 0, index: 7)
             
             let vertexCount   = vertexCounts[i]
             let triangleCount = triangleCounts[i]
             
             vertexOffset   += vertexCount
             triangleOffset += triangleCount
             
             computeEncoder.dispatchThreadgroups([ max(vertexCount, triangleCount) ], threadsPerThreadgroup: 1)
         }
         
         computeEncoder.popOptDebugGroup()
         computeEncoder.endEncoding()
         
         let counts4096Pointer  = bridgeBuffer[.counts4096].assumingMemoryBound(to: UInt16.self)
         let offsets4096Pointer = bridgeBuffer[.offsets4096].assumingMemoryBound(to: UInt32.self)
         
         commandBuffer1.waitUntilCompleted()
         
         
         
         do {
             var vertexOffset: UInt32 = 0
             
             for i in 0..<expandedVertexCount >> 12 {
                 offsets4096Pointer[i] = vertexOffset
                 vertexOffset += UInt32(counts4096Pointer[i])
             }
         }
         
         commandBuffer2.commit()
         
         _preCullVertexCount = Int(vertexOffset)
     }
}
