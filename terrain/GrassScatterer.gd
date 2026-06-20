@tool
extends Node3D
## Scatters animated grass over the streamed terrain, only where the terrain
## control map says the ground is a "grass" layer.
##
## How it fits the project
## ------------------------
## The terrain is no longer a 4-channel splatmap; it is a 32-layer control map
## (terrain_control_map.exr) where each texel names a base + overlay layer and a
## blend. Every layer carries a `group` in control_map_layers.json
## (grass / rock / snow / sand / forest / wet / gravel / special). This node reads
## the manifest, works out which layer indices are grass (group in `grass_groups`),
## then samples the control map on the CPU at each candidate blade so grass only
## appears on grass-textured ground — denser where the texel is more grass, none on
## rock/snow/sand.
##
## Placement strategy (mirrors TerrainStreamer)
## --------------------------------------------
##   * Only chunks within `grass_radius` of the player get grass (a small radius —
##     grass is a near-camera detail, the terrain streams much further).
##   * Each chunk gets ONE MultiMesh of up to `instances_per_chunk` blades, scattered
##     on a per-chunk deterministic RNG (seeded by chunk key) so re-entering a chunk
##     reproduces the exact same field — no popping or reshuffling.
##   * Ground height + slope per blade come from a downward raycast against the
##     terrain's existing collision, so this node needs no copy of the heightfield.
##   * MultiMeshInstance3D nodes are POOLED and reused as the player moves, so we are
##     not churning RenderingServer resources every step (the terrain notes warn hard
##     against per-chunk runtime mesh/shape creation while flying — MultiMesh buffer
##     refills are far lighter, and pooling keeps even those bounded). All work is on
##     the main thread and time-budgeted per frame.
##
## LOD
## ---
## You bake the grass LODs into the mesh on import; a MultiMesh applies the mesh's
## own LODs automatically by screen size. `view_distance` additionally fades whole
## chunks out at the far edge. Tune `grass_radius` / `instances_per_chunk` for the
## near-field density you want.
##
## Setup
## -----
##   1. Add this node to your level (or instance scenes/Grass.tscn) and set Player Path.
##   2. Plug your grass mesh into Grass Mesh (a Mesh resource — e.g. the ArrayMesh
##      from your imported grass .glb, which carries its LODs). Until you do, a simple
##      procedural blade tuft stands in so you can see the wind + scatter working.
##   3. Grass Material defaults to a ShaderMaterial using shaders/grass_wind.gdshader.
##      Leave it to animate the stand-in / your mesh, or clear it to use your mesh's
##      own material.

# ---- wiring ----------------------------------------------------------------
@export var player_path: NodePath
## Terrain manifest (for step size, grid centre and per-chunk height range).
@export_file("*.json") var manifest_path: String = "res://terrain/terrain_manifest.json"
## 32-layer manifest — read to learn which layer indices belong to a grass group.
@export_file("*.json") var layer_manifest_path: String = "res://terrain/control_map_layers.json"
## 16-bit single-channel control map: base(5) | overlay(5) | blend(5) per texel.
@export_file var control_map_path: String = "res://terrain/terrain_control_map.exr"
## Layer groups treated as "grass". The manifest tags 05-09 as group "grass"; add
## "forest" here too if you want grass under the forest-floor layers (16-19).
@export var grass_groups: PackedStringArray = PackedStringArray(["grass"])

# ---- the grass asset (you make this elsewhere) -----------------------------
## Your grass mesh. A Mesh resource with the pivot at the blade BASE (y=0..height).
## Imported grass .glb LODs are applied automatically by the MultiMesh. Leave empty
## to use the built-in procedural stand-in blade.
@export var grass_mesh: Mesh
## Material applied to every grass MultiMesh (overrides the mesh's own material).
## Defaults via Grass.tscn to a ShaderMaterial on shaders/grass_wind.gdshader. Clear
## it to fall back to your mesh's material.
@export var grass_material: Material
## Build a stand-in blade tuft when Grass Mesh is empty so the system is visible
## before your asset lands. Turn off to render nothing until you plug a mesh in.
@export var use_placeholder_when_empty: bool = true

