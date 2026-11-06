"""Lossless PNG re-encoder: drop alpha when opaque-capable, try filter strategies, zlib level 9."""
import sys, zlib, struct

def read(p):
    d = open(p, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n'
    i = 8; idat = b''; ihdr = None
    while i < len(d):
        n = struct.unpack('>I', d[i:i+4])[0]; t = d[i+4:i+8]; c = d[i+8:i+8+n]; i += 12 + n
        if t == b'IHDR': ihdr = c
        elif t == b'IDAT': idat += c
    w, h, bd, ct = struct.unpack('>IIBB', ihdr[:10])
    assert bd == 8 and ct in (2, 6)
    bpp = 4 if ct == 6 else 3
    raw = zlib.decompress(idat)
    stride = w * bpp
    rows = []; prev = bytearray(stride); pos = 0
    for y in range(h):
        f = raw[pos]; line = bytearray(raw[pos+1:pos+1+stride]); pos += 1 + stride
        if f == 1:
            for x in range(bpp, stride): line[x] = (line[x] + line[x-bpp]) & 255
        elif f == 2:
            for x in range(stride): line[x] = (line[x] + prev[x]) & 255
        elif f == 3:
            for x in range(stride): line[x] = (line[x] + ((line[x-bpp] if x >= bpp else 0) + prev[x]) // 2) & 255
        elif f == 4:
            for x in range(stride):
                a = line[x-bpp] if x >= bpp else 0; b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line); prev = line
    return w, h, ct, bpp, rows

def filt(line, prev, bpp, f):
    n = len(line); out = bytearray(n)
    if f == 0: return bytes(line)
    for x in range(n):
        a = line[x-bpp] if x >= bpp else 0; b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
        if f == 1: p = a
        elif f == 2: p = b
        elif f == 3: p = (a + b) // 2
        else:
            pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
            p = a if pa <= pb and pa <= pc else b if pb <= pc else c
        out[x] = (line[x] - p) & 255
    return bytes(out)

def write(p, w, h, ct, bpp, rows):
    best = None
    for strat in ('min', 0, 1, 2, 4):
        prev = bytearray(len(rows[0])); data = bytearray()
        for line in rows:
            if strat == 'min':
                cands = [(sum(v if v < 128 else 256 - v for v in fl), f, fl) for f in (0, 1, 2, 3, 4) for fl in [filt(line, prev, bpp, f)]]
                _, f, fl = min(cands)
            else:
                f = strat; fl = filt(line, prev, bpp, f)
            data.append(f); data += fl; prev = line
        z = zlib.compress(bytes(data), 9)
        if best is None or len(z) < len(best): best = z
    def chunk(t, c): return struct.pack('>I', len(c)) + t + c + struct.pack('>I', zlib.crc32(t + c) & 0xffffffff)
    ihdr = struct.pack('>IIBBBBB', w, h, 8, ct, 0, 0, 0)
    open(p, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr) + chunk(b'IDAT', best) + chunk(b'IEND', b''))

for p in sys.argv[1:]:
    w, h, ct, bpp, rows = read(p)
    write(p, w, h, ct, bpp, rows)
    print(p)
