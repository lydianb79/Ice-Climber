#!/usr/bin/env python3
"""
NES (NROM) 6502 static recompiler.

Reads an iNES ROM, traces 6502 code from the interrupt vectors (plus any extra
entry points), and emits C:

  * recomp_run()   - every discovered instruction becomes a `case`/label inside
                     one big dispatch function. Direct jumps/branches/JSRs turn
                     into `goto`, dynamic control flow (RTS, RTI, JMP (ind))
                     goes back through the switch. The 6502 stack lives in
                     emulated RAM so stack tricks behave exactly as on hardware.
  * interp_step()  - a generated fallback interpreter (same op semantics) for any
                     address the static trace did not discover.
  * the ROM image  - PRG and CHR arrays, so the finished app is self-contained.

Usage: recomp.py <rom.nes> <out_dir> [extra_entry_hex ...]
"""
import sys, os

# ---------------------------------------------------------------- opcode table
# mode: imp acc imm zp zpx zpy abs abx aby ind izx izy rel
OPS = {}
def op(code, mn, mode, cyc, kind=None):
    OPS[code] = (mn, mode, cyc)

grp1 = [('ORA',0x00),('AND',0x20),('EOR',0x40),('ADC',0x60),('LDA',0xA0),('CMP',0xC0),('SBC',0xE0)]
for mn, b in grp1:
    for off, mode, cyc in [(0x09,'imm',2),(0x05,'zp',3),(0x15,'zpx',4),(0x0D,'abs',4),
                           (0x1D,'abx',4),(0x19,'aby',4),(0x01,'izx',6),(0x11,'izy',5)]:
        op(b+off, mn, mode, cyc)
for off, mode, cyc in [(0x05,'zp',3),(0x15,'zpx',4),(0x0D,'abs',4),(0x1D,'abx',5),
                       (0x19,'aby',5),(0x01,'izx',6),(0x11,'izy',6)]:
    op(0x80+off, 'STA', mode, cyc)
for mn, b in [('ASL',0x00),('ROL',0x20),('LSR',0x40),('ROR',0x60)]:
    op(b+0x0A, mn, 'acc', 2)
    for off, mode, cyc in [(0x06,'zp',5),(0x16,'zpx',6),(0x0E,'abs',6),(0x1E,'abx',7)]:
        op(b+off, mn, mode, cyc)
for mn, b in [('DEC',0xC0),('INC',0xE0)]:
    for off, mode, cyc in [(0x06,'zp',5),(0x16,'zpx',6),(0x0E,'abs',6),(0x1E,'abx',7)]:
        op(b+off, mn, mode, cyc)
for code, mn in [(0x90,'BCC'),(0xB0,'BCS'),(0xF0,'BEQ'),(0x30,'BMI'),(0xD0,'BNE'),
                 (0x10,'BPL'),(0x50,'BVC'),(0x70,'BVS')]:
    op(code, mn, 'rel', 2)
op(0x24,'BIT','zp',3); op(0x2C,'BIT','abs',4)
op(0x00,'BRK','imp',7)
for code, mn in [(0x18,'CLC'),(0xD8,'CLD'),(0x58,'CLI'),(0xB8,'CLV'),(0x38,'SEC'),(0xF8,'SED'),
                 (0x78,'SEI'),(0xCA,'DEX'),(0x88,'DEY'),(0xE8,'INX'),(0xC8,'INY'),(0xEA,'NOP'),
                 (0xAA,'TAX'),(0xA8,'TAY'),(0xBA,'TSX'),(0x8A,'TXA'),(0x9A,'TXS'),(0x98,'TYA')]:
    op(code, mn, 'imp', 2)
op(0xE0,'CPX','imm',2); op(0xE4,'CPX','zp',3); op(0xEC,'CPX','abs',4)
op(0xC0,'CPY','imm',2); op(0xC4,'CPY','zp',3); op(0xCC,'CPY','abs',4)
op(0x4C,'JMP','abs',3); op(0x6C,'JMP','ind',5)
op(0x20,'JSR','abs',6)
op(0xA2,'LDX','imm',2); op(0xA6,'LDX','zp',3); op(0xB6,'LDX','zpy',4); op(0xAE,'LDX','abs',4); op(0xBE,'LDX','aby',4)
op(0xA0,'LDY','imm',2); op(0xA4,'LDY','zp',3); op(0xB4,'LDY','zpx',4); op(0xAC,'LDY','abs',4); op(0xBC,'LDY','abx',4)
op(0x48,'PHA','imp',3); op(0x08,'PHP','imp',3); op(0x68,'PLA','imp',4); op(0x28,'PLP','imp',4)
op(0x40,'RTI','imp',6); op(0x60,'RTS','imp',6)
op(0x86,'STX','zp',3); op(0x96,'STX','zpy',4); op(0x8E,'STX','abs',4)
op(0x84,'STY','zp',3); op(0x94,'STY','zpx',4); op(0x8C,'STY','abs',4)

