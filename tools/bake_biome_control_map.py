#!/usr/bin/env python3
"""Bake a terrain control map from the painted Azgaar biome map (+ a Gaea water mask).

Pipeline context
----------------
The world was painted in Azgaar (discrete biome per cell), pushed through Gaea ->
Blender -> Godot. The biome COLOURS survive in the exported "Biomes ....png"; the
colour<->biome table is "Biomes data ....csv". A separate Gaea export, Adjust_Out.png,
is a binary land/water mask (the seas/ocean). This tool turns those into the 16-bit
packed control map the terrain splat shader samples, so each biome gets the right
ground texture layer, water gets a (submerged) shore layer, and biome boundaries blend.

What's faithful to the inputs (and what bit us before)
------------------------------------------------------
* ORIENTATION is verified against the ACTUAL render, not a comment. Despite the manifest
  `uv` note and the grass scatterer both claiming v top=south, the chunk UVs are top=NORTH
  (confirmed in-engine: the rendered landmass matched a vertically-mirrored preview). So
  image row 0 must hold NORTH data: Azgaar is north-up -> FLIP_V=False, and the Gaea mask
  is north-up too -> MASK_FLIP_V=False. (Two earlier bakes got this wrong: one applied the
  mask upside-down vs the biomes; the next flipped BOTH to top=south, which renders the
  whole map mirrored N<->S.) In the terrain's own frame (per-chunk hmin/hmax from
  terrain_manifest.json) water correlates with low ground at ~93%; biome-blue and
  mask-water agree at ~93%. check_orientation() re-checks this every run in the top=north
  frame.
* WATER comes from the MASK only (it matches the Gaea heightfield the chunks were built
  from). We do NOT widen water using the biome map's blue gradient — that anti-aliased
  ocean fringe used to over-paint ~12% of the LAND with beach sand. The only blue we read
  off the biome map on land is (a) a thin coastal fringe -> a natural beach, and (b)
  INLAND blue lines far from the sea -> rivers (see pebbles below).
* BLENDING uses the previous world's technique: every layer boundary is FEATHERED into
  the shader's height-blend by packing base|overlay|blend (overlay = the neighbouring
  layer, blend ramping to the 50/50 seam). Interior texels keep overlay=base, blend=0 (a
  no-op) so the shader never leaks layer 0 into solid regions. No hard biome edges.
* PEBBLES surround RIVERS, not the ocean. Rivers = inland biome-blue (blue in the biome
  PNG, NOT in the mask, and far from any mask-water). We paint pebble_field over the river
  course and a band around it, then feather it like everything else. The ocean (mask
  water) never gets pebbles.

Output format: EXR (NOT PNG)
----------------------------
The control map MUST be an .exr (32-bit float). The layer index is packed into the LOW
bits, and Godot truncates a 16-bit PNG to 8 bits keeping the HIGH byte -> every texel
reads 0 -> base layer 0 (rock) everywhere. We write the R channel of a 2048x2048 float
EXR via tools/exr_control_map.py, using the existing control-map EXR as a structural
template. The terrain_control_map.png twin is NOT updated and goes stale (the streamer
loads the EXR).

Encoding (terrain/control_map_layers.json):
  V = base | (overlay<<5) | (blend_raw<<10)         # 15 bits ; base/overlay = layer 0..31
  blend_weight = (blend_raw/31)*0.5                 # 0..0.5 = overlay fraction at a texel

Pure-Python (no numpy/Pillow), consistent with tools/exr_control_map.py.
"""

import argparse
import array
import glob
import itertools
import json
import os
import struct
import sys
import zlib
from collections import deque

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # project root
sys.path.insert(0, os.path.join(HERE, "tools"))
from exr_control_map import ControlMapEXR  # noqa: E402


# --- File discovery ---------------------------------------------------------

def _find(pattern, fallback):
    hits = sorted(glob.glob(os.path.join(HERE, pattern)))
    return hits[0] if hits else os.path.join(HERE, fallback)