# ---- scatter density / radius ----------------------------------------------
## Chunks (square radius) around the player that get grass. 1 -> 3x3, 2 -> 5x5. Keep
## small; grass is a near detail. 1 chunk = step_m metres (~193 m).
@export var grass_radius: int = 2
## Chunks kept before recycling — keep > grass_radius for hysteresis (no thrash).
@export var keep_radius: int = 3
## Candidate blades scattered per chunk before the control-map / slope gates reject
## some. A 193 m chunk at 1200 -> ~0.03 blades/m² of candidates; raise for denser turf.
@export var instances_per_chunk: int = 1200
## Global seed; change to reshuffle every field at once.
@export var grass_seed: int = 1337

@export_group("Meadow density field")
## Modulate grass density with a domain-warped fBm field so plains read as patchy
## meadows — lush clumps, thinner ground, occasional bare scrapes — instead of a flat
## uniform carpet. 0 = off (uniform within grass texels). ~0.0015 = ~horizon-scale
## patches; higher = smaller tufts. Shares the algorithm with terrain/ScatterField.gd.
@export var meadow_freq: float = 0.0
@export_range(1, 8) var meadow_octaves: int = 4
## fBm value below which grass thins out toward bare (lower = grassier overall).
@export_range(0.0, 1.0) var meadow_threshold: float = 0.3
## Soft-edge half-width around the threshold (lush fades to thin over this band).
@export_range(0.001, 0.5) var meadow_falloff: float = 0.25
## Domain-warp amplitude (m) so meadow patches meander instead of forming blobs.
@export var meadow_warp: float = 60.0
## How strongly the field thins grass: 0 = no effect (even if freq>0), 1 = full mask.
@export_range(0.0, 1.0) var meadow_strength: float = 1.0
## Optional shared region seed (see ScatterKind.density_seed). 0 = derive from grass_seed.
## Match a meadow-flower ScatterKind's density_seed to align the lush patches with it.
@export var meadow_seed: int = 0

# ---- per-blade placement ----------------------------------------------------
## How much each blade tilts to match the ground normal (0 = always upright,
## 1 = fully laid along the slope). A little looks natural; too much on slopes splays.
@export_range(0.0, 1.0) var align_to_normal: float = 0.25
## Skip ground steeper than this (degrees) — grass doesn't cling to cliffs. Also
## guards against the control map reading grass on a steep face.
@export_range(0.0, 90.0) var max_slope_deg: float = 40.0
## Don't spawn grass on ground that sits below the water surface (sea or lake). Reads
## the WaterMap autoload; no-op if it isn't present.
@export var avoid_water: bool = true
## Treat ground within this many metres of the water surface as submerged too, so the
## turf stops a touch before the waterline instead of poking through the shallows.
@export var water_margin: float = 0.15
@export var min_scale: float = 0.7
@export var max_scale: float = 1.4
## Sink the base this many metres into the ground so blades don't hover on bumps.
@export var ground_sink: float = 0.03
## Physics layers the ground ray tests against (terrain StaticBody is layer 1).
@export_flags_3d_physics var collision_mask: int = 1

# ---- rendering --------------------------------------------------------------
## Distance (m) at which whole grass chunks fade out. 0 = no extra fade (rely on
## grass_radius). Applied as MultiMeshInstance3D visibility range.
@export var view_distance: float = 0.0
## Grass casting shadows is expensive for little gain; off by default.
@export var cast_shadows: bool = false

# ---- streaming budget -------------------------------------------------------
@export var update_interval: float = 0.25
## Soft per-frame time budget (ms) for scattering newly-entered chunks (the raycasts
## are the cost). Always does at least one chunk so it makes progress.
@export var build_budget_ms: float = 2.5
@export var max_builds_per_frame: int = 1
@export var debug_grass: bool = false

# ---- editor preview ---------------------------------------------------------
## Chunk (i, j) to centre the editor preview on. (15, 15) is the world origin.
@export var preview_focus_chunk: Vector2i = Vector2i(15, 15)
@export var preview_radius: int = 1
@export_tool_button("Load Editor Preview") var _btn_load_preview: Callable = _load_editor_preview
@export_tool_button("Clear Editor Preview") var _btn_clear_preview: Callable = _clear_editor_preview

