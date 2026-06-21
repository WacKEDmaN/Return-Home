#!/usr/bin/env python3
"""
Return Home - build script.

Assembles src/return_home.asm with RASM and packages a bootable Amstrad CPC
disk image (dist/returnhome.dsk) containing:

    DISC.BAS    - BASIC loader (RUN"DISC" to play)
    65.SCR      - loading screen      (extracted from assets/images.dsk)
    69.SCR      - objectives screen   (extracted from assets/images.dsk)
    WIN.DAT     - compressed win screen (assets/win47.bin, loads to &2000)
    RETURN.BIN  - the assembled game  (loads + runs at &4000)

Usage:
    python build.py

Requires Python 3.8+.  RASM (tools/rasm.exe) runs natively on Windows; on
Linux/macOS install RASM and set the RASM environment variable to its path,
e.g.  RASM=rasm python build.py
"""
import os, sys, subprocess, struct

HERE   = os.path.dirname(os.path.abspath(__file__))
SRC    = os.path.join(HERE, "src", "return_home.asm")
RASM   = os.environ.get("RASM", os.path.join(HERE, "tools", "rasm.exe"))
IMAGES = os.path.join(HERE, "assets", "images.dsk")
WIN    = os.path.join(HERE, "assets", "win47.bin")
OUTDSK = os.path.join(HERE, "dist", "returnhome.dsk")
TMPBIN = os.path.join(HERE, "out.bin")

# The BASIC loader.  OPENOUT"D":MEMORY &1FF keeps BASIC out of the way so the
# 32 KB overscan loading screen can load to &0200.  See docs/ARCHITECTURE.md.
LOADER = (b'10 MODE 0:OPENOUT"D":MEMORY &1FF:LOAD"65.SCR":CALL &811:CALL &BB18:'
          b'MODE 0:LOAD"WIN.DAT",&2000:LOAD"RETURN.BIN":CALL &4000\r\n')

NTRACK, SPT = 40, 9            # 40 tracks, 9 sectors/track (CPC DATA format)


