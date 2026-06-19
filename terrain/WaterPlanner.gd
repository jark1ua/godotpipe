@tool
extends Node3D
## Places water on the terrain: one sea plane at sea level (follows the player), a
## clipped plane for every inland lake, and a flowing ribbon for every river spill path
## found by tools/build_water_bodies.py.
##
## How it fits the project
## -----------------------
## The terrain streams, so the whole heightfield is never in memory at once. The
## OFFLINE tool tools/build_water_bodies.py reads the chunk meshes, runs a priority-
## flood depression-fill to work out where water pools, and writes:
##     terrain/water_bodies.json      sea level + per-lake { level, world bbox, mask }
##     terrain/water_masks/lake_*.png binary shoreline mask per lake
## This node just renders that result. Nothing here recomputes the basins, and no
## ArrayMesh is built at runtime (the terrain notes warn against per-chunk runtime
## mesh churn): the sea and lakes are plain PlaneMesh primitives created ONCE.
##
## Ocean
## -----
## A single big plane at y = sea_level, recentred on the player each frame (snapped to
## its own vertex grid so the world-space waves don't shimmer). Land is opaque and
## sits above sea level, so it draws in front of the translucent water — exact
## coastlines for free, no per-fragment work.
##
## Lakes
## -----
## One plane per lake, sized to the lake's bounding box at the lake's water level. Its
## material samples the lake's outline mask by world position and discards fragments
## outside the real shoreline (see water_body.gdshader), so a rectangular plane reads
## as the true lake shape. Distant lakes fade out via visibility range.
##
## Setup
## -----
##   1. Run `python3 tools/build_water_bodies.py` once (re-run after re-exporting the
##      terrain) and open the project so Godot imports the new masks.
##   2. Add this node (or instance scenes/Water.tscn) next to your TerrainStreamer and
##      set Player Path. The Water Material defaults (via Water.tscn) to a ShaderMaterial
##      on shaders/water_body.gdshader.

@export var player_path: NodePath
@export_file("*.json") var water_bodies_path: String = "res://terrain/water_bodies.json"
## Base water material; duplicated per lake to set its own mask + bbox. Defaults via
## Water.tscn to a ShaderMaterial on shaders/water_body.gdshader.
@export var water_material: Material

@export_group("Ocean")
@export var enable_ocean: bool = true
## Side length (m) of the player-following sea plane. Make it reach the fog/far plane.
@export var ocean_size: float = 4000.0
## Plane subdivisions per axis (vertices for the wave displacement). 200 -> 20 m grid
## on a 4 km plane. Higher = smoother waves, more verts.
@export var ocean_subdiv: int = 200
## Overrides the JSON sea level if not NAN. Leave as-is to use the file's value.
@export var sea_level_override: float = NAN

@export_group("Rivers")
## Render the flow-path rivers (polylines from build_water_bodies.py) as ribbons.
@export var enable_rivers: bool = true
## Distance (m) past which a river ribbon fades out (0 = never).
@export var river_view_distance: float = 1400.0
## Scroll speed of the flow highlight along each river (0 = still water).
@export var river_flow_speed: float = 0.35
## Metres of river length per flow-highlight repeat (smaller = denser bands).
@export var river_flow_tile: float = 10.0

@export_group("Lakes")
@export var enable_lakes: bool = true
## Target metres between lake-plane vertices (for the wave displacement). Each lake's
## subdivisions are derived from its size and this, capped by Max Lake Subdiv.
@export var lake_vertex_spacing_m: float = 12.0
@export var lake_max_subdiv: int = 64
## Distance (m) past which a lake plane fades out (0 = never; always drawn).
@export var lake_view_distance: float = 1800.0
## Grow each lake plane outward by this fraction of its bbox so the mask's edge cells
## aren't clipped by the plane border. Small (the mask does the real clipping).
@export var lake_bbox_padding: float = 0.04

