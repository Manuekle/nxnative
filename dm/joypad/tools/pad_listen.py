#!/usr/bin/env python3
"""A stand-in for the host's NX Pad receiver, to try the app without a game.

It advertises _nxpad._udp with macOS's dns-sd as a game on a Mac of its own, keeps its pairing window open (it prints the six digits
and the link the Mac's QR code carries), pairs phones, welcomes a paired one as player 1 after it answers the challenge, answers its
pings and prints what it holds on one line: each Joy-Con's buttons and stick, Home and Capture, and the newest motion sample.

    python3 dm/joypad/tools/pad_listen.py [--port 48620] [--title "Test game"] [--rumble] [--state FILE]

The pairing lasts as long as the script runs, unless --state names a file that keeps this stand-in's ID and its paired phones (not the
Mac's own, which the games keep in ~/Library/Application Support/nxnative/nxpad). With the macOS firewall on, the Python that runs it
must be allowed to take incoming connections (System Settings > Network > Firewall > Options): macOS asks once, or nothing arrives.
--rumble makes the phone rumble while ZL (softly) or ZR (strongly) is held, repeated every 100 ms as a host does, and silent once let go.
Stops with Ctrl-C. The format is in dm/joypad/README.md, "Protocol"; dm/host/pad_net.h is the host's side.
"""
import argparse
import hashlib
import hmac
import os
import secrets
import socket
import struct
import subprocess
import sys
import time
import urllib.parse

MAGIC, VERSION = 0x4450584E, 2
HELLO, INPUT, BYE, PING, PAIR = 0x01, 0x02, 0x03, 0x04, 0x05
WELCOME, RUMBLE, LIGHTS, PONG, KICK, PAIRED, CHALLENGE = 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87
KICK_CLOSING, KICK_NOT_PAIRED = 2, 4
PAIR_CODE, PAIR_QR = 1, 2
PAIRED_OK, PAIRED_WRONG, PAIRED_RENEWED = 0, 1, 3
HEADER = struct.Struct('<IBBHI')
SAMPLE = struct.Struct('<I6f')
NAMES = {0: 'A', 1: 'B', 2: 'X', 3: 'Y', 4: 'LS', 5: 'RS', 6: 'L', 7: 'R', 8: 'ZL', 9: 'ZR', 10: '+', 11: '-',
         12: 'Left', 13: 'Up', 14: 'Right', 15: 'Down', 24: 'SL(L)', 25: 'SR(L)', 26: 'SL(R)', 27: 'SR(R)'}
LIGHTS_P1 = 0b0001


def names(bits):
    return ' '.join(n for i, n in NAMES.items() if bits >> i & 1) or '-'


def packet(kind, seq, payload=b''):
    return HEADER.pack(MAGIC, VERSION, kind, 0, seq) + payload


def rumble_payload(amp):
    motor = (amp, 160.0, amp * 0.8, 320.0)
    return struct.pack('<8f', *motor, *motor)


def mac(key, label, host, client, extra=b''):
    """pad_net.h nxpd_hmac: HMAC-SHA256 of the label, host and client (little endian) and extra."""
    return hmac.new(key, label + struct.pack('<QQ', host, client) + extra, hashlib.sha256).digest()


def string(s):
    b = s.encode()[:255].decode('utf-8', 'ignore').encode()   # a character cut at byte 255 is left out whole
    return bytes([len(b)]) + b


def read_name(body, at):
    n = body[at] if len(body) > at else 0
    return body[at + 1:at + 1 + min(n, 32)].decode('utf-8', 'replace'), 1 + n


