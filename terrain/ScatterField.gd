@tool
class_name ScatterField
extends RefCounted
## Advanced spatial distribution for scattered world content (trees, shrubs, grass,
## wildflowers). Replaces naive uniform-random scatter — which clumps, leaves bald
## patches and SEAMS at chunk edges — with an ecologically-structured field that
## produces dense forests, open plains and organic meadows.
##
## Three cheap layers compose the field. Every value is keyed on GLOBAL world
## coordinates (never on the chunk being built), so the field is fully deterministic
## AND seamless across the streamed chunk grid: two chunks sharing a boundary compute
## the same candidates and the same density, so a forest never breaks at a chunk edge.
##
##   1. Blue-noise placement (jittered grid). Instead of N independent uniform samples
##      per chunk (which clump and leave gaps), the world is tiled by a global grid of
##      `spacing` metres; each cell contributes ONE candidate, hash-jittered within the
##      cell. Even, natural spacing with no overlaps — the cheap, tileable cousin of
##      Poisson-disk sampling.
##   2. Region density (domain-warped fBm). A fractal noise field over world XZ decides
##      where the biome is dense vs absent: thresholded into stands (forest) with soft,
##      domain-warped (organic, non-circular) edges and interior clearings.
##   3. Grove clumping (optional second noise). Within a dense region, a higher-frequency
##      mask carves copses and lanes, so a forest reads as clustered stands rather than a
##      uniform fill — the Matérn / Neyman-Scott "cluster process" look, done as a mask.
##
## Usage (per kind, built once and reused for every chunk):
##   var field := ScatterField.make(kind.field_params(global_seed))
##   for cand in field.candidates(min_x, min_z, max_x, max_z):     # blue-noise points
##       var pos: Vector2 = cand[0]
##       var rng := field.cell_rng(cand[1], salt)                  # deterministic per cell
##       if rng.randf() > field.density_at(pos.x, pos.y) * biome_weight:
##           continue                                              # region/grove/biome gate
##       # ... raycast ground, slope/water gates, place ...
##
## Two kinds that share `density_seed` + `density_freq` (+ warp) sample the SAME region
## field; give one `density_invert = true` and they INTERLOCK — trees fill the stands,
## meadow flowers fill the plains between them, with a shared organic boundary.

# ---- blue-noise grid --------------------------------------------------------
var field_seed: int = 0   # master seed for the grid jitter + region/clump noise
## Mean distance between candidates (m); the jittered grid's cell size. Smaller = denser.
var spacing: float = 8.0
## 0 = rigid grid (rows), 1 = full-cell jitter (organic blue noise).
var jitter: float = 0.85

# ---- region density (domain-warped fBm) ------------------------------------
var _density: FastNoiseLite = null   # null => density disabled (density_at == 1.0)
## fBm value (0..1) below which the region is empty; higher = less coverage.
var threshold: float = 0.5
## Half-width of the soft edge around the threshold (stand fades to clearing).
var falloff: float = 0.12
## Spawn where the region is LOW instead of high (plains in the gaps between forests).
var invert: bool = false

# ---- grove clumping ---------------------------------------------------------
var _clump: FastNoiseLite = null     # null => no clumping
var clump_amount: float = 0.0        # 0 = even fill within the region, 1 = strong copses
var clump_threshold: float = 0.5

# Build a configured field from a params Dictionary (see ScatterKind.field_params).
static func make(p: Dictionary) -> ScatterField:
	var f := ScatterField.new()
	f.field_seed = int(p.get("seed", 0))
	f.spacing = maxf(0.25, float(p.get("spacing", 8.0)))
	f.jitter = clampf(float(p.get("jitter", 0.85)), 0.0, 1.0)
	f.threshold = clampf(float(p.get("density_threshold", 0.5)), 0.0, 1.0)
	f.falloff = maxf(0.001, float(p.get("density_falloff", 0.12)))
	f.invert = bool(p.get("density_invert", false))

	var dfreq := float(p.get("density_freq", 0.0))
	if dfreq > 0.0:
		f._density = FastNoiseLite.new()
		f._density.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		f._density.seed = f.field_seed
		f._density.frequency = dfreq
		f._density.fractal_type = FastNoiseLite.FRACTAL_FBM
		f._density.fractal_octaves = clampi(int(p.get("density_octaves", 4)), 1, 8)
		var warp := float(p.get("density_warp", 0.0))
		if warp > 0.0:
			# Domain warp pushes the sample point around before evaluating, so the
			# thresholded stand edges meander instead of forming smooth blobs/circles.
			f._density.domain_warp_enabled = true
			f._density.domain_warp_type = FastNoiseLite.DOMAIN_WARP_SIMPLEX
			f._density.domain_warp_amplitude = warp
			f._density.domain_warp_frequency = float(p.get("density_warp_freq", dfreq * 2.0))

	f.clump_amount = clampf(float(p.get("clump_amount", 0.0)), 0.0, 1.0)
	f.clump_threshold = clampf(float(p.get("clump_threshold", 0.5)), 0.0, 1.0)
	var cfreq := float(p.get("clump_freq", 0.0))
	if cfreq > 0.0 and f.clump_amount > 0.0:
		f._clump = FastNoiseLite.new()
		f._clump.noise_type = FastNoiseLite.TYPE_SIMPLEX
		# Decorrelate the clump field from the region field even when they share a seed.
		f._clump.seed = f.field_seed ^ 0x5bd1e995
		f._clump.frequency = cfreq
	return f

