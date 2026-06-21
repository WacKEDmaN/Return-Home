# Architecture

How *Return Home* works under the hood. The whole game is one Z80 source file,
`src/return_home.asm`, assembled to a single `RETURN.BIN` that loads and runs at
`&4000`. It targets the **Maxam / JavaCPC** assembler dialect (`&` for hex;
`defb/defw/defs/equ/org/end`) and only uses **documented** Z80 opcodes — JavaCPC
will not run undocumented instructions such as `dec ixl`.

## Memory map

```
&0000-&01FF   (free; the loading screen lands at &0200 during boot)
&2000         WIN.DAT lives here at boot (compressed win screen)
&4000-&7FFF   game code + data + stack
&8000-&BFFF   screen buffer 1  (BUF1)
&C000-&FFFF   screen buffer 0  (BUF0)
```

Everything fits in a stock 64 KB CPC. No RAM expansion is required for the game
itself.

## Firmware-less boot

The game executes `DI` immediately, sets up its own stack inside `&4000-&7FFF`,
and never calls the firmware again. All hardware is driven directly:

- **Mode + ROM enables** via the Gate Array RMR register (`OUT &7F, n`). The mode
  bytes used are `&88` (Mode 0, upper ROM off, lower ROM on) and `&89` (Mode 1).
  The **upper ROM must be disabled** (bit 3 set): `&C000-&FFFF` is the upper ROM
  when enabled, and the code reads that region constantly — `LDIR` clears read the
  destination, sprite masking does `AND (HL)` against the screen. With the ROM on,
  those reads return ROM bytes and you get BASIC-ROM noise smeared across the
  screen. This bug cost real debugging time; the fix is baked into the mode bytes.
- **Palette** via the Gate Array directly, using **hardware** colour codes (not
  firmware ink numbers). Firmware `SCR_SET_INK` only applies inks on its VSYNC
  interrupt, which is useless after `DI`.
- **Rule of thumb:** every value `OUT` to `&7F` must be a pen/colour (`&00-&5F`),
  the border select (`&10`), or a mode byte (`&88`/`&89`). Never `OUT` a value
  `>= &C0` — that is a RAM-bank select and an instant crash/reset on a 464.

## Display & double-buffering

Two 16 KB screen pages are used as front/back buffers:

| Buffer | Address | CRTC R12 |
| ------ | ------- | -------- |
| BUF0   | `&C000` | `&30`    |
| BUF1   | `&8000` | `&20`    |

Each frame the game renders into the **back** buffer, waits for VSYNC (polling
PPI port B bit 0), writes the new R12 to flip, then swaps. Because each buffer is
only shown every other frame, **each buffer is two frames stale** — so moving
objects keep a *per-buffer* draw shadow (old X/Y/sprite for buf0 and buf1,
selected by a `parity` flag): render erases last time's shadow in *this* buffer,
then draws the new position.

### Screen address layout

The CPC's non-linear screen layout is precomputed into a 200-entry word table per
buffer (`tbl_c` for BUF0, `tbl_8` = `tbl_c - &4000` for BUF1). `draw_tbl` points
at the current back buffer's table. `get_scr_addr` (`H` = x byte, `L` = y) reads
`draw_tbl[y]` and adds x. The next scanline within a character row is `+&800`;
crossing a character row wraps with `+&50` (`adv_line`).

### Mode 0 pixel encoding

Mode 0 packs **two pixels per byte** with interleaved bits. Two lookup tables,
`m0_left` and `m0_right`, map a pen (0-15) to the bit pattern for the left/right
pixel; OR them together for a two-pixel byte. This is used everywhere pixels are
built — sprites, the font, and the cityscape window pattern.

## Sprites

Sprite art is written as ASCII "pen-art" (`'0'-'9'`, `'A'-'F'` for pens, `.` for
transparent) and **encoded at runtime** (`encode_spr`) into interleaved
`(mask, data)` byte pairs. `draw_spr` walks those pairs: `AND` the mask into the
screen to punch transparency, then `OR` the data. `erase_rect` fills a bounding
box with pen 0. Both preserve `IX`/`IY` (used by the enemy pool).

## The scrolling cityscape

The terrain is a horizontally scrolling band along the bottom of the screen
(`TERR_NT` scanlines tall, sitting at `TERR_TOP`). It is held in an off-screen
`terr_bmp` buffer 128 columns wide and blitted into the back buffer every frame,
scrolled by the running `scroll_off` (the window wraps at 128).

- `build_terr_bmp` lays down flat green ground (`GROUND_H` rows at the bottom).
- `regen_terr_col` is a per-column **state machine** that scrolls fresh structure
  in on the right and never repeats. It decides building-vs-house, height, width
  and gaps from per-sector tables (`sect_house`, `sect_bh`, `sect_gap`) indexed by
  the current level, so the skyline evolves from city to houses across the game.
- `render_struct_col` draws one column: sky, then the structure rows, then ground.

**Window pattern.** Buildings are dark blue with single-pixel windows. A
wall row is `&C3` (both pixels pen 9, blue); `st_xor` toggles alternate rows to
`&49` (left pixel = pen 2 yellow window, right pixel = pen 9 gap). The result is
single-pixel windows with a blue gap horizontally (every other pixel) *and*
vertically (every other row). Houses use red walls (`&CC`) with the same trick
toggling to `&4C`.