var _step: float = 193.5483
var _center: int = 15
var _world_size: float = 6000.0
var _meta: Dictionary = {}        # "i_j" -> { h_min, h_max } (valid chunk set)
var _grass_layers: Dictionary = {} # layer index -> true, for the grass groups
var _control_img: Image = null
var _cm_w: int = 0
var _cm_h: int = 0
var _player: Node3D = null
var _accum: float = 0.0
var _active: Dictionary = {}      # "i_j" -> MultiMeshInstance3D (scattered)
var _pool: Array[MultiMeshInstance3D] = []
var _preview: Dictionary = {}     # editor-only, not saved
var _placeholder: Mesh = null
var _water: Node = null            # WaterMap autoload, for the under-water gate
var _meadow: ScatterField = null   # optional meadow density modulation (null = off)
var _pi: int = 0
var _pj: int = 0

func _ready() -> void:
	_load_manifest()
	_load_grass_layers()
	_build_meadow_field()
	_load_control_map()
	if Engine.is_editor_hint():
		return
	if not player_path.is_empty():
		_player = get_node_or_null(player_path) as Node3D
	if _player == null:
		_player = get_viewport().get_camera_3d()
		if _player != null:
			push_warning("GrassScatterer: player_path unresolved; falling back to active Camera3D.")
	if avoid_water:
		_water = get_node_or_null("/root/WaterMap")
	print("GrassScatterer ready: %d grass layers, control map %dx%d, player=%s" % [
		_grass_layers.size(), _cm_w, _cm_h, _player.name if _player != null else "<none>"])

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
	if debug_grass:
		print("GrassScatterer: chunk (%d,%d) active=%d pooled=%d" % [
			_pi, _pj, _active.size(), _pool.size()])

# Scatter the nearest wanted-but-missing chunks inside grass_radius, nearest-first,
# bounded by the per-frame time budget (always >= 1 chunk so it progresses).
func _scatter_wanted() -> void:
	var mesh := _resolve_mesh()
	if mesh == null:
		return
	var wanted: Array = []
	for di in range(-grass_radius, grass_radius + 1):
		for dj in range(-grass_radius, grass_radius + 1):
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
		if _scatter_chunk(entry[1], mesh):
			built += 1   # only counts when the chunk was ready (collision present)

# Build one chunk's grass field. Returns false (retry later) if the terrain
# collision under the chunk isn't loaded yet, true once the field is placed.
func _scatter_chunk(key: String, mesh: Mesh) -> bool:
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
	# Probe the chunk centre: a miss means the terrain collision hasn't streamed in
	# yet, so bail and retry next frame rather than scattering into the void.
	if _ground_hit(space, cx, cz, ray_top, ray_bot).is_empty():
		return false

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(key) ^ grass_seed
	var cos_max := cos(deg_to_rad(max_slope_deg))
	var transforms: Array[Transform3D] = []
	for n in range(instances_per_chunk):
		var wx := cx + rng.randf_range(-half, half)
		var wz := cz + rng.randf_range(-half, half)
		# Control-map gate: probability of a blade follows the grass weight here.
		if rng.randf() > _grass_weight(wx, wz):
			continue
		var hit := _ground_hit(space, wx, wz, ray_top, ray_bot)
		if hit.is_empty():
			continue
		var nrm: Vector3 = hit["normal"]
		if nrm.y < cos_max:
			continue   # too steep for grass
		var pos: Vector3 = hit["position"]
		# Skip ground that sits under the water surface (sea or lake).
		if _water != null and _water.is_submerged(pos, water_margin):
			continue
		pos.y -= ground_sink
		var yaw := rng.randf() * TAU
		var scl := rng.randf_range(min_scale, max_scale)
		transforms.append(_blade_transform(pos, nrm, yaw, scl))

	var mmi := _take_mmi()
	var mm := mmi.multimesh
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in range(transforms.size()):
		mm.set_instance_transform(i, transforms[i])
	mmi.visible = transforms.size() > 0
	_active[key] = mmi
	if debug_grass:
		print("GrassScatterer: chunk %s -> %d blades" % [key, transforms.size()])
	return true

# Compose a blade transform: stand mostly upright, tilt toward the ground normal by
# align_to_normal, random yaw about that up axis, uniform scale.
func _blade_transform(pos: Vector3, nrm: Vector3, yaw: float, scl: float) -> Transform3D:
	var up := Vector3.UP.lerp(nrm, align_to_normal).normalized()
	var fwd := Vector3(sin(yaw), 0.0, cos(yaw))
	var right := fwd.cross(up)
	if right.length_squared() < 1e-6:
		right = Vector3.RIGHT
	right = right.normalized()
	# z = x.cross(y) keeps the basis right-handed (det +1); the reverse sign would
	# mirror the blade and invert its normals.
	var zaxis := right.cross(up).normalized()
	var basis := Basis(right, up, zaxis).scaled(Vector3(scl, scl, scl))
	return Transform3D(basis, pos)

