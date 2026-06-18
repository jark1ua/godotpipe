@tool
extends Node3D
## Streams Blender-exported terrain chunks around a player.
## Reads terrain_manifest.json and loads/frees Chunk_II_JJ.glb by distance.
##
## Setup:
##   1. Copy terrain_manifest.json and the terrain_chunks/ folder into res://.
##   2. Add a Node3D to your level, attach this script.
##   3. Set "Player Path" to your player/camera node.
##   4. Tune Load Radius / Keep Radius (in chunks; 1 chunk = step_m metres).
##
## Editor preview: this is a @tool script. To see the terrain in the editor
## viewport (to place props, tweak lighting, etc.) press the "Load Editor
## Preview" button in the Inspector — it loads a small block of chunks around
## Preview Focus Chunk. "Clear Editor Preview" removes them. Preview chunks are
## NOT saved into the scene (no owner), so they cost nothing on disk and never
## ship in the running game; at runtime the distance streamer takes over.
##
## Coordinate mapping (baked into the manifest):
##   Blender +X (east)  -> Godot +X
##   Blender +Y (north) -> Godot -Z
##   Blender +Z (up)    -> Godot +Y   (1 unit = 1 metre, no scaling)
##   chunk j -> +X, chunk i -> -Z ;  index = round(p / step_m) + center_index

@export_file("*.json") var manifest_path: String = "res://terrain/terrain_manifest.json"
@export var player_path: NodePath
## Folder (in res://) that holds the .glb files.
@export_dir var chunks_dir: String = "res://terrain/chunks"
## Chunks loaded around the player (Chebyshev / square radius).
@export var load_radius: int = 6
## Chunks kept before freeing — keep > load_radius for hysteresis (no load/free thrash).
@export var keep_radius: int = 8
## Build a trimesh StaticBody under each chunk on load (runtime collision).
@export var add_collision: bool = true
## Optional: a ShaderMaterial (e.g. terrain_splat.gdshader) applied to every chunk mesh.
## Leave null to keep each .glb's own imported material.
@export var terrain_material: Material
## Seconds between streaming updates.
@export var update_interval: float = 0.25

@export_group("Editor Preview")
## Chunk (i, j) to centre the editor preview on. (15, 15) is the world origin.
@export var preview_focus_chunk: Vector2i = Vector2i(15, 15)
## Half-width (in chunks) of the editor preview block. 3 -> a 7x7 = 49-chunk patch.
@export var preview_radius: int = 3
## Click in the Inspector to load/refresh the editor-only preview.
@export_tool_button("Load Editor Preview") var _btn_load_preview: Callable = _load_editor_preview
## Click in the Inspector to remove the editor-only preview.
@export_tool_button("Clear Editor Preview") var _btn_clear_preview: Callable = _clear_editor_preview

var _step: float = 193.5483
var _center: int = 15
var _meta: Dictionary = {}     # "i_j" -> { pos: Vector3, path: String }
var _loaded: Dictionary = {}   # "i_j" -> Node3D
var _pending: Dictionary = {}  # "i_j" -> resource path
var _preview: Dictionary = {}  # "i_j" -> Node3D (editor-only, not saved)
var _player: Node3D = null
var _accum: float = 0.0
var _logged_first: bool = false
var _mesh_count: int = 0

func _ready() -> void:
	_load_manifest()
	# In the editor we don't stream; the preview buttons handle visibility.
	if Engine.is_editor_hint():
		return
	if not player_path.is_empty():
		_player = get_node_or_null(player_path) as Node3D
	# Fall back to the active camera so streaming still works if Player Path is
	# unset or fails to resolve (otherwise _process bails forever on a null player).
	if _player == null:
		_player = get_viewport().get_camera_3d()
		if _player != null:
			push_warning("TerrainStreamer: player_path unresolved; falling back to active Camera3D.")
	print("TerrainStreamer ready: %d chunks in manifest, player=%s" % [
		_meta.size(), _player.name if _player != null else "<none>"])
	# Synchronously load the chunk directly under the player so there is ground
	# (and collision) on the very first physics frame — no falling through.
	_ensure_chunk_under_player()