BIOME_PNG = _find("[Bb]iomes*.png", "Biomes.png")
BIOME_CSV = _find("[Bb]iomes*data*.csv", "Biomes data.csv")
WATER_MASK = _find("[Aa]djust[_-]?[Oo]ut*.png", "Adjust_Out.png")  # binary land/water
LAYERS_JSON = os.path.join(HERE, "terrain", "control_map_layers.json")
MANIFEST_JSON = os.path.join(HERE, "terrain", "terrain_manifest.json")
TEMPLATE_EXR = os.path.join(HERE, "terrain", "terrain_control_map.exr")  # structure only

OUT_CONTROL_EXR = os.path.join(HERE, "terrain", "terrain_control_map_16k.exr")
OUT_LAYER_PREVIEW = os.path.join(HERE, "terrain", "control_map_16k_layer_preview.png")
OUT_BIOME_PREVIEW = os.path.join(HERE, "terrain", "control_map_16k_biome_preview.png")
OUT_NATURAL_PREVIEW = os.path.join(HERE, "terrain", "control_map_16k_natural_preview.png")

# Representative ground colour per layer NAME, so a preview can be eyeballed against the
# biome PNG / terrain_color.png. Only the layers this bake emits need an entry; others
# fall back to mid-grey.
LAYER_PREVIEW_RGB = {
    "sand_fine_beach":        (60, 110, 170),   # shown as water/coast blue (mostly submerged)
    "pebble_field":           (150, 150, 150),  # river pebbles
    "grass_lush_meadow":      (95, 150, 70),
    "grass_dry_dead":         (170, 165, 95),
    "heather_shrubland":      (120, 120, 95),
    "snow_fresh_powder":      (235, 240, 245),
    "scree_loose":            (140, 130, 115),
    "sand_dune":              (210, 190, 130),
    "forest_floor_conifer":   (40, 80, 50),
    "forest_floor_deciduous": (70, 110, 55),
    "fern_undergrowth":       (55, 120, 60),
    "swamp_bog":              (70, 95, 70),
}


# --- Config -----------------------------------------------------------------

RES = 2048           # control-map resolution (square); must match TEMPLATE_EXR.
WORLD_SIZE_M = 16000.0

# Orientation. CONFIRMED IN-ENGINE (the user compared the render to mirrored previews):
# the chunk UVs are top=NORTH (image row 0 renders at the NORTH edge), NOT top=south as
# the manifest `uv` comment and the grass scatterer claim. Azgaar is north-up, so NO
# vertical flip puts north at row 0; the Gaea mask is north-up too. (An earlier bake used
# FLIP_V/MASK_FLIP_V=True and rendered the whole map mirrored N<->S.) check_orientation()
# correlates against the heightfield in this top=north frame. Override per-run if a future
# re-export changes the convention: --flip-v / --mask-flip-v (and the -h variants).
FLIP_V = False       # biome PNG (Azgaar north-up) -> row 0 = north
FLIP_H = False       # west on the left (u=0 = west)
MASK_FLIP_V = False  # Gaea mask north-up -> row 0 = north (matches biome)
MASK_FLIP_H = False
MASK_WATER_BELOW = 0.5   # mask value (0..1) below this = water (black=water, white=land)

# Azgaar biome id -> terrain texture layer NAME (resolved to an index from the manifest,
# so a re-numbered layer table can't silently mis-paint). This table IS the whole
# "which texture per biome" decision -- edit freely.
BIOME_TO_LAYER_NAME = {
    1:  "sand_dune",                # Hot desert
    2:  "scree_loose",              # Cold desert (rocky/gravel desert)
    3:  "grass_dry_dead",           # Savanna
    4:  "grass_lush_meadow",        # Grassland
    5:  "forest_floor_deciduous",   # Tropical seasonal forest
    6:  "forest_floor_deciduous",   # Temperate deciduous forest
    7:  "fern_undergrowth",         # Tropical rainforest
    8:  "forest_floor_conifer",     # Temperate rainforest
    9:  "forest_floor_conifer",     # Taiga
    10: "heather_shrubland",        # Tundra
    11: "snow_fresh_powder",        # Glacier
    12: "swamp_bog",                # Wetland
}
BEACH_LAYER_NAME = "sand_fine_beach"   # ocean (submerged) + thin coastal fringe
RIVER_LAYER_NAME = "pebble_field"      # pebbles for river courses and their banks

