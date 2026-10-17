#!/usr/bin/env python3
"""Fuzzing the image decoders, PNG first: an extension's icon reaches them as soon as it is
installed. Valid images (tests/data/images and a few made here) are mutated: bits flipped, bytes
replaced, the file cut short, IHDR's fields and chunk lengths set to extremes, chunks repeated and
dropped, the compressed stream corrupted inside a valid container. build/image_test decodes each
batch; a crash, a hang or a missing line fails the run.

    tests/image-fuzz.py [SEED] [ROUNDS]       (defaults 1 and 40; each round is 100 images)
"""
import os
from pathlib import Path
import random
import struct
import subprocess
import sys
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
EXE = Path(os.environ.get('RHUN_IMAGE_TEST', ROOT / 'build/image_test'))
SEED = int(sys.argv[1]) if len(sys.argv) > 1 else 1
ROUNDS = int(sys.argv[2]) if len(sys.argv) > 2 else 40
BATCH = 100


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)


def png(w, h, color_type=6, depth=8, interlace=0, pixel=lambda x, y: (x, y, x ^ y, 200)):
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color_type]
    raw = b''.join(b'\x00' + b''.join(bytes(pixel(x, y)[:channels]) for x in range(w)) for y in range(h))
    head = struct.pack('>IIBBBBB', w, h, depth, color_type, 0, 0, interlace)
    extra = chunk(b'PLTE', bytes(range(256)) * 3) if color_type == 3 else b''
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', head) + extra + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b'')


def chunks(data):
    """(start, length, kind) of each chunk of a PNG, as far as it parses."""
    out, pos = [], 8
    while pos + 12 <= len(data):
        length = struct.unpack('>I', data[pos:pos + 4])[0]
        out.append((pos, length, data[pos + 4:pos + 8]))
        pos += 12 + length
    return out


def mutate(rng, data):
    data = bytearray(data)
    if len(data) < 2:                               # too little to cut: grow it
        return bytes(data) + bytes(rng.randrange(256) for _ in range(rng.randint(1, 64)))
    kind = rng.randrange(9)
    if kind == 0:                                   # flip bits
        for _ in range(rng.randint(1, 8)):
            i = rng.randrange(len(data))
            data[i] ^= 1 << rng.randrange(8)
    elif kind == 1:                                 # random bytes
        for _ in range(rng.randint(1, 16)):
            data[rng.randrange(len(data))] = rng.randrange(256)
    elif kind == 2:                                 # cut short
        del data[rng.randrange(1, len(data)):]
    elif kind == 3 and data[:8] == b'\x89PNG\r\n\x1a\n' and len(data) > 33:   # IHDR extremes
        field = rng.choice([(16, 4), (20, 4), (24, 1), (25, 1), (26, 1), (27, 1), (28, 1)])
        values = [0, 1, 2, 3, 4, 5, 6, 7, 8, 15, 16, 255, 256, 0x7fff, 0x8000, 0xffff, 0x10000,
                  0x7fffffff, 0x80000000, 0xffffffff]
        value = rng.choice(values) & ((1 << (8 * field[1])) - 1)
        data[field[0]:field[0] + field[1]] = value.to_bytes(field[1], 'big')
        data[29:33] = struct.pack('>I', zlib.crc32(bytes(data[12:29])) & 0xffffffff)
    elif kind == 4 and data[:8] == b'\x89PNG\r\n\x1a\n':                     # a chunk length
        found = chunks(bytes(data))
        if found:
            start, _, _ = rng.choice(found)
            data[start:start + 4] = struct.pack('>I', rng.choice([0, 1, 0x7fffffff, 0xffffffff,
                                                                   rng.randrange(1 << 20)]))
    elif kind == 5 and data[:8] == b'\x89PNG\r\n\x1a\n':                     # repeat or drop a chunk
        found = chunks(bytes(data))
        if found:
            start, length, _ = rng.choice(found)
            piece = data[start:start + 12 + length]
            if rng.random() < 0.5:
                data[start:start] = piece * rng.randint(1, 3)
            else:
                del data[start:start + 12 + length]
    elif kind == 6 and data[:8] == b'\x89PNG\r\n\x1a\n':                     # corrupt the stream, keep the CRCs
        found = [c for c in chunks(bytes(data)) if c[2] == b'IDAT' and c[1] > 2]
        if found:
            start, length, _ = rng.choice(found)
            body = bytearray(data[start + 8:start + 8 + length])
            for _ in range(rng.randint(1, 6)):
                body[rng.randrange(len(body))] = rng.randrange(256)
            data[start:start + 12 + length] = chunk(b'IDAT', bytes(body))
    elif kind == 7:                                 # junk appended
        data += bytes(rng.randrange(256) for _ in range(rng.randint(1, 300)))
    else:                                           # two cuts spliced
        a, b = sorted(rng.randrange(len(data)) for _ in range(2))
        data = data[:a] + data[b:]
    return bytes(data)


def seeds():
    out = [p.read_bytes() for p in sorted((ROOT / 'tests/data/images').iterdir()) if p.is_file()]
    out += [png(16, 16), png(33, 7, 2), png(9, 9, 3), png(12, 5, 0), png(8, 8, 4), png(17, 13, 6, 8, 1),
            png(128, 128, pixel=lambda x, y: (255, 255, 255, (x * y) & 255))]
    return out


def main():
    if not EXE.exists():
        sys.exit(f'{EXE} is missing: build with tests (tools/build-mac.sh test, or build.sh test)')
    rng = random.Random(SEED)
    pool = seeds()
    failures = 0
    with tempfile.TemporaryDirectory(prefix='rhun-imgfuzz-') as tmp:
        work = Path(tmp)
        for round_ in range(ROUNDS):
            names = []
            for i in range(BATCH):
                data = mutate(rng, rng.choice(pool))
                if rng.random() < 0.3:
                    data = mutate(rng, data)
                path = work / f'{round_:03}-{i:03}.png'
                path.write_bytes(data)
                names.append(path)
            try:
                result = subprocess.run([str(EXE), *map(str, names)], stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, timeout=120)   # it reports on stderr
            except subprocess.TimeoutExpired:
                print(f'HANG round {round_} (seed {SEED})')
                failures += 1
                keep = ROOT / 'build' / f'image-fuzz-hang-{SEED}-{round_}'
                keep.mkdir(parents=True, exist_ok=True)
                for p in names:
                    (keep / p.name).write_bytes(p.read_bytes())
                continue
            lines = result.stdout.decode(errors='replace').splitlines()
            if result.returncode != 0 or len(lines) != len(names):
                failures += 1
                bad = names[len(lines)] if len(lines) < len(names) else None
                print(f'FAIL round {round_} (seed {SEED}): exit {result.returncode}, {len(lines)} of {len(names)} lines'
                      + (f', stopped at {bad.name}' if bad else ''))
                if bad:
                    keep = ROOT / 'build' / f'image-fuzz-{SEED}-{bad.name}'
                    keep.write_bytes(bad.read_bytes())
                    print('  kept as', keep)
            for p in names:
                p.unlink()
    print(f'{ROUNDS * BATCH} images, {failures} failing batches')
    sys.exit(1 if failures else 0)


if __name__ == '__main__':
    main()
