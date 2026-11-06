/* 2A03 APU: two pulse channels, triangle, noise and DMC, mixed with the
 * standard non-linear mixer and resampled to the host rate. */
#include <string.h>
#include <math.h>
#include "nes.h"

static const uint8_t length_table[32] = {
    10,254,20,2,40,4,80,6,160,8,60,10,14,12,26,14,12,16,24,18,48,20,96,22,192,24,72,26,16,28,32,30 };
static const uint8_t duty_table[4][8] = {
    {0,1,0,0,0,0,0,0},{0,1,1,0,0,0,0,0},{0,1,1,1,1,0,0,0},{1,0,0,1,1,1,1,1} };
static const uint8_t tri_table[32] = {
    15,14,13,12,11,10,9,8,7,6,5,4,3,2,1,0,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15 };
static const uint16_t noise_period[16] = {
    4,8,16,32,64,96,128,160,202,254,380,508,762,1016,2034,4068 };
static const uint16_t dmc_rate[16] = {
    428,380,340,320,286,254,226,214,190,160,142,128,106,84,72,54 };

typedef struct {
    int enabled, duty, step, length, halt, constvol, vol;
    int env_start, env_div, env_decay;
    int sweep_en, sweep_period, sweep_neg, sweep_shift, sweep_div, sweep_reload;
    int timer, period;
} Pulse;
static Pulse pulse[2];

static struct { int enabled, length, halt, linear, lin_reload_val, lin_reload, timer, period, step; } tri;
static struct { int enabled, length, halt, constvol, vol, env_start, env_div, env_decay, mode, timer, period; uint16_t shift; } noi;
static struct { int enabled, irq_en, loop, rate, timer, output, addr, length, cur_addr, remaining, buffer, buffer_empty, shift, bits, silence, irq; uint8_t sample_addr, sample_len; } dmc;

static int fc_mode, fc_irq_inhibit, fc_irq, fc_cycle;
static uint64_t apu_cyc;
static int odd;

/* resampler */
#define CPU_HZ 1789773.0
#define RING 16384
static int16_t ring[RING];
static size_t ring_w, ring_r; /* SPSC ring: producer = emulation thread, consumer = audio thread */
static double sample_rate = 44100.0, cyc_per_sample, sample_acc;
static double sum_acc; static int sum_n;
static double hp_prev_in, hp_prev_out, lp_out;

void nes_audio_set_rate(double hz) { sample_rate = hz; cyc_per_sample = CPU_HZ / hz; }

static void env_clock(int *start, int *div, int *decay, int period, int loop) {
    if (*start) { *start = 0; *decay = 15; *div = period; }
    else if (*div == 0) { *div = period; if (*decay) (*decay)--; else if (loop) *decay = 15; }
    else (*div)--;
}

static int pulse_target(int i) {
    Pulse *p = &pulse[i];
    int c = p->period >> p->sweep_shift;
    if (p->sweep_neg) c = -c - (i == 0 ? 1 : 0);
    return p->period + c;
}

static void quarter_frame(void) {
    for (int i = 0; i < 2; i++)
        env_clock(&pulse[i].env_start, &pulse[i].env_div, &pulse[i].env_decay, pulse[i].vol, pulse[i].halt);
    env_clock(&noi.env_start, &noi.env_div, &noi.env_decay, noi.vol, noi.halt);
    if (tri.lin_reload) tri.linear = tri.lin_reload_val;
    else if (tri.linear) tri.linear--;
    if (!tri.halt) tri.lin_reload = 0;
}

static void half_frame(void) {
    for (int i = 0; i < 2; i++) {
        Pulse *p = &pulse[i];
        if (!p->halt && p->length) p->length--;
        int tgt = pulse_target(i);
        if (p->sweep_div == 0 && p->sweep_en && p->sweep_shift && p->period >= 8 && tgt <= 0x7FF)
            p->period = tgt;
        if (p->sweep_div == 0 || p->sweep_reload) { p->sweep_div = p->sweep_period; p->sweep_reload = 0; }
        else p->sweep_div--;
    }
    if (!tri.halt && tri.length) tri.length--;
    if (!noi.halt && noi.length) noi.length--;
}

static void frame_counter_step(void) {
    fc_cycle++;
    /* counted in CPU cycles */
    if (fc_mode == 0) {
        switch (fc_cycle) {
        case 7457: quarter_frame(); break;
        case 14913: quarter_frame(); half_frame(); break;
        case 22371: quarter_frame(); break;
        case 29829: quarter_frame(); half_frame(); if (!fc_irq_inhibit) fc_irq = 1; break;
        case 29830: fc_cycle = 0; break;
        }
    } else {
        switch (fc_cycle) {
        case 7457: quarter_frame(); break;
        case 14913: quarter_frame(); half_frame(); break;
        case 22371: quarter_frame(); break;
        case 37281: quarter_frame(); half_frame(); break;
        case 37282: fc_cycle = 0; break;
        }
    }
}

