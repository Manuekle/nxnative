#!/usr/bin/env python3
"""The NX Pad receiver (pad_net_apple.m) against a phone, without a game: runs t_netpad_host (the receiver with the npad layer stubbed)
and plays the phone over UDP on the loopback: a phone that never paired is kicked; a wrong code is refused and counted once however
often it is sent again; the right code pairs (the PAIRED confirmation proves the same key); a HELLO takes a player only with the
answer to the challenge; PING gets PONG; a second phone pairs by the QR code's token; a second game on the same Mac (another
receiver on the same paired phones' folder, Phone controllers on auto) listens by itself and takes the first phone at once.

    python3 t_netpad_host.py <t_netpad_host binary>
"""
import hashlib
import hmac
import os
import secrets
import socket
import struct
import subprocess
import sys
import tempfile
import urllib.parse

MAGIC, VERSION = 0x4450584E, 2
HELLO, INPUT, PING, PAIR, TOUCH = 0x01, 0x02, 0x04, 0x05, 0x06
WELCOME, PONG, KICK, PAIRED, CHALLENGE = 0x81, 0x84, 0x85, 0x86, 0x87
HEADER = struct.Struct('<IBBHI')


def mac(key, label, host, client, extra=b''):
    return hmac.new(key, label + struct.pack('<QQ', host, client) + extra, hashlib.sha256).digest()


def name(s):
    b = s.encode()
    return bytes([len(b)]) + b


class Phone:
    def __init__(self, port, client):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(2)
        self.to = ('127.0.0.1', port)
        self.client = client
        self.seq = 0

    def send(self, kind, payload):
        self.seq += 1
        self.sock.sendto(HEADER.pack(MAGIC, VERSION, kind, 0, self.seq) + payload, self.to)

    def recv(self, want):
        while True:
            data, _ = self.sock.recvfrom(2048)
            magic, version, kind, _, _ = HEADER.unpack_from(data)
            assert magic == MAGIC and version == VERSION, data[:8]
            if kind == want:
                return data[HEADER.size:]
            if kind == KICK and want != KICK:
                raise AssertionError(f'kicked, reason {data[HEADER.size]}')

    def hello(self, sides=3, auth=b''):
        self.send(HELLO, struct.pack('<QBBBB', self.client, sides, 1, 3, 0) + name('Test phone') + auth)

    def pair(self, method, secret, host, nonce):
        proof = mac(secret, b'NXPD pair', host, self.client, nonce)
        self.send(PAIR, struct.pack('<QB3x', self.client, method) + nonce + proof + name('Test phone'))
        body = self.recv(PAIRED)
        result, = struct.unpack_from('<B', body)
        got_host, = struct.unpack_from('<Q', body, 8)
        return result, got_host, body[16:32], body[32:64]

    def join(self, host, key, sides=3):
        """HELLO, the challenge, the answer: the player WELCOME gives."""
        self.hello(sides)
        body = self.recv(CHALLENGE)
        chal_host, = struct.unpack_from('<Q', body)
        assert chal_host == host, (hex(chal_host), hex(host))
        chal = body[8:24]
        self.hello(sides, b'\0' * 32)   # a wrong answer: the same challenge again, still good
        again = self.recv(CHALLENGE)
        assert again[8:24] == chal
        self.hello(sides, mac(key, b'NXPD hello', host, self.client, chal + bytes([sides])))
        self.welcome = self.recv(WELCOME)
        return self.welcome[0]


def touch_line(proc):
    """What the receiver handed the game's touch screen next ("2 0:0.500,0.250 1:..."): the test front end prints each dm_touch_set."""
    while True:
        line = proc.stderr.readline()
        assert line, 'the receiver ended'
        if line.startswith('[test] touch '):
            return line[len('[test] touch '):].strip()


def finger(slot, x, y):
    return struct.pack('<BHH', slot, x, y)


