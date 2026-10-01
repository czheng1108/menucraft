#!/usr/bin/env python3
"""Recompress PNG IDAT bytes without changing pixels or metadata."""
import struct, sys, zlib
from pathlib import Path
for path in Path(sys.argv[1]).glob('*.png'):
    original = path.read_bytes(); offset = 8; chunks = []; compressed = b''
    while offset < len(original):
        size = struct.unpack('>I', original[offset:offset+4])[0]
        kind = original[offset+4:offset+8]; body = original[offset+8:offset+8+size]
        chunks.append((kind, body)); offset += size + 12
        if kind == b'IDAT': compressed += body
    if not compressed: continue
    raw = zlib.decompress(compressed)
    candidates = [compressed]
    for strategy in (zlib.Z_DEFAULT_STRATEGY, zlib.Z_FILTERED):
        compressor = zlib.compressobj(9, zlib.DEFLATED, 15, 9, strategy)
        candidates.append(compressor.compress(raw) + compressor.flush())
    packed = min(candidates, key=len)
    assert zlib.decompress(packed) == raw
    result = original[:8]; inserted = False
    for kind, body in chunks:
        if kind == b'IDAT':
            if inserted: continue
            body = packed; inserted = True
        result += struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body) & 0xffffffff)
    if len(result) < len(original): path.write_bytes(result)