# An ocean/river blue in the biome PNG: distinctly bluish AND not near-white (so the
# legitimate near-white glacier biome #d5e7eb is NOT swept up as water).
def is_ocean_blue(r, g, b):
    return b > r + 25 and b > g + 20 and max(r, g, b) < 205

# Feather + river widths, in METRES (converted to texels against WORLD_SIZE_M / RES).
FEATHER_M = 39.0        # half-width of a biome ecotone (each side of a boundary)
INLAND_M = 24.0         # blue this far from mask-water counts as a river, not coastal
PEBBLE_BAND_M = 31.0    # pebble band grown around the river course


# --- Palette (CSV) ----------------------------------------------------------

def load_palette(csv_path, name_to_index):
    """Return [((r,g,b), layer_index), ...] for the LAND biomes only."""
    pal = []
    with open(csv_path, newline="") as f:
        header = f.readline().strip().split(",")
        idx = {name: i for i, name in enumerate(header)}
        for line in f:
            line = line.strip()
            if not line:
                continue
            cols = line.split(",")
            bid = int(cols[idx["Id"]])
            hexc = cols[idx["Color"]].lstrip("#")
            rgb = (int(hexc[0:2], 16), int(hexc[2:4], 16), int(hexc[4:6], 16))
            lname = BIOME_TO_LAYER_NAME.get(bid)
            if lname is None:
                continue
            pal.append((rgb, name_to_index[lname]))
    return pal


def resolve_layers(layers_json):
    data = json.load(open(layers_json))
    name_to_index = {L["name"]: L["index"] for L in data["layers"]}
    index_to_name = {L["index"]: L["name"] for L in data["layers"]}
    return name_to_index, index_to_name, data


# --- PNG decode helpers -----------------------------------------------------

def _png_read(path):
    """Return (raw_idat_decompressed, W, H, channels, bit_depth)."""
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG: " + path
    i = 8
    W = H = bd = ct = None
    idat = bytearray()
    while i < len(data):
        ln = struct.unpack(">I", data[i:i + 4])[0]
        typ = data[i + 4:i + 8]
        chunk = data[i + 8:i + 8 + ln]
        i += 12 + ln
        if typ == b"IHDR":
            W, H, bd, ct = struct.unpack(">IIBB", chunk[:10])
        elif typ == b"IDAT":
            idat += chunk
        elif typ == b"IEND":
            break
    chan = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ct]
    return zlib.decompress(bytes(idat)), W, H, chan, bd


def _src_indices(n_src, res, flip):
    out = [min(n_src - 1, round(o * (n_src - 1) / (res - 1))) for o in range(res)]
    return [n_src - 1 - v for v in out] if flip else out


def _unfilter_row(ft, row, cur, prev, bpp):
    if ft == 0:
        cur[:] = row
    elif ft == 1:  # Sub
        for x in range(len(row)):
            cur[x] = (row[x] + (cur[x - bpp] if x >= bpp else 0)) & 255
    elif ft == 2:  # Up
        for x in range(len(row)):
            cur[x] = (row[x] + prev[x]) & 255
    elif ft == 3:  # Average
        for x in range(len(row)):
            a = cur[x - bpp] if x >= bpp else 0
            cur[x] = (row[x] + ((a + prev[x]) >> 1)) & 255
    elif ft == 4:  # Paeth
        for x in range(len(row)):
            a = cur[x - bpp] if x >= bpp else 0
            c = prev[x - bpp] if x >= bpp else 0
            b = prev[x]
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            cur[x] = (row[x] + pr) & 255
    else:
        raise ValueError("bad PNG filter %d" % ft)


