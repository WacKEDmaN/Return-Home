#!/usr/bin/env python3
# Minimal Z80 interpreter to smoke-test return_home.bin headless.
# Firmware calls are stubbed; Space/fire + up/down are simulated as held.
# Goal: run many frames and detect the crash signature (writes below 0x4000 /
# into firmware, PC running off into low memory, or unimplemented opcodes).
import sys

mem = bytearray(0x10000)

def load(path, org):
    data = open(path, "rb").read()
    mem[org:org+len(data)] = data
    return len(data)

# ---- CPU state ----
A=B=C=D=E=H=L=F=0
IX=IY=0
SP=0xBF00
PC=0x4000
frame=0
bad_writes=[]
halt=False

# flag bits
FC=0x01; FN=0x02; FPV=0x04; FH=0x10; FZ=0x40; FS=0x80

def parity(v):
    return 0 if bin(v&0xFF).count("1")%2 else FPV

def setf(mask, cond):
    global F
    if cond: F|=mask
    else: F&=~mask & 0xFF

def add8(a,b,cin=0):
    global F
    s=a+b+cin; r=s&0xFF
    F=0
    if r&0x80: F|=FS
    if r==0: F|=FZ
    if ((a&0xF)+(b&0xF)+cin)>0xF: F|=FH
    if (~(a^b))&(a^r)&0x80: F|=FPV
    if s>0xFF: F|=FC
    return r

def sub8(a,b,cin=0):
    global F
    s=a-b-cin; r=s&0xFF
    F=FN
    if r&0x80: F|=FS
    if r==0: F|=FZ
    if ((a&0xF)-(b&0xF)-cin)<0: F|=FH
    if (a^b)&(a^r)&0x80: F|=FPV
    if s<0: F|=FC
    return r

def cp8(a,b):
    sub8(a,b,0)  # flags only

def and8(a,b):
    global F
    r=a&b; F=FH|parity(r)
    if r&0x80: F|=FS
    if r==0: F|=FZ
    return r

def or8(a,b):
    global F
    r=a|b; F=parity(r)
    if r&0x80: F|=FS
    if r==0: F|=FZ
    return r

def xor8(a,b):
    global F
    r=(a^b)&0xFF; F=parity(r)
    if r&0x80: F|=FS
    if r==0: F|=FZ
    return r

def inc8(v):
    global F
    r=(v+1)&0xFF
    F &= FC
    if r&0x80: F|=FS
    if r==0: F|=FZ
    if (v&0xF)+1>0xF: F|=FH
    if v==0x7F: F|=FPV
    return r

def dec8(v):
    global F
    r=(v-1)&0xFF
    F &= FC
    F |= FN
    if r&0x80: F|=FS
    if r==0: F|=FZ
    if (v&0xF)==0: F|=FH
    if v==0x80: F|=FPV
    return r

def add16(a,b):
    global F
    s=a+b; r=s&0xFFFF
    F &= (FS|FZ|FPV)  # preserve S,Z,PV
    if ((a&0xFFF)+(b&0xFFF))>0xFFF: F|=FH
    if s>0xFFFF: F|=FC
    return r

def rd(a): return mem[a&0xFFFF]
def wr(a,v):
    a&=0xFFFF
    # legit: code/data/stack 0x4000-0x7FFF, screen buffers 0x8000-0xFFFF
    if a<0x4000:
        if len(bad_writes)<20:
            bad_writes.append((PC,a,v&0xFF))
    mem[a]=v&0xFF

def rd16(a): return rd(a)|(rd(a+1)<<8)
def wr16(a,v): wr(a,v&0xFF); wr(a+1,(v>>8)&0xFF)

def push(v):
    global SP
    SP=(SP-2)&0xFFFF
    wr16(SP,v)
def pop():
    global SP
    v=rd16(SP); SP=(SP+2)&0xFFFF; return v

