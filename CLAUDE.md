# CLAUDE.md

Guidance for Claude when working in this repository. Read before making changes.

This is a Godot 4 **.NET** project that mixes **GDScript** and **C#**. It must be
opened with the Godot **.NET** editor (the standard build cannot load C#).

## Toolchain (already installed in this environment)

| Tool | Path / value | Notes |
|---|---|---|
| Godot .NET engine | `/home/user/tools/godot-mono/godot-mono` | `4.6.3.stable.mono` — **use this one** |
| Standard Godot | `/home/user/tools/godot/godot` | `4.6.3.stable`; not used by this project |
| .NET SDK | `dotnet` (8.x, on PATH) | builds C# → `.godot/mono/temp/bin/Debug/GodotPipe.dll` |
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