def sample_rgb_grid(path, res, flip_v, flip_h):
    """8-bit RGB(A) PNG -> flat list of (r,g,b), res*res, row 0 = control TOP.
    Light-memory: with the all-'Up' export only the sampled columns are rebuilt."""
    raw, W, H, chan, bd = _png_read(path)
    assert bd == 8 and chan in (3, 4), "expected 8-bit RGB/RGBA"
    stride = W * chan
    line = 1 + stride
    filters = {raw[y * line] for y in range(H)}
    sx = _src_indices(W, res, flip_h)
    sy = _src_indices(H, res, flip_v)
    grid = [None] * (res * res)
    if filters == {2}:  # all 'Up': columns independent (cumulative sum down each column)
        for xo in range(res):
            base = 1 + sx[xo] * chan
            cs = [list(itertools.accumulate(raw[base + ch::line])) for ch in range(3)]
            for yo in range(res):
                s = sy[yo]
                grid[yo * res + xo] = (cs[0][s] & 255, cs[1][s] & 255, cs[2][s] & 255)
    else:               # general: reconstruct full rows, keep only sampled ones
        wanted = {}
        for yo, s in enumerate(sy):
            wanted.setdefault(s, []).append(yo)
        prev, cur = bytearray(stride), bytearray(stride)
        pos = 0
        for y in range(H):
            ft = raw[pos]; pos += 1
            _unfilter_row(ft, raw[pos:pos + stride], cur, prev, chan); pos += stride
            if y in wanted:
                for yo in wanted[y]:
                    for xo in range(res):
                        b = sx[xo] * chan
                        grid[yo * res + xo] = (cur[b], cur[b + 1], cur[b + 2])
            prev, cur = cur, prev
    return grid, W, H


def sample_gray16_grid(path, res, flip_v, flip_h):
    """16-bit grayscale PNG -> flat list of floats 0..1, res*res, row 0 = control TOP."""
    raw, W, H, chan, bd = _png_read(path)
    assert bd == 16 and chan == 1, "expected 16-bit grayscale mask"
    bpp = 2
    stride = W * bpp
    sx = _src_indices(W, res, flip_h)
    sy = _src_indices(H, res, flip_v)
    wanted = {}
    for yo, s in enumerate(sy):
        wanted.setdefault(s, []).append(yo)
    grid = [0.0] * (res * res)
    prev, cur = bytearray(stride), bytearray(stride)
    pos = 0
    for y in range(H):
        ft = raw[pos]; pos += 1
        _unfilter_row(ft, raw[pos:pos + stride], cur, prev, bpp); pos += stride
        if y in wanted:
            for yo in wanted[y]:
                base = yo * res
                for xo in range(res):
                    b = sx[xo] * 2
                    grid[base + xo] = ((cur[b] << 8) | cur[b + 1]) / 65535.0
        prev, cur = cur, prev
    return grid, W, H


# --- Spatial helpers (binary masks; row-major res*res bytearrays) ------------

def dist_to(mask, res, cap):
    """Capped 4-connected distance (in texels) to the nearest set texel of `mask`.
    Unreached texels keep the sentinel 255. cap < 255."""
    dist = bytearray(b"\xff" * (res * res))
    dq = deque()
    for i, m in enumerate(mask):
        if m:
            dist[i] = 0
            dq.append(i)
    while dq:
        p = dq.popleft()
        d = dist[p]
        if d >= cap:
            continue
        nd = d + 1
        y, x = divmod(p, res)
        if y > 0 and dist[p - res] > nd:
            dist[p - res] = nd; dq.append(p - res)
        if y < res - 1 and dist[p + res] > nd:
            dist[p + res] = nd; dq.append(p + res)
        if x > 0 and dist[p - 1] > nd:
            dist[p - 1] = nd; dq.append(p - 1)
        if x < res - 1 and dist[p + 1] > nd:
            dist[p + 1] = nd; dq.append(p + 1)
    return dist


