// Native macOS front-end for the recompiled game: Cocoa window + Core Animation
// presentation, Core Audio output, keyboard and Game Controller input,
// remappable controls and video filtering options (Settings, ⌘,).
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>
#import <GameController/GameController.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include "../../runtime/nes.h"
#include "game.h"

#define SAMPLE_RATE 44100.0
#define AQ_BUFS 3
#define AQ_FRAMES 512
#define NES_FPS 60.0988
#define AUDIO_TARGET_FILL 2048.0

// ------------------------------------------------------------------ settings model
enum { ACT_UP, ACT_DOWN, ACT_LEFT, ACT_RIGHT, ACT_A, ACT_B, ACT_SELECT, ACT_START, ACT_COUNT };
static const uint8_t act_bits[ACT_COUNT] = { 0x10, 0x20, 0x40, 0x80, 0x01, 0x02, 0x04, 0x08 };
static NSString *const act_names[ACT_COUNT] = { @"Up", @"Down", @"Left", @"Right",
                                                 GAME_ACTION_A, GAME_ACTION_B, @"Select", @"Start" };

enum { GP_A, GP_B, GP_X, GP_Y, GP_L1, GP_R1, GP_L2, GP_R2, GP_MENU, GP_OPTIONS,
       GP_DUP, GP_DDOWN, GP_DLEFT, GP_DRIGHT, GP_LUP, GP_LDOWN, GP_LLEFT, GP_LRIGHT, GP_COUNT };
static NSString *const gp_names[GP_COUNT] = {
    @"A / Cross", @"B / Circle", @"X / Square", @"Y / Triangle", @"L1", @"R1", @"L2", @"R2",
    @"Menu", @"Options", @"D-pad Up", @"D-pad Down", @"D-pad Left", @"D-pad Right",
    @"Stick Up", @"Stick Down", @"Stick Left", @"Stick Right" };

static const int default_keys[2][ACT_COUNT] = {
    { 126, 125, 123, 124, 7, 6, 48, 36 },   // arrows, X, Z, Tab, Return
    { 13, 1, 0, 2, 4, 5, -1, -1 },          // W S A D, H, G
};
static const int default_pads[2][ACT_COUNT] = {
    { GP_DUP, GP_DDOWN, GP_DLEFT, GP_DRIGHT, GP_A, GP_B, GP_OPTIONS, GP_MENU },
    { GP_DUP, GP_DDOWN, GP_DLEFT, GP_DRIGHT, GP_A, GP_B, GP_OPTIONS, GP_MENU },
};

enum { FILTER_NEAREST, FILTER_LINEAR, FILTER_SHARP };
typedef struct { int filter, aspect /*0 square, 1 NTSC 8:7*/, integer_scale, crop, scanlines /*0 off..3 strong*/; } VideoSettings;
static const double scanline_alpha[4] = { 0.0, 0.22, 0.40, 0.60 };

static int g_keymap[2][ACT_COUNT];
static int g_padmap[2][ACT_COUNT];
static VideoSettings g_video;
static bool g_keydown[128];
static AudioQueueRef g_queue;
static atomic_bool g_paused;

static void load_settings(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    memcpy(g_keymap, default_keys, sizeof g_keymap);
    memcpy(g_padmap, default_pads, sizeof g_padmap);
    NSArray *km = [d arrayForKey:@"keymap"], *pm = [d arrayForKey:@"padmap"];
    if (km.count == 2 * ACT_COUNT)
        for (int i = 0; i < 2 * ACT_COUNT; i++) g_keymap[i / ACT_COUNT][i % ACT_COUNT] = [km[i] intValue];
    if (pm.count == 2 * ACT_COUNT)
        for (int i = 0; i < 2 * ACT_COUNT; i++) g_padmap[i / ACT_COUNT][i % ACT_COUNT] = [pm[i] intValue];
    g_video.filter = (int)[d integerForKey:@"videoFilter"];
    g_video.aspect = (int)[d integerForKey:@"videoAspect"];
    g_video.integer_scale = [d boolForKey:@"videoIntegerScale"];
    g_video.crop = [d boolForKey:@"videoCropOverscan"];
    g_video.scanlines = (int)[d integerForKey:@"videoScanlines"];
    if (g_video.filter < 0 || g_video.filter > 2) g_video.filter = FILTER_NEAREST;
    if (g_video.scanlines < 0 || g_video.scanlines > 3) g_video.scanlines = 0;
}

static void save_settings(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSMutableArray *km = [NSMutableArray array], *pm = [NSMutableArray array];
    for (int i = 0; i < 2 * ACT_COUNT; i++) {
        [km addObject:@(g_keymap[i / ACT_COUNT][i % ACT_COUNT])];
        [pm addObject:@(g_padmap[i / ACT_COUNT][i % ACT_COUNT])];
    }
    [d setObject:km forKey:@"keymap"];
    [d setObject:pm forKey:@"padmap"];
    [d setInteger:g_video.filter forKey:@"videoFilter"];
    [d setInteger:g_video.aspect forKey:@"videoAspect"];
    [d setBool:g_video.integer_scale forKey:@"videoIntegerScale"];
    [d setBool:g_video.crop forKey:@"videoCropOverscan"];
    [d setInteger:g_video.scanlines forKey:@"videoScanlines"];
}

