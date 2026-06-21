#!/usr/bin/env python3
"""Bake river ribbons for the streamed terrain from the painted Azgaar biome map.

Why this exists (vs. the old build_water_bodies.py)
---------------------------------------------------
The OLD 6 km world had no painted rivers, so tools/build_water_bodies.py *invented*
them: priority-flood the GLB heightfield, run D8 flow accumulation, trace the spill
paths. The NEW 16 km world is hand-painted in Azgaar, and the rivers are already drawn
into the biome map as thin INLAND BLUE lines (the same blue tools/bake_biome_control_map.py
turns into pebble shores). So here we don't route water at all — we just *trace what the
artist drew*:

  1. Rebuild the river-core mask exactly as the control-map baker does: biome-blue that is
     NOT ocean (Gaea mask) and lies inland (>= --inland-m from the sea). Top=NORTH frame,
     so the river world positions line up with the painted pebbles and the terrain UVs.
  2. Thin that mask to a 1-px skeleton (Zhang-Suen) and trace it into centreline polylines.
  3. Width per vertex from the painted line's local thickness (a distance transform).
  4. Height per vertex from the ground:
        --chunks <dir>   read the .glb chunks, max-pool the surface (drops skirts) -> EXACT
        --heightmap <p>  a 16-bit-grey Gaea heightfield mapped to [height_min,height_max]
        (default)        the per-chunk hmin/hmax in terrain_manifest.json -> COARSE (~254 m
                         cells). Good enough to see the rivers in the right place; RE-RUN
                         with --chunks on the machine that has the GLBs for flush ribbons.
     Heights are smoothed and forced monotonically downhill (water flows down), clamped to
     >= sea level, and sunk a touch so the ribbon tucks into the bank instead of floating.
  5. Write terrain/water_bodies.json: { sea_level, rivers:[{id, points:[[x,y,z,width]...]}] }
     which terrain/WaterPlanner.gd renders as one ribbon ArrayMesh per river (once, at
     startup) with shaders/water_body.gdshader (flow_speed>0 => the river path).

Pure-Python (no numpy/Pillow), reusing the PNG samplers in bake_biome_control_map.py and
the GLB parser in bake_chunk_normals.py.

Usage
-----
    python3 tools/build_rivers.py                      # coarse heights (manifest)
    python3 tools/build_rivers.py --chunks terrain/chunks   # exact heights (GLBs)
    python3 tools/build_rivers.py --heightmap terrain/height16.png
Re-run whenever the terrain / biome map is re-exported (a re-export reverts derived assets).
"""

import argparse
import json
import math
import os
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # project root
sys.path.insert(0, os.path.join(HERE, "tools"))

from bake_biome_control_map import (  # noqa: E402  (reuse the proven samplers/config)
    sample_rgb_grid, sample_gray16_grid, is_ocean_blue, dist_to, dilate,
    BIOME_PNG, WATER_MASK, RES, WORLD_SIZE_M, MASK_WATER_BELOW,
)

MANIFEST_JSON = os.path.join(HERE, "terrain", "terrain_manifest.json")
OUT_JSON = os.path.join(HERE, "terrain", "water_bodies.json")

# Defaults (metres). RES texel = WORLD_SIZE_M / RES (= 7.81 m at 2048/16 km).
INLAND_M = 24.0          # blue this far from ocean counts as a river (matches the baker)
MIN_RIVER_M = 180.0      # drop traced segments shorter than this (kills speckle stubs)
SIMPLIFY_M = 16.0        # Douglas-Peucker tolerance (fewer ribbon verts; ~2 texels)
MIN_WIDTH_M = 5.0        # thin painted lines render at least this wide (visible)
MAX_WIDTH_M = 46.0       # cap so a fat confluence blob doesn't become a lake
SMOOTH_PASSES = 2        # moving-average passes over each river's height profile
HEIGHT_BIAS = 0.20       # manifest fallback: hmin + bias*(hmax-hmin) (rivers sit low)
SINK_M = 0.4             # drop the surface this far so the ribbon tucks into the bank


# --- River-core mask (identical convention to bake_biome_control_map) --------

