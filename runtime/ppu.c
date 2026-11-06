/* 2C02 PPU: scanline renderer with dot-accurate event timing for vblank/NMI
 * and sprite-0 hit, which is what NROM games rely on. */
#include <string.h>
#include "nes.h"

uint32_t ppu_fb[NES_W * NES_H];
int ppu_nmi_pending;
int ppu_frame_done;

static uint8_t ctrl, mask, status, oamaddr, readbuf, finex, wlatch;
static uint16_t v, t;
static uint8_t oam[256];
static uint8_t vram[0x800];
static uint8_t chr_ram[0x2000];
static uint8_t pal[32];
static uint64_t dots;        /* absolute PPU dot count                       */
static uint64_t frame_start; /* absolute dot where the current frame began   */
static int odd_frame;
static uint64_t s0_time;     /* absolute dot at which sprite-0 hit triggers  */
static int last_event;       /* last processed event index in current frame  */

static const uint32_t nes_palette[64] = {
    0x7C7C7C,0x0000FC,0x0000BC,0x4428BC,0x940084,0xA80020,0xA81000,0x881400,
    0x503000,0x007800,0x006800,0x005800,0x004058,0x000000,0x000000,0x000000,
    0xBCBCBC,0x0078F8,0x0058F8,0x6844FC,0xD800CC,0xE40058,0xF83800,0xE45C10,
    0xAC7C00,0x00B800,0x00A800,0x00A844,0x008888,0x000000,0x000000,0x000000,
    0xF8F8F8,0x3CBCFC,0x6888FC,0x9878F8,0xF878F8,0xF85898,0xF87858,0xFCA044,
    0xF8B800,0xB8F818,0x58D854,0x58F898,0x00E8D8,0x787878,0x000000,0x000000,
    0xFCFCFC,0xA4E4FC,0xB8B8F8,0xD8B8F8,0xF8B8F8,0xF8A4C0,0xF0D0B0,0xFCE0A8,
    0xF8D878,0xD8F878,0xB8F8B8,0xB8F8D8,0x00FCFC,0xF8D8F8,0x000000,0x000000,
};

#define RENDERING (mask & 0x18)

static inline const uint8_t *chr_mem(void) { return rom_chr_is_ram ? chr_ram : rom_chr; }

static inline uint16_t nt_index(uint16_t a) {
    a &= 0x0FFF;
    if (rom_mirror_vertical) return a & 0x07FF;
    return (uint16_t)(((a >> 1) & 0x400) | (a & 0x3FF));
}
static inline uint8_t pal_idx(uint16_t a) {
    a &= 0x1F;
    if ((a & 0x13) == 0x10) a &= 0x0F;
    return (uint8_t)a;
}
static uint8_t vram_read(uint16_t a) {
    a &= 0x3FFF;
    if (a < 0x2000) return chr_mem()[a];
    if (a < 0x3F00) return vram[nt_index(a)];
    return pal[pal_idx(a)];
}
static void vram_write(uint16_t a, uint8_t val) {
    a &= 0x3FFF;
    if (a < 0x2000) { if (rom_chr_is_ram) chr_ram[a] = val; return; }
    if (a < 0x3F00) { vram[nt_index(a)] = val; return; }
    pal[pal_idx(a)] = val & 0x3F;
}

static void inc_x(void) {
    if ((v & 0x1F) == 31) { v &= (uint16_t)~0x1F; v ^= 0x400; } else v++;
}
static void inc_y(void) {
    if ((v & 0x7000) != 0x7000) { v += 0x1000; return; }
    v &= (uint16_t)~0x7000;
    int y = (v & 0x3E0) >> 5;
    if (y == 29) { y = 0; v ^= 0x800; }
    else if (y == 31) y = 0;
    else y++;
    v = (uint16_t)((v & ~0x3E0) | (y << 5));
}