# Survival probability [0,1] at a world XZ: region density (thresholded, soft-edged,
# optionally inverted) times the optional grove-clumping mask. The caller multiplies
# this by its own biome/group weight and rolls a deterministic random number to accept.
func density_at(wx: float, wz: float) -> float:
	if _density == null:
		return 1.0
	var n := _density.get_noise_2d(wx, wz) * 0.5 + 0.5   # -1..1 -> 0..1
	if invert:
		n = 1.0 - n
	var p := smoothstep(threshold - falloff, threshold + falloff, n)
	if _clump != null:
		var c := _clump.get_noise_2d(wx, wz) * 0.5 + 0.5
		var mask := smoothstep(clump_threshold - 0.15, clump_threshold + 0.15, c)
		p *= lerp(1.0, mask, clump_amount)
	return clampf(p, 0.0, 1.0)

# Enumerate the blue-noise candidate points whose jittered position lands inside the
# half-open chunk box [min,max). Each cell is claimed by exactly ONE chunk (the one
# containing its candidate), so neighbouring chunks never double-place or leave a gap.
# Returns Array of [Vector2 pos, int cell_hash].
func candidates(min_x: float, min_z: float, max_x: float, max_z: float) -> Array:
	var out: Array = []
	var c0x := int(floor(min_x / spacing))
	var c1x := int(floor(max_x / spacing))
	var c0z := int(floor(min_z / spacing))
	var c1z := int(floor(max_z / spacing))
	for cx in range(c0x, c1x + 1):
		for cz in range(c0z, c1z + 1):
			var h := _cell_hash(cx, cz)
			var jx := 0.5 + (_hash01(h, 0x9e3779b1) - 0.5) * jitter
			var jz := 0.5 + (_hash01(h, 0x85ebca6b) - 0.5) * jitter
			var px := (float(cx) + jx) * spacing
			var pz := (float(cz) + jz) * spacing
			# Claim by candidate position so a cell straddling the boundary belongs to
			# whichever chunk actually contains its point (computed identically on both).
			if px < min_x or px >= max_x or pz < min_z or pz >= max_z:
				continue
			out.append([Vector2(px, pz), h])
	return out

# A deterministic RNG for one cell (yaw, scale, the accept roll). Salt with a per-kind
# value so different kinds sharing the grid still draw independent random streams.
func cell_rng(cell_hash: int, salt: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = (cell_hash ^ (salt * 2654435761)) & 0x7fffffffffff
	return rng

# Integer hash of a global cell index (+ field seed) -> 31-bit non-negative int.
func _cell_hash(cx: int, cz: int) -> int:
	var h := (field_seed * 374761393 + 0x9e3779b9) & 0x7fffffff
	h = (h + cx * 668265263) & 0x7fffffff
	h = (h ^ (h >> 13)) & 0x7fffffff
	h = (h + cz * 2246822519) & 0x7fffffff
	h = (h ^ (h >> 16)) & 0x7fffffff
	return h & 0x7fffffff

# Stable float in [0,1) from a hash and a salt (for the per-cell jitter offsets).
func _hash01(h: int, salt: int) -> float:
	var x := (h * 1103515245 + salt * 12345 + 1013904223) & 0x7fffffff
	x = (x ^ (x >> 15)) & 0x7fffffff
	return float(x % 1000003) / 1000003.0