def dilate(mask, res, r):
    """Square (Chebyshev) dilation by r texels, separable (two 1-D max passes)."""
    if r <= 0:
        return bytearray(mask)
    tmp = bytearray(res * res)
    for y in range(res):
        row = y * res
        run = -1  # x-distance back to the last set texel within the window
        for x in range(res):
            if mask[row + x]:
                run = 0
            elif run >= 0:
                run += 1
            tmp[row + x] = 1 if (0 <= run <= r) else 0
        run = -1
        for x in range(res - 1, -1, -1):
            if mask[row + x]:
                run = 0
            elif run >= 0:
                run += 1
            if 0 <= run <= r:
                tmp[row + x] = 1
    out = bytearray(res * res)
    for x in range(res):
        run = -1
        for y in range(res):
            i = y * res + x
            if tmp[i]:
                run = 0
            elif run >= 0:
                run += 1
            out[i] = 1 if (0 <= run <= r) else 0
        run = -1
        for y in range(res - 1, -1, -1):
            i = y * res + x
            if tmp[i]:
                run = 0
            elif run >= 0:
                run += 1
            if 0 <= run <= r:
                out[i] = 1
    return out


# --- Classify ---------------------------------------------------------------

def classify_land(grid, palette):
    """Per-texel nearest LAND-biome layer (memoised by exact RGB) + an ocean-blue flag."""
    pal_rgb = [p[0] for p in palette]
    pal_layer = [p[1] for p in palette]
    land = bytearray(len(grid))
    blue = bytearray(len(grid))
    memo = {}
    for i, c in enumerate(grid):
        hit = memo.get(c)
        if hit is None:
            best, bl = 1 << 30, pal_layer[0]
            for k in range(len(pal_rgb)):
                pr, pg, pb = pal_rgb[k]
                d = (c[0] - pr) ** 2 + (c[1] - pg) ** 2 + (c[2] - pb) ** 2
                if d < best:
                    best, bl = d, pal_layer[k]
            hit = (bl, 1 if is_ocean_blue(c[0], c[1], c[2]) else 0)
            memo[c] = hit
        land[i] = hit[0]
        blue[i] = hit[1]
    return land, blue, len(memo)


def feather(L, res, radius):
    """Feather every layer boundary into the shader's height-blend.

    Returns (overlay, blend_raw) arrays. A texel keeps base = L[texel]; near a boundary
    its overlay = the neighbouring (foreign) layer and blend_raw ramps 31 (0.5, at the
    seam) -> 0 (radius texels in). Interior texels get overlay = base, blend_raw = 0 (a
    no-op mix, so the shader never bleeds layer 0 into solid regions)."""
    n = res * res
    overlay = bytearray(L)               # default: overlay == base
    blend_raw = bytearray(n)             # default: 0
    bdist = bytearray(b"\xff" * n)
    dq = deque()
    # Seed: boundary texels (a 4-neighbour has a different layer). Foreign layer = the
    # majority differing neighbour (tie -> smallest index), so junctions are deterministic.
    for y in range(res):
        row = y * res
        for x in range(res):
            a = L[row + x]
            votes = {}
            if y > 0:
                b = L[row - res + x]
                if b != a: votes[b] = votes.get(b, 0) + 1
            if y < res - 1:
                b = L[row + res + x]
                if b != a: votes[b] = votes.get(b, 0) + 1
            if x > 0:
                b = L[row + x - 1]
                if b != a: votes[b] = votes.get(b, 0) + 1
            if x < res - 1:
                b = L[row + x + 1]
                if b != a: votes[b] = votes.get(b, 0) + 1
            if votes:
                p = row + x
                overlay[p] = min(votes, key=lambda k: (-votes[k], k))
                blend_raw[p] = 31
                bdist[p] = 0
                dq.append(p)
    # Propagate the foreign layer inward across the same-layer region, up to `radius`.
    inv = 1.0 / radius
    while dq:
        p = dq.popleft()
        d = bdist[p]
        if d >= radius - 1:
            continue
        nd = d + 1
        a = L[p]
        f = overlay[p]
        br = int(31 * (1.0 - nd * inv) + 0.5)
        y, x = divmod(p, res)
        if y > 0 and L[p - res] == a and bdist[p - res] > nd:
            bdist[p - res] = nd; overlay[p - res] = f; blend_raw[p - res] = br; dq.append(p - res)
        if y < res - 1 and L[p + res] == a and bdist[p + res] > nd:
            bdist[p + res] = nd; overlay[p + res] = f; blend_raw[p + res] = br; dq.append(p + res)
        if x > 0 and L[p - 1] == a and bdist[p - 1] > nd:
            bdist[p - 1] = nd; overlay[p - 1] = f; blend_raw[p - 1] = br; dq.append(p - 1)
        if x < res - 1 and L[p + 1] == a and bdist[p + 1] > nd:
            bdist[p + 1] = nd; overlay[p + 1] = f; blend_raw[p + 1] = br; dq.append(p + 1)
    return overlay, blend_raw


