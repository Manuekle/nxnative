// pad_net.h: the NX Pad phone protocol (NXPD 2) as the host reads and writes it: HELLO (with and without its answer to the challenge), PAIR, INPUT (each Joy-Con's own buttons
// only, sticks, samples kept or dropped), PING and BYE; WELCOME, RUMBLE, LIGHTS, PONG, KICK, PAIRED and CHALLENGE; the pairing's HMACs (against values Python's hmac gives, the
// same the phone's CryptoKit and dm/joypad/tools/pad_listen.py compute); the paired phones' file lines; sequence order; and a phone's state as one whole controller, its merged
// sample and its rumble, the way original Joy-Cons give them.
#include "../pad_net.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static size_t header(uint8_t *b, uint8_t kind, uint32_t seq) {
    nxpd_put32(b, NXPD_MAGIC); b[4] = NXPD_VERSION; b[5] = kind; b[6] = b[7] = 0; nxpd_put32(b + 8, seq); return NXPD_HEADER;
}
static size_t hello(uint8_t *b, uint64_t client, uint8_t sides, uint8_t device, const char *name, size_t namelen) {
    size_t n = header(b, NXPD_HELLO, 7);
    nxpd_put64(b + n, client); b[n + 8] = sides; b[n + 9] = device; b[n + 10] = NXPD_FEATURE_MOTION | NXPD_FEATURE_RUMBLE; b[n + 11] = 0;
    b[n + 12] = (uint8_t)namelen; memcpy(b + n + 13, name, namelen);
    return n + 13 + namelen;
}
static size_t input(uint8_t *b, uint32_t seq, uint8_t sides, uint8_t extras, uint32_t lb, int16_t lx, int16_t ly, uint32_t rb, int16_t rx, int16_t ry,
                    int count, const float (*samples)[6]) {
    size_t n = header(b, NXPD_INPUT, seq);
    nxpd_put64(b + n, 123456789); b[n + 8] = sides; b[n + 9] = extras; nxpd_put16(b + n + 10, 0);
    nxpd_put32(b + n + 12, lb); nxpd_put16(b + n + 16, (uint16_t)lx); nxpd_put16(b + n + 18, (uint16_t)ly);
    nxpd_put32(b + n + 20, rb); nxpd_put16(b + n + 24, (uint16_t)rx); nxpd_put16(b + n + 26, (uint16_t)ry);
    b[n + 28] = (uint8_t)count; b[n + 29] = b[n + 30] = b[n + 31] = 0;
    size_t k = n + 32;
    for (int i = 0; samples && i < count; i++) {
        nxpd_put32(b + k, (uint32_t)(1000 * (count - i))); k += 4;
        for (int j = 0; j < 6; j++) { nxpd_putf(b + k, samples[i][j]); k += 4; }
    }
    return k;
}