/* Render one visible scanline from the current v / finex. */
static void render_line(int sl, uint64_t line_start) {
    uint8_t bgpix[256 + 16];
    uint8_t line[256];
    const uint8_t *chr = chr_mem();
    memset(bgpix, 0, sizeof bgpix);

    if (mask & 0x08) {
        uint16_t vv = v;
        uint16_t bgtab = (ctrl & 0x10) ? 0x1000 : 0;
        for (int i = 0; i < 33; i++) {
            uint8_t tile = vram[nt_index(0x2000 | (vv & 0x0FFF))];
            uint8_t at = vram[nt_index((uint16_t)(0x23C0 | (vv & 0x0C00) | ((vv >> 4) & 0x38) | ((vv >> 2) & 0x07)))];
            int shift = ((vv >> 4) & 4) | (vv & 2);
            uint8_t palhi = (uint8_t)(((at >> shift) & 3) << 2);
            uint16_t pa = (uint16_t)(bgtab + tile * 16 + ((vv >> 12) & 7));
            uint8_t lo = chr[pa], hi = chr[pa + 8];
            for (int b = 0; b < 8; b++) {
                int px = i * 8 + b - finex;
                if (px < 0 || px >= 256) continue;
                uint8_t c = (uint8_t)(((lo >> (7 - b)) & 1) | (((hi >> (7 - b)) & 1) << 1));
                bgpix[px] = c ? (uint8_t)(palhi | c) : 0;
            }
            if ((vv & 0x1F) == 31) { vv &= (uint16_t)~0x1F; vv ^= 0x400; } else vv++;
        }
        if (!(mask & 0x02)) memset(bgpix, 0, 8);
    }

    /* sprites */
    uint8_t sppix[256], sppri[256], sp0[256];
    memset(sppix, 0, sizeof sppix);
    memset(sp0, 0, sizeof sp0);
    if (mask & 0x10) {
        int h = (ctrl & 0x20) ? 16 : 8;
        int count = 0;
        for (int i = 0; i < 64; i++) {
            int y = oam[i * 4];
            int row = sl - (y + 1);
            if (row < 0 || row >= h) continue;
            if (++count > 8) { status |= 0x20; break; }
            uint8_t tile = oam[i * 4 + 1], attr = oam[i * 4 + 2], x = oam[i * 4 + 3];
            if (attr & 0x80) row = h - 1 - row;
            uint16_t pa;
            if (h == 16) {
                pa = (uint16_t)(((tile & 1) ? 0x1000 : 0) + (tile & 0xFE) * 16);
                if (row >= 8) { pa += 16; row -= 8; }
            } else {
                pa = (uint16_t)(((ctrl & 0x08) ? 0x1000 : 0) + tile * 16);
            }
            pa += (uint16_t)row;
            uint8_t lo = chr[pa], hi = chr[pa + 8];
            for (int b = 0; b < 8; b++) {
                int px = x + b;
                if (px > 255) break;
                int bit = (attr & 0x40) ? b : 7 - b;
                uint8_t c = (uint8_t)(((lo >> bit) & 1) | (((hi >> bit) & 1) << 1));
                if (!c) continue;
                if (px < 8 && !(mask & 0x04)) continue;
                if (i == 0) sp0[px] = 1;
                if (sppix[px]) continue;
                sppix[px] = (uint8_t)(0x10 | ((attr & 3) << 2) | c);
                sppri[px] = attr & 0x20;
            }
        }
    }

    int hit_x = -1;
    for (int x = 0; x < 256; x++) {
        uint8_t bg = bgpix[x], sp = sppix[x], c;
        if (sp0[x] && bg && hit_x < 0 && x != 255 && (mask & 0x18) == 0x18) hit_x = x;
        if (sp && (!bg || !sppri[x])) c = sp;
        else c = bg;
        line[x] = pal[pal_idx(c)];
    }
    if (hit_x >= 0 && !(status & 0x40) && s0_time == 0)
        s0_time = line_start + (uint64_t)hit_x + 2;

    uint32_t *dst = &ppu_fb[sl * NES_W];
    uint8_t grey = (mask & 0x01) ? 0x30 : 0x3F;
    for (int x = 0; x < 256; x++) dst[x] = 0xFF000000u | nes_palette[line[x] & grey];
}

static void blank_line(int sl) {
    uint32_t c = 0xFF000000u | nes_palette[pal[0] & 0x3F];
    uint32_t *dst = &ppu_fb[sl * NES_W];
    for (int x = 0; x < 256; x++) dst[x] = c;
}

/* Per-frame event schedule (in dots relative to frame start):
 *   visible line L: L*341+1 render,  L*341+257 incY + copy horizontal
 *   241*341+1: vblank start / NMI
 *   261*341+1: clear flags; 261*341+257 incY/hori; 261*341+280 copy vertical
 *   frame end: 262*341 (one dot shorter on odd frames while rendering)   */
#define EV_COUNT (240 * 2 + 1 + 4)
static uint32_t ev_pos(int i) {
    if (i < 480) return (uint32_t)((i >> 1) * 341 + ((i & 1) ? 257 : 1));
    switch (i - 480) {
    case 0: return 241 * 341 + 1;
    case 1: return 261 * 341 + 1;
    case 2: return 261 * 341 + 257;
    case 3: return 261 * 341 + 280;
    default: return 262 * 341 - ((odd_frame && RENDERING) ? 1 : 0);
    }
}

