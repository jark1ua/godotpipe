#!/usr/bin/env python3
"""Bake a terrain control map from the painted Azgaar biome map (+ a water mask).

Pipeline context
----------------
The world was painted in Azgaar (discrete biome per cell), pushed through Gaea ->
Blender -> Godot. The biome COLOURS survive in the exported "Biomes ....png"; the
colour<->biome table is "Biomes data ....csv". A separate Gaea export, Adjust_Out.png,
is a binary land/water mask (ocean + rivers). This tool turns those into the 16-bit
packed control map the terrain splat shader samples, so each biome gets the right
ground texture layer and water areas get a shore layer.

Output format: EXR (NOT PNG)
----------------------------
The control map MUST be an .exr (32-bit float). The layer index is packed into the
LOW bits, and Godot truncates a 16-bit PNG to 8 bits keeping the HIGH byte -> every
texel reads 0 -> base layer 0 (rock) everywhere. The project already ships the
control map as EXR for exactly this reason (see CLAUDE.md). We write the R channel of
a 2048x2048 float EXR via tools/exr_control_map.py, using the existing control-map EXR
purely as a structural template.

What it does
------------
1. Reads the biome palette from the CSV (hex colour -> Azgaar biome id).
2. Decodes the biome PNG, point-samples onto a square RES x RES grid matching the
   terrain world UV (square stretch + vertical flip to top=south).
3. Decodes the Adjust_Out water mask (already top=south, square) the same way.
4. Per texel: water (mask) -> WATER_LAYER; else nearest biome colour -> BIOME_TO_LAYER.
5. Packs base|overlay|blend (base only here) and writes:
     terrain/terrain_control_map_16k.exr         <- the control map the shader samples
     terrain/control_map_16k_layer_preview.png   debug colours per layer
     terrain/control_map_16k_biome_preview.png    resampled biome colours (orientation)

Alignment (verify in-engine against terrain_heightmap_16k.png)
--------------------------------------------------------------
- Azgaar PNG is north-up -> FLIP_V puts south on top (control-map convention).
- Adjust_Out.png is from Gaea (top=south already) -> MASK_FLIP_V defaults False.
  The script prints how well the mask's water agrees with the biome map's ocean
  colour; if that agreement is low the mask is probably flipped -> toggle MASK_FLIP_V.
- Shader sampling: world_uv = (vertex.world_xz + half) / world_size.

Encoding (terrain/control_map_layers.json):
  V = base | (overlay<<5) | (blend_raw<<10)   # 15 bits ; base/overlay = layer 0..31
This biome pass writes base only (overlay=0, blend=0): a solid layer per biome.

Pure-Python (no numpy/Pillow), consistent with tools/exr_control_map.py.
"""

import array
import glob
import itertools
import json
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # project root
sys.path.insert(0, os.path.join(HERE, "tools"))
from exr_control_map import ControlMapEXR  # noqa: E402


# --- Config -----------------------------------------------------------------

def _find(pattern, fallback):
    hits = sorted(glob.glob(os.path.join(HERE, pattern)))
    return hits[0] if hits else os.path.join(HERE, fallback)

BIOME_PNG = _find("[Bb]iomes*.png", "Biomes.png")
BIOME_CSV = _find("[Bb]iomes*data*.csv", "Biomes data.csv")
WATER_MASK = _find("[Aa]djust[_-]?[Oo]ut*.png", "Adjust_Out.png")  # binary land/water
LAYERS_JSON = os.path.join(HERE, "terrain", "control_map_layers.json")
TEMPLATE_EXR = os.path.join(HERE, "terrain", "terrain_control_map.exr")  # structure only

OUT_CONTROL_EXR = os.path.join(HERE, "terrain", "terrain_control_map_16k.exr")
OUT_LAYER_PREVIEW = os.path.join(HERE, "terrain", "control_map_16k_layer_preview.png")
OUT_BIOME_PREVIEW = os.path.join(HERE, "terrain", "control_map_16k_biome_preview.png")

RES = 2048           # control-map resolution (square); must match TEMPLATE_EXR.
FLIP_V = True        # Azgaar top=north -> control top=south. Toggle if N-S mirrored.
FLIP_H = False       # Azgaar left=west == control left=west.
MASK_FLIP_V = False  # Adjust_Out is top=south (like the heightmap). Toggle if needed.
MASK_FLIP_H = False
MASK_WATER_BELOW = 0.5   # mask value (0..1) below this = water (black=water, white=land)
WATER_DIST2 = 1600   # fallback only (no mask): squared RGB dist beyond which a texel
                     # is treated as non-land -> WATER_LAYER.

# Azgaar biome id -> terrain texture layer index (see control_map_layers.json).
# Edit freely; this is the whole "which texture per biome" decision.
BIOME_TO_LAYER = {
    1:  15,  # Hot desert               -> sand_dune
    2:  20,  # Cold desert              -> scree_loose (rocky/gravel desert)
    3:  6,   # Savanna                  -> grass_dry_dead
    4:  5,   # Grassland                -> grass_lush_meadow
    5:  17,  # Tropical seasonal forest -> forest_floor_deciduous
    6:  17,  # Temperate deciduous      -> forest_floor_deciduous
    7:  18,  # Tropical rainforest      -> fern_undergrowth
    8:  16,  # Temperate rainforest     -> forest_floor_conifer
    9:  16,  # Taiga                    -> forest_floor_conifer
    10: 9,   # Tundra                   -> heather_shrubland
    11: 10,  # Glacier                  -> snow_fresh_powder
    12: 24,  # Wetland                  -> swamp_bog
}
WATER_LAYER = 13     # sand_fine_beach: neutral placeholder for ocean/river texels
                     # (mostly below sea level; replace once water rendering returns).