func _ground_hit(space: PhysicsDirectSpaceState3D, wx: float, wz: float, top: float, bot: float) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(Vector3(wx, top, wz), Vector3(wx, bot, wz), collision_mask)
	return space.intersect_ray(q)

# Recycle grass chunks the player has moved away from back into the pool (kept, not
# freed, so the next traversal reuses the MultiMesh buffers instead of reallocating).
func _recycle_distant() -> void:
	for key in _active.keys():
		var parts := String(key).split("_")
		if max(abs(int(parts[0]) - _pi), abs(int(parts[1]) - _pj)) > keep_radius:
			var mmi: MultiMeshInstance3D = _active[key]
			mmi.visible = false
			mmi.multimesh.instance_count = 0
			_pool.append(mmi)
			_active.erase(key)

func _take_mmi() -> MultiMeshInstance3D:
	if not _pool.is_empty():
		return _pool.pop_back()
	var mmi := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mmi.multimesh = mm
	if grass_material != null:
		mmi.material_override = grass_material
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if view_distance > 0.0:
		mmi.visibility_range_end = view_distance
		mmi.visibility_range_end_margin = view_distance * 0.15
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(mmi)
	return mmi

# ---- control map + grass layers --------------------------------------------

func _load_manifest() -> void:
	if not _meta.is_empty():
		return
	var f := FileAccess.open(manifest_path, FileAccess.READ)
	if f == null:
		push_warning("GrassScatterer: terrain manifest not found: " + manifest_path)
		return
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	_step = float(data.get("step_m", _step))
	_center = int(data.get("center_index", _center))
	_world_size = float(data.get("world_size_m", _world_size))
	for c in data.get("chunks", []):
		var key := "%d_%d" % [int(c["i"]), int(c["j"])]
		_meta[key] = {"h_min": float(c.get("h_min", -400.0)), "h_max": float(c.get("h_max", 1500.0))}

func _load_grass_layers() -> void:
	_grass_layers.clear()
	var f := FileAccess.open(layer_manifest_path, FileAccess.READ)
	if f == null:
		push_warning("GrassScatterer: layer manifest not found: " + layer_manifest_path)
		return
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	for li in data.get("layers", []):
		if String(li.get("group", "")) in grass_groups:
			_grass_layers[int(li["index"])] = true

# Build the optional meadow density field (null when meadow_freq <= 0). Reuses the same
# domain-warped fBm machinery as the object scatterer so plains and forests read alike.
func _build_meadow_field() -> void:
	if meadow_freq <= 0.0:
		_meadow = null
		return
	_meadow = ScatterField.make({
		"seed": meadow_seed if meadow_seed != 0 else grass_seed,
		"density_freq": meadow_freq,
		"density_octaves": meadow_octaves,
		"density_threshold": meadow_threshold,
		"density_falloff": meadow_falloff,
		"density_warp": meadow_warp,
	})

func _load_control_map() -> void:
	_control_img = Image.new()
	if _control_img.load(control_map_path) != OK:
		# Imported-pipeline fallback (e.g. running from an exported .pck).
		if ResourceLoader.exists(control_map_path):
			var tex := load(control_map_path) as Texture2D
			if tex != null:
				_control_img = tex.get_image()
			else:
				push_warning("GrassScatterer: control map not found: " + control_map_path)
				_control_img = null
				return
		else:
			push_warning("GrassScatterer: control map not found: " + control_map_path)
			_control_img = null
			return
	if _control_img.get_format() != Image.FORMAT_RF:
		_control_img.convert(Image.FORMAT_RF)
	_cm_w = _control_img.get_width()
	_cm_h = _control_img.get_height()

# Grass weight at a world XZ (0..1): how much of this texel is a grass layer.
# Mirrors the terrain shader's control-map UV: u across +X (east), v top=south(+Z).
func _grass_weight(wx: float, wz: float) -> float:
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
	if _grass_layers.has(base_l):
		w += 1.0 - blend
	if _grass_layers.has(over_l):
		w += blend
	# Thin the grass through the meadow density field (patchy lush/bare), if enabled.
	if _meadow != null and meadow_strength > 0.0:
		w *= lerp(1.0, _meadow.density_at(wx, wz), meadow_strength)
	return clampf(w, 0.0, 1.0)