def assemble():
    """RASM assemble -> raw binary bytes (ORG &4000)."""
    if not os.path.exists(RASM):
        sys.exit(f"RASM not found at {RASM!r}. Set the RASM env var to your rasm binary.")
    # -amper : accept '&' as the hex prefix (the source is Maxam/JavaCPC dialect)
    r = subprocess.run([RASM, SRC, "-amper", "-ob", TMPBIN],
                       capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    if r.returncode != 0 or not os.path.exists(TMPBIN):
        sys.stderr.write(r.stderr)
        sys.exit("RASM assembly failed.")
    data = open(TMPBIN, "rb").read()
    os.remove(TMPBIN)
    print(f"  assembled RETURN.BIN: {len(data)} bytes (org &4000)")
    return data


# ---------- read a file's payload out of the source images.dsk ----------
def extract_scr(name):
    """Pull NAME.SCR (with its 128-byte AMSDOS header) out of images.dsk."""
    d = open(IMAGES, "rb").read()
    ntr = d[48]
    tsz = [d[52 + i] * 256 for i in range(ntr)]

    def toff(t):    return 256 + sum(tsz[:t])

    def track_sectors(t):
        off = toff(t); th = d[off:off + 256]; ns = th[0x15]; m = {}; p = off + 256
        for i in range(ns):
            si = th[0x18 + i * 8: 0x18 + i * 8 + 8]
            ln = si[6] | (si[7] << 8)
            m[si[2]] = d[p:p + ln]; p += ln
        return m

    def block(b):                       # 1 KB block = 2 consecutive 512-byte sectors
        out = b''
        for s in (b * 2, b * 2 + 1):
            out += track_sectors(s // 9)[0xC1 + s % 9]
        return out

    dirb = b''.join(track_sectors(0)[r] for r in range(0xC1, 0xC5))
    entries = {}
    for i in range(0, len(dirb), 32):
        e = dirb[i:i + 32]
        if e[0] != 0:
            continue
        nm = bytes(c & 0x7F for c in e[1:9]).decode('latin1').rstrip()
        ex = bytes(c & 0x7F for c in e[9:12]).decode('latin1').rstrip()
        if ex == "SCR":
            extent = e[12] | (e[14] << 5)
            entries.setdefault(nm, {})[extent] = [b for b in e[16:32] if b]
    blocks = entries[name]
    raw = b''.join(block(b) for ext in sorted(blocks) for b in blocks[ext])
    return raw[:128 + (raw[24] | (raw[25] << 8))]   # trim to header-declared length


def amsdos(name, ext, ftype, load, exec_, data):
    """Prefix DATA with a 128-byte AMSDOS header."""
    h = bytearray(128)
    h[1:9]   = name.ljust(8)[:8].encode()
    h[9:12]  = ext.ljust(3)[:3].encode()
    h[18]    = ftype
    h[19:21] = struct.pack("<H", len(data) & 0xFFFF)
    h[21:23] = struct.pack("<H", load)
    h[23]    = 0xFF
    h[24:26] = struct.pack("<H", len(data) & 0xFFFF)
    h[26:28] = struct.pack("<H", exec_)
    h[64:67] = struct.pack("<I", len(data))[:3]
    chk = sum(h[0:67]) & 0xFFFF
    h[67:69] = struct.pack("<H", chk)
    return bytes(h) + data


def build_dsk(files):
    """files = [(name, ext, payload_with_header_or_ascii), ...] -> .dsk bytes."""
    nblk = (NTRACK * SPT) // 2
    blocks = [bytearray(1024) for _ in range(nblk)]
    entries = []
    nb = 2                                   # blocks 0,1 hold the directory
    for name, ext, data in files:
        used = []
        for k in range((len(data) + 1023) // 1024):
            blocks[nb][:] = data[k * 1024:(k + 1) * 1024].ljust(1024, b'\0')
            used.append(nb); nb += 1
        recs = (len(data) + 127) // 128
        bi = xt = 0
        while bi < len(used):
            chunk = used[bi:bi + 16]
            e = bytearray(32)
            e[1:9]  = name.ljust(8)[:8].encode()
            e[9:12] = ext.ljust(3)[:3].encode()
            e[12] = xt & 0x1F
            e[14] = (xt >> 5) & 0x3F
            e[15] = min(128, recs - xt * 128)
            for j, b in enumerate(chunk):
                e[16 + j] = b
            entries.append(bytes(e)); bi += 16; xt += 1

    dirb = bytearray(b'\xE5' * 2048)
    for i, e in enumerate(entries):
        dirb[i * 32:(i + 1) * 32] = e
    blocks[0][:] = dirb[:1024]
    blocks[1][:] = dirb[1024:]

    secs = [bytes(blocks[b][s * 512:(s + 1) * 512]) for b in range(nblk) for s in (0, 1)]
    while len(secs) < NTRACK * SPT:
        secs.append(b'\xE5' * 512)

    out = bytearray(256)
    out[0:34]  = b"MV - CPCEMU Disk-File\r\nDisk-Info\r\n"
    out[34:48] = b"RETURNHOME    "[:14]
    out[48] = NTRACK; out[49] = 1; out[50] = 0; out[51] = 0x13
    si = 0
    for t in range(NTRACK):
        th = bytearray(256)
        th[0:12] = b"Track-Info\r\n"
        th[0x10] = t; th[0x14] = 2; th[0x15] = SPT; th[0x16] = 0x4E; th[0x17] = 0xE5
        for s in range(SPT):
            o = 0x18 + s * 8
            th[o] = t; th[o + 2] = 0xC1 + s; th[o + 3] = 2
        out += th
        for s in range(SPT):
            out += secs[si]; si += 1
    return bytes(out)


def main():
    print("Return Home - build")
    game = assemble()
    print("  extracting 65.SCR / 69.SCR from images.dsk ...")
    scr65 = extract_scr("65")
    scr69 = extract_scr("69")
    wdat  = amsdos("WIN", "DAT", 2, 0x2000, 0x2000, open(WIN, "rb").read())
    rbin  = amsdos("RETURN", "BIN", 2, 0x4000, 0x4000, game)
    dsk = build_dsk([
        ("DISC", "BAS", LOADER),
        ("65",   "SCR", scr65),
        ("69",   "SCR", scr69),
        ("WIN",  "DAT", wdat),
        ("RETURN", "BIN", rbin),
    ])
    os.makedirs(os.path.dirname(OUTDSK), exist_ok=True)
    open(OUTDSK, "wb").write(dsk)
    print(f"  wrote {OUTDSK} ({len(dsk)} bytes)")
    print('Done.  Boot it in an Amstrad CPC emulator with  RUN"DISC"')


if __name__ == "__main__":
    main()
