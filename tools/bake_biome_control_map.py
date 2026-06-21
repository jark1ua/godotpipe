#!/usr/bin/env python3
"""Bake a terrain control map from the painted Azgaar biome map.

Pipeline context
----------------
The world was painted in Azgaar (discrete biome per cell), pushed through Gaea ->
Blender -> Godot. The biome COLOURS survive in the exported "Biomes ....png"; the
colour<->biome table is "Biomes data ....csv". This tool turns that painted map
into the 16-bit packed control map the terrain splat shader samples, so each biome
gets the right ground texture layer.

What it does
------------
1. Reads the biome palette from the CSV (hex colour -> Azgaar biome id).
2. Decodes the biome PNG and point-samples it onto a square RES x RES grid that
   matches the terrain's world UV (the same square the heightmap/geometry use).
3. Classifies every grid texel to the nearest palette colour, maps the biome id ->
   a texture layer index (BIOME_TO_LAYER), and packs base|overlay|blend.
4. Writes:
     terrain/terrain_control_map_16k.png   16-bit grayscale, R = packed/65535
     terrain/control_map_16k_layer_preview.png   debug colours per layer
     terrain/control_map_16k_biome_preview.png    resampled biome colours (orientation check)

Alignment (verify on your machine against terrain_heightmap_16k.png)
--------------------------------------------------------------------
- The Azgaar PNG is north-up, west-left, and was STRETCHED to a square for Gaea, so
  we resize (not crop) to RESxRES. Geometry derives from that square, so square
  biome map == terrain in UV space.
- The control-map convention is image TOP row = south, col0 = west (see
  control_map_layers.json). Azgaar is TOP = north, so we FLIP VERTICALLY (FLIP_V).
  If the baked map reads N-S mirrored vs the relief, toggle FLIP_V.
- Shader sampling: world_uv = (vertex.world_xz + half) / world_size.

Encoding (matches terrain/control_map_layers.json):
  V = base | (overlay<<5) | (blend_raw<<10)   # 15 bits
  base/overlay = layer index 0..31 ; blend_raw 0..31 -> overlay weight 0..0.5
This biome pass writes base only (overlay=0, blend=0): a solid layer per biome.
Slope/altitude overlays (rock on cliffs, snow up high) are a follow-up that needs
the heightmap; hooks are noted below.

Pure-Python (no numpy/Pillow), consistent with tools/exr_control_map.py. Uses PIL if
present (faster) else a built-in PNG decoder.
"""

import array
import glob
import itertools
import json
import os
import struct
import zlib

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # project root


# --- Config -----------------------------------------------------------------

def _find(pattern, fallback):
    hits = sorted(glob.glob(os.path.join(HERE, pattern)))
    return hits[0] if hits else os.path.join(HERE, fallback)

BIOME_PNG = _find("Biomes*.png", "Biomes.png")
BIOME_CSV = _find("Biomes*data*.csv", "Biomes data.csv")
LAYERS_JSON = os.path.join(HERE, "terrain", "control_map_layers.json")

OUT_CONTROL = os.path.join(HERE, "terrain", "terrain_control_map_16k.png")
OUT_LAYER_PREVIEW = os.path.join(HERE, "terrain", "control_map_16k_layer_preview.png")
OUT_BIOME_PREVIEW = os.path.join(HERE, "terrain", "control_map_16k_biome_preview.png")

RES = 2048           # control-map resolution (square). 2048 over 16 km ~= 7.8 m/texel.
FLIP_V = True        # Azgaar top=north -> control top=south. Toggle if N-S mirrored.
FLIP_H = False       # Azgaar left=west == control left=west.
WATER_DIST2 = 1600   # squared RGB distance beyond which a texel is "not a land biome"
                     # (ocean / lake / river / coastline stroke) -> WATER_LAYER.

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
WATER_LAYER = 13     # sand_fine_beach: a neutral placeholder for ocean/lake/river
                     # texels (mostly below sea level, hidden once water returns).


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


# --- PNG decode: sample source onto RES x RES of RGB ------------------------