static void do_event(int i) {
    if (i < 480) {
        int sl = i >> 1;
        if (!(i & 1)) {
            if (RENDERING) render_line(sl, frame_start + (uint64_t)sl * 341);
            else blank_line(sl);
        } else if (RENDERING) {
            inc_y();
            v = (uint16_t)((v & ~0x041F) | (t & 0x041F));
        }
        return;
    }
    switch (i - 480) {
    case 0:
        status |= 0x80;
        if (ctrl & 0x80) ppu_nmi_pending = 1;
        ppu_frame_done = 1;
        break;
    case 1:
        status &= (uint8_t)~0xE0;
        s0_time = 0;
        break;
    case 2:
        if (RENDERING) { inc_y(); v = (uint16_t)((v & ~0x041F) | (t & 0x041F)); }
        break;
    case 3:
        if (RENDERING) v = (uint16_t)((v & ~0x7BE0) | (t & 0x7BE0));
        break;
    case 4:
        frame_start += ev_pos(i);
        odd_frame ^= 1;
        last_event = -1;
        break;
    }
}

void ppu_run_to(uint64_t cpu_cycle) {
    uint64_t target = cpu_cycle * 3;
    while (dots < target) {
        int next = last_event + 1;
        uint64_t when = frame_start + ev_pos(next);
        if (s0_time && s0_time > dots && s0_time <= target && s0_time < when) {
            dots = s0_time;
            status |= 0x40;
            continue;
        }
        if (when > target) { dots = target; break; }
        dots = when;
        last_event = next;
        do_event(next);
    }
    if (s0_time && s0_time <= dots) status |= 0x40;
}

uint64_t ppu_next_vblank_cpu(void) {
    uint64_t vb = frame_start + 241 * 341 + 1;
    if (last_event >= 480) vb += 262 * 341;  /* already past this frame's vblank */
    return (vb + 2) / 3;
}

uint8_t ppu_read(uint16_t reg) {
    ppu_run_to(cpu_cyc);
    switch (reg) {
    case 2: {
        uint8_t r = (uint8_t)((status & 0xE0) | (readbuf & 0x1F));
        status &= 0x7F;
        wlatch = 0;
        return r;
    }
    case 4: return oam[oamaddr];
    case 7: {
        uint16_t a = v & 0x3FFF;
        uint8_t r;
        if (a >= 0x3F00) { r = vram_read(a); readbuf = vram_read((uint16_t)(a - 0x1000)); }
        else { r = readbuf; readbuf = vram_read(a); }
        v = (uint16_t)(v + ((ctrl & 0x04) ? 32 : 1));
        return r;
    }
    }
    return readbuf;
}

void ppu_write(uint16_t reg, uint8_t val) {
    ppu_run_to(cpu_cyc);
    switch (reg) {
    case 0: {
        uint8_t old = ctrl;
        ctrl = val;
        t = (uint16_t)((t & ~0x0C00) | ((val & 3) << 10));
        if (!(old & 0x80) && (val & 0x80) && (status & 0x80)) {
            ppu_nmi_pending = 1;
            g_next_event = 0;
        }
        break;
    }
    case 1: mask = val; break;
    case 3: oamaddr = val; break;
    case 4: oam[oamaddr++] = val; break;
    case 5:
        if (!wlatch) { t = (uint16_t)((t & ~0x1F) | (val >> 3)); finex = val & 7; }
        else t = (uint16_t)((t & ~0x73E0) | ((val & 0x07) << 12) | ((val & 0xF8) << 2));
        wlatch ^= 1;
        break;
    case 6:
        if (!wlatch) t = (uint16_t)((t & 0x00FF) | ((val & 0x3F) << 8));
        else { t = (uint16_t)((t & 0xFF00) | val); v = t; }
        wlatch ^= 1;
        break;
    case 7:
        vram_write(v, val);
        v = (uint16_t)(v + ((ctrl & 0x04) ? 32 : 1));
        break;
    }
}

void ppu_oam_dma(const uint8_t *page) {
    for (int i = 0; i < 256; i++) oam[(uint8_t)(oamaddr + i)] = page[i];
}

void ppu_reset(void) {
    ctrl = mask = status = oamaddr = readbuf = finex = wlatch = 0;
    v = t = 0;
    dots = frame_start = cpu_cyc * 3;
    odd_frame = 0;
    last_event = -1;
    s0_time = 0;
    ppu_nmi_pending = ppu_frame_done = 0;
    memset(oam, 0, sizeof oam);
    memset(ppu_fb, 0, sizeof ppu_fb);
    (void)inc_x;
}