def river_core_mask(inland_m):
    """Return (core, res) — top=NORTH binary mask of inland river-blue texels."""
    res = RES
    m_per_texel = WORLD_SIZE_M / res
    inland_d = max(1, min(254, round(inland_m / m_per_texel)))
    grid, _, _ = sample_rgb_grid(BIOME_PNG, res, False, False)   # FLIP_V/H = False
    water = bytearray(res * res)
    if os.path.exists(WATER_MASK):
        mg, _, _ = sample_gray16_grid(WATER_MASK, res, False, False)
        for i, v in enumerate(mg):
            water[i] = 1 if v < MASK_WATER_BELOW else 0
    dwater = dist_to(water, res, inland_d)
    core = bytearray(res * res)
    for i in range(res * res):
        if not water[i] and dwater[i] >= inland_d and is_ocean_blue(*grid[i]):
            core[i] = 1
    return core, res


def erode(mask, res, r):
    """Chebyshev erosion by r texels (dilation of the complement)."""
    if r <= 0:
        return bytearray(mask)
    inv = bytearray(1 if not v else 0 for v in mask)
    inv = dilate(inv, res, r)
    return bytearray(0 if v else 1 for v in inv)


def close_mask(mask, res, r):
    """Morphological close (dilate then erode): fills 1-texel gaps and smooths the ragged,
    anti-aliased edges of the painted river lines so the skeleton doesn't sprout a spur at
    every bump."""
    return erode(dilate(mask, res, r), res, r)


def half_width_texels(core, res, cap=24):
    """For every core texel, the BFS distance (in texels) to the nearest non-core texel —
    i.e. the river's local half-width. Seeded from the core boundary, expanded inside the
    core only, so it is cheap (work ~ |core|, not the whole map)."""
    from collections import deque
    INF = 255
    d = bytearray([INF]) * (res * res)
    dq = deque()
    for i in range(res * res):
        if not core[i]:
            continue
        y, x = divmod(i, res)
        edge = (x == 0 or y == 0 or x == res - 1 or y == res - 1
                or not core[i - 1] or not core[i + 1]
                or not core[i - res] or not core[i + res])
        if edge:
            d[i] = 1
            dq.append(i)
    while dq:
        p = dq.popleft()
        dp = d[p]
        if dp >= cap:
            continue
        y, x = divmod(p, res)
        for q in ((p - 1 if x > 0 else -1), (p + 1 if x < res - 1 else -1),
                  (p - res if y > 0 else -1), (p + res if y < res - 1 else -1)):
            if q >= 0 and core[q] and d[q] > dp + 1:
                d[q] = dp + 1
                dq.append(q)
    return d


# --- Skeletonise (Zhang-Suen), walking only the foreground each pass ----------

_N8 = ((0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1))  # p2..p9 CW


def thin(mask, res):
    """Zhang-Suen thinning -> set of skeleton texel indices (1-px wide centrelines)."""
    g = bytearray(mask)
    fg = [i for i in range(res * res) if g[i]]

    def at(x, y):
        return g[y * res + x] if (0 <= x < res and 0 <= y < res) else 0

    while True:
        removed_any = False
        for step in (0, 1):
            kill = []
            for p in fg:
                if not g[p]:
                    continue
                y, x = divmod(p, res)
                n = [at(x + dx, y + dy) for dx, dy in _N8]  # p2..p9
                b = sum(n)
                if b < 2 or b > 6:
                    continue
                a = sum(1 for k in range(8) if n[k] == 0 and n[(k + 1) % 8] == 1)
                if a != 1:
                    continue
                p2, p3, p4, p5, p6, p7, p8, p9 = n
                if step == 0:
                    if p2 * p4 * p6 != 0 or p4 * p6 * p8 != 0:
                        continue
                else:
                    if p2 * p4 * p8 != 0 or p2 * p6 * p8 != 0:
                        continue
                kill.append(p)
            for p in kill:
                g[p] = 0
            if kill:
                removed_any = True
                fg = [p for p in fg if g[p]]
        if not removed_any:
            break
    return set(fg)


def prune_spurs(skel, res, min_branch):
    """Remove short dead-end branches (spurs) that join a junction within min_branch texels.
    These are thinning artefacts off the ragged painted lines; pruning them stops the trace
    from chopping a real channel into 2-pixel fragments at every spur."""
    skel = set(skel)
    for _ in range(20):
        deg = {p: len(_nbrs(p, res, skel)) for p in skel}
        remove = set()
        for ep in [p for p in skel if deg[p] == 1]:
            path = [ep]
            prev, cur = None, ep
            while True:
                nxt = [q for q in _nbrs(cur, res, skel) if q != prev and q not in remove]
                if len(nxt) != 1:
                    break                       # cur is a junction or dead end
                prev, cur = cur, nxt[0]
                if deg.get(cur, 0) >= 3:
                    break                       # reached a junction: stop (keep it)
                path.append(cur)
                if len(path) > min_branch:
                    break
            if len(path) <= min_branch and deg.get(cur, 0) >= 3:
                remove.update(path)             # short spur into a junction -> drop it
        if not remove:
            break
        skel -= remove
    return skel


