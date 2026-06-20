@tool
extends Node3D
## Scatters discrete scene objects (rocks, boulders, trees, shrubs, logs, reeds, …) over
## the streamed terrain, each only where the terrain control map says the ground is the
## right biome (boulders on rock, small rocks on pebble, reeds at the waterline, …).
##
## How it fits the project
## -----------------------
## This is the chunky-object sibling of terrain/GrassScatterer.gd. Grass is thousands of
## blades per chunk -> one MultiMesh. Objects are sparse but each wants real geometry AND
## discrete LODs (a tree that becomes a billboard far away), which a MultiMesh can't swap,
## so each placement is a pooled PackedScene instance carrying its own visibility-range
## LODs (see scenes/scatter/*.tscn and scenes/lod_tree.tscn).
##
## What it reuses from the grass scatterer (same rules, see CLAUDE.md):
##   * Per-chunk, nearest-first, time-budgeted streaming around the player; chunks beyond
##     keep_radius recycle back to a pool (no churn of nodes/resources while flying).
##   * Deterministic per-chunk RNG (seeded by chunk key + kind), so revisiting a chunk
##     reproduces the exact same field — no popping/reshuffle.
##   * Ground height + slope from a downward raycast against the terrain collision, so this
##     node needs no copy of the heightfield.
##   * Control-map biome gate on the CPU: each kind names terrain `groups`; placement
##     probability follows how much of the texel is that group.
##
## Kinds are data (terrain/ScatterKind.gd resources) set in the inspector / Objects.tscn,
## so adding an object type or swapping in your real model is no-code. Pooling is PER KIND.

# ---- wiring ----------------------------------------------------------------
@export var player_path: NodePath
@export_file("*.json") var manifest_path: String = "res://terrain/terrain_manifest.json"
@export_file("*.json") var layer_manifest_path: String = "res://terrain/control_map_layers.json"
@export_file var control_map_path: String = "res://terrain/terrain_control_map.exr"
## The object kinds to scatter. Each element is a ScatterKind resource (scene + biome
## groups + density + placement). Objects.tscn ships a starter set of placeholders.
## (Untyped Array so the hand-authored .tscn list loads cleanly; elements are ScatterKind.)
@export var kinds: Array = []

# ---- scatter radius / budget ------------------------------------------------
## Chunks (square radius) around the player that get objects. Objects read further than
## grass (they're big), but each is a scene instance — keep it sane. 1 chunk ~193 m.
@export var object_radius: int = 3
## Chunks kept before recycling — keep > object_radius for hysteresis (no thrash).
@export var keep_radius: int = 4
## Global seed; change to reshuffle every field at once.
@export var scatter_seed: int = 9001
## Don't place on ground steeper than the kind allows OR this global cap (deg).
@export_range(0.0, 90.0) var global_max_slope_deg: float = 60.0
@export var update_interval: float = 0.25
## Soft per-frame time budget (ms) for populating newly-entered chunks (raycasts cost).
@export var build_budget_ms: float = 3.0
@export var max_builds_per_frame: int = 1
## Physics layers the ground ray tests against (terrain StaticBody is layer 1).
@export_flags_3d_physics var collision_mask: int = 1
## Distance (m) at which whole object chunks fade out (0 = rely on object_radius).
@export var view_distance: float = 0.0
@export var debug_objects: bool = false

# ---- editor preview ---------------------------------------------------------
@export var preview_focus_chunk: Vector2i = Vector2i(15, 15)
@export var preview_radius: int = 1
@export_tool_button("Load Editor Preview") var _btn_load_preview: Callable = _load_editor_preview
@export_tool_button("Clear Editor Preview") var _btn_clear_preview: Callable = _clear_editor_preview

