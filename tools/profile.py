#!/usr/bin/env python3
"""
Return Home - frame-budget profiler.

Assembles the game, runs steady-state gameplay in the bundled Z80 emulator
(tools/z80test.py), and reports where the ~79,900 T-states of one 50 Hz CPC
frame actually go, grouped by engine subsystem.

Why this exists: eyeballing assembly tells you nothing reliable about cost. This
attributes a T-state estimate to every executed instruction (with LDIR costed at
21 T x bytes copied - the real CPC cost - since the emulator runs a whole LDIR as
one step), maps the PC to the nearest routine via RASM's symbol file, and sums.

    python tools/profile.py

See docs/PERFORMANCE.md for the methodology and the optimisation story.
"""
import os, sys, re, bisect, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC  = os.path.join(ROOT, "src", "return_home.asm")
RASM = os.environ.get("RASM", os.path.join(HERE, "rasm.exe"))
EMU  = os.path.join(HERE, "z80test.py")
BIN  = os.path.join(HERE, "_profile.bin")
SYM  = os.path.join(os.getcwd(), "rasmoutput.sym")

FRAME_T   = 79896          # T-states in one 50 Hz CPC frame (4 MHz)
WARMUP    = 40             # emulator frames to reach steady-state gameplay
MEASURE   = 60             # emulator frames to profile

# group routine-name prefixes into engine subsystems
GROUPS = {
    "terrain (blit)": ["DTS_", "DRAW_TERRAIN"],
    "terrain (gen)":  ["REGEN", "RTC_", "RSC_", "RENDER_STRUCT", "BTB"],
    "sprite engine":  ["DSPR", "ERCT", "DRAW_SPR", "ERASE_RECT", "ADV_LINE", "GET_SCR_ADDR"],
    "starfield":      ["RS_", "US_", "RENDER_STARS", "UPDATE_STARS"],
    "explosions":     ["RX_", "RENDER_EXPL", "UPDATE_EXPL", "UPDATE_PBOOM"],
    "enemies":        ["RE_", "UEM", "UE_", "UPDATE_ENE", "RENDER_ENE", "SW_", "START_WAVE", "INIT_LEVEL"],
    "bullets":        ["RB_", "UB_", "PU_", "SPAWN_BUL", "UPDATE_BUL", "RENDER_BUL", "FIRE"],
    "collision":      ["CC_", "CHECK_COLL"],
    "sound":          ["SU_", "PSG", "SOUND", "PT_"],
    "player":         ["RP_", "UP_", "PLAYER", "RENDER_PLAYER", "UPDATE_PLAYER"],
}


def tstate_cost(mem, B, C, pc):
    op = mem[pc]
    if op == 0xED:
        o2 = mem[(pc + 1) & 0xFFFF]
        if o2 == 0xB0:                              # LDIR
            n = (B << 8) | C
            return 21 * (n if n else 65536)
        return 12
    if op in (0xDD, 0xFD): return 19                # IX/IY prefixed
    if op == 0xCB: return 8
    if op == 0xCD: return 17                         # call
    if op in (0xC4, 0xCC, 0xD4, 0xDC, 0xE4, 0xEC, 0xF4, 0xFC): return 14
    if op == 0xC9: return 10                         # ret
    if op in (0xC0, 0xC8, 0xD0, 0xD8, 0xE0, 0xE8, 0xF0, 0xF8): return 8
    if op in (0xC3, 0xC2, 0xCA, 0xD2, 0xDA, 0xE2, 0xEA, 0xF2, 0xFA): return 10
    if op == 0x18: return 12
    if op in (0x20, 0x28, 0x30, 0x38): return 10
    if op in (0xC5, 0xD5, 0xE5, 0xF5): return 11    # push
    if op in (0xC1, 0xD1, 0xE1, 0xF1): return 10    # pop
    if op in (0xD3, 0xDB): return 11                # in/out (n)
    if op in (0x34, 0x35, 0x36, 0x09, 0x19, 0x29, 0x39, 0x22, 0x2A, 0x32, 0x3A): return 11
    if 0x40 <= op <= 0x7F and ((op & 7) == 6 or ((op >> 3) & 7) == 6): return 7   # (hl)
    if 0x80 <= op <= 0xBF and (op & 7) == 6: return 7
    if op in (0x01, 0x11, 0x21, 0x31): return 10
    return 5


def main():
    if not os.path.exists(RASM):
        sys.exit(f"RASM not found at {RASM!r}; set the RASM env var.")
    r = subprocess.run([RASM, SRC, "-amper", "-ob", BIN, "-s"], capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(BIN):
        sys.stderr.write(r.stdout + r.stderr); sys.exit("assembly failed")

    syms = []
    for ln in open(SYM):
        m = re.match(r'^(\S+)\s+#([0-9A-Fa-f]+)', ln)
        if m:
            a = int(m.group(2), 16)
            if 0x4000 <= a < 0x8000:
                syms.append((a, m.group(1)))
    syms.sort()
    addrs = [a for a, _ in syms]
    names = [n for _, n in syms]

    def routine(pc):
        i = bisect.bisect_right(addrs, pc) - 1
        return names[i] if i >= 0 else "?"

    src = open(EMU).read().replace('while frame<maxframe', 'while False and frame<maxframe')
    sys.argv = ["z80test.py", BIN]
    G = {}
    exec(compile(src, EMU, "exec"), G)
    mem = G['mem']
    DTS = next(a for a, n in syms if n.upper() == "DRAW_TERRAIN_SCROLL")

    def run_until(target):
        while G['frame'] < target and G['steps'] < 50_000_000:
            G['step']()

    run_until(WARMUP)
    prof = {}
    loops = 0
    f0 = G['frame']
    while G['frame'] < f0 + MEASURE and G['steps'] < 200_000_000:
        pc = G['PC']
        if pc == DTS:
            loops += 1
        r = routine(pc)
        prof[r] = prof.get(r, 0) + tstate_cost(mem, G['B'], G['C'], pc)
        G['step']()

    idle = {"WAIT_VSYNC", "WAIT_VSYNC_EDGE"}
    work = sum(t for r, t in prof.items() if r.upper() not in idle)

    def group_of(r):
        u = r.upper()
        for g, ps in GROUPS.items():
            if any(u.startswith(p) for p in ps):
                return g
        return "other"

    grp = {}
    for r, t in prof.items():
        if r.upper() in idle:
            continue
        grp[group_of(r)] = grp.get(group_of(r), 0) + t

    print(f"\nReturn Home - frame budget (worst case: fire held, all entities active)")
    print(f"measured {loops} game loops; 1 frame = {FRAME_T} T-states\n")
    print(f"  TOTAL WORK = {100 * (work / loops) / FRAME_T:.0f}% of one 50 Hz frame "
          f"({'OVER budget' if work/loops > FRAME_T else 'within budget'})\n")
    print(f"  {'subsystem':18}{'% of frame':>11}")
    print(f"  {'-'*18}{'-'*11:>11}")
    for g, t in sorted(grp.items(), key=lambda x: -x[1]):
        print(f"  {g:18}{100 * (t / loops) / FRAME_T:>10.1f}%")

    os.remove(BIN)
    if os.path.exists(SYM):
        os.remove(SYM)


if __name__ == "__main__":
    main()
