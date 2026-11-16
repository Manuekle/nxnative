// NX Pad (dm/joypad): an iPhone that plays as Joy-Cons over the local network. This is its protocol, NXPD version 2 (dm/joypad/README.md, Protocol), and what the host makes of
// a packet: plain C on CommonCrypto's HMAC, no network, so tests/t_netpad.c checks it without one. The transport (a UDP socket, the Bonjour advertisement, the paired phones'
// file and the pairing code) is pad_net_apple.m.
//
// Every datagram is little endian and starts with a 12-byte header: the magic "NXPD", the version, the kind, two reserved bytes and the sender's sequence number. The phone sends
// PAIR (the code or the QR code's token the Mac shows proves it is in front of it), HELLO (its client ID, which Joy-Cons it stands for, its name, and its answer to the host's
// CHALLENGE), INPUT (each Joy-Con's NpadButtons and stick, Home and Capture, up to four six-axis samples), TOUCH (the fingers on the phone's touch area, for a game that reads
// the Switch's touch screen), PING and BYE; the host answers PAIRED, CHALLENGE, WELCOME (the player,
// the player lights, the game's name), RUMBLE (what each Joy-Con plays), LIGHTS, PONG and KICK. A phone's values are a real Joy-Con's: buttons as jc1_joy_buttons gives them,
// sticks in the upright Joy-Con's frame (y up), samples in its upright frame (x right, y toward the top, z out of the face; the gravity direction in G and rad/s), so a pad of
// them takes the same path as the original Joy-Cons read from HID (pad_jc1.h, pad_jc1_mac.h).
//
// Pairing (once per phone and Mac, for every game on that Mac): PAIR carries HMAC-SHA256(secret, "NXPD pair" host client nonce), the secret being the six digits the Mac shows
// or the QR code's 16-byte token; both sides then hold key = HMAC-SHA256(secret, "NXPD key" host client phone-nonce host-nonce), and PAIRED proves the host has it. Every HELLO
// after that answers a fresh CHALLENGE with HMAC-SHA256(key, "NXPD hello" host client challenge sides), so a phone that never paired, or a HELLO played back, takes no player.
// What it does not do: hide the traffic, or keep out someone who records a pairing by code on the same network and tries the million codes against it (the QR code's token
// is too long for that). INPUT is not signed: after a HELLO the host takes it from the phone's address only.
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <CommonCrypto/CommonHMAC.h>
#include "dm_input.h"
#include "hle_haptics.h"
#include "pad_jc1.h"