# ---- grass mesh -------------------------------------------------------------

func _resolve_mesh() -> Mesh:
	if grass_mesh != null:
		return grass_mesh
	if not use_placeholder_when_empty:
		return null
	if _placeholder == null:
		_placeholder = _make_placeholder_mesh()
	return _placeholder

# A stand-in grass tuft: three crossed quad blades, pivot at the base (y=0..h), so
# the wind mask and base->tip gradient in grass_wind.gdshader work out of the box.
# Built once; replaced the moment you assign Grass Mesh.
func _make_placeholder_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h := 0.6
	var w := 0.12
	for b in range(3):
		var ang := float(b) * (PI / 3.0)
		var dx := cos(ang) * w
		var dz := sin(ang) * w
		# Two triangles forming the blade quad, narrowing toward the tip.
		var p0 := Vector3(-dx, 0.0, -dz)
		var p1 := Vector3(dx, 0.0, dz)
		var p2 := Vector3(dx * 0.3, h, dz * 0.3)
		var p3 := Vector3(-dx * 0.3, h, -dz * 0.3)
		# Upward normal: stylised grass reads best lit like the ground beneath it
		# rather than from the side of each thin blade.
		_quad(st, p0, p1, p2, p3, Vector3.UP)
	return st.commit()

func _quad(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, nrm: Vector3) -> void:
	var uvs := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
	var pts := [p0, p1, p2, p3]
	for idx in [0, 1, 2, 0, 2, 3]:
		st.set_normal(nrm)
		st.set_uv(uvs[idx])
		st.add_vertex(pts[idx])

# ---- editor-only preview (no streaming, no save) ---------------------------

func _load_editor_preview() -> void:
	if not Engine.is_editor_hint():
		return
	_clear_editor_preview()
	_load_manifest()
	_load_grass_layers()
	_build_meadow_field()
	_load_control_map()
	push_warning("GrassScatterer preview: editor has no terrain collision to raycast; "
		+ "blades are placed on a flat plane at chunk height. Run the scene (F6) for the real field.")
	var mesh := _resolve_mesh()
	if mesh == null:
		return
	var fi := preview_focus_chunk.x
	var fj := preview_focus_chunk.y
	for di in range(-preview_radius, preview_radius + 1):
		for dj in range(-preview_radius, preview_radius + 1):
			var key := "%d_%d" % [fi + di, fj + dj]
			if not _meta.has(key):
				continue
			var mmi := _preview_field(key, mesh)
			if mmi != null:
				_preview[key] = mmi

# Editor preview can't raycast (no physics), so it lays blades on a flat plane at the
# chunk's mid height just to visualise density / wind. The running scene uses real
# ground via collision.
func _preview_field(key: String, mesh: Mesh) -> MultiMeshInstance3D:
	var parts := String(key).split("_")
	var ci := int(parts[0])
	var cj := int(parts[1])
	var cx := (cj - _center) * _step
	var cz := -(ci - _center) * _step
	var half := _step * 0.5
	var info: Dictionary = _meta[key]
	var y := (float(info["h_min"]) + float(info["h_max"])) * 0.5
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(key) ^ grass_seed
	var transforms: Array[Transform3D] = []
	for n in range(instances_per_chunk):
		var wx := cx + rng.randf_range(-half, half)
		var wz := cz + rng.randf_range(-half, half)
		if rng.randf() > _grass_weight(wx, wz):
			continue
		transforms.append(_blade_transform(Vector3(wx, y, wz), Vector3.UP,
			rng.randf() * TAU, rng.randf_range(min_scale, max_scale)))
	var mmi := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in range(transforms.size()):
		mm.set_instance_transform(i, transforms[i])
	mmi.multimesh = mm
	if grass_material != null:
		mmi.material_override = grass_material
	add_child(mmi)   # no owner -> not serialised into the .tscn
	return mmi

func _clear_editor_preview() -> void:
	for key in _preview.keys():
		var n: Node = _preview[key]
		if is_instance_valid(n):
			n.free()
	_preview.clear()
