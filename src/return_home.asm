;;============================================================================
;; RETURN HOME - Amstrad CPC Z80 Space Shooter  (Mode 0)
;; FIRMWARE-LESS, HARDWARE DOUBLE-BUFFERED engine.
;;
;; You head home to the LEFT: ship sits on the RIGHT facing LEFT, firing LEFT.
;; Enemies pour in from the LEFT moving right. 3-layer parallax starfield
;; scrolls right. Two screen buffers (&C000 / &8000) flipped each frame via
;; the CRTC for flicker-free display.
;;
;; Controls: Q / Cursor-Up    = Up
;;           A / Cursor-Down  = Down
;;           Space / Joy-Fire = Shoot
;;
;; Boot uses the firmware ONLY to set mode 0, the palette, and to copy the
;; character font into RAM. After that interrupts are disabled and the program
;; drives the hardware directly (CRTC display base, VSYNC, keyboard matrix).
;;
;; Assemble with the RASM / Maxam assembler.   ORG &4000 ,  RUN &4000
;;============================================================================

;;----------------------------------------------------------------------------
;; Firmware entry points (used at boot only)
;;----------------------------------------------------------------------------
SCR_SET_MODE    equ &BC0E
SCR_SET_INK     equ &BC32
SCR_SET_BORDER  equ &BC38

;;----------------------------------------------------------------------------
;; Hardware
;;----------------------------------------------------------------------------
;; CRTC: register-select port &BCxx, data port &BDxx
;; Gate-Array: port &7Fxx
;; PPI: port A=&F4xx, port B=&F5xx, port C=&F6xx, control=&F7xx

BUF0            equ &C000       ; screen buffer 0  (R12 = &30)
BUF1            equ &8000       ; screen buffer 1  (R12 = &20)
R12_BUF0        equ &30
R12_BUF1        equ &20

;;----------------------------------------------------------------------------
;; Screen / layout
;;----------------------------------------------------------------------------
SCR_W           equ 80          ; bytes per scanline (Mode 0)

PL_W            equ 8           ; player sprite width  (bytes) = 16 px
PL_H            equ 8
EN_W            equ 4           ; enemy  width (bytes) = 8 px
EN_H            equ 8
BL_W            equ 1           ; bullet width (bytes) = 2 px (small bolt)
BL_H            equ 2
EX_W            equ 4           ; explosion 8 px
EX_H            equ 8

MAX_ENE         equ 10
MAX_BUL         equ 16          ; lots of small bullets at once
MAX_EXP         equ 10
N_STARS         equ 24          ; 8 per parallax layer (fewer = faster; see frame budget)
WAVE_SIZE       equ 5           ; enemies per wave

PL_XSTART       equ 64
PL_XMIN         equ 22
PL_XMAX         equ 72
PL_YMIN         equ 22
PL_YMAX         equ 150         ; within enemy reach (no safe camping spot)
PL_YSTART       equ 80
PL_SPEED        equ 3

BL_SPEED        equ 4           ; bullets fly LEFT (slower; was 6 = tunnelled past enemies)
BL_SWEEP        equ BL_W+BL_SPEED  ; collision box covers a bullet's whole travel this frame
EN_ESCAPE       equ 76          ; enemy reaching here (right edge) is gone

PLAY_TOP        equ 22
PLAY_BOT        equ 170         ; enemies/stars stay above the terrain
TERR_TOP        equ 188         ; scrolling terrain band: y 188..199
TERR_NT         equ 12          ; terrain band height. The blit is TERR_NT*80 bytes EVERY
                                ; frame (~2.4% of the frame budget per row) - this is the
                                ; single biggest cost, so taller buildings cost real speed.
GROUND_H        equ 2           ; green ground rows at the bottom (city sits on it)
FIRE_DELAY      equ 5           ; frames between shots (rapid fire)
N_LEVELS        equ 5           ; 5 sectors to win
WAVES_PER_SECTOR equ 5          ; 5 waves per sector (speed constant within a sector)
WEAP_DUAL       equ 1           ; weapon levels: 0 single, 1 dual, 2 tri-spread
WEAP_TRI        equ 2
STREAK_NEED     equ 5           ; clear 5 in a row (a wave) to upgrade firepower
MARK_W          equ 1           ; sector progress post: 2px x 3 scanlines
MARK_H          equ 3
MARK_Y          equ 180         ; in the gap between play area and terrain

;; laser "pew": tone A swept from a high pitch DOWN, with a soft volume decay
SFX_FIRE_PER0   equ 56          ; starting period (smaller = higher pitch)
SFX_FIRE_STEP   equ 30          ; period added per frame (bigger = faster downward sweep)
SFX_FIRE_LEN    equ 5           ; frames the pew lasts (short, for rapid fire)

;; Enemy struct (13 bytes): logical + sine state + per-buffer draw shadow
EN_X            equ 0
EN_Y            equ 1           ; current (computed) y
EN_ACTIVE       equ 2
EN_TYPE         equ 3
EN_SPEED        equ 4           ; horizontal speed in 1/4-byte units (per sector)
EN_BASEY        equ 5           ; centre of vertical oscillation
EN_PHASE        equ 6           ; sine phase (0..31)
EN_SHADOW       equ 7           ; OX0,OY0,OA0,OX1,OY1,OA1
EN_FRAC         equ 13          ; sub-byte movement accumulator (1/4-byte units)
EN_SZ           equ 14

;; Bullet struct (10 bytes)
BL_X            equ 0
BL_Y            equ 1
BL_ACTIVE       equ 2
BL_SHADOW       equ 3           ; OX0,OY0,OA0,OX1,OY1,OA1
BL_VY           equ 9           ; signed vertical velocity (diagonal shots)
BL_SZ           equ 10

;; Explosion struct (9 bytes)
EX_X            equ 0
EX_Y            equ 1
EX_TIMER        equ 2           ; counts down; 0 = inactive
EX_SHADOW       equ 3           ; OX0,OY0,OA0,OX1,OY1,OA1
EX_SZ           equ 9

;; Star struct (3 bytes) - deterministic motion, old position is computed
ST_X            equ 0
ST_Y            equ 1
ST_SPD          equ 2
STAR_SZ         equ 3

;; Keyboard matrix key positions (line, bit) - pressed = bit CLEAR
;; line0 b0 Cursor-Up   b2 Cursor-Down
;; line5 b7 Space
;; line8 b3 Q           b5 A
;; line9 b0 Joy-Up b1 Joy-Down b4 Joy-Fire2 b5 Joy-Fire1

;;============================================================================
    org &4000

start:
    di
    ld sp,stack_end
    call set_crtc_std           ; force standard geometry (the loader leaves overscan on)
    call build_tables
    call init_sprites
    call sound_init
    call set_text_pen_white
    jp show_title

;;============================================================================
;; GATE ARRAY palette (firmware-less; hardware colour codes from garray docs)
;;============================================================================
;; A = value to send to the Gate Array (&7F)
ga_out:
    ld bc,&7F00
    out (c),a
    ret

;; program the 12 game pens + border (Mode 0) directly via the Gate Array
set_game_palette:
    ld hl,pal_game
    ld d,0                      ; pen number
sgp_loop:
    ld bc,&7F00
    ld a,d
    out (c),a                   ; select pen d
    ld a,(hl)
    out (c),a                   ; set its hardware colour
    inc hl
    inc d
    ld a,d
    cp 12
    jr nz,sgp_loop
    ld bc,&7F00
    ld a,&10
    out (c),a                   ; select border
    ld a,&54                    ; black
    out (c),a
    ret

;; program the 4 title pens + border (Mode 1) via the Gate Array
set_title_palette:
    ld hl,pal_title
    ld d,0
stp_loop:
    ld bc,&7F00
    ld a,d
    out (c),a
    ld a,(hl)
    out (c),a
    inc hl
    inc d
    ld a,d
    cp 4
    jr nz,stp_loop
    ld bc,&7F00
    ld a,&10
    out (c),a
    ld a,&54                    ; black border (raster bars override it per line)
    out (c),a
    ret

;;============================================================================
;; BUILD SCANLINE TABLES for both buffers
;;  tbl_c -> BUF0 (&C000),  tbl_8 -> BUF1 (&8000) = tbl_c - &4000
;;============================================================================
build_tables:
    ld ix,tbl_c
    ld hl,BUF0
    ld b,200
bt_loop:
    ld (ix+0),l
    ld (ix+1),h
    inc ix
    inc ix
    ld de,&800
    add hl,de                   ; next scanline within char block
    ld a,h
    and &38
    jr nz,bt_nowrap
    ld de,&C050                 ; (-&4000 + &50) mod 65536 : next char row
    add hl,de
bt_nowrap:
    djnz bt_loop
    ;; derive tbl_8 = tbl_c - &4000
    ld ix,tbl_c
    ld iy,tbl_8
    ld b,200
bt2_loop:
    ld l,(ix+0)
    ld h,(ix+1)
    ld de,&C000                 ; -&4000 mod 65536
    add hl,de
    ld (iy+0),l
    ld (iy+1),h
    inc ix
    inc ix
    inc iy
    inc iy
    djnz bt2_loop
    ret

;;============================================================================
;; CLEAR BOTH BUFFERS to pen 0
;;============================================================================
clear_buffers:
    ld hl,BUF1
    ld de,BUF1+1
    ld bc,&3FFF
    ld (hl),0
    ldir
    ld hl,BUF0
    ld de,BUF0+1
    ld bc,&3FFF
    ld (hl),0
    ldir
    ret

;;============================================================================
;; SET CRTC R12 (display base page)   A = R12 value
;;============================================================================
set_r12:
    ld bc,&BC0C                 ; select register 12
    out (c),c
    ld b,&BD
    ld c,a
    out (c),c                   ; write value
    ret

;; program the standard (non-overscan) Mode-0 CRTC geometry. The overscan
;; loading screen leaves R1=48/R6=34/R12=&0D, which garbles title + gameplay.
set_crtc_std:
    ld hl,crtc_std
    ld bc,&BC00
scs_l:
    ld a,(hl)                   ; register number (or &FF = end)
    cp &FF
    jr z,scs_done
    out (c),a                   ; B=&BC -> select register
    inc b                       ; B=&BD
    inc hl
    ld a,(hl)
    out (c),a                   ; write its value
    dec b                       ; B=&BC
    inc hl
    jr scs_l
scs_done:
    ret
crtc_std:
    defb 0,63, 1,40, 2,46, 3,&8E, 4,38, 5,0, 6,25, 7,30, 8,0, 9,7, 13,0
    defb &FF

;;============================================================================
;; WIN SCREEN (47): a 32K overscan image that is 87% black. Stored skip-RLE
;; compressed in the binary, decompressed firmware-LESS into main RAM at &8200,
;; shown as overscan. Works on 464 AND 6128 - NO banking (you can't get a 32K
;; contiguous region via 16K paging; the native &0200 base relocates cleanly to
;; &8200 = R12 &2D, a pure +&8000 two-page shift).
;;============================================================================
;; decompress win_data -> &8200. Format: [zero_run][lit_count][lit bytes]... ;
;; the canvas is pre-cleared so a zero-run just advances the write pointer.
;; The compressed image lives at &2000 (loaded there by the DISC loader as WIN.DAT),
;; freeing the code region. &2000 is under the lower ROM, so read it with ROM off.
WIN_DATA        equ &2000
decomp_win:
    ld bc,&7F8C                 ; mode0, both ROMs off -> &2000..&3FFF = RAM
    out (c),c
    ld hl,&8200                 ; clear the 31936-byte displayed area to black
    ld (hl),0
    ld de,&8201
    ld bc,&7CBF
    ldir
    ld hl,WIN_DATA
    ld de,&8200
dw_loop:
    ld a,(hl)                   ; zero-run -> skip (already black)
    inc hl
    add a,e
    ld e,a
    jr nc,dw_l2
    inc d
dw_l2:
    ld a,(hl)                   ; literal count
    inc hl
    or a
    jr z,dw_chk
    ld b,a
dw_cp:
    ld a,(hl)
    ld (de),a
    inc hl
    inc de
    djnz dw_cp
dw_chk:
    ld a,d
    cp &FE
    jr c,dw_loop
    ld a,e
    cp &C0
    jr c,dw_loop                ; loop until DE reaches &FEC0
    ld bc,&7F88                 ; restore game ROM config (lower ROM on)
    out (c),c
    ret

;; overscan CRTC geometry; screen base &8200 (R12=&2D)
set_crtc_overscan:
    ld hl,crtc_over
    ld bc,&BC00
sco_l:
    ld a,(hl)
    cp &FF
    jr z,sco_done
    out (c),a
    inc b
    inc hl
    ld a,(hl)
    out (c),a
    dec b
    inc hl
    jr sco_l
sco_done:
    ret
crtc_over:
    defb 1,48, 2,50, 3,&89, 6,34, 7,35, 12,&2D, 13,0
    defb &FF

;; set the win image's 16 inks directly (hardware codes converted from its
;; firmware ink table) - no firmware needed
set_win_palette:
    ld hl,win_pal
    ld d,0
swp_l:
    ld bc,&7F00
    ld a,d
    out (c),a
    ld a,(hl)
    out (c),a
    inc hl
    inc d
    ld a,d
    cp 16
    jr c,swp_l
    ret

;; ---- text on the overscan win screen (drawn into the black borders) ----
;; render a Mode-0 glyph IX (8 bytes) at cell address HL (raster 0); 8 rows, +&800
;; each; uses text_pp (set_text_pen). Copied from my_putc's 4-byte row render.
render_over_char:
    ld b,8