#define NXPD_MAGIC 0x4450584Eu   // "NXPD" in memory order
enum {
    NXPD_VERSION = 2,
    NXPD_PORT = 48620,
    NXPD_HEADER = 12,
    NXPD_SAMPLES = 4,
    NXPD_NAME = 32,
    NXPD_HELLO = 0x01, NXPD_INPUT = 0x02, NXPD_BYE = 0x03, NXPD_PING = 0x04, NXPD_PAIR = 0x05, NXPD_TOUCH = 0x06,
    NXPD_WELCOME = 0x81, NXPD_RUMBLE = 0x82, NXPD_LIGHTS = 0x83, NXPD_PONG = 0x84, NXPD_KICK = 0x85, NXPD_PAIRED = 0x86, NXPD_CHALLENGE = 0x87,
    NXPD_DEVICE_JOYCON = 1,
    NXPD_FEATURE_MOTION = 1, NXPD_FEATURE_RUMBLE = 2,
    NXPD_FEATURE_TOUCH = 4,   // in WELCOME's flags: this host takes TOUCH (a host from before it does not, and the phone sends none)
    NXPD_TOUCHES = 10,        // fingers one TOUCH carries (a phone's screen takes five)
    NXPD_EXTRA_HOME = 1, NXPD_EXTRA_CAPTURE = 2,
    NXPD_KICK_FULL = 1, NXPD_KICK_CLOSING = 2, NXPD_KICK_UNSUPPORTED = 3, NXPD_KICK_NOT_PAIRED = 4,
    NXPD_NO_PLAYER = 0xFF,   // WELCOME's player while the phone waits for its first button press (DM_PAD_PRESS_TO_JOIN)
    // Pairing
    NXPD_PAIR_CODE = 1, NXPD_PAIR_QR = 2,           // PAIR's method: the six digits typed, or the QR code's token
    NXPD_PAIRED_OK = 0, NXPD_PAIRED_WRONG = 1,      // PAIRED's result: paired; a wrong code (the Mac's tries left go down)
    NXPD_PAIRED_CLOSED = 2, NXPD_PAIRED_RENEWED = 3,// no pairing window open in this game; too many wrong codes, the Mac shows a new one
    NXPD_NONCE = 16, NXPD_HMAC = 32, NXPD_KEY = 32, NXPD_CODE = 6, NXPD_TOKEN = 16,
    NXPD_PAIR_TRIES = 5,                            // wrong codes a pairing code takes before the Mac makes a new one
};
// A phone may only press its own Joy-Con's buttons
#define NXPD_LEFT_BUTTONS (DM_BTN_LEFT | DM_BTN_UP | DM_BTN_RIGHT | DM_BTN_DOWN | DM_BTN_L | DM_BTN_ZL | DM_BTN_MINUS | DM_BTN_LS | DM_BTN_LSL | DM_BTN_LSR)
#define NXPD_RIGHT_BUTTONS (DM_BTN_A | DM_BTN_B | DM_BTN_X | DM_BTN_Y | DM_BTN_R | DM_BTN_ZR | DM_BTN_PLUS | DM_BTN_RS | DM_BTN_RSL | DM_BTN_RSR)
// Bounds a sample must keep: far beyond a hand's (a hard shake is a few G, a fast flick some 20 rad/s), so only garbage is dropped
#define NXPD_ACC_MAX 16.f
#define NXPD_ROT_MAX 64.f

typedef struct {
    uint64_t client; uint8_t sides, device, features; char name[NXPD_NAME + 1];
    int has_auth; uint8_t auth[NXPD_HMAC];   // the answer to the host's CHALLENGE (nxpd_hello_auth); a first HELLO has none
} nxpd_hello;
typedef struct { uint64_t client; uint8_t method; uint8_t nonce[NXPD_NONCE], proof[NXPD_HMAC]; char name[NXPD_NAME + 1]; } nxpd_pair;
typedef struct { uint32_t age_us; float acc[3], rot[3]; } nxpd_sample;
typedef struct {
    uint64_t time_ns;               // the phone's clock at sending; only the samples' ages are used
    uint8_t sides, extras;          // sides: bit 0 the left Joy-Con, bit 1 the right one (as dm_joy_attach); extras: NXPD_EXTRA_*
    uint64_t buttons[2];            // each Joy-Con's NpadButtons, the other Joy-Con's bits and those of a side not carried cleared
    int32_t stick[2][2];            // each Joy-Con's stick, -32767..32767, y up; 0 for a side not carried
    int samples;                    // the valid samples in s, oldest first (a sample out of bounds or not finite is left out)
    nxpd_sample s[NXPD_SAMPLES];
} nxpd_input;
typedef struct { uint8_t id; float x, y; } nxpd_touch;   // id: the finger's slot 0-15; x and y on the touch area, [0,1) from the top left
typedef struct { int n; nxpd_touch t[NXPD_TOUCHES]; } nxpd_touches;   // the whole set of fingers down; n = 0: all lifted
typedef struct {
    uint8_t kind; uint32_t seq;
    nxpd_touches touch;             // NXPD_TOUCH
    nxpd_hello hello;               // NXPD_HELLO
    nxpd_pair pair;                 // NXPD_PAIR
    nxpd_input input;               // NXPD_INPUT
    uint64_t ping;                  // NXPD_PING: the phone's time, echoed in PONG
} nxpd_msg;

