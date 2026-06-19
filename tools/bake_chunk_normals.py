#!/usr/bin/env python3
"""Bake skirt-free vertex normals into the terrain chunk GLBs (offline).

Why this exists
---------------
Each chunk carries a 25 m vertical skirt around its rim to hide cracks between
chunks. The top ring of skirt verts is shared with the surface's outer ring, so
Blender's normal averaging blends the (near-flat) surface normal with the
(horizontal) skirt-wall normal — tilting every chunk edge row and painting a grid
of dark seams across the terrain.

TerrainStreamer can fix this at runtime, but rebuilding an ArrayMesh per chunk
while the renderer is drawing crashes some drivers (observed: RTX 3060, Vulkan).
So we fix it once, here, by recomputing each chunk's NORMAL attribute with the
near-vertical skirt faces excluded — exactly the algorithm in
TerrainStreamer._recompute_surface_normals, but written straight into the .glb.
After running this, set TerrainStreamer.fix_edge_normals = false (the assets are
already correct) and there is no runtime mesh work at all.

Usage
-----
    python3 tools/bake_chunk_normals.py [chunks_dir] [--skirt-y-max 0.15] [--check]

    chunks_dir     folder of Chunk_*.glb  (default: terrain/chunks)
    --skirt-y-max  faces flatter than this |normal.y| are treated as skirt walls
                   and excluded from the edge-vertex normals (default 0.15)
    --check        report what would change; do not write

The edit is surgical: only the bytes of the NORMAL accessor change; counts,
offsets, JSON, and total file size are identical. Commit/back up first (git) —
the script rewrites the files in place.
"""

import json
import math
import os
import struct
import sys

GLB_MAGIC = 0x46546C67
JSON_CHUNK = 0x4E4F534A
BIN_CHUNK = 0x004E4942

# glTF componentType -> (struct char, size in bytes)
COMP = {
    5120: ("b", 1),  # BYTE
    5121: ("B", 1),  # UNSIGNED_BYTE
    5122: ("h", 2),  # SHORT
    5123: ("H", 2),  # UNSIGNED_SHORT
    5125: ("I", 4),  # UNSIGNED_INT
    5126: ("f", 4),  # FLOAT
}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}


def parse_glb(data):
    magic, ver, length = struct.unpack_from("<III", data, 0)
    if magic != GLB_MAGIC:
        raise ValueError("not a GLB")
    off = 12
    js = None
    bin_off = bin_len = None
    while off < length:
        clen, ctype = struct.unpack_from("<II", data, off)
        off += 8
        if ctype == JSON_CHUNK:
            js = json.loads(data[off:off + clen].decode("utf-8"))
        elif ctype == BIN_CHUNK:
            bin_off, bin_len = off, clen
        off += clen
    if js is None or bin_off is None:
        raise ValueError("missing JSON or BIN chunk")
    return js, bin_off, bin_len


def accessor_view(js, bin_off, acc_idx):
    """Return (file_offset, stride, count, ncomp, comp_char, comp_size) for an accessor."""
    acc = js["accessors"][acc_idx]
    bv = js["bufferViews"][acc["bufferView"]]
    if bv.get("buffer", 0) != 0:
        raise ValueError("accessor not in the embedded buffer")
    comp_char, comp_size = COMP[acc["componentType"]]
    ncomp = NCOMP[acc["type"]]
    stride = bv.get("byteStride") or (ncomp * comp_size)
    base = bin_off + bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    return base, stride, acc["count"], ncomp, comp_char, comp_size


def read_vec3(data, base, stride, count):
    out = []
    for i in range(count):
        o = base + i * stride
        out.append(struct.unpack_from("<fff", data, o))
    return out


def read_scalars(data, base, stride, count, comp_char):
    out = []
    for i in range(count):
        out.append(struct.unpack_from("<" + comp_char, data, base + i * stride)[0])
    return out