static void dmc_fetch(void) {
    if (dmc.buffer_empty && dmc.remaining) {
        dmc.buffer = RD((uint16_t)dmc.cur_addr);
        dmc.buffer_empty = 0;
        dmc.cur_addr = dmc.cur_addr == 0xFFFF ? 0x8000 : dmc.cur_addr + 1;
        if (--dmc.remaining == 0) {
            if (dmc.loop) { dmc.cur_addr = dmc.addr; dmc.remaining = dmc.length; }
            else if (dmc.irq_en) dmc.irq = 1;
        }
    }
}

static void step_cycle(void) {
    frame_counter_step();
    /* triangle clocks every CPU cycle */
    if (tri.timer == 0) {
        tri.timer = tri.period;
        if (tri.length && tri.linear && tri.period > 1) tri.step = (tri.step + 1) & 31;
    } else tri.timer--;

    odd ^= 1;
    if (odd) {
        for (int i = 0; i < 2; i++) {
            Pulse *p = &pulse[i];
            if (p->timer == 0) { p->timer = p->period; p->step = (p->step + 1) & 7; }
            else p->timer--;
        }
        if (noi.timer == 0) {
            noi.timer = noi.period;
            int fb = (noi.shift & 1) ^ ((noi.shift >> (noi.mode ? 6 : 1)) & 1);
            noi.shift = (uint16_t)((noi.shift >> 1) | (fb << 14));
        } else noi.timer--;
    }
    if (dmc.enabled || dmc.remaining || !dmc.buffer_empty) {
        if (dmc.timer == 0) {
            dmc.timer = dmc.rate - 1;
            if (!dmc.silence) {
                if (dmc.shift & 1) { if (dmc.output <= 125) dmc.output += 2; }
                else { if (dmc.output >= 2) dmc.output -= 2; }
            }
            dmc.shift >>= 1;
            if (--dmc.bits <= 0) {
                dmc.bits = 8;
                if (dmc.buffer_empty) dmc.silence = 1;
                else { dmc.silence = 0; dmc.shift = dmc.buffer; dmc.buffer_empty = 1; dmc_fetch(); }
            }
        } else dmc.timer--;
    }

    /* mix */
    int p1 = 0, p2 = 0, tr, nz = 0;
    for (int i = 0; i < 2; i++) {
        Pulse *p = &pulse[i];
        int out = 0;
        if (p->length && p->period >= 8 && pulse_target(i) <= 0x7FF && duty_table[p->duty][p->step])
            out = p->constvol ? p->vol : p->env_decay;
        if (i == 0) p1 = out; else p2 = out;
    }
    tr = tri_table[tri.step];
    if (noi.length && !(noi.shift & 1)) nz = noi.constvol ? noi.vol : noi.env_decay;
    double pulse_out = (p1 + p2) ? 95.88 / (8128.0 / (p1 + p2) + 100.0) : 0.0;
    double tnd_in = tr / 8227.0 + nz / 12241.0 + dmc.output / 22638.0;
    double tnd_out = tnd_in > 0 ? 159.79 / (1.0 / tnd_in + 100.0) : 0.0;
    sum_acc += pulse_out + tnd_out;
    sum_n++;

    sample_acc += 1.0;
    if (sample_acc >= cyc_per_sample) {
        sample_acc -= cyc_per_sample;
        double s = sum_acc / sum_n;
        sum_acc = 0; sum_n = 0;
        /* 90 Hz-ish high-pass + gentle low-pass, like the console's output stage */
        double hp = s - hp_prev_in + 0.996 * hp_prev_out;
        hp_prev_in = s; hp_prev_out = hp;
        lp_out += (hp - lp_out) * 0.55;
        double o = lp_out * 1.6;
        if (o > 1.0) o = 1.0;
        if (o < -1.0) o = -1.0;
        size_t w = __atomic_load_n(&ring_w, __ATOMIC_RELAXED);
        if (((w + 1) % RING) != __atomic_load_n(&ring_r, __ATOMIC_ACQUIRE)) {
            ring[w] = (int16_t)(o * 32000.0);
            __atomic_store_n(&ring_w, (w + 1) % RING, __ATOMIC_RELEASE);
        }
    }
}

void apu_run_to(uint64_t cpu_cycle) {
    while (apu_cyc < cpu_cycle) { step_cycle(); apu_cyc++; }
}

size_t nes_audio_read(int16_t *dst, size_t max) {
    size_t n = 0;
    size_t r = __atomic_load_n(&ring_r, __ATOMIC_RELAXED);
    size_t w = __atomic_load_n(&ring_w, __ATOMIC_ACQUIRE);
    while (n < max && r != w) { dst[n++] = ring[r]; r = (r + 1) % RING; }
    __atomic_store_n(&ring_r, r, __ATOMIC_RELEASE);
    return n;
}

