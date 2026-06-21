# Terrain chunk export → Godot import guide (16 km world)

Exported from Blender 5.1. Source height = **resampled directly from the displaced `Plane`
surface** (not re-derived from the EXR — the displace uses LOCAL+REPEAT mapping that doesn't
stretch the image 1:1, so direct resampling is the only way to match the Blender model exactly),
then scaled to 16 km, upsampled to 3970², + slope-modulated fractal detail. This **replaces**
the old 6 km export (left intact in `terrain_chunks/` + `terrain_manifest.json`).

## What was exported
- **World:** 16 000 × 16 000 units, centred on origin (−8000 … +8000). **1 Blender m = 1 Godot unit.**
- **Grid:** **63 × 63 = 3969 chunks**, each **253.97 m** square, **64 × 64 verts** (~4 m/quad).
  Odd grid → clean centre chunk `Chunk_31_31` at world origin. `center_index = 31`.
- **Height:** Gaea proportions preserved → relief **0 … 821 m**, lowest terrain at **y = 0** (sea level).
- Each chunk has a **25 m skirt** around its edge and a **per-vertex world UV** (0..1 across the
  whole 16 km: u = east, v = north).
- Total ~**758 MB** of `.glb`.

## Files
- `terrain_chunks_16k/Chunk_II_JJ.glb` — 3969 chunk meshes (recentred to local origin, +Y up).
- `terrain_manifest_16k.json` — grid metadata + per-chunk Godot `pos` and height range.
- `terrain_heightmap_16k.png` — 3970² 16-bit BW heightmap (white = 820.8 m). PNG **top = south**,
  matching the control-map orientation convention. Use this to bake your 3D terrain control map.

## Install
Copy into `res://`:
```
res://terrain_chunks_16k/
res://terrain_manifest_16k.json
```
Let Godot import the `.glb` files. **Note:** 3969 files is a heavy one-time import — expect the first
project open to take a while. Set Import → *Generate LODs* on (default) for cheap per-chunk LOD.

## Streaming
Reuse `TerrainStreamer.gd` unchanged — just repoint it:
- **Manifest Path** = `res://terrain_manifest_16k.json`
- **Chunks Dir** = `res://terrain_chunks_16k`

The script reads `step_m` (253.9683) and `center_index` (31) from the manifest, so its index math
already adapts. Chunk index from a world position:
```
j = round(player.x / step_m) + center_index
i = round(-player.z / step_m) + center_index
```
With `load_radius = 6` you stream a 13×13 window ≈ 3.3 km view. Each chunk's `pos` is in Godot space
(`[x, 0, -y_blender]`); meshes are recentred so local coords stay within ±127 m (good float precision).

## Axis mapping (baked into the .glb)
- Blender +X (east) → Godot **+X**
- Blender +Y (north) → Godot **−Z**
- Blender +Z (up) → Godot **+Y**

## Texturing — 3D terrain control map
Geometry carries a world UV (0..1) but **no material** (export was materials='NONE'), exactly so you
can drive shading from your packed control map. Bake the control map against
`terrain_heightmap_16k.png` (same 3970² grid, top = south) using `bake_control_map.py`, then sample
it in the shader with `world_uv = (vertex.world_xz + 8000) / 16000`. See the project CLAUDE.md
"32-Class Control Map Bake" section for the loader/shader gotchas (ship a lossless `.exr` control map,
4-tap bilinear decode, etc.).

## Placeholder textures (shared material — overwritten by the control map later)
`terrain_color.png` (the Gaea `Combine-754_Out` albedo) is shipped so the terrain isn't grey before
the control map exists. Because every chunk has a world UV (0..1), one material textures the whole
world:
1. Copy `terrain_color.png` into `res://`. In the Import dock leave it **sRGB** (it's colour), Mipmaps on.
2. New **StandardMaterial3D** → Albedo → Texture = `terrain_color.png`.
3. Drop it into the TerrainStreamer node's **Terrain Material** slot — it applies to every streamed chunk.
4. **Later:** swap that same slot to your `terrain_splat.gdshader` ShaderMaterial. One-click overwrite.

If the placeholder colour looks N–S mirrored vs the relief, set the material's `uv1_scale.y = -1`
(the colour image's row order vs the mesh UV) — it doesn't affect geometry and the control map replaces
it anyway.

## Float precision
16 km is fine for 32-bit float (~0.001 m error at the far corner). If you push much larger, add
origin-rebasing so the player stays near (0,0).

## Re-exporting
The whole pipeline is reproducible from the Gaea heightmap via the MCP scripts used to generate this
(`terrexp.py` / `chunkexp.py` staged in Blender's tempdir). To change world size, chunk size, height
scale, or detail, adjust the params block and re-run.