var _step: float = 193.5483
var _center: int = 15
var _world_size: float = 6000.0
var _meta: Dictionary = {}            # "i_j" -> { h_min, h_max }
var _layer_group: Dictionary = {}     # layer index -> group string
var _kind_layers: Array = []          # per kind: Dictionary index->true (null = any ground)
var _fields: Array = []               # per kind: ScatterField (blue_noise) or null (uniform)
var _control_img: Image = null
var _cm_w: int = 0
var _cm_h: int = 0
var _player: Node3D = null
var _water: Node = null
var _accum: float = 0.0
var _active: Dictionary = {}          # "i_j" -> Array of [kind_index, Node3D]
var _pools: Array = []                # per kind: Array[Node3D] of recycled instances
var _preview: Dictionary = {}
var _pi: int = 0
var _pj: int = 0

func _ready() -> void:
	_load_manifest()
	_load_layer_groups()
	_build_fields()
	_load_control_map()
	_pools.resize(kinds.size())
	for i in range(kinds.size()):
		_pools[i] = []
	if Engine.is_editor_hint():
		return
	if not player_path.is_empty():
		_player = get_node_or_null(player_path) as Node3D
	if _player == null:
		_player = get_viewport().get_camera_3d()
		if _player != null:
			push_warning("ObjectScatterer: player_path unresolved; using active Camera3D.")
	_water = get_node_or_null("/root/WaterMap")
	print("ObjectScatterer ready: %d kind(s), control map %dx%d, player=%s" % [
		kinds.size(), _cm_w, _cm_h, _player.name if _player != null else "<none>"])

func _process(delta: float) -> void:
	if Engine.is_editor_hint() or _player == null:
		return
	_pj = int(round(_player.global_position.x / _step)) + _center
	_pi = int(round(-_player.global_position.z / _step)) + _center
	_scatter_wanted()
	_accum += delta
	if _accum < update_interval:
		return
	_accum = 0.0
	_recycle_distant()
	if debug_objects:
		print("ObjectScatterer: chunk (%d,%d) active=%d" % [_pi, _pj, _active.size()])

# Populate the nearest wanted-but-missing chunks inside object_radius, nearest-first,
# bounded by the per-frame time budget (always >= 1 chunk so it progresses).
func _scatter_wanted() -> void:
	if kinds.is_empty():
		return
	var wanted: Array = []
	for di in range(-object_radius, object_radius + 1):
		for dj in range(-object_radius, object_radius + 1):
			var key := "%d_%d" % [_pi + di, _pj + dj]
			if _meta.has(key) and not _active.has(key):
				wanted.append([di * di + dj * dj, key])
	if wanted.is_empty():
		return
	wanted.sort_custom(func(a, b): return a[0] < b[0])
	var budget_us := int(build_budget_ms * 1000.0)
	var t_start := Time.get_ticks_usec()
	var built := 0
	for entry in wanted:
		if built >= max_builds_per_frame:
			break
		if built > 0 and Time.get_ticks_usec() - t_start >= budget_us:
			break
		if _scatter_chunk(entry[1]):
			built += 1