static inline uint16_t nxpd_u16(const uint8_t *b) { return (uint16_t)(b[0] | b[1] << 8); }
static inline uint32_t nxpd_u32(const uint8_t *b) { return (uint32_t)b[0] | (uint32_t)b[1] << 8 | (uint32_t)b[2] << 16 | (uint32_t)b[3] << 24; }
static inline uint64_t nxpd_u64(const uint8_t *b) { return (uint64_t)nxpd_u32(b) | (uint64_t)nxpd_u32(b + 4) << 32; }
static inline float nxpd_f32(const uint8_t *b) { uint32_t u = nxpd_u32(b); float f; memcpy(&f, &u, 4); return f; }
static inline void nxpd_put16(uint8_t *b, uint16_t v) { b[0] = (uint8_t)v; b[1] = (uint8_t)(v >> 8); }
static inline void nxpd_put32(uint8_t *b, uint32_t v) { for (int i = 0; i < 4; i++) b[i] = (uint8_t)(v >> (8 * i)); }
static inline void nxpd_put64(uint8_t *b, uint64_t v) { nxpd_put32(b, (uint32_t)v); nxpd_put32(b + 4, (uint32_t)(v >> 32)); }
static inline void nxpd_putf(uint8_t *b, float f) { uint32_t u; memcpy(&u, &f, 4); nxpd_put32(b, u); }
static inline int32_t nxpd_axis(int16_t v) { return v < -DM_STICK_MAX ? -DM_STICK_MAX : v; }   // -32768 is no stick value

// A sequence number later than the last one taken (they wrap): an older datagram that arrives late is dropped
static inline int nxpd_seq_newer(uint32_t seq, uint32_t last) { return (int32_t)(seq - last) > 0; }

static inline int nxpd_sample_ok(const nxpd_sample *s) {
    for (int i = 0; i < 3; i++) {
        if (!isfinite(s->acc[i]) || !isfinite(s->rot[i]) || fabsf(s->acc[i]) > NXPD_ACC_MAX || fabsf(s->rot[i]) > NXPD_ROT_MAX) return 0;
    }
    return 1;
}

// A name from a phone: a length byte and UTF-8, at most NXPD_NAME bytes kept, control characters made spaces (it goes into the log and the paired phones' file). Returns the
// bytes the string took in the datagram (length byte included), or 0 when the datagram ends before its length byte
static inline size_t nxpd_name(const uint8_t *p, size_t len, char out[NXPD_NAME + 1]) {
    out[0] = 0; if (!len) return 0;
    size_t k = p[0]; if (k > NXPD_NAME) k = NXPD_NAME; if (k > len - 1) k = len - 1;
    memcpy(out, p + 1, k); out[k] = 0;
    for (size_t i = 0; i < k; i++) if ((unsigned char)out[i] < 0x20 || out[i] == 0x7F) out[i] = ' ';
    return 1 + (size_t)p[0];
}

