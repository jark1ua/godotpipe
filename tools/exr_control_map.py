#!/usr/bin/env python3
"""Read/patch/write the terrain control-map EXR in pure Python (no numpy/OpenEXR).

The control map is a 2048x2048, 3x FLOAT (B,G,R), ZIP-compressed scanline EXR exported
by Blender. Only the R channel carries data (a 15-bit packed layer id per texel); the
terrain shader samples R. This module lets the water tool repaint texels (e.g. a pebble
shore around water) by editing R, preserving everything else byte-for-byte where it can.

ZIP scanline EXR layout we support:
  header attributes ... \\0
  line-offset table: nBlocks x uint64 (file offset of each block)
  per block: int32 y (first scanline) | int32 dataSize | data
    data = zlib( reorder(deltaEncode(rawPixels)) ), or the raw pixels verbatim if that
    was smaller. rawPixels for a block = for each scanline: for each channel (B,G,R):
    width*4 bytes (little-endian float).

The predictor/reorder pair is OpenEXR's Imf::Zip (validated against the real file by
checking the decoded base-layer ids land in 0..31 and match the layer manifest).
"""

import struct
import zlib


def _undo(b):
    """zlib-inflated block bytes -> raw pixel bytes (undo delta, then de-interleave)."""
    b = bytearray(b)
    n = len(b)
    for k in range(1, n):
        b[k] = (b[k - 1] + b[k] - 128) & 0xFF
    out = bytearray(n)
    t1 = 0
    t2 = (n + 1) // 2
    s = 0
    while s < n:
        out[s] = b[t1]; t1 += 1; s += 1
        if s < n:
            out[s] = b[t2]; t2 += 1; s += 1
    return out


def _redo(raw):
    """raw pixel bytes -> bytes ready for zlib (interleave, then delta-encode)."""
    n = len(raw)
    t = bytearray(n)
    half = (n + 1) // 2
    a = 0
    b = half
    s = 0
    while s < n:
        t[a] = raw[s]; a += 1; s += 1
        if s < n:
            t[b] = raw[s]; b += 1; s += 1
    # delta-encode in place
    p = t[0]
    for k in range(1, n):
        v = t[k]
        t[k] = (v - p + 384) & 0xFF
        p = v
    return bytes(t)


class ControlMapEXR:
    def __init__(self, path):
        self.path = path
        raw = open(path, "rb").read()
        self.raw = raw
        if raw[:4] != b"\x76\x2f\x31\x01":
            raise ValueError("not an EXR")
        i = 8
        hdr = {}
        order = []
        while True:
            e = raw.index(b"\x00", i); name = raw[i:e].decode("latin1"); i = e + 1
            if name == "":
                break
            e = raw.index(b"\x00", i); typ = raw[i:e].decode("latin1"); i = e + 1
            sz = struct.unpack_from("<i", raw, i)[0]; i += 4
            hdr[name] = (typ, raw[i:i + sz]); i += sz
            order.append(name)
        self.header_end = i
        self.header_bytes = raw[:i]
        # channels (alphabetical order on disk)
        ch = hdr["channels"][1]; j = 0; chans = []
        while j < len(ch):
            e = ch.index(b"\x00", j); nm = ch[j:e].decode("latin1"); j = e + 1
            if nm == "":
                break
            ptype = struct.unpack_from("<i", ch, j)[0]; j += 16
            chans.append((nm, ptype))
        self.channels = sorted(c[0] for c in chans)
        if any(p != 2 for _, p in chans):
            raise ValueError("expected all-FLOAT channels")
        self.comp = hdr["compression"][1][0]
        if self.comp != 3:
            raise ValueError("expected ZIP (16-row) compression")
        dw = struct.unpack("<4i", hdr["dataWindow"][1])
        self.x0, self.y0 = dw[0], dw[1]
        self.W = dw[2] - dw[0] + 1
        self.H = dw[3] - dw[1] + 1
        self.rows_per_block = 16
        self.nblocks = (self.H + self.rows_per_block - 1) // self.rows_per_block
        self.row_bytes = self.W * 4 * len(self.channels)
        # offset of R within one scanline's bytes
        self.r_off = self.channels.index("R") * self.W * 4
        # line-offset table
        ot = self.header_end
        self.offsets = list(struct.unpack_from("<%dQ" % self.nblocks, raw, ot))
        # original on-disk (y, dataSize, data) for each block (for verbatim passthrough)
        self._orig = []
        for off in self.offsets:
            y = struct.unpack_from("<i", raw, off)[0]
            ds = struct.unpack_from("<i", raw, off + 4)[0]
            self._orig.append((y, ds, raw[off + 8:off + 8 + ds]))
        self._edits = {}   # block index -> { local_byte_offset_of_R_pixel : float_bytes }
        self._decoded = {}  # block index -> bytearray raw pixels (lazily decoded when edited)

    def _block_raw(self, bi):
        if bi not in self._decoded:
            y, ds, data = self._orig[bi]
            nrows = min(self.rows_per_block, self.H - bi * self.rows_per_block)
            rawsize = self.row_bytes * nrows
            self._decoded[bi] = bytearray(data) if ds == rawsize else _undo(zlib.decompress(data))
        return self._decoded[bi]

    def set_packed(self, x, y, packed):
        """Set the R value at texel (x, y) to encode `packed` (0..65535)."""
        bi = y // self.rows_per_block
        row_in_block = y % self.rows_per_block
        pos = row_in_block * self.row_bytes + self.r_off + x * 4
        buf = self._block_raw(bi)
        struct.pack_into("<f", buf, pos, packed / 65535.0)

    def get_packed(self, x, y):
        bi = y // self.rows_per_block
        row_in_block = y % self.rows_per_block
        pos = row_in_block * self.row_bytes + self.r_off + x * 4
        v = struct.unpack_from("<f", self._block_raw(bi), pos)[0]
        return int(round(v * 65535.0))

    def save(self, path):
        out = bytearray(self.header_bytes)
        ot_pos = len(out)
        out += b"\x00" * (8 * self.nblocks)   # placeholder offset table
        new_offsets = []
        for bi in range(self.nblocks):
            new_offsets.append(len(out))
            y = self._orig[bi][0]
            if bi in self._decoded:
                raw = bytes(self._decoded[bi])
                comp = zlib.compress(_redo(raw), 9)
                if len(comp) < len(raw):
                    payload = comp
                else:
                    payload = raw            # store verbatim if compression didn't help
            else:
                # untouched: reuse the original compressed bytes exactly
                payload = self._orig[bi][2]
            out += struct.pack("<ii", y, len(payload)) + payload
        struct.pack_into("<%dQ" % self.nblocks, out, ot_pos, *new_offsets)
        with open(path, "wb") as f:
            f.write(out)
