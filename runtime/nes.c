/* System bus, interrupts, controllers and frame stepping. */
#include <string.h>
#include <stdio.h>
#include "nes.h"
#include "cpu_ops.h"

CPU6502 cpu;
uint64_t cpu_cyc;
uint64_t g_next_event;
int g_exit;
uint8_t ram[0x800];
static uint8_t wram[0x2000];
uint8_t interp_seen[65536];

static uint8_t pad_state[2], pad_shift[2], pad_strobe;

void interp_note(uint16_t pc) { interp_seen[pc] = 1; }
void interp_bad_opcode(uint16_t pc, uint8_t opc) {
    static int reported;
    if (reported++ < 8) fprintf(stderr, "recomp: unknown opcode $%02X at $%04X\n", opc, pc);
}

uint8_t bus_read(uint16_t a) {
    if (a < 0x2000) return ram[a & 0x7FF];
    if (a < 0x4000) return ppu_read(a & 7);
    if (a == 0x4015) return apu_read_status();
    if (a == 0x4016 || a == 0x4017) {
        int p = a & 1;
        uint8_t v;
        if (pad_strobe) v = pad_state[p] & 1;
        else { v = pad_shift[p] & 1; pad_shift[p] = (uint8_t)((pad_shift[p] >> 1) | 0x80); }
        return (uint8_t)(0x40 | v);
    }
    if (a >= 0x6000 && a < 0x8000) return wram[a & 0x1FFF];
    if (a >= 0x8000) return prg_rom[a & 0x7FFF];
    return 0;
}

void bus_write(uint16_t a, uint8_t v) {
    if (a < 0x2000) { ram[a & 0x7FF] = v; return; }
    if (a < 0x4000) { ppu_write(a & 7, v); return; }
    if (a == 0x4014) {
        uint8_t page[256];
        for (int i = 0; i < 256; i++) page[i] = RD((uint16_t)((v << 8) | i));
        ppu_run_to(cpu_cyc);
        ppu_oam_dma(page);
        cpu_cyc += 513 + (cpu_cyc & 1);
        return;
    }
    if (a == 0x4016) {
        pad_strobe = v & 1;
        if (pad_strobe) { pad_shift[0] = pad_state[0]; pad_shift[1] = pad_state[1]; }
        return;
    }
    if (a >= 0x4000 && a <= 0x4017) { apu_write(a, v); return; }
    if (a >= 0x6000 && a < 0x8000) { wram[a & 0x1FFF] = v; return; }
}

static void update_next_event(void) {
    g_next_event = ppu_next_vblank_cpu();
    if (apu_irq() && !(cpu.p & 0x04)) g_next_event = cpu_cyc;
}

int nes_sync(uint16_t pc) {
    int redirected = 0;
    ppu_run_to(cpu_cyc);
    if (ppu_nmi_pending) {
        ppu_nmi_pending = 0;
        PUSH16(pc); PUSH((cpu.p | 0x20) & ~0x10); cpu.p |= 0x04;
        pc = (uint16_t)(RD(0xFFFA) | (RD(0xFFFB) << 8));
        cpu_cyc += 7;
        redirected = 1;
    } else if (apu_irq() && !(cpu.p & 0x04)) {
        apu_run_to(cpu_cyc);
        PUSH16(pc); PUSH((cpu.p | 0x20) & ~0x10); cpu.p |= 0x04;
        pc = (uint16_t)(RD(0xFFFE) | (RD(0xFFFF) << 8));
        cpu_cyc += 7;
        redirected = 1;
    }
    if (ppu_frame_done) { ppu_frame_done = 0; g_exit = 1; }
    cpu.pc = pc;
    update_next_event();
    return redirected || g_exit;
}

void nes_set_buttons(int pad, uint8_t b) {
    /* Never report opposing directions at once - the game didn't expect it. */
    if ((b & 0x30) == 0x30) b &= (uint8_t)~0x30;
    if ((b & 0xC0) == 0xC0) b &= (uint8_t)~0xC0;
    pad_state[pad & 1] = b;
}

void nes_reset(void) {
    cpu.a = cpu.x = cpu.y = 0;
    cpu.s = 0xFD; cpu.p = 0x24;
    cpu.pc = (uint16_t)(RD(0xFFFC) | (RD(0xFFFD) << 8));
    g_exit = 0;
    ppu_reset();
    apu_reset();
    update_next_event();
}

void nes_init(void) {
    memset(ram, 0, sizeof ram);
    cpu_cyc = 0;
    nes_reset();
}

void nes_run_frame(void) {
    recomp_run();
    apu_run_to(cpu_cyc);
}

const uint32_t *nes_framebuffer(void) { return ppu_fb; }
