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

Output
------
  terrain/water_bodies.json      sea level + per-lake {level, bbox, mask}
  terrain/water_masks/lake_*.png 8-bit outline mask per lake (255 = water)

Re-run whenever the terrain chunks are re-exported (this is a derived asset, like
tools/bake_chunk_normals.py -- keep it committed and idempotent).

Usage
-----
    python3 tools/build_water_bodies.py [--res 512] [--sea 0.0] [--min-area 8]
        [--chunks terrain/chunks] [--manifest terrain/terrain_manifest.json]
        [--out terrain/water_bodies.json] [--masks terrain/water_masks]
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
    """Return per-cell spill elevation (the level water rises to before escaping)."""
    INF = float("inf")
    spill = [INF] * (res * res)
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
    while heap:
        lvl, idx = heapq.heappop(heap)
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
    return spill


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
    chunks_dir = "terrain/chunks"
    manifest_path = "terrain/terrain_manifest.json"
    out_path = "terrain/water_bodies.json"
    masks_dir = "terrain/water_masks"
    a = argv[1:]
    i = 0
    while i < len(a):
        t = a[i]
        if t == "--res": i += 1; res = int(a[i])
        elif t == "--sea": i += 1; sea_level = float(a[i])
        elif t == "--min-area": i += 1; min_area = int(a[i])
        elif t == "--shore-dilate": i += 1; shore_dilate = int(a[i])
        elif t == "--chunks": i += 1; chunks_dir = a[i]
        elif t == "--manifest": i += 1; manifest_path = a[i]
        elif t == "--out": i += 1; out_path = a[i]
        elif t == "--masks": i += 1; masks_dir = a[i]
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
    spill = priority_flood(height, res, sea_level)

    sea_cells = sum(1 for i in range(res * res)
                    if spill[i] - height[i] > depth_eps and spill[i] <= sea_level + lake_above_sea)
    lakes = find_lakes(height, spill, res, sea_level, depth_eps, lake_above_sea, min_area)
    lakes.sort(key=len, reverse=True)
    print("Sea/ocean covers ~%d cells (%.1f km2). Found %d inland lake(s) >= %d cells." % (
        sea_cells, sea_cells * cell_m * cell_m / 1e6, len(lakes), min_area))

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

    doc = {
        "version": "1.0",
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
                 "only inland lakes are listed here. Re-run tools/build_water_bodies.py after "
                 "re-exporting the terrain chunks."),
        "lakes": bodies,
    }
    json.dump(doc, open(out_path, "w"), indent=2)
    print("Wrote %s (%d lakes) and %d mask(s) in %s" % (out_path, len(bodies), len(bodies), masks_dir))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