def _png_chunks(data):
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    i = 8
    while i < len(data):
        ln = struct.unpack(">I", data[i:i + 4])[0]
        typ = data[i + 4:i + 8]
        yield typ, data[i + 8:i + 8 + ln]
        i += 12 + ln


def sample_rgb_grid(path, res, flip_v, flip_h):
    """Decode an 8-bit RGB(A) PNG and return a flat list of (r,g,b), res*res, row-major
    with row 0 = control-map TOP. Memory-light: only the sampled columns are
    reconstructed (exploiting the all-'Up'-filter layout when present)."""
    raw_file = open(path, "rb").read()
    W = H = bd = ct = None
    idat = bytearray()
    for typ, chunk in _png_chunks(raw_file):
        if typ == b"IHDR":
            W, H, bd, ct = struct.unpack(">IIBB", chunk[:10])
        elif typ == b"IDAT":
            idat += chunk
        elif typ == b"IEND":
            break
    assert bd == 8 and ct in (2, 6), "expected 8-bit RGB/RGBA PNG (got bd=%s ct=%s)" % (bd, ct)
    chan = 3 if ct == 2 else 4
    raw = zlib.decompress(bytes(idat))
    stride = W * chan
    line = 1 + stride  # filter byte + pixels
    filters = {raw[y * line] for y in range(H)}

    # source col/row indices for each output col/row (square resize == stretch)
    sx = [min(W - 1, round(xo * (W - 1) / (res - 1))) for xo in range(res)]
    syf = []  # source row per output row (output row 0 = control top)
    for yo in range(res):
        v = yo / (res - 1)            # 0..1 across output top->bottom
        src_v = (1.0 - v) if flip_v else v
        syf.append(min(H - 1, round(src_v * (H - 1))))
    if flip_h:
        sx = [W - 1 - x for x in sx]

    grid = [None] * (res * res)

    if filters == {2}:
        # All-'Up' filter: each column is the cumulative (mod 256) sum down its bytes,
        # and columns are independent -> reconstruct only the columns we sample.
        for xo in range(res):
            base = 1 + sx[xo] * chan  # byte offset of this column's R within a scanline
            cs = []
            for ch in range(3):
                strip = raw[base + ch::line]               # filtered bytes, all rows
                cs.append(list(itertools.accumulate(strip)))  # C-fast cumulative sum
            for yo in range(res):
                sy = syf[yo]
                grid[yo * res + xo] = (cs[0][sy] & 255, cs[1][sy] & 255, cs[2][sy] & 255)
    else:
        # General path: reconstruct full rows (handles None/Sub/Up/Average/Paeth),
        # keeping only the rows we sample. Correct for any re-export; slower.
        wanted = {}
        for yo, sy in enumerate(syf):
            wanted.setdefault(sy, []).append(yo)
        prev = bytearray(stride)
        cur = bytearray(stride)
        pos = 0
        for y in range(H):
            ft = raw[pos]; pos += 1
            row = raw[pos:pos + stride]; pos += stride
            _unfilter_row(ft, row, cur, prev, chan)
            if y in wanted:
                for yo in wanted[y]:
                    for xo in range(res):
                        b = sx[xo] * chan
                        grid[yo * res + xo] = (cur[b], cur[b + 1], cur[b + 2])
            prev, cur = cur, prev
    return grid, W, H


def _unfilter_row(ft, row, cur, prev, bpp):
    if ft == 0:
        cur[:] = row
    elif ft == 1:  # Sub
        for x in range(len(row)):
            a = cur[x - bpp] if x >= bpp else 0
            cur[x] = (row[x] + a) & 255
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


# --- Classify + pack --------------------------------------------------------

