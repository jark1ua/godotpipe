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
## Recompute each chunk's surface normals at load, excluding the near-vertical
## skirt faces that otherwise tilt the edge-row normals and draw a dark grid along
## every chunk seam. Leave on unless the source meshes already have split skirt
## normals. See _fix_chunk_normals.
@export var fix_edge_normals: bool = true
## Faces flatter than this |normal.y| are treated as skirt walls and excluded from
## edge-vertex normals. 0 = vertical wall, 1 = flat ground; ~0.15 keeps real cliffs
## while dropping the 25 m skirts.
@export var skirt_normal_y_max: float = 0.15
## Optional override: assign a ShaderMaterial to use it verbatim. Leave null and
## the streamer builds the control-map material at runtime from the settings below.
@export var terrain_material: Material
## Seconds between streaming updates.
@export var update_interval: float = 0.25

@export_group("Terrain Material (control map + arrays)")
## 32-layer manifest (names, texture_set, tile_meters, triplanar) baked in Blender.
@export_file("*.json") var layer_manifest_path: String = "res://terrain/control_map_layers.json"
## 16-bit single-channel control map: base(5) | overlay(5) | blend(5) per texel.
@export_file var control_map_path: String = "res://terrain/terrain_control_map.png"
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
var _meta: Dictionary = {}     # "i_j" -> { pos: Vector3, path: String }
var _loaded: Dictionary = {}   # "i_j" -> Node3D
var _pending: Dictionary = {}  # "i_j" -> resource path
var _preview: Dictionary = {}  # "i_j" -> Node3D (editor-only, not saved)
var _player: Node3D = null
var _accum: float = 0.0
var _logged_first: bool = false
var _mesh_count: int = 0
var _material: ShaderMaterial = null   # built once, shared by every chunk
var _fixed_meshes: Dictionary = {}     # mesh RID -> true; fix each shared mesh once

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
	var mat := _get_material()
	for child in node.get_children():
		if child is MeshInstance3D:
			var mi := child as MeshInstance3D
			_mesh_count += 1
			if fix_edge_normals:
				_fix_chunk_normals(mi)
			if mat != null:
				mi.material_override = mat
			if with_collision and mi.mesh != null:
				var body := StaticBody3D.new()
				var cs := CollisionShape3D.new()
				cs.shape = mi.mesh.create_trimesh_shape()
				body.add_child(cs)
				mi.add_child(body)
		_setup_meshes(child, with_collision)

# ---- Edge-normal repair (kills the dark grid along chunk seams) ---------------
#
# Each chunk carries a 25 m vertical skirt around its rim to hide cracks. The top
# ring of skirt verts is shared with the surface's outer ring, so the exporter's
# normal averaging blends the (near-flat) surface normal with the (horizontal)
# skirt-wall normal — tilting the whole edge row outward and shading it darker.
# Across all chunks that paints a grid of shadow lines on the seams.
#
# Fix: recompute vertex normals from the surface faces only, excluding faces that
# are nearly vertical (the skirt). Edge-top verts then take their normal from the
# flat top alone and match across chunks, so the grid disappears. The skirts stay
# (they still hide cracks); only the contaminated normals change. The chunk mesh
# is a shared sub-resource, so each is fixed once and the change covers every
# instance of that chunk.
func _fix_chunk_normals(mi: MeshInstance3D) -> void:
	var mesh := mi.mesh as ArrayMesh
	if mesh == null:
		return
	var rid := mesh.get_rid()
	if _fixed_meshes.has(rid):
		return
	_fixed_meshes[rid] = true
	# Bail unless every surface is plain triangles — we rebuild from arrays and
	# don't want to silently drop strips/points or per-surface materials we can't
	# re-attach. Terrain chunks are triangle soup, so this normally passes.
	for s in range(mesh.get_surface_count()):
		if mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			return
	var fixed_arrays: Array = []
	var any := false
	for s in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(s)
		if _recompute_surface_normals(arrays):
			any = true
		fixed_arrays.append(arrays)
	if not any:
		return
	mesh.clear_surfaces()
	for arrays in fixed_arrays:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

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
			_setup_meshes(inst, false)
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
	mat.set_shader_parameter("world_size_m", 6000.0)
	mat.set_shader_parameter("default_tile_m", default_tile_m)
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