def start(binary, folder, pair):
    env = dict(os.environ, DM_NXPAD='auto', DM_NXPAD_DIR=folder, DM_NXPAD_PORT='0', DM_NXPAD_TEST_PAIR='1' if pair else '0')
    p = subprocess.Popen([binary], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    line = p.stdout.readline().split()
    assert line and line[0] == 'READY', line
    return p, int(line[1]), line[2], line[3]


def main():
    binary = sys.argv[1]
    procs = []
    with tempfile.TemporaryDirectory() as folder:
        try:
            # A game with no phone paired listens only once its pairing window is open
            p, port, _, _ = start(binary, folder, pair=False)
            procs.append(p)
            assert port == 0, 'listening with no phone paired and no pairing window'
            p.kill()

            p, port, code, url = start(binary, folder, pair=True)
            procs.append(p)
            assert port and len(code) == 6 and url.startswith('nxpad://pair?'), (port, code, url)
            q = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(url).query))
            host = int(q['m'], 16)
            assert q['v'] == '2' and int(q['p']) == port and len(q['k']) == 32 and q['g'], q

            a = Phone(port, 0x1111)
            a.hello()
            assert a.recv(KICK)[0] == 4, 'an unpaired phone is not kicked as not paired'

            wrong = f'{(int(code) + 1) % 1000000:06d}'.encode()
            n1 = secrets.token_bytes(16)
            for _ in range(3):   # sent again: the same answer, one try counted
                result, got, _, _ = a.pair(1, wrong, host, n1)
                assert result == 1 and got == host, result
            n2 = secrets.token_bytes(16)
            result, got, hn, confirm = a.pair(1, code.encode(), host, n2)
            assert result == 0 and got == host, 'the right code did not pair (the wrong one counted more than once?)'
            key = mac(code.encode(), b'NXPD key', host, a.client, n2 + hn)
            assert hmac.compare_digest(confirm, mac(key, b'NXPD paired', host, a.client)), 'PAIRED does not prove the same key'
            again = a.pair(1, code.encode(), host, n2)   # PAIRED lost: the same PAIR again gets the same answer
            assert again == (0, host, hn, confirm)
            with open(os.path.join(folder, 'paired.tsv')) as f:
                assert f'{a.client:016x}\t{key.hex()}\t' in f.read()
            assert oct(os.stat(os.path.join(folder, 'paired.tsv')).st_mode & 0o777) == '0o600'

            assert a.join(host, key) == 0, 'the paired phone is not player 1'
            a.send(PING, struct.pack('<Q', 12345))
            assert struct.unpack('<Q', a.recv(PONG)[:8])[0] == 12345

            # The touch area: WELCOME says this host takes it, the fingers go to the game's touch screen as a set, an empty set lifts them, and a phone that goes
            # takes its fingers with it
            assert a.welcome[3] & 4, 'WELCOME does not say the host takes TOUCH'
            a.send(TOUCH, bytes([2]) + finger(0, 0x8000, 0x4000) + finger(3, 0, 0xFFFF))
            assert touch_line(p) == '2 0:0.500,0.250 3:0.000,1.000'
            a.send(TOUCH, bytes([1]) + finger(0, 0x8000, 0x4000))
            assert touch_line(p) == '1 0:0.500,0.250'
            a.send(TOUCH, bytes([0]))
            assert touch_line(p) == '0'

            # A second phone, by the QR code's token: the code changed with the first pairing, the token too
            p.stdout.close()
            b = Phone(port, 0x2222)
            result, _, _, _ = b.pair(2, bytes.fromhex(q['k']), host, secrets.token_bytes(16))
            assert result == 1, 'an old QR code still paired'

            # Another game on the same Mac: auto listens (a phone is paired) and takes the first phone with the same key
            p2, port2, code2, _ = start(binary, folder, pair=False)
            procs.append(p2)
            assert port2 and port2 != port and code2 == '-', (port2, code2)
            a2 = Phone(port2, a.client)
            assert a2.join(host, key) == 0, 'the second game did not take the paired phone'
            c = Phone(port2, 0x3333)
            c.hello()
            assert c.recv(KICK)[0] == 4
        finally:
            for p in procs:
                p.kill()
    print('t_netpad_host: ok')


if __name__ == '__main__':
    main()