# --- Palette ----------------------------------------------------------------

def load_palette(csv_path):
    """Return [(biome_id, name, (r,g,b), layer_index), ...] from the Azgaar CSV."""
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
            name = cols[idx["Biome"]]
            hexc = cols[idx["Color"]].lstrip("#")
            rgb = (int(hexc[0:2], 16), int(hexc[2:4], 16), int(hexc[4:6], 16))
            layer = BIOME_TO_LAYER.get(bid, WATER_LAYER)
            pal.append((bid, name, rgb, layer))
    return pal


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
    """16-bit grayscale PNG -> flat list of floats 0..1, res*res, row 0 = control TOP.
    General unfilter (handles mixed filters); fine since the mask is small (1024^2)."""
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


# --- Classify + pack --------------------------------------------------------

def classify(grid, palette, water):
    """grid (r,g,b) + water (bool per texel or None) -> (packed 'H', layers 'B', stats)."""
    pal_rgb = [p[2] for p in palette]
    pal_layer = [p[3] for p in palette]
    memo = {}
    packed = array.array("H", bytes(2 * len(grid)))
    layers = array.array("B", bytes(len(grid)))
    counts = {}
    for i, c in enumerate(grid):
        hit = memo.get(c)
        if hit is None:
            best, bl = 1 << 30, pal_layer[0]
            for k, (pr, pg, pb) in enumerate(pal_rgb):
                d = (c[0] - pr) ** 2 + (c[1] - pg) ** 2 + (c[2] - pb) ** 2
                if d < best:
                    best, bl = d, pal_layer[k]
            # a colour far from EVERY land biome is an ocean/river blue the mask may
            # miss at the shoreline -> treat as water too.
            hit = (bl, best > WATER_DIST2)
            memo[c] = hit
        bl, color_water = hit
        is_water = color_water or (water is not None and water[i])
        layer = WATER_LAYER if is_water else bl
        layers[i] = layer
        packed[i] = layer & 31          # base only; overlay=0, blend=0
        counts[layer] = counts.get(layer, 0) + 1
    return packed, layers, {"counts": counts, "distinct_colors": len(memo)}


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


def main():
    print("biome png :", os.path.basename(BIOME_PNG))
    print("biome csv :", os.path.basename(BIOME_CSV))
    print("water mask:", os.path.basename(WATER_MASK) if os.path.exists(WATER_MASK) else "(none)")
    palette = load_palette(BIOME_CSV)

    grid, W, H = sample_rgb_grid(BIOME_PNG, RES, FLIP_V, FLIP_H)
    print("biome src : %dx%d (aspect %.4f) -> %dx%d" % (W, H, W / H, RES, RES))

    water = None
    if os.path.exists(WATER_MASK):
        mg, mw, mh = sample_gray16_grid(WATER_MASK, RES, MASK_FLIP_V, MASK_FLIP_H)
        water = [v < MASK_WATER_BELOW for v in mg]
        print("mask  src : %dx%d -> %dx%d ; water = %.1f%%"
              % (mw, mh, RES, RES, 100.0 * sum(water) / len(water)))
        # orientation sanity: how often does mask-water match biome ocean-colour?
        pal_rgb = [p[2] for p in palette]
        agree = 0
        for i, c in enumerate(grid):
            far = min((c[0] - r) ** 2 + (c[1] - g) ** 2 + (c[2] - b) ** 2
                      for r, g, b in pal_rgb) > WATER_DIST2
            if far == water[i]:
                agree += 1
        pct = 100.0 * agree / len(grid)
        print("mask/biome water agreement: %.1f%% %s" % (
            pct, "(OK)" if pct >= 75 else "(LOW -> mask may be flipped: toggle MASK_FLIP_V)"))

    packed, layers, stats = classify(grid, palette, water)
    layer_name = {L["index"]: L["name"] for L in json.load(open(LAYERS_JSON))["layers"]}
    total = RES * RES
    print("layer histogram:")
    for layer, n in sorted(stats["counts"].items(), key=lambda kv: -kv[1]):
        print("   layer %2d %-24s %6.2f%%" % (layer, layer_name.get(layer, "?"), 100.0 * n / total))

    bases = write_control_exr(packed, RES)
    write_rgb_png(OUT_LAYER_PREVIEW, RES, lambda i: _layer_color(layers[i]))
    write_rgb_png(OUT_BIOME_PREVIEW, RES, lambda i: grid[i])
    print("wrote (base ids present %s):" % bases)
    print("  ", OUT_CONTROL_EXR)
    print("  ", OUT_LAYER_PREVIEW)
    print("  ", OUT_BIOME_PREVIEW)


if __name__ == "__main__":
    main()
