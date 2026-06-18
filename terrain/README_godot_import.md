# Terrain chunk export → Godot import guide

Exported from Blender 5.1. The 6 km RPG terrain is split into a **31×31 grid (961 chunks)**,
each chunk ~**193.55 m** square (34×34 verts / 1089 quads), recentred to its own local origin.

## Where it lives in this project (godotpipe12)
Already installed at:
```
res://terrain/chunks/Chunk_II_JJ.glb   (the 961 chunk meshes, 25 m skirts + world UVs)
res://terrain/terrain_manifest.json    grid metadata + per-chunk world pos & height range
res://terrain/terrain_splatmap.png     1024² RGBA splatmap (R=grass G=rock B=snow A=sand)
res://terrain/TerrainStreamer.gd       reference distance-streamer (collision + material)
res://terrain/README_godot_import.md   this file
res://shaders/terrain_splat.gdshader   starter shader: blends 4 tiling textures by splatmap
res://scenes/Terrain.tscn              starter scene: a Node3D with the streamer attached
```

## 0. First open
On opening the project, Godot imports the 961 `.glb` (a minute or so the first time) into a
PackedScene each, and the `.png`. Nothing to copy — it's already in place.

For `terrain/terrain_splatmap.png`, in the Import dock set **Compress → Lossless**
(or VRAM Uncompressed) and **Mipmaps on**; do NOT use sRGB (it's data, not colour), then Reimport.

> This is a **C# project**; `TerrainStreamer.gd` is GDScript on purpose — it's a working
> reference that can't affect your C# build. Port it to C# (or write your own loader) when you do
> the streaming pass; the manifest is the contract (see below).

## 2. Scale & units — nothing to change
- **1 Blender metre = 1 Godot unit.** The world is **6000 × 6000 units**. Do **not** rescale on import.
- Exported **+Y up** (Godot-native). Axis mapping is already baked in:
  - Blender +X (east) → Godot **+X**
  - Blender +Y (north) → Godot **−Z**
  - Blender +Z (up) → Godot **+Y**
- Height range across the world: **−373 m … +1470 m**. Sea level is at **y = 0** (your Blender SeaLevel plane).

## 3. Wire up streaming
1. Add a `Node3D` to your level, attach `TerrainStreamer.gd`.
2. Set **Player Path** to your player/camera node.
3. Tune **Load Radius** / **Keep Radius** (in chunks). `load_radius = 6` ≈ a 13×13 chunk
   window ≈ 2.5 km view; `keep_radius` must stay **larger** than `load_radius` (hysteresis).
4. Chunks load asynchronously (`load_threaded_request`) and free when the player moves away.
   Each chunk is placed from the manifest `pos`; meshes are centred so you never fight float
   precision (local coords stay ±97 m).

Chunk index from any world position:
```
j = round(player.x / step_m) + center_index   # step_m = 193.5483, center_index = 15
i = round(-player.z / step_m) + center_index
```

## 4. Collision (runtime trimesh — what you chose)
`TerrainStreamer.gd` builds a `StaticBody3D` + `CollisionShape3D(ConcavePolygonShape3D)`
from each chunk mesh on load (`mesh.create_trimesh_shape()`). 1089 polys/chunk is cheap.
Toggle with the **Add Collision** export flag.
*Optimisation later:* a regular grid can use `HeightMapShape3D` (cheaper) — ask and I'll export
per-chunk 16-bit height PNGs to feed it.

## 5. Level-of-detail
- **Within a chunk:** Godot 4 auto-generates mesh LODs on import (Import dock → *Generate LODs*,
  on by default) and swaps them by screen coverage. You usually need nothing here.
- **Across chunks:** chunk *streaming* (load/free by distance) is handled by the script.
- **Skirts (included):** every chunk has a 25 m vertical lip around its edge (`skirt_depth_m` in
  the manifest). This hides any hairline crack that independent per-mesh LOD could open between a
  near (high-LOD) and far (low-LOD) chunk — you see skirt instead of sky. Chunk *surfaces* are
  also watertight at matching LOD (shared boundary vertex positions). If skirts ever peek out on a
  steep coast, lower the **Skirt Depth** in the Blender panel and re-export.

## 6. Materials / splatmap (texture it here)
Each chunk has a **per-vertex world UV** (0..1 across the full 6 km), so all chunks sample the one
shared `terrain_splatmap.png` seamlessly. Channels: **R=grass, G=rock, B=snow, A=sand** weights
(sum to 1). Use the provided `terrain_splat.gdshader`:

1. Create a **ShaderMaterial**, set its shader to `terrain_splat.gdshader`.
2. Assign `splatmap` = `terrain_splatmap.png`, and `tex_grass/rock/snow/sand` = your 4 tiling
   PBR albedo textures. Set `tile_m` to taste (~8–16 m per tile) and `world_size_m` = 6000.
3. Drag that material into the **Terrain Material** slot on the TerrainStreamer node — it applies
   to every chunk as it streams in. (Or set it per chunk yourself.)

The shader is a starting point (albedo only). Extend it with normal/roughness layers, slope-based
blending, or triplanar on cliffs as you like. The biome split was derived from height + slope:
rock on slopes >~30°, snow above ~950 m, sand near/below sea level, grass elsewhere.

## 7. Float precision
6 km is comfortably within 32-bit float range (≈0.0002 m error at 3 km). If you later grow the
world past ~8–10 km, add origin-rebasing (shift the world so the player stays near 0,0).

---
### Regenerating / re-exporting
The export button lives in Blender: **3D View → N sidebar → Terrain tab → Export Chunks for Godot**
(set the folder field first). Re-run it any time after editing chunks. Re-splitting at a different
chunk resolution is a one-call rebuild from the hidden `Terrain_backup`.