# --- PNG encode (previews only) ---------------------------------------------

def _write_png(path, width, height, bit_depth, color_type, raw_rows):
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))
    ihdr = struct.pack(">IIBBBBB", width, height, bit_depth, color_type, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", zlib.compress(bytes(raw_rows), 9)))
        f.write(chunk(b"IEND", b""))


def write_rgb_png(path, res, pixel_fn):
    rows = bytearray()
    for y in range(res):
        rows.append(0)
        for x in range(res):
            r, g, b = pixel_fn(y * res + x)
            rows += bytes((r, g, b))
    _write_png(path, res, res, 8, 2, rows)


def _layer_color(idx):
    import colorsys
    r, g, b = colorsys.hsv_to_rgb((idx * 0.61803398875) % 1.0,
                                  0.55 + 0.30 * ((idx % 3) / 2.0),
                                  0.45 + 0.45 * (idx % 2))
    return int(r * 255), int(g * 255), int(b * 255)


# --- EXR output -------------------------------------------------------------

def write_control_exr(packed, res):
    exr = ControlMapEXR(TEMPLATE_EXR)
    if exr.W != res or exr.H != res:
        raise SystemExit("TEMPLATE_EXR is %dx%d but RES=%d; need a matching template."
                         % (exr.W, exr.H, res))
    exr.write_all_packed(list(packed))   # R = packed/65535 ; indexed y*W + x
    exr.save(OUT_CONTROL_EXR)
    # round-trip verify: every base id must land in 0..31
    chk = ControlMapEXR(OUT_CONTROL_EXR).read_all_packed()
    bases = {v & 31 for v in chk[::997]}
    if not bases <= set(range(32)):
        raise SystemExit("EXR round-trip produced out-of-range base ids: %s" % sorted(bases))
    return sorted(bases)


# --- Orientation sanity (against the real terrain heightfield) --------------

def check_orientation(water, res):
    """Correlate mask-water with LOW terrain in the control map's TRUE render frame.

    Chunk UVs are top=NORTH (confirmed in-engine), so image row 0 renders at the NORTH
    edge: chunk i (i=0 = south, z=+half) maps to row (n-1-i)/(n-1)*(res-1); col j (j=0 =
    west) maps to row-major col j/(n-1)*(res-1). High % => the painted water sits on the
    low ground as the engine will sample it. Returns % agreement or None."""
    if not os.path.exists(MANIFEST_JSON):
        return None
    d = json.load(open(MANIFEST_JSON))
    n = d.get("n_chunks_side")
    chunks = d.get("chunks")
    if not n or not chunks:
        return None
    mid = [[None] * n for _ in range(n)]
    for c in chunks:
        mid[c["i"]][c["j"]] = (c["hmax"] + c["hmin"]) / 2.0
    flat = sorted(v for r in mid for v in r if v is not None)
    thr = flat[len(flat) // 2]
    ok = tot = 0
    for i in range(n):
        sy = min(res - 1, round((n - 1 - i) * (res - 1) / (n - 1)))   # row 0 = north
        for j in range(n):
            if mid[i][j] is None:
                continue
            sx = min(res - 1, round(j * (res - 1) / (n - 1)))
            tot += 1
            if water[sy * res + sx] == (mid[i][j] <= thr):
                ok += 1
    return 100.0 * ok / tot if tot else None


# --- Main -------------------------------------------------------------------

def main():
    global FLIP_V, FLIP_H, MASK_FLIP_V, MASK_FLIP_H
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--feather-m", type=float, default=FEATHER_M,
                    help="biome ecotone half-width in metres (more = softer/wider blend)")
    ap.add_argument("--inland-m", type=float, default=INLAND_M,
                    help="inland distance (m) past which biome-blue is a river, not coast")
    ap.add_argument("--pebble-band-m", type=float, default=PEBBLE_BAND_M,
                    help="pebble band width (m) grown around river courses")
    ap.add_argument("--no-pebbles", action="store_true", help="skip river pebbles")
    ap.add_argument("--no-feather", action="store_true", help="hard biome edges (debug)")
    # Orientation overrides (defaults are the confirmed top=north convention). Use these
    # if a future terrain re-export flips a UV axis.
    ap.add_argument("--flip-v", dest="flip_v", action="store_true", default=FLIP_V)
    ap.add_argument("--no-flip-v", dest="flip_v", action="store_false")
    ap.add_argument("--flip-h", dest="flip_h", action="store_true", default=FLIP_H)
    ap.add_argument("--no-flip-h", dest="flip_h", action="store_false")
    ap.add_argument("--mask-flip-v", dest="mask_flip_v", action="store_true", default=MASK_FLIP_V)
    ap.add_argument("--no-mask-flip-v", dest="mask_flip_v", action="store_false")
    ap.add_argument("--mask-flip-h", dest="mask_flip_h", action="store_true", default=MASK_FLIP_H)
    ap.add_argument("--no-mask-flip-h", dest="mask_flip_h", action="store_false")
    args = ap.parse_args()
    FLIP_V, FLIP_H = args.flip_v, args.flip_h
    MASK_FLIP_V, MASK_FLIP_H = args.mask_flip_v, args.mask_flip_h

    m_per_texel = WORLD_SIZE_M / RES
    feather_r = max(1, round(args.feather_m / m_per_texel))
    inland_d = max(1, min(254, round(args.inland_m / m_per_texel)))
    band_r = max(0, round(args.pebble_band_m / m_per_texel))

    name_to_index, index_to_name, _ = resolve_layers(LAYERS_JSON)
    BEACH = name_to_index[BEACH_LAYER_NAME]
    PEBBLE = name_to_index[RIVER_LAYER_NAME]
    palette = load_palette(BIOME_CSV, name_to_index)

    print("biome png :", os.path.basename(BIOME_PNG))
    print("water mask:", os.path.basename(WATER_MASK) if os.path.exists(WATER_MASK) else "(none)")
    print("texel = %.2f m ; feather=%d px  inland=%d px  pebble band=%d px"
          % (m_per_texel, feather_r, inland_d, band_r))

    grid, W, H = sample_rgb_grid(BIOME_PNG, RES, FLIP_V, FLIP_H)
    print("biome src : %dx%d (aspect %.4f) -> %dx%d" % (W, H, W / H, RES, RES))

    # Water = the Gaea mask (authoritative; matches the terrain heightfield).
    water = bytearray(RES * RES)
    if os.path.exists(WATER_MASK):
        mg, mw, mh = sample_gray16_grid(WATER_MASK, RES, MASK_FLIP_V, MASK_FLIP_H)
        for i, v in enumerate(mg):
            water[i] = 1 if v < MASK_WATER_BELOW else 0
        print("mask  src : %dx%d -> %dx%d ; water = %.1f%%"
              % (mw, mh, RES, RES, 100.0 * sum(water) / len(water)))
    pct = check_orientation(water, RES)
    if pct is not None:
        print("orientation: mask-water vs terrain low-ground = %.1f%% %s" % (
            pct, "(OK)" if pct >= 85 else "(LOW -> check FLIP_V/MASK_FLIP_V!)"))

    land, blue, ncolors = classify_land(grid, palette)
    print("biome colours: %d distinct" % ncolors)

    # Rivers = inland biome-blue (blue, on land, far from the sea). dist capped at inland_d:
    # texels still at the sentinel (255) are inland -> river; 1..inland_d = coastal fringe.
    river_core = bytearray(RES * RES)
    if not args.no_pebbles:
        dwater = dist_to(water, RES, inland_d)
        for i in range(RES * RES):
            if blue[i] and not water[i] and dwater[i] >= inland_d:
                river_core[i] = 1
        pebble = dilate(river_core, RES, band_r)
        n_river = sum(river_core)
        n_peb = sum(1 for i in range(RES * RES) if pebble[i] and not water[i])
        print("rivers    : core %.3f%% -> pebble (with band) %.3f%% of map"
              % (100.0 * n_river / (RES * RES), 100.0 * n_peb / (RES * RES)))
    else:
        pebble = bytearray(RES * RES)

    # Compose the crisp per-texel layer grid.
    L = bytearray(RES * RES)
    for i in range(RES * RES):
        if water[i]:
            L[i] = BEACH                       # ocean / sea (submerged)
        elif pebble[i] and not water[i]:
            L[i] = PEBBLE                       # river course + banks
        elif blue[i]:
            L[i] = BEACH                        # thin coastal fringe -> beach
        else:
            L[i] = land[i]                      # nearest land biome

    # Feather every boundary into base|overlay|blend (else hard edges).
    if args.no_feather:
        overlay = bytearray(L)
        blend_raw = bytearray(RES * RES)
    else:
        overlay, blend_raw = feather(L, RES, feather_r)

    packed = array.array("H", bytes(2 * RES * RES))
    for i in range(RES * RES):
        packed[i] = (L[i] & 31) | ((overlay[i] & 31) << 5) | ((blend_raw[i] & 31) << 10)

    # Stats.
    counts = {}
    for v in L:
        counts[v] = counts.get(v, 0) + 1
    total = RES * RES
    blended = sum(1 for b in blend_raw if b)
    print("layer histogram:")
    for layer, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        print("   layer %2d %-24s %6.2f%%" % (layer, index_to_name.get(layer, "?"),
                                              100.0 * n / total))
    print("feathered texels (overlay/blend non-zero): %.1f%%" % (100.0 * blended / total))

    bases = write_control_exr(packed, RES)
    write_rgb_png(OUT_LAYER_PREVIEW, RES, lambda i: _layer_color(L[i]))
    write_rgb_png(OUT_BIOME_PREVIEW, RES, lambda i: grid[i])

    # Natural-colour preview: representative ground colour per layer, with the SAME
    # base->overlay feather the shader applies, so the user can compare it directly to
    # the biome PNG and see both the layout and the blended boundaries.
    grey = (128, 128, 128)
    rep = [LAYER_PREVIEW_RGB.get(index_to_name.get(idx), grey) for idx in range(32)]

    def natural(i):
        bc = rep[L[i]]
        oc = rep[overlay[i]]
        t = (blend_raw[i] / 31.0) * 0.5
        return (int(bc[0] + (oc[0] - bc[0]) * t),
                int(bc[1] + (oc[1] - bc[1]) * t),
                int(bc[2] + (oc[2] - bc[2]) * t))
    write_rgb_png(OUT_NATURAL_PREVIEW, RES, natural)

    print("wrote (base ids present %s):" % bases)
    print("  ", OUT_CONTROL_EXR)
    print("  ", OUT_NATURAL_PREVIEW, "(representative colours + feather -- compare to biome PNG)")
    print("  ", OUT_LAYER_PREVIEW, "(false-colour layers)")
    print("  ", OUT_BIOME_PREVIEW, "(resampled biome colours -- orientation check)")


if __name__ == "__main__":
    main()