// A datagram from a phone; 0 for anything else (another protocol, a version this host does not speak, a kind only the host sends, a short payload)
static inline int nxpd_parse(const uint8_t *b, size_t n, nxpd_msg *m) {
    memset(m, 0, sizeof *m);
    if (n < NXPD_HEADER || nxpd_u32(b) != NXPD_MAGIC || b[4] != NXPD_VERSION) return 0;
    m->kind = b[5]; m->seq = nxpd_u32(b + 8);
    const uint8_t *p = b + NXPD_HEADER; size_t len = n - NXPD_HEADER;
    switch (m->kind) {
    case NXPD_HELLO: {
        if (len < 13) return 0;
        nxpd_hello *h = &m->hello;
        h->client = nxpd_u64(p); h->sides = p[8] & 3; h->device = p[9]; h->features = p[10];
        size_t used = nxpd_name(p + 12, len - 12, h->name);
        if (p[12] <= NXPD_NAME && 12 + used + NXPD_HMAC <= len) { h->has_auth = 1; memcpy(h->auth, p + 12 + used, NXPD_HMAC); }   // the answer follows the whole name
        return h->client != 0 && h->sides != 0;
    }
    case NXPD_PAIR: {
        if (len < 8 + 4 + NXPD_NONCE + NXPD_HMAC + 1) return 0;
        nxpd_pair *q = &m->pair;
        q->client = nxpd_u64(p); q->method = p[8];
        memcpy(q->nonce, p + 12, NXPD_NONCE); memcpy(q->proof, p + 12 + NXPD_NONCE, NXPD_HMAC);
        size_t at = 12 + NXPD_NONCE + NXPD_HMAC; nxpd_name(p + at, len - at, q->name);
        return q->client != 0 && (q->method == NXPD_PAIR_CODE || q->method == NXPD_PAIR_QR);
    }
    case NXPD_INPUT: {
        if (len < 32) return 0;
        nxpd_input *in = &m->input;
        in->time_ns = nxpd_u64(p); in->sides = p[8] & 3; in->extras = p[9] & (NXPD_EXTRA_HOME | NXPD_EXTRA_CAPTURE);
        static const uint64_t mask[2] = {NXPD_LEFT_BUTTONS, NXPD_RIGHT_BUTTONS};
        for (int k = 0; k < 2; k++) {
            const uint8_t *q = p + 12 + 8 * k;
            if (!(in->sides >> k & 1)) continue;
            in->buttons[k] = nxpd_u32(q) & mask[k];
            in->stick[k][0] = nxpd_axis((int16_t)nxpd_u16(q + 4)); in->stick[k][1] = nxpd_axis((int16_t)nxpd_u16(q + 6));
        }
        int count = p[28]; if (count > NXPD_SAMPLES) count = NXPD_SAMPLES;
        if ((size_t)count * 28 > len - 32) count = (int)((len - 32) / 28);
        for (int i = 0; i < count; i++) {
            const uint8_t *q = p + 32 + 28 * i; nxpd_sample s;
            s.age_us = nxpd_u32(q);
            for (int j = 0; j < 3; j++) { s.acc[j] = nxpd_f32(q + 4 + 4 * j); s.rot[j] = nxpd_f32(q + 16 + 4 * j); }
            if (nxpd_sample_ok(&s)) in->s[in->samples++] = s;
        }
        return in->sides != 0;
    }
    case NXPD_TOUCH: {   // a count, then for each finger its slot (one byte) and x and y (16 bits each, 65536 to the whole area)
        if (len < 1) return 0;
        size_t count = p[0];
        if (count > NXPD_TOUCHES || 1 + 5 * count > len) return 0;
        uint32_t used = 0;
        for (size_t i = 0; i < count; i++) {
            const uint8_t *q = p + 1 + 5 * i; uint8_t id = q[0] & 15;
            if (used >> id & 1) continue;   // a slot twice: the first counts
            used |= 1u << id;
            nxpd_touch *t = &m->touch.t[m->touch.n++];
            t->id = id; t->x = (float)nxpd_u16(q + 1) / 65536.f; t->y = (float)nxpd_u16(q + 3) / 65536.f;
        }
        return 1;
    }
    case NXPD_PING:
        if (len < 8) return 0;
        m->ping = nxpd_u64(p);
        return 1;
    case NXPD_BYE:
        return 1;
    default:
        return 0;
    }
}