func _load_manifest() -> void:
	if not _meta.is_empty():
		return
	var f := FileAccess.open(manifest_path, FileAccess.READ)
	assert(f != null, "Terrain manifest not found: " + manifest_path)
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	_step = float(data["step_m"])
	_center = int(data["center_index"])
	for c in data["chunks"]:
		var key := "%d_%d" % [int(c["i"]), int(c["j"])]
		var p: Array = c["pos"]
		_meta[key] = {
			"pos": Vector3(float(p[0]), float(p[1]), float(p[2])),
			"path": chunks_dir.path_join(String(c["file"]).get_file()),
		}

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_accum += delta
	_poll_threaded()
	if _accum < update_interval or _player == null:
		return
	_accum = 0.0
	var pj := int(round(_player.global_position.x / _step)) + _center
	var pi := int(round(-_player.global_position.z / _step)) + _center
	if not _logged_first:
		_logged_first = true
		print("TerrainStreamer: player at %s -> chunk (i=%d, j=%d); requesting load radius %d" % [
			_player.global_position, pi, pj, load_radius])

	# request loads within load_radius
	for di in range(-load_radius, load_radius + 1):
		for dj in range(-load_radius, load_radius + 1):
			var key := "%d_%d" % [pi + di, pj + dj]
			if _meta.has(key) and not _loaded.has(key) and not _pending.has(key):
				ResourceLoader.load_threaded_request(_meta[key]["path"])
				_pending[key] = _meta[key]["path"]

	# free chunks beyond keep_radius
	for key in _loaded.keys():
		var parts := String(key).split("_")
		var ci := int(parts[0])
		var cj := int(parts[1])
		if max(abs(ci - pi), abs(cj - pj)) > keep_radius:
			(_loaded[key] as Node).queue_free()
			_loaded.erase(key)

func _poll_threaded() -> void:
	for key in _pending.keys():
		var path: String = _pending[key]
		var st := ResourceLoader.load_threaded_get_status(path)
		if st == ResourceLoader.THREAD_LOAD_LOADED:
			_pending.erase(key)
			_spawn(key, ResourceLoader.load_threaded_get(path))
		elif st == ResourceLoader.THREAD_LOAD_FAILED or st == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			_pending.erase(key)
			push_warning("Terrain chunk failed to load: " + path)

# Blocking load + spawn of the single chunk the player stands on, used at spawn
# time so collision exists before gravity can pull the player through the world.
func _ensure_chunk_under_player() -> void:
	if _player == null:
		return
	var pj := int(round(_player.global_position.x / _step)) + _center
	var pi := int(round(-_player.global_position.z / _step)) + _center
	var key := "%d_%d" % [pi, pj]
	if _meta.has(key) and not _loaded.has(key):
		var packed := load(_meta[key]["path"]) as PackedScene
		if packed != null:
			_spawn(key, packed)

func _spawn(key: String, packed: PackedScene) -> void:
	if _loaded.has(key) or packed == null:
		return
	var inst := packed.instantiate() as Node3D
	inst.position = _meta[key]["pos"]
	add_child(inst)
	_loaded[key] = inst
	_mesh_count = 0
	_setup_meshes(inst, add_collision)
	if _loaded.size() == 1:
		print("TerrainStreamer: first chunk '%s' spawned at %s with %d MeshInstance3D(s)" % [
			key, inst.position, _mesh_count])

func _setup_meshes(node: Node, with_collision: bool) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			var mi := child as MeshInstance3D
			_mesh_count += 1
			if terrain_material != null:
				mi.material_override = terrain_material
			if with_collision and mi.mesh != null:
				var body := StaticBody3D.new()
				var cs := CollisionShape3D.new()
				cs.shape = mi.mesh.create_trimesh_shape()
				body.add_child(cs)
				mi.add_child(body)
		_setup_meshes(child, with_collision)

# ---- Editor-only preview (no streaming, no save) -----------------------------

func _load_editor_preview() -> void:
	if not Engine.is_editor_hint():
		return
	_clear_editor_preview()
	_load_manifest()
	var fi := preview_focus_chunk.x
	var fj := preview_focus_chunk.y
	for di in range(-preview_radius, preview_radius + 1):
		for dj in range(-preview_radius, preview_radius + 1):
			var key := "%d_%d" % [fi + di, fj + dj]
			if not _meta.has(key):
				continue
			var packed := load(_meta[key]["path"]) as PackedScene
			if packed == null:
				continue
			var inst := packed.instantiate() as Node3D
			inst.position = _meta[key]["pos"]
			add_child(inst)
			# No owner -> these nodes are not serialised into the .tscn.
			_setup_meshes(inst, false)
			_preview[key] = inst
	print("TerrainStreamer preview: %d chunks around %s" % [_preview.size(), preview_focus_chunk])

func _clear_editor_preview() -> void:
	for key in _preview.keys():
		var n: Node = _preview[key]
		if is_instance_valid(n):
			n.free()
	_preview.clear()
