// The Mac's Controllers > Pair iPhone… window for NX Pad phones (pad_net_panel_mac.m): the six digits and the QR code a phone pairs with this Mac by, once for every
// game on it, and the phones paired, each with Forget. pad_net_apple.h is the receiver it drives.
#pragma once
#import <Cocoa/Cocoa.h>

NSMenuItem *dm_netpad_pair_menu_item(void);   // "Pair iPhone (NX Pad)…", ⌘⇧P, for the front end's Controllers menu
void dm_netpad_panel_show(void);              // opens the window (and pairing); on the main thread