# unofficial NOPs (harmless, occasionally hit by stray decoding)
for c in (0x1A,0x3A,0x5A,0x7A,0xDA,0xFA): op(c,'NOP','imp',2)
for c in (0x80,0x82,0x89,0xC2,0xE2): op(c,'NOP','imm',2)
for c in (0x04,0x44,0x64): op(c,'NOP','zp',3)
for c in (0x14,0x34,0x54,0x74,0xD4,0xF4): op(c,'NOP','zpx',4)
op(0x0C,'NOP','abs',4)
for c in (0x1C,0x3C,0x5C,0x7C,0xDC,0xFC): op(c,'NOP','abx',4)

LEN = {'imp':1,'acc':1,'imm':2,'zp':2,'zpx':2,'zpy':2,'rel':2,'izx':2,'izy':2,
       'abs':3,'abx':3,'aby':3,'ind':3}

READ_OPS  = {'ORA','AND','EOR','ADC','SBC','CMP','CPX','CPY','LDA','LDX','LDY','BIT','NOP'}
WRITE_OPS = {'STA','STX','STY'}
RMW_OPS   = {'ASL','LSR','ROL','ROR','INC','DEC'}
BRANCH = {'BCC':'!(cpu.p&0x01)','BCS':'(cpu.p&0x01)','BNE':'!(cpu.p&0x02)','BEQ':'(cpu.p&0x02)',
          'BPL':'!(cpu.p&0x80)','BMI':'(cpu.p&0x80)','BVC':'!(cpu.p&0x40)','BVS':'(cpu.p&0x40)'}
IMPLIED = {
    'CLC':'cpu.p&=~0x01;','SEC':'cpu.p|=0x01;','CLI':'cpu.p&=~0x04;','SEI':'cpu.p|=0x04;',
    'CLV':'cpu.p&=~0x40;','CLD':'cpu.p&=~0x08;','SED':'cpu.p|=0x08;','NOP':'',
    'DEX':'cpu.x--;NZ(cpu.x);','DEY':'cpu.y--;NZ(cpu.y);','INX':'cpu.x++;NZ(cpu.x);','INY':'cpu.y++;NZ(cpu.y);',
    'TAX':'cpu.x=cpu.a;NZ(cpu.x);','TAY':'cpu.y=cpu.a;NZ(cpu.y);','TXA':'cpu.a=cpu.x;NZ(cpu.a);',
    'TYA':'cpu.a=cpu.y;NZ(cpu.a);','TSX':'cpu.x=cpu.s;NZ(cpu.x);','TXS':'cpu.s=cpu.x;',
    'PHA':'PUSH(cpu.a);','PHP':'PUSH(cpu.p|0x30);','PLA':'cpu.a=PULL();NZ(cpu.a);',
    'PLP':'cpu.p=(PULL()&0xCF)|0x20;',
}
READ_SEM = {
    'LDA':'cpu.a=v;NZ(cpu.a);','LDX':'cpu.x=v;NZ(cpu.x);','LDY':'cpu.y=v;NZ(cpu.y);',
    'ORA':'cpu.a|=v;NZ(cpu.a);','AND':'cpu.a&=v;NZ(cpu.a);','EOR':'cpu.a^=v;NZ(cpu.a);',
    'ADC':'op_adc(v);','SBC':'op_adc(v^0xFF);','CMP':'op_cmp(cpu.a,v);','CPX':'op_cmp(cpu.x,v);',
    'CPY':'op_cmp(cpu.y,v);','BIT':'op_bit(v);','NOP':'(void)v;',
}
RMW_SEM = {'ASL':'op_asl','LSR':'op_lsr','ROL':'op_rol','ROR':'op_ror','INC':'op_inc','DEC':'op_dec'}
WRITE_REG = {'STA':'cpu.a','STX':'cpu.x','STY':'cpu.y'}