# register access helpers for r-index (0=B..7=A, 6=(HL))
def get_r(i):
    if i==0:return B
    if i==1:return C
    if i==2:return D
    if i==3:return E
    if i==4:return H
    if i==5:return L
    if i==6:return rd((H<<8)|L)
    return A
def set_r(i,v):
    global B,C,D,E,H,L,A
    v&=0xFF
    if i==0:B=v
    elif i==1:C=v
    elif i==2:D=v
    elif i==3:E=v
    elif i==4:H=v
    elif i==5:L=v
    elif i==6:wr((H<<8)|L,v)
    else:A=v

def hl(): return (H<<8)|L
def de(): return (D<<8)|E
def bc(): return (B<<8)|C

# ---- simulated input ----
import os
NOINPUT = os.environ.get("NOINPUT")
def key_pressed(keynum):
    if NOINPUT: return False
    # always fire; alternate up/down each ~80 frames to hit boundaries
    if keynum in (47,76,77): return True          # fire
    phase=(frame//80)&1
    if keynum in (0,67,72): return phase==0        # up
    if keynum in (2,69,73): return phase==1        # down
    return False

def next_line(addr):
    addr=(addr+0x800)&0xFFFF
    if (addr&0x3800)==0:
        addr=(addr-0x4000+0x50)&0xFFFF
    return addr

def firmware(addr):
    global A,H,L,F,PC,SP
    if addr==0xBBA5:  # TXT_GET_MATRIX: A=char -> HL=ptr to 8-byte matrix
        # return a fixed dummy glyph buffer (solid pattern) at 0x0100
        H=0x01; L=0x00
    # SCR_SET_MODE/INK/BORDER: no-op
    PC=pop()  # RET

# ---- I/O hardware model ----
crtc_reg=0
displayed_page=0xC000
flips=0
kb_line=0

def sim_key_line(line):
    v=0xFF                       # released = 1
    if NOINPUT: return v
    firedown = (frame & 8)==0    # fire held with release windows (for debounce)
    if line==5 and firedown: v &= ~0x80          # Space (bit7)
    if line==9 and firedown: v &= ~0x20          # Joy fire1 (bit5)
    if (frame & 32):
        if line==0: v &= ~0x01                   # Cursor Up (bit0)
    else:
        if line==0: v &= ~0x04                   # Cursor Down (bit2)
    return v & 0xFF

vphase=0
VSYNC_PERIOD=300                 # port-B reads per frame (model)
def io_in(b,c):
    global frame, vphase
    if b==0xF5:                  # PPI port B: bit0 = VSYNC (toggles, like real HW)
        vphase+=1
        if vphase>=VSYNC_PERIOD:
            vphase=0
            frame+=1
        return 0x01 if vphase<12 else 0x00   # active ~12 reads, then inactive
    if b==0xF4:                  # PPI port A: selected keyboard line
        return sim_key_line(kb_line)
    return 0xFF

def io_out(b,c,val):
    global crtc_reg, displayed_page, flips, kb_line
    if b==0xBC:
        crtc_reg=val
        return
    if b==0xBD:
        if crtc_reg==12:
            np = 0xC000 if val==0x30 else (0x8000 if val==0x20 else displayed_page)
            if np!=displayed_page: flips+=1
            displayed_page=np
        return
    if b==0xF6:                  # PPI port C: keyboard line select (read func)
        if (val & 0xC0)==0x40:
            kb_line = val & 0x0F
        return

steps=0
def step():
    global PC,A,B,C,D,E,H,L,F,IX,IY,SP,steps
    steps+=1
    op=rd(PC)

    # firmware trap (jumpblock region)
    if 0xB900<=PC<0xC000:
        firmware(PC); return

    PC=(PC+1)&0xFFFF

    # ---- DD / FD prefix (IX/IY) ----
    if op in (0xDD,0xFD):
        useIX = (op==0xDD)
        op2=rd(PC); PC=(PC+1)&0xFFFF
        def getR(): return IX if useIX else IY
        def setR(v):
            global IX,IY
            if useIX: IX=v&0xFFFF
            else: IY=v&0xFFFF
        if op2==0x21:  # ld ix,nn
            setR(rd16(PC)); PC=(PC+2)&0xFFFF; return
        if op2 in (0x09,0x19,0x39):  # add ix,bc/de/sp
            src={0x09:bc(),0x19:de(),0x39:SP}[op2]
            setR(add16(getR(),src)); return
        if op2==0x23: setR((getR()+1)&0xFFFF); return  # inc ix
        if op2==0x2B: setR((getR()-1)&0xFFFF); return  # dec ix
        if op2==0xE5: push(getR()); return             # push ix
        if op2==0xE1: setR(pop()); return              # pop ix
        # (IX+d) forms
        if op2 in (0x7E,0x46,0x4E,0x56,0x5E,0x66,0x6E,
                   0x70,0x71,0x72,0x73,0x74,0x75,0x77,
                   0x36,0x34,0x35,0x86,0x96,0xBE,0xA6,0xB6,0x8E,0x9E,0xAE):
            d=rd(PC); PC=(PC+1)&0xFFFF
            if d>=0x80: d-=0x100
            ea=(getR()+d)&0xFFFF
            if op2==0x7E: A=rd(ea); return
            if op2==0x46: B=rd(ea); return
            if op2==0x4E: C=rd(ea); return
            if op2==0x56: D=rd(ea); return
            if op2==0x5E: E=rd(ea); return
            if op2==0x66: H=rd(ea); return
            if op2==0x6E: L=rd(ea); return
            if op2==0x70: wr(ea,B); return
            if op2==0x71: wr(ea,C); return
            if op2==0x72: wr(ea,D); return
            if op2==0x73: wr(ea,E); return
            if op2==0x74: wr(ea,H); return
            if op2==0x75: wr(ea,L); return
            if op2==0x77: wr(ea,A); return
            if op2==0x36: n=rd(PC); PC=(PC+1)&0xFFFF; wr(ea,n); return
            if op2==0x34: wr(ea,inc8(rd(ea))); return
            if op2==0x35: wr(ea,dec8(rd(ea))); return
            v=rd(ea)
            if op2==0x86: A=add8(A,v); return
            if op2==0x8E: A=add8(A,v,F&FC); return
            if op2==0x96: A=sub8(A,v); return
            if op2==0x9E: A=sub8(A,v,F&FC); return
            if op2==0xA6: A=and8(A,v); return
            if op2==0xB6: A=or8(A,v); return
            if op2==0xAE: A=xor8(A,v); return
            if op2==0xBE: cp8(A,v); return
        raise Exception(f"unimpl {'DD' if useIX else 'FD'} {op2:02X} @ {PC-2:04X}")

    # ---- CB prefix ----
    if op==0xCB:
        op2=rd(PC); PC=(PC+1)&0xFFFF
        grp=(op2>>3)&7; ri=op2&7
        v=get_r(ri)
        kind=op2>>6
        if kind==0:  # rotates/shifts
            if grp==1:  # rrc
                c=v&1; v=((v>>1)|(c<<7))&0xFF
            elif grp==7:  # srl
                c=v&1; v=(v>>1)&0xFF
            elif grp==4:  # sla
                c=(v>>7)&1; v=(v<<1)&0xFF
            elif grp==6:  # sll (undoc) - not used
                c=(v>>7)&1; v=((v<<1)|1)&0xFF
            elif grp==0:  # rlc
                c=(v>>7)&1; v=((v<<1)|c)&0xFF
            elif grp==2:  # rl (through carry)
                oc=1 if (F&FC) else 0; c=(v>>7)&1; v=((v<<1)|oc)&0xFF
            elif grp==3:  # rr (through carry)
                oc=1 if (F&FC) else 0; c=v&1; v=((v>>1)|(oc<<7))&0xFF
            else:
                raise Exception(f"unimpl CB {op2:02X}")
            F=parity(v)
            if v&0x80: F|=FS
            if v==0: F|=FZ
            if c: F|=FC
            set_r(ri,v); return
        elif kind==1:  # bit
            z = (v>>grp)&1
            F = (F&FC)|FH
            if z==0: F|=FZ|FPV
            if grp==7 and z: F|=FS
            return
        elif kind==2:  # res
            set_r(ri, v & ~(1<<grp)); return
        else:          # set
            set_r(ri, v | (1<<grp)); return

    # ---- ED prefix ----
    if op==0xED:
        op2=rd(PC); PC=(PC+1)&0xFFFF
        if op2==0xB0:  # ldir
            while True:
                wr(de(), rd(hl()))
                Hl=(hl()+1)&0xFFFF; setHL(Hl)
                De=(de()+1)&0xFFFF; setDE(De)
                Bc=(bc()-1)&0xFFFF; setBC(Bc)
                if Bc==0: break
            F&=~(FH|FN|FPV)&0xFF
            return
        if op2==0x53: wr16(rd16(PC),de()); PC=(PC+2)&0xFFFF; return
        if op2==0x5B: setDE(rd16(rd16(PC))); PC=(PC+2)&0xFFFF; return
        # sbc/adc hl,ss  (ED 42/52/62/72 sbc ; 4A/5A/6A/7A adc)
        if op2 in (0x42,0x52,0x62,0x72,0x4A,0x5A,0x6A,0x7A):
            ss={0x42:bc(),0x52:de(),0x62:hl(),0x72:SP,
                0x4A:bc(),0x5A:de(),0x6A:hl(),0x7A:SP}[op2]
            cin=1 if (F&FC) else 0
            h0=hl()
            if op2 in (0x42,0x52,0x62,0x72):
                res=h0-ss-cin; c=1 if res<0 else 0; nf=FN
            else:
                res=h0+ss+cin; c=1 if res>0xFFFF else 0; nf=0
            r=res&0xFFFF; setHL(r)
            f=nf
            if c: f|=FC
            if r==0: f|=FZ
            if r&0x8000: f|=FS
            F=f
            return
        # IN r,(c)  : ED 40/48/50/58/60/68/78  (port = BC)
        if op2 in (0x40,0x48,0x50,0x58,0x60,0x68,0x78):
            val=io_in(B,C)
            ridx={0x40:0,0x48:1,0x50:2,0x58:3,0x60:4,0x68:5,0x78:7}[op2]
            set_r(ridx,val)
            # flags for IN r,(c): S,Z,P set from val; H,N=0; C unchanged
            f2=F&FC
            if val&0x80: f2|=FS
            if val==0: f2|=FZ
            f2|=parity(val)
            F=f2
            return
        # OUT (c),r : ED 41/49/51/59/61/69/79 ; ED 71 = out (c),0
        if op2 in (0x41,0x49,0x51,0x59,0x61,0x69,0x79,0x71):
            ridx={0x41:0,0x49:1,0x51:2,0x59:3,0x61:4,0x69:5,0x79:7}.get(op2,None)
            val=0 if op2==0x71 else get_r(ridx)
            io_out(B,C,val)
            return
        # IM 0/1/2 and LD I,A / LD R,A / RETI/RETN : no-op for this emulator
        if op2 in (0x46,0x4E,0x56,0x5E,0x66,0x6E,0x47,0x4F,0x57,0x5F):
            return
        if op2 in (0x4D,0x45):       # RETI / RETN
            PC=pop(); return
        raise Exception(f"unimpl ED {op2:02X} @ {(PC-2)&0xFFFF:04X}")

    # ---- main table ----
    # ld r,r'  (0x40-0x7F, not 0x76)
    if 0x40<=op<=0x7F and op!=0x76:
        dst=(op>>3)&7; src=op&7
        set_r(dst, get_r(src)); return
    # ALU A,r (0x80-0xBF)
    if 0x80<=op<=0xBF:
        g=(op>>3)&7; v=get_r(op&7)
        alu(g,v); return

    # misc
    if op==0x00: return  # nop
    if op==0x76:
        return                       # HALT: emulator has no interrupts -> treat as NOP
    if op==0xF3 or op==0xFB: return  # di/ei
    # 16-bit loads ld rr,nn
    if op==0x01: setBC(rd16(PC)); PC=(PC+2)&0xFFFF; return
    if op==0x11: setDE(rd16(PC)); PC=(PC+2)&0xFFFF; return
    if op==0x21: setHL(rd16(PC)); PC=(PC+2)&0xFFFF; return
    if op==0x31: SP=rd16(PC); PC=(PC+2)&0xFFFF; return
    # ld r,n
    if op in (0x06,0x0E,0x16,0x1E,0x26,0x2E,0x36,0x3E):
        n=rd(PC); PC=(PC+1)&0xFFFF
        set_r((op>>3)&7, n); return
    # ld (nn),a / ld a,(nn)
    if op==0x32: wr(rd16(PC),A); PC=(PC+2)&0xFFFF; return
    if op==0x3A: A=rd(rd16(PC)); PC=(PC+2)&0xFFFF; return
    # ld (nn),hl / ld hl,(nn)
    if op==0x22: wr16(rd16(PC),hl()); PC=(PC+2)&0xFFFF; return
    if op==0x2A: setHL(rd16(rd16(PC))); PC=(PC+2)&0xFFFF; return
    # ld (bc)/(de),a ; ld a,(bc)/(de)
    if op==0x02: wr(bc(),A); return
    if op==0x12: wr(de(),A); return
    if op==0x0A: A=rd(bc()); return
    if op==0x1A: A=rd(de()); return
    # inc/dec rr
    if op==0x03: setBC((bc()+1)&0xFFFF); return
    if op==0x13: setDE((de()+1)&0xFFFF); return
    if op==0x23: setHL((hl()+1)&0xFFFF); return
    if op==0x33: SP=(SP+1)&0xFFFF; return
    if op==0x0B: setBC((bc()-1)&0xFFFF); return
    if op==0x1B: setDE((de()-1)&0xFFFF); return
    if op==0x2B: setHL((hl()-1)&0xFFFF); return
    if op==0x3B: SP=(SP-1)&0xFFFF; return
    # inc/dec r
    if op in (0x04,0x0C,0x14,0x1C,0x24,0x2C,0x34,0x3C):
        i=(op>>3)&7; set_r(i, inc8(get_r(i))); return
    if op in (0x05,0x0D,0x15,0x1D,0x25,0x2D,0x35,0x3D):
        i=(op>>3)&7; set_r(i, dec8(get_r(i))); return
    # add hl,rr
    if op==0x09: setHL(add16(hl(),bc())); return
    if op==0x19: setHL(add16(hl(),de())); return
    if op==0x29: setHL(add16(hl(),hl())); return
    if op==0x39: setHL(add16(hl(),SP)); return
    # rotates
    if op==0x07:  # rlca
        c=(A>>7)&1; A=((A<<1)|c)&0xFF; F&=(FS|FZ|FPV); F&=~(FH|FN)&0xFF
        setf(FC,c); return
    if op==0x0F:  # rrca
        c=A&1; A=((A>>1)|(c<<7))&0xFF; F&=(FS|FZ|FPV); F&=~(FH|FN)&0xFF
        setf(FC,c); return
    if op==0x17:  # rla (through carry)
        oc=1 if (F&FC) else 0; c=(A>>7)&1; A=((A<<1)|oc)&0xFF
        F&=(FS|FZ|FPV); F&=~(FH|FN)&0xFF; setf(FC,c); return
    if op==0x1F:  # rra (through carry)
        oc=1 if (F&FC) else 0; c=A&1; A=((A>>1)|(oc<<7))&0xFF
        F&=(FS|FZ|FPV); F&=~(FH|FN)&0xFF; setf(FC,c); return
    # ALU A,n
    if op in (0xC6,0xCE,0xD6,0xDE,0xE6,0xEE,0xF6,0xFE):
        n=rd(PC); PC=(PC+1)&0xFFFF
        g={0xC6:0,0xCE:1,0xD6:2,0xDE:3,0xE6:4,0xEE:5,0xF6:6,0xFE:7}[op]
        alu(g,n); return
    # jr
    if op==0x18:
        d=rd(PC); PC=(PC+1)&0xFFFF
        if d>=0x80:d-=0x100
        PC=(PC+d)&0xFFFF; return
    if op in (0x20,0x28,0x30,0x38):  # jr cc
        d=rd(PC); PC=(PC+1)&0xFFFF
        if d>=0x80:d-=0x100
        cc={0x20:not(F&FZ),0x28:F&FZ,0x30:not(F&FC),0x38:F&FC}[op]
        if cc: PC=(PC+d)&0xFFFF
        return
    if op==0x10:  # djnz
        d=rd(PC); PC=(PC+1)&0xFFFF
        if d>=0x80:d-=0x100
        B=(B-1)&0xFF
        if B!=0: PC=(PC+d)&0xFFFF
        return
    # jp
    if op==0xC3: PC=rd16(PC); return
    if op in (0xC2,0xCA,0xD2,0xDA,0xE2,0xEA,0xF2,0xFA):
        nn=rd16(PC); PC=(PC+2)&0xFFFF
        cc={0xC2:not(F&FZ),0xCA:F&FZ,0xD2:not(F&FC),0xDA:F&FC,
            0xE2:not(F&FPV),0xEA:F&FPV,0xF2:not(F&FS),0xFA:F&FS}[op]
        if cc: PC=nn
        return
    if op==0xE9: PC=hl(); return  # jp (hl)
    # call
    if op==0xCD:
        nn=rd16(PC); PC=(PC+2)&0xFFFF; push(PC); PC=nn; return
    if op in (0xC4,0xCC,0xD4,0xDC,0xE4,0xEC,0xF4,0xFC):
        nn=rd16(PC); PC=(PC+2)&0xFFFF
        cc={0xC4:not(F&FZ),0xCC:F&FZ,0xD4:not(F&FC),0xDC:F&FC,
            0xE4:not(F&FPV),0xEC:F&FPV,0xF4:not(F&FS),0xFC:F&FS}[op]
        if cc: push(PC); PC=nn
        return
    # ret
    if op==0xC9: PC=pop(); return
    if op in (0xC0,0xC8,0xD0,0xD8,0xE0,0xE8,0xF0,0xF8):
        cc={0xC0:not(F&FZ),0xC8:F&FZ,0xD0:not(F&FC),0xD8:F&FC,
            0xE0:not(F&FPV),0xE8:F&FPV,0xF0:not(F&FS),0xF8:F&FS}[op]
        if cc: PC=pop()
        return
    # push/pop
    if op==0xC5: push(bc()); return
    if op==0xD5: push(de()); return
    if op==0xE5: push(hl()); return
    if op==0xF5: push((A<<8)|F); return
    if op==0xC1: setBC(pop()); return
    if op==0xD1: setDE(pop()); return
    if op==0xE1: setHL(pop()); return
    if op==0xF1:
        v=pop(); A=(v>>8)&0xFF; F=v&0xFF; return
    if op==0x2F:  # cpl
        A^=0xFF; F|=FH|FN; return
    if op==0x37:  # scf
        F|=FC; F&=~(FH|FN)&0xFF; return
    if op==0x3F:  # ccf
        F^=FC; F&=~FN&0xFF; return
    if op==0xEB:  # ex de,hl
        D,E,H,L = H,L,D,E; return

    raise Exception(f"unimpl op {op:02X} @ {(PC-1)&0xFFFF:04X}")

def alu(g,v):
    global A
    if g==0: A=add8(A,v)
    elif g==1: A=add8(A,v,1 if F&FC else 0)
    elif g==2: A=sub8(A,v)
    elif g==3: A=sub8(A,v,1 if F&FC else 0)
    elif g==4: A=and8(A,v)
    elif g==5: A=xor8(A,v)
    elif g==6: A=or8(A,v)
    else: cp8(A,v)

def setBC(v):
    global B,C; B=(v>>8)&0xFF; C=v&0xFF
def setDE(v):
    global D,E; D=(v>>8)&0xFF; E=v&0xFF
def setHL(v):
    global H,L; H=(v>>8)&0xFF; L=v&0xFF

# symbol addresses (from RASM -sa)
STAR=0x53FA; NST=36; STAR_SZ=3
ENEMY=0x5320; EN_SZ=11; MAX_ENE=10
LEVEL=0x52FE; SCORE=0x52FF; LIVES=0x5300; GAME_STATE=0x530D

# ---- run ----
n=load(sys.argv[1], 0x4000)
for i in range(8): mem[0x0100+i]=0x3C   # dummy glyph for TXT_GET_MATRIX
print(f"loaded {n} bytes at 0x4000, entry 0x4000")
PC=0x4000
maxframe=int(sys.argv[2]) if len(sys.argv)>2 else 600
try:
    while frame<maxframe and steps<200_000_000 and not halt:
        if PC<0x0100:
            print(f"*** CRASH: PC ran into low memory 0x{PC:04X} at step {steps}, frame {frame}")
            break
        if not (0x4000<=SP<=0xBF02):
            print(f"*** CRASH: SP out of range 0x{SP:04X} at PC 0x{PC:04X}, frame {frame}")
            break
        step()
    else:
        print(f"completed: frame={frame} steps={steps} halt={halt}")
except Exception as ex:
    import traceback; traceback.print_exc()
    print(f"*** EXCEPTION at PC~0x{PC:04X} frame {frame}: {ex}")

print(f"final: frame={frame} steps={steps} PC=0x{PC:04X} SP=0x{SP:04X}")
print(f"display flips: {flips}   last displayed page: 0x{displayed_page:04X}")

# ---- state dump ----
xs=set()
for i in range(NST):
    x=mem[STAR+i*STAR_SZ]; y=mem[STAR+i*STAR_SZ+1]; sp=mem[STAR+i*STAR_SZ+2]
    xs.add((x,y))
print(f"stars: {NST}, distinct (x,y): {len(xs)}, sample: " +
      ", ".join(f"({mem[STAR+i*STAR_SZ]},{mem[STAR+i*STAR_SZ+1]},s{mem[STAR+i*STAR_SZ+2]})" for i in range(6)))
for base,name in ((0x8000,"BUF1(&8000)"),(0xC000,"BUF0(&C000)")):
    lit=sum(1 for off in range(0x4000) if mem[base+off])
    print(f"non-zero bytes in {name}: {lit}")
print(f"game: level={mem[LEVEL]} score={mem[SCORE]} lives={mem[LIVES]} state={mem[GAME_STATE]}")
ene=sum(1 for i in range(MAX_ENE) if mem[ENEMY+i*EN_SZ+2])
exp=sum(1 for i in range(8) if mem[0x53B2+i*9+2])
print(f"active enemies: {ene}  active explosions: {exp}")
if bad_writes:
    print(f"!!! {len(bad_writes)} suspicious writes (PC, addr, val):")
    for w in bad_writes[:20]:
        print(f"    PC=0x{w[0]:04X} -> [0x{w[1]:04X}]=0x{w[2]:02X}")
else:
    print("no suspicious writes (all writes in data/screen/stack regions)")