def _nbrs(p, res, skel):
    y, x = divmod(p, res)
    out = []
    for dx, dy in _N8:
        nx, ny = x + dx, y + dy
        if 0 <= nx < res and 0 <= ny < res:
            q = ny * res + nx
            if q in skel:
                out.append(q)
    return out


def trace_polylines(skel, res):
    """Vectorise the raster skeleton into polylines by a greedy DIRECTIONAL march.

    Degree-based splitting fails on 8-connected skeletons: at every bend a diagonal
    shortcut makes a pixel look like a 3-way junction, chopping a smooth channel into
    thousands of 2-pixel fragments. Instead, from each pixel we walk to the neighbour that
    best CONTINUES the current heading (max direction dot product), consuming pixels as we
    go — so the march glides straight through those false junctions and only forks at real
    tributaries (which start their own polyline). Endpoints are preferred as starts."""
    skel = set(skel)
    deg = {p: len(_nbrs(p, res, skel)) for p in skel}
    consumed = set()
    lines = []

    def comp(a, b):  # direction (dx, dy) from a to b
        return (b % res) - (a % res), (b // res) - (a // res)

    for s in sorted(skel, key=lambda p: (deg[p] != 1, p)):   # endpoints first
        if s in consumed:
            continue
        if not [q for q in _nbrs(s, res, skel) if q not in consumed]:
            continue
        path = [s]
        consumed.add(s)
        prev, cur = None, s
        while True:
            cand = [q for q in _nbrs(cur, res, skel) if q not in consumed and q != prev]
            if not cand:
                break
            if prev is None:
                nxt = cand[0]
            else:
                dx, dy = comp(prev, cur)
                nxt = max(cand, key=lambda q: dx * comp(cur, q)[0] + dy * comp(cur, q)[1])
            path.append(nxt)
            consumed.add(nxt)
            prev, cur = cur, nxt
        if len(path) >= 2:
            lines.append(path)
    return lines


# --- Polyline simplify (iterative Douglas-Peucker; texel space) --------------

def rdp(points, eps):
    if len(points) < 3:
        return points[:]
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        i0, i1 = stack.pop()
        ax, ay = points[i0]
        bx, by = points[i1]
        dx, dy = bx - ax, by - ay
        seg = math.hypot(dx, dy) or 1.0
        dmax, idx = 0.0, -1
        for i in range(i0 + 1, i1):
            px, py = points[i]
            # perpendicular distance of p to segment a->b
            d = abs((px - ax) * dy - (py - ay) * dx) / seg
            if d > dmax:
                dmax, idx = d, i
        if dmax > eps and idx != -1:
            keep[idx] = True
            stack.append((i0, idx))
            stack.append((idx, i1))
    return [points[i] for i in range(len(points)) if keep[i]]


# --- Height sources ----------------------------------------------------------

class ManifestHeight:
    """Coarse fallback: bilinear over the per-chunk grid (hmin..hmax blended low)."""

    def __init__(self, bias):
        d = json.load(open(MANIFEST_JSON))
        self.n = int(d["n_chunks_side"])
        self.step = float(d["step_m"])
        self.center = int(d["center_index"])
        self.sea = float(d.get("sea_level_y", 0.0))
        self.h = [[None] * self.n for _ in range(self.n)]
        for c in d["chunks"]:
            # Floor hmin at sea level FIRST: a coastal chunk's hmin is the sea floor
            # (~-24 m), and anchoring a river there sinks it underwater. Clamping to sea
            # level keeps coastal rivers on the low land while inland valley floors (hmin
            # well above sea) are unchanged. Rivers sit low in the chunk -> small bias.
            lo = max(self.sea, c["hmin"])
            self.h[c["i"]][c["j"]] = lo + bias * (c["hmax"] - lo)
        # Fill any holes with a global mean so bilinear never hits None.
        vals = [v for r in self.h for v in r if v is not None]
        mean = sum(vals) / len(vals) if vals else 0.0
        for r in range(self.n):
            for cc in range(self.n):
                if self.h[r][cc] is None:
                    self.h[r][cc] = mean

    def _g(self, i, j):
        i = min(self.n - 1, max(0, i))
        j = min(self.n - 1, max(0, j))
        return self.h[i][j]

    def at(self, x, z):
        # world -> continuous chunk index (matches TerrainStreamer): j=x/step+center,
        # i=center - z/step (i grows toward north / -Z).
        jf = x / self.step + self.center
        iff = self.center - z / self.step
        j0, i0 = int(math.floor(jf)), int(math.floor(iff))
        tj, ti = jf - j0, iff - i0
        h00 = self._g(i0, j0); h01 = self._g(i0, j0 + 1)
        h10 = self._g(i0 + 1, j0); h11 = self._g(i0 + 1, j0 + 1)
        top = h00 + (h01 - h00) * tj
        bot = h10 + (h11 - h10) * tj
        return top + (bot - top) * ti


class GridHeight:
    """Exact: a max-pooled surface heightfield sampled bilinearly. Holes hold None and are
    nearest-filled after the pool. Used by both --chunks and --heightmap."""

    def __init__(self, gw, half):
        self.gw = gw
        self.half = half
        self.cell = (2.0 * half) / gw
        self.grid = [None] * (gw * gw)

    def _idx(self, x, z):
        # world -> grid cell. col grows east (+x); row grows north (-z) to match top=north.
        cx = int((x + self.half) / self.cell)
        cz = int((self.half - z) / self.cell)
        if 0 <= cx < self.gw and 0 <= cz < self.gw:
            return cz * self.gw + cx
        return -1

    def add(self, x, z, y):
        k = self._idx(x, z)
        if k >= 0 and (self.grid[k] is None or y > self.grid[k]):
            self.grid[k] = y       # max-pool drops the skirts (they hang below the surface)

    def finalize(self):
        # Nearest-fill empty cells so bilinear sampling never sees a hole (multi-pass grow).
        g = self.grid
        gw = self.gw
        holes = [k for k in range(gw * gw) if g[k] is None]
        guard = 0
        while holes and guard < 64:
            guard += 1
            nxt = []
            for k in holes:
                y, x = divmod(k, gw)
                acc, cnt = 0.0, 0
                for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < gw and 0 <= ny < gw and g[ny * gw + nx] is not None:
                        acc += g[ny * gw + nx]; cnt += 1
                if cnt:
                    g[k] = acc / cnt
                else:
                    nxt.append(k)
            holes = nxt
        for k in range(gw * gw):
            if g[k] is None:
                g[k] = 0.0

    def at(self, x, z):
        fx = (x + self.half) / self.cell
        fz = (self.half - z) / self.cell
        x0 = min(self.gw - 1, max(0, int(math.floor(fx))))
        z0 = min(self.gw - 1, max(0, int(math.floor(fz))))
        x1 = min(self.gw - 1, x0 + 1)
        z1 = min(self.gw - 1, z0 + 1)
        tx, tz = fx - x0, fz - z0
        g = self.grid
        h00 = g[z0 * self.gw + x0]; h01 = g[z0 * self.gw + x1]
        h10 = g[z1 * self.gw + x0]; h11 = g[z1 * self.gw + x1]
        top = h00 + (h01 - h00) * tx
        bot = h10 + (h11 - h10) * tx
        return top + (bot - top) * tz


def height_from_glbs(chunks_dir, gw):
    """Max-pool every chunk's surface verts into a gw x gw heightfield (drops skirts)."""
    from bake_chunk_normals import parse_glb, accessor_view, read_vec3
    import struct
    d = json.load(open(MANIFEST_JSON))
    half = float(d["half_m"])
    hf = GridHeight(gw, half)
    pos_by_file = {c["file"]: c["pos"] for c in d["chunks"]}
    files = sorted(f for f in os.listdir(chunks_dir) if f.lower().endswith(".glb"))
    if not files:
        raise SystemExit("no .glb files in " + chunks_dir)
    for name in files:
        ox, _oy, oz = pos_by_file.get(name, (0.0, 0.0, 0.0))
        raw = open(os.path.join(chunks_dir, name), "rb").read()
        js, bin_off, _ = parse_glb(raw)
        for mesh in js.get("meshes", []):
            for prim in mesh["primitives"]:
                attrs = prim.get("attributes", {})
                if "POSITION" not in attrs:
                    continue
                base, stride, count, _, _, _ = accessor_view(js, bin_off, attrs["POSITION"])
                for vx, vy, vz in read_vec3(raw, base, stride, count):
                    hf.add(ox + vx, oz + vz, vy)   # xz recentred + offset; y absolute
    hf.finalize()
    print("  GLB heightfield: %d chunks -> %dx%d grid (cell %.1f m)" % (
        len(files), gw, gw, hf.cell))
    return hf


def height_from_heightmap(path, gw):
    """16-bit grey PNG (0..1) mapped to [height_min_m, height_max_m] from the manifest."""
    d = json.load(open(MANIFEST_JSON))
    half = float(d["half_m"])
    hmin, hmax = float(d["height_min_m"]), float(d["height_max_m"])
    g16, w, h = sample_gray16_grid(path, gw, False, False)   # row 0 = north (top=north)
    hf = GridHeight(gw, half)
    for k, v in enumerate(g16):
        hf.grid[k] = hmin + v * (hmax - hmin)
    hf.finalize()
    print("  heightmap %s %dx%d -> %dx%d grid (h %.1f..%.1f)" % (
        os.path.basename(path), w, h, gw, gw, hmin, hmax))
    return hf


# --- Assemble rivers ---------------------------------------------------------

def smooth(vals, passes):
    for _ in range(passes):
        if len(vals) < 3:
            break
        out = vals[:]
        for i in range(1, len(vals) - 1):
            out[i] = (vals[i - 1] + vals[i] + vals[i + 1]) / 3.0
        vals = out
    return vals


def _isotonic_decreasing(ys):
    """Least-squares NON-INCREASING fit (pool-adjacent-violators). Unlike a running min it
    follows the samples closely — it only flattens runs that actually go uphill, instead of
    dragging the whole profile down to a single low sample."""
    val, cnt = [], []
    for y in ys:
        val.append(float(y))
        cnt.append(1)
        while len(val) > 1 and val[-2] < val[-1]:          # violation: should be >=
            nv = (val[-2] * cnt[-2] + val[-1] * cnt[-1]) / (cnt[-2] + cnt[-1])
            nc = cnt[-2] + cnt[-1]
            val[-2:], cnt[-2:] = [nv], [nc]
    out = []
    for v, c in zip(val, cnt):
        out.extend([v] * c)
    return out


def downhill(ys):
    """Make the river flow downhill: orient so index 0 is the higher (source) end, fit a
    monotonic descent, restore orientation. Removes small uphill back-flows from noisy
    height samples while keeping the real elevation change."""
    if len(ys) < 2:
        return ys
    flip = ys[0] < ys[-1]
    seq = list(reversed(ys)) if flip else list(ys)
    seq = _isotonic_decreasing(seq)
    return list(reversed(seq)) if flip else seq


def build(args):
    res = RES
    m_per_texel = WORLD_SIZE_M / res
    half = WORLD_SIZE_M * 0.5

    core, _ = river_core_mask(args.inland_m)
    n_core = sum(core)
    print("river-core texels: %d (%.3f%% of map)" % (n_core, 100.0 * n_core / (res * res)))
    if n_core == 0:
        raise SystemExit("no inland river-blue found — check the biome map / --inland-m")

    hw = half_width_texels(core, res)
    smoothed = close_mask(core, res, args.close_px) if args.close_px > 0 else core
    skel = thin(smoothed, res)
    skel = prune_spurs(skel, res, args.spur_px)
    print("skeleton texels:   %d (after close=%d, spur-prune=%d)"
          % (len(skel), args.close_px, args.spur_px))
    lines = trace_polylines(skel, res)
    print("traced polylines:  %d (pre-filter)" % len(lines))

    # Height sampler.
    if args.chunks:
        hsrc = height_from_glbs(args.chunks, args.height_grid)
        src_name = "glb"
    elif args.heightmap:
        hsrc = height_from_heightmap(args.heightmap, args.height_grid)
        src_name = "heightmap"
    else:
        hsrc = ManifestHeight(args.height_bias)
        src_name = "manifest(coarse)"
    sea = json.load(open(MANIFEST_JSON)).get("sea_level_y", 0.0)
    print("height source:     %s ; sea_level=%.2f" % (src_name, sea))

    simplify_px = max(1.0, args.simplify_m / m_per_texel)
    min_len_px = args.min_river_m / m_per_texel
    rivers = []
    rid = 0
    for line in lines:
        # Length in texels (skip stubs before the costlier work).
        if len(line) < 2:
            continue
        plen = sum(math.hypot((line[i] % res) - (line[i - 1] % res),
                              (line[i] // res) - (line[i - 1] // res))
                   for i in range(1, len(line)))
        if plen < min_len_px:
            continue
        pts = [(p % res, p // res) for p in line]
        pts = rdp(pts, simplify_px)
        if len(pts) < 2:
            continue
        # World x,z + width from the painted half-width at each kept vertex.
        wpts = []
        for (x, y) in pts:
            wx = x / (res - 1) * WORLD_SIZE_M - half
            wz = y / (res - 1) * WORLD_SIZE_M - half
            d = hw[y * res + x]
            w = (2 * d - 1) * m_per_texel if d != 255 else args.min_width_m
            w = max(args.min_width_m, min(args.max_width_m, w))
            wpts.append([wx, wz, w])
        # Heights along the course: sample, smooth, force downhill, clamp, sink.
        ys = [hsrc.at(p[0], p[1]) for p in wpts]
        ys = smooth(ys, args.smooth_passes)
        ys = downhill(ys)
        pts_out = []
        for (wx, wz, w), y in zip(wpts, ys):
            yy = max(sea + 0.02, y) - args.sink_m
            pts_out.append([round(wx, 2), round(yy, 2), round(wz, 2), round(w, 2)])
        rivers.append({"id": rid, "points": pts_out})
        rid += 1

    rivers.sort(key=lambda r: -len(r["points"]))
    if args.max_rivers and len(rivers) > args.max_rivers:
        rivers = rivers[:args.max_rivers]
    for k, r in enumerate(rivers):
        r["id"] = k

    total_pts = sum(len(r["points"]) for r in rivers)
    print("rivers kept:       %d (>= %.0f m) ; %d ribbon vertices total"
          % (len(rivers), args.min_river_m, total_pts))

    doc = {
        "version": 2,
        "world_size_m": WORLD_SIZE_M,
        "sea_level": sea,
        "height_source": src_name,
        "note": ("Rivers traced from the painted Azgaar biome map (inland blue) by "
                 "tools/build_rivers.py. Re-run with --chunks for exact heights. "
                 "Lakes are not generated for this map."),
        "lakes": [],
        "rivers": rivers,
    }
    with open(OUT_JSON, "w") as f:
        json.dump(doc, f, separators=(",", ":"))
        f.write("\n")                      # Godot's JSON parser wants a trailing newline
    print("wrote", os.path.relpath(OUT_JSON, HERE))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--chunks", help="folder of Chunk_*.glb -> exact river heights")
    ap.add_argument("--heightmap", help="16-bit grey heightfield PNG (0..1) -> heights")
    ap.add_argument("--height-grid", type=int, default=512,
                    help="resolution of the pooled heightfield for --chunks/--heightmap")
    ap.add_argument("--inland-m", type=float, default=INLAND_M)
    ap.add_argument("--close-px", type=int, default=1,
                    help="morphological-close radius (texels) before thinning (0=off)")
    ap.add_argument("--spur-px", type=int, default=6,
                    help="prune dead-end skeleton branches up to this many texels long")
    ap.add_argument("--min-river-m", type=float, default=MIN_RIVER_M)
    ap.add_argument("--simplify-m", type=float, default=SIMPLIFY_M)
    ap.add_argument("--min-width-m", type=float, default=MIN_WIDTH_M)
    ap.add_argument("--max-width-m", type=float, default=MAX_WIDTH_M)
    ap.add_argument("--smooth-passes", type=int, default=SMOOTH_PASSES)
    ap.add_argument("--height-bias", type=float, default=HEIGHT_BIAS,
                    help="manifest fallback: hmin + bias*(hmax-hmin)")
    ap.add_argument("--sink-m", type=float, default=SINK_M,
                    help="lower the ribbon this far so it tucks into the bank")
    ap.add_argument("--max-rivers", type=int, default=500,
                    help="keep at most this many (longest first); 0 = unlimited")
    build(ap.parse_args())


if __name__ == "__main__":
    main()