def h4(v): return '0x%04X' % (v & 0xFFFF)
def h2(v): return '0x%02X' % (v & 0xFF)

# ---------------------------------------------------------------- address exprs
class Operands:
    """Abstraction over 'operand known at recompile time' vs 'read at runtime'."""
    def __init__(self, const=None):
        self.const = const          # (o1, o16) or None for interpreter
    @property
    def o1(self):  return h2(self.const[0]) if self.const else 'o1'
    @property
    def o16(self): return h4(self.const[1]) if self.const else 'o16'

def rd_const(addr):
    """Read from a compile-time-known absolute address."""
    if addr < 0x2000: return 'ram[%s]' % h4(addr & 0x7FF)
    if addr >= 0x8000: return 'prg_rom[%s]' % h4(addr & 0x7FFF)
    return 'bus_read(%s)' % h4(addr)

def wr_const(addr, val):
    if addr < 0x2000: return 'ram[%s]=%s;' % (h4(addr & 0x7FF), val)
    if addr >= 0x8000: return '/* rom write ignored */ (void)(%s);' % val
    return 'bus_write(%s,%s);' % (h4(addr), val)

def ea(mode, ops, for_read):
    """Return (setup_code, addr_expr, const_addr_or_None) for memory modes."""
    c = ops.const
    if mode == 'zp':
        return '', ops.o1, (c[0] if c else None), 'zp'
    if mode == 'zpx':
        return '', '(uint8_t)(%s + cpu.x)' % ops.o1, None, 'zp'
    if mode == 'zpy':
        return '', '(uint8_t)(%s + cpu.y)' % ops.o1, None, 'zp'
    if mode == 'abs':
        return '', ops.o16, (c[1] if c else None), 'abs'
    if mode in ('abx', 'aby'):
        r = 'cpu.x' if mode == 'abx' else 'cpu.y'
        setup = 'uint16_t ea=(uint16_t)(%s + %s);' % (ops.o16, r)
        if for_read:
            setup += 'if(((%s & 0xFF) + %s)>0xFF)cpu_cyc++;' % (ops.o16, r)
        return setup, 'ea', None, 'abs'
    if mode == 'izx':
        setup = 'uint8_t zp=(uint8_t)(%s + cpu.x);uint16_t ea=ram[zp]|(ram[(uint8_t)(zp+1)]<<8);' % ops.o1
        return setup, 'ea', None, 'abs'
    if mode == 'izy':
        setup = ('uint16_t base=ram[%s]|(ram[(uint8_t)(%s + 1)]<<8);uint16_t ea=(uint16_t)(base+cpu.y);'
                 % (ops.o1, ops.o1))
        if for_read:
            setup += 'if(((base&0xFF)+cpu.y)>0xFF)cpu_cyc++;'
        return setup, 'ea', None, 'abs'
    raise ValueError(mode)

def read_expr(mode, ops):
    if mode == 'imm':
        return '', ops.o1
    setup, a, const, kind = ea(mode, ops, True)
    if kind == 'zp':
        return setup, 'ram[%s]' % (h2(const) if const is not None else a)
    if const is not None:
        return setup, rd_const(const)
    return setup, 'RD(%s)' % a

def write_stmt(mode, ops, val):
    setup, a, const, kind = ea(mode, ops, False)
    if kind == 'zp':
        return setup + 'ram[%s]=%s;' % (h2(const) if const is not None else a, val)
    if const is not None:
        return setup + wr_const(const, val)
    return setup + 'WR(%s,%s);' % (a, val)

def rmw_stmt(mode, ops, fn):
    if mode == 'acc':
        return 'cpu.a=%s(cpu.a);' % fn
    setup, a, const, kind = ea(mode, ops, False)
    if kind == 'zp':
        loc = 'ram[%s]' % (h2(const) if const is not None else a)
        return setup + '%s=%s(%s);' % (loc, fn, loc)
    if const is not None:
        return setup + '{uint8_t t=%s;%s}' % (rd_const(const), wr_const(const, '%s(t)' % fn))
    return setup + '{uint8_t t=RD(%s);WR(%s,t);WR(%s,%s(t));}' % (a, a, a, fn)

