extends Node
## Global water lookup (autoload singleton: /root/WaterMap).
##
## Minimal SEA-LEVEL model: the world's ocean is one global surface at y =
## sea_level, so a column is underwater wherever its ground sits below it. The
## scatterers query this to keep grass/props out of the sea (GrassScatterer's
## avoid_water, ObjectScatterer's water_edge / avoid_water gates).
##
## The old procedural lake/river basins (tools/build_water_bodies.py +
## terrain/water_bodies.json + per-lake masks) were removed: that water was
## flood-filled from the OLD 6 km heightfield and doesn't match the new map.
## Inland water (lakes, rivers) now comes from the painted biome map and will be
## reintroduced through the control map. Until then this answers sea-level only,
## which is the correct gate for the ocean surrounding the painted landmass.
##
## API kept stable for callers: water_level_at(), is_submerged(), in_lake().

## Sea surface height (Godot Y) is read from the terrain manifest's "sea_level_y"
## when present; the new 16 km export puts sea level at y = 0.
@export_file("*.json") var manifest_path: String = "res://terrain/terrain_manifest.json"
## Used when the manifest is missing or has no sea_level_y.
@export var default_sea_level: float = 0.0

var sea_level: float = 0.0
var _loaded: bool = false

# Resolved lazily on the first query, so scenes with no water (title, menu) pay
# nothing.
func _load() -> void:
	if _loaded:
		return
	_loaded = true
	sea_level = default_sea_level
	var f := FileAccess.open(manifest_path, FileAccess.READ)
	if f != null:
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		if parsed is Dictionary:
			sea_level = float((parsed as Dictionary).get("sea_level_y", default_sea_level))
	print("WaterMap ready: sea_level=%.1f (sea-only model)." % sea_level)

# Water surface height for a column. Sea level everywhere (no inland lakes now).
func water_level_at(_x: float, _z: float) -> float:
	_load()
	return sea_level

# True if a point lies below the sea surface (i.e. underwater).
func is_submerged(pos: Vector3, margin: float = 0.0) -> bool:
	_load()
	return pos.y < sea_level - margin

# No inland lakes in the sea-only model (kept so callers don't need to change).
func in_lake(_x: float, _z: float) -> bool:
	return false