# Build one chunk's full object set across every kind. Returns false (retry next frame)
# if the terrain collision under the chunk hasn't streamed in yet.
func _scatter_chunk(key: String) -> bool:
	var parts := String(key).split("_")
	var ci := int(parts[0])
	var cj := int(parts[1])
	var cx := (cj - _center) * _step
	var cz := -(ci - _center) * _step
	var half := _step * 0.5
	var info: Dictionary = _meta[key]
	var ray_top := float(info["h_max"]) + 5.0
	var ray_bot := float(info["h_min"]) - 30.0   # below the 25 m skirt

	var space := get_world_3d().direct_space_state
	if _ground_hit(space, cx, cz, ray_top, ray_bot).is_empty():
		return false   # chunk collision not ready

	var placed: Array = []
	for ki in range(kinds.size()):
		var kind: ScatterKind = kinds[ki]
		if kind == null or kind.scene == null:
			continue
		var cos_max := cos(deg_to_rad(min(kind.max_slope_deg, global_max_slope_deg)))
		var layers: Variant = _kind_layers[ki]
		var field: ScatterField = _fields[ki]
		if field != null:
			# Advanced path: blue-noise candidates masked by the region/grove density
			# field times the biome weight. Raycasts only fire for accepted candidates.
			for cand in field.candidates(cx - half, cz - half, cx + half, cz + half):
				var p2: Vector2 = cand[0]
				var rng := field.cell_rng(cand[1], kind.seed_offset)
				var gw := 1.0 if layers == null else _group_weight(p2.x, p2.y, layers)
				if rng.randf() > field.density_at(p2.x, p2.y) * gw:
					continue
				var node := _place_candidate(ki, kind, p2.x, p2.y, rng, space, ray_top, ray_bot, cos_max)
				if node != null:
					placed.append([ki, node])
		else:
			# Legacy uniform path: `density` independent random samples per chunk.
			var rng := RandomNumberGenerator.new()
			rng.seed = hash(key) ^ scatter_seed ^ (kind.seed_offset * 2654435761)
			for n in range(kind.density):
				var wx := cx + rng.randf_range(-half, half)
				var wz := cz + rng.randf_range(-half, half)
				# Biome gate: probability follows how much of this texel is the kind's group.
				if layers != null and rng.randf() > _group_weight(wx, wz, layers):
					continue
				var node := _place_candidate(ki, kind, wx, wz, rng, space, ray_top, ray_bot, cos_max)
				if node != null:
					placed.append([ki, node])
	_active[key] = placed
	if debug_objects:
		print("ObjectScatterer: chunk %s -> %d object(s)" % [key, placed.size()])
	return true

# Try to place one candidate at world XZ: raycast the ground, reject by slope and the
# kind's placement rule (land/water_edge), then take a pooled instance and pose it.
# Returns the placed Node3D, or null if any gate rejected it. `rng` supplies yaw/scale.
func _place_candidate(ki: int, kind: ScatterKind, wx: float, wz: float, rng: RandomNumberGenerator,
		space: PhysicsDirectSpaceState3D, ray_top: float, ray_bot: float, cos_max: float) -> Node3D:
	var hit := _ground_hit(space, wx, wz, ray_top, ray_bot)
	if hit.is_empty():
		return null
	var nrm: Vector3 = hit["normal"]
	if nrm.y < cos_max:
		return null
	var pos: Vector3 = hit["position"]
	if not _placement_ok(kind, pos):
		return null
	pos.y -= kind.y_offset
	var yaw := rng.randf() * TAU if kind.random_yaw else 0.0
	var scl := rng.randf_range(kind.min_scale, kind.max_scale)
	var node := _take_instance(ki)
	node.transform = _object_transform(pos, nrm, yaw, scl, kind.align_to_normal)
	node.visible = true
	return node

# True if `pos` satisfies the kind's placement rule (land vs shoreline band).
func _placement_ok(kind: ScatterKind, pos: Vector3) -> bool:
	if kind.placement == "water_edge":
		if _water == null:
			return false
		var lvl: float = _water.water_level_at(pos.x, pos.z)
		return absf(pos.y - lvl) <= kind.water_band
	# land
	if kind.avoid_water and _water != null and _water.is_submerged(pos, 0.05):
		return false
	return true

# Object transform: stand mostly upright, tilt toward the ground normal by align,
# optional random yaw, uniform scale. Right-handed basis (det +1) so normals stay valid.
func _object_transform(pos: Vector3, nrm: Vector3, yaw: float, scl: float, align: float) -> Transform3D:
	var up := Vector3.UP.lerp(nrm, align).normalized()
	var fwd := Vector3(sin(yaw), 0.0, cos(yaw))
	var right := fwd.cross(up)
	if right.length_squared() < 1e-6:
		right = Vector3.RIGHT
	right = right.normalized()
	var zaxis := right.cross(up).normalized()
	var basis := Basis(right, up, zaxis).scaled(Vector3(scl, scl, scl))
	return Transform3D(basis, pos)

func _ground_hit(space: PhysicsDirectSpaceState3D, wx: float, wz: float, top: float, bot: float) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(Vector3(wx, top, wz), Vector3(wx, bot, wz), collision_mask)
	return space.intersect_ray(q)