The blit is the single most expensive thing the game does every frame — see
[PERFORMANCE.md](PERFORMANCE.md). It walks the back-buffer row table directly and
advances the source with a running pointer to avoid per-row address recomputation.

## Starfield

`N_STARS` stars in three parallax layers (different speeds). Each star is a single
pixel scrolling right at its layer speed; its previous position is *computed*
(`x - 2*speed mod 80`) rather than stored, so stars need no per-buffer shadow.
`render_stars` looks the star's row address up **once** and writes both the erase
and the new pixel from that base (they share a row).

## RNG

A 16-bit Galois LFSR (`taps &B400`, period 65535) drives star/enemy placement and
the cityscape. An earlier period-3 generator put everything in the same spot — the
LFSR fixed that.

## Title screen

The title runs in **Mode 1** (4 colours, 40 columns). "RETURN HOME" is rendered
**double-size** in pen 3 (each glyph row expanded through a 32-byte nibble table),
the rest in normal pen 2. Behind it, an **N-bar raster engine** changes pen 0
(the paper colour) at several scanline positions every frame: each bar has its own
colour cycle, speed and direction; a sorting network orders the bars by position
each frame so the single top-to-bottom beam can paint them in order, and
overlapping bars merge. This is all done under a VSYNC-polled `DI` loop.

## Game structure

The difficulty hierarchy (`pattern → wave → sector`) is described in the
[README](../README.md). In code: `start_wave` releases one pattern; `pat_in_wave`
(0-4) selects both the attack pattern and the enemy sprite, cycling all five each
wave; when it wraps, `wave_in_sector` increments; sector rollover (level up, or
win when level would exceed 5) is checked at the start of each fresh wave. Enemy
speed comes from `sector_speed[]` (fixed-point, 1.0-2.0 bytes/frame) and is
constant within a sector.

Five enemy types map one-to-one onto the five patterns of a wave: sine/white,
diagonal/red, wall/cyan, big-sine/yellow, snake/magenta. Two weave tables drive
the sine motion (the big-sine type uses the larger-amplitude table).

## Power-ups, bullets, collision

`weapon_level` is 0 (single), 1 (dual) or 2 (tri-spread). A `kill_streak` counts
kills; at `STREAK_NEED` (5 — a cleared wave) the weapon upgrades and the streak
resets. An enemy escaping off the right edge, or the player taking a hit, resets
the streak/weapon. Bullets carry a signed vertical velocity (`BL_VY`) so the
spread shots fan out. Bullets are small (2 px) and fast, with up to 16 in flight.

Collision is **swept**: `check_collisions` extends the bullet's leading edge by
its per-frame travel so a fast bullet can't tunnel through a 4-byte-wide enemy in
a single step.

## Sound

Direct PSG access through the PPI (`psg_write`, `D` = register, `E` = value). The
laser is a downward-swept tone on channel A with a volume decay; explosions are
white noise on channel B with a decaying envelope; the win/lose jingles use a
small note-table player. The mixer enables tone A + noise B.

Two VSYNC waits exist on purpose: the game loop uses a fast "wait until active"
(`wait_vsync`) that catches up on heavy frames, while the jingle player uses an
"inactive→active edge" wait (`wait_vsync_edge`) — without the edge wait the
note-timing loop runs through a note in a single VSYNC and the jingle is silent.

## Input

The keyboard is read straight from the PPI/PSG matrix into `key_buf[0..9]` (a
pressed key is a cleared bit). Cursor up/down (line 0 bits 0/2) and Space (line 5
bit 7) drive play; `Q/A/O/P` and the joystick are also read.

## The TOPGUN cheat

`cheat_check` runs in the title loop. It edge-detects each letter of `TOPGUN`
against the previous frame's matrix state using a `(line, bitmask)` sequence
table; a full match toggles `invincible` (and flips the border red).
`check_player_hit` returns early while invincible. It persists until a full
reload — the user toggles it at the title.

## Loading / win screens (overscan)

`assets/images.dsk` holds three 32 KB **CRTC-overscan** Mode 0 screens: 65
(loading), 69 (objectives) and 47 (win). The build extracts the `.SCR` payloads
and packs them onto the game disk.

- **65 (loading)** is the easy one: the BASIC loader shows it at boot (firmware
  still alive), then loads and runs the game.
- **47 (win)** is hard: by win time the firmware is gone and the game owns
  `&8000-&FFFF`. The 32 KB image cannot be reloaded from disk firmware-lessly, so
  it ships as `WIN.DAT` (skip-RLE compressed to ~5.6 KB; the image is 87 % black),
  loaded to `&2000` at boot and **decompressed at the win** into `&8200` with the
  lower ROM switched out. The overscan CRTC geometry is set up by hand
  (`R1=48, R2=50, R3=&89, R6=34, R7=35, R12=&2D`). "WELCOME HOME!" and the score
  are drawn into the black overscan borders.
- **69 (objectives)** ships on the disk but the in-game (post-title) display is not
  wired up yet — it would need the same firmware-less overscan path as 47.

Skip-RLE format is `[zero_run][literal_count][literal bytes]…`; the decompressor
pre-clears the target and skips the long black runs.
