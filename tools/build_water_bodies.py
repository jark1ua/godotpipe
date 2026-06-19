#!/usr/bin/env python3
"""Compute where water collects on the terrain (offline) -> terrain/water_bodies.json.

What it does
------------
The terrain is streamed, so no single moment has the whole 6 km heightfield in the
engine. This tool reads the terrain chunk GLBs once, offline, rasterises their
surface into a coarse global heightfield, then works out where water would pool:

  1. Heightfield: max-pool every chunk surface vertex into an R x R grid over the
     6 km world (max-pool drops the 25 m skirts, which hang below the surface).
  2. Priority-Flood (Barnes et al. 2014): from the open boundaries -- the map edge
     AND every cell at/below sea level (the sea is an open outlet) -- flood inward,
     recording each cell's SPILL elevation: the level water must rise to before it
     escapes toward an outlet. depth = spill - terrain; depth > 0 == standing water.
  3. Bodies: connected components of standing-water cells. Components whose surface
     sits at sea level belong to the ocean (drawn at runtime as one y=0 plane and
     skipped here). The rest are inland LAKES -- each gets a flat surface level, a
     world bounding box and a small binary outline mask (PNG) for the runtime to
     clip its water plane to the real shoreline.
  4. Rivers: D8 flow directions on the pit-free (depression-filled) surface, then
     flow accumulation. Cells whose accumulated drainage exceeds a threshold form the
     spill paths off the lakes/high ground down to the sea. These are traced into
     polylines (with per-vertex width) the runtime renders as flowing-water ribbons.
  5. (optional, --paint-control-map) Stamp a pebble layer into the terrain control map
     EXR in a band around every water body (lake/sea shores + riverbeds). This makes
     the shoreline read as pebbles AND -- because grass only spawns on grass-group
     layers -- stops grass there automatically.

Output
------
  terrain/water_bodies.json      sea level + per-lake {level, bbox, mask} + rivers
  terrain/water_masks/lake_*.png 8-bit outline mask per lake (255 = water)
  terrain/terrain_control_map.exr (only with --paint-control-map) pebble shores painted in

Re-run whenever the terrain chunks are re-exported (this is a derived asset, like
tools/bake_chunk_normals.py -- keep it committed and idempotent).

Usage
-----
    python3 tools/build_water_bodies.py [--res 512] [--sea 0.0] [--min-area 8]
        [--shore-dilate 2] [--river-threshold 220] [--paint-control-map]
        [--pebble-band 2] [--pebble-layer 21]
        [--chunks DIR] [--manifest FILE] [--out FILE] [--masks DIR]
        [--control-map terrain/terrain_control_map.exr]
"""

import array
import glob
import heapq
import json
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bake_chunk_normals as glb  # reuse the GLB parser (parse_glb / accessor_view)


def read_positions(raw):
    """All POSITION vertices of a chunk GLB as a flat [x0,y0,z0,x1,...] float array."""
    js, bin_off, _ = glb.parse_glb(raw)
    out = []
    data = memoryview(raw)
    for mesh in js.get("meshes", []):
        for prim in mesh["primitives"]:
            if prim.get("mode", 4) != 4 or "POSITION" not in prim["attributes"]:
                continue
            base, stride, count, ncomp, cc, cs = glb.accessor_view(
                js, bin_off, prim["attributes"]["POSITION"])
            if stride == 12:  # tightly packed VEC3 floats -> bulk read
                a = array.array("f")
                a.frombytes(data[base:base + count * 12].tobytes())
                out.append(a)
            else:
                a = array.array("f")
                for i in range(count):
                    a.frombytes(data[base + i * stride: base + i * stride + 12].tobytes())
                out.append(a)
    return out


