// UDP and Bonjour transport for NX Pad phones, shared by the Mac and iOS front ends (pad_net_apple.h says what it does; pad_net.h is the protocol).
// Everything runs on the main queue, where the front ends' own pad callbacks run; only the rumble sink comes from the haptics queue, behind a lock.
#import <Foundation/Foundation.h>
#import "pad_net_apple.h"
#include "pad_net.h"
#include "dm.h"
#include "front.h"   // dm_touch_set
#include <dns_sd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <os/lock.h>
#include <TargetConditionals.h>
#if TARGET_OS_OSX
#import <SystemConfiguration/SystemConfiguration.h>
#endif

// A phone: its pad (first, so a net_pad * is its net_client *), where it sends from, and what the host last told the npad layer and the phone
typedef struct net_client {
    net_pad pad;
    struct sockaddr_storage addr; socklen_t alen;
    uint32_t seq; int seq_ok;        // the last sequence number taken (a datagram that arrives late is dropped)
    int64_t clock; int clock_ok;     // the phone's clock to the host's: now_ns() at arrival minus the packet's time, its lowest (the quickest datagram), creeping up 1 us a
                                     // packet so the two clocks' drift is followed
    uint64_t heard;                  // now_ns() of its last datagram
    int player;                      // the player last told (WELCOME, dm_joy_attach); -1 none
    uint8_t told_sides;              // the Joy-Cons last given to the npad layer
    int rumble_off;                  // silent RUMBLE packets still to send after a buzz
    int touching;                    // fingers of its touch area handed to the game now (dm_touch_set)
    uint64_t packets, samples, logged;
} net_client;

static dm_netpad_front g_front;
static net_pad *g_pads;
static int g_sock = -1, g_port, g_log, g_joy = 1, g_active = 1, g_rumble_on;   // g_joy: each Joy-Con reported on its own (not with DM_PAD_MERGE)
static int g_started, g_mode;   // g_started: dm_netpad_start ran (the front end is known); g_mode: DM_NXPAD, NP_OFF / NP_ON / NP_AUTO
enum { NP_OFF, NP_ON, NP_AUTO };
static dispatch_source_t g_read, g_tick, g_rumble;
static DNSServiceRef g_dns;
static uint32_t g_seq;
static uint64_t g_host_id;                  // this Mac's ID, the same for every game (np_identity): a phone pairs with a Mac, not with one game
static char g_mac_name[64], g_tid[20];      // the Mac's name and the game's title ID, for the advertisement and PAIRED
static char g_dir[PATH_MAX];                // where the host ID and the paired phones live: <Application Support>/nxnative/nxpad
// The paired phones (nxpd_trust lines of paired.tsv), read again whenever the file changed: another game on this Mac may have paired one
static nxpd_trust *g_trust; static int g_ntrust; static struct timespec g_trust_mtime; static int g_trust_read;
// The challenges sent and not yet answered: one per phone, good for 10 s
typedef struct { uint64_t client, until; uint8_t nonce[NXPD_NONCE]; } np_chal;
static np_chal g_chal[16];
static uint64_t g_kicked[8][2];             // a phone told it is not paired, and when: the log names it once in 10 s, not at every HELLO
// The pairing window (Pair iPhone…): the code and the QR code's token while it is open. A code is used once, and changes after NXPD_PAIR_TRIES wrong tries or 10 minutes;
// after NP_CODE_MAX_WRONG wrong tries in all, codes are refused until the window opens again (the QR code still pairs)
#define NP_CODE_MAX_WRONG 15
static struct {
    int open, tries, wrong; uint64_t until;
    char code[NXPD_CODE + 1]; uint8_t token[NXPD_TOKEN];
    void (*changed)(int event, const char *phone);
    uint64_t last_client; uint8_t last_nonce[NXPD_NONCE]; uint8_t last_reply[NXPD_HEADER + 64 + 512]; size_t last_len;   // the last pairing's answer, sent again when its PAIR comes again
    uint64_t wrong_client; uint8_t wrong_nonce[NXPD_NONCE]; uint8_t wrong_result;   // the last wrong PAIR: the same one again costs no second try
} g_pair;
static const uint64_t NP_CODE_NS = 600000000000ull, NP_CHAL_NS = 10000000000ull;
static char g_title[201];            // the game's name, as the app shows it: WELCOME and the TXT record
static jc1_rumble_hold g_rv[DM_PLAYERS];   // each player's vibration, from the haptics queue (dm_netpad_rumble)
static os_unfair_lock g_rv_lock = OS_UNFAIR_LOCK_INIT;
static const uint64_t NP_SILENT_NS = 1000000000ull, NP_TICK_NS = 250000000ull, NP_RUMBLE_NS = 15000000ull;

net_pad *dm_netpad_pads(void) { return g_pads; }