static NSString *key_name(int code) {
    if (code < 0) return @"—";
    switch (code) {
    case 0: return @"A"; case 1: return @"S"; case 2: return @"D"; case 3: return @"F";
    case 4: return @"H"; case 5: return @"G"; case 6: return @"Z"; case 7: return @"X";
    case 8: return @"C"; case 9: return @"V"; case 11: return @"B"; case 12: return @"Q";
    case 13: return @"W"; case 14: return @"E"; case 15: return @"R"; case 16: return @"Y";
    case 17: return @"T"; case 18: return @"1"; case 19: return @"2"; case 20: return @"3";
    case 21: return @"4"; case 22: return @"6"; case 23: return @"5"; case 24: return @"=";
    case 25: return @"9"; case 26: return @"7"; case 27: return @"-"; case 28: return @"8";
    case 29: return @"0"; case 30: return @"]"; case 31: return @"O"; case 32: return @"U";
    case 33: return @"["; case 34: return @"I"; case 35: return @"P"; case 36: return @"Return";
    case 37: return @"L"; case 38: return @"J"; case 39: return @"'"; case 40: return @"K";
    case 41: return @";"; case 42: return @"\\"; case 43: return @","; case 44: return @"/";
    case 45: return @"N"; case 46: return @"M"; case 47: return @"."; case 48: return @"Tab";
    case 49: return @"Space"; case 50: return @"`"; case 51: return @"Delete"; case 53: return @"Esc";
    case 56: return @"Left Shift"; case 57: return @"Caps Lock"; case 58: return @"Left Option";
    case 59: return @"Left Control"; case 60: return @"Right Shift"; case 61: return @"Right Option";
    case 62: return @"Right Control"; case 63: return @"Fn";
    case 76: return @"Enter"; case 82: return @"Keypad 0"; case 83: return @"Keypad 1";
    case 84: return @"Keypad 2"; case 85: return @"Keypad 3"; case 86: return @"Keypad 4";
    case 87: return @"Keypad 5"; case 88: return @"Keypad 6"; case 89: return @"Keypad 7";
    case 91: return @"Keypad 8"; case 92: return @"Keypad 9"; case 65: return @"Keypad .";
    case 67: return @"Keypad *"; case 69: return @"Keypad +"; case 75: return @"Keypad /";
    case 78: return @"Keypad -"; case 117: return @"Fwd Delete"; case 115: return @"Home";
    case 119: return @"End"; case 116: return @"Page Up"; case 121: return @"Page Down";
    case 123: return @"←"; case 124: return @"→"; case 125: return @"↓"; case 126: return @"↑";
    case 122: return @"F1"; case 120: return @"F2"; case 99: return @"F3"; case 118: return @"F4";
    case 96: return @"F5"; case 97: return @"F6"; case 98: return @"F7"; case 100: return @"F8";
    case 101: return @"F9"; case 109: return @"F10"; case 103: return @"F11"; case 111: return @"F12";
    }
    return [NSString stringWithFormat:@"Key %d", code];
}

static NSString *pad_name(int el) {
    return (el >= 0 && el < GP_COUNT) ? gp_names[el] : @"—";
}

// Modifier keys arrive as flagsChanged; use device-dependent bits for left/right.
static bool modifier_down(int code, NSEventModifierFlags f) {
    NSUInteger raw = (NSUInteger)f;
    switch (code) {
    case 56: return raw & 0x00000002;   // left shift
    case 60: return raw & 0x00000004;   // right shift
    case 59: return raw & 0x00000001;   // left control
    case 62: return raw & 0x00002000;   // right control
    case 58: return raw & 0x00000020;   // left option
    case 61: return raw & 0x00000040;   // right option
    case 57: return f & NSEventModifierFlagCapsLock;
    case 63: return f & NSEventModifierFlagFunction;
    }
    return false;
}

static bool key_is_bound(int code) {
    for (int p = 0; p < 2; p++)
        for (int a = 0; a < ACT_COUNT; a++)
            if (g_keymap[p][a] == code) return true;
    return false;
}

static bool gp_pressed(GCExtendedGamepad *g, int el) {
    switch (el) {
    case GP_A: return g.buttonA.pressed;
    case GP_B: return g.buttonB.pressed;
    case GP_X: return g.buttonX.pressed;
    case GP_Y: return g.buttonY.pressed;
    case GP_L1: return g.leftShoulder.pressed;
    case GP_R1: return g.rightShoulder.pressed;
    case GP_L2: return g.leftTrigger.pressed;
    case GP_R2: return g.rightTrigger.pressed;
    case GP_MENU: return g.buttonMenu.pressed;
    case GP_OPTIONS: return g.buttonOptions != nil && g.buttonOptions.pressed;
    case GP_DUP: return g.dpad.up.pressed;
    case GP_DDOWN: return g.dpad.down.pressed;
    case GP_DLEFT: return g.dpad.left.pressed;
    case GP_DRIGHT: return g.dpad.right.pressed;
    case GP_LUP: return g.leftThumbstick.yAxis.value > 0.5f;
    case GP_LDOWN: return g.leftThumbstick.yAxis.value < -0.5f;
    case GP_LLEFT: return g.leftThumbstick.xAxis.value < -0.5f;
    case GP_LRIGHT: return g.leftThumbstick.xAxis.value > 0.5f;
    }
    return false;
}