def build_heightfield(chunks_dir, manifest, res):
    half = manifest["world_size_m"] / 2.0
    world = manifest["world_size_m"]
    # filename -> chunk world origin
    pos_by_file = {}
    for c in manifest["chunks"]:
        pos_by_file[os.path.basename(c["file"])] = c["pos"]
    NEG = float("-inf")
    height = [NEG] * (res * res)
    files = sorted(glob.glob(os.path.join(chunks_dir, "*.glb")))
    if not files:
        raise SystemExit("No .glb chunks in " + chunks_dir)
    scale = (res - 1) / world
    for path in files:
        name = os.path.basename(path)
        ox, oy, oz = pos_by_file.get(name, (0.0, 0.0, 0.0))
        for verts in read_positions(open(path, "rb").read()):
            n = len(verts)
            for i in range(0, n, 3):
                wx = verts[i] + ox
                wy = verts[i + 1] + oy
                wz = verts[i + 2] + oz
                gx = int((wx + half) * scale + 0.5)
                gy = int((half - wz) * scale + 0.5)  # row 0 = south(+Z), like the control map
                if gx < 0: gx = 0
                elif gx >= res: gx = res - 1
                if gy < 0: gy = 0
                elif gy >= res: gy = res - 1
                idx = gy * res + gx
                if wy > height[idx]:
                    height[idx] = wy
    # Fill any cells no vertex landed in (rare at this resolution) by dilating the
    # mean of filled neighbours, so the flood has a complete grid to work on.
    _fill_holes(height, res, NEG)
    return height


def _fill_holes(height, res, sentinel):
    empty = [i for i, v in enumerate(height) if v == sentinel]
    guard = 0
    while empty and guard < 64:
        guard += 1
        still = []
        for idx in empty:
            y = idx // res
            x = idx % res
            s = 0.0
            c = 0
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    ny, nx = y + dy, x + dx
                    if 0 <= ny < res and 0 <= nx < res:
                        v = height[ny * res + nx]
                        if v != sentinel:
                            s += v
                            c += 1
            if c:
                height[idx] = s / c
            else:
                still.append(idx)
        empty = still
    for idx in empty:           # totally isolated (shouldn't happen) -> high wall
        height[idx] = 1e9


def priority_flood(height, res, sea_level):
    """Priority-flood the DEM. Returns (spill, order):
      spill  per-cell filled elevation (level water rises to before escaping an outlet)
      order  the sequence number each cell was settled in (small == nearer an outlet);
             used to route flow across flats (lakes / filled pits) toward their pour
             point, where the elevation alone gives no gradient."""
    INF = float("inf")
    spill = [INF] * (res * res)
    order = [0] * (res * res)
    visited = bytearray(res * res)
    heap = []
    for y in range(res):
        for x in range(res):
            idx = y * res + x
            border = x == 0 or y == 0 or x == res - 1 or y == res - 1
            ocean = height[idx] <= sea_level
            if border or ocean:
                lvl = sea_level if ocean else height[idx]
                spill[idx] = lvl
                visited[idx] = 1
                heapq.heappush(heap, (lvl, idx))
    seq = 0
    while heap:
        lvl, idx = heapq.heappop(heap)
        order[idx] = seq
        seq += 1
        y = idx // res
        x = idx % res
        for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < res and 0 <= nx < res:
                nidx = ny * res + nx
                if not visited[nidx]:
                    s = height[nidx]
                    if s < lvl:
                        s = lvl
                    spill[nidx] = s
                    visited[nidx] = 1
                    heapq.heappush(heap, (s, nidx))
    return spill, order


def find_lakes(height, spill, res, sea_level, depth_eps, lake_above_sea, min_area):
    """8-connected components of inland standing water (above sea level)."""
    is_lake = bytearray(res * res)
    for i in range(res * res):
        if spill[i] - height[i] > depth_eps and spill[i] > sea_level + lake_above_sea:
            is_lake[i] = 1
    seen = bytearray(res * res)
    lakes = []
    for start in range(res * res):
        if not is_lake[start] or seen[start]:
            continue
        stack = [start]
        seen[start] = 1
        cells = []
        while stack:
            idx = stack.pop()
            cells.append(idx)
            y = idx // res
            x = idx % res
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    if dy == 0 and dx == 0:
                        continue
                    ny, nx = y + dy, x + dx
                    if 0 <= ny < res and 0 <= nx < res:
                        nidx = ny * res + nx
                        if is_lake[nidx] and not seen[nidx]:
                            seen[nidx] = 1
                            stack.append(nidx)
        if len(cells) >= min_area:
            lakes.append(cells)
    return lakes