roc_row:
    push bc
    push hl
    ld a,(ix+0)
    ld e,a
    rlca
    rlca
    and 3
    call pp_lookup
    ld (hl),a
    inc hl
    ld a,e
    rlca
    rlca
    rlca
    rlca
    and 3
    call pp_lookup
    ld (hl),a
    inc hl
    ld a,e
    rrca
    rrca
    and 3
    call pp_lookup
    ld (hl),a
    inc hl
    ld a,e
    and 3
    call pp_lookup
    ld (hl),a
    inc ix
    pop hl
    ld a,h
    add a,8
    ld h,a                      ; HL += &800 (next raster line)
    pop bc
    djnz roc_row
    ret

;; draw string DE at overscan line base HL, start char col B (0..23), current pen
draw_over_str:
    ld (dos_base),hl
dos_l:
    ld a,(de)
    or a
    ret z
    push de
    push bc
    sub 32                      ; glyph addr -> IX
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl
    ld de,font_tbl
    add hl,de
    push hl
    pop ix
    ld hl,(dos_base)            ; cell = line base + col*4
    pop bc
    push bc
    ld a,b
    add a,a
    add a,a
    ld c,a
    ld b,0
    add hl,bc
    call render_over_char
    pop bc
    pop de
    inc de
    inc b
    jr dos_l

;; poke the 16-bit score as 4 ASCII digits into win_msg+6 ("SCORE nnnn")
score_to_msg:
    ld hl,(score)
    ld de,win_msg+6
    ld bc,1000
    call stm_dig
    ld bc,100
    call stm_dig
    ld bc,10
    call stm_dig
    ld a,l
    add a,'0'
    ld (de),a
    ret
stm_dig:
    ld a,'0'
stm_l:
    or a
    sbc hl,bc
    jr c,stm_done
    inc a
    jr stm_l
stm_done:
    add hl,bc
    ld (de),a
    inc de
    ret

;;============================================================================
;; WAIT FOR VSYNC  (PPI port B bit 0)
;;============================================================================
;; game loop: wait until VSYNC active (fast - returns immediately if already in
;; vsync so heavy frames catch up instead of dropping to 25fps).
wait_vsync:
    ld b,&F5
wv_loop:
    in a,(c)
    rra
    jr nc,wv_loop
    ret

;; play_tune needs a true EDGE wait (inactive->active) so its tight per-note loop
;; doesn't spin through a whole note inside one vsync window.
wait_vsync_edge:
    ld b,&F5
wve_off:
    in a,(c)
    rra
    jr c,wve_off
wve_on:
    in a,(c)
    rra
    jr nc,wve_on
    ret

;;============================================================================
;; READ KEYBOARD MATRIX into key_buf[0..9]  (pressed = bit clear)
;; Standard PPI/PSG sequence.
;;============================================================================
read_keys:
    ld bc,&F782                 ; PPI control: Port A output
    out (c),c
    ld bc,&F40E                 ; Port A = 14 (PSG register index of port A)
    out (c),c
    ld bc,&F6C0                 ; Port C: PSG "select register" (bits7,6=11)
    out (c),c
    ld bc,&F600                 ; Port C: inactive (bits7,6=00)
    out (c),c
    ld bc,&F792                 ; PPI control: Port A input
    out (c),c
    ld hl,key_buf
    ld a,&40                    ; Port C value: read (bit6=1) + line 0
rk_loop:
    ld b,&F6
    ld c,a
    out (c),c                   ; select matrix line + PSG read
    ld b,&F4
    in e,(c)                    ; read Port A = line data
    ld (hl),e
    inc hl
    inc a
    cp &4A                      ; &40 + 10 lines done
    jr nz,rk_loop
    ld bc,&F600                 ; Port C inactive
    out (c),c
    ld bc,&F782                 ; Port A back to output
    out (c),c
    ret

;;============================================================================
;; TEXT  - render using the copied font, opaque (set bit = text pen, else pen0)
;;============================================================================
;; SET TEXT PEN: A = pen -> builds text_pp[4] pair table
set_text_pen_white:
    ld a,6
set_text_pen:
    push af
    call lookup_left            ; A = m0_left[pen]
    ld (text_pp+2),a
    ld d,a
    pop af
    call lookup_right           ; A = m0_right[pen]
    ld (text_pp+1),a
    or d
    ld (text_pp+3),a
    xor a
    ld (text_pp+0),a
    ret

;; PP LOOKUP: A = 0..3 -> A = text_pp[A].  Preserves everything else.
pp_lookup:
    push hl
    ld hl,text_pp
    add a,l
    ld l,a
    ld a,0
    adc a,h
    ld h,a
    ld a,(hl)
    pop hl
    ret

;; PUTC: A=char, B=col(0-19), C=row(0-24) -> draw into draw_tbl buffer
my_putc:
    sub 32
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl                   ; *8
    ld de,font_tbl
    add hl,de
    push hl
    pop ix                      ; IX = glyph
    ld a,b
    add a,a
    add a,a                     ; col*4 = X byte
    ld (mpc_x),a
    ld a,c
    add a,a
    add a,a
    add a,a                     ; row*8 = Y line
    ld (mpc_y),a
    ld b,8
mpc_loop:
    push bc
    ld a,(mpc_x)
    ld h,a
    ld a,(mpc_y)
    ld l,a
    call get_scr_addr           ; HL = screen addr
    ld a,(ix+0)
    ld e,a                      ; glyph row bits
    rlca
    rlca
    and 3
    call pp_lookup
    ld (hl),a
    inc hl
    ld a,e
    rlca
    rlca
    rlca
    rlca
    and 3
    call pp_lookup
    ld (hl),a
    inc hl
    ld a,e
    rrca
    rrca
    and 3
    call pp_lookup
    ld (hl),a
    inc hl
    ld a,e
    and 3
    call pp_lookup
    ld (hl),a
    inc ix
    ld a,(mpc_y)
    inc a
    ld (mpc_y),a
    pop bc
    djnz mpc_loop
    ret

;; PRINT: HL=string(0-term), B=col, C=row
my_print:
    ld a,(hl)
    or a
    ret z
    push hl
    push bc
    call my_putc
    pop bc
    pop hl
    inc hl
    inc b                       ; next column
    jr my_print

;;============================================================================
;; GET SCREEN ADDRESS  (uses draw_tbl = current back-buffer table)
;; IN:  H = x byte, L = y scanline.   OUT: HL = address.  BC,DE preserved.
;;============================================================================
;; H=x byte, L=y -> HL=screen addr.  Preserves DE; CLOBBERS BC (hot path: called
;; ~80x/frame by sprites/stars, none of which need BC across it; the lone title
;; caller that does - title_draw_stars - saves it itself).
get_scr_addr:
    push de
    ld c,h
    ld h,0
    add hl,hl
    ld de,(draw_tbl)
    add hl,de
    ld a,(hl)
    inc hl
    ld h,(hl)
    ld l,a
    ld b,0
    add hl,bc
    pop de
    ret

;; A = pen (0-15) -> A = Mode 0 LEFT pixel bits.  Preserves all but A,F.
lookup_left:
    push hl
    ld hl,m0_left
    add a,l
    ld l,a
    ld a,0
    adc a,h
    ld h,a
    ld a,(hl)
    pop hl
    ret

;; A = pen -> A = Mode 0 RIGHT pixel bits.
lookup_right:
    push hl
    ld hl,m0_right
    add a,l
    ld l,a
    ld a,0
    adc a,h
    ld h,a
    ld a,(hl)
    pop hl
    ret

;;============================================================================
;; SOUND  (direct PSG access via PPI)
;;============================================================================
;; write PSG register: D = register, E = value
psg_write:
    ld bc,&F782                 ; PPI control: Port A output
    out (c),c
    ld b,&F4
    out (c),d                   ; Port A = register number
    ld bc,&F6C0                 ; Port C: PSG select-register
    out (c),c
    ld bc,&F600                 ; inactive
    out (c),c
    ld b,&F4
    out (c),e                   ; Port A = data
    ld bc,&F680                 ; Port C: PSG write
    out (c),c
    ld bc,&F600                 ; inactive
    out (c),c
    ret

sound_init:
    ld d,7
    ld e,&2E                    ; mixer: tone A on, noise B on, AY port A input
    call psg_write
    ld d,8
    ld e,0
    call psg_write
    ld d,9
    ld e,0
    call psg_write
    ld d,6
    ld e,8                      ; noise period
    call psg_write
    ret

sound_fire:
    call rng                    ; small per-shot pitch wobble -> less repetitive
    and 15
    add a,SFX_FIRE_PER0
    ld l,a
    ld h,0
    ld (snd_a_per),hl
    ld d,0
    ld e,l
    call psg_write              ; R0 tone A period low
    ld d,1
    ld e,0
    call psg_write              ; R1 tone A period high
    ld d,8
    ld e,14
    call psg_write              ; R8 volume A
    ld a,SFX_FIRE_LEN
    ld (snd_a_t),a
    ret

sound_expl:
    ld d,6
    ld e,20
    call psg_write              ; deeper/coarser noise period -> meatier boom
    ld d,9
    ld e,15
    call psg_write              ; channel B noise, full volume
    ld a,16                     ; longer decay tail
    ld (snd_b_t),a
    ret

;; firepower upgrade chime (non-blocking; sound_update plays the rising tone)
sound_powerup:
    ld a,14
    ld (pu_snd_t),a
    ret

sound_update:
    ld a,(pu_snd_t)
    or a
    jr z,su_laser
    ;; POWERUP: a rising tone on channel A (briefly overrides the laser)
    dec a
    ld (pu_snd_t),a
    jr z,su_a_off
    add a,a
    add a,a
    add a,a                     ; period = pu_snd_t*8 + 40 (falls -> pitch rises)
    add a,40
    ld d,0
    ld e,a
    call psg_write              ; R0
    ld d,1
    ld e,0
    call psg_write              ; R1 = 0
    ld d,8
    ld e,15
    call psg_write              ; R8 full volume
    jr su_b
su_laser:
    ld a,(snd_a_t)
    or a
    jr z,su_b
    dec a
    ld (snd_a_t),a
    jr z,su_a_off               ; pew finished -> mute channel A
    ;; sweep the pitch downward and let the volume decay
    ld hl,(snd_a_per)
    ld de,SFX_FIRE_STEP
    add hl,de
    ld (snd_a_per),hl
    ld d,0
    ld e,l
    call psg_write              ; R0 = period low
    ld a,h
    and 15
    ld d,1
    ld e,a
    call psg_write              ; R1 = period high (12-bit)
    ld a,(snd_a_t)
    add a,5                     ; volume ~13 down to ~6 as it fades
    ld d,8
    ld e,a
    call psg_write
    jr su_b
su_a_off:
    ld d,8
    ld e,0
    call psg_write              ; mute fire
su_b:
    ld a,(snd_b_t)
    or a
    jr z,su_done
    dec a
    ld (snd_b_t),a
    ld d,9
    ld e,a                      ; decay noise volume
    call psg_write
su_done:
    ret

;; silence both channels (also stops any decaying SFX)
sound_silence:
    ld d,8
    ld e,0
    call psg_write
    ld d,9
    ld e,0
    call psg_write
    xor a
    ld (snd_a_t),a
    ld (snd_b_t),a
    ret

;; play a jingle on channel A.  HL = (period_lo, period_hi, frames)*, frames 0 ends
play_tune:
pt_next:
    ld a,(hl)
    inc hl
    ld (note_lo),a
    ld a,(hl)
    inc hl
    ld (note_hi),a
    ld a,(hl)
    inc hl
    or a
    jr z,pt_done
    ld (note_dur),a
    push hl
    ld d,0
    ld a,(note_lo)
    ld e,a
    call psg_write              ; R0 tone A low
    ld d,1
    ld a,(note_hi)
    ld e,a
    call psg_write              ; R1 tone A high
    ld d,8
    ld e,13
    call psg_write              ; R8 volume A
    ld a,(note_dur)
    ld b,a
pt_wait:
    push bc
    call wait_vsync_edge
    pop bc
    djnz pt_wait
    pop hl
    jr pt_next
pt_done:
    call sound_silence
    ret

;;============================================================================
;; TERRAIN  (random scrolling green hills)
;;  A 128-column random-walk height map -> terr_bmp (128 x TERR_NT). Each frame
;;  an 80-byte window at scroll_off (wrapping at 128) is copied into the band.
;;============================================================================
;; random-walk height map (128 columns)
gen_terr_heights:
    ld ix,th_rand
    ld c,6                      ; current height
    ld b,128
gth_loop:
    call rng
    and 3
    add a,c
    sub 1                       ; step -1..+2
    cp 3
    jr nc,gth_lo
    ld a,3
gth_lo:
    cp TERR_NT-1
    jr c,gth_hi
    ld a,TERR_NT-2
gth_hi:
    ld c,a
    ld (ix+0),a
    inc ix
    djnz gth_loop
    ret

;; build the initial bitmap: flat green ground (bottom GROUND_H rows), rest sky.
;; Buildings/houses scroll in via regen_terr_col.
build_terr_bmp:
    ld hl,terr_bmp
    ld c,0                      ; row
btb_row:
    ld a,c
    cp TERR_NT-GROUND_H         ; rows >= this are ground
    ld a,0
    jr c,btb_fill
    ld a,&30                    ; green ground (pen 4)
btb_fill:
    ld b,128
btb_col:
    ld (hl),a
    inc hl
    djnz btb_col
    inc c
    ld a,c
    cp TERR_NT
    jr nz,btb_row
    ret

