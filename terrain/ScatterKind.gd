@tool
class_name ScatterKind
extends Resource
## One kind of scattered object (rocks, boulders, trees, shrubs, …) for
## terrain/ObjectScatterer.gd. Data-driven so you can add/retune kinds — and swap in
## your real models — entirely in the inspector, no code.
##
## Each kind points at a PackedScene (a placeholder LOD scene ships under
## scenes/scatter/; replace its meshes with your asset and keep the LOD wiring). The
## scatterer places it only where the terrain control map reads one of `groups` (e.g.
## boulders on "rock", reeds on "gravel" near water), scattered deterministically per
## chunk so a field reproduces exactly when you revisit it.

## Label (debug only).
@export var name: String = "object"
## The scene to instance. Ship a placeholder; drop your own .glb/scene in to replace it.
## Give it discrete LODs via GeometryInstance3D visibility ranges (see scenes/scatter/*).
@export var scene: PackedScene
## Terrain control-map groups this spawns on (grass/rock/snow/sand/forest/gravel/wet/
## special). Empty = any ground. Probability follows how much of the texel is that group.
@export var groups: PackedStringArray = PackedStringArray()

## Candidate placements tried per chunk before the group/slope/water gates thin them out.
## Keep modest — these are scene instances, heavier than grass. Trees/boulders: sparse.
@export var density: int = 24
@export var min_scale: float = 0.8
@export var max_scale: float = 1.4
## Max ground slope (deg) it will sit on — boulders cling to steeper ground than shrubs.
@export_range(0.0, 90.0) var max_slope_deg: float = 35.0
## How much it tilts to match the ground normal (0 upright, 1 fully laid along slope).
@export_range(0.0, 1.0) var align_to_normal: float = 0.15
## Random yaw about up (off for things with a "front", e.g. a billboard you pre-face).
@export var random_yaw: bool = true
## Sink (+) or raise (−) the base this many metres so it doesn't hover/float on bumps.
@export var y_offset: float = 0.0

## Placement rule:
##   "land"       normal ground; skips ground under the water surface if avoid_water.
##   "water_edge" only the shoreline band — ground within `water_band` m of the water
##                surface (reeds/cattails). Needs the WaterMap autoload.
@export_enum("land", "water_edge") var placement: String = "land"
## Skip ground below the water surface (land kinds). No-op without WaterMap.
@export var avoid_water: bool = true
## Half-width (m) of the shoreline band for placement == "water_edge".
@export var water_band: float = 1.2

## Per-kind seed offset so different kinds don't scatter in correlated positions.
@export var seed_offset: int = 0
