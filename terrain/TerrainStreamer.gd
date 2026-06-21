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

@export_file("*.json") var manifest_path: String = "res://terrain_manifest.json"
@export var player_path: NodePath
## Folder (in res://) that holds the .glb files.
@export_dir var chunks_dir: String = "res://terrain_chunks_16k"
## Chunks loaded around the player (Chebyshev / square radius). The loaded area is
## (2*load_radius+1)^2 chunks, so 4 -> 9x9 = 81. With fog hiding the far edge there
## is little point loading more; raise it only if you can see the unloaded boundary.
@export var load_radius: int = 4
## Chunks kept before freeing — keep > load_radius for hysteresis (no load/free thrash).
@export var keep_radius: int = 5
## Build a trimesh StaticBody under each chunk on load (runtime collision).
@export var add_collision: bool = true
## Recompute each chunk's surface normals at load, excluding the near-vertical
## skirt faces that draw a dark grid along chunk seams. LEFT OFF by default: doing
## this at runtime rebuilds an ArrayMesh per chunk, which crashes some drivers when
## new chunks build during flight. Bake it into the GLBs instead with
## tools/bake_chunk_normals.py (then leave this off). Only turn on to A/B test.
@export var fix_edge_normals: bool = false
## Faces flatter than this |normal.y| are treated as skirt walls and excluded from
## edge-vertex normals. 0 = vertical wall, 1 = flat ground; ~0.15 keeps real cliffs
## while dropping the 25 m skirts.
@export var skirt_normal_y_max: float = 0.15
## Optional override: assign a ShaderMaterial to use it verbatim. Leave null and
## the streamer builds the control-map material at runtime from the settings below.
@export var terrain_material: Material
## Seconds between streaming updates.
@export var update_interval: float = 0.25
## Soft per-frame time budget (ms) for the heavy chunk build (instance + normal-fix
## mesh + collision bake), which runs on the main thread. We build ready chunks
## nearest-first until this is exceeded, but always at least one so loading makes
## progress. This caps the per-frame stall instead of building a whole burst at once.
@export var build_budget_ms: float = 3.0
## Hard cap on chunks built per frame, regardless of the time budget (safety net).
@export var max_builds_per_frame: int = 3
## Max chunk loads in flight at once. Bounds the request backlog when you cross
## chunks quickly, so pending loads (and the threads behind them) can't pile up
## without limit. Loads are issued nearest-first.
@export var max_in_flight: int = 16
## Print per-update / per-build streaming stats (player chunk, in-flight, and the
## time split between the normal-fix and the collision bake). Use to find hitches.
@export var debug_streaming: bool = false
@export var debug_skip_terrain_material: bool = false

@export_group("Terrain Shader (for bisecting GPU cost)")
## Enable parallax occlusion mapping on the runtime-built terrain material. Turn off
## to test whether the POM shader is responsible for a GPU stall / device-lost crash.
@export var enable_parallax: bool = true
## Enable triplanar mapping on steep faces. Turn off to lighten the fragment shader.
@export var enable_triplanar: bool = true

