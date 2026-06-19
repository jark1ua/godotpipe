extends Node
## Global water lookup (autoload singleton: /root/WaterMap).
##
## Answers "is there water at this world point, and what is its surface level?" so any
## system can branch on it WITHOUT needing the streamed terrain in memory:
##   * GrassScatterer skips blades whose ground sits below the water surface.
##   * Lake/river SHORE detection (in_lake / near_water) can drive pebble texturing.
##   * Buoyancy / swimming physics later can read water_level_at() + is_submerged().
##
## Data is the offline result of tools/build_water_bodies.py:
##   sea_level                          the global ocean surface (y = sea_level)
##   terrain/water_bodies.json + masks  per inland lake: level + world bbox + outline
##
## The sea is treated as a global surface at sea_level (water exists wherever the
## ground is below it); lakes contribute their own higher surface inside their outline.
## So water_level_at() returns the water SURFACE for a column; to test presence at a
## point, compare it against that point's ground height (is_submerged() does this).

@export_file("*.json") var water_bodies_path: String = "res://terrain/water_bodies.json"

var sea_level: float = 0.0
var _lakes: Array = []   # { level, min_x, max_x, min_z, max_z, img:Image, w, h }
var _loaded: bool = false

# Loaded lazily on the first query, so scenes with no water (title, menu) pay nothing.
func _load() -> void:
	if _loaded:
		return
	_loaded = true
	var f := FileAccess.open(water_bodies_path, FileAccess.READ)
	if f == null:
		push_warning("WaterMap: water bodies file not found (run tools/build_water_bodies.py): "
			+ water_bodies_path)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		push_warning("WaterMap: could not parse " + water_bodies_path)
		return
	var doc: Dictionary = parsed
	sea_level = float(doc.get("sea_level", 0.0))
	for lake in doc.get("lakes", []):
		var img: Image = null
		var path := "res://terrain/".path_join(String(lake.get("mask", "")))
		if ResourceLoader.exists(path):
			var tex := load(path) as Texture2D
			if tex != null:
				img = tex.get_image()
				# Imported textures come back VRAM/lossless-compressed; get_pixel() throws
				# "Can't get_pixel() on compressed image" on those. Decompress to a plain
				# format once here so the per-blade _mask_hit() lookups are safe & cheap.
				if img != null and img.is_compressed():
					img.decompress()
		_lakes.append({
			"level": float(lake["level"]),
			"min_x": float(lake["min_x"]), "max_x": float(lake["max_x"]),
			"min_z": float(lake["min_z"]), "max_z": float(lake["max_z"]),
			"img": img,
			"w": int(lake.get("mask_w", 1)), "h": int(lake.get("mask_h", 1)),
		})
	print("WaterMap ready: sea_level=%.1f, %d lake(s)." % [sea_level, _lakes.size()])

# Highest water surface level covering this column: sea_level everywhere, raised to a
# lake's level inside that lake's outline. (A column is only actually wet where the
# ground is below this — see is_submerged.)
func water_level_at(x: float, z: float) -> float:
	_load()
	var lvl := sea_level
	for l in _lakes:
		if x >= l["min_x"] and x <= l["max_x"] and z >= l["min_z"] and z <= l["max_z"]:
			if l["level"] > lvl and _mask_hit(l, x, z):
				lvl = l["level"]
	return lvl

# True if a point lies below the water surface for its column (i.e. underwater).
func is_submerged(pos: Vector3, margin: float = 0.0) -> bool:
	return pos.y < water_level_at(pos.x, pos.z) - margin

# True if (x, z) falls inside any lake's outline (regardless of ground height). Useful
# for shore/edge logic such as pebble texturing around lakes.
func in_lake(x: float, z: float) -> bool:
	_load()
	for l in _lakes:
		if x >= l["min_x"] and x <= l["max_x"] and z >= l["min_z"] and z <= l["max_z"]:
			if _mask_hit(l, x, z):
				return true
	return false

func _mask_hit(l: Dictionary, x: float, z: float) -> bool:
	var img: Image = l["img"]
	if img == null:
		return true   # mask missing (not imported yet) -> fall back to the bbox
	# Dictionary subscripts are Variant, so := can't infer a type here — annotate float.
	var u: float = (x - l["min_x"]) / maxf(l["max_x"] - l["min_x"], 1e-3)
	var v: float = (l["max_z"] - z) / maxf(l["max_z"] - l["min_z"], 1e-3)
	var px := clampi(int(u * float(l["w"] - 1)), 0, l["w"] - 1)
	var py := clampi(int(v * float(l["h"] - 1)), 0, l["h"] - 1)
	return img.get_pixel(px, py).r > 0.5