def dilate(cells, res, n):
    """Grow a set of cell indices outward by n cells (8-connected). Used to run the
    lake surface a little way UP INTO the surrounding terrain, so the flat water plane
    tucks under the rising shore and reads flush instead of leaving a gap at the rim
    (the same reason the sea looks flush: its plane runs under the land)."""
    s = set(cells)
    for _ in range(max(0, n)):
        add = []
        for idx in s:
            y = idx // res
            x = idx % res
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    ny, nx = y + dy, x + dx
                    if 0 <= ny < res and 0 <= nx < res:
                        add.append(ny * res + nx)
        s.update(add)
    return s


_N8 = ((-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1))


def flow_directions(spill, order, res):
    """D8 downstream link per cell on the pit-free surface. Each cell points to the
    neighbour with the lowest (spill, order); ties on spill drop toward the cell
    settled earlier (nearer the outlet), so flats drain the right way. -1 = an outlet
    (no lower neighbour)."""
    N = res * res
    down = [-1] * N
    for idx in range(N):
        y = idx // res
        x = idx % res
        best_key = (spill[idx], order[idx])
        best = -1
        for dy, dx in _N8:
            ny, nx = y + dy, x + dx
            if 0 <= ny < res and 0 <= nx < res:
                nidx = ny * res + nx
                key = (spill[nidx], order[nidx])
                if key < best_key:
                    best_key = key
                    best = nidx
        down[idx] = best
    return down


def flow_accumulation(down, spill, order, res):
    """Upstream cell count draining through each cell (its catchment, in cells)."""
    N = res * res
    acc = [1.0] * N
    # Process from highest (spill, order) to lowest so a cell is done before its outlet.
    for idx in sorted(range(N), key=lambda i: (spill[i], order[i]), reverse=True):
        d = down[idx]
        if d >= 0:
            acc[d] += acc[idx]
    return acc