var _player: Node3D = null
var _sea: MeshInstance3D = null
var _sea_level: float = 0.0
var _ocean_cell: float = 20.0
var _built: bool = false

func _ready() -> void:
	if Engine.is_editor_hint():
		# Build a static preview so the water is visible while dressing the scene.
		_build_all()
		return
	if not player_path.is_empty():
		_player = get_node_or_null(player_path) as Node3D
	if _player == null:
		_player = get_viewport().get_camera_3d()
		if _player != null:
			push_warning("WaterPlanner: player_path unresolved; falling back to active Camera3D.")
	_build_all()
	print("WaterPlanner ready: sea_level=%.1f, %d water node(s)." % [
		_sea_level, get_child_count()])

func _process(_delta: float) -> void:
	if _sea == null or _player == null:
		return
	# Recentre the sea on the player, snapped to the plane's own vertex spacing so each
	# vertex keeps landing on the same world xz — the world-space waves stay rock steady.
	var px := snappedf(_player.global_position.x, _ocean_cell)
	var pz := snappedf(_player.global_position.z, _ocean_cell)
	_sea.global_position = Vector3(px, _sea_level, pz)

func _build_all() -> void:
	if _built:
		return
	_built = true
	var doc := _load_bodies()
	_sea_level = float(doc.get("sea_level", 0.0)) if doc != null else 0.0
	if not is_nan(sea_level_override):
		_sea_level = sea_level_override
	if enable_ocean:
		_build_ocean()
	if enable_lakes and doc != null:
		for lake in doc.get("lakes", []):
			_build_lake(lake)
	if enable_rivers and doc != null:
		for river in doc.get("rivers", []):
			_build_river(river)

func _load_bodies() -> Dictionary:
	var f := FileAccess.open(water_bodies_path, FileAccess.READ)
	if f == null:
		push_warning("WaterPlanner: water bodies file not found (run tools/build_water_bodies.py): "
			+ water_bodies_path)
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}

func _build_ocean() -> void:
	var sub := maxi(1, ocean_subdiv)
	_ocean_cell = ocean_size / float(sub)
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(ocean_size, ocean_size)
	mesh.subdivide_width = sub
	mesh.subdivide_depth = sub
	_sea = MeshInstance3D.new()
	_sea.name = "Ocean"
	_sea.mesh = mesh
	_sea.position = Vector3(0.0, _sea_level, 0.0)
	# Big translucent plane: don't let it cast shadows or get frustum-culled by its
	# resting AABB as it slides under the camera.
	_sea.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sea.extra_cull_margin = ocean_size
	var mat := _material_for(false)
	if mat != null:
		_sea.material_override = mat
	add_child(_sea)

func _build_lake(lake: Dictionary) -> void:
	var min_x := float(lake["min_x"])
	var max_x := float(lake["max_x"])
	var min_z := float(lake["min_z"])
	var max_z := float(lake["max_z"])
	var level := float(lake["level"])
	var w := max_x - min_x
	var d := max_z - min_z
	if w <= 0.0 or d <= 0.0:
		return
	var pad_x := w * lake_bbox_padding
	var pad_z := d * lake_bbox_padding
	var sw := w + 2.0 * pad_x
	var sd := d + 2.0 * pad_z

	var mesh := PlaneMesh.new()
	mesh.size = Vector2(sw, sd)
	mesh.subdivide_width = clampi(int(sw / max(lake_vertex_spacing_m, 1.0)), 1, lake_max_subdiv)
	mesh.subdivide_depth = clampi(int(sd / max(lake_vertex_spacing_m, 1.0)), 1, lake_max_subdiv)

	var mi := MeshInstance3D.new()
	mi.name = "Lake_%s" % str(lake.get("id", 0))
	mi.mesh = mesh
	mi.position = Vector3((min_x + max_x) * 0.5, level, (min_z + max_z) * 0.5)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if lake_view_distance > 0.0:
		mi.visibility_range_end = lake_view_distance
		mi.visibility_range_end_margin = lake_view_distance * 0.15
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF

	var mat := _material_for(true)
	if mat is ShaderMaterial:
		var sm := mat as ShaderMaterial
		sm.set_shader_parameter("use_mask", true)
		sm.set_shader_parameter("mask_min", Vector2(min_x, min_z))
		sm.set_shader_parameter("mask_max", Vector2(max_x, max_z))
		var tex := _load_mask(String(lake.get("mask", "")))
		if tex != null:
			sm.set_shader_parameter("mask_tex", tex)
	if mat != null:
		mi.material_override = mat
	add_child(mi)