static net_client *np_client(net_pad *p) { return (net_client *)p; }
static int np_player(net_pad *p) { return p && g_front.player ? g_front.player(p) : -1; }
static int np_blocked(void) { return !g_active || (g_front.blocked && g_front.blocked()); }
static uint32_t np_seq(void) { return ++g_seq; }
static void np_send(int sock, const struct sockaddr_storage *to, socklen_t tolen, const uint8_t *b, size_t n) {
    if (sock >= 0 && sendto(sock, b, n, 0, (const struct sockaddr *)to, tolen) < 0 && g_log) LOG("[nxpad] send failed: %s", strerror(errno));
}
static void np_send_to(net_client *c, const uint8_t *b, size_t n) { np_send(g_sock, &c->addr, c->alen, b, n); }
static int np_same_addr(const struct sockaddr_storage *a, const struct sockaddr_storage *b) {
    if (a->ss_family != b->ss_family) return 0;
    if (a->ss_family == AF_INET6) {
        const struct sockaddr_in6 *x = (const struct sockaddr_in6 *)a, *y = (const struct sockaddr_in6 *)b;
        return x->sin6_port == y->sin6_port && x->sin6_scope_id == y->sin6_scope_id && !memcmp(&x->sin6_addr, &y->sin6_addr, sizeof x->sin6_addr);
    }
    if (a->ss_family == AF_INET) {
        const struct sockaddr_in *x = (const struct sockaddr_in *)a, *y = (const struct sockaddr_in *)b;
        return x->sin_port == y->sin_port && x->sin_addr.s_addr == y->sin_addr.s_addr;
    }
    return 0;
}
static void np_addr_text(const struct sockaddr_storage *a, char *out, size_t cap) {
    char ip[INET6_ADDRSTRLEN] = "?"; int port = 0;
    if (a->ss_family == AF_INET6) {
        const struct sockaddr_in6 *x = (const struct sockaddr_in6 *)a; port = ntohs(x->sin6_port);
        if (IN6_IS_ADDR_V4MAPPED(&x->sin6_addr)) inet_ntop(AF_INET, &x->sin6_addr.s6_addr[12], ip, sizeof ip);   // an IPv4 phone on the dual-stack socket
        else inet_ntop(AF_INET6, &x->sin6_addr, ip, sizeof ip);
    } else if (a->ss_family == AF_INET) {
        const struct sockaddr_in *x = (const struct sockaddr_in *)a; port = ntohs(x->sin_port);
        inet_ntop(AF_INET, &x->sin_addr, ip, sizeof ip);
    }
    snprintf(out, cap, "%s port %d", ip, port);
}
static const char *np_sides_text(uint8_t sides) { return sides == 3 ? "a Joy-Con pair" : sides == 1 ? "a left Joy-Con held sideways" : "a right Joy-Con held sideways"; }
static void np_joy_release(int pl, int side) { if (g_joy && pl >= 0) { dm_joy_set(pl, side, 0, 0, 0); dm_motion_clear_joy(pl, side); } }

static void np_welcome(net_client *c) {
    int pl = np_player(&c->pad); uint8_t b[NXPD_HEADER + 5 + 255];
    np_send_to(c, b, nxpd_welcome(b, np_seq(), pl, c->pad.sides, nxpd_player_lights(pl), NXPD_FEATURE_MOTION | NXPD_FEATURE_RUMBLE | NXPD_FEATURE_TOUCH, g_title));
}
// After a HELLO or the front end's read(): the pad's player (a first press may have given it one) and its Joy-Cons, to the npad layer and, when the player changed, to the phone.
// Returns whether a WELCOME went out
static int np_sync(net_client *c) {
    int pl = np_player(&c->pad); uint8_t sides = c->pad.sides;
    if (pl == c->player && sides == c->told_sides) return 0;
    if (g_joy && c->player >= 0 && c->player != pl) { np_joy_release(c->player, 0); np_joy_release(c->player, 1); dm_joy_attach(c->player, 0); }
    if (g_joy && pl >= 0) {
        for (int k = 0; k < 2; k++) if (pl == c->player && !(sides >> k & 1) && (c->told_sides >> k & 1)) np_joy_release(pl, k);   // a Joy-Con the phone no longer stands for
        dm_joy_attach(pl, sides);
    }
    int moved = pl != c->player;
    c->player = pl; c->told_sides = sides;
    if (moved) { np_welcome(c); return 1; }
    return 0;
}
// The rumble tick runs while a phone is there, not for the whole game
static void np_rumble_timer_sync(void) {
    if (!g_rumble || g_rumble_on == (g_pads != NULL)) return;
    g_rumble_on = g_pads != NULL;
    if (g_rumble_on) dispatch_resume(g_rumble); else dispatch_suspend(g_rumble);
}
// The phone's fingers off the game's touch screen (it went, lost focus or has no player): none stays down
static void np_touch_lift(net_client *c) {
    if (!c->touching) return;
    c->touching = 0;
    dm_touch_set(NULL, 0);
}
static void np_unlink(net_client *c) {
    net_pad **link = &g_pads; while (*link && *link != &c->pad) link = &(*link)->next;
    if (*link) *link = c->pad.next;
    np_rumble_timer_sync();
}
static void np_remove(net_client *c, const char *why) {
    np_unlink(c);
    int pl = c->player;
    np_touch_lift(c);
    if (pl >= 0) { if (g_joy) { np_joy_release(pl, 0); np_joy_release(pl, 1); dm_joy_attach(pl, 0); } dm_motion_clear_hid(pl); }
    LOG("[nxpad] '%s' %s", c->pad.name, why);
    if (g_front.detach) g_front.detach(&c->pad);
    free(c);
}
static net_client *np_at(const struct sockaddr_storage *from) {
    for (net_pad *p = g_pads; p; p = p->next) if (np_same_addr(&np_client(p)->addr, from)) return np_client(p);
    return NULL;
}