def lan_address():
    """The address a phone on the Wi-Fi reaches this Mac at (what the QR code carries)."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(('192.0.2.1', 9))   # no packet goes out: it only picks the route
            return s.getsockname()[0]
    except OSError:
        return ''


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--port', type=int, default=48620)
    ap.add_argument('--title', default='Test game', help='the game name the phone shows')
    ap.add_argument('--host', default=socket.gethostname().split('.')[0] + ' (stand-in)', help='the Mac name the phone shows')
    ap.add_argument('--rumble', action='store_true', help='rumble while ZL or ZR is held')
    ap.add_argument('--state', help='a file that keeps this stand-in\'s ID and paired phones across runs')
    args = ap.parse_args()

    host_id = secrets.randbits(64) or 1
    paired = {}   # client -> (key, name)
    if args.state and os.path.exists(args.state):
        with open(args.state) as f:
            for line in f:
                p = line.rstrip('\n').split('\t')
                if p[0] == 'host':
                    host_id = int(p[1], 16)
                elif len(p) >= 3:
                    paired[int(p[0], 16)] = (bytes.fromhex(p[1]), p[2])

    def save():
        if not args.state:
            return
        with open(args.state, 'w') as f:
            f.write(f'host\t{host_id:016x}\n')
            for c, (k, n) in paired.items():
                f.write(f'{c:016x}\t{k.hex()}\t{n}\n')
        os.chmod(args.state, 0o600)

    code, token, tries = '', b'', 0

    def renew():
        nonlocal code, token, tries
        code, token, tries = f'{secrets.randbelow(1000000):06d}', secrets.token_bytes(16), 0
        q = {'v': '2', 'm': f'{host_id:016x}', 'k': token.hex()}
        a = lan_address()
        if a:
            q.update(a=a, p=str(args.port))
        q.update(n=args.host, g=args.title)
        print(f'\npairing code {code[:3]} {code[3:]}  (QR link: nxpad://pair?{urllib.parse.urlencode(q, quote_via=urllib.parse.quote)})')

    # Dual stack, as the host's receiver: Bonjour gives the phone the Mac's IPv6 addresses too, and it may well send there
    sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
    sock.bind(('::', args.port))
    sock.settimeout(0.02)
    advert = subprocess.Popen(['dns-sd', '-R', args.title[:63], '_nxpad._udp', 'local', str(args.port), f'game={args.title}', 'v=2',
                               f'mac={host_id:016x}', f'host={args.host}', 'tid=0000000000000000'],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f'listening on UDP {args.port} as "{args.title}" on "{args.host}", {len(paired)} phone(s) paired; Ctrl-C stops')
    renew()

    seq = 0
    peer = None
    last_heard = 0.0
    challenges = {}   # client -> (nonce, until)
    rumble_amp = 0.0    # what the held triggers ask for: ZL 0.4, ZR 0.9
    rumble_on = False
    rumble_sent = 0.0
    last_pair = None   # (client, nonce, reply): the answer to a PAIR that comes again
    last_wrong = None  # the same for the last wrong one

    def send(kind, payload=b'', to=None):
        nonlocal seq
        seq = (seq + 1) & 0xFFFFFFFF
        sock.sendto(packet(kind, seq, payload), to or peer)

    try:
        while True:
            now = time.monotonic()
            try:
                data, addr = sock.recvfrom(2048)
            except socket.timeout:
                data, addr = None, None
            if data and len(data) >= HEADER.size:
                magic, version, kind, _, _ = HEADER.unpack_from(data)
                body = data[HEADER.size:]
                if magic == MAGIC and version != VERSION:
                    print(f'\na datagram of NXPD version {version} from {addr[0]}: this stand-in speaks {VERSION}')
                elif magic == MAGIC:
                    if kind == PAIR and len(body) >= 61:
                        client, method = struct.unpack_from('<QB', body)
                        nonce, proof = body[12:28], body[28:60]
                        name, _ = read_name(body, 60)
                        if last_pair and last_pair[:2] == (client, nonce):
                            send(PAIRED, last_pair[2], addr)
                            continue
                        if last_wrong and last_wrong[:2] == (client, nonce):   # sent again: the same answer, no try counted
                            send(PAIRED, last_wrong[2], addr)
                            continue
                        secret = code.encode() if method == PAIR_CODE else token
                        if not hmac.compare_digest(mac(secret, b'NXPD pair', host_id, client, nonce), proof):
                            result = PAIRED_WRONG
                            if method == PAIR_CODE:
                                tries += 1
                                result = PAIRED_RENEWED if tries >= 5 else PAIRED_WRONG
                            print(f'\n"{name}" at {addr[0]}: wrong {"code" if method == PAIR_CODE else "QR code"}')
                            reply = struct.pack('<B7xQ', result, host_id) + bytes(48) + string(args.host) + string(args.title)
                            last_wrong = (client, nonce, reply)
                            send(PAIRED, reply, addr)
                            if result == PAIRED_RENEWED:
                                renew()
                            continue
                        hn = secrets.token_bytes(16)
                        key = mac(secret, b'NXPD key', host_id, client, nonce + hn)
                        reply = (struct.pack('<B7xQ', PAIRED_OK, host_id) + hn + mac(key, b'NXPD paired', host_id, client)
                                 + string(args.host) + string(args.title))
                        paired[client] = (key, name)
                        save()
                        last_pair = (client, nonce, reply)
                        send(PAIRED, reply, addr)
                        print(f'\n"{name}" at {addr[0]} paired by {"code" if method == PAIR_CODE else "QR code"}')
                        renew()
                    elif kind == HELLO and len(body) >= 13:
                        client, sides, device, features = struct.unpack_from('<QBBB', body)
                        name, used = read_name(body, 12)
                        auth = body[12 + used:12 + used + 32] if body[12] <= 32 and len(body) >= 12 + used + 32 else None
                        if client not in paired:
                            send(KICK, bytes([KICK_NOT_PAIRED]), addr)
                            continue
                        chal = challenges.get(client)
                        if chal and now > chal[1]:
                            chal = None
                        if auth and chal and hmac.compare_digest(
                                mac(paired[client][0], b'NXPD hello', host_id, client, chal[0] + bytes([sides & 3])), auth):
                            del challenges[client]
                            if addr != peer:
                                print(f'\nhello from "{name}" at {addr[0]}:{addr[1]}: sides {sides:02b}, device {device}, '
                                      f'features {features:02b}')
                            peer, last_heard = addr, now
                            send(WELCOME, struct.pack('<BBBB', 0, sides, LIGHTS_P1, 0b11) + string(args.title))
                            continue
                        if not chal:
                            chal = challenges[client] = (secrets.token_bytes(16), now + 10)
                        send(CHALLENGE, struct.pack('<Q', host_id) + chal[0], addr)
                    elif kind == INPUT and addr == peer and len(body) >= 32:
                        last_heard = now
                        _, sides, extras = struct.unpack_from('<QBB', body)
                        lb, lx, ly, rb, rx, ry = struct.unpack_from('<IhhIhh', body, 12)
                        rumble_amp = 0.9 if rb >> 9 & 1 else 0.4 if lb >> 8 & 1 else 0.0   # ZR, ZL
                        count = body[28]
                        line = []
                        if sides & 1: line.append(f'L[{names(lb)}] ({lx:+6d},{ly:+6d})')
                        if sides & 2: line.append(f'R[{names(rb)}] ({rx:+6d},{ry:+6d})')
                        if extras & 1: line.append('Home')
                        if extras & 2: line.append('Capture')
                        if count and len(body) >= 32 + count * SAMPLE.size:
                            age, ax, ay, az, gx, gy, gz = SAMPLE.unpack_from(body, 32 + (count - 1) * SAMPLE.size)
                            line.append(f'acc ({ax:+.2f},{ay:+.2f},{az:+.2f}) gyro ({gx:+.2f},{gy:+.2f},{gz:+.2f}) {age} us old')
                        sys.stdout.write('\r' + '  '.join(line)[:170].ljust(170))
                        sys.stdout.flush()
                    elif kind == PING and addr == peer:
                        last_heard = now
                        send(PONG, body[:8])
                    elif kind == BYE and addr == peer:
                        print('\nbye')
                        peer = None
            if peer and now - last_heard > 1.0:
                print('\ncontroller gone: 1 s without a packet')
                peer = None
            if peer and args.rumble:
                if rumble_amp > 0 and now - rumble_sent >= 0.1:
                    send(RUMBLE, rumble_payload(rumble_amp))
                    rumble_on, rumble_sent = True, now
                elif rumble_amp == 0 and rumble_on:
                    send(RUMBLE, rumble_payload(0.0))
                    rumble_on = False
    except KeyboardInterrupt:
        print()
    finally:
        if peer:
            send(KICK, bytes([KICK_CLOSING]))
        advert.terminate()


if __name__ == '__main__':
    main()