;; scroll + blit the band into the current (back) buffer (window wraps at 128).
;; Hot path: dst addresses come straight from the back-buffer row table
;; (terrain x is always 0), and the source walks with a running +128 pointer -
;; no per-row get_scr_addr / *128 recompute (that was ~16% of frame time).
draw_terrain_scroll:
    ld a,(scroll_off)
    dec a
    and 127
    ld (scroll_off),a
    ld (dts_off),a              ; cache it (used every row)
    call regen_terr_col         ; fresh random column scrolls in -> never repeats
    ld hl,(draw_tbl)
    ld de,TERR_TOP*2
    add hl,de
    ld (dts_dtp),hl             ; -> row-address table entry for TERR_TOP
    ld hl,terr_bmp
    ld (dts_srcrow),hl          ; src base for row 0
    ld a,TERR_NT
    ld (dts_r),a                ; row down-counter
dts_row:
    ld hl,(dts_dtp)             ; DE = dst = table[row]  (x=0)
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld (dts_dtp),hl             ; advance to next row's entry
    ld hl,(dts_srcrow)          ; HL = src base
    ld a,(dts_off)
    ld c,a
    ld b,0
    add hl,bc                   ; HL = src + off
    ld a,128
    sub c                       ; n1 = 128 - off
    cp 80
    jr c,dts_wrap
    ld bc,80
    ldir
    jr dts_next
dts_wrap:
    ld c,a                      ; n1 (<80)
    ld b,0
    ld a,80
    sub c                       ; rem = 80 - n1
    push af
    ldir                        ; copy n1 (src+off..end -> dst)
    ld hl,(dts_srcrow)          ; src base again (DE continues)
    pop af
    ld c,a
    ld b,0
    ldir                        ; copy rem from src base
dts_next:
    ld hl,(dts_srcrow)          ; src base += 128 for next row
    ld de,128
    add hl,de
    ld (dts_srcrow),hl
    ld a,(dts_r)
    dec a
    ld (dts_r),a
    jr nz,dts_row
    ret

;; regenerate the incoming column (= scroll_off): flat green ground with a
;; cityscape of buildings/houses sitting ON it, scrolling with the terrain. The
;; mix + size evolve per sector (level): big city -> smaller -> all houses.
regen_terr_col:
    ld a,(st_cnt)
    or a
    jp nz,rtc_draw              ; still drawing the current structure
    ld a,(gap_cnt)
    or a
    jr z,rtc_new
    dec a
    ld (gap_cnt),a
    xor a
    ld (st_h),a                 ; gap column -> just ground (height 0)
    jp rtc_draw
rtc_new:
    ld a,(level)
    dec a
    ld e,a
    ld d,0
    ld hl,sect_house
    add hl,de
    ld c,(hl)                   ; house chance for this sector
    call rng
    cp c
    jr c,rtc_house              ; rng < chance -> house
    ;; building: blue + windows, taller
    ld hl,sect_bh
    add hl,de
    ld a,(hl)
    ld c,a
    call rng
    and 3
    add a,c                     ; height = base + 0..3
    cp TERR_NT-GROUND_H+1
    jr c,rtc_hok
    ld a,TERR_NT-GROUND_H       ; cap
rtc_hok:
    ld (st_h),a
    ld a,&C3
    ld (st_wall),a              ; dark-blue wall (both pixels pen 9)
    ld a,&8A
    ld (st_xor),a               ; toggle to &49 = single yellow window + blue gap
    call rng
    and 3
    add a,2                     ; width 2..5 windows
    ld (st_cnt),a
    jr rtc_gap
rtc_house:
    call rng
    and 1
    add a,3                     ; height 3..4
    ld (st_h),a
    ld a,&CC
    ld (st_wall),a              ; red wall (both pixels pen 3)
    ld a,&80
    ld (st_xor),a               ; toggle to &4C = yellow window + red gap
    call rng
    and 1
    add a,2                     ; width 2..3
    ld (st_cnt),a
rtc_gap:
    ld a,(level)
    dec a
    ld e,a
    ld d,0
    ld hl,sect_gap
    add hl,de
    ld a,(hl)
    ld b,a
    call rng
    and 1
    add a,b
    ld (gap_after),a
rtc_draw:
    ld a,(scroll_off)
    ld e,a
    ld d,0
    ld hl,terr_bmp
    add hl,de
    ld de,128
    call render_struct_col
    ld a,(st_cnt)
    or a
    ret z                       ; gap column: nothing to decrement
    dec a
    ld (st_cnt),a
    ret nz
    ld a,(gap_after)            ; structure finished -> arm the gap
    ld (gap_cnt),a
    ret

;; render one terrain column at HL (terr_bmp+col), DE=128: (TERR_NT-GROUND_H-st_h)
;; sky, st_h structure rows (st_wall toggled by st_xor), GROUND_H green rows.
render_struct_col:
    ld a,TERR_NT-GROUND_H
    ld b,a
    ld a,(st_h)
    ld c,a
    ld a,b
    sub c                       ; sky rows above the structure
    jr z,rsc_body
    ld b,a
rsc_sky:
    ld (hl),0
    add hl,de
    djnz rsc_sky
rsc_body:
    ld a,(st_h)
    or a
    jr z,rsc_ground
    ld b,a
    ld a,(st_wall)
    ld c,a
rsc_wall:
    ld (hl),c
    add hl,de
    ld a,(st_xor)
    xor c
    ld c,a                      ; toggle wall<->window (xor 0 = solid)
    djnz rsc_wall
rsc_ground:
    ld b,GROUND_H
rsc_grn:
    ld (hl),&30
    add hl,de
    djnz rsc_grn
    ret

;; per-sector cityscape parameters (index = level-1)
sect_house:     defb 0, 0, 70, 160, 255    ; rng(0-255) < this -> a house (else building)
sect_bh:        defb 9, 7, 5, 4, 3          ; building base height (+0..3, capped) -> windows
sect_gap:       defb 1, 1, 2, 3, 5          ; ground gap (>=1 so buildings stay separate)

;;============================================================================
;; ENCODE SPRITES - pack ASCII pen-art into interleaved (mask,data) buffers
;;============================================================================
init_sprites:
    ld ix,pl_pen
    ld de,pl_spr
    ld b,PL_W*PL_H             ; pixel pairs
    call encode_spr
    ld ix,en0_pen
    ld de,en_spr0
    ld b,EN_W*EN_H
    call encode_spr
    ld ix,en1_pen
    ld de,en_spr1
    ld b,EN_W*EN_H
    call encode_spr
    ld ix,en2_pen
    ld de,en_spr2
    ld b,EN_W*EN_H
    call encode_spr
    ld ix,en3_pen
    ld de,en_spr3
    ld b,EN_W*EN_H
    call encode_spr
    ld ix,en4_pen
    ld de,en_spr4
    ld b,EN_W*EN_H
    call encode_spr
    ld ix,bul_pen
    ld de,bul_spr
    ld b,BL_W*BL_H
    call encode_spr
    ld ix,mark_lit_pen
    ld de,mark_lit_spr
    ld b,MARK_W*MARK_H
    call encode_spr
    ld ix,mark_dim_pen
    ld de,mark_dim_spr
    ld b,MARK_W*MARK_H
    call encode_spr
    ld ix,exp0_pen
    ld de,exp_spr0
    ld b,EX_W*EX_H
    call encode_spr
    ld ix,exp1_pen
    ld de,exp_spr1
    ld b,EX_W*EX_H
    call encode_spr
    ld ix,exp2_pen
    ld de,exp_spr2
    ld b,EX_W*EX_H
    call encode_spr
    ret

encode_spr:
    ;; IX = src ascii, DE = dest, B = pixel pairs
    ;; pen chars: '0'-'9' = 0-9 , 'A'-'F' = 10-15
es_loop:
    ld a,(ix+0)
    call pen_digit
    call lookup_left
    ld c,a                      ; left pixel bits
    ld a,(ix+1)
    call pen_digit
    call lookup_right
    or c
    ld c,a                      ; data byte
    ld l,0                      ; mask accumulator
    and &AA
    jr nz,es_lo
    ld l,&AA                    ; left pixel transparent
es_lo:
    ld a,c
    and &55
    jr nz,es_ro
    ld a,l
    or &55                      ; right pixel transparent
    ld l,a
es_ro:
    ld a,l
    ld (de),a                   ; mask
    inc de
    ld a,c
    ld (de),a                   ; data
    inc de
    inc ix
    inc ix
    djnz es_loop
    ret

;; A = ASCII pen char -> A = pen value (0-15).  '0'-'9'->0-9, 'A'-'F'->10-15
pen_digit:
    sub '0'
    cp 10
    ret c
    sub 7                       ; 'A'(=17 after sub'0') -> 10
    ret

;;============================================================================
;; DRAW SPRITE (interleaved mask,data) into draw_tbl buffer
;; IN: DE=sprite, H=x byte, L=y, B=height, C=width(bytes). Preserves IX/IY.
;;============================================================================
draw_spr:
    ld a,c
    ld (spr_w),a
    ld a,b
    ld (spr_h),a
    call get_scr_addr           ; HL = first row addr (BC,DE preserved)
dspr_row:
    push hl
    ld a,(spr_w)
    ld b,a
dspr_col:
    ld a,(de)
    inc de
    and (hl)
    ld c,a
    ld a,(de)
    inc de
    or c
    ld (hl),a
    inc hl
    djnz dspr_col
    pop hl
    call adv_line               ; HL -> next scanline (AF only)
    ld a,(spr_h)
    dec a
    ld (spr_h),a
    jr nz,dspr_row
    ret

;; advance HL to the next scanline (CPC interleaved layout). Clobbers AF only.
adv_line:
    ld a,h
    add a,8
    ld h,a
    and &38
    ret nz
    ld a,l
    add a,&50
    ld l,a
    ld a,h
    adc a,&C0
    ld h,a
    ret

;;============================================================================
;; ERASE RECTANGLE (fill pen 0) into draw_tbl buffer
;; IN: H=x byte, L=y, B=height, C=width.  Preserves IX/IY.
;;============================================================================
erase_rect:
    ld a,c
    ld (spr_w),a
    ld a,b
    ld (spr_h),a
    call get_scr_addr
erct_row:
    push hl
    ld a,(spr_w)
    ld b,a
erct_col:
    ld (hl),0
    inc hl
    djnz erct_col
    pop hl
    call adv_line
    ld a,(spr_h)
    dec a
    ld (spr_h),a
    jr nz,erct_row
    ret

;;============================================================================
;; MEMCLR / RNG
;;============================================================================
memclr:
    ld (hl),0
    ld d,h
    ld e,l
    inc de
    dec bc
    ld a,b
    or c
    ret z
    ldir
    ret

;; 16-bit Galois LFSR (period 65535). OUT: A. Preserves BC/DE/IX/IY.
rng:
    push hl
    ld hl,(rng_seed)
    srl h
    rr l
    jr nc,rng_nc
    ld a,h
    xor &B4
    ld h,a
rng_nc:
    ld (rng_seed),hl
    ld a,h
    pop hl
    ret

;;============================================================================
;; FIRE PRESSED?  -> Carry set if any fire key/button is down
;;============================================================================
fire_pressed:
    ld a,(key_buf+5)
    bit 7,a
    jr z,fp_yes
    ld a,(key_buf+9)
    bit 5,a
    jr z,fp_yes
    ld a,(key_buf+9)
    bit 4,a
    jr z,fp_yes
    or a
    ret
fp_yes:
    scf
    ret

wait_fire_release:
    call read_keys
    call fire_pressed
    jr nc,wfr_done
    call wait_vsync
    jr wait_fire_release
wfr_done:
    ret

;;============================================================================
;; TITLE  (Mode 1, centred text, static starfield, scrolling PEN-0 raster bars)
;;  Raster bars change PEN 0 (the screen paper) per band, interrupt(HALT)-synced
;;  so they fill the screen behind the text. Timing values are tunable.
;;============================================================================
RB_BARLEN       equ end_bar-bar_pulse  ; colours in the bar
RB_LINEDLY      equ 64-4-2-2-1-3       ; NOP delay per colour band (~1 scanline)
BAR_MIN         equ 210               ; bar position at top of visible screen (tune)
BAR_MAX         equ 2600              ; bar position near bottom; wraps (tune)
BAR_STEP        equ 12                ; bar 1 (red)  scrolls DOWN, fast
BAR_STEP2       equ 10                ; bar 2 (neon) scrolls UP,   medium -> crossover drifts
BAR_STEP3       equ 7                 ; bar 3 (green) scrolls DOWN, slow  -> laps bar 1
NBARS           equ 3                 ; number of raster bars
BAR_H           equ 115               ; one bar's drawn height in position-units (~10 lines)

show_title:
    ld a,&89
    call ga_out                 ; Mode 1, upper ROM off (so &C000 reads = RAM)
    call set_title_palette
    ld hl,tbl_c
    ld (draw_tbl),hl
    ld a,R12_BUF0
    call set_r12
    call clear_buffers
    call init_stars
    call title_draw_stars       ; static stars (behind the text)
    ld hl,str_title
    ld c,3
    call m1_center2x            ; BIG yellow "RETURN HOME" (rows 3-4)
    ld hl,str_sub
    ld c,7
    call m1_center
    ld hl,str_c1
    ld c,10
    call m1_center
    ld hl,str_c2
    ld c,11
    call m1_center
    ld hl,str_c3
    ld c,12
    call m1_center
    ld hl,str_c4
    ld c,13
    call m1_center
    ld hl,str_goal
    ld c,16
    call m1_center
    ld hl,str_press
    ld c,19
    call m1_center
    call init_raster            ; copy pulse colours to the working buffer
    ld hl,BAR_MIN
    ld (bar_pos),hl             ; bar 1 starts at the top, scrolls down
    ld hl,BAR_MAX
    ld (bar2_pos),hl            ; bar 2 starts at the bottom, scrolls up
    ld hl,BAR_MIN+(BAR_MAX-BAR_MIN)/2
    ld (bar3_pos),hl            ; bar 3 starts in the middle, scrolls down
    ;; PEN 0 black to begin with (background above/below the bars)
    ld bc,&7F00
    out (c),c
    ld a,&54
    out (c),a
