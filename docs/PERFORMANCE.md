# Performance & the frame budget

A 50 Hz Amstrad CPC gives you one frame every 1/50 s — about **19,968 µs**, or
~**79,900 Z80 T-states** at 4 MHz. If the game loop does more work than that, it
misses the VSYNC flip and the frame rate drops; motion stutters and, because the
sound engine ticks once per frame, the audio chops too.

This game *was* over budget on busy frames. This is the story of finding out why
and fixing it — and the headline result:

> The slowdown was **not the sound** (sound is ~0.4 % of the frame). It was the
> scrolling cityscape blit and the sprite engine. Worst-case frame load went from
> **131 % → 107 %** of the budget, and the *constant* baseline (terrain + stars,
> present on every frame) dropped much further, so normal play has real headroom.

## How it was measured

Guessing where cycles go is unreliable, so the work was measured directly.
`tools/profile.py` runs the game headless in the Z80 emulator, and for every
instruction executed it:

1. maps the program counter to the nearest routine (from RASM's symbol file), and
2. adds an estimated T-state cost (with `LDIR` costed at 21 T × bytes copied, the
   real CPC cost, since the emulator runs a whole `LDIR` as one Python step).

It accumulates per-routine totals over a stretch of steady-state gameplay (the
emulator simulates the fire button held, so enemies, bullets and explosions are
all active — a deliberate worst case). One wrinkle: the emulator's notion of a
"frame" (a fixed number of port-B reads) doesn't line up 1:1 with game-loop
iterations, so the profiler counts real loop iterations (entries to
`draw_terrain_scroll`) and divides by that — measured at **12 game loops per
emulator frame**. The `wait_vsync` spin is excluded as idle time.

Run it yourself:

```sh
python tools/profile.py
```

## What it found (worst case, sound playing)

| System | % of one frame |
| ------ | -------------- |
| Sprite engine (`get_scr_addr` + `draw_spr` + `erase_rect` + `adv_line`) | ~39 % |
| Terrain blit (scrolling cityscape) | ~38 % |
| Starfield | ~10–24 % |
| Bullets / enemies / collision | ~16 % |
| **Sound** | **~0.4 %** |

Two facts reframed everything:

- **Sound is negligible.** `sound_update` is only a handful of PSG register writes
  per frame. The audible stutter was a *symptom* of dropped frames, not a cause.
- **The terrain blit is a huge constant.** Copying the cityscape band into the
  back buffer every frame costs `TERR_NT × 80 bytes` of `LDIR` — about **2.4 % of
  the frame budget per row of building height**. At 22 rows (10-window towers)
  that's ~38 % of the whole frame *before drawing a single sprite*. Tall buildings
  literally trade against speed, 1:1 with their height.

## What was changed

All changes were re-profiled to confirm the win.

1. **Terrain blit rewrite.** `draw_terrain_scroll` now reads each row's
   destination address straight from the back-buffer row table (terrain x is
   always 0) and walks the source with a running `+128` pointer — eliminating a
   per-row `get_scr_addr` call and a per-row `×128` recompute that together were
   ~16 % of the frame.
2. **`render_stars` halved its lookups.** A star's erase and its redraw are on the
   same scanline, so the row base is now computed **once** per star instead of
   twice.
3. **`get_scr_addr` slimmed.** It's called ~80×/frame by sprites and stars, none
   of which need `BC` preserved across it, so the `push/pop bc` was dropped (it now
   clobbers `BC`, still preserves `DE`). The one title-screen caller that *did*
   rely on `BC` saves it itself.
4. **Heights and counts tuned to the budget.** Building band `TERR_NT` 22 → 16 →
   **12** rows; starfield `N_STARS` 36 → **24**.

## The standing trade-off

The terrain blit is fundamental: it's a full-width copy whose cost scales with the
band height. The current 12-row band keeps the game comfortably interactive while
still showing a proper windowed skyline that evolves city→houses. If you want
taller buildings back without losing speed, the next real lever is a **stack-blit**
(`PUSH`-based copy, ~1.5× faster than `LDIR`) for `draw_terrain_scroll`, which
would buy back roughly four rows of height at the same frame cost. It's a riskier
change (stack-pointer juggling under `DI`) and hasn't been done.

Other levers, in rough order of payoff, if more headroom is ever needed:

- Reduce simultaneous explosions/bullets (they dominate the *peak*, not the
  baseline).
- A `PUSH`-based fill for `erase_rect`.
- Fewer / cheaper stars.

## Tuning knobs (all in `src/return_home.asm`)

| Constant | Effect |
| -------- | ------ |
| `TERR_NT` / `TERR_TOP` | Cityscape band height — **the biggest single cost**. Re-profile if you raise it. |
| `sect_bh` | Per-sector building base heights (capped at `TERR_NT - GROUND_H`). |
| `N_STARS` | Starfield density (×3 layers). |
| `MAX_BUL` / `FIRE_DELAY` | Bullets in flight and fire rate. |
