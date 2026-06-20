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

# ---- advanced distribution (terrain/ScatterField.gd) -----------------------
## Placement algorithm:
##   "uniform"    legacy — `density` independent uniform-random samples per chunk.
##                Cheap, but clumps and leaves bald patches. Fine for sparse rocks/logs.
##   "blue_noise" advanced — an even-spaced jittered grid masked by a domain-warped
##                density field and optional grove clumping, for dense forests and
##                organic meadows. Ignores `density`; tune `spacing_m`, `density_*`,
##                `clump_*` instead. Seamless across chunk borders.
@export_enum("uniform", "blue_noise") var distribution: String = "uniform"

@export_group("Blue-noise distribution")
## Mean distance between candidates (m) — the jittered grid's cell size. Smaller =
## denser. Forest trees ~7-9 m; meadow shrubs/flowers ~3-5 m.
@export var spacing_m: float = 8.0
## 0 = rigid grid rows, 1 = fully jittered within each cell (natural blue noise).
@export_range(0.0, 1.0) var jitter: float = 0.85
## Region-density fBm frequency (cycles/m). 0 = fill the whole biome (no stands). Lower
## = bigger forests/meadows: ~0.0008 -> ~600 m stands, ~0.002 -> ~250 m copses.
@export var density_freq: float = 0.0
@export_range(1, 8) var density_octaves: int = 4
## fBm value below which the region is empty (higher = sparser coverage / more clearings).
@export_range(0.0, 1.0) var density_threshold: float = 0.5
## Soft-edge half-width around the threshold (forest fades to clearing over this band).
@export_range(0.001, 0.5) var density_falloff: float = 0.12
## Spawn where the region is LOW instead of high — e.g. a meadow kind that fills the
## plains BETWEEN forests. Pair with a forest kind that shares Density Seed + Density
## Freq to interlock the two perfectly.
@export var density_invert: bool = false
## Domain-warp amplitude (m) — warps the region edges so stands aren't blobby/circular.
## 0 = off. ~40-120 m reads natural.
@export var density_warp: float = 0.0
## Shared region seed. 0 = derive a unique seed from this kind. Set the SAME non-zero
## value on two kinds (same density_freq/warp) so they sample one region field; combine
## with density_invert to interlock a forest and its meadow.
@export var density_seed: int = 0
## Within-region clumping noise frequency (cycles/m). 0 = even fill. Higher than
## density_freq -> copses and lanes inside the stand.
@export var clump_freq: float = 0.0
## 0 = even fill within the region, 1 = strong copses/clearings.
@export_range(0.0, 1.0) var clump_amount: float = 0.0

# Parameters for ScatterField.make(). `global_seed` is the scatterer's scatter_seed.
func field_params(global_seed: int) -> Dictionary:
	var region_seed := density_seed if density_seed != 0 else (global_seed ^ (seed_offset * 2654435761))
	return {
		"seed": region_seed,
		"spacing": spacing_m,
		"jitter": jitter,
		"density_freq": density_freq,
		"density_octaves": density_octaves,
		"density_threshold": density_threshold,
		"density_falloff": density_falloff,
		"density_invert": density_invert,
		"density_warp": density_warp,
		"clump_freq": clump_freq,
		"clump_amount": clump_amount,
	}