// ------------------------------------------------------------------ audio
static void aq_callback(void *ud, AudioQueueRef q, AudioQueueBufferRef buf) {
    (void)ud;
    int16_t *dst = (int16_t *)buf->mAudioData;
    static int16_t last;
    size_t got = atomic_load(&g_paused) ? 0 : nes_audio_read(dst, AQ_FRAMES);
    if (got) last = dst[got - 1];
    for (size_t i = got; i < AQ_FRAMES; i++) {   // underrun: fade toward silence, no clicks
        last = (int16_t)(last * 0.98);
        dst[i] = last;
    }
    buf->mAudioDataByteSize = (UInt32)(AQ_FRAMES * sizeof(int16_t));
    AudioQueueEnqueueBuffer(q, buf, 0, NULL);
}

static void audio_start(void) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = SAMPLE_RATE;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    f.mBitsPerChannel = 16;
    f.mChannelsPerFrame = 1;
    f.mBytesPerFrame = 2;
    f.mFramesPerPacket = 1;
    f.mBytesPerPacket = 2;
    if (AudioQueueNewOutput(&f, aq_callback, NULL, NULL, NULL, 0, &g_queue) != noErr) {
        g_queue = NULL;
        return;
    }
    for (int i = 0; i < AQ_BUFS; i++) {
        AudioQueueBufferRef b;
        if (AudioQueueAllocateBuffer(g_queue, AQ_FRAMES * sizeof(int16_t), &b) == noErr) {
            memset(b->mAudioData, 0, AQ_FRAMES * sizeof(int16_t));
            b->mAudioDataByteSize = AQ_FRAMES * sizeof(int16_t);
            AudioQueueEnqueueBuffer(g_queue, b, 0, NULL);
        }
    }
    AudioQueueStart(g_queue, NULL);
}

// ------------------------------------------------------------------ view
static double video_display_width(void) { return NES_W * (g_video.aspect ? 8.0 / 7.0 : 1.0); }
static int video_src_height(void) { return g_video.crop ? 224 : 240; }

@interface GameView : NSView
- (void)presentFrame:(const uint32_t *)fb;
- (void)applyVideoSettings;
@end

@implementation GameView {
    CGColorSpaceRef _cs;
    CALayer *_screen;
    CALayer *_scan;          // scanline overlay, one dark band per game line
    int _scanKey;            // (intensity, source height) the overlay image was built for
    uint32_t *_scaled;
    size_t _scaledCap;
}
- (instancetype)initWithFrame:(NSRect)r {
    if ((self = [super initWithFrame:r])) {
        CALayer *root = [CALayer layer];
        root.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        self.layer = root;           // layer-hosting view: we own the layer tree
        self.wantsLayer = YES;
        _screen = [CALayer layer];
        _screen.contentsGravity = kCAGravityResize;
        _screen.actions = @{ @"contents": [NSNull null], @"bounds": [NSNull null],
                             @"position": [NSNull null], @"frame": [NSNull null] };
        [root addSublayer:_screen];
        _scan = [CALayer layer];
        _scan.contentsGravity = kCAGravityResize;
        _scan.magnificationFilter = kCAFilterLinear;   // soft, CRT-like bands
        _scan.minificationFilter = kCAFilterLinear;
        _scan.actions = _screen.actions;
        _scan.hidden = YES;
        [root addSublayer:_scan];
        _scanKey = -1;
        _cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        [self applyVideoSettings];
    }
    return self;
}
- (void)dealloc { CGColorSpaceRelease(_cs); free(_scaled); }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isOpaque { return YES; }

- (void)applyVideoSettings {
    BOOL nearest = (g_video.filter == FILTER_NEAREST);
    _screen.magnificationFilter = nearest ? kCAFilterNearest : kCAFilterLinear;
    _screen.minificationFilter = kCAFilterLinear;
    [self rebuildScanlines];
    [self relayout];
}

- (void)rebuildScanlines {
    int h = video_src_height();
    int key = g_video.scanlines * 1000 + h;
    if (key == _scanKey) return;
    _scanKey = key;
    if (!g_video.scanlines) { _scan.contents = nil; return; }
    // 1 pixel wide, 2 rows per game line: clear row, then a translucent black row.
    int rows = h * 2;
    uint32_t *px = calloc((size_t)rows, 4);
    uint32_t a = (uint32_t)lround(scanline_alpha[g_video.scanlines] * 255.0);
    for (int y = 1; y < rows; y += 2) px[y] = a << 24;   // premultiplied black
    CFDataRef data = CFDataCreate(NULL, (const UInt8 *)px, (CFIndex)rows * 4);
    free(px);
    CGDataProviderRef prov = CGDataProviderCreateWithCFData(data);
    CGImageRef img = CGImageCreate(1, rows, 8, 32, 4, _cs,
                                   kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaPremultipliedFirst,
                                   prov, NULL, false, kCGRenderingIntentDefault);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _scan.contents = (__bridge id)img;
    [CATransaction commit];
    CGImageRelease(img);
    CGDataProviderRelease(prov);
    CFRelease(data);
}

- (void)setFrameSize:(NSSize)s { [super setFrameSize:s]; [self relayout]; }
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; [self relayout]; }

- (CGFloat)backingScale {
    CGFloat bs = self.window ? self.window.backingScaleFactor : 1.0;
    return bs > 0 ? bs : 1.0;
}