title_loop:
    ;; wait for the start of VSYNC (interrupts stay OFF throughout - no firmware
    ;; interrupt to re-apply its palette, and nothing for a direct CALL to fight)
    ld b,&F5
tl_vs:
    in a,(c)
    rra
    jr nc,tl_vs
    call build_barr             ; collect the 3 bars into the sort array
    call sort_barr              ; order them top-to-bottom (beam goes down)
    call draw_bars              ; wait+paint each in order
    call rotate_bars            ; shimmer all three pulses
    ;; bar 1 scrolls DOWN (wrap MAX -> MIN)
    ld hl,(bar_pos)
    ld de,BAR_STEP
    add hl,de
    ld de,BAR_MAX
    ld a,h
    cp d
    jr c,b1_store
    jr nz,b1_wrap
    ld a,l
    cp e
    jr c,b1_store
b1_wrap:
    ld hl,BAR_MIN
b1_store:
    ld (bar_pos),hl
    ;; bar 2 scrolls UP (wrap MIN -> MAX), a touch slower than bar 1
    ld hl,(bar2_pos)
    ld de,BAR_STEP2
    or a
    sbc hl,de
    ld de,BAR_MIN
    ld a,h
    cp d
    jr c,b2_wrap
    jr nz,b2_store
    ld a,l
    cp e
    jr nc,b2_store
b2_wrap:
    ld hl,BAR_MAX
b2_store:
    ld (bar2_pos),hl
    ;; bar 3 scrolls DOWN (wrap MAX -> MIN), slower than bar 1
    ld hl,(bar3_pos)
    ld de,BAR_STEP3
    add hl,de
    ld de,BAR_MAX
    ld a,h
    cp d
    jr c,b3_store
    jr nz,b3_wrap
    ld a,l
    cp e
    jr c,b3_store
b3_wrap:
    ld hl,BAR_MIN
b3_store:
    ld (bar3_pos),hl
    call read_keys
    call cheat_check            ; TOPGUN toggles invincible mode
    call fire_pressed
    jp nc,title_loop
    ld a,&88
    call ga_out                 ; Mode 0, upper ROM off
    call set_game_palette
    jp game_start

;; Watch for the letters T-O-P-G-U-N typed in order on the title screen; each
;; full match toggles invincible mode (and the border: red = on). Edge-detected
;; against last frame's keys so held keys count once.
cheat_check:
    ld a,(cheat_idx)
    add a,a
    ld e,a
    ld d,0
    ld hl,cheat_seq
    add hl,de
    ld c,(hl)                   ; keyboard line
    inc hl
    ld b,(hl)                   ; bit mask
    ld hl,key_buf
    ld e,c
    ld d,0
    add hl,de
    ld a,(hl)
    and b
    jr nz,cc_save               ; expected key not down now
    ld hl,prev_keys
    add hl,de
    ld a,(hl)
    and b
    jr z,cc_save                ; was already down last frame -> not a new press
    ;; new press of the expected letter -> advance
    ld a,(cheat_idx)
    inc a
    cp 6
    jr c,cc_store
    ;; TOPGUN complete -> toggle invincible + border feedback
    ld a,(invincible)
    xor 1
    ld (invincible),a
    call cheat_border
    xor a                       ; reset sequence
cc_store:
    ld (cheat_idx),a
cc_save:
    ld hl,key_buf               ; remember this frame's keys for edge detection
    ld de,prev_keys
    ld bc,10
    ldir
    ret

;; border red while invincible armed, black otherwise
cheat_border:
    ld bc,&7F00
    ld a,&10
    out (c),a                   ; select border (pen 16)
    ld a,(invincible)
    or a
    jr z,cb_off
    ld a,&4C                    ; bright red
    jr cb_set
cb_off:
    ld a,&54                    ; black
cb_set:
    out (c),a
    ret

;; gather the three bars (position + colour buffer) into the sort array `barr`
build_barr:
    ld hl,(bar_pos)
    ld (barr+0),hl
    ld hl,bar_buf
    ld (barr+2),hl
    ld hl,(bar2_pos)
    ld (barr+4),hl
    ld hl,bar2_buf
    ld (barr+6),hl
    ld hl,(bar3_pos)
    ld (barr+8),hl
    ld hl,bar3_buf
    ld (barr+10),hl
    ret

;; sort `barr` by position ascending (3-element sorting network)
sort_barr:
    ld hl,barr+0
    ld de,barr+4
    call cmpswap
    ld hl,barr+4
    ld de,barr+8
    call cmpswap
    ld hl,barr+0
    ld de,barr+4
    call cmpswap
    ret

;; HL -> entry A, DE -> entry B (4 bytes each); swap both if A.pos > B.pos
cmpswap:
    ld c,(hl)
    inc hl
    ld b,(hl)
    dec hl                     ; BC = A.pos, HL -> A (start)
    push hl                    ; save A pointer
    ld a,(de)                  ; B.pos low
    ld l,a
    inc de
    ld a,(de)                  ; B.pos high
    ld h,a
    dec de                     ; HL = B.pos, DE -> B (start)
    or a
    sbc hl,bc                  ; B.pos - A.pos ; carry => B < A => A > B => swap
    pop hl                     ; HL -> A (start)
    ret nc                     ; A.pos <= B.pos, already ordered
    ld b,4                     ; swap 4 bytes A<->B
cs_swap:
    ld a,(hl)
    ld c,a
    ld a,(de)
    ld (hl),a
    ld a,c
    ld (de),a
    inc hl
    inc de
    djnz cs_swap
    ret

;; walk the sorted array, waiting then painting each bar in beam order
draw_bars:
    ld hl,0
    ld (beam_pos),hl
    ld ix,barr
    ld b,NBARS
db_loop:
    push bc
    ld l,(ix+0)
    ld h,(ix+1)                ; HL = this bar's position
    ld de,(beam_pos)
    or a
    sbc hl,de                  ; HL = pos - beam (gap to this bar)
    jr nc,db_gap
    ld hl,0                    ; overlaps previous bar -> no gap
db_gap:
    ex de,hl
    call rb_wait               ; DE = gap
    ld l,(ix+2)
    ld h,(ix+3)                ; HL = this bar's colour buffer
    call rb_drawbar
    ld l,(ix+0)
    ld h,(ix+1)
    ld de,BAR_H
    add hl,de                  ; beam = pos + bar height
    ld (beam_pos),hl
    ld de,4
    add ix,de                  ; next entry
    pop bc
    djnz db_loop
    ret

;; delay DE loop iterations - positions a bar vertically
rb_wait:
    ld a,d
    or e
    ret z                       ; 0 -> no delay (avoids a 65536 underflow)
rbw_l:
    dec de
    ld a,d
    or e
    jr nz,rbw_l
    ret

;; draw one pulse bar on PEN 0, then leave PEN 0 black below it.  HL -> colour buffer
rb_drawbar:
    ld bc,&7F00
    out (c),c                   ; select PEN 0
    ld e,RB_BARLEN
rbd_l:
    ld a,(hl)
    inc hl
    out (c),a
    defs RB_LINEDLY
    dec e
    jp nz,rbd_l
    ld a,&54
    out (c),a                   ; PEN 0 -> black
    ret

;; copy all three pulse palettes into their working buffers
init_raster:
    ld hl,bar_pulse
    ld de,bar_buf
    ld bc,RB_BARLEN
    ldir
    ld hl,bar_pulse2
    ld de,bar2_buf
    ld bc,RB_BARLEN
    ldir
    ld hl,bar_pulse3
    ld de,bar3_buf
    ld bc,RB_BARLEN
    ldir
    ret

;; shimmer all three bars: rotate each buffer left by one
rotate_bars:
    ld hl,bar_buf
    call rotate_one
    ld hl,bar2_buf
    call rotate_one
    ld hl,bar3_buf
    call rotate_one
    ret
;; rotate the RB_BARLEN buffer at HL left by one
rotate_one:
    ld a,(hl)                   ; save first colour
    ld d,h
    ld e,l                      ; DE = buffer start (dest)
    inc hl                      ; HL = start+1 (src)
    ld bc,RB_BARLEN-1
    ldir                        ; shift colours down by one; DE -> last slot
    ld (de),a                   ; wrap first colour into the last slot
    ret

;; plot the (static) starfield once, pen 2
title_draw_stars:
    ld ix,star_data
    ld b,N_STARS
tds_loop:
    push bc                     ; get_scr_addr clobbers BC now; B is our counter
    ld h,(ix+ST_X)
    ld l,(ix+ST_Y)
    call get_scr_addr
    ld (hl),&08
    pop bc
    ld de,STAR_SZ
    add ix,de
    djnz tds_loop
    ret

;; centre HL string on row C (Mode 1, 40 columns)
m1_center:
    push hl
    ld b,0
m1c_cnt:
    ld a,(hl)
    or a
    jr z,m1c_done
    inc hl
    inc b
    jr m1c_cnt
m1c_done:
    pop hl
    ld a,40
    sub b
    srl a
    ld b,a                      ; col
    ;; fall through to m1_print
m1_print:
    ld a,(hl)
    or a
    ret z
    push hl
    push bc
    call m1_putc
    pop bc
    pop hl
    inc hl
    inc b
    jr m1_print

;; render glyph A at (B=col 0-39, C=row 0-24), Mode 1 pen 1
m1_putc:
    sub 32
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl
    ld de,font_tbl
    add hl,de
    push hl
    pop ix
    ld a,b
    add a,a
    ld (m1_x),a                 ; col*2 = x byte
    ld a,c
    add a,a
    add a,a
    add a,a
    ld (m1_y),a                 ; row*8 = y
    ld b,8
m1p_row:
    push bc
    ld a,(m1_x)
    ld h,a
    ld a,(m1_y)
    ld l,a
    call get_scr_addr
    ld a,(ix+0)
    ld c,a
    and &F0                     ; left 4 pixels (pen 1 -> bits 7654)
    ld (hl),a
    inc hl
    ld a,c
    add a,a
    add a,a
    add a,a
    add a,a                     ; right 4 pixels
    ld (hl),a
    inc ix
    ld a,(m1_y)
    inc a
    ld (m1_y),a
    pop bc
    djnz m1p_row
    ret

;; centre + print a string DOUBLE-SIZE (16x16) in pen 3.  HL=string, C=row
m1_center2x:
    push hl
    ld b,0
m2c_cnt:
    ld a,(hl)
    or a
    jr z,m2c_done
    inc hl
    inc b
    jr m2c_cnt
m2c_done:
    pop hl
    ld a,20
    sub b                       ; col = 20 - len  (each 2x char = 2 cols)
    ld b,a
m1_print2x:
    ld a,(hl)
    or a
    ret z
    push hl
    push bc
    call m1_putc2x
    pop bc
    pop hl
    inc hl
    inc b
    inc b                       ; advance 2 cols per double-width char
    jr m1_print2x

;; render glyph A at 2x (16 wide x 16 tall) at (B=col, C=row), pen 3
m1_putc2x:
    sub 32
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl
    ld de,font_tbl
    add hl,de
    push hl
    pop ix
    ld a,b
    add a,a
    ld (m1_x),a                 ; col*2 = start x byte
    ld a,c
    add a,a
    add a,a
    add a,a
    ld (m1_y),a                 ; row*8 = y line
    ld b,8
m2_row:
    push bc
    ld a,(ix+0)
    ld c,a
    rrca
    rrca
    rrca
    rrca
    and &0F                     ; high nibble
    add a,a
    ld e,a
    ld d,0
    ld hl,exp2x
    add hl,de
    ld a,(hl)
    ld (m2_buf),a
    inc hl
    ld a,(hl)
    ld (m2_buf+1),a
    ld a,c
    and &0F                     ; low nibble
    add a,a
    ld e,a
    ld d,0
    ld hl,exp2x
    add hl,de
    ld a,(hl)
    ld (m2_buf+2),a
    inc hl
    ld a,(hl)
    ld (m2_buf+3),a
    ld b,2                      ; write each row twice (vertical 2x)
m2_dup:
    push bc
    ld a,(m1_x)
    ld h,a
    ld a,(m1_y)
    ld l,a
    call get_scr_addr
    ld de,m2_buf
    ld a,(de)
    ld (hl),a
    inc hl
    inc de
    ld a,(de)
    ld (hl),a
    inc hl
    inc de
    ld a,(de)
    ld (hl),a
    inc hl
    inc de
    ld a,(de)
    ld (hl),a
    ld a,(m1_y)
    inc a
    ld (m1_y),a
    pop bc
    djnz m2_dup
    inc ix
    pop bc
    djnz m2_row
    ret
;; nibble -> 2 Mode-1 bytes, each font bit doubled to 2 pixels, pen 3
exp2x:
    defb &00,&00, &00,&33, &00,&CC, &00,&FF, &33,&00, &33,&33, &33,&CC, &33,&FF
    defb &CC,&00, &CC,&33, &CC,&CC, &CC,&FF, &FF,&00, &FF,&33, &FF,&CC, &FF,&FF