def extract_rivers(acc, height, down, res, sea_level, threshold, lake_set, world, half,
                   min_w, max_w, surface_lift, min_points=4):
    """Trace river polylines down the flow network. River cells = drainage >= threshold,
    above sea level, not inside a lake. Walk each headwater downstream to the sea / a
    lake / an existing channel, emitting [x, y, z, width] points (y from the terrain)."""
    N = res * res
    river = set()
    for i in range(N):
        if acc[i] >= threshold and height[i] > sea_level and i not in lake_set:
            river.add(i)
    if not river:
        return river, []

    def wx(gx):
        return gx / (res - 1) * world - half

    def wz(gy):
        return half - gy / (res - 1) * world

    def width(i):
        w = min_w * (acc[i] / threshold) ** 0.5
        return round(max(min_w, min(max_w, w)), 2)

    def point(i):
        return [round(wx(i % res), 2), round(height[i] + surface_lift, 2),
                round(wz(i // res), 2), width(i)]

    indeg = {}
    for i in river:
        d = down[i]
        if d in river:
            indeg[d] = indeg.get(d, 0) + 1
    heads = [i for i in river if indeg.get(i, 0) == 0]
    heads.sort(key=lambda i: acc[i])   # small tributaries first; main stems absorb them

    consumed = set()
    polylines = []
    for hw in heads:
        if hw in consumed:
            continue
        pts = []
        c = hw
        while c is not None:
            pts.append(point(c))
            if c in consumed:        # joined an already-traced channel; stop at the junction
                break
            consumed.add(c)
            d = down[c]
            if d >= 0 and d in river:
                c = d
            else:
                if d >= 0:           # final step into the sea / a lake / the map edge
                    pts.append(point(d))
                c = None
        if len(pts) >= min_points:
            polylines.append(pts)
    return river, polylines


def paint_control_map(control_path, pebble_cells, res, world, half, pebble_layer):
    """Stamp `pebble_layer` into the control-map EXR for every world cell in
    pebble_cells (a set of 512-grid indices). Each coarse cell covers a few control
    texels; we set them to a solid pebble (base=layer, overlay=0, blend=0)."""
    import exr_control_map
    cm = exr_control_map.ControlMapEXR(control_path)
    cw, ch = cm.W, cm.H
    cell_m = world / (res - 1)

    def tx(wx):
        return max(0, min(cw - 1, int(round((wx + half) / world * (cw - 1)))))

    def ty(wz):
        return max(0, min(ch - 1, int(round((half - wz) / world * (ch - 1)))))

    packed = pebble_layer & 0x7FFF   # base = pebble, overlay 0, blend 0 -> pure pebble
    painted = 0
    for idx in pebble_cells:
        gx = idx % res
        gy = idx // res
        wx = gx / (res - 1) * world - half
        wz = half - gy / (res - 1) * world
        x0 = tx(wx - cell_m * 0.5)
        x1 = tx(wx + cell_m * 0.5)
        # z grows south; ty() is inverted, so the +z edge maps to the smaller row.
        y0 = ty(wz + cell_m * 0.5)
        y1 = ty(wz - cell_m * 0.5)
        for ty_ in range(y0, y1 + 1):
            for tx_ in range(x0, x1 + 1):
                cm.set_packed(tx_, ty_, packed)
                painted += 1
    cm.save(control_path)
    return painted


def write_gray_png(path, w, h, rows):
    def chunk(typ, data):
        return (struct.pack(">I", len(data)) + typ + data
                + struct.pack(">I", zlib.crc32(typ + data) & 0xffffffff))
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0)  # 8-bit grayscale, no interlace
    raw = bytearray()
    for row in rows:
        raw.append(0)  # filter: none
        raw.extend(row)
    idat = zlib.compress(bytes(raw), 9)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
                + chunk(b"IDAT", idat) + chunk(b"IEND", b""))


def main(argv):
    res = 512
    sea_level = 0.0
    min_area = 8
    depth_eps = 0.5
    lake_above_sea = 1.0
    shore_dilate = 2
    river_threshold = 220      # upstream cells (~0.03 km2) before a flow line is a river
    river_min_w = 4.0
    river_max_w = 26.0
    river_lift = 0.3           # raise the ribbon this far above the terrain sample
    paint_cm = False
    pebble_band = 4            # lake pebble shore (cells); needs > shore_dilate to clear
                              # the water plane's own overhang and stay visible on land
    river_band = 1            # pebble bank on each side of a river channel (cells)
    pebble_layer = 21          # control-map layer index to stamp (21 = pebble_field)
    chunks_dir = "terrain/chunks"
    manifest_path = "terrain/terrain_manifest.json"
    out_path = "terrain/water_bodies.json"
    masks_dir = "terrain/water_masks"
    control_path = "terrain/terrain_control_map.exr"
    a = argv[1:]
    i = 0
    while i < len(a):
        t = a[i]
        if t == "--res": i += 1; res = int(a[i])
        elif t == "--sea": i += 1; sea_level = float(a[i])
        elif t == "--min-area": i += 1; min_area = int(a[i])
        elif t == "--shore-dilate": i += 1; shore_dilate = int(a[i])
        elif t == "--river-threshold": i += 1; river_threshold = int(a[i])
        elif t == "--paint-control-map": paint_cm = True
        elif t == "--pebble-band": i += 1; pebble_band = int(a[i])
        elif t == "--river-band": i += 1; river_band = int(a[i])
        elif t == "--pebble-layer": i += 1; pebble_layer = int(a[i])
        elif t == "--chunks": i += 1; chunks_dir = a[i]
        elif t == "--manifest": i += 1; manifest_path = a[i]
        elif t == "--out": i += 1; out_path = a[i]
        elif t == "--masks": i += 1; masks_dir = a[i]
        elif t == "--control-map": i += 1; control_path = a[i]
        i += 1

    manifest = json.load(open(manifest_path))
    world = manifest["world_size_m"]
    half = world / 2.0
    cell_m = world / (res - 1)
    print("Reading %d chunks -> %dx%d heightfield (%.2f m/cell)..." % (
        len(manifest["chunks"]), res, res, cell_m))
    height = build_heightfield(chunks_dir, manifest, res)
    hmin = min(height)
    hmax = max(v for v in height if v < 1e8)
    print("Heightfield range: %.1f .. %.1f m. Flooding (sea level %.1f)..." % (hmin, hmax, sea_level))
    spill, order = priority_flood(height, res, sea_level)

    sea_set = set(i for i in range(res * res)
                  if spill[i] - height[i] > depth_eps and spill[i] <= sea_level + lake_above_sea)
    lakes = find_lakes(height, spill, res, sea_level, depth_eps, lake_above_sea, min_area)
    lakes.sort(key=len, reverse=True)
    lake_set = set()
    for cells in lakes:
        lake_set.update(cells)
    print("Sea/ocean covers ~%d cells (%.1f km2). Found %d inland lake(s) >= %d cells." % (
        len(sea_set), len(sea_set) * cell_m * cell_m / 1e6, len(lakes), min_area))

    print("Routing flow (D8) and tracing rivers (threshold %d cells)..." % river_threshold)
    down = flow_directions(spill, order, res)
    acc = flow_accumulation(down, spill, order, res)
    river_set, rivers = extract_rivers(acc, height, down, res, sea_level, river_threshold,
                                       lake_set, world, half, river_min_w, river_max_w, river_lift)
    print("Rivers: %d cell(s) of channel traced into %d polyline(s)." % (len(river_set), len(rivers)))

    if not os.path.isdir(masks_dir):
        os.makedirs(masks_dir)

    def world_x(gx):
        return gx / (res - 1) * world - half

    def world_z(gy):
        return half - gy / (res - 1) * world

    bodies = []
    for li, cells in enumerate(lakes):
        level = max(spill[c] for c in cells)
        # The surface level comes from the true water cells; the rendered/queried mask
        # is dilated so the water runs up into the shore and sits flush (no rim gap).
        mask_cells = dilate(cells, res, shore_dilate)
        xs = [c % res for c in mask_cells]
        ys = [c // res for c in mask_cells]
        min_gx, max_gx = min(xs), max(xs)
        min_gy, max_gy = min(ys), max(ys)
        mw = max_gx - min_gx + 1
        mh = max_gy - min_gy + 1
        rows = [bytearray(mw) for _ in range(mh)]
        for c in mask_cells:
            rows[(c // res) - min_gy][(c % res) - min_gx] = 255
        mask_name = "lake_%03d.png" % li
        write_gray_png(os.path.join(masks_dir, mask_name), mw, mh, rows)
        # World bbox. row min_gy = south (max z); row max_gy = north (min z).
        bodies.append({
            "id": li,
            "level": round(level, 3),
            "area_cells": len(cells),
            "area_m2": round(len(cells) * cell_m * cell_m, 1),
            "min_x": round(world_x(min_gx), 3), "max_x": round(world_x(max_gx), 3),
            "min_z": round(world_z(max_gy), 3), "max_z": round(world_z(min_gy), 3),
            "mask": "water_masks/" + mask_name, "mask_w": mw, "mask_h": mh,
        })

    river_bodies = [{"id": ri, "points": pts} for ri, pts in enumerate(rivers)]

    doc = {
        "version": "1.1",
        "world_size_m": world,
        "grid_res": res,
        "cell_size_m": round(cell_m, 4),
        "sea_level": sea_level,
        "shore_dilate_cells": shore_dilate,
        "uv_mapping": ("u=(world_x+%g)/%g (east+); lake mask v=(max_z-world_z)/(max_z-min_z) "
                       "so mask row 0 = south(+Z), matching the control map. Mask is dilated "
                       "%d cell(s) past the waterline so the plane tucks under the shore."
                       % (half, world, shore_dilate)),
        "note": ("Sea/ocean is drawn at runtime as one plane at y=sea_level (land occludes it); "
                 "only inland lakes are listed here. Rivers are polylines of [x,y,z,width] the "
                 "runtime renders as ribbons. Re-run tools/build_water_bodies.py after "
                 "re-exporting the terrain chunks."),
        "lakes": bodies,
        "rivers": river_bodies,
    }
    json.dump(doc, open(out_path, "w"), indent=2)
    print("Wrote %s (%d lakes, %d rivers) and %d mask(s) in %s" % (
        out_path, len(bodies), len(river_bodies), len(bodies), masks_dir))

    if paint_cm:
        # Pebble = the visible shore of LAKES and RIVERS only (the ocean coast already
        # reads as sand). Lakes get a wider band (their water plane overhangs the shore
        # by shore_dilate cells, so pebble must reach past that); rivers get a thin bank.
        # Drop lake interiors and sea cells so we only repaint visible land + riverbeds.
        pebble_cells = (dilate(lake_set, res, pebble_band) | dilate(river_set, res, river_band))
        pebble_cells = pebble_cells - lake_set - sea_set
        print("Painting pebble layer %d into %s over %d shore/bed cell(s)..." % (
            pebble_layer, control_path, len(pebble_cells)))
        n = paint_control_map(control_path, pebble_cells, res, world, half, pebble_layer)
        print("Painted %d control-map texel(s). (EXR is the source the streamer loads; the "
              ".png twin is left untouched.)" % n)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