- (void)relayout {
    NSSize b = self.bounds.size;
    double dw = video_display_width(), dh = video_src_height();
    double s = MIN(b.width / dw, b.height / dh);
    if (g_video.integer_scale) {
        CGFloat bs = [self backingScale];
        double sp = floor(s * bs);            // whole screen pixels per game pixel (vertical)
        if (sp >= 1) s = sp / bs;
    }
    double w = round(dw * s), h = round(dh * s);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _screen.frame = CGRectMake(round((b.width - w) / 2), round((b.height - h) / 2), w, h);
    _scan.frame = _screen.frame;
    // Below ~2 screen pixels per game line the bands just dim/moiré the image.
    _scan.hidden = !g_video.scanlines || (h * [self backingScale] / dh) < 2.0;
    [CATransaction commit];
}

- (void)presentFrame:(const uint32_t *)fb {
    int h = video_src_height();
    const uint32_t *src = fb + (g_video.crop ? 8 * NES_W : 0);
    int iw = NES_W, ih = h;
    const uint32_t *pix = src;

    if (g_video.filter == FILTER_SHARP) {
        // "Sharp linear": nearest-neighbour prescale by the largest whole factor,
        // then let the GPU filter linearly for the remaining fraction.
        CGFloat bs = [self backingScale];
        double fx = _screen.bounds.size.width * bs / NES_W;
        double fy = _screen.bounds.size.height * bs / h;
        int k = (int)floor(MIN(fx, fy));
        if (k > 8) k = 8;
        if (k >= 2) {
            size_t need = (size_t)NES_W * k * h * k;
            if (need > _scaledCap) { free(_scaled); _scaled = malloc(need * 4); _scaledCap = need; }
            iw = NES_W * k; ih = h * k;
            for (int y = 0; y < h; y++) {
                uint32_t *row = _scaled + (size_t)y * k * iw;
                const uint32_t *s = src + (size_t)y * NES_W;
                for (int x = 0; x < NES_W; x++) {
                    uint32_t c = s[x];
                    for (int i = 0; i < k; i++) row[x * k + i] = c;
                }
                for (int r = 1; r < k; r++) memcpy(row + (size_t)r * iw, row, (size_t)iw * 4);
            }
            pix = _scaled;
        }
    }

    CFDataRef data = CFDataCreate(NULL, (const UInt8 *)pix, (CFIndex)iw * ih * 4);
    CGDataProviderRef prov = CGDataProviderCreateWithCFData(data);
    CGImageRef img = CGImageCreate(iw, ih, 8, 32, (size_t)iw * 4, _cs,
                                   kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst,
                                   prov, NULL, false, kCGRenderingIntentDefault);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _screen.contents = (__bridge id)img;
    [CATransaction commit];
    CGImageRelease(img);
    CGDataProviderRelease(prov);
    CFRelease(data);
}
@end

// ------------------------------------------------------------------ app
enum { CAP_NONE, CAP_KEY, CAP_PAD };

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation>
@end

@implementation AppDelegate {
    NSWindow *_window;
    GameView *_view;
    NSTimer *_timer;
    double _last, _acc, _ticksToSec;
    NSMenuItem *_pauseItem;

    // settings window
    NSWindow *_settings;
    NSTabView *_tabs;
    NSSegmentedControl *_playerSeg;
    NSMutableArray<NSButton *> *_keyButtons, *_padButtons;
    NSPopUpButton *_filterPopup, *_aspectPopup, *_scanPopup;
    NSButton *_integerCheck, *_cropCheck;
    int _capKind, _capAction;
    BOOL _padNeedsRelease;
}