def recompute_normals(positions, indices, old_normals, skirt_y_max):
    n = len(positions)
    accum = [[0.0, 0.0, 0.0] for _ in range(n)]
    tris = len(indices) // 3
    for t in range(tris):
        a, b, c = indices[t * 3], indices[t * 3 + 1], indices[t * 3 + 2]
        pa, pb, pc = positions[a], positions[b], positions[c]
        ux, uy, uz = pb[0] - pa[0], pb[1] - pa[1], pb[2] - pa[2]
        vx, vy, vz = pc[0] - pa[0], pc[1] - pa[1], pc[2] - pa[2]
        fx = uy * vz - uz * vy
        fy = uz * vx - ux * vz
        fz = ux * vy - uy * vx
        ln = math.sqrt(fx * fx + fy * fy + fz * fz)
        if ln < 1e-12:
            continue
        fx, fy, fz = fx / ln, fy / ln, fz / ln
        # Match the exporter's winding so accumulated normals point the right way.
        rx = old_normals[a][0] + old_normals[b][0] + old_normals[c][0]
        ry = old_normals[a][1] + old_normals[b][1] + old_normals[c][1]
        rz = old_normals[a][2] + old_normals[b][2] + old_normals[c][2]
        if rx * fx + ry * fy + rz * fz < 0.0:
            fx, fy, fz = -fx, -fy, -fz
        # Drop the vertical skirt walls so they can't tilt the edge-row normals.
        if abs(fy) < skirt_y_max:
            continue
        for idx in (a, b, c):
            accum[idx][0] += fx
            accum[idx][1] += fy
            accum[idx][2] += fz
    out = []
    changed = 0
    for i in range(n):
        ax, ay, az = accum[i]
        ll = ax * ax + ay * ay + az * az
        if ll > 1e-12:
            inv = 1.0 / math.sqrt(ll)
            nv = (ax * inv, ay * inv, az * inv)
        else:
            nv = old_normals[i]  # skirt-only vertex (hidden); keep original
        out.append(nv)
        ov = old_normals[i]
        if (abs(nv[0] - ov[0]) + abs(nv[1] - ov[1]) + abs(nv[2] - ov[2])) > 1e-4:
            changed += 1
    return out, changed


def process_file(path, skirt_y_max, check):
    with open(path, "rb") as f:
        raw = f.read()
    js, bin_off, _ = parse_glb(raw)
    data = bytearray(raw)
    total_changed = 0
    for mesh in js.get("meshes", []):
        for prim in mesh["primitives"]:
            if prim.get("mode", 4) != 4:  # TRIANGLES only
                continue
            attrs = prim["attributes"]
            if "POSITION" not in attrs or "NORMAL" not in attrs or "indices" not in prim:
                continue
            pbase, pstride, pcount, _, _, _ = accessor_view(js, bin_off, attrs["POSITION"])
            nbase, nstride, ncount, _, _, _ = accessor_view(js, bin_off, attrs["NORMAL"])
            ibase, istride, icount, _, ichar, _ = accessor_view(js, bin_off, prim["indices"])
            positions = read_vec3(data, pbase, pstride, pcount)
            old_normals = read_vec3(data, nbase, nstride, ncount)
            indices = read_scalars(data, ibase, istride, icount, ichar)
            new_normals, changed = recompute_normals(positions, indices, old_normals, skirt_y_max)
            total_changed += changed
            if not check:
                for i, nv in enumerate(new_normals):
                    struct.pack_into("<fff", data, nbase + i * nstride, nv[0], nv[1], nv[2])
    if not check and total_changed:
        with open(path, "wb") as f:
            f.write(data)
    return total_changed


def main(argv):
    chunks_dir = "terrain/chunks"
    skirt_y_max = 0.15
    check = False
    args = argv[1:]
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--check":
            check = True
        elif a == "--skirt-y-max":
            i += 1
            skirt_y_max = float(args[i])
        elif not a.startswith("-"):
            chunks_dir = a
        i += 1
    files = sorted(f for f in os.listdir(chunks_dir) if f.lower().endswith(".glb"))
    if not files:
        print("No .glb files in", chunks_dir)
        return 1
    print("%s %d chunk(s) in %s (skirt_y_max=%.3f)%s" % (
        "Checking" if check else "Baking", len(files), chunks_dir, skirt_y_max,
        " [dry run]" if check else ""))
    total = 0
    touched = 0
    for name in files:
        c = process_file(os.path.join(chunks_dir, name), skirt_y_max, check)
        total += c
        if c:
            touched += 1
    print("%s: %d normals %s across %d/%d file(s)." % (
        "Would change" if check else "Changed", total,
        "would change" if check else "rewritten", touched, len(files)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