# Build one river as a flat ribbon following its baked centreline (points carry world
# x,y,z + width). One ArrayMesh per river, built once at startup — bounded work, not the
# per-chunk streaming churn the terrain notes warn against.
func _build_river(river: Dictionary) -> void:
	var pts: Array = river.get("points", [])
	if pts.size() < 2:
		return
	var n := pts.size()
	var p := PackedVector3Array()
	var hw := PackedFloat32Array()
	p.resize(n)
	hw.resize(n)
	for i in range(n):
		var e: Array = pts[i]
		p[i] = Vector3(float(e[0]), float(e[1]), float(e[2]))
		hw[i] = float(e[3]) * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var left := PackedVector3Array()
	var right := PackedVector3Array()
	var vdist := PackedFloat32Array()
	left.resize(n); right.resize(n); vdist.resize(n)
	var run := 0.0
	for i in range(n):
		var fwd: Vector3
		if i == 0:
			fwd = p[1] - p[0]
		elif i == n - 1:
			fwd = p[n - 1] - p[n - 2]
		else:
			fwd = p[i + 1] - p[i - 1]
		fwd.y = 0.0
		if fwd.length() < 1e-4:
			fwd = Vector3(0, 0, 1)
		fwd = fwd.normalized()
		var perp := Vector3(-fwd.z, 0.0, fwd.x)   # horizontal, across the channel
		left[i] = p[i] + perp * hw[i]
		right[i] = p[i] - perp * hw[i]
		if i > 0:
			run += p[i].distance_to(p[i - 1])
		vdist[i] = run / maxf(river_flow_tile, 0.01)
	for i in range(n - 1):
		_ribbon_quad(st, left[i], right[i], right[i + 1], left[i + 1], vdist[i], vdist[i + 1])
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.name = "River_%s" % str(river.get("id", 0))
	mi.mesh = st.commit()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if river_view_distance > 0.0:
		mi.visibility_range_end = river_view_distance
		mi.visibility_range_end_margin = river_view_distance * 0.15
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	var mat := _material_for(false)
	if mat is ShaderMaterial:
		(mat as ShaderMaterial).set_shader_parameter("flow_speed", river_flow_speed)
	if mat != null:
		mi.material_override = mat
	add_child(mi)

func _ribbon_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		v0: float, v1: float) -> void:
	# a,b = this cross-section (left,right at v0); d,c = next (left,right at v1).
	var uvs := [Vector2(0, v0), Vector2(1, v0), Vector2(1, v1), Vector2(0, v1)]
	var pv := [a, b, c, d]
	for idx in [0, 1, 2, 0, 2, 3]:
		st.set_uv(uvs[idx])
		st.add_vertex(pv[idx])

# A per-instance material copy (lakes each need their own mask + bbox uniforms).
func _material_for(is_lake: bool) -> Material:
	if water_material == null:
		return null
	var m := water_material.duplicate() as Material
	if m is ShaderMaterial:
		(m as ShaderMaterial).set_shader_parameter("use_mask", is_lake)
	return m

func _load_mask(rel: String) -> Texture2D:
	if rel.is_empty():
		return null
	# Paths in the JSON are relative to terrain/.
	var path := "res://terrain/".path_join(rel)
	if ResourceLoader.exists(path):
		return load(path) as Texture2D
	push_warning("WaterPlanner: lake mask missing (re-import after building): " + path)
	return null
