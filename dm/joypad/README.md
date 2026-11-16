# NX Pad

An iPhone app that plays as Joy-Cons (Switch 1) for a game nxnative runs on the Mac: a pair, the phone held sideways in both hands, or one Joy-Con on its own, held sideways. The phone pairs once with a Mac, with a QR code or six digits a game on that Mac shows; after that it finds that Mac's games on the local network over Bonjour and joins them by itself. What you press goes over UDP, the phone's gyro and accelerometer are the Joy-Cons' six-axis sensor, and the game's rumble comes back to the phone's Taptic Engine. Several games open at once each keep their own session, and one button switches between them.

Status: pairing, joining, switching between two games and the controller tried in the Simulator against [tools/pad_listen.py](tools/pad_listen.py), which stands in for a game; the Mac host's receiver tried by `dm/host/tests/t_netpad_host.py`, and five Mac apps run with it; not yet played with on a phone. **Try the layout offline** shows the controller without a game.

- [What you need](#what-you-need)
- [Install the app on the iPhone](#install-the-app-on-the-iphone)
- [Get the Mac ready](#get-the-mac-ready)
- [Pair the iPhone with the Mac](#pair-the-iphone-with-the-mac)
- [Play](#play)
- [Several games at once](#several-games-at-once)
- [Troubleshooting](#troubleshooting)
- [Try it without a game](#try-it-without-a-game)
- [Protocol](#protocol)
- [Host side](#host-side)
- [Files](#files)

## What you need

- An iPhone with iOS 26 or later, on the same Wi-Fi network as the Mac (not a guest network that keeps devices apart).
- A Mac with Xcode 27.2 (or later) and xcodegen (`brew install xcodegen`), and an Apple ID signed in to Xcode (Xcode > Settings > Accounts) to sign the app.
- A game packed with a host that has the NX Pad receiver: a Mac app built from this repository after NX Pad's pairing came in. An older app has no receiver, and the phone does not see it ([Troubleshooting](#troubleshooting)).

## Install the app on the iPhone

1. In this folder, `xcodegen generate`. It writes `NXPad.xcodeproj` and `Support/Info.plist` (git ignores both; run it again after adding or removing files).
2. Put your signing team and a bundle identifier of your own in `Support/Signing.local.xcconfig` (git ignores it too). The team ID is in Xcode > Settings > Accounts, or in a signing certificate's name:

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   PRODUCT_BUNDLE_IDENTIFIER = com.yourname.nxpad
   ```

3. Optional, for the Wii Menu's own typeface: put your FOT-Rodin Pro DB as `Resources/Fonts/RodinPro-DB.otf` before `xcodegen generate` (git ignores the folder: the font is commercial and stays out of the repository). Without it the app uses the system's rounded face.
4. Connect the iPhone (USB, or the same network once it is paired with Xcode) and turn on Developer Mode on it the first time (Settings > Privacy & Security > Developer Mode).
5. Open `NXPad.xcodeproj`, pick the iPhone and run. From the command line instead, with the iPhone's identifier from `xcrun devicectl list devices`:

   ```
   xcodebuild -project NXPad.xcodeproj -scheme NXPad -configuration Release -destination 'id=<iPhone identifier>' -derivedDataPath build -allowProvisioningUpdates build
   xcrun devicectl device install app --device '<iPhone identifier>' build/Build/Products/Release-iphoneos/NXPad.app
   ```

The first time it looks for games, iOS asks for Local Network access: allow it, or the app finds nothing (Settings > Privacy & Security > Local Network turns it back on). Scanning a QR code inside the app asks for the camera. With a free Apple ID the app stops opening after 7 days: run it again from Xcode.

## Get the Mac ready

Nothing to turn on: **Phone controllers** in a game's settings window is **When an iPhone is paired** by default ([Phone controllers](../../docs/settings.md#phone-controllers)). A game listens for phones once some phone is paired with the Mac, and also while its pairing window is open. **Always** listens in every case; **Off** never by itself.

The first time a game listens, macOS may ask two things: whether the app may find devices on the local network, and (with the firewall on) whether it may accept incoming network connections. Allow both, or the phone finds the game but its datagrams never reach it.

## Pair the iPhone with the Mac

Once for each Mac, for every game on it:

1. Open a game on the Mac and choose **Controllers > Pair iPhone (NX Pad)…** in its menu bar (⌘⇧P). A window shows a QR code and six digits.
2. On the iPhone, point the Camera app at the QR code and tap the NX Pad link, or open NX Pad, tap **Pair a Mac** and either **Scan the QR code** or type the six digits. Tapping a game whose Mac does not know this phone opens the same sheet.
3. The sheet shows **Paired with** followed by the Mac's name. The Mac's window lists the phone, and NX Pad joins the game.

The code is used once, and changes after five wrong tries and every 10 minutes; after 15 wrong tries the window takes only the QR code until it opens again. To unpair, use **Forget** beside the phone in the Mac's window, or Settings > **Paired Macs** > **Forget** on the phone. A phone the Mac forgot forgets that Mac too, and asks to pair again.

## Play

- From then on a paired Mac's game joins by itself: one that opens while NX Pad shows its games screen takes the phone to the controller. The games screen lists the open games and, greyed, the ones played before on the paired Macs. Each greyed one has an ✕ (or a long press, Remove) that takes it off the list, and **Clear closed games** takes them all; a game that opens again is back. **Back to games** (in the menu) lets every game go; each joins again once it closes and opens again. Settings > **Join open games by themselves** turns this off: a game is then joined with a tap.
- How the phone is held, on the games screen or in the menu:
  - **Pair**: the left Joy-Con on the left half of the screen (stick, direction buttons, −, Capture, L and ZL at the top), the right one on the right half (A B X Y, stick, +, Home, R and ZR). The player lights, the game and the latency sit between them.
  - **Left Joy-Con** or **Right Joy-Con**: one Joy-Con held sideways across the screen, rail at the top with SL and SR, stick on the left. The game sees a single Joy-Con, as a real one held sideways; a game that only knows whole controllers reads it the way the host reads a sideways Joy-Con.
- Fingers slide from key to key (rolling over the direction buttons, A to B), and a finger between two keys of the diamond presses both.
- A stick tilts from its centre when the thumb lands on the ring, and from where the thumb lands when it lands on the knob (or always, with **Floating sticks**). A short tap clicks it (L3 / R3); tap it, then touch it again and hold, to keep it clicked.
- Home held for two seconds opens the game's quit prompt.
- The gear opens the menu: status, the open games, how the phone is held, settings, back to the games.
- Settings: paired Macs, colours (**Wii**, the default, or a pair of real Joy-Con colours), size, stick dead zone, floating sticks, a tap on every press, game rumble and its strength, and whether the phone's motion is sent.
- **Customize the layout** (in the menu) lets you drag and resize every control, hide it, or add keys, and keeps the result for every game or for one game. A button can **lock**: a tap holds it down until the next tap. It can also be **turbo** (held, it lets go and presses again ten times a second, and a locked turbo button does it until the next tap) and **also press** other buttons with it, for a game that wants a combination on one key. A stick can read only side to side or up and down, hold a button down in a direction (push up to accelerate), press a button at full tilt (sprint), keep its tilt when the thumb lifts, or stand in for the direction buttons (eight directions, or four). A **shift key** makes the other buttons become others (or nothing) while it is held, and held as a lock, until the next tap: one pad for driving and another for walking. A **camera area** is a part of the screen where a sweeping finger steers a stick from where it lands. **Touch screen** is an area that is the Switch's own touch screen (a game that reads it: menus, a map, a minigame): a finger there touches the same place on the game's screen, up to ten at once. **Motion** moves a stick with the phone itself: turned like a steering wheel, or swept like an aim, optionally only while a button is held. **Try the layout offline** tests all of it without a game.
- The look is the Wii Menu's: pearl stripes, white channels, glossy pill buttons, sky blue for what is selected.

## Several games at once

The phone stays linked to every open game of its paired Macs and keeps its player in each. The game shown gets the touches, the motion and the rumble; the others get a released controller. **⇄** beside the menu button goes to the next game, and the menu lists them all. A game that opens during play shows a line saying so; a game that closes is let go, and the phone goes on with the next one. Each game keeps how the phone is held.

## Troubleshooting

| What you see | Why | What to do |
|---|---|---|
| The games screen stays empty | The phone and the Mac are on different networks, NX Pad has no Local Network access, or the game does not listen | Same Wi-Fi for both; Settings > Privacy & Security > Local Network > NX Pad on; open the game's **Pair iPhone…** window, which always listens |
| A game shows "update this game to play with NX Pad" | Its host speaks the first protocol, without pairing | Build the Mac app again from this repository |
| A game does not show at all, even with its pairing window open | Its host has no receiver: its log (`~/Library/Logs/nxnative/<title ID>.log`) has no `[nxpad]` line | Build the Mac app again from this repository |
| The game is listed but **Waiting for the game…** never ends | The Mac's firewall drops the phone's datagrams | Allow the game's incoming connections (System Settings > Network > Firewall > Options) |
| **Wrong code** | A typo, or the code changed | Type the code the window shows now; the QR code avoids typing |
| **No pairing window is open** | The code went to games whose window is closed | Open **Controllers > Pair iPhone…** in the game first |
| **This Mac does not know this iPhone (any more)** | The Mac forgot the phone (**Forget**, or `paired.tsv` deleted) | Pair again |
| The controller lags | A busy or distant Wi-Fi network | The menu shows the latency; a 5 GHz network close to both helps |

On the Mac, the game's log names what happened with each phone in its `[nxpad]` lines; `DM_NXPAD_LOG=1` adds each phone's packets once a second.

## Try it without a game

On the Mac, on the same Wi-Fi:

```
python3 dm/joypad/tools/pad_listen.py --rumble
```

The phone lists the game "Test game"; the script prints a pairing code and the link the Mac's QR code would carry (open it in the Simulator with `xcrun simctl openurl booted '<link>'`), then what the phone holds, and with `--rumble` the phone rumbles while ZL (softly) or ZR (strongly) is held. `--state FILE` keeps its pairing across runs; a second one with `--port 48621 --title "Second game"` and the same `--state` is a second game on the same Mac. With the macOS firewall on, run it with a Python the firewall lets in (`/usr/bin/python3` usually is).

## Protocol

NXPD version 2 (version 1 had no pairing). UDP datagrams on the local network, every number little-endian, floats IEEE 754 single precision. The host advertises Bonjour `_nxpad._udp` under the game's name (default port 48620) with the TXT keys `game` (the game's name), `v` (`2`), `mac` (the Mac's ID, 16 hex digits, the same for every game on it), `host` (the Mac's name) and `tid` (the game's title ID).

Every datagram starts with a 12-byte header:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | magic `NXPD` (0x4450584E) |
| 4 | 1 | version, 2 |
| 5 | 1 | kind |
| 6 | 2 | reserved, 0 |
| 8 | 4 | sequence number, per sender, wrapping |

A string is a length byte and that many bytes of UTF-8.

Phone to host:

| Kind | Name | Payload |
|---|---|---|
| 0x01 | HELLO | u64 client ID (random, kept across launches), u8 sides (bit 0 left Joy-Con, bit 1 right), u8 device (1 = Joy-Con), u8 features (bit 0 motion, bit 1 rumble), u8 reserved, string name (32 bytes at most); then, answering a CHALLENGE, 32 bytes HMAC-SHA256(key, "NXPD hello" ‖ u64 Mac ID ‖ u64 client ID ‖ the challenge's 16 bytes ‖ u8 sides) |
| 0x02 | INPUT | u64 sender time in ns, u8 sides, u8 extra buttons (bit 0 Home, bit 1 Capture), u16 reserved; left Joy-Con: u32 buttons, i16 stick x, i16 stick y; right Joy-Con: the same; u8 sample count n (0 to 4), 3 reserved bytes; n samples of u32 age in µs, f32 acceleration x y z, f32 rotation x y z |
| 0x03 | BYE | none |
| 0x04 | PING | u64 sender time in ns |
| 0x05 | PAIR | u64 client ID, u8 method (1 the six digits, 2 the QR code's token), 3 reserved bytes, 16 bytes nonce, 32 bytes proof = HMAC-SHA256(secret, "NXPD pair" ‖ u64 Mac ID ‖ u64 client ID ‖ nonce), string the phone's name; the secret is the six digits as text or the token's 16 bytes |
| 0x06 | TOUCH | u8 finger count n (0 to 10; 0 lifts every finger), then n fingers of u8 slot (0 to 15), u16 x, u16 y: a point of the game's touch screen, 65536 to the whole width or height from the top left. The whole set of fingers down, not changes; sent again for 120 ms after a change and every 100 ms while a finger is down. Only sent when WELCOME's flags have bit 2 |
Host to phone:

| Kind | Name | Payload |
|---|---|---|
| 0x81 | WELCOME | u8 player (0 to 7; 255 while the game waits for a first button press), u8 sides taken, u8 player lights (bit 0 the first light; 0 lets the phone show the Switch's pattern for the player), u8 flags (bit 0 the host reads motion, bit 1 it sends rumble, bit 2 it takes TOUCH), string game name |
| 0x82 | RUMBLE | two actuators, the left Joy-Con's then the right one's: f32 low-band amplitude, f32 low-band frequency (Hz), f32 high-band amplitude, f32 high-band frequency (Hz) |
| 0x83 | LIGHTS | u8 player lights |
| 0x84 | PONG | the PING's u64, as it came |
| 0x85 | KICK | u8 reason: 1 no free player, 2 the game is closing, 3 not supported, 4 this phone is not paired with the Mac |
| 0x86 | PAIRED | u8 result (0 paired, 1 wrong code, 2 no pairing window open in this game, 3 too many wrong codes: the Mac shows a new one), 7 reserved bytes, u64 Mac ID, 16 bytes nonce, 32 bytes confirmation = HMAC-SHA256(key, "NXPD paired" ‖ u64 Mac ID ‖ u64 client ID) (zeros unless paired), string the Mac's name, string the game's |
| 0x87 | CHALLENGE | u64 Mac ID, 16 bytes nonce the next HELLO answers |

The values are the Joy-Con's own, so the host can hand them to what its Joy-Con front ends already use ([dm_input.h](../host/dm_input.h)):

- Buttons are `nn::hid::NpadButton` bits, each on the Joy-Con it belongs to (the left one's direction buttons, L, ZL, −, its stick button and its rail buttons SL 24 and SR 25; the right one's A B X Y, R, ZR, +, its stick button, SL 26 and SR 27), as `jc1_joy_buttons` in [pad_jc1.h](../host/pad_jc1.h) makes them.
- Sticks are −32767 to 32767 with y up, in the upright Joy-Con's frame, also for a Joy-Con the phone draws sideways: the phone turns it back.
- Motion samples are in the upright frame of every Joy-Con the packet carries: x the short axis (to the right), y the long axis (toward the top), z out of the face; a pair is held upright, so both share it. Acceleration is the gravity direction in G, (0, 0, −1) face up; rotation is in rad/s. A sample was taken its age before the packet was sent.

Labels are their ASCII bytes, without a terminator. Both sides of a pairing keep key = HMAC-SHA256(secret, "NXPD key" ‖ u64 Mac ID ‖ u64 client ID ‖ the phone's nonce ‖ the Mac's nonce); the phone in its Keychain, the Mac in `paired.tsv` ([Host side](#host-side)). The Mac's QR code carries `nxpad://pair?v=2&m=<Mac ID>&k=<token, 32 hex digits>&a=<IPv4>&p=<port>&n=<Mac's name>&g=<game>`: the phone sends PAIR to that address and to the Mac's games it sees. A typed code goes to every game on the network that advertises a Mac ID; only the one whose window is open takes it.

What pairing protects: a phone that never paired, or a HELLO recorded and played back, takes no player. What it does not: the traffic is not hidden, INPUT is not signed (after a HELLO the host takes it from the phone's address), and someone on the same network who records a pairing by code can try the million codes against it offline (a QR token is too long for that).

The phone sends HELLO every 500 ms until WELCOME comes; the host answers a HELLO without the right answer with CHALLENGE (the same one while it is good, 10 s), and the phone sends HELLO again at once with the answer. A PAIR is sent again every 400 ms to a game that has not answered, for 4 s; the host answers a PAIR it already answered with the same PAIRED, and counts a wrong one once. Then INPUT goes on every change, again for 120 ms after it (a lost datagram costs nothing), at least every 100 ms as a heartbeat, and with each batch of motion samples (about 100 a second); a PING goes every second. A phone that hears nothing for 3 s says HELLO again. It sends a new HELLO when its mode changes, and BYE when it disconnects or goes to the background. A phone linked to several games sends each its own session; the games not shown get a released controller as their heartbeat.

## Host side

[pad_net_apple.m](../host/pad_net_apple.m) (the UDP socket, the Bonjour advertisement, the pairing and the phones), [pad_net.h](../host/pad_net.h) (the protocol and its HMACs, plain C on CommonCrypto, checked by `dm/host/tests/t_netpad.c`) and [pad_net_panel_mac.m](../host/pad_net_panel_mac.m) (the Pair iPhone… window); `dm/host/tests/t_netpad_host.py` drives the receiver as a phone. `DM_NXPAD` (the Mac settings window's **Phone controllers**): `auto` (the default) listens when some phone is paired with this Mac, `1` always, `0` never by itself; the pairing window listens in every case. The Mac front end gives each phone a player slot as it does a Switch 2 controller ([front_mac.m](../host/front_mac.m), `netpad_*`); the iOS front end does not take phones yet.

- The Mac's ID and its paired phones are in `~/Library/Application Support/nxnative/nxpad/` (`host_id`, `paired.tsv`: client ID, key, when, name; owner-only), shared by every game on the Mac and read again when another game changed them. Deleting a line of `paired.tsv` unpairs that phone.
- The pairing window (Controllers > Pair iPhone…, ⌘⇧P; `DM_NXPAD_PAIR_WINDOW=1` opens it at start): a six-digit code and a QR token, both used once, new after five wrong codes or 10 minutes; after 15 wrong codes since it opened only the QR code pairs. It lists the paired phones with **Forget** (which also lets one that plays now go, with KICK 4).
- A HELLO from a client ID `paired.tsv` does not hold gets KICK 4; from a paired one without the right answer, CHALLENGE; with it, the HELLO goes on as below.
- A HELLO from a new client ID takes a player slot named after the phone (the same phone coming back gets its player back), `dm_joy_attach(player, sides)`, and is answered with WELCOME: its player (255 while it waits for a first press, with Press a button to join) and the Switch's player lights. A HELLO with other sides attaches those; a phone the game has no player for gets KICK.
- INPUT: a sequence number older than the last one taken is dropped; each carried Joy-Con goes to `dm_joy_set`, the pad as one whole controller to `dm_pad_set_player` (`jc1_pad_input`: a pair is a Pro Controller, a single Joy-Con the one held sideways), each sample to `dm_motion_set_joy` for each Joy-Con and to `dm_motion_set_hid` for the pad (turned for a single Joy-Con). A sample's time on the host's clock is the packet's time minus its age plus the clocks' offset, the lowest seen (the quickest datagram), creeping up 1 µs a packet to follow their drift. Home goes to the hold-to-quit prompt, A and B to the prompts.
- TOUCH: the whole set goes to `dm_touch_set`, the game's touch screen, as the Mac's mouse does; only a phone with a player touches, none while the game takes no controller input, and a phone that goes (or loses focus) lifts its fingers. A host from before TOUCH does not set bit 2, and the phone sends none.
- PING is answered with PONG. BYE, or a second without a datagram, frees the slot and `dm_joy_attach(player, 0)`.
- Rumble: the player's haptics sink takes the game's two motors (with Rumble strength and cutoff applied); every 15 ms while they buzz the phone gets what each of its Joy-Cons plays (its own side in a pair, the stronger of the two alone), then three packets of silence.
- `DM_NXPAD_PORT` picks the port (48620; a taken one makes the system pick, as for a second game running); `DM_NXPAD_LOG=1` logs each phone's packets once a second; `DM_NXPAD_DIR` keeps the ID and paired phones elsewhere (the tests). The Mac app's Info.plist carries `NSLocalNetworkUsageDescription` and `NSBonjourServices` (dm/mac/pack_app.py).

## Files

- `project.yml`: the xcodegen project. `Support/Signing.xcconfig`: signing defaults (`Signing.local.xcconfig`, yours, overrides them). The app is in English only.
- `Sources/App`: the app and its model (`AppModel.swift`: the open games' sessions, joining, switching, pairing).
- `Sources/Link`: the protocol and its HMACs (`Wire.swift`), the UDP session (`PadLink.swift`), a pairing (`PairAttempt.swift`) and the Bonjour browser (`HostBrowser.swift`).
- `Sources/Model`: the controller's buttons and modes (`Pad.swift`), the paired Macs and their games (`PairStore.swift`, keys in the Keychain), the settings' keys.
- `Sources/Input`: the phone's motion and rumble.
- `Sources/Layout`: where each control goes, for drawing and for touches alike.
- `Sources/UI`: the games screen (`ConnectView.swift`), the controller (`ControllerScreen.swift`, `PadViews.swift`, `TouchSurface.swift`), the pairing sheet and QR scanner (`PairView.swift`), the menu and settings (`SettingsForm.swift`) and the Wii Menu style (`WiiStyle.swift`, `PadTheme.swift`).
- `Resources/AppIcon.icon`: the icon, an Icon Composer file (Xcode 26 and later): the Wii U mark full bleed, its U (`Assets/Glyph.svg`, a glass layer) on the mark's blue. Nintendo's mark: fine on your own phone, not for an app published to others.
- `tools/pad_listen.py`: the stand-in receiver, pairing included.
