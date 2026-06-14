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