@export_group("Terrain Material (control map + arrays)")
## 32-layer manifest (names, texture_set, tile_meters, triplanar) baked in Blender.
@export_file("*.json") var layer_manifest_path: String = "res://terrain/control_map_layers.json"
## 16-bit single-channel control map: base(5) | overlay(5) | blend(5) per texel.
## Default is the biome-baked map for the 16 km world (tools/bake_biome_control_map.py).
@export_file var control_map_path: String = "res://terrain/terrain_control_map_16k.png"
## Folder of base PBR sets: <sets_dir>/<set>/{albedo,normal,height,ao,rough}.png.
## Used as the fallback for any layer that has no dedicated textures yet.
@export_dir var sets_dir: String = "res://terrain/arrays/sets"
## Folder of per-layer PBR sets: <layers_dir>/<NN_name>/{albedo,normal,height,ao,rough}.png
## (NN_name = zero-padded index + manifest name, e.g. "00_rock_cold_granite").
## Drop dedicated maps here to override the base set for that one layer; any map
## you leave out falls back to the layer's base set. See arrays/layers/README.md.
@export_dir var layers_dir: String = "res://terrain/arrays/layers"
## Fallback tile size (metres) for any layer missing tile_meters in the manifest.
@export var default_tile_m: float = 12.0

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
var _world_size_m: float = 16000.0    # full world span (m); read from the manifest
var _meta: Dictionary = {}     # "i_j" -> { pos: Vector3, path: String }
var _loaded: Dictionary = {}   # "i_j" -> Node3D
var _pending: Dictionary = {}  # "i_j" -> resource path
var _preview: Dictionary = {}  # "i_j" -> Node3D (editor-only, not saved)
var _player: Node3D = null
var _accum: float = 0.0
var _logged_first: bool = false
var _material: ShaderMaterial = null   # built once, shared by every chunk
var _fixed_cache: Dictionary = {}      # chunk key#idx -> fixed ArrayMesh (or null)
var _shape_cache: Dictionary = {}      # chunk key#idx -> trimesh Shape3D (shared)
var _pi: int = 0                       # player's current chunk (i, j); kept for
var _pj: int = 0                       # nearest-first ordering of loads/spawns
var _fix_us: int = 0                   # per-frame normal-fix / collision time (usec),
var _coll_us: int = 0                  # accumulated for the debug print

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
	_world_size_m = float(data.get("world_size_m", _world_size_m))
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
	if _player == null:
		return
	_pj = int(round(_player.global_position.x / _step)) + _center
	_pi = int(round(-_player.global_position.z / _step)) + _center
	if not _logged_first:
		_logged_first = true
		print("TerrainStreamer: player at %s -> chunk (i=%d, j=%d); requesting load radius %d" % [
			_player.global_position, _pi, _pj, load_radius])

	# Build ready chunks (budgeted, nearest-first) and top up requests every frame so
	# the pipeline stays fed; the heavier free/debug pass runs on update_interval.
	_poll_threaded()
	_request_loads()
	_accum += delta
	if _accum < update_interval:
		return
	_accum = 0.0
	_free_distant_chunks()
	if debug_streaming:
		# fix/coll are summed over this update window (the heavy build cost per phase).
		print("TerrainStreamer: chunk (%d,%d) loaded=%d pending=%d | fix=%.1fms coll=%.1fms" % [
			_pi, _pj, _loaded.size(), _pending.size(), _fix_us / 1000.0, _coll_us / 1000.0])
	_fix_us = 0
	_coll_us = 0

# Request the nearest wanted-but-missing chunks in load_radius, capped by
# max_in_flight. Nearest-first keeps the most visible ground filling in even when
# we can't keep up; the in-flight cap stops the request backlog (and its loader
# threads) exploding when crossing chunks fast — the main cause of the fly stall.
func _request_loads() -> void:
	if _pending.size() >= max_in_flight:
		return
	var wanted: Array = []
	for di in range(-load_radius, load_radius + 1):
		for dj in range(-load_radius, load_radius + 1):
			var key := "%d_%d" % [_pi + di, _pj + dj]
			if _meta.has(key) and not _loaded.has(key) and not _pending.has(key):
				wanted.append([di * di + dj * dj, key])
	wanted.sort_custom(func(a, b): return a[0] < b[0])
	for entry in wanted:
		if _pending.size() >= max_in_flight:
			break
		var key: String = entry[1]
		ResourceLoader.load_threaded_request(_meta[key]["path"])
		_pending[key] = _meta[key]["path"]

func _free_distant_chunks() -> void:
	for key in _loaded.keys():
		var parts := String(key).split("_")
		var ci := int(parts[0])
		var cj := int(parts[1])
		if max(abs(ci - _pi), abs(cj - _pj)) > keep_radius:
			(_loaded[key] as Node).queue_free()
			_loaded.erase(key)

