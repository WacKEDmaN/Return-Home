# Building, running & testing

## Requirements

- **Python 3.8+** (the build script and the emulator/profiler are pure Python).
- **RASM** — bundled as `tools/rasm.exe` (Windows). On Linux/macOS, build or
  download RASM from <http://www.roudoudou.com/rasm/> and point the build at it
  with the `RASM` environment variable.

## Build

From the repo root:

```sh
python build.py
```

This:

1. Assembles `src/return_home.asm` with RASM (`-amper`, so `&` is the hex prefix)
   into a raw binary at `ORG &4000`.
2. Extracts the `65.SCR` (loading) and `69.SCR` (objectives) overscan screens from
   `assets/images.dsk`.
3. Wraps the game (`RETURN.BIN`), the win screen (`WIN.DAT`, from
   `assets/win47.bin`) and the screens with AMSDOS headers.
4. Writes a BASIC loader (`DISC.BAS`) and packs everything into a standard
   40-track DATA-format disk image at `dist/returnhome.dsk`.

On Linux/macOS:

```sh
RASM=rasm python build.py        # if rasm is on PATH
RASM=/opt/rasm/rasm python build.py
```

### Assembling by hand

RASM accepts the source directly — no preprocessing is needed:

```sh
tools/rasm.exe src/return_home.asm -amper -ob out.bin        # raw binary
tools/rasm.exe src/return_home.asm -amper -ob out.bin -s     # also writes rasmoutput.sym
```

The `-s` symbol file is what the profiler uses.

> Note on dialect: the source is written for **Maxam / JavaCPC** (`&` hex,
> `defb/defw/defs`, `end`). RASM with `-amper` is compatible. JavaCPC's *own*
> built-in assembler is too limited for this source (it mishandles some
> ED-prefixed 16-bit loads) — assemble with RASM and run the produced disk.

## Run

Open `dist/returnhome.dsk` in any CPC emulator and type:

```
RUN"DISC"
```

The loader (`DISC.BAS`) is:

```basic
10 MODE 0:OPENOUT"D":MEMORY &1FF:LOAD"65.SCR":CALL &811:CALL &BB18:
   MODE 0:LOAD"WIN.DAT",&2000:LOAD"RETURN.BIN":CALL &4000
```

`OPENOUT"D":MEMORY &1FF` keeps BASIC's variables out of low RAM so the 32 KB
loading screen can load to `&0200`; `CALL &811` runs the screen's own overscan
setup; `CALL &BB18` waits for a key; then the game and win-screen data load and
the game starts at `&4000`.

## The disk image

`dist/returnhome.dsk` is a standard `MV - CPCEMU` DATA-format image: 40 tracks, 9
× 512-byte sectors per track (sector IDs `&C1-&C9`), 1 KB blocks, directory in
blocks 0-1, 16-block / 128-record extents. `build.py` generates it from scratch;
the same code can round-trip (extract) files, which is how the overscan screens
are pulled out of `assets/images.dsk`.

## Headless testing — the Z80 emulator

`tools/z80test.py` is a small Z80 emulator written to crash-test the game without
a real machine. It models the CRTC R12 buffer flips, VSYNC polling and the
keyboard ports, stubs the firmware, and implements the documented opcodes the game
uses (including the ED-prefixed 16-bit `sbc/adc hl,ss`). With the fire button
simulated as held, it drives the title screen straight into live gameplay.

```sh
tools/rasm.exe src/return_home.asm -amper -ob out.bin
python tools/z80test.py out.bin 300          # run 300 frames
```

It reports load size, completion/crash, buffer activity, the game state, and flags
any writes outside the expected data/screen/stack regions.

**Limits:** it cannot model real timing, CRTC overscan display, RAM banking, or
disk I/O — so the loading/win screens and exact frame timing must be checked in a
real emulator (JavaCPC) or on hardware. It's a logic/crash harness, not a
pixel-accurate display.

## Profiling

`tools/profile.py` measures where the frame budget goes (see
[PERFORMANCE.md](PERFORMANCE.md) for the methodology and results):

```sh
python tools/profile.py
```

It assembles the game, runs steady-state gameplay, and prints a per-system
breakdown of T-states as a percentage of one 50 Hz frame.
