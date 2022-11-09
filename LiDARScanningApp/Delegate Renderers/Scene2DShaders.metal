//
//  Scene2DShaders.metal
//  LiDARScanningApp
//
//  Created by Philip Turner on 11/8/22.
//

#include <metal_stdlib>
#include "../Metal Utilities/ColorUtilities.h"
using namespace metal;

typedef struct {
  float4x4 projectionTransform;
  float cameraPlaneDepth;
  float2 imageBounds;
} VertexUniforms;

typedef struct {
  float4 position [[position]];
  float2 videoFrameCoords;
} VertexInOut;

[[vertex]]
VertexInOut scene2DVertexTransform(
  constant VertexUniforms &vertexUniforms [[buffer(0)]],
  ushort vid [[vertex_id]]
) {
  float3 cameraSpacePosition(
    vertexUniforms.imageBounds, vertexUniforms.cameraPlaneDepth);

  bool isRight = any(ushort3(1, 2, 4) == vid);
  bool isTop   = any(ushort3(2, 4, 5) == vid);
  
  if (!isRight) { cameraSpacePosition.x = -cameraSpacePosition.x; }
  if (!isTop)   { cameraSpacePosition.y = -cameraSpacePosition.y; }
  
  float2 texCoords(
    select(0, 1, isRight),
    select(1, 0, isTop)
  );
  
  float4 position =
    vertexUniforms.projectionTransform * float4(cameraSpacePosition, 1);
  position.y = copysign(position.w, position.y);
  return { position, texCoords };
}

typedef struct {
  half4 color [[color(0)]];
  float depth [[depth(any)]];
} FragmentOut;

[[fragment]]
FragmentOut scene2DFragmentShader(
  VertexInOut in [[stage_in]],
  texture2d<half, access::sample> colorTextureY [[texture(0)]],
  texture2d<half, access::sample> colorTextureCbCr [[texture(1)]]
) {
  constexpr sampler colorSampler(filter::linear, coord::normalized);
  
  half2 chroma = colorTextureCbCr.sample(colorSampler, in.videoFrameCoords).rg;
  half  luma   = colorTextureY   .sample(colorSampler, in.videoFrameCoords).r;
  
  half4 color(ColorUtilities::convertYCbCr_toRGB(chroma, luma), 1);
  return { color, FLT_MIN };
}