;;============================================================================
;; GAME START / INIT
;;============================================================================
game_start:
    call game_init
    call init_stars
    call clear_buffers
    call build_terr_bmp
    xor a
    ld (scroll_off),a
    ld (st_cnt),a               ; cityscape: no structure / gap in progress
    ld (gap_cnt),a
    call hud_mark               ; draw HUD into both buffers at the start
    ;; first frame draws to BUF1 (hidden)
    ld a,1
    ld (parity),a
    ld hl,tbl_8
    ld (draw_tbl),hl
    ld a,R12_BUF1
    ld (disp_r12),a
    jp game_loop

game_init:
    ld a,3
    ld (lives),a
    ld hl,0
    ld (score),hl               ; 16-bit score
    xor a
    ld (game_state),a
    ld (fire_timer),a
    ld (wave_type),a
    ld (wave_remaining),a       ; no wave in progress -> first one starts soon
    ld (spawn_timer),a          ; start the first wave almost immediately
    ld (pl_boom),a              ; no death boom in progress
    ld (wave_in_sector),a       ; first sector starts at wave 0
    ld (pat_in_wave),a          ; and pattern 0 of that wave
    ld (weapon_level),a         ; start with single shot
    ld (kill_streak),a
    ld a,1
    ld (level),a                ; sector 1
    ld a,PL_XSTART
    ld (pl_x),a
    ld (pl_ox0),a
    ld (pl_ox1),a
    ld a,PL_YSTART
    ld (pl_y),a
    ld (pl_oy0),a
    ld (pl_oy1),a
    ld hl,enemy_pool
    ld bc,EN_SZ*MAX_ENE
    call memclr
    ld hl,bullet_pool
    ld bc,BL_SZ*MAX_BUL
    call memclr
    ld hl,explosion_pool
    ld bc,EX_SZ*MAX_EXP
    call memclr
    call init_level
    ret

level_data:                    ; kills, (speed unused - wave-driven), spawn-delay
    defb  8, 0, 70             ; L1 - sector clears after 8 kills
    defb 10, 0, 55             ; L2
    defb 12, 0, 45             ; L3
    defb 16, 0, 35             ; L4
    defb 20, 0, 28             ; L5

init_level:
    ld a,(level)
    dec a
    ld e,a
    ld d,0
    ld l,a
    ld h,0
    add hl,hl
    add hl,de                   ; *3
    ld de,level_data
    add hl,de
    ld a,(hl)
    ld (kills_needed),a
    inc hl
    inc hl                      ; skip speed column (speed is wave-cycle driven now)
    ld a,(hl)
    ld (spawn_delay),a
    ld (spawn_timer),a
    xor a
    ld (lvl_kills),a
    ret

;;============================================================================
;; MAIN LOOP (logic -> render back buffer -> vsync -> flip -> swap)
;;============================================================================
game_loop:
    call read_keys
    call update_player
    call update_bullets
    call update_enemies
    call update_explosions
    call update_pboom
    call update_stars
    call check_collisions
    call render_stars
    call render_enemies
    call render_bullets
    call render_explosions
    call render_player
    call draw_terrain_scroll
    ;; HUD only redraws when a value changed (covers both buffers via counter)
    ld a,(hud_count)
    or a
    jr z,gl_nohud
    dec a
    ld (hud_count),a
    call draw_hud
gl_nohud:
    call sound_update
    call wait_vsync
    ld a,(disp_r12)
    call set_r12
    call swap_buffers
    ld a,(game_state)
    or a
    jp nz,gl_end
    jp game_loop
gl_end:
    cp 2
    jp z,show_win
    jp show_gameover

swap_buffers:
    ld a,(parity)
    xor 1
    ld (parity),a
    or a
    jr z,swb_p0
    ld hl,tbl_8
    ld (draw_tbl),hl
    ld a,R12_BUF1
    ld (disp_r12),a
    ret
swb_p0:
    ld hl,tbl_c
    ld (draw_tbl),hl
    ld a,R12_BUF0
    ld (disp_r12),a
    ret

;;============================================================================
;; PLAYER
;;============================================================================
update_player:
    ld a,(pl_boom)
    or a
    ret nz                      ; frozen while the death boom plays
    ;; --- UP --- cursor-up(l0 b0), Q(l8 b3), joy-up(l9 b0)
    ld a,(key_buf+0)
    bit 0,a
    jr z,pu_up
    ld a,(key_buf+8)
    bit 3,a
    jr z,pu_up
    ld a,(key_buf+9)
    bit 0,a
    jr z,pu_up
    jr pu_dn
pu_up:
    ld a,(pl_y)
    cp PL_YMIN+PL_SPEED
    jr c,pu_dn
    sub PL_SPEED
    ld (pl_y),a
pu_dn:
    ;; --- DOWN --- cursor-down(l0 b2), A(l8 b5), joy-down(l9 b1)
    ld a,(key_buf+0)
    bit 2,a
    jr z,pu_down
    ld a,(key_buf+8)
    bit 5,a
    jr z,pu_down
    ld a,(key_buf+9)
    bit 1,a
    jr z,pu_down
    jr pu_lf
pu_down:
    ld a,(pl_y)
    cp PL_YMAX-PL_SPEED
    jr nc,pu_lf
    add a,PL_SPEED
    ld (pl_y),a
pu_lf:
    ;; --- LEFT --- cursor-left(l1 b0), joy-left(l9 b2)
    ld a,(key_buf+1)
    bit 0,a
    jr z,pu_left
    ld a,(key_buf+9)
    bit 2,a
    jr z,pu_left
    jr pu_rt
pu_left:
    ld a,(pl_x)
    cp PL_XMIN+PL_SPEED
    jr c,pu_rt
    sub PL_SPEED
    ld (pl_x),a
pu_rt:
    ;; --- RIGHT --- cursor-right(l0 b1), joy-right(l9 b3)
    ld a,(key_buf+0)
    bit 1,a
    jr z,pu_right
    ld a,(key_buf+9)
    bit 3,a
    jr z,pu_right
    jr pu_fire
pu_right:
    ld a,(pl_x)
    cp PL_XMAX-PL_SPEED
    jr nc,pu_fire
    add a,PL_SPEED
    ld (pl_x),a
pu_fire:
    ld a,(fire_timer)
    or a
    jr z,pu_fchk
    dec a
    ld (fire_timer),a
    ret
pu_fchk:
    ld a,(key_buf+5)
    bit 7,a
    jr z,pu_dofire
    ld a,(key_buf+9)
    bit 5,a
    jr z,pu_dofire
    ld a,(key_buf+9)
    bit 4,a
    jr z,pu_dofire
    ret
pu_dofire:
    ld a,FIRE_DELAY
    ld (fire_timer),a
    ld a,(pl_y)
    add a,3
    ld (nb_y),a                ; centre line
    xor a
    ld (nb_vy),a               ; straight by default
    ld a,(weapon_level)
    or a
    jr z,pdf_one
    cp WEAP_DUAL
    jr z,pdf_dual
    ;; TRI: centre straight + up-diagonal + down-diagonal
    call spawn_bullet
    ld a,-2
    ld (nb_vy),a
    call spawn_bullet
    ld a,2
    ld (nb_vy),a
    call spawn_bullet
    jr pdf_snd
pdf_dual:                      ; two parallel straight streams
    ld a,(pl_y)
    add a,1
    ld (nb_y),a
    call spawn_bullet
    ld a,(pl_y)
    add a,6
    ld (nb_y),a
    call spawn_bullet
    jr pdf_snd
pdf_one:
    call spawn_bullet
pdf_snd:
    call sound_fire
    ret

;; spawn one bullet at (pl_x-1, nb_y) with vertical velocity nb_vy
spawn_bullet:
    ld ix,bullet_pool
    ld b,MAX_BUL
sb_loop:
    ld a,(ix+BL_ACTIVE)
    or a
    jr z,sb_found
    ld de,BL_SZ
    add ix,de
    djnz sb_loop
    ret                        ; pool full
sb_found:
    ld a,(pl_x)
    dec a
    ld (ix+BL_X),a             ; just left of the ship
    ld a,(nb_y)
    ld (ix+BL_Y),a
    ld a,(nb_vy)
    ld (ix+BL_VY),a
    ld a,1
    ld (ix+BL_ACTIVE),a
    ret

update_bullets:
    ld ix,bullet_pool
    ld b,MAX_BUL
ub_loop:
    ld a,(ix+BL_ACTIVE)
    or a
    jr z,ub_next
    ld a,(ix+BL_X)
    sub BL_SPEED                ; fly LEFT
    jr c,ub_die
    ld (ix+BL_X),a
    ld a,(ix+BL_VY)
    or a
    jr z,ub_next               ; straight shot - no vertical move
    add a,(ix+BL_Y)            ; signed VY
    cp PLAY_TOP
    jr c,ub_die                ; left the play area vertically
    cp PLAY_BOT
    jr nc,ub_die
    ld (ix+BL_Y),a
    jr ub_next
ub_die:
    xor a
    ld (ix+BL_ACTIVE),a
ub_next:
    ld de,BL_SZ
    add ix,de
    djnz ub_loop
    ret

;;============================================================================
;; ENEMIES  - traditional formation waves
;;  Each wave uses one of 4 attack patterns (cycled): a vertical WALL with gaps,
;;  a weaving SNAKE in single file, and two DIAGONAL sweeps. The pattern decides
;;  each enemy's entry Y, whether it weaves (sine) and the release spacing.
;;============================================================================
update_enemies:
    ld a,(wave_remaining)
    or a
    jr z,ue_gap                 ; no wave running -> count to next wave
    ld a,(release_timer)
    or a
    jr z,ue_release
    dec a
    ld (release_timer),a
    jr ue_move
ue_release:
    call spawn_one_seq
    ld a,(wave_remaining)
    dec a
    ld (wave_remaining),a
    jr z,ue_wdone
    ld a,(cur_reldelay)
    ld (release_timer),a
    or a
    jr z,ue_release             ; 0 spacing -> launch the whole wall this frame
    jr ue_move
ue_wdone:
    ld a,(spawn_delay)          ; wave finished -> inter-wave gap
    ld (spawn_timer),a
    jr ue_move
ue_gap:
    ld a,(spawn_timer)
    or a
    jr z,ue_newwave
    dec a
    ld (spawn_timer),a
    jr ue_move
ue_newwave:
    call start_wave
ue_move:
    ld ix,enemy_pool
    ld b,MAX_ENE
uem_loop:
    ld a,(ix+EN_ACTIVE)
    or a
    jr z,uem_next
    ld a,(ix+EN_PHASE)
    cp 255
    jr z,uem_movex              ; 255 = straight line (no weave)
    inc a
    and 31
    ld (ix+EN_PHASE),a
    ld e,a
    ld d,0
    ld hl,sintab                ; default weave amplitude (~14)
    ld a,(ix+EN_TYPE)
    cp 3
    jr nz,uem_havetab
    ld hl,sintab2               ; pattern 3 weaves with the big amplitude (~26)
uem_havetab:
    add hl,de
    ld a,(ix+EN_BASEY)
    add a,(hl)
    ld (ix+EN_Y),a
uem_movex:
    ld a,(ix+EN_FRAC)
    add a,(ix+EN_SPEED)         ; accumulate 1/4-byte steps
    ld c,a
    and 3
    ld (ix+EN_FRAC),a           ; keep the fraction
    ld a,c
    srl a
    srl a                       ; whole bytes to advance this frame
    add a,(ix+EN_X)
    cp EN_ESCAPE
    jr nc,uem_die
    ld (ix+EN_X),a
    jr uem_next
uem_die:
    xor a
    ld (ix+EN_ACTIVE),a
    ld (kill_streak),a          ; an enemy escaped -> firepower streak broken
uem_next:
    ld de,EN_SZ
    add ix,de
    djnz uem_loop
    ret

;; Release ONE attack pattern (5 enemies). Hierarchy:
;;   pattern = 5 enemies   |   wave = 5 patterns (one of each, 25 enemies)
;;   sector N = N waves    |   5 sectors -> win.  Speed steps up each sector.
;; `pat_in_wave` (0..4) = the pattern/sprite; `wave_in_sector` counts finished waves.
start_wave:
    ;; only test for sector rollover at the start of a fresh wave (pat_in_wave==0)
    ld a,(pat_in_wave)
    or a
    jr nz,sw_setpat
    ld a,(wave_in_sector)
    ld hl,level
    cp (hl)                     ; sector N runs N waves
    jr c,sw_setpat              ; waves left in this sector
    ;; sector complete -> next sector (or win the game)
    ld a,(level)
    inc a
    cp N_LEVELS+1
    jr nc,sw_win
    ld (level),a
    ld a,2
    ld (hud_count),a            ; refresh HUD sector number in both buffers
    xor a
    ld (wave_in_sector),a
sw_setpat:
    ;; pattern + sprite = position within the wave
    ld a,(pat_in_wave)
    ld (wave_type),a
    ;; sector speed (constant within a sector)
    ld a,(level)
    dec a
    ld e,a
    ld d,0
    ld hl,sector_speed
    add hl,de
    ld a,(hl)
    ld (ene_speed),a
    ;; arm this pattern's 5-enemy release
    ld a,WAVE_SIZE
    ld (wave_remaining),a
    xor a
    ld (wave_index),a
    ld (release_timer),a        ; release first immediately
    ld a,(wave_type)
    ld e,a
    ld d,0
    ld hl,pat_reldelay
    add hl,de
    ld a,(hl)
    ld (cur_reldelay),a
    ;; advance pattern counter; after 5 patterns a whole wave is done
    ld a,(pat_in_wave)
    inc a
    cp 5
    jr c,sw_patstore
    xor a                       ; wave finished
    ld (pat_in_wave),a
    ld a,(wave_in_sector)
    inc a
    ld (wave_in_sector),a
    ret