def classify_grid(grid, palette):
    """grid of (r,g,b) -> (packed array 'H', layer array 'B', stats dict)."""
    pal_rgb = [p[2] for p in palette]
    pal_layer = [p[3] for p in palette]
    memo = {}                       # exact colour -> (layer, is_water)
    packed = array.array("H", bytes(2 * len(grid)))
    layers = array.array("B", bytes(len(grid)))
    counts = {}
    for i, c in enumerate(grid):
        hit = memo.get(c)
        if hit is None:
            best = WATER_DIST2 + 1
            bl = WATER_LAYER
            for k, (pr, pg, pb) in enumerate(pal_rgb):
                d = (c[0] - pr) ** 2 + (c[1] - pg) ** 2 + (c[2] - pb) ** 2
                if d < best:
                    best = d; bl = pal_layer[k]
            is_water = best > WATER_DIST2
            layer = WATER_LAYER if is_water else bl
            hit = (layer, is_water)
            memo[c] = hit
        layer = hit[0]
        layers[i] = layer
        packed[i] = layer & 31           # base only; overlay=0, blend=0
        counts[layer] = counts.get(layer, 0) + 1
    return packed, layers, {"counts": counts, "distinct_colors": len(memo)}


# --- PNG encode -------------------------------------------------------------

def _write_png(path, width, height, bit_depth, color_type, raw_rows):
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))
    ihdr = struct.pack(">IIBBBBB", width, height, bit_depth, color_type, 0, 0, 0)
    comp = zlib.compress(bytes(raw_rows), 9)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", comp))
        f.write(chunk(b"IEND", b""))


def write_control_png16(path, packed, res):
    rows = bytearray()
    for y in range(res):
        rows.append(0)  # filter None
        base = y * res
        for x in range(res):
            v = packed[base + x]          # 0..32767
            rows += struct.pack(">H", v)  # 16-bit big-endian (PNG order)
    _write_png(path, res, res, 16, 0, rows)


def write_rgb_png(path, res, pixel_fn):
    rows = bytearray()
    for y in range(res):
        rows.append(0)
        for x in range(res):
            r, g, b = pixel_fn(y * res + x)
            rows += bytes((r, g, b))
    _write_png(path, res, res, 8, 2, rows)


# distinct debug colours per layer index (so the preview is readable)
def _layer_color(idx):
    import colorsys
    h = (idx * 0.61803398875) % 1.0
    s = 0.55 + 0.30 * ((idx % 3) / 2.0)
    v = 0.45 + 0.45 * ((idx % 2))
    r, g, b = colorsys.hsv_to_rgb(h, s, v)
    return int(r * 255), int(g * 255), int(b * 255)


def main():
    print("biome png :", BIOME_PNG)
    print("biome csv :", BIOME_CSV)
    palette = load_palette(BIOME_CSV)
    print("palette   : %d biomes" % len(palette))
    for bid, name, rgb, layer in palette:
        print("   id=%2d %-26s #%02x%02x%02x -> layer %d" % (bid, name, rgb[0], rgb[1], rgb[2], layer))

    print("decoding + sampling %dx%d -> %dx%d ..." % (0, 0, RES, RES))
    grid, W, H = sample_rgb_grid(BIOME_PNG, RES, FLIP_V, FLIP_H)
    print("source    : %dx%d (aspect %.4f)" % (W, H, W / H))

    packed, layers, stats = classify_grid(grid, palette)
    print("distinct source colours sampled:", stats["distinct_colors"])
    layer_name = {L["index"]: L["name"] for L in json.load(open(LAYERS_JSON))["layers"]}
    total = RES * RES
    print("layer histogram (texel %):")
    for layer, n in sorted(stats["counts"].items(), key=lambda kv: -kv[1]):
        print("   layer %2d %-24s %6.2f%%" % (layer, layer_name.get(layer, "?"), 100.0 * n / total))

    write_control_png16(OUT_CONTROL, packed, RES)
    write_rgb_png(OUT_LAYER_PREVIEW, RES, lambda i: _layer_color(layers[i]))
    write_rgb_png(OUT_BIOME_PREVIEW, RES, lambda i: grid[i])
    print("wrote:")
    print("  ", OUT_CONTROL)
    print("  ", OUT_LAYER_PREVIEW)
    print("  ", OUT_BIOME_PREVIEW)


if __name__ == "__main__":
    main()