// ---------------------------------------------------------------- menus
- (void)buildMenus {
    NSString *name = GAME_TITLE;
    NSMenu *bar = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    [bar addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:[@"About " stringByAppendingString:name]
                       action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Settings…" action:@selector(showSettings:) keyEquivalent:@","];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:[@"Hide " stringByAppendingString:name] action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:[@"Quit " stringByAppendingString:name] action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;

    NSMenuItem *gameItem = [NSMenuItem new];
    [bar addItem:gameItem];
    NSMenu *game = [[NSMenu alloc] initWithTitle:@"Game"];
    [game addItemWithTitle:@"Reset" action:@selector(resetGame:) keyEquivalent:@"r"];
    _pauseItem = [game addItemWithTitle:@"Pause" action:@selector(togglePause:) keyEquivalent:@"p"];
    gameItem.submenu = game;

    NSMenuItem *viewItem = [NSMenuItem new];
    [bar addItem:viewItem];
    NSMenu *view = [[NSMenu alloc] initWithTitle:@"View"];
    for (int s = 1; s <= 4; s++) {
        NSMenuItem *it = [view addItemWithTitle:[NSString stringWithFormat:@"Size %dx", s]
                                         action:@selector(setWindowScale:)
                                  keyEquivalent:[NSString stringWithFormat:@"%d", s]];
        it.tag = s;
    }
    [view addItem:[NSMenuItem separatorItem]];
    NSArray *filters = @[ @"Nearest (Sharp Pixels)", @"Linear (Smooth)", @"Sharp Linear" ];
    for (NSInteger i = 0; i < 3; i++) {
        NSMenuItem *it = [view addItemWithTitle:filters[i] action:@selector(setFilterFromMenu:) keyEquivalent:@""];
        it.tag = i;
    }
    [view addItem:[NSMenuItem separatorItem]];
    NSMenuItem *integer = [view addItemWithTitle:@"Integer Scaling" action:@selector(toggleIntegerScale:) keyEquivalent:@""];
    (void)integer;
    [view addItemWithTitle:@"NTSC Pixel Aspect (8:7)" action:@selector(toggleAspect:) keyEquivalent:@""];
    [view addItemWithTitle:@"Crop Overscan" action:@selector(toggleCrop:) keyEquivalent:@""];
    NSMenuItem *scanItem = [view addItemWithTitle:@"Scanlines" action:nil keyEquivalent:@""];
    NSMenu *scanMenu = [[NSMenu alloc] initWithTitle:@"Scanlines"];
    NSArray *scanNames = @[ @"Off", @"Light", @"Medium", @"Strong" ];
    for (NSInteger i = 0; i < 4; i++) {
        NSMenuItem *it = [scanMenu addItemWithTitle:scanNames[i] action:@selector(setScanlinesFromMenu:) keyEquivalent:@""];
        it.tag = i;
    }
    scanItem.submenu = scanMenu;
    [view addItem:[NSMenuItem separatorItem]];
    NSMenuItem *fs = [view addItemWithTitle:@"Enter Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
    fs.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
    viewItem.submenu = view;

    NSMenuItem *helpItem = [NSMenuItem new];
    [bar addItem:helpItem];
    NSMenu *help = [[NSMenu alloc] initWithTitle:@"Help"];
    [help addItemWithTitle:@"Controls…" action:@selector(showControls:) keyEquivalent:@"?"];
    helpItem.submenu = help;

    NSApp.mainMenu = bar;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    SEL a = item.action;
    if (a == @selector(setFilterFromMenu:)) item.state = (item.tag == g_video.filter) ? NSControlStateValueOn : NSControlStateValueOff;
    else if (a == @selector(toggleIntegerScale:)) item.state = g_video.integer_scale ? NSControlStateValueOn : NSControlStateValueOff;
    else if (a == @selector(toggleAspect:)) item.state = g_video.aspect ? NSControlStateValueOn : NSControlStateValueOff;
    else if (a == @selector(setScanlinesFromMenu:)) item.state = (item.tag == g_video.scanlines) ? NSControlStateValueOn : NSControlStateValueOff;
    else if (a == @selector(toggleCrop:)) item.state = g_video.crop ? NSControlStateValueOn : NSControlStateValueOff;
    return YES;
}

// ---------------------------------------------------------------- launch
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    load_settings();
    [self buildMenus];
    NSRect r = NSMakeRect(0, 0, round(video_display_width() * 3), video_src_height() * 3);
    _window = [[NSWindow alloc] initWithContentRect:r
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                    NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                            backing:NSBackingStoreBuffered defer:NO];
    _window.title = GAME_TITLE;
    _window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    _window.delegate = self;
    _window.backgroundColor = NSColor.blackColor;
    _view = [[GameView alloc] initWithFrame:r];
    _window.contentView = _view;
    [self updateWindowAspect:NO];
    [_window center];
    [_window setFrameAutosaveName:@"MainWindow"];
    [_window makeKeyAndOrderFront:nil];
    [_window makeFirstResponder:_view];
    [_view applyVideoSettings];

    __weak AppDelegate *weakSelf = self;
    [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskKeyDown | NSEventMaskKeyUp | NSEventMaskFlagsChanged)
                                          handler:^NSEvent *(NSEvent *e) {
        AppDelegate *s = weakSelf;
        return s ? [s handleKeyEvent:e] : e;
    }];

    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    _ticksToSec = (double)tb.numer / (double)tb.denom / 1e9;

    nes_audio_set_rate(SAMPLE_RATE);
    nes_init();
    audio_start();

    _last = mach_absolute_time() * _ticksToSec;
    _timer = [NSTimer timerWithTimeInterval:1.0 / 250.0 target:self selector:@selector(tick:)
                                   userInfo:nil repeats:YES];
    _timer.tolerance = 0.0005;
    [[NSRunLoop currentRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    [NSApp activateIgnoringOtherApps:YES];
}

// ---------------------------------------------------------------- input
- (NSEvent *)handleKeyEvent:(NSEvent *)e {
    int code = e.keyCode;
    if (e.type == NSEventTypeFlagsChanged) {
        if (code == 54 || code == 55 || code >= 128) return e;      // Command stays for menus
        bool down = modifier_down(code, e.modifierFlags);
        if (_capKind == CAP_KEY) {
            if (down) [self finishKeyCapture:code];
            return nil;
        }
        g_keydown[code] = down;
        return e;
    }
    if (e.modifierFlags & NSEventModifierFlagCommand) return e;
    if (code >= 128) return e;

    if (_capKind != CAP_NONE) {
        if (e.type != NSEventTypeKeyDown) return nil;
        if (code == 53) { [self cancelCapture]; return nil; }              // Esc: cancel
        if (_capKind == CAP_KEY) {
            if (code == 51) [self finishKeyCapture:-1];                     // Delete: clear
            else [self finishKeyCapture:code];
        } else if (code == 51) {
            [self finishPadCapture:-1];
        }
        return nil;
    }

    bool down = (e.type == NSEventTypeKeyDown);
    g_keydown[code] = down;
    return key_is_bound(code) ? nil : e;
}

- (void)pollInput {
    uint8_t pads[2] = { 0, 0 };
    if (_capKind == CAP_NONE) {
        for (int p = 0; p < 2; p++)
            for (int a = 0; a < ACT_COUNT; a++) {
                int k = g_keymap[p][a];
                if (k >= 0 && k < 128 && g_keydown[k]) pads[p] |= act_bits[a];
            }
    }
    NSArray<GCController *> *cs = [GCController controllers];

    if (_capKind == CAP_PAD) {
        BOOL any = NO;
        for (GCController *c in cs) {
            GCExtendedGamepad *g = c.extendedGamepad;
            if (!g) continue;
            for (int el = 0; el < GP_COUNT; el++) {
                if (!gp_pressed(g, el)) continue;
                any = YES;
                if (!_padNeedsRelease) { [self finishPadCapture:el]; return; }
            }
        }
        if (!any) _padNeedsRelease = NO;
        nes_set_buttons(0, 0);
        nes_set_buttons(1, 0);
        return;
    }

    for (NSUInteger i = 0; i < cs.count && i < 2; i++) {
        GCExtendedGamepad *g = cs[i].extendedGamepad;
        if (!g || _capKind != CAP_NONE) continue;
        uint8_t b = 0;
        for (int a = 0; a < ACT_COUNT; a++)
            if (gp_pressed(g, g_padmap[i][a])) b |= act_bits[a];
        // The left stick always steers too, in addition to whatever is mapped.
        if (gp_pressed(g, GP_LLEFT)) b |= 0x40;
        if (gp_pressed(g, GP_LRIGHT)) b |= 0x80;
        if (gp_pressed(g, GP_LUP)) b |= 0x10;
        if (gp_pressed(g, GP_LDOWN)) b |= 0x20;
        pads[i] |= b;
    }
    nes_set_buttons(0, pads[0]);
    nes_set_buttons(1, pads[1]);
}

// ---------------------------------------------------------------- frame loop
- (void)tick:(NSTimer *)t {
    double now = mach_absolute_time() * _ticksToSec;
    double dt = now - _last;
    _last = now;
    if (_capKind == CAP_PAD) [self pollInput];        // capture works even while paused
    if (atomic_load(&g_paused)) return;
    _acc += dt;
    if (_acc > 0.1) _acc = 0.1;          // don't spiral after a stall
    const double frame = 1.0 / NES_FPS;
    BOOL ran = NO;
    while (_acc >= frame) {
        [self pollInput];
        nes_run_frame();
        _acc -= frame;
        ran = YES;
    }
    if (ran) {
        [_view presentFrame:nes_framebuffer()];
        // Keep audio latency steady by nudging the resampler (±0.5%).
        double fill = (double)nes_audio_available();
        double adj = 1.0 + (AUDIO_TARGET_FILL - fill) / AUDIO_TARGET_FILL * 0.005;
        if (adj < 0.995) adj = 0.995;
        if (adj > 1.005) adj = 1.005;
        nes_audio_set_rate(SAMPLE_RATE * adj);
    }
}

// ---------------------------------------------------------------- game / view actions
- (void)resetGame:(id)sender { nes_reset(); }

- (void)togglePause:(id)sender {
    bool p = !atomic_load(&g_paused);
    atomic_store(&g_paused, p);
    _pauseItem.title = p ? @"Resume" : @"Pause";
    _window.title = p ? [GAME_TITLE stringByAppendingString:@" — Paused"] : GAME_TITLE;
}

- (void)setWindowScale:(NSMenuItem *)sender {
    if (_window.styleMask & NSWindowStyleMaskFullScreen) return;
    NSRect f = [_window frameRectForContentRect:NSMakeRect(0, 0, round(video_display_width() * sender.tag),
                                                           video_src_height() * sender.tag)];
    NSRect cur = _window.frame;
    f.origin = NSMakePoint(cur.origin.x, NSMaxY(cur) - f.size.height);
    [_window setFrame:f display:YES animate:YES];
}

- (void)updateWindowAspect:(BOOL)resize {
    NSSize ratio = NSMakeSize(video_display_width(), video_src_height());
    _window.contentAspectRatio = ratio;
    _window.contentMinSize = ratio;
    if (resize && !(_window.styleMask & NSWindowStyleMaskFullScreen)) {
        NSRect content = [_window contentRectForFrameRect:_window.frame];
        double h = content.size.height;
        NSRect nc = NSMakeRect(content.origin.x, content.origin.y, round(h * ratio.width / ratio.height), h);
        NSRect f = [_window frameRectForContentRect:nc];
        [_window setFrame:f display:YES animate:NO];
    }
}

- (void)videoSettingsChanged:(BOOL)geometry {
    save_settings();
    if (geometry) [self updateWindowAspect:YES];
    [_view applyVideoSettings];
    [_view presentFrame:nes_framebuffer()];
    [self syncVideoControls];
}

- (void)setFilterFromMenu:(NSMenuItem *)sender { g_video.filter = (int)sender.tag; [self videoSettingsChanged:NO]; }
- (void)toggleIntegerScale:(id)sender { g_video.integer_scale = !g_video.integer_scale; [self videoSettingsChanged:NO]; }
- (void)toggleAspect:(id)sender { g_video.aspect = !g_video.aspect; [self videoSettingsChanged:YES]; }
- (void)toggleCrop:(id)sender { g_video.crop = !g_video.crop; [self videoSettingsChanged:YES]; }
- (void)setScanlinesFromMenu:(NSMenuItem *)sender { g_video.scanlines = (int)sender.tag; [self videoSettingsChanged:NO]; }

// ---------------------------------------------------------------- settings window
- (NSTextField *)label:(NSString *)s bold:(BOOL)bold {
    NSTextField *l = [NSTextField labelWithString:s];
    if (bold) l.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize];
    return l;
}

- (NSView *)buildControlsTab {
    _playerSeg = [NSSegmentedControl segmentedControlWithLabels:@[ @"Player 1", @"Player 2" ]
                                                   trackingMode:NSSegmentSwitchTrackingSelectOne
                                                         target:self action:@selector(playerChanged:)];
    _playerSeg.selectedSegment = 0;

    _keyButtons = [NSMutableArray array];
    _padButtons = [NSMutableArray array];
    NSMutableArray *rows = [NSMutableArray array];
    [rows addObject:@[ [NSGridCell emptyContentView], [self label:@"Keyboard" bold:YES],
                       [self label:@"Controller" bold:YES] ]];
    for (int a = 0; a < ACT_COUNT; a++) {
        NSButton *kb = [NSButton buttonWithTitle:@"" target:self action:@selector(bindKey:)];
        kb.tag = a;
        [kb.widthAnchor constraintEqualToConstant:150].active = YES;
        NSButton *pb = [NSButton buttonWithTitle:@"" target:self action:@selector(bindPad:)];
        pb.tag = a;
        [pb.widthAnchor constraintEqualToConstant:150].active = YES;
        [_keyButtons addObject:kb];
        [_padButtons addObject:pb];
        [rows addObject:@[ [self label:act_names[a] bold:NO], kb, pb ]];
    }
    NSGridView *grid = [NSGridView gridViewWithViews:rows];
    grid.rowSpacing = 6;
    grid.columnSpacing = 12;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    grid.rowAlignment = NSGridRowAlignmentFirstBaseline;

    NSTextField *hint = [self label:@"Click a button, then press a key or controller button.\n"
                                     "Esc cancels, Delete clears. The left stick always steers."
                               bold:NO];
    hint.textColor = NSColor.secondaryLabelColor;
    hint.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];

    NSButton *reset = [NSButton buttonWithTitle:@"Restore Defaults" target:self action:@selector(restoreControlDefaults:)];

    NSStackView *stack = [NSStackView stackViewWithViews:@[ _playerSeg, grid, hint, reset ]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 14;
    stack.edgeInsets = NSEdgeInsetsMake(16, 16, 16, 16);
    return stack;
}

- (NSView *)buildVideoTab {
    _filterPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_filterPopup addItemsWithTitles:@[ @"Nearest — sharp pixels", @"Linear — smooth",
                                        @"Sharp linear — crisp, even pixels" ]];
    _filterPopup.target = self;
    _filterPopup.action = @selector(filterPopupChanged:);

    _aspectPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_aspectPopup addItemsWithTitles:@[ @"Square pixels (1:1)", @"NTSC TV (8:7)" ]];
    _aspectPopup.target = self;
    _aspectPopup.action = @selector(aspectPopupChanged:);

    _scanPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_scanPopup addItemsWithTitles:@[ @"Off", @"Light", @"Medium", @"Strong" ]];
    _scanPopup.target = self;
    _scanPopup.action = @selector(scanPopupChanged:);

    _integerCheck = [NSButton checkboxWithTitle:@"Integer scaling (whole-pixel sizes only)"
                                         target:self action:@selector(integerCheckChanged:)];
    _cropCheck = [NSButton checkboxWithTitle:@"Crop overscan (hide top and bottom 8 lines)"
                                      target:self action:@selector(cropCheckChanged:)];

    NSGridView *grid = [NSGridView gridViewWithViews:@[
        @[ [self label:@"Filtering:" bold:NO], _filterPopup ],
        @[ [self label:@"Pixel aspect:" bold:NO], _aspectPopup ],
        @[ [self label:@"Scanlines:" bold:NO], _scanPopup ],
        @[ [NSGridCell emptyContentView], _integerCheck ],
        @[ [NSGridCell emptyContentView], _cropCheck ],
    ]];
    grid.rowSpacing = 10;
    grid.columnSpacing = 10;
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    grid.rowAlignment = NSGridRowAlignmentFirstBaseline;

    NSTextField *hint = [self label:@"Linear blurs the image when scaled. Sharp linear scales by\n"
                                     "whole pixels first, then smooths only the remainder, so pixels\n"
                                     "stay crisp but evenly sized at any window size.\n"
                                     "Scanlines appear once each game line is at least 2 screen\n"
                                     "pixels tall; they look most even with integer scaling."
                               bold:NO];
    hint.textColor = NSColor.secondaryLabelColor;
    hint.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];

    NSStackView *stack = [NSStackView stackViewWithViews:@[ grid, hint ]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 16;
    stack.edgeInsets = NSEdgeInsetsMake(20, 16, 16, 16);
    return stack;
}

