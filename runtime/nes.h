/* NES runtime shared by the recompiled game code and the platform layer. */
#ifndef NES_RUNTIME_H
#define NES_RUNTIME_H
#include <stdint.h>
#include <stddef.h>

typedef struct { uint8_t a, x, y, s, p; uint16_t pc; } CPU6502;

extern CPU6502 cpu;
extern uint64_t cpu_cyc;          /* CPU cycles since power-on            */
extern uint64_t g_next_event;     /* cpu_cyc at which nes_sync must run   */
extern int g_exit;                /* set when a frame is complete         */
extern uint8_t ram[0x800];

/* ROM image (generated from the user's ROM by recomp.py) */
extern const uint8_t rom_prg[32768];
extern const uint8_t rom_chr[8192];
extern const int rom_chr_is_ram;
extern const int rom_mirror_vertical;
#define prg_rom rom_prg

uint8_t bus_read(uint16_t a);
void bus_write(uint16_t a, uint8_t v);

static inline uint8_t RD(uint16_t a) {
    if (a < 0x2000) return ram[a & 0x7FF];
    if (a >= 0x8000) return prg_rom[a & 0x7FFF];
    return bus_read(a);
}
static inline void WR(uint16_t a, uint8_t v) {
    if (a < 0x2000) ram[a & 0x7FF] = v;
    else bus_write(a, v);
}
static inline uint16_t prg_or_bus_rd16_bug(uint16_t a) {
    /* JMP ($xxFF) wraps within the page on a real 6502 */
    return RD(a) | (RD((uint16_t)((a & 0xFF00) | ((a + 1) & 0xFF))) << 8);
}

int  nes_sync(uint16_t pc);      /* returns 1 if control flow was redirected/exit */
void interp_step(void);
void recomp_run(void);
void interp_note(uint16_t pc);
void interp_bad_opcode(uint16_t pc, uint8_t opc);

/* ---- machine API used by the platform layer ---- */
#define NES_W 256
#define NES_H 240
void nes_init(void);
void nes_reset(void);
void nes_run_frame(void);                       /* runs until the next vblank   */
const uint32_t *nes_framebuffer(void);          /* 256x240 0xAARRGGBB           */
void nes_set_buttons(int pad, uint8_t buttons); /* bit0=A 1=B 2=Sel 3=Start 4=U 5=D 6=L 7=R */
size_t nes_audio_read(int16_t *dst, size_t max);/* drain generated samples       */
void nes_audio_set_rate(double hz);
size_t nes_audio_available(void);
extern uint8_t interp_seen[65536];              /* addresses run by interpreter */

/* PPU / APU internals */
void ppu_reset(void);
void ppu_run_to(uint64_t cpu_cycle);
uint8_t ppu_read(uint16_t reg);
void ppu_write(uint16_t reg, uint8_t v);
void ppu_oam_dma(const uint8_t *page);
uint64_t ppu_next_vblank_cpu(void);
extern int ppu_nmi_pending;
extern int ppu_frame_done;
extern uint32_t ppu_fb[NES_W * NES_H];

void apu_reset(void);
void apu_run_to(uint64_t cpu_cycle);
void apu_write(uint16_t reg, uint8_t v);
uint8_t apu_read_status(void);
int apu_irq(void);
#endif
