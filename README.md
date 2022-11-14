# LiDAR Scanning App

iOS app for scanning a scene and exporting the 3D mesh. Renders the mesh as a green wireframe and exports it when you tap the screen.

![Screenshot of the green scene mesh overlaid on the real world](./Documentation/AppScreenshot.jpg)

Mesh serialization format:

```
UInt32 - Number of vertices
UInt32 - Number of indices
UInt32 - Number of normals
[SIMD3<Float>] - Vertices; array of coordinate vectors aligned to 16B
[SIMD3<UInt32>] - Indices; array of triangle index triples aligned to 16B
[SIMD3<Float] - Normals; array of direction vectors aligned to 16B
```