- (void)ensureSettingsWindow {
    if (_settings) return;
    _settings = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 500, 470)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                              backing:NSBackingStoreBuffered defer:YES];
    _settings.title = @"Settings";
    _settings.releasedWhenClosed = NO;
    _settings.delegate = self;

    _tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, 500, 470)];
    NSTabViewItem *c = [[NSTabViewItem alloc] initWithIdentifier:@"controls"];
    c.label = @"Controls";
    c.view = [self buildControlsTab];
    NSTabViewItem *v = [[NSTabViewItem alloc] initWithIdentifier:@"video"];
    v.label = @"Video";
    v.view = [self buildVideoTab];
    [_tabs addTabViewItem:c];
    [_tabs addTabViewItem:v];
    _tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 500, 470)];
    _tabs.frame = NSInsetRect(content.bounds, 8, 8);
    [content addSubview:_tabs];
    _settings.contentView = content;
    [_settings center];
    [self syncControlButtons];
    [self syncVideoControls];
}

- (void)showSettings:(id)sender {
    [self ensureSettingsWindow];
    [_settings makeKeyAndOrderFront:nil];
}

- (void)showControls:(id)sender {
    [self ensureSettingsWindow];
    [_tabs selectTabViewItemWithIdentifier:@"controls"];
    [_settings makeKeyAndOrderFront:nil];
}

