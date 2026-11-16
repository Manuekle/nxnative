// NX Pad phones (dm/joypad) over the local network, shared by the Mac and iOS front ends as pad_switch2_apple.h is: pad_net_apple.m listens on UDP, advertises the game over
// Bonjour (_nxpad._udp, TXT game=<name>) and turns each phone into a pad, and the front end gives a pad a player slot through dm_netpad_front. pad_net.h is the protocol.
//
// A phone pairs once with a Mac, for every game on it: the game's Controllers > Pair iPhone… window (front_mac.m) shows a six-digit code and a QR code, the phone proves it saw
// one (PAIR), and both keep a key; the Mac's in <Application Support>/nxnative/nxpad/paired.tsv, beside the Mac's ID (host_id). After that a HELLO takes a player only with
// the answer to a fresh challenge made with that key (pad_net.h says what this does and does not protect). DM_NXPAD (the "Phone controllers" setting): auto (the default)
// listens when some phone is paired with this Mac, so a Mac that never paired one opens no socket and advertises nothing and the system asks nothing; 1 always; 0 never by
// itself. Opening the pairing window listens in every case, for that run. DM_NXPAD_PORT=<n> picks the UDP port (default 48620; when it is taken, by a second game running,
// the system picks one and Bonjour carries it). DM_NXPAD_LOG=1 logs each phone's packets once a second.
//
// A pad is one phone: a Joy-Con pair, or one Joy-Con held sideways, as its HELLO says. Its Joy-Cons are devices of their own to the npad layer (dm_joy_attach, dm_joy_set,
// dm_motion_set_joy), as the original Joy-Cons read from HID are, so the game decides whether a pair is one dual npad or two single ones; the pad's merged state
// (dm_pad_set_player) and merged six-axis stream (dm_motion_set_hid) serve a game that supports no Joy-Con style. A phone that comes back (the same client ID) gets its pad
// back; one silent for a second, or that says goodbye, is gone. Its rumble goes back over the network (dm_netpad_rumble), and WELCOME tells it its player and player lights.
#pragma once
#include <stdint.h>
#include "dm_input.h"
#include "hle_haptics.h"

typedef struct net_pad {
    uint64_t client;          // the phone's client ID, kept across its launches
    char name[48];            // "<phone's name> (NX Pad)", the player slot's name: a phone that comes back gets its player back
    uint8_t sides;            // its Joy-Cons: bit 0 left, bit 1 right
    uint64_t buttons[2];      // each Joy-Con's NpadButtons, from its last input
    int32_t stick[2][2];      // each Joy-Con's stick, upright, y up
    uint8_t extras;           // Home (bit 0) and Capture (bit 1)
    int have;                 // an input has come
    struct net_pad *next;
} net_pad;

// The front end's side. All calls come on the main queue.
typedef struct {
    int (*attach)(net_pad *p);   // a new phone: take it a player slot (player() then names it). 1: kept, with a player or waiting for its first button press; 0: no free player,
                                 // and the phone is told so (KICK)
    void (*detach)(net_pad *p);  // the phone went: it is already off the list and is freed after the call
    void (*read)(net_pad *p);    // its state changed
    int (*player)(net_pad *p);   // 0-based player, -1 without one
    int (*blocked)(void);        // the game takes no controller input now (focus lost, the Home quit prompt open); NULL: never
} dm_netpad_front;

int dm_netpad_start(const dm_netpad_front *front);   // 1: listening; 0: off (DM_NXPAD=0, or auto with no phone paired) or no socket
void dm_netpad_active(int on);                        // focus lost (0): its Joy-Cons and sensors stop driving the game's; back (1): they continue
net_pad *dm_netpad_pads(void);                        // the pads, a list through next
int dm_netpad_state(const net_pad *p, uint64_t *m, int32_t st[4]);   // the pad as one whole controller (pad_net.h nxpd_pad_input); 0 before its first input
int dm_netpad_home(const net_pad *p);
void dm_netpad_ab(const net_pad *p, int *a, int *b);  // ORs in its A and B as one whole controller (a single Joy-Con's by their place), for the Home and controller prompts
// Rumble: the sink for a player whose pad is a phone (dm_haptics_apple_set_sink(player, dm_netpad_rumble)); called on the haptics queue. Every 15 ms while it buzzes the phone
// gets what each of its Joy-Cons plays, then a few packets of silence (a datagram can be lost)
void dm_netpad_rumble(const dm_haptic_state *state);

// Pairing, for the Mac's Pair iPhone… window. All calls on the main queue
typedef struct {
    char code[8];           // the six digits, while the window is open
    char url[768];          // what the QR code carries: nxpad://pair?v=2&m=<Mac ID>&k=<token>&a=<IPv4>&p=<port>&n=<Mac's name>&g=<game>
    char mac[64], game[201];// the Mac's name, the game's
    int port, listening;    // the UDP port; 0 when no socket could be opened
    int code_locked;        // too many wrong codes since the window opened: only the QR code pairs now
    int seconds_left;       // until the code changes by itself
} dm_netpad_pairing;
enum { DM_NETPAD_PAIR_NEW_CODE = 1, DM_NETPAD_PAIR_PAIRED = 2, DM_NETPAD_PAIR_WRONG = 3 };
typedef struct { uint64_t client; int64_t when; char name[33]; int connected, player; } dm_netpad_phone;
// Opens pairing (listening first when nothing did): a fresh code, then changed(event, phone) for each new code, pairing (the phone's name) or wrong code. 0: no socket
int dm_netpad_pair_open(void (*changed)(int event, const char *phone));
void dm_netpad_pair_close(void);
void dm_netpad_pair_get(dm_netpad_pairing *out);
int dm_netpad_phones(dm_netpad_phone *out, int max);   // the phones paired with this Mac, newest first, and which of them play this game now
void dm_netpad_forget(uint64_t client);                // unpairs a phone on this Mac (every game), and lets it go if it plays this one