# Instance and fully build ready chunks on the main thread, nearest-first, until the
# per-frame time budget is spent (always >=1 so loading progresses). The build
# (normal-fix mesh + trimesh collision) is the heavy part; budgeting it by time
# keeps a burst of finished loads from spiking the frame. Resource creation is kept
# on the main thread on purpose — doing it on a worker thread crashes the process.
# load_threaded_get is only called for chunks we build now; the rest stay LOADED.
func _poll_threaded() -> void:
	var ready: Array = []
	for key in _pending.keys():
		var st := ResourceLoader.load_threaded_get_status(_pending[key])
		if st == ResourceLoader.THREAD_LOAD_LOADED:
			var parts := String(key).split("_")
			var di := int(parts[0]) - _pi
			var dj := int(parts[1]) - _pj
			ready.append([di * di + dj * dj, key])
		elif st == ResourceLoader.THREAD_LOAD_FAILED or st == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			push_warning("Terrain chunk failed to load: " + String(_pending[key]))
			_pending.erase(key)
	if ready.is_empty():
		return
	ready.sort_custom(func(a, b): return a[0] < b[0])
	var budget_us := int(build_budget_ms * 1000.0)
	var t_start := Time.get_ticks_usec()
	var built := 0
	for entry in ready:
		if built >= max_builds_per_frame:
			break
		if built > 0 and Time.get_ticks_usec() - t_start >= budget_us:
			break  # spent the frame's build budget; the rest wait (still LOADED)
		var key: String = entry[1]
		var path: String = _pending[key]
		_pending.erase(key)
		_spawn(key, ResourceLoader.load_threaded_get(path))
		built += 1

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

# Instance a chunk, apply the shared material, build its normal-fixed mesh and bake
# its trimesh collision. All on the main thread (resource creation off-thread is
# unsafe). The per-frame work is bounded by _poll_threaded's time budget.
func _spawn(key: String, packed: PackedScene) -> void:
	if _loaded.has(key) or packed == null:
		return
	var inst := packed.instantiate() as Node3D
	inst.position = _meta[key]["pos"]
	add_child(inst)
	_loaded[key] = inst
	var meshes: Array = []
	_collect_meshes(inst, meshes)
	if _loaded.size() == 1:
		print("TerrainStreamer: first chunk '%s' spawned at %s with %d MeshInstance3D(s)" % [
			key, inst.position, meshes.size()])
	_build_meshes_now(meshes, key)

# Gather every MeshInstance3D under a freshly-instanced chunk and apply the shared
# terrain material.
func _collect_meshes(node: Node, out: Array) -> void:
	var mat := _get_material()
	for child in node.get_children():
		if child is MeshInstance3D:
			var mi := child as MeshInstance3D
			if mat != null and not debug_skip_terrain_material:
				mi.material_override = mat
			out.append(mi)
		_collect_meshes(child, out)

# Build the normal-fixed mesh and (optionally) the trimesh collision for each mesh,
# timing the two phases separately so the debug print shows where the cost is.
#
# Collision is always baked from the ORIGINAL mesh (normals don't affect it), so the
# rebuilt mesh never enters the physics path. Both the fixed display mesh and the
# trimesh shape are cached per chunk and reused on reload, so each unique chunk is
# built at most once ever — no per-reload ArrayMesh/shape churn as you fly back and
# forth. That churn (and baking collision off the rebuilt mesh) was the cause of the
# fix_edge_normals crash.
func _build_meshes_now(meshes: Array, cache_key: String) -> void:
	for idx in range(meshes.size()):
		var mi := meshes[idx] as MeshInstance3D
		var src := mi.mesh as ArrayMesh
		if src == null:
			continue
		var ck := "%s#%d" % [cache_key, idx]
		if add_collision:
			var t1 := Time.get_ticks_usec()
			_attach_collision(mi, _get_shape(src, ck))
			_coll_us += Time.get_ticks_usec() - t1
		if fix_edge_normals:
			var t0 := Time.get_ticks_usec()
			var fixed := _get_fixed_mesh(src, ck)
			if fixed != null:
				mi.mesh = fixed
			_fix_us += Time.get_ticks_usec() - t0

# Return the skirt-free mesh for a source mesh, building it once and caching by a
# stable per-chunk key (null = "couldn't fix / no change", also cached so we don't
# retry). Keyed by chunk (not the mesh RID) because RIDs can be reused after free.
func _get_fixed_mesh(src: ArrayMesh, ck: String) -> ArrayMesh:
	if src == null:
		return null
	if _fixed_cache.has(ck):
		return _fixed_cache[ck]
	var surfaces := _extract_surfaces(src)
	var result: ArrayMesh = null
	if not surfaces.is_empty():
		var built := _build_fixed_mesh(surfaces, true)
		if built["changed"] and (built["mesh"] as ArrayMesh).get_surface_count() > 0:
			result = built["mesh"]
	_fixed_cache[ck] = result
	return result

