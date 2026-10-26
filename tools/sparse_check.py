#!/usr/bin/env python3
"""Check an Android sparse image before `fastboot flash` (TP-025): every output block is written, and it expands to the raw image.

  sparse_check.py SPARSE [--sha256 HEX] [--size BYTES]     exit 0 only if all checks pass; one line per check
  sparse_check.py --selftest

Format from AOSP libsparse sparse_format.h (platform/system/core main, fetched 2026-10-26): 28-byte header, magic 0xed26ff3a, major 1,
chunk header 12 bytes {u16 type, u16 reserved, u32 chunk_sz in blocks, u32 total_sz in bytes incl. header}; RAW 0xCAC1 is followed by
chunk_sz * blk_sz bytes, FILL 0xCAC2 and CRC32 0xCAC4 by 4 bytes, DONT_CARE 0xCAC3 by nothing.
Refuses DONT_CARE: those blocks keep whatever the partition held before (old Android data inside the iOS volume). Expands the image
in a stream (never in RAM) to compute the SHA-256 that must equal the raw image's .sha256, and checks total_blks * blk_sz == --size.
Written independently of libsparse, so it is a second reader next to simg2img. Python stdlib only.
"""
import hashlib, os, struct, sys, tempfile

MAGIC, RAW, FILL, DONT_CARE, CRC32 = 0xed26ff3a, 0xCAC1, 0xCAC2, 0xCAC3, 0xCAC4
NAMES = {RAW: 'raw', FILL: 'fill', DONT_CARE: 'dont_care', CRC32: 'crc32'}
STEP = 1 << 20


def check(path, want_sha=None, want_size=None):
    """returns (ok, [lines])"""
    out, ok = [], True

    def rec(good, text):
        nonlocal ok
        ok = ok and good
        out.append(('ok   ' if good else 'FAIL ') + text)

    with open(path, 'rb') as f:
        hdr = f.read(28)
        if len(hdr) < 28:
            rec(False, 'shorter than a sparse header'); return False, out
        magic, major, minor, fhs, chs, bs, total_blks, total_chunks, _csum = struct.unpack('<IHHHHIIII', hdr)
        rec(magic == MAGIC and major == 1, f'header magic {magic:#x} version {major}.{minor}')
        if magic != MAGIC or major != 1:
            return False, out
        rec(fhs >= 28 and chs >= 12 and bs > 0 and bs % 4 == 0, f'header {fhs} B, chunk header {chs} B, block size {bs}')
        f.seek(fhs)
        h, blocks, counts, zero_block = hashlib.sha256(), 0, {}, None
        for n in range(total_chunks):
            ch = f.read(chs)
            if len(ch) < chs:
                rec(False, f'truncated at chunk {n} of {total_chunks}'); return False, out
            ctype, _r, csz, tsz = struct.unpack_from('<HHII', ch)
            counts[ctype] = counts.get(ctype, 0) + 1
            if ctype == RAW:
                if tsz != chs + csz * bs:
                    rec(False, f'chunk {n}: raw total_sz {tsz} != {chs + csz * bs}'); return False, out
                left = csz * bs
                while left:
                    b = f.read(min(STEP, left))
                    if not b:
                        rec(False, f'chunk {n}: raw data truncated'); return False, out
                    h.update(b); left -= len(b)
            elif ctype == FILL:
                if tsz != chs + 4:
                    rec(False, f'chunk {n}: fill total_sz {tsz} != {chs + 4}'); return False, out
                val = f.read(4)
                pattern = val * (STEP // 4)
                left = csz * bs
                while left:
                    k = min(STEP, left); h.update(pattern[:k]); left -= k
            elif ctype == CRC32:
                f.read(4); csz = 0
            elif ctype == DONT_CARE:
                rec(False, f'chunk {n}: DONT_CARE of {csz} blocks at block {blocks} (would keep old partition data)'); return False, out
            else:
                rec(False, f'chunk {n}: unknown type {ctype:#x}'); return False, out
            blocks += csz
        rec(blocks == total_blks, f'chunks cover {blocks} of {total_blks} blocks')
        rec(not f.read(1), 'no data after the last chunk')
    rec(DONT_CARE not in counts, 'chunks: ' + ', '.join(f'{NAMES[t]} {c}' for t, c in sorted(counts.items())))
    if want_size is not None:
        rec(total_blks * bs == want_size, f'expands to {total_blks * bs} bytes (raw image {want_size})')
    digest = h.hexdigest()
    if want_sha is not None:
        rec(digest == want_sha.lower(), f'expanded sha256 {digest[:16]}... {"==" if digest == want_sha.lower() else "!="} raw {want_sha[:16]}...')
    return ok, out


def write(path, chunks, bs=4096):
    """test helper: chunks = [(type, blocks, payload)]"""
    with open(path, 'wb') as f:
        f.write(struct.pack('<IHHHHIIII', MAGIC, 1, 0, 28, 12, bs, sum(c[1] for c in chunks), len(chunks), 0))
        for t, n, p in chunks:
            f.write(struct.pack('<HHII', t, 0, n, 12 + len(p)) + p)


def selftest():
    bs, fails = 4096, 0
    data = bytes(range(256)) * 16
    raw = data + b'\0' * bs * 3 + b'\x11\x22\x33\x44' * (bs // 4)
    sha = hashlib.sha256(raw).hexdigest()
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, 's.img')
        cases = [
            ('raw + fill(0) + fill(pattern)', [(RAW, 1, data), (FILL, 3, b'\0' * 4), (FILL, 1, b'\x11\x22\x33\x44')], True),
            ('MUTANT dont_care for the zero run', [(RAW, 1, data), (DONT_CARE, 3, b''), (FILL, 1, b'\x11\x22\x33\x44')], False),
            ('MUTANT wrong fill value', [(RAW, 1, data), (FILL, 3, b'\1\0\0\0'), (FILL, 1, b'\x11\x22\x33\x44')], False),
            ('MUTANT one block short', [(RAW, 1, data), (FILL, 2, b'\0' * 4), (FILL, 1, b'\x11\x22\x33\x44')], False),
        ]
        for name, chunks, want in cases:
            write(p, chunks)
            ok, lines = check(p, sha, len(raw))
            if ok != want:
                fails += 1; print(f'FAIL {name}: got ok={ok}', *lines, sep='\n  ')
            else:
                print(f'ok   {name}')
    print('selftest PASS' if not fails else 'selftest FAIL')
    return 1 if fails else 0


def main(argv):
    if argv[1:] == ['--selftest']:
        return selftest()
    if len(argv) < 2:
        print(__doc__.split('\n\n')[0], file=sys.stderr); return 2
    path, sha, size = argv[1], None, None
    rest = argv[2:]
    while rest:
        if rest[0] == '--sha256' and len(rest) > 1:
            sha, rest = rest[1], rest[2:]
        elif rest[0] == '--size' and len(rest) > 1:
            size, rest = int(rest[1]), rest[2:]
        else:
            print(f'unknown argument {rest[0]}', file=sys.stderr); return 2
    ok, lines = check(path, sha, size)
    print(*lines, sep='\n')
    print('RESULT: ' + ('PASS' if ok else 'FAIL') + f' {path}')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