sw_patstore:
    ld (pat_in_wave),a
    ret
sw_win:
    ld a,2
    ld (game_state),a
    ret

;; release the next enemy of the current wave at the left edge, using the
;; current pattern's Y table and weave setting.
spawn_one_seq:
    ld ix,enemy_pool
    ld b,MAX_ENE
sos_find:
    ld a,(ix+EN_ACTIVE)
    or a
    jr z,sos_found
    ld de,EN_SZ
    add ix,de
    djnz sos_find
    ret                         ; pool full
sos_found:
    xor a
    ld (ix+EN_X),a              ; enter at left edge
    ;; base Y = pat_basey[wave_type*5 + wave_index]
    ld a,(wave_type)
    ld c,a
    add a,a
    add a,a
    add a,c                     ; *5
    ld c,a
    ld a,(wave_index)
    add a,c
    ld e,a
    ld d,0
    ld hl,pat_basey
    add hl,de
    ld a,(hl)
    ld (ix+EN_BASEY),a
    ld (ix+EN_Y),a
    ld a,1
    ld (ix+EN_ACTIVE),a
    ld a,(wave_type)
    ld (ix+EN_TYPE),a           ; sprite/colour by pattern
    ld a,(ene_speed)
    ld (ix+EN_SPEED),a
    xor a
    ld (ix+EN_FRAC),a           ; reset sub-byte accumulator for this slot
    ;; phase: weaving patterns get a staggered phase, others go straight (255)
    ld a,(wave_type)
    ld e,a
    ld d,0
    ld hl,pat_sine
    add hl,de
    ld a,(hl)
    or a
    jr z,sos_straight
    ld a,(wave_index)
    ld c,a
    add a,a
    add a,a
    add a,c                     ; phase = index*5
    and 31
    jr sos_setph
sos_straight:
    ld a,255
sos_setph:
    ld (ix+EN_PHASE),a
    ld a,(wave_index)
    inc a
    ld (wave_index),a
    ret

;; explosions
spawn_explosion:
    ld ix,explosion_pool
    ld b,MAX_EXP
spx_find:
    ld a,(ix+EX_TIMER)
    or a
    jr z,spx_found
    ld de,EX_SZ
    add ix,de
    djnz spx_find
    ret
spx_found:
    ld a,(exp_x)
    ld (ix+EX_X),a
    ld a,(exp_y)
    ld (ix+EX_Y),a
    ld a,18
    ld (ix+EX_TIMER),a
    ret

update_explosions:
    ld ix,explosion_pool
    ld b,MAX_EXP
uex_loop:
    ld a,(ix+EX_TIMER)
    or a
    jr z,uex_next
    dec a
    ld (ix+EX_TIMER),a
uex_next:
    ld de,EX_SZ
    add ix,de
    djnz uex_loop
    ret

;;============================================================================
;; STARS
;;============================================================================
init_stars:
    ld ix,star_data
    ld b,N_STARS
    ld c,0
is_loop:
    call rng
isx:
    cp 80
    jr c,isxok
    sub 80
    jr isx
isxok:
    ld (ix+ST_X),a
    call rng
isy:
    cp 130
    jr c,isyok
    sub 130
    jr isy
isyok:
    add a,PLAY_TOP             ; y 22..151 (above terrain)
    ld (ix+ST_Y),a
    ld a,c
ismod:
    cp 3
    jr c,ismodok
    sub 3
    jr ismod
ismodok:
    inc a                       ; speed 1..3
    ld (ix+ST_SPD),a
    inc c
    ld de,STAR_SZ
    add ix,de
    djnz is_loop
    ret

update_stars:
    ld ix,star_data
    ld b,N_STARS
us_loop:
    ld a,(ix+ST_X)
    add a,(ix+ST_SPD)          ; scroll right
    cp 80
    jr c,us_ok
    sub 80
us_ok:
    ld (ix+ST_X),a
    ld de,STAR_SZ
    add ix,de
    djnz us_loop
    ret

render_stars:
    ld ix,star_data
    ld b,N_STARS
rs_loop:
    push bc
    ;; erase and draw are on the SAME row (ST_Y) - look the row base up ONCE
    ld h,0
    ld l,(ix+ST_Y)
    call get_scr_addr           ; HL = base of row ST_Y (x=0)
    ;; erase pixel from 2 frames ago: x - 2*spd (this buffer is 2 frames stale)
    ld a,(ix+ST_SPD)
    add a,a
    ld c,a                      ; 2*spd
    ld a,(ix+ST_X)
    sub c
    jr nc,rs_eok
    add a,80
rs_eok:
    push hl                     ; row base
    ld e,a
    ld d,0
    add hl,de                   ; base + old_x
    ld (hl),0
    pop hl                      ; row base
    ;; draw new pixel at base + ST_X
    ld a,(ix+ST_X)
    ld e,a
    ld d,0
    add hl,de
    ld a,(ix+ST_SPD)
    dec a
    ld e,a
    ld d,0
    push hl
    ld hl,star_bytes
    add hl,de
    ld a,(hl)
    pop hl
    ld (hl),a
    pop bc
    ld de,STAR_SZ
    add ix,de
    djnz rs_loop
    ret

;;============================================================================
;; COLLISIONS
;;============================================================================
check_collisions:
    ld iy,bullet_pool
    ld c,MAX_BUL
cc_b:
    ld a,(iy+BL_ACTIVE)
    or a
    jp z,cc_b_next
    ld ix,enemy_pool
    ld b,MAX_ENE
cc_e:
    ld a,(ix+EN_ACTIVE)
    or a
    jr z,cc_e_next
    ld a,(ix+EN_X)
    add a,EN_W
    ld d,a
    ld a,(iy+BL_X)
    cp d
    jr nc,cc_e_next
    ld a,(iy+BL_X)
    add a,BL_SWEEP              ; swept right edge: where the bullet was last frame
    ld d,a
    ld a,(ix+EN_X)
    cp d
    jr nc,cc_e_next
    ld a,(ix+EN_Y)
    add a,EN_H
    ld d,a
    ld a,(iy+BL_Y)
    cp d
    jr nc,cc_e_next
    ld a,(iy+BL_Y)
    add a,BL_H
    ld d,a
    ld a,(ix+EN_Y)
    cp d
    jr nc,cc_e_next
    ;; HIT
    ld a,(ix+EN_X)
    ld (exp_x),a
    ld a,(ix+EN_Y)
    ld (exp_y),a
    xor a
    ld (ix+EN_ACTIVE),a
    ld (iy+BL_ACTIVE),a
    push bc
    push iy
    call spawn_explosion
    call enemy_killed
    pop iy
    pop bc
    jr cc_b_next
cc_e_next:
    ld de,EN_SZ
    add ix,de
    djnz cc_e
cc_b_next:
    ld de,BL_SZ
    add iy,de
    dec c
    jr nz,cc_b
    call check_player_hit
    ret

enemy_killed:
    call sound_expl
    call hud_mark
    ld hl,(score)               ; 16-bit score (no 250 cap)
    inc hl
    ld (score),hl
    ;; POWERUP: STREAK_NEED kills in a row (a cleared wave) upgrades firepower.
    ;; (Sector/win progression is wave-driven in start_wave, not here.)
    ld a,(kill_streak)
    inc a
    cp STREAK_NEED
    jr c,ek_streak
    ld a,(weapon_level)         ; cleared a wave's worth -> upgrade
    cp WEAP_TRI
    jr nc,ek_maxw
    inc a
    ld (weapon_level),a
    call hud_mark               ; show the new firepower
    call sound_powerup          ; upgrade chime
ek_maxw:
    xor a                       ; reset the streak after each upgrade
ek_streak:
    ld (kill_streak),a
    ret

check_player_hit:
    ld a,(invincible)
    or a
    ret nz                      ; TOPGUN cheat -> never take a hit
    ld a,(pl_boom)
    or a
    ret nz                      ; invulnerable while the death boom plays
    ld ix,enemy_pool
    ld b,MAX_ENE
cph_loop:
    ld a,(ix+EN_ACTIVE)
    or a
    jr z,cph_next
    ld a,(ix+EN_X)
    add a,EN_W
    ld d,a
    ld a,(pl_x)
    cp d
    jr nc,cph_next
    ld a,(pl_x)
    add a,PL_W
    ld d,a
    ld a,(ix+EN_X)
    cp d
    jr nc,cph_next
    ld a,(ix+EN_Y)
    add a,EN_H
    ld d,a
    ld a,(pl_y)
    cp d
    jr nc,cph_next
    ld a,(pl_y)
    add a,PL_H
    ld d,a
    ld a,(ix+EN_Y)
    cp d
    jr nc,cph_next
    ;; record explosion at the enemy, kill it
    ld a,(ix+EN_X)
    ld (exp_x),a
    ld a,(ix+EN_Y)
    ld (exp_y),a
    xor a
    ld (ix+EN_ACTIVE),a
    call spawn_explosion
    call player_hit
    ret
cph_next:
    ld de,EN_SZ
    add ix,de
    djnz cph_loop
    ret

player_hit:
    call sound_expl
    call hud_mark
    ;; losing a life resets firepower back to single shot
    xor a
    ld (weapon_level),a
    ld (kill_streak),a
    ;; remember the death site and start a sustained multi-explosion boom
    ld a,(pl_x)
    ld (boom_x),a
    ld a,(pl_y)
    ld (boom_y),a
    ld a,44
    ld (pl_boom),a              ; long, dramatic death sequence
    ld a,(lives)
    dec a
    ld (lives),a
    jr nz,ph_done
    ld a,1
    ld (game_state),a
ph_done:
    ret

;; while pl_boom > 0 the ship is hidden; spray explosions across its wreck every
;; frame (the pool caps how many show at once). When it ends, respawn at start.
update_pboom:
    ld a,(pl_boom)
    or a
    ret z
    dec a
    ld (pl_boom),a
    jr nz,upb_spray
    ;; sequence finished -> respawn the ship at its start position
    ld a,PL_XSTART
    ld (pl_x),a
    ld a,PL_YSTART
    ld (pl_y),a
    ret
upb_spray:
    ld a,(pl_boom)
    cp 19
    ret c                       ; last 18 frames: let blasts finish before respawn
    call rng
    and 7
    ld c,a
    ld a,(boom_x)
    add a,c
    ld (exp_x),a
    call rng
    and 7
    ld c,a
    ld a,(boom_y)
    add a,c
    ld (exp_y),a
    call spawn_explosion
    ret

;;============================================================================
;; RENDER (per-buffer shadow erase-old / draw-new)
;;============================================================================
render_player:
    ld a,(pl_boom)
    or a
    jr z,rp_normal
    ;; ship hidden during the boom: just erase its last-drawn position
    ld a,(parity)
    or a
    jr nz,rph_p1
    ld a,(pl_ox0)
    ld h,a
    ld a,(pl_oy0)
    ld l,a
    ld b,PL_H
    ld c,PL_W
    jp erase_rect
rph_p1:
    ld a,(pl_ox1)
    ld h,a
    ld a,(pl_oy1)
    ld l,a
    ld b,PL_H
    ld c,PL_W
    jp erase_rect
rp_normal:
    ld a,(parity)
    or a
    jr nz,rp_p1
    ;; parity 0
    ld a,(pl_ox0)
    ld h,a
    ld a,(pl_oy0)
    ld l,a
    ld b,PL_H
    ld c,PL_W
    call erase_rect
    ld de,pl_spr
    ld a,(pl_x)
    ld h,a
    ld a,(pl_y)
    ld l,a
    ld b,PL_H
    ld c,PL_W
    call draw_spr
    ld a,(pl_x)
    ld (pl_ox0),a
    ld a,(pl_y)
    ld (pl_oy0),a
    ret
rp_p1:
    ld a,(pl_ox1)
    ld h,a
    ld a,(pl_oy1)
    ld l,a
    ld b,PL_H
    ld c,PL_W
    call erase_rect
    ld de,pl_spr
    ld a,(pl_x)
    ld h,a
    ld a,(pl_y)
    ld l,a
    ld b,PL_H
    ld c,PL_W
    call draw_spr
    ld a,(pl_x)
    ld (pl_ox1),a
    ld a,(pl_y)
    ld (pl_oy1),a
    ret

render_enemies:
    ld ix,enemy_pool
    ld b,MAX_ENE
re_loop:
    push bc
    push ix
    pop iy
    ld de,EN_SHADOW
    ld a,(parity)
    or a
    jr z,re_p0
    ld de,EN_SHADOW+3
re_p0:
    add iy,de
    ld a,(iy+2)
    or a
    jr z,re_noerase
    ld h,(iy+0)
    ld l,(iy+1)
    ld b,EN_H
    ld c,EN_W
    call erase_rect
re_noerase:
    ld a,(ix+EN_ACTIVE)
    or a
    jr z,re_inact
    ;; select sprite by type (0..3) via en_spr_tbl
    ld a,(ix+EN_TYPE)
    add a,a
    ld e,a
    ld d,0
    ld hl,en_spr_tbl
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)                   ; DE = sprite ptr
    ld h,(ix+EN_X)
    ld l,(ix+EN_Y)
    ld b,EN_H
    ld c,EN_W
    call draw_spr
    ld a,(ix+EN_X)
    ld (iy+0),a
    ld a,(ix+EN_Y)
    ld (iy+1),a
    ld a,1
    ld (iy+2),a
    jr re_next
