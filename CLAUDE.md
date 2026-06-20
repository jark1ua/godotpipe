# CLAUDE.md

Guidance for Claude when working in this repository. Read before making changes.

This is a Godot 4 **.NET** project that mixes **GDScript** and **C#**. It must be
opened with the Godot **.NET** editor (the standard build cannot load C#).

## Toolchain (already installed in this environment)

| Tool | Path / value | Notes |
|---|---|---|
| Godot .NET engine | `/home/user/tools/godot-mono/godot-mono` | `4.6.3.stable.mono` — **use this one** |
| Standard Godot | `/home/user/tools/godot/godot` | `4.6.3.stable`; not used by this project |
| .NET SDK | `dotnet` (8.x) | builds C# → `.godot/mono/temp/bin/Debug/GodotPipe.dll`. May be absent in a fresh container — see Lessons learned. |
| godot-mcp server | `/home/user/tools/godot-mcp/build/index.js` | wired in `.mcp.json`; `GODOT_PATH` → the .NET engine |

`mcp__godot__*` tools load at session start (from `.mcp.json`); they are not
available mid-session if `.mcp.json` changed during it.

## Layout & conventions

- `project.godot` — manifest. `[dotnet] project/assembly_name="GodotPipe"`; `run/main_scene` is the title scene.
- `GodotPipe.csproj` / `GodotPipe.sln` — the C# project: `net8.0`, `Godot.NET.Sdk/4.6.3`, `Nullable=enable`.
- `scenes/*.tscn` — declarative node trees (plain text; safe to hand-edit).
- `scripts/*.gd` — GDScript. `scripts/*.cs` — C#.
- C# scripts: `public partial class Name : GodotType`; **filename must equal the class name**. Override lifecycle as `_Ready` / `_Process` / `_UnhandledInput`. Expose fields with `[Export]`.
- Every script has a committed `.uid` companion — keep it; do not hand-edit or delete.
- Build output is git-ignored, never commit: `.godot/`, `bin/`, `obj/`.

## How files relate across languages

- A node's script language is transparent to other nodes; cross-language access is by node reference.
- From GDScript → C#: read an `[Export]` field with `node.get("FieldName")` (PascalCase); call a public method with `node.call("MethodName", args)`.
- From C# → GDScript: `GetNode<T>(path)`, then `.Get("field")` / `.Call("method")`.
- After adding or editing **C#**, the engine only sees the change after a rebuild
  (`dotnet build GodotPipe.csproj`). **GDScript** and `.tscn` edits need no build.

## Commands

- Build C#: `dotnet build GodotPipe.csproj`
- Run (desktop window): `./scripts/run.sh`
- Run headless: `HEADLESS=1 ./scripts/run.sh`
- Screenshot a scene (only when verification is requested): `./scripts/capture.sh [res://scene.tscn res://docs/out.png]`

## Working agreement

- **Scope:** the main job is writing functionality and debugging — C# files,
  GDScript files, the relationships between them, and MCP wiring. Often a single
  C# edit; sometimes a C# edit plus a little GDScript/MCP glue.
- **Verification:** the user verifies changes on their own machine. Do **not**
  self-verify by running the engine or generating screenshots unless explicitly
  asked (e.g. when the user cannot access their machine). Make the code correct;
  state what a reviewer should check.
- **README:** do not update it unless directed.
- **Environment:** do not install, download, or reconfigure tooling unless clearly
  expedient — and ask first.
- **Git:** work on the session's designated feature branch; clear commit messages;
  do not open pull requests unless asked.

## Lessons learned (gotchas that have bitten us)

### Shaders (Godot shading language ≠ raw GLSL)
- **No `return` in `fragment()` / `vertex()` / `light()`.** An early `return`
  fails compilation. Use a flag computed mid-function and applied at the final
  write (e.g. `COLOR = vec4(offscreen ? vec3(0.0) : col, 1.0);`). `return` is
  fine inside your own helper functions.
- **Array initializers use the constructor form:** `float m[16] = float[16](…);`
  — brace `{…}` init is not reliable.
- **`hint_depth_texture` and `hint_normal_roughness_texture` only exist in
  `spatial` shaders, not `canvas_item`.** A depth/normal post-process (outline,
  SSAO, SSR, DoF) must be a **fullscreen-quad spatial shader**: a `QuadMesh`
  (size 2) on a `MeshInstance3D` child of the camera, `render_mode unshaded,
  cull_disabled, depth_draw_never, depth_test_disabled`, vertex
  `POSITION = vec4(VERTEX.xy, 1.0, 1.0)`, write `ALPHA` so it draws in the
  transparent pass (screen copy then holds the full scene), set
  `extra_cull_margin` large so it isn't frustum-culled. Linearize depth with
  `INV_PROJECTION_MATRIX`. Reverse-Z: sky/cleared depth is **0** (mask geometry
  with `step(eps, depth)`).
- **Pure screen-space effects (CRT, pixelate, posterize, dither)** are
  `canvas_item` shaders on a screen-covering `ColorRect` (mouse_filter ignore)
  on a high `CanvasLayer`, reading `hint_screen_texture`. Stack independent
  passes by `CanvasLayer.layer` order; each reads the composited result below it.
- **A `ColorRect` whose shader fails to compile renders solid white.** A sudden
  white screen almost always means a shader compile error — check the Output log.
- PS1 vertex snapping: snap projected NDC.xy to a grid in `vertex()`, blend with
  a `snap_strength` to damp swimming. **Don't snap low-poly meshes like a
  2-triangle ground plane** — the whole plane swims; tessellate or exclude it.
- Affine (PS1) UV warp: pass `UV * clip.w` and `clip.w` as varyings, then
  `uv = v_uv_w / v_w` in `fragment()` cancels perspective correction.

### Hand-editing `.tscn`
- `load_steps` must equal **(ext_resource count) + (sub_resource count) + 1**.
  Recount after adding/removing resources.
- Before committing, verify every `ExtResource("id")` / `SubResource("id")`
  reference has a matching definition (a quick `grep`/`diff` of referenced vs
  defined ids catches typos that would corrupt the scene).
- Node groups: `[node name="X" type="…" parent="." groups=["pickup"]]`.
  Metadata: `metadata/item_id = "boots"`. Instance a scene:
  `[node name="X" parent="." instance=ExtResource("id")]`.
- `StandardMaterial3D` reads PBR maps natively (`albedo_texture`,
  `normal_enabled`+`normal_texture`, `ao_enabled`+`ao_texture`,
  `heightmap_enabled`+`heightmap_texture`, `uv1_scale` for tiling). Use it for
  modern PBR; use a `ShaderMaterial` only when you need custom vertex/fragment.

### C# / the assembly
- **The C# assembly is all-or-nothing:** one compile error takes down *every*
  C# script. A Godot error like *"autoload script … is not compiling"* usually
  means the whole assembly failed to build (often an unrestored NuGet package),
  not a problem with that one file.
- A committed `nuget.config` (with nuget.org) is required so `dotnet build`
  restores packages on any machine — don't rely on the user's local config.
- C# autoload: register in `project.godot` `[autoload]` as
  `Name="*res://scripts/Name.cs"`; it's a global in GDScript, called as
  `Name.call("Method")`. Give it **Variant-friendly wrapper methods** since
  GDScript can't see C#-only types.
- Async events: `await ToSignal(GetTree().CreateTimer(t),
  SceneTreeTimer.SignalName.Timeout)`; guard loops with `IsInsideTree()`.
- SQLite via `Microsoft.Data.Sqlite` (bundles the native lib, cross-platform);
  put the DB under `user://` (`ProjectSettings.GlobalizePath`).

### Environment & tooling (fresh containers)
- **A fresh session container may have NO `dotnet` or Godot binary** despite the
  toolchain table above — those are installed by the setup scripts, which need
  network. Don't assume `dotnet`/`godot-mono` are on PATH; check first.
- **Network egress is allow-listed.** `api.nuget.org` is reachable;
  `builds.dotnet.microsoft.com` / `dot.net` were **blocked**. `apt-get install
  dotnet-sdk-8.0` worked (after `apt-get update`) when the direct installer
  didn't.
- Per the working agreement, **don't self-compile/run unless asked.** When you do
  need to verify a C# change locally, `dotnet build` is enough (no engine needed).
- No image libraries (PIL/numpy/ImageMagick) are present. PNGs can be generated
  with a small pure-Python `zlib` encoder if needed.

### Assets from the user
- **Chat-attached files (images, etc.) are NOT written to the filesystem** — you
  can see them but can't read their bytes. To use them: wire materials/scenes
  against fixed paths, commit **neutral placeholders** at those paths so the
  scene still loads, and have the user overwrite them with the real files.
- Texture import settings matter: normal maps → **Normal Map** mode; AO / height
  / roughness → **Non-Color**; albedo → sRGB. Godot uses **OpenGL (+Y) normals**
  (Blender's default bake).

### Terrain streaming & chunk meshes (`terrain/TerrainStreamer.gd`)
- **`load_radius` is per-axis.** The loaded set is `(2*load_radius+1)^2` chunks,
  so radius 6 = **169** chunks, not ~36. With the scene's fog hiding the far
  edge, radius 4 (81) is plenty. Stream nearest-first and cap loads in flight.
- **Do NOT create/rebuild meshes or collision shapes at runtime while the world
  is rendering.** Rebuilding an `ArrayMesh` (`add_surface_from_arrays`) or baking
  `create_trimesh_shape()` per chunk as new chunks stream in **crashed the engine
  hard** on the user's RTX 3060 / Vulkan (Forward+) — instantly when flying into
  unvisited terrain. It crashes on the **main thread** *and* on a
  `WorkerThreadPool` thread (creating RenderingServer/PhysicsServer resources off
  the main thread is unsafe here). Treat runtime mesh/shape creation as off-limits
  for streaming; do that work **offline / at import** instead.
- **The skirt-normal "grid of seams" fix is baked into the GLBs, not done at
  runtime.** Chunks have a 25 m vertical skirt whose top ring shares the surface's
  outer verts, so the exporter averages skirt + top normals and darkens every
  chunk edge into a grid. `tools/bake_chunk_normals.py` recomputes each chunk's
  `NORMAL` attribute in-place in the `.glb` (excluding near-vertical skirt faces;
  surgical edit — only normal bytes change, size/JSON identical). `TerrainStreamer.
  fix_edge_normals` defaults **false** (the assets are already correct).
- **Re-run `tools/bake_chunk_normals.py` whenever the terrain chunks are
  re-exported from Blender** (`python3 tools/bake_chunk_normals.py terrain/chunks`).
  Re-export overwrites the baked normals, so the seam grid will come back until
  you re-bake. This generalises: any **derived/baked asset fix must be re-applied
  after the source asset is regenerated** — keep the baker committed and idempotent
  so it's a one-liner.
- glTF/Godot share the orientation that matters here (Y-up), so a normal's `.y`
  means the same thing in the raw `.glb` and in-engine — the offline baker and the
  old runtime fix compute identical results.

### Debugging discipline (learned the hard way this session)
- **Add comprehensive, granular instrumentation EARLY — before guessing at
  fixes.** This session burned several iterations on plausible-but-wrong fixes
  (throttling, then moving work to a worker thread) because the logging was too
  coarse to localise the fault. The crash was only pinned down once the debug
  output (a) **timed each suspect phase separately** (`fix=…ms coll=…ms`) and
  (b) **exposed live pipeline state** (`loaded/pending/building` counts). The
  counts revealed the worker tasks were dying (never draining); the per-phase
  timing + a user A/B of the toggle proved it was the mesh rebuild, not collision
  or the shader.
- **Instrument the specific operation you suspect, and make each suspect
  independently toggleable** (here: `fix_edge_normals`, `add_collision`,
  `enable_parallax`, `enable_triplanar` as exports). When you can't run the engine
  yourself, cheap toggles + a per-phase debug print let the user bisect a crash in
  one run instead of many round-trips. Reach for this on the *first* sign of a
  fault you can't see directly, not the third.

### Debugging VISUAL quality you can't see (you have no engine; the user verifies)
- **Define a quantitative metric for the user's actual complaint and measure base vs
  result — don't assume your change worked.** A texturing "fix" (feathering edits +
  a singleton de-speckle) *looked* reasonable but changed nothing the user could see;
  it shipped twice before measuring revealed why. Build a tiny pure-Python metric over
  the asset and print `base -> result` so "did this do anything?" is answered with a
  number, not a hope.
- **Match the metric's SCALE to the complaint, and probe several scales.** The map was
  already 0.98-coherent at single-texel scale (so de-speckle was a no-op), yet looked
  like a hodgepodge because the mess was REGIONAL — ~40–90 m patches. The fix only became
  obvious once the metric was "distinct layers per ~94 m window" (2.05 → 1.5), not
  per-texel agreement. If a metric says "already fine" but the user says "broken," you're
  measuring at the wrong scale.
- **Sweep parameters offline against that metric before committing.** Isolate the
  expensive sub-step (here: run `biomify()` alone, not the whole water pipeline) so you
  can try several settings in one go, pick the knee of the curve (res=96 plateaued vs 64),
  and ship calibrated defaults instead of a guess.
- **On unverifiable visual work, ship tunable knobs and tell the user which way to turn
  them.** Expose the dials as flags/exports (`--biome-res/-smooth/-warp`, scatter density)
  and state the direction for "too much / too little," so a miscalibration is a one-line
  retune by the user, not another full round-trip.
- **A plausible fix that the user says "looks unchanged" usually means the DIAGNOSIS was
  wrong, not the dose.** Go measure the real fault before re-implementing harder.

### Hand-editing `.tscn`: automate the bookkeeping checks
- After writing/editing scenes, **script the invariants instead of eyeballing them**: a
  3-line loop that recomputes `load_steps == ext + sub + 1` per file caught 6 wrong counts
  in one pass; another that diffs referenced vs defined `ExtResource/SubResource` ids
  catches typos that would corrupt the scene. Cheap to run, and you can't open the editor
  to find these the easy way.

### Terrain texturing: the 32-layer control map (NOT the old 4-channel splatmap)
- The terrain is no longer painted by `terrain_splatmap.png` (R=grass/G=rock/B=snow/
  A=sand). That is superseded by a **32-layer control map**: `terrain/
  terrain_control_map.exr` (2048², 16-bit-equivalent FLOAT) packs **per texel** a
  base layer | overlay layer | blend, 5+5+5 bits: `V=round(R*65535)`,
  `base=V&31`, `overlay=(V>>5)&31`, `blend=((V>>10)&31)/31*0.5`. `shaders/
  terrain_splat.gdshader` samples it (NEAREST, no sRGB/mipmaps) and
  `TerrainStreamer.gd` builds the per-layer `Texture2DArray`s at runtime.
- Each layer has a **`group`** in `terrain/control_map_layers.json`
  (grass/rock/snow/sand/forest/gravel/wet/special). Select terrain "of a type" by
  group, not by channel. Grass = indices 5–9; pebble = `pebble_field` (21).
- **Orientation: the control map and the water tool use OPPOSITE `v` conventions — this
  cost two sessions.** The TERRAIN samples the control map at the **chunk mesh UVs**,
  which run `u=(world_x+3000)/6000` (east+), **`v=(world_z+3000)/6000`** — so the
  control-map texture **row 0 = NORTH (−Z)**. *Verify this empirically from a chunk GLB's
  `TEXCOORD_0`, never from a comment:* `Chunk_00_00` @ z=+2903 → v≈1, `Chunk_30_30` @
  z=−2903 → v≈0. The water tool's own heightfield/mask grid instead uses
  `v=(3000−world_z)/6000` (**row 0 = south, +Z**); that's fine *internally* because it
  both writes and reads its own masks the same way. **But when you PAINT the control map
  (pebble shores, etc.) you MUST use the chunk-UV convention (row 0 = north), or the paint
  lands mirrored north↔south and lines up with nothing** — `paint_control_map` does this;
  the water masks deliberately do NOT (they're a separate, self-consistent texture).
  Chunk index: `j=round(x/step)+center`, `i=round(−z/step)+center` (`step≈193.55`,
  `center=15`, world 6000²).
- **General trap — a self-consistent subsystem hides coordinate bugs.** The water masks
  rendered perfectly all along (writer and reader share a frame), which made the lake
  geometry *look* correct and pointed suspicion at logic, not coordinates. The flip only
  surfaced at the **cross-system handoff** (water tool → control map, sampled by the
  terrain). When two subsystems exchange a grid/texture, test alignment in the
  **CONSUMER's frame** (here: decode the painted control map at chunk-UV `v`, confirm
  pebble rings the lakes), not the producer's.
- Don't hardcode a **layer index** (e.g. pebble=21) in a generator; **resolve it by name
  from `control_map_layers.json`** (`build_water_bodies.resolve_pebble_layer`). The
  manifest gets re-uploaded/re-numbered, and a stale constant silently paints the wrong
  layer.
- A layer's textures resolve **per-layer dir FIRST**
  (`terrain/arrays/layers/<NN_name>/{albedo,normal,height,ao,rough}.png`), then fall back
  to `arrays/sets/<texture_set>/`. So the manifest's `is_placeholder`/`texture_set` can be
  **stale**: if the per-layer dir has real PNGs (e.g. `21_pebble_field/` does), that is
  what renders regardless of the flag — check the dir on disk, not the JSON.

### Editing the control-map EXR in pure Python (`tools/exr_control_map.py`)
- The env has **no numpy / OpenEXR / PIL**, and the control map is a **ZIP
  scanline EXR** (3× FLOAT B,G,R; only R carries data). `tools/exr_control_map.py`
  reads/patches/writes it by hand: per 16-scanline block, `zlib` inflate then undo
  EXR's **predictor (delta) + de-interleave**; on write, re-interleave + delta then
  deflate, and rebuild the line-offset table. Verbatim-copy untouched blocks.
- **Validate any EXR write three ways** (you can't open Godot here): no-edit
  round-trip is byte-identical via your own reader; edits persist with neighbours
  unchanged; and decoded `base = V&31` lands cleanly in **0..31** matching the layer
  manifest (a wrong predictor/interleave yields garbage, so this is a strong check).
- **Edits to the control map must FEATHER, never stamp pure base.** The base map (from
  Blender) blends ~60% of texels (`overlay`/`blend` non-zero); writing `overlay=0,blend=0`
  (pure base) over a region gives hard, square, blend-free patches (the bug that made the
  pebble/rock paint look blocky). `build_water_bodies.py` now paints at **full 2048
  resolution** (not coarse 512 cells) and feathers: each region is a 512 strength field
  (box-blurred), bilinearly upsampled; per texel `_feather_pack(s,target,orig)` writes
  `base=target,overlay=orig` for the strong interior and swaps to `base=orig,overlay=target`
  past the 50/50 seam — a continuous transition the shader's height-blend reads as smooth.
  Bulk-edit the EXR via `ControlMapEXR.read_all_packed()/write_all_packed()` (per-texel
  `get/set_packed` over 4M texels is far too slow). Rock-loosening is the same feather keyed
  on terrain slope; a conservative singleton de-speckle removes lone outliers.
- **The base map is a HODGEPODGE — feathering edits is NOT enough; you must `--biomify`.**
  The base map is already coherent at single-texel scale (0.98 neighbour agreement), so a
  singleton de-speckle changes nothing visible. The mess the user sees is REGIONAL: ~40–90 m
  patches of different grass variants (lush/dry/dead) and rock variants (granite/sandstone/
  slate) and sprinkled marker layers, alternating randomly. `biomify` fixes it: majority-vote
  the layer ids down to a coarse grid (`--biome-res`, ~96 = 62 m cells), MODE-SMOOTH that grid
  (`--biome-smooth`, default 3) so each region settles on its dominant layer (scattered odd
  layers get out-voted and vanish; variants merge into patches), then upsample back with
  noise-WARPED, feathered boundaries (`--biome-warp`) so seams are organic not blocky. Measure
  success by **regional patch diversity** (distinct layers per ~94 m window: base 2.05 →
  ~1.5), NOT single-texel coherence. `--biomify` runs FIRST, then rock-loosen + pebble on the
  cleaned map. `{"sand"}` is protected so thin beaches survive the smoothing.
- The **EXR is the source the streamer loads** (`Image.load()` reads the raw file at
  full precision). The `terrain_control_map.png` twin is a 16-bit grayscale export;
  **don't rely on a 16-bit PNG round-tripping through Godot's importer** (it can
  truncate to 8-bit and zero the low byte — that's why the project uses EXR). When
  you edit the control map, edit the EXR and note the PNG twin goes stale.
- **The pebble paint only ADDS (sets texels to pebble); it never reverts.** So re-running
  it on an already-painted EXR *accumulates* stale shores from the old logic. Always
  **restore the pre-paint EXR from git first** (`git show <commit-before-paint>:terrain/
  terrain_control_map.exr`), then re-paint — `build_water_bodies.py --paint-control-map`
  expects an unpainted base. (Caveat: this restore discards any *manual* EXR edits made
  after that commit; if the artist hand-painted the control map, reconcile first.)
- **`get_pixel()` throws on a compressed `Image`.** A mask/texture loaded via
  `tex.get_image()` comes back VRAM/lossless-compressed; call `img.decompress()` once
  before any `get_pixel()` (WaterMap does this for the lake masks — otherwise it spams
  "Can't get_pixel() on compressed image" once per query).
- **GDScript `:=` can't infer a type from a Dictionary subscript** (it's `Variant`):
  `var u := dict["k"] - x` errors. Annotate explicitly (`var u: float = …`) or wrap
  (`float(dict["k"])`).

### Streamed world ⇒ do global calculations OFFLINE from the chunk GLBs
- Because the terrain streams, **no runtime moment holds the whole heightfield.**
  Any world-scale computation (water basins, river routing, biome passes) must run
  **offline** over `terrain/chunks/*.glb`. Reuse the GLB parser in
  `tools/bake_chunk_normals.py` (`parse_glb` / `accessor_view` / `read_vec3`); POSITION
  is tightly-packed VEC3 float (bulk-read with `array('f')`). **Max-pool** surface
  verts into a coarse grid — that drops the 25 m skirts (they hang below the
  surface). Per-chunk world offset comes from the manifest `pos`; add it to local
  verts (xz are recentred ±97 m, y is absolute).
- Hydrology that worked here (`tools/build_water_bodies.py`): **Priority-Flood**
  (Barnes 2014) for depression-fill + spill levels (outlets = map edge + sea-level
  cells); then **D8 flow + accumulation** on the filled surface for rivers (use the
  flood's settle order to break flat ties toward the pour point). Lakes = connected
  standing-water components; rivers = accumulation over a threshold, traced to
  polylines.

### Water system & queryable world properties
- **Ocean** = one translucent plane at `y=sea_level` that follows the player
  (snapped to its vertex grid so world-space waves don't shimmer). Land is opaque
  and above sea level, so it occludes the plane → **exact coastlines for free**, no
  per-fragment work.
- **Lakes/rivers can't use one flat global plane** (they sit at different levels and
  follow terrain). Lakes = a bbox `PlaneMesh` at the lake level, **clipped to the
  real shoreline** by sampling a small per-lake outline mask *by world position* in
  the shader (`discard` off-shore). **Dilate the lake mask a couple of cells past
  the waterline** so the flat plane tucks under the rising shore and reads flush
  (same reason the sea looks flush). Rivers = thin ribbon `ArrayMesh`es along baked
  centrelines. Build these **once at startup** (bounded) — never per-frame.
- Expose world facts other systems need as a **GDScript autoload "map" singleton**
  (`terrain/WaterMap.gd` → `/root/WaterMap`): `water_level_at(x,z)`,
  `is_submerged(pos)`, `in_lake(x,z)`. **Lazy-load on first query** so unrelated
  scenes (title/menu) pay nothing. Other systems fetch it with
  `get_node_or_null("/root/WaterMap")` and degrade gracefully if absent.
- **Texturing can double as gameplay logic.** Grass only spawns on grass-group
  layers, so painting shore/river bands to a non-grass layer (pebble) in the control
  map *automatically* stops grass there — no extra exclusion code. Prefer making one
  source of truth (the control map) drive both look and behaviour.
- **Making a flat plane read as 3-D water (`shaders/water_body.gdshader`) — no physics
  needed.** Depth-fade + screen-texture refraction + shoreline foam are *volume* cues, but
  they don't stop it looking 2-D at grazing angles. What sells a 3-D surface side-on is a
  **rippled, REFLECTIVE** surface: multi-octave animated ripples with an **analytic
  per-fragment normal** (independent of the coarse plane tessellation), **Fresnel sky
  reflection** (rippled by that normal), and an **additive sun glint** (via `EMISSION`, so
  it survives regardless of scene lights). Reconstruct scene depth with
  `INV_PROJECTION_MATRIX` (reverse-Z: sky depth = 0, guard with `step`).
- **Rivers are the hard case and need their own path.** A river ribbon sits ~0.3 m above
  the terrain, so its measured water column is ≈0 → the depth logic washes it to flat wet
  rock. Detect a river (`flow_speed>0`) and give it a **fixed body depth** (stay opaque,
  keep colour), **higher-frequency ripples** (the ocean swell wavelength ~100 m is far
  wider than a channel, so scale freq up ~8×) scrolled **downstream**, and skip the depth
  foam. (A flat ribbon viewed *dead* edge-on is still flat; the real cure is carving the
  bed into the terrain export — a bigger offline job.)
- **Basin detection must be strict or water sits in non-basins / pokes out the side**
  (`build_water_bodies.py`): (a) **split connected water by spill level** (Priority-Flood
  gives one pit a single spill; an 8-connected blob can merge two pits at different levels,
  and a single flat plane at `max(spill)` then floats above the lower rim — connect only
  within `--level-tol`, take the level as `min(spill)`); (b) require real **`--min-depth`**
  (a 0.5 m film over a noisy max-pooled cell isn't a lake); (c) a **containment** gate
  (reject if too much of the rim is below the level — it would drain).
- **The flush shore tuck-under must be terrain-AWARE.** Running the lake plane a couple
  cells under the rising shore (so it reads flush, like the sea under the coast) is good —
  but a plain all-direction dilate crosses a thin ridge/lip and the flat plane pokes out
  the **lower** ground beyond. Keep the flush (don't cap how far *above* the level you tuck)
  but add ONE check: only step into a cell while `height >= level − shore_eps`; the moment
  terrain drops back below the water level (the lip's far side) **stop**. Grow the pebble
  shore from this rendered footprint *outward* so the band lands on dry land (visible), not
  under the water plane.

### Dense scatter without runtime mesh churn (`terrain/GrassScatterer.gd`)
- For thousands of instances (grass), use a **`MultiMesh` per chunk** and **pool the
  `MultiMeshInstance3D` nodes**, refilling their buffers as the player moves —
  reusing resources, not creating them. This honours the "no per-chunk runtime
  ArrayMesh/shape creation while streaming" rule (a `MultiMesh` buffer refill is far
  lighter than building meshes, and pooling bounds even that). Budget per frame and
  scatter nearest-first, exactly like `TerrainStreamer`.
- Grass mesh LODs (baked on import) are applied by the MultiMesh automatically.
  Anchor wind at the blade base (sway weight from `VERTEX.y`); for world-coherent
  wind across randomly-yawed instances, rotate the world wind vector into object
  space with `wind * mat3(MODEL_MATRIX)` (= `transpose·wind`, the inverse for a
  rotation) instead of a per-vertex `inverse()`.

### Chunky scattered objects (`terrain/ObjectScatterer.gd` + `ScatterKind.gd`)
- Sparse objects (rocks, boulders, trees, shrubs, logs, reeds, …) that each want **real
  geometry AND discrete LODs** (a tree → billboard far away) can't ride a `MultiMesh` (it
  can't swap LOD nodes). Use **pooled PackedScene instances** instead: same streaming
  discipline as `GrassScatterer` (per-chunk, nearest-first, time-budgeted, recycle past
  `keep_radius`, deterministic per-chunk+kind RNG), but pooled PER KIND. **No runtime mesh/
  shape creation** — instancing a scene reuses shared mesh resources; safe like the grass.
- Kinds are **data** (`ScatterKind` resources set in `scenes/Objects.tscn`), routed to a
  biome by control-map **group** (boulders→rock, small rocks→gravel/pebble, snowy→snow,
  trees→grass+forest, reeds→`placement="water_edge"` via WaterMap, driftwood→sand). Swap a
  kind's `scene` for your model and keep its `visibility_range` LOD wiring (placeholders in
  `scenes/scatter/*.tscn`, pattern from `scenes/lod_tree.tscn`: near mesh → mid → billboard
  quad, `billboard_mode=1`). Keep `kinds` an **untyped** `Array` so the hand-authored .tscn
  list loads cleanly.

### Derived assets generalised (extends the bake_chunk_normals rule)
- This project has several **committed, derived assets**: baked chunk normals,
  `terrain/water_bodies.json` + `terrain/water_masks/*.png`, and the painted
  control-map EXR. Each has a committed, **idempotent** generator under `tools/`.
  **Re-run the generator whenever its source is regenerated** (re-export terrain →
  re-run `bake_chunk_normals.py` *and* `build_water_bodies.py`); a source re-export
  silently reverts the derived edit. Keep generators idempotent and re-runnable in
  one line, and `git` is the backup before any in-place asset rewrite.
- Pure-Python PNG I/O is fine here (no PIL): 8-bit grayscale masks via a tiny
  `zlib`+CRC writer; decode by undoing the per-row filter. Keep mask textures small
  and binary (precision doesn't matter — a 0.5 threshold is robust to sRGB/filter).