// How many bytes of s fit in cap without cutting a UTF-8 sequence in two
static inline size_t nxpd_utf8_fit(const char *s, size_t cap) {
    size_t n = s ? strlen(s) : 0; if (n <= cap) return n;
    size_t k = cap; while (k > 0 && ((unsigned char)s[k] & 0xC0) == 0x80) k--;   // s[k], the first byte left out, must start a character
    return k;
}
// The header of a reply; returns its length
static inline size_t nxpd_header(uint8_t *out, uint8_t kind, uint32_t seq) {
    nxpd_put32(out, NXPD_MAGIC); out[4] = NXPD_VERSION; out[5] = kind; nxpd_put16(out + 6, 0); nxpd_put32(out + 8, seq);
    return NXPD_HEADER;
}
// WELCOME: the player (NXPD_NO_PLAYER while it waits for a press), the sides taken, the player lights, feature flags and the game's name (cut to what fits, at a character
// boundary). out needs NXPD_HEADER + 5 + 255 bytes for any name
static inline size_t nxpd_welcome(uint8_t *out, uint32_t seq, int player, uint8_t sides, uint8_t lights, uint8_t flags, const char *title) {
    size_t n = nxpd_header(out, NXPD_WELCOME, seq);
    out[n++] = player >= 0 && player < DM_PLAYERS ? (uint8_t)player : NXPD_NO_PLAYER;
    out[n++] = sides; out[n++] = lights; out[n++] = flags;
    size_t k = nxpd_utf8_fit(title, 255);
    out[n++] = (uint8_t)k; if (k) memcpy(out + n, title, k);
    return n + k;
}
// RUMBLE: what each Joy-Con plays, the left one's then the right one's (low band amplitude and frequency, high band amplitude and frequency). out needs NXPD_HEADER + 32 bytes
static inline size_t nxpd_rumble(uint8_t *out, uint32_t seq, const dm_vibration v[2]) {
    size_t n = nxpd_header(out, NXPD_RUMBLE, seq);
    for (int k = 0; k < 2; k++) {
        float f[4] = {v[k].amplitude_low, v[k].frequency_low, v[k].amplitude_high, v[k].frequency_high};
        for (int i = 0; i < 4; i++) { nxpd_putf(out + n, isfinite(f[i]) ? f[i] : 0.f); n += 4; }
    }
    return n;
}
static inline size_t nxpd_byte(uint8_t *out, uint8_t kind, uint32_t seq, uint8_t value) {   // LIGHTS (the pattern) and KICK (the reason)
    size_t n = nxpd_header(out, kind, seq); out[n++] = value; return n;
}
static inline size_t nxpd_pong(uint8_t *out, uint32_t seq, uint64_t echo) {
    size_t n = nxpd_header(out, NXPD_PONG, seq); nxpd_put64(out + n, echo); return n + 8;
}
static inline size_t nxpd_put_string(uint8_t *out, const char *s) {   // a length byte and UTF-8 cut at a character boundary
    size_t k = nxpd_utf8_fit(s, 255); out[0] = (uint8_t)k; if (k) memcpy(out + 1, s, k); return 1 + k;
}