# Trimesh shape for a source mesh, built once and shared across reloads of the same
# chunk (collision geometry is identical and a static shape is safe to share).
func _get_shape(src: ArrayMesh, ck: String) -> Shape3D:
	if _shape_cache.has(ck):
		return _shape_cache[ck]
	var shape := src.create_trimesh_shape()
	_shape_cache[ck] = shape
	return shape

func _attach_collision(mi: MeshInstance3D, shape: Shape3D) -> void:
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	mi.add_child(body)

# ---- Edge-normal repair (kills the dark grid along chunk seams) ---------------
#
# Each chunk carries a 25 m vertical skirt around its rim to hide cracks. The top
# ring of skirt verts is shared with the surface's outer ring, so the exporter's
# normal averaging blends the (near-flat) surface normal with the (horizontal)
# skirt-wall normal — tilting the whole edge row outward and shading it darker.
# Across all chunks that paints a grid of shadow lines on the seams.
#
# Fix: build a copy of the mesh whose vertex normals come from the surface faces
# only, excluding the near-vertical skirt faces. Edge-top verts then take their
# normal from the flat top alone and match across chunks, so the grid disappears.
# The skirts stay (they still hide cracks); only the normals change.
#
# Pull the triangle surface arrays out of a source mesh (main thread; a cheap
# readback). Returns [] if the mesh has any non-triangle surface, so we never try
# to faithfully rebuild something we can't.
func _extract_surfaces(src: ArrayMesh) -> Array:
	var out: Array = []
	if src == null:
		return out
	for s in range(src.get_surface_count()):
		if src.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			return []
		out.append(src.surface_get_arrays(s))
	return out

# Build an ArrayMesh from extracted surface arrays, optionally recomputing normals
# to drop the skirt contamination. Pure data + resource creation, so it is safe to
# call from a worker thread. Returns { "mesh": ArrayMesh, "changed": bool }.
func _build_fixed_mesh(surfaces: Array, do_fix: bool) -> Dictionary:
	var out := ArrayMesh.new()
	var changed := false
	for arrays in surfaces:
		if do_fix and _recompute_surface_normals(arrays):
			changed = true
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return {"mesh": out, "changed": changed}

# Recompute ARRAY_NORMAL in-place from the triangle faces, skipping near-vertical
# (skirt) faces. Returns true if normals were written.
func _recompute_surface_normals(arrays: Array) -> bool:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if verts.is_empty():
		return false
	# Unused slots come back as null; coerce to empty packed arrays so the typed
	# locals below never see a null (non-indexed meshes have no ARRAY_INDEX).
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var n := verts.size()
	var accum := PackedVector3Array()
	accum.resize(n)  # PackedVector3Array initialises to zero vectors
	var tri := (indices.size() / 3) if indices.size() > 0 else (n / 3)
	for t in range(tri):
		var a: int
		var b: int
		var c: int
		if indices.size() > 0:
			a = indices[t * 3]; b = indices[t * 3 + 1]; c = indices[t * 3 + 2]
		else:
			a = t * 3; b = t * 3 + 1; c = t * 3 + 2
		var fn := (verts[b] - verts[a]).cross(verts[c] - verts[a])
		var l := fn.length()
		if l < 1e-12:
			continue
		fn /= l
		# Match the exporter's winding so accumulated normals point the right way.
		if not normals.is_empty() and (normals[a] + normals[b] + normals[c]).dot(fn) < 0.0:
			fn = -fn
		# Drop the vertical skirt walls so they can't tilt the edge-row normals.
		if absf(fn.y) < skirt_normal_y_max:
			continue
		accum[a] += fn
		accum[b] += fn
		accum[c] += fn
	if normals.is_empty():
		normals = PackedVector3Array()
		normals.resize(n)
	for i in range(n):
		# Skirt-only verts get no contribution; keep their original normal (hidden).
		if accum[i].length_squared() > 1e-12:
			normals[i] = accum[i].normalized()
	arrays[Mesh.ARRAY_NORMAL] = normals
	return true

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
			# Material + normal fix only (no collision in preview).
			var meshes: Array = []
			_collect_meshes(inst, meshes)
			if fix_edge_normals:
				for idx in range(meshes.size()):
					var mi := meshes[idx] as MeshInstance3D
					var fixed := _get_fixed_mesh(mi.mesh as ArrayMesh, "%s#%d" % [key, idx])
					if fixed != null:
						mi.mesh = fixed
			_preview[key] = inst
	print("TerrainStreamer preview: %d chunks around %s" % [_preview.size(), preview_focus_chunk])

