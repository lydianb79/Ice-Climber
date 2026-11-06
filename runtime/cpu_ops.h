/* 6502 helper semantics used by generated code (recompiled + interpreter). */
#ifndef CPU_OPS_H
#define CPU_OPS_H
#include "nes.h"

#define NZ(v) (cpu.p = (uint8_t)((cpu.p & ~0x82) | ((v) & 0x80) | (((uint8_t)(v)) ? 0 : 0x02)))
#define PUSH(v) (ram[0x100 | cpu.s--] = (uint8_t)(v))
#define PULL() (ram[0x100 | ++cpu.s])
#define PUSH16(v) do { uint16_t _v = (v); PUSH(_v >> 8); PUSH(_v & 0xFF); } while (0)
static inline uint16_t PULL16(void) { uint16_t lo = PULL(); uint16_t hi = PULL(); return lo | (hi << 8); }

/* Interrupts (NMI/IRQ) are taken at instruction boundaries via SYNC. */
#define SYNC(addr) if (cpu_cyc >= g_next_event) { if (nes_sync(addr)) goto dispatch; }

static inline void op_adc(uint8_t v) {
    unsigned s = cpu.a + v + (cpu.p & 1);
    uint8_t r = (uint8_t)s;
    cpu.p = (uint8_t)((cpu.p & ~0x41) | (s > 0xFF ? 1 : 0) | (((cpu.a ^ r) & (v ^ r) & 0x80) ? 0x40 : 0));
    cpu.a = r; NZ(r);
}
static inline void op_cmp(uint8_t r, uint8_t v) {
    uint8_t t = (uint8_t)(r - v);
    cpu.p = (uint8_t)((cpu.p & ~1) | (r >= v ? 1 : 0)); NZ(t);
}
static inline void op_bit(uint8_t v) {
    cpu.p = (uint8_t)((cpu.p & ~0xC2) | (v & 0xC0) | ((cpu.a & v) ? 0 : 0x02));
}
static inline uint8_t op_asl(uint8_t v) { cpu.p = (uint8_t)((cpu.p & ~1) | (v >> 7)); v <<= 1; NZ(v); return v; }
static inline uint8_t op_lsr(uint8_t v) { cpu.p = (uint8_t)((cpu.p & ~1) | (v & 1)); v >>= 1; NZ(v); return v; }
static inline uint8_t op_rol(uint8_t v) { uint8_t c = cpu.p & 1; cpu.p = (uint8_t)((cpu.p & ~1) | (v >> 7)); v = (uint8_t)((v << 1) | c); NZ(v); return v; }
static inline uint8_t op_ror(uint8_t v) { uint8_t c = cpu.p & 1; cpu.p = (uint8_t)((cpu.p & ~1) | (v & 1)); v = (uint8_t)((v >> 1) | (c << 7)); NZ(v); return v; }
static inline uint8_t op_inc(uint8_t v) { v++; NZ(v); return v; }
static inline uint8_t op_dec(uint8_t v) { v--; NZ(v); return v; }
#endif