// ---- Pairing ----
// HMAC-SHA256 of label (its bytes, no terminator), host and client (8 bytes each, little endian), then extra
static inline void nxpd_hmac(const void *key, size_t keylen, const char *label, uint64_t host, uint64_t client, const uint8_t *extra, size_t extralen, uint8_t out[NXPD_HMAC]) {
    uint8_t msg[64]; size_t n = strlen(label);
    memcpy(msg, label, n); nxpd_put64(msg + n, host); nxpd_put64(msg + n + 8, client); n += 16;
    if (extralen) memcpy(msg + n, extra, extralen);
    CCHmac(kCCHmacAlgSHA256, key, keylen, msg, n + extralen, out);
}
// What the phone proves with PAIR; secret: the six digits as text, or the QR code's token
static inline void nxpd_pair_proof(const uint8_t *secret, size_t slen, uint64_t host, uint64_t client, const uint8_t nonce[NXPD_NONCE], uint8_t out[NXPD_HMAC]) {
    nxpd_hmac(secret, slen, "NXPD pair", host, client, nonce, NXPD_NONCE, out);
}
// The pairing's key, which both sides keep
static inline void nxpd_pair_key(const uint8_t *secret, size_t slen, uint64_t host, uint64_t client, const uint8_t phone_nonce[NXPD_NONCE], const uint8_t host_nonce[NXPD_NONCE],
                                 uint8_t key[NXPD_KEY]) {
    uint8_t both[2 * NXPD_NONCE]; memcpy(both, phone_nonce, NXPD_NONCE); memcpy(both + NXPD_NONCE, host_nonce, NXPD_NONCE);
    nxpd_hmac(secret, slen, "NXPD key", host, client, both, sizeof both, key);
}
// PAIRED's proof that the host holds the key
static inline void nxpd_pair_confirm(const uint8_t key[NXPD_KEY], uint64_t host, uint64_t client, uint8_t out[NXPD_HMAC]) {
    nxpd_hmac(key, NXPD_KEY, "NXPD paired", host, client, NULL, 0, out);
}
// A HELLO's answer to the challenge; sides are part of it, so a mode change cannot be forged either
static inline void nxpd_hello_auth(const uint8_t key[NXPD_KEY], uint64_t host, uint64_t client, const uint8_t challenge[NXPD_NONCE], uint8_t sides, uint8_t out[NXPD_HMAC]) {
    uint8_t extra[NXPD_NONCE + 1]; memcpy(extra, challenge, NXPD_NONCE); extra[NXPD_NONCE] = sides;
    nxpd_hmac(key, NXPD_KEY, "NXPD hello", host, client, extra, sizeof extra, out);
}
static inline int nxpd_hmac_equal(const uint8_t *a, const uint8_t *b) {   // in constant time
    uint8_t d = 0; for (int i = 0; i < NXPD_HMAC; i++) d |= a[i] ^ b[i]; return d == 0;
}
// PAIRED: the result, the host's ID and nonce, the confirmation (zeros unless paired), the Mac's name and the game's. out needs NXPD_HEADER + 64 + 2 * 256 bytes
static inline size_t nxpd_paired(uint8_t *out, uint32_t seq, uint8_t result, uint64_t host, const uint8_t nonce[NXPD_NONCE], const uint8_t confirm[NXPD_HMAC],
                                 const char *mac_name, const char *game) {
    size_t n = nxpd_header(out, NXPD_PAIRED, seq);
    out[n] = result; memset(out + n + 1, 0, 7); n += 8;
    nxpd_put64(out + n, host); n += 8;
    if (nonce) memcpy(out + n, nonce, NXPD_NONCE); else memset(out + n, 0, NXPD_NONCE);
    n += NXPD_NONCE;
    if (confirm) memcpy(out + n, confirm, NXPD_HMAC); else memset(out + n, 0, NXPD_HMAC);
    n += NXPD_HMAC;
    n += nxpd_put_string(out + n, mac_name);
    return n + nxpd_put_string(out + n, game);
}
// CHALLENGE: the host's ID and a fresh nonce the next HELLO answers. out needs NXPD_HEADER + 24 bytes
static inline size_t nxpd_challenge(uint8_t *out, uint32_t seq, uint64_t host, const uint8_t nonce[NXPD_NONCE]) {
    size_t n = nxpd_header(out, NXPD_CHALLENGE, seq); nxpd_put64(out + n, host); memcpy(out + n + 8, nonce, NXPD_NONCE); return n + 8 + NXPD_NONCE;
}