func _clear_editor_preview() -> void:
	for key in _preview.keys():
		var n: Node = _preview[key]
		if is_instance_valid(n):
			n.free()
	_preview.clear()

# ---- Terrain material: control map + Texture2DArrays --------------------------

var _MAPS := ["albedo", "normal", "height", "ao", "rough"]
var _MAP_FALLBACK := {
	"albedo": Color(0.5, 0.5, 0.5),  # overridden per set below
	"normal": Color(0.5, 0.5, 1.0),  # flat tangent normal
	"height": Color(0.5, 0.5, 0.5),
	"ao": Color(1.0, 1.0, 1.0),
	"rough": Color(0.6, 0.6, 0.6),
}
var _SET_TINT := {
	"grass": Color(0.31, 0.47, 0.20),
	"rock": Color(0.44, 0.42, 0.39),
	"snow": Color(0.92, 0.94, 0.96),
	"sand": Color(0.79, 0.71, 0.51),
}

func _get_material() -> Material:
	if terrain_material != null:
		return terrain_material
	if _material == null:
		_material = _build_terrain_material()
	return _material

func _build_terrain_material() -> ShaderMaterial:
	var layers := _read_layers()
	var n := layers.size()
	# Load each base set's 5 maps once, then index per layer.
	var set_cache: Dictionary = {}
	var imgs := {"albedo": [], "normal": [], "height": [], "ao": [], "rough": []}
	var tiles := PackedFloat32Array(); tiles.resize(32)
	var tris := PackedFloat32Array(); tris.resize(32)
	for i in range(32):
		var li: Dictionary = layers[i] if i < n else {}
		var setname := String(li.get("texture_set", "grass"))
		var lname := String(li.get("name", "layer_%d" % i))
		var maps := _get_layer_images(i, lname, setname, set_cache)
		for m in _MAPS:
			imgs[m].append(maps[m])
		tiles[i] = float(li.get("tile_meters", default_tile_m))
		tris[i] = 1.0 if bool(li.get("triplanar", false)) else 0.0

	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/terrain_splat.gdshader")
	mat.set_shader_parameter("albedo_array", _make_array(imgs["albedo"]))
	mat.set_shader_parameter("normal_array", _make_array(imgs["normal"]))
	mat.set_shader_parameter("ao_array", _make_array(imgs["ao"]))
	mat.set_shader_parameter("rough_array", _make_array(imgs["rough"]))
	mat.set_shader_parameter("height_array", _make_array(imgs["height"]))
	var cm := _load_control_map_texture()
	if cm != null:
		mat.set_shader_parameter("control_map", cm)
	mat.set_shader_parameter("layer_tile_m", tiles)
	mat.set_shader_parameter("layer_triplanar", tris)
	mat.set_shader_parameter("world_size_m", _world_size_m)
	mat.set_shader_parameter("default_tile_m", default_tile_m)
	# Bisection toggles for GPU cost (see exports): drive the shader's own switches.
	mat.set_shader_parameter("enable_parallax", enable_parallax)
	mat.set_shader_parameter("enable_triplanar", enable_triplanar)
	print("TerrainStreamer: built control-map material for %d layers (%d base sets)." % [
		n, set_cache.size()])
	return mat

func _read_layers() -> Array:
	var f := FileAccess.open(layer_manifest_path, FileAccess.READ)
	if f == null:
		push_warning("Layer manifest not found: " + layer_manifest_path)
		return []
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	return data.get("layers", [])