def body(mn, mode, ops):
    """Semantics for non-control-flow ops."""
    if mode in ('imp',) and mn in IMPLIED:
        return IMPLIED[mn]
    if mn in READ_OPS:
        s, v = read_expr(mode, ops)
        return '{%suint8_t v=%s;%s}' % (s, v, READ_SEM[mn])
    if mn in WRITE_OPS:
        return '{%s}' % write_stmt(mode, ops, WRITE_REG[mn])
    if mn in RMW_OPS:
        return '{%s}' % rmw_stmt(mode, ops, RMW_SEM[mn])
    raise ValueError(mn + ' ' + mode)

# ---------------------------------------------------------------- ROM / trace
def load(path):
    d = open(path, 'rb').read()
    if d[:4] != b'NES\x1a':
        sys.exit('not an iNES file')
    nprg, nchr = d[4], d[5]
    mapper = (d[6] >> 4) | (d[7] & 0xF0)
    if mapper != 0:
        sys.exit('only mapper 0 (NROM) is supported, got %d' % mapper)
    off = 16 + (512 if d[6] & 4 else 0)
    prg = d[off: off + nprg * 16384]
    chr_ = d[off + nprg * 16384: off + nprg * 16384 + nchr * 8192]
    prg32 = (prg * 2)[:32768] if nprg == 1 else prg[:32768]
    mirror_vertical = d[6] & 1
    return prg32, chr_, mirror_vertical

def trace_once(prg, entries, dispatchers):
    def rb(a): return prg[a & 0x7FFF]
    seen = {}            # addr -> (opcode, mn, mode, cyc, len)
    jump_targets = set()
    work = [e for e in entries if e >= 0x8000]
    while work:
        a = work.pop()
        while a >= 0x8000 and a <= 0xFFFF and a not in seen:
            opc = rb(a)
            info = OPS.get(opc)
            if info is None:
                seen[a] = (opc, None, None, 0, 1)
                break
            mn, mode, cyc = info
            ln = LEN[mode]
            if a + ln - 1 > 0xFFFF:
                break
            seen[a] = (opc, mn, mode, cyc, ln)
            nxt = a + ln
            if mode == 'rel':
                off = rb(a + 1); off = off - 256 if off >= 128 else off
                t = (nxt + off) & 0xFFFF
                jump_targets.add(t); work.append(t)
            if mn in ('JMP', 'JSR') and mode == 'abs':
                t = rb(a + 1) | (rb(a + 2) << 8)
                jump_targets.add(t); work.append(t)
                if mn == 'JMP':
                    break
                if t in dispatchers:      # bytes after this JSR are a pointer table, not code
                    break
            if mn in ('RTS', 'RTI', 'BRK') or (mn == 'JMP'):
                break
            a = nxt
    return seen, jump_targets

def trace(prg, entries):
    def rb(a): return prg[a & 0x7FFF]
    dispatchers = set()
    entries = list(entries)
    for _ in range(16):
        seen, jt = trace_once(prg, entries, dispatchers)
        # detect dispatcher subroutines
        calls = {}
        for a, v in seen.items():
            if v[1] == 'JSR':
                calls.setdefault(rb(a + 1) | (rb(a + 2) << 8), []).append(a)
        new_disp = set()
        for t in calls:
            x, pla = t, 0
            for _i in range(24):
                v = seen.get(x)
                if not v or v[1] is None:
                    break
                if v[1] == 'PLA':
                    pla += 1
                if v[1] == 'JMP' and v[2] == 'ind':
                    if pla >= 2:
                        new_disp.add(t)
                    break
                if v[1] in ('RTS', 'RTI', 'JMP', 'BRK'):
                    break
                x += v[4]
        # read the inline pointer tables after each call site
        added = []
        for t in new_disp | dispatchers:
            for site in calls.get(t, []):
                pos = site + 3
                for _k in range(128):
                    if pos + 1 > 0xFFFF:
                        break
                    w = rb(pos) | (rb(pos + 1) << 8)
                    if w < 0x8000 or (pos in seen and pos != site + 3 and pos in jt):
                        break
                    if w not in entries:
                        added.append(w)
                    pos += 2
        if not (new_disp - dispatchers) and not added:
            return seen, jt
        dispatchers |= new_disp
        entries += added
    return seen, jt

# ---------------------------------------------------------------- emitters
CHUNK = 160   # instructions per generated C function (keeps clang compile times low)

