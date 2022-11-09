//
//  LiDARMeshShaders.metal
//  LiDARScanningApp
//
//  Created by Philip Turner on 11/9/22.
//

#include <metal_stdlib>
using namespace metal;

typedef struct {
  float4x4 projectionTransform;
} VertexUniforms;

typedef struct {
  float4 position [[position]];
} VertexInOut;

[[vertex]]
VertexInOut lidarMeshVertexTransform(
  constant VertexUniforms &vertexUniforms [[buffer(0)]],
  const device packed_float3 *vertices [[buffer(1)]],
  uint vid [[vertex_id]]
) {
  float4 position =
    vertexUniforms.projectionTransform * float4(vertices[vid], 1);
  return { position };
}

typedef struct {
  half4 color [[color(0)]];
} FragmentOut;

// This is only the line fragment shader. Duplicate the source code for the
// triangle shader that has opacity.
[[fragment]]
FragmentOut lidarMeshLineFragmentShader(
  VertexInOut in [[stage_in]],
  depth2d<float, access::sample> depthTexture [[texture(0)]]
) {
  constexpr sampler depthSampler(filter::linear, coord::normalized);
  
  // Larger depths mean closer to the camera; this is part of the algorithm that
  // redistributes dynamic range to preserve more information.
  // TODO: Validate that in.xy actually correlates to texture coordinates.
  float depth = depthTexture.sample(depthSampler, in.position.xy);
  
  if (in.position.z >= depth) {
    // Green
    return { half4(0, 1, 0, 1) };
  } else {
    // Red
    return { half4(1, 0, 0, 1) };
  }
}