int main(void) {
    uint8_t b[512]; nxpd_msg m;

    // HELLO: the client, its Joy-Cons, its device and a name cut to 32 bytes with control characters made spaces (it goes into the log)
    char name[40]; memset(name, 'x', sizeof name); name[3] = '\n';
    size_t n = hello(b, 0x1122334455667788ull, 3, NXPD_DEVICE_JOYCON, name, sizeof name);
    assert(nxpd_parse(b, n, &m) && m.kind == NXPD_HELLO && m.seq == 7);
    assert(m.hello.client == 0x1122334455667788ull && m.hello.sides == 3 && m.hello.device == NXPD_DEVICE_JOYCON);
    assert(strlen(m.hello.name) == NXPD_NAME && m.hello.name[3] == ' ' && m.hello.name[0] == 'x');
    n = hello(b, 1, 2, NXPD_DEVICE_JOYCON, "iPhone", 6);
    assert(nxpd_parse(b, n, &m) && !strcmp(m.hello.name, "iPhone") && m.hello.sides == 2);
    assert(nxpd_parse(b, n - 3, &m) && !strcmp(m.hello.name, "iPh"));   // a name longer than the datagram is cut to what came
    n = hello(b, 0, 3, NXPD_DEVICE_JOYCON, "a", 1); assert(!nxpd_parse(b, n, &m));   // client 0 is no client
    n = hello(b, 5, 0, NXPD_DEVICE_JOYCON, "a", 1); assert(!nxpd_parse(b, n, &m));   // no Joy-Con
    n = hello(b, 5, 3, NXPD_DEVICE_JOYCON, "a", 1); assert(!nxpd_parse(b, NXPD_HEADER + 12, &m));   // short
    assert(nxpd_parse(b, n, &m) && !m.hello.has_auth);   // a first HELLO: no answer
    uint8_t ans[NXPD_HMAC]; for (int i = 0; i < NXPD_HMAC; i++) ans[i] = (uint8_t)(0xA0 + i);
    memcpy(b + n, ans, NXPD_HMAC);
    assert(nxpd_parse(b, n + NXPD_HMAC, &m) && m.hello.has_auth && !memcmp(m.hello.auth, ans, NXPD_HMAC) && !strcmp(m.hello.name, "a"));
    assert(nxpd_parse(b, n + NXPD_HMAC - 1, &m) && !m.hello.has_auth);   // an answer cut short is none

    // Not a phone's datagram: another magic, another version, a host's kind
    n = hello(b, 5, 3, NXPD_DEVICE_JOYCON, "a", 1);
    b[0] ^= 1; assert(!nxpd_parse(b, n, &m)); b[0] ^= 1;
    b[4] = 1; assert(!nxpd_parse(b, n, &m)); b[4] = NXPD_VERSION;   // version 1 phones knew no pairing
    b[5] = NXPD_WELCOME; assert(!nxpd_parse(b, n, &m));

    // INPUT: each Joy-Con keeps its own buttons only, a side not carried reads nothing, -32768 is -32767, Home and Capture come through
    uint32_t every = 0xffffffffu;
    n = input(b, 9, 1, NXPD_EXTRA_HOME | 0x80, every, -32768, 1000, every, 500, -500, 0, NULL);
    assert(nxpd_parse(b, n, &m) && m.kind == NXPD_INPUT && m.seq == 9);
    assert(m.input.sides == 1 && m.input.extras == NXPD_EXTRA_HOME && m.input.time_ns == 123456789);
    assert(m.input.buttons[0] == NXPD_LEFT_BUTTONS && m.input.buttons[1] == 0);
    assert(m.input.stick[0][0] == -DM_STICK_MAX && m.input.stick[0][1] == 1000 && m.input.stick[1][0] == 0 && m.input.stick[1][1] == 0);
    n = input(b, 10, 3, 0, DM_BTN_A | DM_BTN_UP | DM_BTN_LSL, 0, 0, DM_BTN_A | DM_BTN_UP | DM_BTN_RSR, 0, 0, 0, NULL);
    assert(nxpd_parse(b, n, &m) && m.input.buttons[0] == (DM_BTN_UP | DM_BTN_LSL) && m.input.buttons[1] == (DM_BTN_A | DM_BTN_RSR));
    assert(!nxpd_parse(b, NXPD_HEADER + 31, &m));   // shorter than the fixed part

    // Samples: oldest first; one not finite or out of bounds is left out; a count beyond four, or beyond the datagram, is cut
    const float s[5][6] = {{0, -1, 0, 0.1f, 0.2f, 0.3f}, {0, 0, -1, 0, 0, 0}, {NAN, 0, 0, 0, 0, 0}, {0, 0, 99, 0, 0, 0}, {1, 0, 0, 0, 0, 1}};
    n = input(b, 11, 3, 0, 0, 0, 0, 0, 0, 0, 5, s);
    assert(nxpd_parse(b, n, &m) && m.input.samples == 2);   // the first four only, the NaN and the 99 G left out
    assert(m.input.s[0].acc[1] == -1.f && m.input.s[0].rot[2] == 0.3f && m.input.s[0].age_us == 5000 && m.input.s[1].acc[2] == -1.f);
    n = input(b, 12, 3, 0, 0, 0, 0, 0, 0, 0, 2, s);
    assert(nxpd_parse(b, n - 1, &m) && m.input.samples == 1);   // the second one did not fully come

    // PING and BYE
    n = header(b, NXPD_PING, 13); nxpd_put64(b + n, 0xabcdefull); n += 8;
    assert(nxpd_parse(b, n, &m) && m.kind == NXPD_PING && m.ping == 0xabcdefull);
    assert(!nxpd_parse(b, n - 1, &m));
    n = header(b, NXPD_BYE, 14); assert(nxpd_parse(b, n, &m) && m.kind == NXPD_BYE);

    // PAIR: the client, the method, the nonce, the proof and the phone's name
    n = header(b, NXPD_PAIR, 15); nxpd_put64(b + n, 0x42); b[n + 8] = NXPD_PAIR_QR; b[n + 9] = b[n + 10] = b[n + 11] = 0;
    for (int i = 0; i < NXPD_NONCE; i++) b[n + 12 + i] = (uint8_t)i;
    for (int i = 0; i < NXPD_HMAC; i++) b[n + 28 + i] = (uint8_t)(0x80 + i);
    b[n + 60] = 6; memcpy(b + n + 61, "Manu\x01l", 6); n += 67;
    assert(nxpd_parse(b, n, &m) && m.kind == NXPD_PAIR && m.pair.client == 0x42 && m.pair.method == NXPD_PAIR_QR);
    assert(m.pair.nonce[15] == 15 && m.pair.proof[0] == 0x80 && m.pair.proof[31] == 0x9F && !strcmp(m.pair.name, "Manu l"));
    b[NXPD_HEADER + 8] = 7; assert(!nxpd_parse(b, n, &m)); b[NXPD_HEADER + 8] = NXPD_PAIR_CODE;   // no such method
    assert(nxpd_parse(b, NXPD_HEADER + 61, &m) && !m.pair.name[0]);   // a name that did not come
    assert(!nxpd_parse(b, NXPD_HEADER + 60, &m));                       // nor its length byte

    // The pairing's HMACs: SHA-256's own check value (RFC 4231, case 2), then each step against Python's hmac on the same inputs, for the six digits and for a QR token
    uint8_t mac[NXPD_HMAC], hx[2 * NXPD_HMAC + 1];
    CCHmac(kCCHmacAlgSHA256, "Jefe", 4, "what do ya want for nothing?", 28, mac); nxpd_hex(mac, NXPD_HMAC, (char *)hx);
    assert(!strcmp((char *)hx, "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"));
    uint64_t host = 0x0102030405060708ull, client = 0x1122334455667788ull; uint8_t pn[NXPD_NONCE], hn[NXPD_NONCE], chal[NXPD_NONCE], tok[NXPD_TOKEN], key[NXPD_KEY];
    for (int i = 0; i < NXPD_NONCE; i++) { pn[i] = (uint8_t)i; hn[i] = (uint8_t)(16 + i); chal[i] = (uint8_t)(32 + i); tok[i] = (uint8_t)(100 + i); }
    static const char *want[2][4] = {
        {"21197fdb2434daa1f8e28bd4453f1ac3b41f727c27c2e322c3607a82d1b8707d", "6b00942cb2fdb8a08978d4b2b10cfffcab912295b4f8a68772397cb0cc963058",
         "a48702f8ebcbd4e17b21e229e68669e0f6534a7738dc5b3ad776b25ab90a48e8", "d44683cc469965e8f414f030e2e21412c7298115e8b0deccbf2c4f9e3292ea73"},
        {"a903c04b51ffac435d0ec219e054e2657fcfec461679c8b4abf0bacb963dc653", "5963fafa24620e7689d7a2bb45abc13d32b1a77f242155fcb7c3c28109afd6c6",
         "2c3ccebecc2344ea6837fed763ac991594e7467498e44e568b94240acb215139", "7da6434a37c70c82ab7414b0bd3c1872ce1b06615a1602a75756dd73ddf75c99"}};
    for (int t = 0; t < 2; t++) {
        const uint8_t *sec = t ? tok : (const uint8_t *)"123456"; size_t sl = t ? NXPD_TOKEN : NXPD_CODE;
        nxpd_pair_proof(sec, sl, host, client, pn, mac); nxpd_hex(mac, NXPD_HMAC, (char *)hx); assert(!strcmp((char *)hx, want[t][0]));
        nxpd_pair_key(sec, sl, host, client, pn, hn, key); nxpd_hex(key, NXPD_KEY, (char *)hx); assert(!strcmp((char *)hx, want[t][1]));
        nxpd_pair_confirm(key, host, client, mac); nxpd_hex(mac, NXPD_HMAC, (char *)hx); assert(!strcmp((char *)hx, want[t][2]));
        nxpd_hello_auth(key, host, client, chal, 3, mac); nxpd_hex(mac, NXPD_HMAC, (char *)hx); assert(!strcmp((char *)hx, want[t][3]));
        uint8_t other[NXPD_HMAC]; nxpd_hello_auth(key, host, client, chal, 1, other); assert(!nxpd_hmac_equal(mac, other) && nxpd_hmac_equal(mac, mac));   // the sides count
    }

    // PAIRED and CHALLENGE
    n = nxpd_paired(b, 51, NXPD_PAIRED_OK, host, hn, mac, "Manu's Mac", "Zelda");
    assert(b[5] == NXPD_PAIRED && b[12] == NXPD_PAIRED_OK && nxpd_u64(b + 20) == host && !memcmp(b + 28, hn, NXPD_NONCE) && !memcmp(b + 44, mac, NXPD_HMAC));
    assert(b[76] == 10 && !memcmp(b + 77, "Manu's Mac", 10) && b[87] == 5 && !memcmp(b + 88, "Zelda", 5) && n == NXPD_HEADER + 81);
    n = nxpd_paired(b, 52, NXPD_PAIRED_WRONG, host, NULL, NULL, NULL, "");
    assert(b[12] == NXPD_PAIRED_WRONG && b[28] == 0 && b[75] == 0 && b[76] == 0 && b[77] == 0 && n == NXPD_HEADER + 66);
    n = nxpd_challenge(b, 53, host, chal); assert(n == NXPD_HEADER + 24 && b[5] == NXPD_CHALLENGE && nxpd_u64(b + 12) == host && !memcmp(b + 20, chal, NXPD_NONCE));

    // The paired phones' file: a line and back; anything else is no line
    nxpd_trust tr = {0}, back; tr.client = 0x00ab00cd00ef0012ull; memcpy(tr.key, key, NXPD_KEY); tr.when = 1794000000; strcpy(tr.name, "iPhone de Manuel");
    char line[256]; assert(nxpd_trust_format(&tr, line, sizeof line) > 0 && !strncmp(line, "00ab00cd00ef0012\t", 17) && line[strlen(line) - 1] == '\n');
    assert(nxpd_trust_parse(line, &back) && back.client == tr.client && !memcmp(back.key, key, NXPD_KEY) && back.when == tr.when && !strcmp(back.name, "iPhone de Manuel"));
    line[3] = 'x'; assert(!nxpd_trust_parse(line, &back));
    assert(!nxpd_trust_parse("", &back) && !nxpd_trust_parse("# comment\n", &back));

    // Sequence numbers wrap
    assert(nxpd_seq_newer(2, 1) && !nxpd_seq_newer(1, 1) && !nxpd_seq_newer(1, 2) && nxpd_seq_newer(3, 0xfffffffeu) && !nxpd_seq_newer(0xfffffffeu, 3));

    // WELCOME: player, sides, lights, flags and the name, cut at a character boundary
    char title[300]; memset(title, 'a', sizeof title); title[sizeof title - 1] = 0;
    memcpy(title + 254, "\xC3\xA9", 2);   // "é" across byte 255: left out whole
    n = nxpd_welcome(b, 21, 2, 3, nxpd_player_lights(2), 3, title);
    assert(nxpd_u32(b) == NXPD_MAGIC && b[4] == NXPD_VERSION && b[5] == NXPD_WELCOME && nxpd_u32(b + 8) == 21);
    assert(b[12] == 2 && b[13] == 3 && b[14] == 0x07 && b[15] == 3 && b[16] == 254 && n == NXPD_HEADER + 5 + 254);
    n = nxpd_welcome(b, 22, -1, 1, 0, 0, "Zelda"); assert(b[12] == NXPD_NO_PLAYER && b[16] == 5 && !memcmp(b + 17, "Zelda", 5) && n == NXPD_HEADER + 10);
    n = nxpd_welcome(b, 23, DM_PLAYERS, 1, 0, 0, NULL); assert(b[12] == NXPD_NO_PLAYER && b[16] == 0 && n == NXPD_HEADER + 5);
    assert(nxpd_utf8_fit("abc", 2) == 2 && nxpd_utf8_fit("ab\xC3\xA9", 3) == 2 && nxpd_utf8_fit("ab\xC3\xA9", 4) == 4 && nxpd_utf8_fit(NULL, 4) == 0);
    assert(nxpd_player_lights(0) == 0x01 && nxpd_player_lights(7) == 0x06 && nxpd_player_lights(-1) == 0 && nxpd_player_lights(8) == 0);

    // LIGHTS, KICK, PONG
    n = nxpd_byte(b, NXPD_LIGHTS, 31, 0x0F); assert(n == NXPD_HEADER + 1 && b[5] == NXPD_LIGHTS && b[12] == 0x0F);
    n = nxpd_byte(b, NXPD_KICK, 32, NXPD_KICK_FULL); assert(b[5] == NXPD_KICK && b[12] == NXPD_KICK_FULL);
    n = nxpd_pong(b, 33, 0x0102030405060708ull); assert(n == NXPD_HEADER + 8 && b[5] == NXPD_PONG && nxpd_u64(b + 12) == 0x0102030405060708ull);

    // RUMBLE: the left Joy-Con's then the right one's, four floats each; not a number goes as silence
    dm_vibration v[2] = {{0.5f, 160, 0.25f, 320}, {NAN, 100, 0, 200}};
    n = nxpd_rumble(b, 41, v);
    assert(n == NXPD_HEADER + 32 && b[5] == NXPD_RUMBLE);
    assert(nxpd_f32(b + 12) == 0.5f && nxpd_f32(b + 16) == 160.f && nxpd_f32(b + 20) == 0.25f && nxpd_f32(b + 24) == 320.f);
    assert(nxpd_f32(b + 28) == 0.f && nxpd_f32(b + 32) == 100.f);

    // What the phone's Joy-Cons play: a pair each its own side's; one alone the stronger of the two in each band, the other side silent
    dm_vibration motors[2] = {{0.2f, 100, 0.6f, 300}, {0.4f, 150, 0.1f, 400}}, out[2];
    nxpd_rumble_pick(motors, 3, out);
    assert(out[0].amplitude_low == 0.2f && out[1].amplitude_low == 0.4f && nxpd_rumble_on(out));
    nxpd_rumble_pick(motors, 2, out);
    assert(out[0].amplitude_low == 0 && out[0].amplitude_high == 0);
    assert(out[1].amplitude_low == 0.4f && out[1].frequency_low == 150 && out[1].amplitude_high == 0.6f && out[1].frequency_high == 300);
    dm_vibration quiet[2] = {{0}, {0}}; nxpd_rumble_pick(quiet, 3, out); assert(!nxpd_rumble_on(out));

    // One whole controller: a pair is a Pro Controller (each stick its own), a single Joy-Con the one held sideways (its Down is A, its stick turned)
    nxpd_input in; memset(&in, 0, sizeof in);
    in.sides = 3; in.buttons[0] = DM_BTN_UP | DM_BTN_LSL; in.buttons[1] = DM_BTN_A; in.stick[0][0] = 100; in.stick[1][1] = -200;
    uint64_t pm; int32_t st[4];
    assert(nxpd_pad_input(&in, &pm, st) && pm == (DM_BTN_UP | DM_BTN_A) && st[0] == 100 && st[3] == -200);   // no rail buttons on a whole controller
    memset(&in, 0, sizeof in); in.sides = 1; in.buttons[0] = DM_BTN_DOWN | DM_BTN_LSR; in.stick[0][1] = 1000;   // the upright stick pushed toward the top
    assert(nxpd_pad_input(&in, &pm, st) && pm == (DM_BTN_A | DM_BTN_R) && st[0] == -1000 && st[1] == 0);   // held sideways, that is to the left
    memset(&in, 0, sizeof in); assert(!nxpd_pad_input(&in, &pm, st));

    // The merged sample: a pair's as it is, a single right Joy-Con's turned as held sideways
    nxpd_sample smp = {0, {0.f, -1.f, 0.f}, {0.f, 0.f, 1.f}}; float acc[3], rot[3];
    nxpd_merged_sample(&smp, 3, acc, rot); assert(acc[1] == -1.f && rot[2] == 1.f);
    nxpd_merged_sample(&smp, 2, acc, rot); assert(acc[0] == -1.f && acc[1] == 0.f && rot[2] == 1.f);   // (y, -x, z): its top points right

    puts("t_netpad: ok");
    return 0;
}