- (int)player { return _playerSeg ? (int)_playerSeg.selectedSegment : 0; }

- (void)syncControlButtons {
    int p = [self player];
    for (int a = 0; a < ACT_COUNT; a++) {
        BOOL capK = (_capKind == CAP_KEY && _capAction == a);
        BOOL capP = (_capKind == CAP_PAD && _capAction == a);
        _keyButtons[a].title = capK ? @"Press a key…" : key_name(g_keymap[p][a]);
        _padButtons[a].title = capP ? @"Press a button…" : pad_name(g_padmap[p][a]);
    }
}

- (void)syncVideoControls {
    if (!_filterPopup) return;
    [_filterPopup selectItemAtIndex:g_video.filter];
    [_aspectPopup selectItemAtIndex:g_video.aspect];
    [_scanPopup selectItemAtIndex:g_video.scanlines];
    _integerCheck.state = g_video.integer_scale ? NSControlStateValueOn : NSControlStateValueOff;
    _cropCheck.state = g_video.crop ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)playerChanged:(id)sender { [self cancelCapture]; }

- (void)bindKey:(NSButton *)sender {
    _capKind = CAP_KEY;
    _capAction = (int)sender.tag;
    memset(g_keydown, 0, sizeof g_keydown);
    [self syncControlButtons];
}