// ---- The paired phones' file: one line each, "<client, 16 hex digits>\t<key, 64 hex digits>\t<when, Unix seconds>\t<the phone's name>" ----
typedef struct { uint64_t client; uint8_t key[NXPD_KEY]; int64_t when; char name[NXPD_NAME + 1]; } nxpd_trust;
static inline int nxpd_hexval(char c) { return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1; }
static inline int nxpd_unhex(const char *s, uint8_t *out, size_t n) {   // exactly 2n hex digits
    for (size_t i = 0; i < n; i++) { int h = nxpd_hexval(s[2 * i]), l = h < 0 ? -1 : nxpd_hexval(s[2 * i + 1]); if (l < 0) return 0; out[i] = (uint8_t)(h << 4 | l); }
    return 1;
}
static inline void nxpd_hex(const uint8_t *b, size_t n, char *out) {   // out needs 2n + 1
    static const char d[] = "0123456789abcdef";
    for (size_t i = 0; i < n; i++) { out[2 * i] = d[b[i] >> 4]; out[2 * i + 1] = d[b[i] & 15]; }
    out[2 * n] = 0;
}
// A line of the file (its newline may still be there); 0 for a line that is not one
static inline int nxpd_trust_parse(const char *line, nxpd_trust *t) {
    memset(t, 0, sizeof *t);
    uint8_t c[8]; const char *p = line;
    if (!nxpd_unhex(p, c, 8) || p[16] != '\t') return 0;
    for (int i = 0; i < 8; i++) t->client = t->client << 8 | c[i];   // written big endian: the ID as one reads it in a log
    p += 17;
    if (!nxpd_unhex(p, t->key, NXPD_KEY) || p[2 * NXPD_KEY] != '\t') return 0;
    p += 2 * NXPD_KEY + 1;
    char *end; t->when = strtoll(p, &end, 10); if (end == p || *end != '\t') return 0;
    p = end + 1;
    size_t k = strcspn(p, "\r\n"); if (k > NXPD_NAME) k = nxpd_utf8_fit(p, NXPD_NAME);
    memcpy(t->name, p, k); t->name[k] = 0;
    for (size_t i = 0; i < k; i++) if ((unsigned char)t->name[i] < 0x20) t->name[i] = ' ';
    return t->client != 0;
}
static inline int nxpd_trust_format(const nxpd_trust *t, char *out, size_t cap) {   // the line with its newline; returns its length (or what snprintf says)
    char key[2 * NXPD_KEY + 1]; nxpd_hex(t->key, NXPD_KEY, key);
    char name[NXPD_NAME + 1]; size_t k = nxpd_utf8_fit(t->name, NXPD_NAME); memcpy(name, t->name, k); name[k] = 0;
    for (size_t i = 0; i < k; i++) if ((unsigned char)name[i] < 0x20) name[i] = ' ';
    return snprintf(out, cap, "%016llx\t%s\t%lld\t%s\n", (unsigned long long)t->client, key, (long long)t->when, name);
}

// The Switch's player light patterns, players 1 to 8 (bit 0 the first light), as the Joy-Con 2s show them (switch2_proto.h s2_led_pattern)
static const uint8_t nxpd_lights[DM_PLAYERS] = {0x01, 0x03, 0x07, 0x0F, 0x09, 0x05, 0x0D, 0x06};
static inline uint8_t nxpd_player_lights(int player) { return player >= 0 && player < DM_PLAYERS ? nxpd_lights[player] : 0; }

// A phone's state as one whole controller, for a game that supports no Joy-Con style (dm_pad_set_player): a pair is a Pro Controller, a single Joy-Con the one held sideways
// (pad_jc1.h jc1_pad_input). 0: the phone has sent no input yet
static inline int nxpd_pad_input(const nxpd_input *in, uint64_t *m, int32_t st[4]) {
    int have[2] = {in->sides & 1, in->sides >> 1 & 1};
    return jc1_pad_input(have, in->buttons, (const int32_t (*)[2])in->stick, m, st);
}
// A sample for the pad's merged six-axis stream (dm_motion_set_hid): a pair's as it is, a single Joy-Con's in the frame of one held sideways (pad_jc1.h jc1_sideways_vec)
static inline void nxpd_merged_sample(const nxpd_sample *s, uint8_t sides, float acc[3], float rot[3]) {
    if (sides == 3) { memcpy(acc, s->acc, sizeof s->acc); memcpy(rot, s->rot, sizeof s->rot); return; }
    int right = sides == 2;
    jc1_sideways_vec(s->acc, right, acc); jc1_sideways_vec(s->rot, right, rot);
}
// What the phone's Joy-Cons play of their player's two motors: each its own side's in a pair, the stronger of the two in each band when alone (pad_jc1.h jc1_rumble_pick)
static inline void nxpd_rumble_pick(const dm_vibration m[2], uint8_t sides, dm_vibration out[2]) {
    for (int k = 0; k < 2; k++) {
        if (sides >> k & 1) out[k] = jc1_rumble_pick(m, k, sides == 3);
        else memset(&out[k], 0, sizeof out[k]);
    }
}
static inline int nxpd_rumble_on(const dm_vibration v[2]) { return jc1_vibration_on(&v[0]) || jc1_vibration_on(&v[1]); }