re_inact:
    xor a
    ld (iy+2),a
re_next:
    pop bc
    ld de,EN_SZ
    add ix,de
    djnz re_loop
    ret

render_bullets:
    ld ix,bullet_pool
    ld b,MAX_BUL
rb_loop:
    push bc
    push ix
    pop iy
    ld de,BL_SHADOW
    ld a,(parity)
    or a
    jr z,rb_p0
    ld de,BL_SHADOW+3
rb_p0:
    add iy,de
    ld a,(iy+2)
    or a
    jr z,rb_noerase
    ld h,(iy+0)
    ld l,(iy+1)
    ld b,BL_H
    ld c,BL_W
    call erase_rect
rb_noerase:
    ld a,(ix+BL_ACTIVE)
    or a
    jr z,rb_inact
    ld h,(ix+BL_X)
    ld l,(ix+BL_Y)
    ld de,bul_spr
    ld b,BL_H
    ld c,BL_W
    call draw_spr
    ld a,(ix+BL_X)
    ld (iy+0),a
    ld a,(ix+BL_Y)
    ld (iy+1),a
    ld a,1
    ld (iy+2),a
    jr rb_next
rb_inact:
    xor a
    ld (iy+2),a
rb_next:
    pop bc
    ld de,BL_SZ
    add ix,de
    djnz rb_loop
    ret

render_explosions:
    ld ix,explosion_pool
    ld b,MAX_EXP
rx_loop:
    push bc
    push ix
    pop iy
    ld de,EX_SHADOW
    ld a,(parity)
    or a
    jr z,rx_p0
    ld de,EX_SHADOW+3
rx_p0:
    add iy,de
    ld a,(iy+2)
    or a
    jr z,rx_noerase
    ld h,(iy+0)
    ld l,(iy+1)
    ld b,EX_H
    ld c,EX_W
    call erase_rect
rx_noerase:
    ld a,(ix+EX_TIMER)
    or a
    jr z,rx_inact
    ;; choose animation frame by remaining timer
    ld de,exp_spr0
    cp 13
    jr nc,rx_draw
    ld de,exp_spr1
    cp 7
    jr nc,rx_draw
    ld de,exp_spr2
rx_draw:
    ld h,(ix+EX_X)
    ld l,(ix+EX_Y)
    ld b,EX_H
    ld c,EX_W
    call draw_spr
    ld a,(ix+EX_X)
    ld (iy+0),a
    ld a,(ix+EX_Y)
    ld (iy+1),a
    ld a,1
    ld (iy+2),a
    jr rx_next
rx_inact:
    xor a
    ld (iy+2),a
rx_next:
    pop bc
    ld de,EX_SZ
    add ix,de
    djnz rx_loop
    ret

;;============================================================================
;; HUD
;;============================================================================
;; mark the HUD dirty for 2 frames (so it refreshes in both buffers)
hud_mark:
    ld a,2
    ld (hud_count),a
    ret

draw_hud:
    ld hl,str_sc                ; "SCORE:"
    ld b,0
    ld c,0
    call my_print
    ld hl,(score)
    ld b,6
    ld c,0
    call print_hl_dec3
    ld hl,str_li                ; "LIVES:"
    ld b,11
    ld c,0
    call my_print
    ld a,(lives)
    add a,'0'
    ld b,17
    ld c,0
    call my_putc
    ret

;; print HL as 3 decimal digits at (B=col,C=row)
print_hl_dec3:
    ld de,100
    call phd_dig
    ld de,10
    call phd_dig
    ld a,l
    add a,'0'                   ; units
    push bc
    call my_putc
    pop bc
    ret
phd_dig:
    ld a,'0'
phd_l:
    or a                        ; clear carry
    sbc hl,de
    jr c,phd_done
    inc a
    jr phd_l
phd_done:
    add hl,de                   ; undo the overshoot
    push hl
    push bc
    call my_putc                ; A = digit char at (B,C)
    pop bc
    inc b                       ; next column
    pop hl
    ret

;; print A as 3 decimal digits at (B=col,C=row)
print_a_dec3:
    ld (pd_val),a
    ld a,(pd_val)
    ld d,'0'
pdh:
    cp 100
    jr c,pdhd
    sub 100
    inc d
    jr pdh
pdhd:
    ld (pd_val),a
    push bc
    ld a,d
    call my_putc
    pop bc
    inc b
    ld a,(pd_val)
    ld d,'0'
pdt:
    cp 10
    jr c,pdtd
    sub 10
    inc d
    jr pdt
pdtd:
    ld (pd_val),a
    push bc
    ld a,d
    call my_putc
    pop bc
    inc b
    ld a,(pd_val)
    add a,'0'
    call my_putc
    ret

;;============================================================================
;; GAME OVER / WIN
;;============================================================================
show_gameover:
    call sound_silence          ; stop the explosion noise that was playing
    call clear_buffers
    ld hl,tbl_c
    ld (draw_tbl),hl
    ld a,R12_BUF0
    call set_r12
    ld hl,str_gover
    ld b,6
    ld c,11
    call my_print
    ld hl,str_again
    ld b,4
    ld c,14
    call my_print
    ld hl,tune_gover
    call play_tune
    call wait_fire_release
sgo_wait:
    call read_keys
    call fire_pressed
    jr c,sgo_go
    call wait_vsync
    jr sgo_wait
sgo_go:
    call wait_fire_release
    jp show_title

;; WIN: decompress the 47 overscan image and show it (works on 464 + 6128).
show_win:
    call sound_silence
    ;; blank all pens to black so the decompression isn't seen
    ld bc,&7F00
    ld d,0
sw_blank:
    ld a,d
    out (c),a                   ; select pen d
    ld a,&54
    out (c),a                   ; black
    inc d
    ld a,d
    cp 16
    jr c,sw_blank
    call decomp_win             ; expand 47 -> &8200..&FEC0
    ;; "WELCOME HOME!" in the top black border (char row 5, pen 9 = white)
    ld a,9
    call set_text_pen
    ld hl,&83E0                 ; overscan line base, char row 5 (top black border)
    ld b,5                      ; centred col
    ld de,win_hello
    call draw_over_str
    ;; "SCORE nnnn" in the bottom black border (char row 28, pen 4 = yellow)
    call score_to_msg
    ld a,4
    call set_text_pen
    ld hl,&C480                 ; overscan line base, char row 28
    ld b,7
    ld de,win_msg
    call draw_over_str
    call set_crtc_overscan      ; switch to overscan, base &8200
    call set_win_palette        ; reveal the image colours
    ld hl,tune_win
    call play_tune
    call wait_fire_release
sw_wait:
    call read_keys
    call fire_pressed
    jr c,sw_go
    call wait_vsync
    jr sw_wait
sw_go:
    call wait_fire_release
    call set_crtc_std           ; standard geometry for the title
    jp show_title

;;============================================================================
;; LOOKUP / CONSTANT TABLES
;;============================================================================
;; Mode 0 pixel encoding (pen -> display-byte bits)
m0_left:
    defb &00,&80,&08,&88,&20,&A0,&28,&A8,&02,&82,&0A,&8A,&22,&A2,&2A,&AA
m0_right:
    defb &00,&40,&04,&44,&10,&50,&14,&54,&01,&41,&05,&45,&11,&51,&15,&55

;; star plot byte by (speed-1): far=pen9 dim, mid=pen8, near=pen7 bright
star_bytes:
    defb &82,&02,&A8

;; Gate Array hardware colour codes (from garray.html quick-reference)
;; game Mode-0 palette, pens 0..11
pal_game:
    defb &54,&53,&4A,&4C,&52,&4E,&4B,&4B,&57,&44,&4D,&40
;; title Mode-1 palette, pens 0..3 (black, white text, cyan stars, yellow)
pal_title:
    defb &54,&4B,&53,&4A
;; bar 1: red-orange-yellow pulse (GA colour codes)
bar_pulse:
    defb &5c,&4c,&4e,&4a,&5e,&4b,&4a,&4e,&4c,&5c
end_bar:
;; bar 2: neon magenta-cyan pulse (from Rasterbars-scroll-AI-updated.asm)
bar_pulse2:
    defb &5d,&4d,&5f,&53,&4b,&4b,&53,&5f,&4d,&5d
;; bar 3: green-yellow pulse (green -> lime -> yellow -> white flash, mirrored)
bar_pulse3:
    defb &56,&52,&5a,&5e,&4a,&4b,&5e,&5a,&52,&56

;; enemy sprite pointer table (by type/wave-position 0..4)
en_spr_tbl:
    defw en_spr0,en_spr1,en_spr2,en_spr3,en_spr4

;; 1/4-byte speed per sector (1..5): 1.0, 1.25, 1.5, 1.75, 2.0 bytes/frame
sector_speed:   defb 4, 5, 6, 7, 8
;; X (byte) of each of the 5 sector-progress posts, spread across the screen
marker_x:       defb 8, 22, 36, 50, 64

;; one attack pattern per wave-of-the-sector (5): same order every sector
;;   wave 1 SINE(white)  2 DIAG(red)  3 WALL(cyan)  4 BIG-SINE(yellow)  5 SNAKE(magenta)
pat_reldelay:   defb 6, 7, 0, 6, 5      ; frames between releases (0 = whole wall at once)
pat_sine:       defb 1, 0, 0, 1, 1      ; 1 = enemies weave (sine; type 3 uses big table)
pat_basey:                              ; entry Y per enemy (5 per pattern)
    defb 86,86,86,86,86                 ; 1 SINE     - single file, small weave
    defb 26,56,86,116,146               ; 2 DIAGONAL - staircase down
    defb 26,56,86,116,146               ; 3 WALL     - spread, dodge the gaps
    defb 86,86,86,86,86                 ; 4 BIG SINE - single file, wide weave
    defb 86,86,86,86,86                 ; 5 SNAKE    - single file, small weave

;; small sine table, 32 entries, amplitude ~14 (signed; added to base Y)
sintab:
    defb 0,3,5,8,10,12,13,14,14,14,13,12,10,8,5,3
    defb 0,-3,-5,-8,-10,-12,-13,-14,-14,-14,-13,-12,-10,-8,-5,-3
;; big sine table, amplitude ~26 (the second weave pattern)
sintab2:
    defb 0,5,10,14,18,22,24,25,26,25,24,22,18,14,10,5
    defb 0,-5,-10,-14,-18,-22,-24,-25,-26,-25,-24,-22,-18,-14,-10,-5

;; jingles: (tone_period_lo, tone_period_hi, frames)*, frames 0 = end
tune_gover:                     ; descending "game over"
    defb &1C,&01,14
    defb &66,&01,14
    defb &A9,&01,14
    defb &38,&02,28
    defb 0,0,0
tune_win:                       ; ascending "you win"
    defb &38,&02,12
    defb &A9,&01,12
    defb &66,&01,12
    defb &1C,&01,12
    defb &BE,&00,24
    defb 0,0,0

;;============================================================================
;; TEXT
;;============================================================================
str_title:      defb "RETURN HOME",0
str_sub:        defb "A CPC SHOOTER",0
str_c1:         defb "CURSORS = MOVE",0
str_c2:         defb "Q A O P = MOVE",0
str_c3:         defb "SPACE   = FIRE",0
str_c4:         defb "OR JOYSTICK",0
str_goal:       defb "CLEAR 5 SECTORS",0
str_press:      defb "FIRE TO START",0
str_gover:      defb "GAME OVER",0
str_again:      defb "FIRE TO RETRY",0
win_hello:      defb "WELCOME HOME!",0
win_msg:        defb "SCORE 0000",0     ; digits poked by score_to_msg (offset 6)
str_sc:         defb "SCORE:",0
str_li:         defb "LIVES:",0

;;============================================================================
;; SPRITE PEN-ART (one ASCII digit per pixel; pen 0 = transparent)
;;============================================================================
pl_pen:                         ; 16 x 8 ship (cell_7C0A flipped, shipmap.png colours)
    defb "000000000006666B"
    defb "00000000006666B0"
    defb "000AAA0066666B00"
    defb "00AA666666666B00"
    defb "6666655555555553"
    defb "0666665555555553"
    defb "00BB666666666600"
    defb "0000BBBBBBBB0000"

;; 5 "meanmap" bug recolours, one per wave-of-the-sector (body/eyes/mouth)
en0_pen:                        ; wave 1 - WHITE body, blue eyes, red mouth
    defb "00666000"
    defb "06666600"
    defb "69969960"
    defb "66969660"
    defb "06666600"
    defb "06636600"
    defb "66060660"
    defb "60060060"

en1_pen:                        ; wave 2 - RED body, white eyes, yellow mouth
    defb "00333000"
    defb "03333300"
    defb "36636630"
    defb "33636330"
    defb "03333300"
    defb "03323300"
    defb "33030330"
    defb "30030030"

en2_pen:                        ; wave 3 - CYAN body, white eyes, red mouth
    defb "00111000"
    defb "01111100"
    defb "16616610"
    defb "11616110"
    defb "01111100"
    defb "01131100"
    defb "11010110"
    defb "10010010"

en3_pen:                        ; wave 4 - YELLOW body, red eyes, white mouth
    defb "00222000"
    defb "02222200"
    defb "23323320"
    defb "22323220"
    defb "02222200"
    defb "02262200"
    defb "22020220"
    defb "20020020"

