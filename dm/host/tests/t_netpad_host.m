// pad_net_apple.m as a game runs it, without a game: the npad layer stubbed, a front end that gives each phone the next player, and the pairing window opened at start
// (DM_NXPAD_TEST_PAIR=1). It prints "READY <port> <code> <QR link>" (or "READY <port> - -" without the window) and serves until killed; t_netpad_host.py is the phone
// that drives it: pairing by code and by QR token, wrong codes, the challenge, WELCOME, PONG, and a second game on the same Mac taking the same phone. The paired phones
// go to DM_NXPAD_DIR, a folder of the test's, never the Mac's own. DM_NXPAD_TEST_PANEL=<file.png> shows the Mac's Pair iPhone… window (pad_net_panel_mac.m) instead and
// writes a picture of it to that file, to look at it without a game.
#import <Cocoa/Cocoa.h>
#include "../pad_net_apple.h"
#include "../pad_net_panel_mac.h"
#include "../dm.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
void dm_joy_attach(int player, uint32_t sides) { (void)player; (void)sides; }
void dm_joy_set(int player, int side, uint64_t buttons, int32_t x, int32_t y) { (void)player; (void)side; (void)buttons; (void)x; (void)y; }
void dm_motion_clear_hid(int player) { (void)player; }
void dm_motion_clear_joy(int player, int side) { (void)player; (void)side; }
void dm_motion_set_hid(int player, const float acc[3], const float rot[3], uint64_t t) { (void)player; (void)acc; (void)rot; (void)t; }
void dm_motion_set_joy(int player, int side, const float acc[3], const float rot[3], uint64_t t) { (void)player; (void)side; (void)acc; (void)rot; (void)t; }

static net_pad *g_slot[8];
static int fe_player(net_pad *p) { for (int i = 0; i < 8; i++) if (g_slot[i] == p) return i; return -1; }
static int fe_attach(net_pad *p) { for (int i = 0; i < 8; i++) if (!g_slot[i]) { g_slot[i] = p; return 1; } return 0; }
static void fe_detach(net_pad *p) { int i = fe_player(p); if (i >= 0) g_slot[i] = NULL; }
static void fe_read(net_pad *p) { (void)p; }
static void pair_changed(int ev, const char *phone) { fprintf(stderr, "[test] pairing event %d %s\n", ev, phone ? phone : "-"); }

static void panel_picture(const char *path) {
    [NSApplication sharedApplication]; NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;
    dm_netpad_panel_show();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500000000), dispatch_get_main_queue(), ^{
        for (NSWindow *w in NSApp.windows) {
            if (!w.visible || ![w isKindOfClass:NSPanel.class]) continue;
            NSView *v = w.contentView.superview ?: w.contentView;   // the frame view: the title bar too
            NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
            [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(path) atomically:YES];
            printf("PANEL %s\n", path); fflush(stdout);
        }
        exit(0);
    });
    [NSApp run];
}

int main(void) {
    @autoreleasepool {
        static const dm_netpad_front front = {fe_attach, fe_detach, fe_read, fe_player, NULL};
        int listening = dm_netpad_start(&front);
        const char *picture = getenv("DM_NXPAD_TEST_PANEL");
        if (picture && *picture) { panel_picture(picture); return 0; }
        const char *pair = getenv("DM_NXPAD_TEST_PAIR");
        if (pair && atoi(pair) && dm_netpad_pair_open(pair_changed)) listening = 1;
        dm_netpad_pairing p; dm_netpad_pair_get(&p);
        printf("READY %d %s %s\n", listening ? p.port : 0, p.code[0] ? p.code : "-", p.url[0] ? p.url : "-");
        fflush(stdout);
        dispatch_main();
    }
}