// ---- This Mac's identity and the paired phones, shared by every game on it (<Application Support>/nxnative/nxpad: host_id, paired.tsv) ----
static void np_path(char *out, size_t cap, const char *name) {
    if (!g_dir[0]) {
        NSURL *u = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        NSString *d = [[(u.path ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"]) stringByAppendingPathComponent:@"nxnative"] stringByAppendingPathComponent:@"nxpad"];
        const char *over = getenv("DM_NXPAD_DIR"); if (over && *over) d = @(over);   // tests/t_netpad_host.m: not the Mac's own pairings
        [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:nil];
        snprintf(g_dir, sizeof g_dir, "%s", d.fileSystemRepresentation);
    }
    snprintf(out, cap, "%s/%s", g_dir, name);
}
// A file written whole or not at all (a temporary file renamed over it), readable by its owner only: the pairing keys are in it
static int np_write_file(const char *path, const char *text, size_t n) {
    char tmp[PATH_MAX + 32]; snprintf(tmp, sizeof tmp, "%s.%d.tmp", path, (int)getpid());
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0600); if (fd < 0) return 0;
    int ok = write(fd, text, n) == (ssize_t)n; ok = close(fd) == 0 && ok;
    if (!ok || rename(tmp, path) != 0) { unlink(tmp); return 0; }
    return 1;
}
// The Mac's ID: made by the first game that needs one (O_EXCL, so two starting together agree on it), read by the others
static void np_identity(void) {
    if (g_host_id) return;
    char path[PATH_MAX]; np_path(path, sizeof path, "host_id");
    for (int attempt = 0; attempt < 3 && !g_host_id; attempt++) {
        char line[64] = ""; FILE *f = fopen(path, "r");
        if (f) { if (!fgets(line, sizeof line, f)) line[0] = 0; fclose(f); }
        uint8_t b[8]; uint64_t id = 0;
        if (nxpd_unhex(line, b, 8)) { for (int i = 0; i < 8; i++) id = id << 8 | b[i]; if (id) { g_host_id = id; break; } }
        do arc4random_buf(&id, sizeof id); while (!id);
        char t[24]; int n = snprintf(t, sizeof t, "%016llx\n", (unsigned long long)id);
        if (f) { if (np_write_file(path, t, (size_t)n)) g_host_id = id; continue; }   // there, but not an ID
        int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (fd < 0) continue;   // another game made it meanwhile: read that one
        if (write(fd, t, (size_t)n) == n) g_host_id = id;
        close(fd);
    }
    if (!g_host_id) { do arc4random_buf(&g_host_id, sizeof g_host_id); while (!g_host_id); LOG("[nxpad] no host ID in %s: pairings made now last until this game closes", g_dir); }
}
// The paired phones, read again when the file changed (another game on this Mac paired or forgot one); force: read it whatever its time
static void np_trust_load(int force) {
    char path[PATH_MAX]; np_path(path, sizeof path, "paired.tsv");
    struct stat st; int have = stat(path, &st) == 0;
    if (!force && g_trust_read && (have ? st.st_mtimespec.tv_sec == g_trust_mtime.tv_sec && st.st_mtimespec.tv_nsec == g_trust_mtime.tv_nsec : !g_trust_mtime.tv_sec)) return;
    free(g_trust); g_trust = NULL; g_ntrust = 0; g_trust_read = 1; memset(&g_trust_mtime, 0, sizeof g_trust_mtime);
    if (!have) return;
    g_trust_mtime = st.st_mtimespec;
    FILE *f = fopen(path, "r"); if (!f) return;
    char line[512]; int cap = 0;
    while (fgets(line, sizeof line, f)) {
        nxpd_trust t; if (!nxpd_trust_parse(line, &t)) continue;
        int i = 0; while (i < g_ntrust && g_trust[i].client != t.client) i++;   // a later line of the same phone wins
        if (i == g_ntrust) {
            if (g_ntrust == cap) { int nc = cap ? cap * 2 : 8; nxpd_trust *nt = realloc(g_trust, (size_t)nc * sizeof *nt); if (!nt) break; g_trust = nt; cap = nc; }
            g_ntrust++;
        }
        g_trust[i] = t;
    }
    fclose(f);
}
static int np_trust_save(void) {
    size_t cap = (size_t)g_ntrust * 200 + 256, n = 0; char *text = malloc(cap); if (!text) return 0;
    n += (size_t)snprintf(text, cap, "# NX Pad: the iPhones paired with this Mac, for every game on it (dm/host/pad_net_apple.m). Client, key, when, name; delete a line to unpair.\n");
    for (int i = 0; i < g_ntrust && n < cap; i++) n += (size_t)nxpd_trust_format(&g_trust[i], text + n, cap - n);
    char path[PATH_MAX]; np_path(path, sizeof path, "paired.tsv");
    int ok = n < cap && np_write_file(path, text, n); free(text);
    struct stat st; if (ok && stat(path, &st) == 0) g_trust_mtime = st.st_mtimespec;
    return ok;
}
static const nxpd_trust *np_trusted(uint64_t client) {
    np_trust_load(0);
    for (int i = 0; i < g_ntrust; i++) if (g_trust[i].client == client) return &g_trust[i];
    return NULL;
}
// The challenge of a phone, made when make is set (a free slot, or the oldest)
static np_chal *np_chal_for(uint64_t client, int make) {
    np_chal *slot = NULL, *oldest = &g_chal[0];
    for (int i = 0; i < (int)(sizeof g_chal / sizeof *g_chal); i++) {
        np_chal *c = &g_chal[i];
        if (c->client == client) return c;
        if (!c->client && !slot) slot = c;
        if (c->until < oldest->until) oldest = c;
    }
    if (!make) return NULL;
    np_chal *c = slot ? slot : oldest; memset(c, 0, sizeof *c); c->client = client; return c;
}
static int np_kick_logged(uint64_t client, uint64_t now) {   // the log names an unpaired phone once in 10 s
    int o = 0;
    for (int i = 0; i < 8; i++) {
        if (g_kicked[i][0] == client) { if (now - g_kicked[i][1] < NP_CHAL_NS) return 1; g_kicked[i][1] = now; return 0; }
        if (g_kicked[i][1] < g_kicked[o][1]) o = i;
    }
    g_kicked[o][0] = client; g_kicked[o][1] = now; return 0;
}

static void np_hello(const nxpd_hello *h, const struct sockaddr_storage *from, socklen_t flen) {
    char at[INET6_ADDRSTRLEN + 16]; np_addr_text(from, at, sizeof at);
    if (h->device != NXPD_DEVICE_JOYCON) {   // a later kind of controller (Joy-Con 2) this host does not know yet
        uint8_t b[NXPD_HEADER + 1]; np_send(g_sock, from, flen, b, nxpd_byte(b, NXPD_KICK, np_seq(), NXPD_KICK_UNSUPPORTED));
        LOG("[nxpad] '%s' at %s: device %u is not supported", h->name, at, (unsigned)h->device);
        return;
    }
    net_client *c = NULL;
    for (net_pad *p = g_pads; p; p = p->next) if (p->client == h->client) { c = np_client(p); break; }
    uint64_t now = now_ns();
    if (!c) {
        c = calloc(1, sizeof *c); if (!c) return;
        c->pad.client = h->client; c->pad.sides = h->sides; c->player = -1;
        snprintf(c->pad.name, sizeof c->pad.name, "%s (NX Pad)", h->name[0] ? h->name : "phone");
        memcpy(&c->addr, from, flen); c->alen = flen; c->heard = now;
        c->pad.next = g_pads; g_pads = &c->pad;
        np_rumble_timer_sync();
        LOG("[nxpad] '%s' at %s: %s%s%s", c->pad.name, at, np_sides_text(h->sides), h->features & NXPD_FEATURE_MOTION ? ", with motion" : "", h->features & NXPD_FEATURE_RUMBLE ? ", with rumble" : "");
        if (!g_front.attach || !g_front.attach(&c->pad)) {
            uint8_t b[NXPD_HEADER + 1]; np_send_to(c, b, nxpd_byte(b, NXPD_KICK, np_seq(), NXPD_KICK_FULL));
            LOG("[nxpad] '%s': all %d players are taken, not used", c->pad.name, DM_PLAYERS);
            np_unlink(c); free(c);
            return;
        }
    } else {
        if (!np_same_addr(&c->addr, from)) { memcpy(&c->addr, from, flen); c->alen = flen; LOG("[nxpad] '%s' is back, at %s", c->pad.name, at); }
        if (c->pad.sides != h->sides) {   // another mode on the phone: the Joy-Con it no longer stands for lets go
            LOG("[nxpad] '%s' is %s now", c->pad.name, np_sides_text(h->sides));
            c->pad.sides = h->sides;
            for (int k = 0; k < 2; k++) if (!(h->sides >> k & 1)) { c->pad.buttons[k] = 0; c->pad.stick[k][0] = c->pad.stick[k][1] = 0; }
            if (g_front.read) g_front.read(&c->pad);
        }
        c->heard = now;
    }
    c->seq_ok = 0; c->clock_ok = 0;   // the phone may have started again: its count and its clock with it
    if (!np_sync(c)) np_welcome(c);
}

// A HELLO takes a player only from a paired phone that answers this run's challenge: the first HELLO gets the CHALLENGE, the next one carries the answer. A challenge
// still good is sent again rather than replaced, so a HELLO that crossed the answer in the air does not undo it; an answered one is used up
static void np_hello_check(const nxpd_hello *h, const struct sockaddr_storage *from, socklen_t flen) {
    uint64_t now = now_ns();
    const nxpd_trust *t = np_trusted(h->client);
    if (!t) {
        uint8_t b[NXPD_HEADER + 1]; np_send(g_sock, from, flen, b, nxpd_byte(b, NXPD_KICK, np_seq(), NXPD_KICK_NOT_PAIRED));
        if (!np_kick_logged(h->client, now)) {
            char at[INET6_ADDRSTRLEN + 16]; np_addr_text(from, at, sizeof at);
            LOG("[nxpad] '%s' at %s is not paired with this Mac: Controllers > Pair iPhone… shows the code it needs", h->name, at);
        }
        return;
    }
    np_chal *c = np_chal_for(h->client, 0);
    if (c && now >= c->until) { c->client = 0; c = NULL; }
    if (h->has_auth && c) {
        uint8_t want[NXPD_HMAC]; nxpd_hello_auth(t->key, g_host_id, h->client, c->nonce, h->sides, want);
        if (nxpd_hmac_equal(want, h->auth)) { c->client = 0; np_hello(h, from, flen); return; }
        if (g_log) LOG("[nxpad] '%s': a wrong answer to the challenge", h->name);
    }
    if (!c) { c = np_chal_for(h->client, 1); arc4random_buf(c->nonce, NXPD_NONCE); c->until = now + NP_CHAL_NS; }
    uint8_t b[NXPD_HEADER + 24]; np_send(g_sock, from, flen, b, nxpd_challenge(b, np_seq(), g_host_id, c->nonce));
}

// ---- Pairing (the Mac's Pair iPhone… window) ----
static void np_pair_renew(void) {   // a new code and QR token, good for 10 minutes
    snprintf(g_pair.code, sizeof g_pair.code, "%06u", arc4random_uniform(1000000));
    arc4random_buf(g_pair.token, NXPD_TOKEN); g_pair.tries = 0; g_pair.until = now_ns() + NP_CODE_NS;
    if (g_pair.changed) g_pair.changed(DM_NETPAD_PAIR_NEW_CODE, NULL);
}
static void np_pair(const nxpd_pair *q, const struct sockaddr_storage *from, socklen_t flen) {
    uint8_t b[sizeof g_pair.last_reply]; char at[INET6_ADDRSTRLEN + 16]; np_addr_text(from, at, sizeof at);
    if (g_pair.last_len && q->client == g_pair.last_client && !memcmp(q->nonce, g_pair.last_nonce, NXPD_NONCE)) {   // the phone did not hear PAIRED: the same again
        np_send(g_sock, from, flen, g_pair.last_reply, g_pair.last_len); return;
    }
    int code = q->method == NXPD_PAIR_CODE;
    if (!g_pair.open || (code && g_pair.wrong >= NP_CODE_MAX_WRONG)) {   // not this game's window, or no window: the phone tries the other games
        np_send(g_sock, from, flen, b, nxpd_paired(b, np_seq(), NXPD_PAIRED_CLOSED, g_host_id, NULL, NULL, g_mac_name, g_title)); return;
    }
    if (g_pair.wrong_client && q->client == g_pair.wrong_client && !memcmp(q->nonce, g_pair.wrong_nonce, NXPD_NONCE)) {   // sent again: the same answer, no try counted
        np_send(g_sock, from, flen, b, nxpd_paired(b, np_seq(), g_pair.wrong_result, g_host_id, NULL, NULL, g_mac_name, g_title)); return;
    }
    const uint8_t *sec = code ? (const uint8_t *)g_pair.code : g_pair.token; size_t sl = code ? NXPD_CODE : NXPD_TOKEN;
    uint8_t want[NXPD_HMAC]; nxpd_pair_proof(sec, sl, g_host_id, q->client, q->nonce, want);
    if (!nxpd_hmac_equal(want, q->proof)) {
        uint8_t result = NXPD_PAIRED_WRONG;
        if (code) { g_pair.wrong++; if (++g_pair.tries >= NXPD_PAIR_TRIES) result = NXPD_PAIRED_RENEWED; }   // a QR token is too long to guess: an old QR code costs no try
        LOG("[nxpad] '%s' at %s: a wrong pairing %s%s", q->name, at, code ? "code" : "QR code", result == NXPD_PAIRED_RENEWED ? ": too many tries, the code changes" : "");
        np_send(g_sock, from, flen, b, nxpd_paired(b, np_seq(), result, g_host_id, NULL, NULL, g_mac_name, g_title));
        g_pair.wrong_client = q->client; memcpy(g_pair.wrong_nonce, q->nonce, NXPD_NONCE); g_pair.wrong_result = result;
        if (result == NXPD_PAIRED_RENEWED) np_pair_renew();
        if (g_pair.changed) g_pair.changed(DM_NETPAD_PAIR_WRONG, q->name);
        return;
    }
    uint8_t hn[NXPD_NONCE], key[NXPD_KEY], confirm[NXPD_HMAC]; arc4random_buf(hn, sizeof hn);
    nxpd_pair_key(sec, sl, g_host_id, q->client, q->nonce, hn, key); nxpd_pair_confirm(key, g_host_id, q->client, confirm);
    np_trust_load(0);
    int i = 0; while (i < g_ntrust && g_trust[i].client != q->client) i++;
    if (i == g_ntrust) { nxpd_trust *nt = realloc(g_trust, (size_t)(g_ntrust + 1) * sizeof *nt); if (!nt) return; g_trust = nt; g_ntrust++; }
    nxpd_trust *t = &g_trust[i]; memset(t, 0, sizeof *t);
    t->client = q->client; memcpy(t->key, key, NXPD_KEY); t->when = (int64_t)time(NULL); snprintf(t->name, sizeof t->name, "%s", q->name[0] ? q->name : "iPhone");
    char name[NXPD_NAME + 1]; memcpy(name, t->name, sizeof name);
    if (!np_trust_save()) LOG("[nxpad] could not write %s/paired.tsv: '%s' stays paired only until this game closes", g_dir, name);
    g_pair.last_client = q->client; memcpy(g_pair.last_nonce, q->nonce, NXPD_NONCE);
    g_pair.last_len = nxpd_paired(g_pair.last_reply, np_seq(), NXPD_PAIRED_OK, g_host_id, hn, confirm, g_mac_name, g_title);
    np_send(g_sock, from, flen, g_pair.last_reply, g_pair.last_len);
    LOG("[nxpad] '%s' at %s paired with this Mac by %s: it connects to every game here by itself from now on", name, at, code ? "code" : "QR code");
    np_pair_renew();   // a code pairs one phone
    if (g_pair.changed) g_pair.changed(DM_NETPAD_PAIR_PAIRED, name);
}

static void np_input(net_client *c, const nxpd_msg *m) {
    if (c->seq_ok && !nxpd_seq_newer(m->seq, c->seq)) return;
    c->seq = m->seq; c->seq_ok = 1;
    const nxpd_input *in = &m->input;
    if (in->sides != c->pad.sides) return;   // sent before its new HELLO took
    uint64_t now = now_ns();
    int64_t clock = (int64_t)(now - in->time_ns);
    if (!c->clock_ok || clock < c->clock + 1000) c->clock = clock; else c->clock += 1000;
    c->clock_ok = 1;
    memcpy(c->pad.buttons, in->buttons, sizeof c->pad.buttons); memcpy(c->pad.stick, in->stick, sizeof c->pad.stick);
    c->pad.extras = in->extras; c->pad.have = 1; c->samples += (uint64_t)in->samples;
    if (g_front.read) g_front.read(&c->pad);   // the pad's whole state; a first press makes it a player
    np_sync(c);
    int pl = np_player(&c->pad);
    if (pl < 0 || np_blocked()) return;
    if (g_joy) for (int k = 0; k < 2; k++) if (in->sides >> k & 1) dm_joy_set(pl, k, in->buttons[k], in->stick[k][0], in->stick[k][1]);
    for (int i = 0; i < in->samples; i++) {
        const nxpd_sample *s = &in->s[i];
        uint64_t t = in->time_ns - (uint64_t)s->age_us * 1000 + (uint64_t)c->clock;   // the sample's time on the host's clock, never later than now
        if ((int64_t)(t - now) > 0) t = now;
        if (g_joy) for (int k = 0; k < 2; k++) if (in->sides >> k & 1) dm_motion_set_joy(pl, k, s->acc, s->rot, t);
        float acc[3], rot[3]; nxpd_merged_sample(s, in->sides, acc, rot);
        dm_motion_set_hid(pl, acc, rot, t);
    }
}

// The fingers of the phone's touch area: the whole set goes to the game's touch screen, as the Mac's mouse and the iPhone's own screen do. Only a phone with a player
// touches, and not while the game takes no controller input
static void np_touch(net_client *c, const nxpd_msg *m) {
    if (c->seq_ok && !nxpd_seq_newer(m->seq, c->seq)) return;
    c->seq = m->seq; c->seq_ok = 1;
    if (np_player(&c->pad) < 0 || np_blocked()) { np_touch_lift(c); return; }
    dm_touch t[NXPD_TOUCHES];
    for (int i = 0; i < m->touch.n; i++) { t[i].id = m->touch.t[i].id; t[i].x = m->touch.t[i].x; t[i].y = m->touch.t[i].y; }
    dm_touch_set(t, m->touch.n);
    c->touching = m->touch.n;
}

static void np_receive(void) {
    for (int i = 0; i < 64; i++) {   // what is queued, a bounded batch at a time
        uint8_t b[512]; struct sockaddr_storage from; socklen_t flen = sizeof from;
        ssize_t n = recvfrom(g_sock, b, sizeof b, 0, (struct sockaddr *)&from, &flen);
        if (n < 0) {
            if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR && g_log) LOG("[nxpad] receive failed: %s", strerror(errno));
            return;
        }
        nxpd_msg m; if (!nxpd_parse(b, (size_t)n, &m)) continue;
        if (m.kind == NXPD_PAIR) { np_pair(&m.pair, &from, flen); continue; }
        if (m.kind == NXPD_HELLO) { np_hello_check(&m.hello, &from, flen); continue; }
        net_client *c = np_at(&from); if (!c) continue;   // a phone this run has not welcomed (the game started again): it says HELLO once it hears nothing back
        c->heard = now_ns(); c->packets++;
        if (m.kind == NXPD_INPUT) np_input(c, &m);
        else if (m.kind == NXPD_TOUCH) np_touch(c, &m);
        else if (m.kind == NXPD_PING) { uint8_t r[NXPD_HEADER + 8]; np_send_to(c, r, nxpd_pong(r, np_seq(), m.ping)); }
        else if (m.kind == NXPD_BYE) np_remove(c, "disconnected");
    }
}

static void np_tick(void) {
    uint64_t now = now_ns();
    if (g_pair.open && now >= g_pair.until) np_pair_renew();   // a code shown for 10 minutes makes way for a new one
    for (net_pad *p = g_pads, *next; p; p = next) {
        next = p->next; net_client *c = np_client(p);
        if (now - c->heard > NP_SILENT_NS) { np_remove(c, "went quiet: 1 s without a packet"); continue; }
        if (g_log && now - c->logged >= 1000000000ull) {
            c->logged = now;
            LOG("[nxpad] '%s': %llu packets, %llu motion samples in the last second; player %d, buttons 0x%llx 0x%llx", c->pad.name, (unsigned long long)c->packets,
                (unsigned long long)c->samples, np_player(p) + 1, (unsigned long long)c->pad.buttons[0], (unsigned long long)c->pad.buttons[1]);
            c->packets = c->samples = 0;
        }
    }
}

// ---- Rumble: the game's two motors per player, sent every 15 ms while they buzz to each phone that has a player ----
void dm_netpad_rumble(const dm_haptic_state *st) {
    if (!st || st->player < 0 || st->player >= DM_PLAYERS) return;
    os_unfair_lock_lock(&g_rv_lock); jc1_rumble_set(&g_rv[st->player], st->motor); os_unfair_lock_unlock(&g_rv_lock);
}
static void np_rumble_tick(void) {
    dm_vibration m[DM_PLAYERS][2]; uint32_t taken = 0;
    for (net_pad *p = g_pads; p; p = p->next) {
        net_client *c = np_client(p); int pl = np_player(p); if (pl < 0 || pl >= DM_PLAYERS) continue;
        if (!(taken >> pl & 1)) { taken |= 1u << pl; os_unfair_lock_lock(&g_rv_lock); jc1_rumble_take(&g_rv[pl], m[pl]); os_unfair_lock_unlock(&g_rv_lock); }
        dm_vibration v[2]; nxpd_rumble_pick(m[pl], p->sides, v);
        if (nxpd_rumble_on(v)) c->rumble_off = 3;   // a buzz goes every tick while it lasts, then three packets of silence, then nothing
        else if (c->rumble_off > 0) c->rumble_off--;
        else continue;
        uint8_t b[NXPD_HEADER + 32]; np_send_to(c, b, nxpd_rumble(b, np_seq(), v));
    }
}

// ---- Pads, as the front end reads them ----
static void np_input_of(const net_pad *p, nxpd_input *in) {
    memset(in, 0, sizeof *in); in->sides = p->sides;
    memcpy(in->buttons, p->buttons, sizeof in->buttons); memcpy(in->stick, p->stick, sizeof in->stick);
}
int dm_netpad_state(const net_pad *p, uint64_t *m, int32_t st[4]) {
    if (!p || !p->have) return 0;
    nxpd_input in; np_input_of(p, &in);
    return nxpd_pad_input(&in, m, st);
}
int dm_netpad_home(const net_pad *p) { return p && p->have && (p->extras & NXPD_EXTRA_HOME); }
void dm_netpad_ab(const net_pad *p, int *a, int *b) {
    uint64_t m; int32_t st[4]; if (!dm_netpad_state(p, &m, st)) return;
    *a |= (m & DM_BTN_A) != 0; *b |= (m & DM_BTN_B) != 0;
}
void dm_netpad_active(int on) {
    g_active = on;
    if (!on) for (net_pad *p = g_pads; p; p = p->next) { np_touch_lift(np_client(p)); int pl = np_player(p); if (pl >= 0) { dm_motion_clear_hid(pl); np_joy_release(pl, 0); np_joy_release(pl, 1); } }
}

// ---- Socket and Bonjour ----
// A dual-stack UDP socket (IPv4 phones arrive as mapped addresses), non-blocking, in Wi-Fi's voice class: the lowest latency the air gives
static int np_socket(int port) {
    int s = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP); if (s < 0) return -1;
    int no = 0; setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &no, sizeof no);