en4_pen:                        ; wave 5 - MAGENTA body, white eyes, yellow mouth
    defb "00AAA000"
    defb "0AAAAA00"
    defb "A66A66A0"
    defb "AA6A6AA0"
    defb "0AAAAA00"
    defb "0AA2AA00"
    defb "AA0A0AA0"
    defb "A00A00A0"

bul_pen:                        ; 2 x 2 small laser bolt (white)
    defb "66"
    defb "66"

;; sector-progress posts (2px x 3): lit = yellow, dim = blue
mark_lit_pen:
    defb "22"
    defb "22"
    defb "22"
mark_dim_pen:
    defb "99"
    defb "99"
    defb "99"

exp0_pen:                       ; 8 x 8 explosion frame 0 (small)
    defb "00000000"
    defb "00000000"
    defb "00033000"
    defb "00366300"
    defb "00366300"
    defb "00033000"
    defb "00000000"
    defb "00000000"

exp1_pen:                       ; 8 x 8 explosion frame 1 (burst)
    defb "00033000"
    defb "03322330"
    defb "03266230"
    defb "32666623"
    defb "32666623"
    defb "03266230"
    defb "03322330"
    defb "00033000"

exp2_pen:                       ; 8 x 8 explosion frame 2 (fading embers)
    defb "30000003"
    defb "05300350"
    defb "00533500"
    defb "00355300"
    defb "00355300"
    defb "00533500"
    defb "05300350"
    defb "30000003"

;;============================================================================
;; RAM BUFFERS / VARIABLES
;;============================================================================
;; encoded sprites (mask,data interleaved) - filled by init_sprites
pl_spr:         defs 2*PL_W*PL_H
en_spr0:        defs 2*EN_W*EN_H
en_spr1:        defs 2*EN_W*EN_H
en_spr2:        defs 2*EN_W*EN_H
en_spr3:        defs 2*EN_W*EN_H
en_spr4:        defs 2*EN_W*EN_H
bul_spr:        defs 2*BL_W*BL_H
mark_lit_spr:   defs 2*MARK_W*MARK_H
mark_dim_spr:   defs 2*MARK_W*MARK_H
exp_spr0:       defs 2*EX_W*EX_H
exp_spr1:       defs 2*EX_W*EX_H
exp_spr2:       defs 2*EX_W*EX_H

;; embedded bold 8x8 font, codes 32..90 (space..'Z'); my_putc indexes (char-32)*8
font_tbl:
    defb 0,0,0,0,0,0,0,0                                 ; 32 space
    defb %00110000,%00110000,%00110000,%00110000,%00110000,%00000000,%00110000,0 ; 33 !
    defb 0,0,0,0,0,0,0,0                                 ; 34 "
    defb 0,0,0,0,0,0,0,0                                 ; 35 #
    defb 0,0,0,0,0,0,0,0                                 ; 36 $
    defb 0,0,0,0,0,0,0,0                                 ; 37 %
    defb 0,0,0,0,0,0,0,0                                 ; 38 &
    defb 0,0,0,0,0,0,0,0                                 ; 39 '
    defb 0,0,0,0,0,0,0,0                                 ; 40 (
    defb 0,0,0,0,0,0,0,0                                 ; 41 )
    defb 0,0,0,0,0,0,0,0                                 ; 42 *
    defb 0,0,0,0,0,0,0,0                                 ; 43 +
    defb 0,0,0,0,0,0,0,0                                 ; 44 ,
    defb 0,0,0,%01111100,%01111100,0,0,0                 ; 45 -
    defb 0,0,0,0,0,%00110000,%00110000,0                 ; 46 .
    defb %00000100,%00001100,%00011000,%00110000,%01100000,%11000000,%10000000,0 ; 47 /
    defb %01111100,%11000110,%11001110,%11011110,%11110110,%11100110,%01111100,0 ; 48 0
    defb %00110000,%01110000,%11110000,%00110000,%00110000,%00110000,%11111100,0 ; 49 1
    defb %01111100,%11000110,%00000110,%00011100,%01110000,%11000000,%11111110,0 ; 50 2
    defb %11111110,%00001100,%00011000,%00111100,%00000110,%11000110,%01111100,0 ; 51 3
    defb %00011100,%00111100,%01101100,%11001100,%11111110,%00001100,%00001100,0 ; 52 4
    defb %11111110,%11000000,%11111100,%00000110,%00000110,%11000110,%01111100,0 ; 53 5
    defb %00111100,%01100000,%11000000,%11111100,%11000110,%11000110,%01111100,0 ; 54 6
    defb %11111110,%00000110,%00001100,%00011000,%00110000,%00110000,%00110000,0 ; 55 7
    defb %01111100,%11000110,%11000110,%01111100,%11000110,%11000110,%01111100,0 ; 56 8
    defb %01111100,%11000110,%11000110,%01111110,%00000110,%00001100,%01111000,0 ; 57 9
    defb 0,%00110000,%00110000,0,%00110000,%00110000,0,0                         ; 58 :
    defb 0,0,0,0,0,0,0,0                                 ; 59 ;
    defb 0,0,0,0,0,0,0,0                                 ; 60 <
    defb 0,0,%01111100,0,%01111100,0,0,0                 ; 61 =
    defb 0,0,0,0,0,0,0,0                                 ; 62 >
    defb 0,0,0,0,0,0,0,0                                 ; 63 ?
    defb 0,0,0,0,0,0,0,0                                 ; 64 @
    defb %00111000,%01101100,%11000110,%11000110,%11111110,%11000110,%11000110,0 ; 65 A
    defb %11111100,%11000110,%11000110,%11111100,%11000110,%11000110,%11111100,0 ; 66 B
    defb %01111100,%11000110,%11000000,%11000000,%11000000,%11000110,%01111100,0 ; 67 C
    defb %11111000,%11001100,%11000110,%11000110,%11000110,%11001100,%11111000,0 ; 68 D
    defb %11111110,%11000000,%11000000,%11111100,%11000000,%11000000,%11111110,0 ; 69 E
    defb %11111110,%11000000,%11000000,%11111100,%11000000,%11000000,%11000000,0 ; 70 F
    defb %01111100,%11000110,%11000000,%11001110,%11000110,%11000110,%01111110,0 ; 71 G
    defb %11000110,%11000110,%11000110,%11111110,%11000110,%11000110,%11000110,0 ; 72 H
    defb %01111100,%00110000,%00110000,%00110000,%00110000,%00110000,%01111100,0 ; 73 I
    defb %00011110,%00001100,%00001100,%00001100,%11001100,%11001100,%01111000,0 ; 74 J
    defb %11000110,%11001100,%11011000,%11110000,%11011000,%11001100,%11000110,0 ; 75 K
    defb %11000000,%11000000,%11000000,%11000000,%11000000,%11000000,%11111110,0 ; 76 L
    defb %11000110,%11101110,%11111110,%11010110,%11000110,%11000110,%11000110,0 ; 77 M
    defb %11000110,%11100110,%11110110,%11011110,%11001110,%11000110,%11000110,0 ; 78 N
    defb %01111100,%11000110,%11000110,%11000110,%11000110,%11000110,%01111100,0 ; 79 O
    defb %11111100,%11000110,%11000110,%11111100,%11000000,%11000000,%11000000,0 ; 80 P
    defb %01111100,%11000110,%11000110,%11000110,%11011110,%11001100,%01110110,0 ; 81 Q
    defb %11111100,%11000110,%11000110,%11111100,%11011000,%11001100,%11000110,0 ; 82 R
    defb %01111100,%11000110,%11000000,%01111100,%00000110,%11000110,%01111100,0 ; 83 S
    defb %11111110,%00110000,%00110000,%00110000,%00110000,%00110000,%00110000,0 ; 84 T
    defb %11000110,%11000110,%11000110,%11000110,%11000110,%11000110,%01111100,0 ; 85 U
    defb %11000110,%11000110,%11000110,%11000110,%01101100,%00111000,%00010000,0 ; 86 V
    defb %11000110,%11000110,%11000110,%11010110,%11111110,%11101110,%11000110,0 ; 87 W
    defb %11000110,%01101100,%00111000,%00010000,%00111000,%01101100,%11000110,0 ; 88 X
    defb %11000110,%11000110,%01101100,%00111000,%00110000,%00110000,%00110000,0 ; 89 Y
    defb %11111110,%00001100,%00011000,%00110000,%01100000,%11000000,%11111110,0 ; 90 Z

;; text rendering scratch
text_pp:        defs 4
mpc_x:          defb 0
mpc_y:          defb 0
pd_val:         defb 0
dos_base:       defw 0          ; overscan text: current line base address

;; sprite blit scratch
spr_w:          defb 0
spr_h:          defb 0

;; double-buffer state
parity:         defb 0
draw_tbl:       defw tbl_c
disp_r12:       defb R12_BUF0
hud_count:      defb 0
scroll_off:     defb 0
st_cnt:         defb 0          ; cityscape: columns left in current structure
st_h:           defb 0          ; cityscape: structure height (above ground)
st_wall:        defb 0          ; cityscape: wall byte (blue building / red house)
st_xor:         defb 0          ; cityscape: window toggle mask (0 = solid house)
gap_cnt:        defb 0          ; cityscape: ground-only columns left before next structure
gap_after:      defb 0          ; cityscape: gap to leave after the current structure
m1_x:           defb 0
m1_y:           defb 0
m2_buf:         defs 4          ; 2x title: 4 expanded Mode-1 bytes per glyph row
dts_r:          defb 0
dts_off:        defb 0          ; cached scroll_off for the blit
dts_dtp:        defw 0          ; running pointer into the row-address table
dts_srcrow:     defw 0          ; running src base (terr_bmp + row*128)

;; game variables
level:          defb 1
score:          defw 0
lives:          defb 3
pl_x:           defb PL_XSTART
pl_ox0:         defb PL_XSTART
pl_ox1:         defb PL_XSTART
pl_y:           defb PL_YSTART
pl_oy0:         defb PL_YSTART
pl_oy1:         defb PL_YSTART
ene_speed:      defb 1
wave_in_sector: defb 0          ; waves finished in the current sector (sector N has N)
pat_in_wave:    defb 0          ; pattern within the current wave (0..4 = the 5 patterns)
weapon_level:   defb 0          ; 0 single, 1 dual, 2 tri-spread
kill_streak:    defb 0          ; consecutive kills toward the next firepower upgrade
nb_y:           defb 0          ; pending bullet Y / VY for spawn_bullet
nb_vy:          defb 0
dsm_idx:        defb 0          ; sector-marker draw loop index
kills_needed:   defb 8
lvl_kills:      defb 0
spawn_delay:    defb 70
spawn_timer:    defb 70
fire_timer:     defb 0
game_state:     defb 0
wave_type:      defb 0
wave_remaining: defb 0
wave_index:     defb 0
release_timer:  defb 0
cur_reldelay:   defb 0
exp_x:          defb 0
exp_y:          defb 0
pl_boom:        defb 0
boom_x:         defb 0
boom_y:         defb 0
snd_a_t:        defb 0
snd_a_per:      defw 0          ; current laser sweep period (12-bit)
pu_snd_t:       defb 0          ; powerup chime timer (rising tone on ch A)
snd_b_t:        defb 0
note_lo:        defb 0
note_hi:        defb 0
note_dur:       defb 0
rng_seed:       defw &A55A
th_rand:        defs 128
terr_bmp:       defs TERR_NT*128
bar_pos:        defw 0          ; bar 1 position (scrolls down)
bar2_pos:       defw 0          ; bar 2 position (scrolls up)
bar3_pos:       defw 0          ; bar 3 position (scrolls down, slow)
barr:           defs NBARS*4    ; per-frame sort array: [posL,posH,bufL,bufH] x NBARS
beam_pos:       defw 0          ; current raster beam position while drawing bars
bar_buf:        defs RB_BARLEN  ; bar 1 working copy (red,  shimmered each frame)
bar2_buf:       defs RB_BARLEN  ; bar 2 working copy (neon, shimmered each frame)
bar3_buf:       defs RB_BARLEN  ; bar 3 working copy (green, shimmered each frame)

;; keyboard matrix buffer (10 lines)
key_buf:        defs 10

;; TOPGUN cheat state
prev_keys:      defs 10         ; last frame's key_buf (edge detection)
cheat_idx:      defb 0          ; how many of T-O-P-G-U-N matched so far
invincible:     defb 0          ; 1 = cheat active
;; (keyboard line, bit-mask) for T,O,P,G,U,N  (matrix: pressed = bit clear)
cheat_seq:
    defb 6,&08                  ; T = line6 bit3
    defb 4,&04                  ; O = line4 bit2
    defb 3,&08                  ; P = line3 bit3
    defb 6,&10                  ; G = line6 bit4
    defb 5,&04                  ; U = line5 bit2
    defb 5,&40                  ; N = line5 bit6

;; object pools
enemy_pool:     defs EN_SZ*MAX_ENE
bullet_pool:    defs BL_SZ*MAX_BUL
explosion_pool: defs EX_SZ*MAX_EXP
star_data:      defs STAR_SZ*N_STARS

;; scanline address tables (one per buffer)
tbl_c:          defs 200*2
tbl_8:          defs 200*2

;; win screen support
;; 47's 16 inks as HARDWARE gate-array codes (converted from its firmware ink table)
win_pal:        defb &54,&4E,&5C,&4A,&5E,&46,&40,&44,&4C,&4B,&47,&43,&58,&56,&45,&5B
;; (the compressed win image is loaded to WIN_DATA=&2000 by the DISC loader, not embedded)

;; stack (grows down from stack_end)
                defs 256
stack_end:

    end