# Recycle object chunks the player has left back into the per-kind pools (hidden, kept).
func _recycle_distant() -> void:
	for key in _active.keys():
		var parts := String(key).split("_")
		if max(abs(int(parts[0]) - _pi), abs(int(parts[1]) - _pj)) > keep_radius:
			for entry in _active[key]:
				var ki: int = entry[0]
				var node: Node3D = entry[1]
				node.visible = false
				_pools[ki].append(node)
			_active.erase(key)

func _take_instance(ki: int) -> Node3D:
	var pool: Array = _pools[ki]
	if not pool.is_empty():
		return pool.pop_back()
	var inst := (kinds[ki].scene as PackedScene).instantiate() as Node3D
	if view_distance > 0.0:
		_apply_view_distance(inst)
	add_child(inst)
	return inst

func _apply_view_distance(inst: Node3D) -> void:
	# Fade the whole instance out past view_distance (in addition to its own per-mesh LODs).
	for child in inst.get_children():
		if child is GeometryInstance3D:
			child.visibility_range_end = view_distance
			child.visibility_range_end_margin = view_distance * 0.15
			child.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF

# ---- control map + biome layers --------------------------------------------

func _load_manifest() -> void:
	if not _meta.is_empty():
		return
	var f := FileAccess.open(manifest_path, FileAccess.READ)
	if f == null:
		push_warning("ObjectScatterer: terrain manifest not found: " + manifest_path)
		return
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	_step = float(data.get("step_m", _step))
	_center = int(data.get("center_index", _center))
	_world_size = float(data.get("world_size_m", _world_size))
	for c in data.get("chunks", []):
		var key := "%d_%d" % [int(c["i"]), int(c["j"])]
		_meta[key] = {"h_min": float(c.get("h_min", -400.0)), "h_max": float(c.get("h_max", 1500.0))}

func _load_layer_groups() -> void:
	_layer_group.clear()
	var f := FileAccess.open(layer_manifest_path, FileAccess.READ)
	if f == null:
		push_warning("ObjectScatterer: layer manifest not found: " + layer_manifest_path)
		return
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	for li in data.get("layers", []):
		_layer_group[int(li["index"])] = String(li.get("group", ""))
	# Per-kind set of layer indices it may spawn on (null = any ground).
	_kind_layers.resize(kinds.size())
	for ki in range(kinds.size()):
		var kind: ScatterKind = kinds[ki]
		if kind == null or kind.groups.is_empty():
			_kind_layers[ki] = null
			continue
		var d := {}
		for idx in _layer_group:
			if String(_layer_group[idx]) in kind.groups:
				d[idx] = true
		_kind_layers[ki] = d

# Build one ScatterField per blue_noise kind (uniform kinds get null). Cheap: each is a
# couple of FastNoiseLite objects; built once and reused for every chunk.
func _build_fields() -> void:
	_fields.resize(kinds.size())
	for ki in range(kinds.size()):
		var kind: ScatterKind = kinds[ki]
		if kind != null and kind.distribution == "blue_noise":
			_fields[ki] = ScatterField.make(kind.field_params(scatter_seed))
		else:
			_fields[ki] = null

func _load_control_map() -> void:
	_control_img = Image.new()
	if _control_img.load(control_map_path) != OK:
		if ResourceLoader.exists(control_map_path):
			var tex := load(control_map_path) as Texture2D
			if tex != null:
				_control_img = tex.get_image()
			else:
				_control_img = null
				return
		else:
			push_warning("ObjectScatterer: control map not found: " + control_map_path)
			_control_img = null
			return
	if _control_img.get_format() != Image.FORMAT_RF:
		_control_img.convert(Image.FORMAT_RF)
	_cm_w = _control_img.get_width()
	_cm_h = _control_img.get_height()