def emit_recomp(prg, seen, jump_targets):
    """Emit recompiled code split into region functions plus a top-level dispatcher."""
    out = []
    w = out.append
    addrs = sorted(seen)
    chunks = [addrs[i:i + CHUNK] for i in range(0, len(addrs), CHUNK)]
    chunk_of = {}
    for ci, ch in enumerate(chunks):
        for a in ch:
            chunk_of[a] = ci
    for ci, ch in enumerate(chunks):
        mine = set(ch)
        def goto(t):
            if t in mine:
                return 'goto L_%04X;' % t
            return 'cpu.pc=%s;return;' % h4(t)
        w('static void rc_%d(void) {' % ci)
        w('dispatch:')
        w('  if (g_exit) return;')
        w('  switch (cpu.pc) {')
        for i, a in enumerate(ch):
            opc, mn, mode, cyc, ln = seen[a]
            nxt = a + ln
            next_emitted = ch[i + 1] if i + 1 < len(ch) else None
            w('  case %s: L_%04X: SYNC(%s)' % (h4(a), a, h4(a)))
            if mn is None:
                w('    cpu.pc=%s; interp_step(); goto dispatch; /* undecoded $%02X */' % (h4(a), opc))
                continue
            o1 = prg[(a + 1) & 0x7FFF]
            o16 = o1 | (prg[(a + 2) & 0x7FFF] << 8)
            ops = Operands((o1, o16))
            cy = 'cpu_cyc+=%d;' % cyc
            fall = True
            if mode == 'rel':
                off = o1 - 256 if o1 >= 128 else o1
                t = (nxt + off) & 0xFFFF
                extra = 2 if (t & 0xFF00) != (nxt & 0xFF00) else 1
                w('    %s if(%s){cpu_cyc+=%d;%s}' % (cy, BRANCH[mn], extra, goto(t)))
            elif mn == 'JMP' and mode == 'abs':
                w('    %s %s' % (cy, goto(o16))); fall = False
            elif mn == 'JMP':
                w('    %s cpu.pc=prg_or_bus_rd16_bug(%s); goto dispatch;' % (cy, h4(o16))); fall = False
            elif mn == 'JSR':
                w('    %s PUSH16(%s); %s' % (cy, h4(a + 2), goto(o16))); fall = False
            elif mn == 'RTS':
                w('    %s cpu.pc=(uint16_t)(PULL16()+1); goto dispatch;' % cy); fall = False
            elif mn == 'RTI':
                w('    %s cpu.p=(PULL()&0xCF)|0x20; cpu.pc=PULL16(); goto dispatch;' % cy); fall = False
            elif mn == 'BRK':
                w('    %s PUSH16(%s); PUSH(cpu.p|0x30); cpu.p|=0x04; cpu.pc=prg_rom[0x7FFE]|(prg_rom[0x7FFF]<<8); goto dispatch;'
                  % (cy, h4(a + 2))); fall = False
            else:
                w('    %s %s' % (cy, body(mn, mode, ops)))
            if fall and next_emitted != nxt:
                w('    ' + goto(nxt))
        w('  default: return;')
        w('  }')
        w('}')
        w('')
    w('typedef void (*rc_fn)(void);')
    w('static const rc_fn rc_table[%d] = { %s };' % (len(chunks), ', '.join('rc_%d' % i for i in range(len(chunks)))))
    w('static const uint16_t rc_addr[%d] = {' % len(addrs))
    for i in range(0, len(addrs), 16):
        w('  ' + ','.join(h4(a) for a in addrs[i:i + 16]) + ',')
    w('};')
    w('static int16_t rc_chunk_of[0x8000];')
    w('static int rc_ready;')
    w('void recomp_run(void) {')
    w('  if (!rc_ready) {')
    w('    for (int i = 0; i < 0x8000; i++) rc_chunk_of[i] = -1;')
    w('    for (int i = 0; i < %d; i++) rc_chunk_of[rc_addr[i] & 0x7FFF] = (int16_t)(i / %d);' % (len(addrs), CHUNK))
    w('    rc_ready = 1;')
    w('  }')
    w('  for (;;) {')
    w('    if (g_exit) { g_exit = 0; return; }')
    w('    int c = cpu.pc >= 0x8000 ? rc_chunk_of[cpu.pc & 0x7FFF] : -1;')
    w('    if (c >= 0) { rc_table[c](); continue; }')
    w('    if (cpu_cyc >= g_next_event && nes_sync(cpu.pc)) continue;')
    w('    interp_step();')
    w('  }')
    w('}')
    return '\n'.join(out)