- (void)bindPad:(NSButton *)sender {
    _capKind = CAP_PAD;
    _capAction = (int)sender.tag;
    _padNeedsRelease = YES;     // ignore buttons already held when capture starts
    [self syncControlButtons];
}

- (void)finishKeyCapture:(int)code {
    int p = [self player];
    if (code >= 0) {   // a key drives one action only
        for (int q = 0; q < 2; q++)
            for (int a = 0; a < ACT_COUNT; a++)
                if (g_keymap[q][a] == code) g_keymap[q][a] = -1;
    }
    g_keymap[p][_capAction] = code;
    _capKind = CAP_NONE;
    memset(g_keydown, 0, sizeof g_keydown);
    save_settings();
    [self syncControlButtons];
}

- (void)finishPadCapture:(int)el {
    int p = [self player];
    if (el >= 0)
        for (int a = 0; a < ACT_COUNT; a++)
            if (g_padmap[p][a] == el) g_padmap[p][a] = -1;
    g_padmap[p][_capAction] = el;
    _capKind = CAP_NONE;
    save_settings();
    [self syncControlButtons];
}

- (void)cancelCapture {
    _capKind = CAP_NONE;
    [self syncControlButtons];
}

- (void)restoreControlDefaults:(id)sender {
    memcpy(g_keymap, default_keys, sizeof g_keymap);
    memcpy(g_padmap, default_pads, sizeof g_padmap);
    _capKind = CAP_NONE;
    save_settings();
    [self syncControlButtons];
}

- (void)filterPopupChanged:(id)sender { g_video.filter = (int)_filterPopup.indexOfSelectedItem; [self videoSettingsChanged:NO]; }
- (void)aspectPopupChanged:(id)sender {
    int a = (int)_aspectPopup.indexOfSelectedItem;
    if (a == g_video.aspect) return;
    g_video.aspect = a;
    [self videoSettingsChanged:YES];
}
- (void)scanPopupChanged:(id)sender { g_video.scanlines = (int)_scanPopup.indexOfSelectedItem; [self videoSettingsChanged:NO]; }
- (void)integerCheckChanged:(id)sender { g_video.integer_scale = (_integerCheck.state == NSControlStateValueOn); [self videoSettingsChanged:NO]; }
- (void)cropCheckChanged:(id)sender { g_video.crop = (_cropCheck.state == NSControlStateValueOn); [self videoSettingsChanged:YES]; }

// ---------------------------------------------------------------- window delegate
- (void)windowDidResignKey:(NSNotification *)n {
    memset(g_keydown, 0, sizeof g_keydown);
    if (n.object == _settings && _capKind != CAP_NONE) [self cancelCapture];
}

- (void)windowWillClose:(NSNotification *)n {
    if (n.object == _settings) [self cancelCapture];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return NO; }

- (BOOL)windowShouldClose:(NSWindow *)w {
    if (w == _window) [NSApp terminate:nil];
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)n {
    save_settings();
    if (g_queue) { AudioQueueStop(g_queue, true); AudioQueueDispose(g_queue, true); }
}
@end

int main(int argc, const char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        AppDelegate *d = [AppDelegate new];
        app.delegate = d;
        [app run];
    }
    return 0;
}