# Per-layer textures override the base set, per map. Missing maps fall back to
# the layer's base set; missing sets fall back to a solid colour.
func _get_layer_images(idx: int, lname: String, setname: String, set_cache: Dictionary) -> Dictionary:
	var ldir := layers_dir.path_join("%02d_%s" % [idx, lname])
	var maps: Dictionary = {}
	var set_maps: Dictionary = {}
	for m in _MAPS:
		var p := ldir.path_join(m + ".png")
		if ResourceLoader.exists(p):
			maps[m] = _load_or_make(p, Color(0.5, 0.5, 0.5))
		else:
			if set_maps.is_empty():
				set_maps = _get_set_images(setname, set_cache)
			maps[m] = set_maps[m]
	return maps

func _get_set_images(setname: String, cache: Dictionary) -> Dictionary:
	if cache.has(setname):
		return cache[setname]
	var dir := sets_dir.path_join(setname)
	var maps: Dictionary = {}
	for m in _MAPS:
		var fallback = _SET_TINT.get(setname, Color(0.5, 0.5, 0.5)) if m == "albedo" else _MAP_FALLBACK[m]
		maps[m] = _load_or_make(dir.path_join(m + ".png"), fallback)
	cache[setname] = maps
	return maps

func _load_or_make(path: String, fallback: Color) -> Image:
	if ResourceLoader.exists(path):
		var tex := load(path) as Texture2D
		if tex != null:
			var img := tex.get_image()
			if img != null:
				return img
	var ph := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	ph.fill(fallback)
	return ph

# Build a Texture2DArray from 32 same-sized images (unifying size + format first).
func _make_array(images: Array) -> Texture2DArray:
	var w := 64
	var h := 64
	if images.size() > 0 and images[0] != null:
		w = (images[0] as Image).get_width()
		h = (images[0] as Image).get_height()
	var slices: Array[Image] = []
	for im in images:
		var img := im as Image
		if img.get_width() != w or img.get_height() != h:
			img.resize(w, h)
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)
		slices.append(img)
	var arr := Texture2DArray.new()
	var err := arr.create_from_images(slices)
	if err != OK:
		push_warning("TerrainStreamer: failed to build Texture2DArray (err %d)." % err)
	return arr

# Load the control map as a single-channel float texture so the 15-bit packing
# survives. Loading the raw file (editor / running from the editor) keeps 16-bit;
# the imported-texture fallback (exported .pck) may be 8-bit — verify if so.
func _load_control_map_texture() -> Texture2D:
	var img := Image.new()
	var ok := img.load(control_map_path) == OK
	if not ok:
		if ResourceLoader.exists(control_map_path):
			var tex := load(control_map_path) as Texture2D
			if tex != null:
				push_warning("Control map via import pipeline — verify it kept 16-bit precision.")
				img = tex.get_image()
			else:
				push_warning("Control map not found: " + control_map_path)
				return null
		else:
			push_warning("Control map not found: " + control_map_path)
			return null
	if img.get_format() != Image.FORMAT_RF:
		img.convert(Image.FORMAT_RF)
	_report_control_map_precision(img)
	return ImageTexture.create_from_image(img)

# Scan a grid of texels to tell whether the control map kept its 16 bits. If it
# was truncated to 8-bit, EVERY value would be a multiple of 256 (low byte == 0),
# which would zero out the base layer everywhere — so a nonzero low byte anywhere
# proves the packing survived.
func _report_control_map_precision(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var step := maxi(1, w / 64)
	var low_byte_nonzero := 0
	var any_overlay := 0
	var any_blend := 0
	var bases := {}
	var samples := 0
	for y in range(0, h, step):
		for x in range(0, w, step):
			var v := int(round(img.get_pixel(x, y).r * 65535.0))
			samples += 1
			if (v & 0xFF) != 0:
				low_byte_nonzero += 1
			if ((v >> 5) & 31) != 0:
				any_overlay += 1
			if ((v >> 10) & 31) != 0:
				any_blend += 1
			bases[v & 31] = true
	var verdict := "16-bit OK" if low_byte_nonzero > 0 else "LOOKS 8-BIT TRUNCATED (re-export as EXR)"
	print("TerrainStreamer: control map %dx%d — %s. %d/%d texels with nonzero low byte; %d distinct base layers; overlay used in %d, blend in %d." % [
		w, h, verdict, low_byte_nonzero, samples, bases.size(), any_overlay, any_blend])