def emit_interp():
    out = []
    w = out.append
    w('void interp_step(void) {')
    w('  uint16_t pc = cpu.pc;')
    w('  uint8_t opc = RD(pc);')
    w('  uint8_t o1 = RD((uint16_t)(pc+1));')
    w('  uint16_t o16 = o1 | (RD((uint16_t)(pc+2))<<8);')
    w('  (void)o16;')
    w('  interp_note(pc);')
    w('  switch (opc) {')
    ops = Operands(None)
    for opc in range(256):
        info = OPS.get(opc)
        if info is None:
            continue
        mn, mode, cyc = info
        ln = LEN[mode]
        cy = 'cpu_cyc+=%d;' % cyc
        nx = '(uint16_t)(pc+%d)' % ln
        if mode == 'rel':
            code = ('%s {uint16_t n=%s; if(%s){uint16_t t=(uint16_t)(n+(int8_t)o1); cpu_cyc+=((t^n)&0xFF00)?2:1; cpu.pc=t;} else cpu.pc=n;}'
                    % (cy, nx, BRANCH[mn]))
        elif mn == 'JMP' and mode == 'abs':
            code = '%s cpu.pc=o16;' % cy
        elif mn == 'JMP':
            code = '%s cpu.pc=prg_or_bus_rd16_bug(o16);' % cy
        elif mn == 'JSR':
            code = '%s PUSH16((uint16_t)(pc+2)); cpu.pc=o16;' % cy
        elif mn == 'RTS':
            code = '%s cpu.pc=(uint16_t)(PULL16()+1);' % cy
        elif mn == 'RTI':
            code = '%s cpu.p=(PULL()&0xCF)|0x20; cpu.pc=PULL16();' % cy
        elif mn == 'BRK':
            code = '%s PUSH16((uint16_t)(pc+2)); PUSH(cpu.p|0x30); cpu.p|=0x04; cpu.pc=RD(0xFFFE)|(RD(0xFFFF)<<8);' % cy
        else:
            code = '%s cpu.pc=%s; %s' % (cy, nx, body(mn, mode, ops))
        w('  case 0x%02X: %s break; /* %s %s */' % (opc, code, mn, mode))
    w('  default: cpu_cyc+=2; cpu.pc=(uint16_t)(pc+1); interp_bad_opcode(pc, opc); break;')
    w('  }')
    w('}')
    return '\n'.join(out)

def c_array(name, data, typ='const uint8_t'):
    lines = ['%s %s[%d] = {' % (typ, name, len(data))]
    for i in range(0, len(data), 24):
        lines.append('  ' + ','.join(str(b) for b in data[i:i + 24]) + ',')
    lines.append('};')
    return '\n'.join(lines)

def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    rom, outdir = sys.argv[1], sys.argv[2]
    extra = [int(x, 16) for x in sys.argv[3:]]
    entries_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'entries.txt')
    if os.path.exists(entries_file):
        for line in open(entries_file):
            line = line.split('#')[0].strip()
            if line:
                extra.append(int(line, 16))
    prg, chr_, vmirror = load(rom)
    vec = lambda a: prg[a & 0x7FFF] | (prg[(a + 1) & 0x7FFF] << 8)
    entries = [vec(0xFFFA), vec(0xFFFC), vec(0xFFFE)] + extra
    seen, jt = trace(prg, entries)
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, 'game_recomp.c'), 'w') as f:
        f.write('/* AUTO-GENERATED by recomp.py from your ROM. Do not edit. */\n')
        f.write('#include "../runtime/nes.h"\n#include "../runtime/cpu_ops.h"\n\n')
        f.write(emit_recomp(prg, seen, jt))
        f.write('\n\n')
        f.write(emit_interp())
        f.write('\n')
    with open(os.path.join(outdir, 'game_rom.c'), 'w') as f:
        f.write('/* AUTO-GENERATED by recomp.py from your ROM. Do not edit. */\n#include <stdint.h>\n')
        f.write(c_array('rom_prg', prg) + '\n')
        f.write(c_array('rom_chr', chr_ if chr_ else bytes(8192)) + '\n')
        f.write('const int rom_chr_is_ram = %d;\n' % (0 if chr_ else 1))
        f.write('const int rom_mirror_vertical = %d;\n' % vmirror)
    decoded = sum(1 for v in seen.values() if v[1])
    print('recomp: %d instructions recompiled from %d entry points' % (decoded, len(entries)))

if __name__ == '__main__':
    main()