#ifdef SO_NET_SERVICE_TYPE
    int st = NET_SERVICE_TYPE_VO; setsockopt(s, SOL_SOCKET, SO_NET_SERVICE_TYPE, &st, sizeof st);
#endif
    struct sockaddr_in6 a; memset(&a, 0, sizeof a);
    a.sin6_len = sizeof a; a.sin6_family = AF_INET6; a.sin6_port = htons((uint16_t)port); a.sin6_addr = in6addr_any;
    if (bind(s, (struct sockaddr *)&a, sizeof a) < 0) { int e = errno; close(s); errno = e; return -1; }
    fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) | O_NONBLOCK);
    return s;
}
static void np_registered(DNSServiceRef ref, DNSServiceFlags flags, DNSServiceErrorType err, const char *name, const char *type, const char *domain, void *ctx) {
    (void)ref; (void)flags; (void)type; (void)domain; (void)ctx;
    if (err != kDNSServiceErr_NoError) LOG("[nxpad] the Bonjour advertisement failed (%d): a phone reaches the game only by this Mac's address and port %d (the QR code carries them)", (int)err, g_port);
    else LOG("[nxpad] advertised as '%s' on '%s'", name, g_mac_name);
}
// _nxpad._udp under the game's name, with TXT game (its name), v (the protocol), mac (this Mac's ID, which a paired phone knows it by), host (the Mac's name) and tid (the
// game's title ID, which the phone remembers its games by)
static void np_advertise(void) {
    TXTRecordRef txt; char buf[512], mac[17];
    snprintf(mac, sizeof mac, "%016llx", (unsigned long long)g_host_id);
    TXTRecordCreate(&txt, sizeof buf, buf);
    TXTRecordSetValue(&txt, "game", (uint8_t)strlen(g_title), g_title);
    TXTRecordSetValue(&txt, "v", 1, "2");
    TXTRecordSetValue(&txt, "mac", 16, mac);
    TXTRecordSetValue(&txt, "host", (uint8_t)strlen(g_mac_name), g_mac_name);
    if (g_tid[0]) TXTRecordSetValue(&txt, "tid", (uint8_t)strlen(g_tid), g_tid);
    char svc[64]; size_t k = nxpd_utf8_fit(g_title, sizeof svc - 1); memcpy(svc, g_title, k); svc[k] = 0;   // a service name holds 63 bytes
    DNSServiceErrorType e = DNSServiceRegister(&g_dns, 0, kDNSServiceInterfaceIndexAny, svc, "_nxpad._udp", NULL, NULL, htons((uint16_t)g_port),
                                               TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt), np_registered, NULL);
    TXTRecordDeallocate(&txt);
    if (e != kDNSServiceErr_NoError) { g_dns = NULL; np_registered(NULL, 0, e, "", "", "", NULL); return; }
    DNSServiceSetDispatchQueue(g_dns, dispatch_get_main_queue());
}
static dispatch_source_t np_timer(uint64_t ns, void (^fn)(void)) {
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)ns), ns, ns / 10);
    dispatch_source_set_event_handler(t, fn);
    return t;
}
// The game's name (the app's), its title ID and the Mac's name: each cut to what a TXT entry and PAIRED hold
static void np_names(void) {
    NSString *t = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"];
    const char *name = t.UTF8String ?: "nxnative"; size_t k = nxpd_utf8_fit(name, sizeof g_title - 1);   // a TXT entry holds 255 bytes, key included
    memcpy(g_title, name, k); g_title[k] = 0;
    id tid = [NSBundle.mainBundle objectForInfoDictionaryKey:@"DMTitleID"];
    snprintf(g_tid, sizeof g_tid, "%s", [tid isKindOfClass:NSString.class] ? [(NSString *)tid UTF8String] : "");
    NSString *mn = nil;
#if TARGET_OS_OSX
    mn = CFBridgingRelease(SCDynamicStoreCopyComputerName(NULL, NULL));   // "Manuel's MacBook Pro", as Sharing names it
#endif
    if (!mn.length) { char h[256] = ""; gethostname(h, sizeof h); char *dot = strchr(h, '.'); if (dot) *dot = 0; mn = @(h); }
    k = nxpd_utf8_fit(mn.UTF8String ?: "Mac", sizeof g_mac_name - 1); memcpy(g_mac_name, mn.UTF8String ?: "Mac", k); g_mac_name[k] = 0;
}
// The UDP socket, its timers and the advertisement, once
static int np_listen(void) {
    if (g_sock >= 0) return 1;
    if (!g_started) return 0;
    np_identity(); np_trust_load(1);
    int want = NXPD_PORT; const char *e = getenv("DM_NXPAD_PORT"); if (e && atoi(e) > 0 && atoi(e) < 65536) want = atoi(e);
    g_sock = np_socket(want);
    if (g_sock < 0 && errno == EADDRINUSE) {
        g_sock = np_socket(0);
        if (g_sock >= 0) LOG("[nxpad] UDP port %d is taken (another game running?): using one the system picked, which Bonjour carries", want);
    }
    if (g_sock < 0) { LOG("[nxpad] phone controllers are off: no UDP socket on port %d (%s)", want, strerror(errno)); return 0; }
    struct sockaddr_in6 a; socklen_t al = sizeof a;
    g_port = getsockname(g_sock, (struct sockaddr *)&a, &al) == 0 ? ntohs(a.sin6_port) : want;
    g_read = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)g_sock, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(g_read, ^{ np_receive(); });
    dispatch_resume(g_read);
    g_tick = np_timer(NP_TICK_NS, ^{ np_tick(); }); dispatch_resume(g_tick);
    g_rumble = np_timer(NP_RUMBLE_NS, ^{ np_rumble_tick(); });   // resumed while a phone is there (np_rumble_timer_sync)
    np_advertise();
    LOG("[nxpad] phone controllers: listening on UDP port %d, %d iPhone%s paired with this Mac", g_port, g_ntrust, g_ntrust == 1 ? "" : "s");
    return 1;
}

