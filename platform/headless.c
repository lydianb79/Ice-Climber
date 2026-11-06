/* Test harness: runs N frames with a scripted input file, dumps chosen frames
 * as PPM and reports addresses that needed the fallback interpreter.
 * script lines: "<frame> <buttons-hex>"  ;  dump list via argv. */
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "../runtime/nes.h"

int main(int argc, char **argv) {
    int frames = argc > 1 ? atoi(argv[1]) : 600;
    const char *script = argc > 2 ? argv[2] : NULL;
    int sf[4096]; unsigned sb[4096]; int ns = 0;
    if (script) {
        FILE *f = fopen(script, "r");
        while (f && ns < 4096 && fscanf(f, "%d %x", &sf[ns], &sb[ns]) == 2) ns++;
        if (f) fclose(f);
    }
    nes_audio_set_rate(44100);
    nes_init();
    int si = 0; long samples = 0; int16_t buf[4096];
    clock_t t0 = clock();
    for (int fr = 0; fr < frames; fr++) {
        while (si < ns && sf[si] <= fr) { nes_set_buttons(0, (uint8_t)sb[si]); nes_set_buttons(1, (uint8_t)(sb[si] >> 8)); si++; }
        nes_run_frame();
        size_t n; while ((n = nes_audio_read(buf, 4096)) > 0) samples += (long)n;
        for (int i = 3; i < argc; i++) {
            if (atoi(argv[i]) == fr) {
                char name[64]; snprintf(name, sizeof name, "frame_%05d.ppm", fr);
                FILE *o = fopen(name, "wb");
                fprintf(o, "P6 256 240 255\n");
                const uint32_t *fb = nes_framebuffer();
                for (int p = 0; p < 256 * 240; p++) {
                    unsigned char rgb[3] = { (unsigned char)(fb[p] >> 16), (unsigned char)(fb[p] >> 8), (unsigned char)fb[p] };
                    fwrite(rgb, 1, 3, o);
                }
                fclose(o);
            }
        }
    }
    double secs = (double)(clock() - t0) / CLOCKS_PER_SEC;
    fprintf(stderr, "%d frames in %.2fs (%.0f fps), %ld audio samples, cpu_cyc=%llu\n",
            frames, secs, frames / (secs > 0 ? secs : 1), samples, (unsigned long long)cpu_cyc);
    int cnt = 0;
    for (int a = 0; a < 65536; a++) if (interp_seen[a]) { if (cnt < 200) printf("%04X\n", a); cnt++; }
    fprintf(stderr, "interpreted addresses: %d\n", cnt);
    return 0;
}