# Group weight at a world XZ (0..1): how much of this texel is one of `layers`. Mirrors the
# terrain shader's control-map UV: u across +X (east), v top = south(+Z).
func _group_weight(wx: float, wz: float, layers: Dictionary) -> float:
	if _control_img == null or _cm_w == 0:
		return 1.0
	var half := _world_size * 0.5
	var u := clampf((wx + half) / _world_size, 0.0, 1.0)
	var v := clampf((half - wz) / _world_size, 0.0, 1.0)
	var px := clampi(int(u * float(_cm_w - 1)), 0, _cm_w - 1)
	var py := clampi(int(v * float(_cm_h - 1)), 0, _cm_h - 1)
	var packed := int(round(_control_img.get_pixel(px, py).r * 65535.0))
	var base_l := packed & 31
	var over_l := (packed >> 5) & 31
	var blend := (float((packed >> 10) & 31) / 31.0) * 0.5
	var w := 0.0
	if layers.has(base_l):
		w += 1.0 - blend
	if layers.has(over_l):
		w += blend
	return clampf(w, 0.0, 1.0)

# ---- editor-only preview (no streaming, no save) ---------------------------

func _load_editor_preview() -> void:
	if not Engine.is_editor_hint():
		return
	_clear_editor_preview()
	_load_manifest()
	_load_layer_groups()
	_build_fields()
	_load_control_map()
	push_warning("ObjectScatterer preview: editor has no terrain collision to raycast; "
		+ "objects are placed on a flat plane at chunk height. Run the scene (F6) for the real field.")
	var fi := preview_focus_chunk.x
	var fj := preview_focus_chunk.y
	for di in range(-preview_radius, preview_radius + 1):
		for dj in range(-preview_radius, preview_radius + 1):
			var key := "%d_%d" % [fi + di, fj + dj]
			if _meta.has(key):
				_preview_chunk(key)

func _preview_chunk(key: String) -> void:
	var parts := String(key).split("_")
	var ci := int(parts[0])
	var cj := int(parts[1])
	var cx := (cj - _center) * _step
	var cz := -(ci - _center) * _step
	var half := _step * 0.5
	var info: Dictionary = _meta[key]
	var y := (float(info["h_min"]) + float(info["h_max"])) * 0.5
	var nodes: Array = []
	for ki in range(kinds.size()):
		var kind: ScatterKind = kinds[ki]
		if kind == null or kind.scene == null:
			continue
		var layers: Variant = _kind_layers[ki]
		var field: ScatterField = _fields[ki]
		if field != null:
			for cand in field.candidates(cx - half, cz - half, cx + half, cz + half):
				var p2: Vector2 = cand[0]
				var crng := field.cell_rng(cand[1], kind.seed_offset)
				var gw := 1.0 if layers == null else _group_weight(p2.x, p2.y, layers)
				if crng.randf() > field.density_at(p2.x, p2.y) * gw:
					continue
				nodes.append(_spawn_preview(kind, p2.x, y, p2.y, crng))
		else:
			var rng := RandomNumberGenerator.new()
			rng.seed = hash(key) ^ scatter_seed ^ (kind.seed_offset * 2654435761)
			for n in range(kind.density):
				var wx := cx + rng.randf_range(-half, half)
				var wz := cz + rng.randf_range(-half, half)
				if layers != null and rng.randf() > _group_weight(wx, wz, layers):
					continue
				nodes.append(_spawn_preview(kind, wx, y, wz, rng))
	_preview[key] = nodes

func _spawn_preview(kind: ScatterKind, wx: float, y: float, wz: float, rng: RandomNumberGenerator) -> Node3D:
	var inst := (kind.scene as PackedScene).instantiate() as Node3D
	var yaw := rng.randf() * TAU if kind.random_yaw else 0.0
	var scl := rng.randf_range(kind.min_scale, kind.max_scale)
	inst.transform = _object_transform(Vector3(wx, y, wz), Vector3.UP, yaw, scl, 0.0)
	add_child(inst)   # no owner -> not serialised into the .tscn
	return inst

func _clear_editor_preview() -> void:
	for key in _preview.keys():
		for n in _preview[key]:
			if is_instance_valid(n):
				n.free()
	_preview.clear()
