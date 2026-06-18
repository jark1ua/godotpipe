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

var _step: float = 193.5483
var _center: int = 15
var _meta: Dictionary = {}     # "i_j" -> { pos: Vector3, path: String }
var _loaded: Dictionary = {}   # "i_j" -> Node3D
var _pending: Dictionary = {}  # "i_j" -> resource path
var _player: Node3D = null
var _accum: float = 0.0
var _logged_first: bool = false
var _mesh_count: int = 0

func _ready() -> void:
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

func _process(delta: float) -> void:
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

func _spawn(key: String, packed: PackedScene) -> void:
	if _loaded.has(key) or packed == null:
		return
	var inst := packed.instantiate() as Node3D
	inst.position = _meta[key]["pos"]
	add_child(inst)
	_loaded[key] = inst
	_mesh_count = 0
	_setup_meshes(inst)
	if _loaded.size() == 1:
		print("TerrainStreamer: first chunk '%s' spawned at %s with %d MeshInstance3D(s)" % [
			key, inst.position, _mesh_count])

func _setup_meshes(node: Node) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			var mi := child as MeshInstance3D
			_mesh_count += 1
			if terrain_material != null:
				mi.material_override = terrain_material
			if add_collision and mi.mesh != null:
				var body := StaticBody3D.new()
				var cs := CollisionShape3D.new()
				cs.shape = mi.mesh.create_trimesh_shape()
				body.add_child(cs)
				mi.add_child(body)
		_setup_meshes(child)