int dm_netpad_start(const dm_netpad_front *front) {
    g_front = *front; g_started = 1;
    const char *e = getenv("DM_NXPAD");
    g_mode = !e || !*e || !strcmp(e, "auto") ? NP_AUTO : atoi(e) ? NP_ON : NP_OFF;
    e = getenv("DM_NXPAD_LOG"); g_log = e && atoi(e);
    e = getenv("DM_PAD_MERGE"); g_joy = !(e && atoi(e));   // merged, every pad is player 1: no pad holds a game's Joy-Cons apart
    np_names();
    if (g_mode == NP_OFF) return 0;   // no socket, nothing advertised, so the system asks nothing; Pair iPhone… still listens for this run
    if (g_mode == NP_AUTO) {
        np_trust_load(1);
        if (!g_ntrust) { LOG("[nxpad] phone controllers: no iPhone is paired with this Mac yet, so nothing listens (Controllers > Pair iPhone… pairs one)"); return 0; }
    }
    return np_listen();
}

// ---- The Pair iPhone… window's side ----
// The Mac's IPv4 address the QR code carries, for a phone that does not see the Bonjour advertisement: en0 first (the built-in Wi-Fi or Ethernet), then another en*, never
// a loopback, link-local (169.254) or tunnel (VPN) one
static void np_address(char *out, size_t cap) {
    out[0] = 0; struct ifaddrs *ifs; if (getifaddrs(&ifs)) return;
    int best = 0;
    for (struct ifaddrs *i = ifs; i; i = i->ifa_next) {
        if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET || (i->ifa_flags & (IFF_UP | IFF_RUNNING)) != (IFF_UP | IFF_RUNNING) || (i->ifa_flags & IFF_LOOPBACK)) continue;
        struct in_addr a = ((const struct sockaddr_in *)(const void *)i->ifa_addr)->sin_addr;
        if ((ntohl(a.s_addr) >> 16) == 0xA9FE) continue;
        int score = !strcmp(i->ifa_name, "en0") ? 3 : !strncmp(i->ifa_name, "en", 2) ? 2 : (!strncmp(i->ifa_name, "utun", 4) || !strncmp(i->ifa_name, "ipsec", 5)) ? 0 : 1;
        if (score > best) { best = score; inet_ntop(AF_INET, &a, out, (socklen_t)cap); }
    }
    freeifaddrs(ifs);
}
int dm_netpad_pair_open(void (*changed)(int event, const char *phone)) {
    if (!np_listen()) return 0;
    if (!g_pair.open) {
        g_pair.open = 1; g_pair.wrong = 0; g_pair.last_len = 0; g_pair.changed = NULL;
        np_pair_renew();
        LOG("[nxpad] pairing window open on '%s' (UDP port %d)", g_mac_name, g_port);
    }
    g_pair.changed = changed;
    return 1;
}
void dm_netpad_pair_close(void) {
    if (!g_pair.open) return;
    memset(&g_pair, 0, sizeof g_pair);   // the code and token with it
    LOG("[nxpad] pairing window closed");
}
void dm_netpad_pair_get(dm_netpad_pairing *o) {
    memset(o, 0, sizeof *o);
    snprintf(o->mac, sizeof o->mac, "%s", g_mac_name); snprintf(o->game, sizeof o->game, "%s", g_title);
    o->listening = g_sock >= 0; o->port = g_port;
    if (!g_pair.open) return;
    snprintf(o->code, sizeof o->code, "%s", g_pair.code);
    o->code_locked = g_pair.wrong >= NP_CODE_MAX_WRONG;
    uint64_t now = now_ns(); o->seconds_left = g_pair.until > now ? (int)((g_pair.until - now) / 1000000000ull) : 0;
    char ip[INET_ADDRSTRLEN], mac[17], tok[2 * NXPD_TOKEN + 1]; np_address(ip, sizeof ip);
    snprintf(mac, sizeof mac, "%016llx", (unsigned long long)g_host_id); nxpd_hex(g_pair.token, NXPD_TOKEN, tok);
    NSURLComponents *u = [NSURLComponents new]; u.scheme = @"nxpad"; u.host = @"pair";
    NSMutableArray<NSURLQueryItem *> *q = [NSMutableArray arrayWithObjects:[NSURLQueryItem queryItemWithName:@"v" value:@"2"], [NSURLQueryItem queryItemWithName:@"m" value:@(mac)],
                                                                           [NSURLQueryItem queryItemWithName:@"k" value:@(tok)], nil];
    if (ip[0]) { [q addObject:[NSURLQueryItem queryItemWithName:@"a" value:@(ip)]]; [q addObject:[NSURLQueryItem queryItemWithName:@"p" value:[NSString stringWithFormat:@"%d", g_port]]]; }
    [q addObject:[NSURLQueryItem queryItemWithName:@"n" value:@(g_mac_name)]]; [q addObject:[NSURLQueryItem queryItemWithName:@"g" value:@(g_title)]];
    u.queryItems = q;
    snprintf(o->url, sizeof o->url, "%s", u.URL.absoluteString.UTF8String ?: "");
}
int dm_netpad_phones(dm_netpad_phone *out, int max) {   // newest pairing first
    np_trust_load(0);
    int n = 0;
    for (int i = g_ntrust - 1; i >= 0 && n < max; i--, n++) {
        dm_netpad_phone *p = &out[n]; memset(p, 0, sizeof *p);
        p->client = g_trust[i].client; p->when = g_trust[i].when; snprintf(p->name, sizeof p->name, "%s", g_trust[i].name); p->player = -1;
        for (net_pad *d = g_pads; d; d = d->next) if (d->client == p->client) { p->connected = 1; p->player = np_player(d); }
    }
    return n;
}
void dm_netpad_forget(uint64_t client) {
    np_trust_load(1);
    int j = 0; char name[NXPD_NAME + 1] = "";
    for (int i = 0; i < g_ntrust; i++) { if (g_trust[i].client == client) { memcpy(name, g_trust[i].name, sizeof name); continue; } g_trust[j++] = g_trust[i]; }
    if (j == g_ntrust) return;
    g_ntrust = j; np_trust_save();
    np_chal *c = np_chal_for(client, 0); if (c) c->client = 0;
    for (net_pad *p = g_pads, *next; p; p = next) {
        next = p->next; if (p->client != client) continue;
        uint8_t b[NXPD_HEADER + 1]; np_send_to(np_client(p), b, nxpd_byte(b, NXPD_KICK, np_seq(), NXPD_KICK_NOT_PAIRED));
        np_remove(np_client(p), "was unpaired");
    }
    LOG("[nxpad] '%s' is no longer paired with this Mac", name);
}