size_t nes_audio_available(void) {
    size_t r = __atomic_load_n(&ring_r, __ATOMIC_ACQUIRE);
    size_t w = __atomic_load_n(&ring_w, __ATOMIC_ACQUIRE);
    return (w + RING - r) % RING;
}

void apu_write(uint16_t reg, uint8_t v) {
    apu_run_to(cpu_cyc);
    if (reg <= 0x4007) {
        Pulse *p = &pulse[(reg >> 2) & 1];
        switch (reg & 3) {
        case 0: p->duty = v >> 6; p->halt = (v >> 5) & 1; p->constvol = (v >> 4) & 1; p->vol = v & 15; break;
        case 1: p->sweep_en = v >> 7; p->sweep_period = (v >> 4) & 7; p->sweep_neg = (v >> 3) & 1;
                p->sweep_shift = v & 7; p->sweep_reload = 1; break;
        case 2: p->period = (p->period & 0x700) | v; break;
        case 3: p->period = (p->period & 0xFF) | ((v & 7) << 8);
                if (p->enabled) p->length = length_table[v >> 3];
                p->step = 0; p->env_start = 1; break;
        }
        return;
    }
    switch (reg) {
    case 0x4008: tri.halt = v >> 7; tri.lin_reload_val = v & 0x7F; break;
    case 0x400A: tri.period = (tri.period & 0x700) | v; break;
    case 0x400B: tri.period = (tri.period & 0xFF) | ((v & 7) << 8);
                 if (tri.enabled) tri.length = length_table[v >> 3];
                 tri.lin_reload = 1; break;
    case 0x400C: noi.halt = (v >> 5) & 1; noi.constvol = (v >> 4) & 1; noi.vol = v & 15; break;
    case 0x400E: noi.mode = v >> 7; noi.period = noise_period[v & 15]; break;
    case 0x400F: if (noi.enabled) noi.length = length_table[v >> 3]; noi.env_start = 1; break;
    case 0x4010: dmc.irq_en = v >> 7; dmc.loop = (v >> 6) & 1; dmc.rate = dmc_rate[v & 15];
                 if (!dmc.irq_en) dmc.irq = 0; break;
    case 0x4011: dmc.output = v & 0x7F; break;
    case 0x4012: dmc.addr = 0xC000 + v * 64; break;
    case 0x4013: dmc.length = v * 16 + 1; break;
    case 0x4015:
        pulse[0].enabled = v & 1; if (!pulse[0].enabled) pulse[0].length = 0;
        pulse[1].enabled = (v >> 1) & 1; if (!pulse[1].enabled) pulse[1].length = 0;
        tri.enabled = (v >> 2) & 1; if (!tri.enabled) tri.length = 0;
        noi.enabled = (v >> 3) & 1; if (!noi.enabled) noi.length = 0;
        dmc.irq = 0;
        if (v & 0x10) {
            dmc.enabled = 1;
            if (!dmc.remaining) { dmc.cur_addr = dmc.addr; dmc.remaining = dmc.length; dmc_fetch(); }
        } else { dmc.enabled = 0; dmc.remaining = 0; }
        break;
    case 0x4017:
        fc_mode = v >> 7; fc_irq_inhibit = (v >> 6) & 1;
        if (fc_irq_inhibit) fc_irq = 0;
        fc_cycle = 0;
        if (fc_mode) { quarter_frame(); half_frame(); }
        break;
    }
}

uint8_t apu_read_status(void) {
    apu_run_to(cpu_cyc);
    uint8_t r = 0;
    if (pulse[0].length) r |= 1;
    if (pulse[1].length) r |= 2;
    if (tri.length) r |= 4;
    if (noi.length) r |= 8;
    if (dmc.remaining) r |= 0x10;
    if (fc_irq) r |= 0x40;
    if (dmc.irq) r |= 0x80;
    fc_irq = 0;
    return r;
}

int apu_irq(void) { return fc_irq || dmc.irq; }

void apu_reset(void) {
    memset(pulse, 0, sizeof pulse);
    memset(&tri, 0, sizeof tri);
    memset(&noi, 0, sizeof noi);
    memset(&dmc, 0, sizeof dmc);
    noi.shift = 1; noi.period = noise_period[0];
    dmc.rate = dmc_rate[0]; dmc.buffer_empty = 1; dmc.bits = 8; dmc.length = 1; dmc.addr = 0xC000;
    fc_mode = 0; fc_irq_inhibit = 0; fc_irq = 0; fc_cycle = 0;
    apu_cyc = cpu_cyc;
    if (cyc_per_sample == 0) nes_audio_set_rate(44100.0);
}
