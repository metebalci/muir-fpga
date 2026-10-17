#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The scripts `qed_compare.py` runs through muir's own Ethernet device
# (`golden/src/quux_ethernet_device.rs`) and through this program over a
# model of the fabric's page (`qed_test --script`).  The format is the
# golden's, in its header.  `scenarios(vectors)` returns (name, text) pairs;
# `vectors` is muir-sim's `tests/ethernet_vectors.txt`, whose frames the
# last scenarios put through both devices whole, both ways.
#
# The layout every scenario uses, unless it says otherwise: main memory of
# 16,384 words; the transmit ring at 0 and the receive ring at 2048; sixteen
# receive buffers from 4096, two to a 1,024-word page, 384 words (1,536
# bytes) each; transmit frames from 10240, each on lines of its own.  Every word the device writes is
# poisoned first, under a tag the device must never write, so that a word
# written anywhere, or a fixnum's tag left off, moves the digest.

TX, RX, BUFS, FRAMES = 0, 2048, 4096, 10240
MEMORY = 16384
MAC = bytes.fromhex("020000000001")
PEER = bytes.fromhex("020000000002")
BROADCAST = b"\xff" * 6
POISON = "0x3fdeadbeef"


def be16(v):
    return bytes([v >> 8 & 255, v & 255])


def ones_sum(b):
    if len(b) % 2:
        b = b + b"\0"
    s = sum(b[i] << 8 | b[i + 1] for i in range(0, len(b), 2))
    while s > 0xFFFF:
        s = (s & 0xFFFF) + (s >> 16)
    return s


def ether(dst, typ, payload, src=PEER):
    return dst + src + be16(typ) + payload


def arp(dst=BROADCAST, op=1):
    body = be16(1) + be16(0x0800) + bytes([6, 4]) + be16(op) + PEER + bytes([169, 254, 100, 1]) \
        + b"\0" * 6 + bytes([169, 254, 100, 2])
    return ether(dst, 0x0806, body)


def ipv4(proto, payload, dst=MAC, fill=True, ttl=64, ident=0x1234, flags=0x4000):
    tl = 20 + len(payload)
    h = bytearray(bytes([0x45, 0]) + be16(tl) + be16(ident) + be16(flags) + bytes([ttl, proto])
                  + b"\0\0" + bytes([169, 254, 100, 1, 169, 254, 100, 2]))
    if fill:
        c = 0xFFFF - ones_sum(bytes(h))
        h[10:12] = be16(c)
    return ether(dst, 0x0800, bytes(h) + payload)


def udp(data, dst=MAC, fill=True, sport=40000, dport=9):
    u = bytearray(be16(sport) + be16(dport) + be16(8 + len(data)) + b"\0\0" + data)
    if fill:
        pseudo = bytes([169, 254, 100, 1, 169, 254, 100, 2, 0, 17]) + be16(len(u))
        c = 0xFFFF - ones_sum(pseudo + bytes(u))
        u[6:8] = be16(c or 0xFFFF)
    return ipv4(17, bytes(u), dst=dst, fill=fill)


def hexed(b):
    return b.hex() if b else "-"


class Script:
    def __init__(self, tx_log2=3, rx_log2=3, memory=MEMORY, host=None):
        self.lines = [f"memory {memory}"]
        if host:
            self.lines.append(f"host {host}")
        self.tx_log2, self.rx_log2 = tx_log2, rx_log2
        self.tx_prod = self.rx_prod = 0
        self.lines.append(f"fill 0 {memory} {POISON}")
        self.lines.append(f"rings {TX} {tx_log2} {RX} {rx_log2}")

    def op(self, *words):
        self.lines.append(" ".join(str(w) for w in words))
        return self

    def tx_entry(self, index, addr, length, tag=5):
        e = TX + 8 * (index % (1 << self.tx_log2))
        self.op("word", e, hex(tag << 32 | addr))
        self.op("word", e + 1, hex(tag << 32 | length))
        for k in range(2, 8):
            self.op("word", e + k, 0)

    def frame_at(self, addr, frame, tag=5):
        if frame:
            self.op("bytes", addr, frame.hex(), tag)

    def send(self, *frames, post=True):
        """Each frame into memory on lines of its own, an entry for it, and
        244 after each, or once after them all when not `post`."""
        spacing = max(8, -(-max(len(f) for f in frames) // 32) * 8)
        slots = (MEMORY - FRAMES) // spacing
        assert post or len(frames) <= slots, "a batch's frames overlap"
        for k, f in enumerate(frames):
            addr = FRAMES + spacing * (k % slots)
            self.frame_at(addr, f)
            self.tx_entry(self.tx_prod, addr, len(f))
            self.tx_prod = (self.tx_prod + 1) & 0xFFFF
            if post:
                self.op("write", "244", self.tx_prod)

    def give(self, n, room=1536, tag=5, at=None):
        """`n` buffers given to the device, entries and 250."""
        for _ in range(n):
            e = RX + 8 * (self.rx_prod % (1 << self.rx_log2))
            slot = self.rx_prod % 16
            buf = at if at is not None else BUFS + 384 * slot
            self.op("word", e, hex(tag << 32 | buf))
            self.op("word", e + 1, hex(tag << 32 | room))
            self.op("word", e + 2, POISON)
            self.rx_prod = (self.rx_prod + 1) & 0xFFFF
        self.op("write", "250", self.rx_prod)

    def reenable(self, ie=0):
        """A disable and an enable: the indexes back to 0."""
        self.op("disable")
        self.op("enable", ie)
        self.tx_prod = self.rx_prod = 0

    def text(self):
        return "\n".join(self.lines) + "\n"


def vector_frames(path):
    rx, tx = [], []
    for line in open(path):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        name, direction, frame, _ = line.split(" ", 3)
        b = bytes.fromhex(frame)
        (rx if direction == "rx" else tx).append((name, b))
    return rx, tx


def scenarios(vectors):
    out = []

    s = Script()
    s.op("enable", 0)
    s.send(arp())
    s.op("run")
    s.send(udp(b"one frame, its checksums left 0", fill=False))
    s.op("run")
    out.append(("transmit", s.text()))

    # Every refusal muir's `send` makes, each counted in <31:24> and passed
    # by 245, and a frame after them that is sent.
    s = Script(tx_log2=4)
    s.op("enable", 0)
    s.frame_at(FRAMES, arp())
    for addr, length in [(FRAMES, 13), (FRAMES, 1515), (FRAMES, 0), (FRAMES, 0xFFFFFFFF),
                         (FRAMES + 1, 42), (FRAMES + 4, 42), (MEMORY - 8, 42), (MEMORY - 16, 42),
                         (MEMORY - 16, 64), (MEMORY - 16, 65),
                         (0o1777777770, 42)]:
        s.tx_entry(s.tx_prod, addr, length)
        s.tx_prod += 1
    for k, f in enumerate([ether(PEER, 0x86DD, b"\0" * 40), ether(PEER, 0x0804, b"\0" * 46),
                           ether(PEER, 0x8100, b"\0" * 46), ipv4(6, b"\0" * 10, dst=PEER, fill=False),
                           arp()]):
        addr = FRAMES + 64 * (k + 1)
        s.frame_at(addr, f)
        s.tx_entry(s.tx_prod, addr, len(f))
        s.tx_prod += 1
    s.op("write", "244", s.tx_prod)
    s.op("run")
    out.append(("transmit-refusals", s.text()))

    # An address's high bits past <27:0> are not the device's, and a word's
    # tag is never read: an entry under tag 1 and an address with <31:28> set.
    s = Script()
    s.op("enable", 0)
    s.frame_at(FRAMES, arp(), tag=1)
    s.tx_entry(0, 0xF0000000 | FRAMES, 42, tag=1)
    s.op("write", "244", 1)
    s.op("run")
    out.append(("transmit-tags", s.text()))

    # Rings of 1, 2 and 256 entries, wrapped.
    for log2, count in [(0, 5), (1, 7), (8, 300)]:
        s = Script(tx_log2=log2)
        s.op("enable", 0)
        for k in range(count):
            s.send(udp(bytes([k & 255]) * (k % 30), fill=False))
            if k % 97 == 96:
                s.op("run")
        s.op("run")
        out.append((f"transmit-ring-{1 << log2}", s.text()))

    # A batch posted at once, the ring's size of it.
    s = Script(tx_log2=3)
    s.op("enable", 0)
    s.send(*[arp(op=1 + k % 2) for k in range(8)], post=False)
    s.op("write", "244", 8)
    s.op("run")
    out.append(("transmit-batch", s.text()))

    s = Script()
    s.op("enable", 1)
    s.give(4)
    s.op("arrive", hexed(arp()))
    s.op("arrive", hexed(udp(b"to us")))
    s.op("arrive", hexed(udp(b"broadcast", dst=BROADCAST)))
    s.op("run")
    s.op("write", "252", 2)
    s.op("run")
    s.op("write", "252", 3)
    s.op("run")
    out.append(("receive", s.text()))

    # Every drop muir's `deliver` makes for a buffer.  A bad buffer stays at
    # 251 and every later frame drops on it until a disable, so each case
    # comes after a disable and an enable of its own.
    s = Script(rx_log2=4)
    s.op("enable", 0)
    s.op("arrive", hexed(udp(b"no buffer yet")))
    for room, at, f in [(40, None, udp(b"a buffer too short for me, forty bytes")),
                        (1536, BUFS + 1, arp()),
                        (1536, BUFS + 4, arp()),
                        (1536, MEMORY - 8, udp(b"past main memory")),
                        (1536, MEMORY - 16, udp(b"one word past main memory")),
                        (1536, MEMORY - 16, udp(b"to the last word, 64!!")),
                        (1536, 0xF0000000 | BUFS, arp()),
                        (1536, MEMORY - 24, arp()),
                        (1536, 0o1777777770, arp()),
                        (41, None, arp()),
                        (42, None, arp())]:
        s.reenable()
        s.give(1, room=room, at=at)
        s.op("arrive", hexed(f))
        s.op("arrive", hexed(arp()))
        s.op("run")
    out.append(("receive-buffers-bad", s.text()))

    s = Script(rx_log2=3)
    s.op("enable", 0)
    s.give(8)
    for f in [ether(bytes.fromhex("020000000003"), 0x0806, arp()[14:]),   # another station
              ether(bytes.fromhex("030000000001"), 0x0806, arp()[14:]),   # a group address
              b"\x02\x00\x00\x00\x00",                                    # no destination
              b"",
              MAC + PEER + b"\x08",                                       # 13 bytes
              ether(MAC, 0x86DD, b"\0" * 40), ether(MAC, 0x0804, b"\0" * 46),
              ether(MAC, 0x8100, b"\0" * 46), ether(MAC, 0x88CC, b"\0" * 46),
              ether(MAC, 0x0000, b"\0" * 46),
              ipv4(17, b"\0" * 8, fill=False),                            # header checksum 0
              udp(b"bad", fill=True)[:-1] + b"\x00",                      # payload changed
              ipv4(6, b"\0" * 19),                                        # TCP under 20
              arp() + b"\0" * 1472,                                       # 1,514 bytes: delivered
              arp() + b"\0" * 1473]:                                      # 1,515: too long
        s.op("arrive", hexed(f))
    s.op("run")
    out.append(("receive-filters", s.text()))

    # The frames arrived while disabled go nowhere and count nowhere; then
    # the device enabled takes the next.
    s = Script()
    s.give(2)
    s.op("arrive", hexed(arp()))
    s.op("enable", 0)
    s.give(2)
    s.op("arrive", hexed(arp()))
    s.op("disable")
    s.op("arrive", hexed(arp()))
    s.op("run")
    out.append(("receive-disabled", s.text()))

    # Odd lengths: the bytes past the end in the last word are 0, and no word
    # past it is written.
    s = Script(rx_log2=3)
    s.op("enable", 0)
    s.give(8)
    for n in [42, 43, 44, 45, 46, 60, 61, 1514]:
        f = ether(MAC, 0x0806, bytes(range(256)) * 6)[:n]
        s.op("arrive", hexed(f))
    s.op("run")
    out.append(("receive-lengths", s.text()))

    # Rings of 1 and 256 entries, wrapped, taken back as they fill.
    for log2, count in [(0, 4), (8, 300)]:
        s = Script(rx_log2=log2)
        s.op("enable", 0)
        taken = 0
        for k in range(count):
            if s.rx_prod - taken < (1 << log2):
                s.give(1)
            s.op("arrive", hexed(udp(bytes([k & 255]) * (k % 40))))
            if k % 50 == 49 or log2 == 0:
                s.op("run")
            taken = (taken + 1) & 0xFFFF
            s.op("write", "252", taken)
        s.op("run")
        out.append((f"receive-ring-{1 << log2}", s.text()))

    # The counters, each past its width: 17 by type, 130 by the IPv4 checks,
    # 260 with no buffer, 260 refused.
    s = Script(tx_log2=8)
    s.op("enable", 0)
    for _ in range(17):
        s.op("arrive", hexed(ether(MAC, 0x86DD, b"\0" * 40)))
    for _ in range(130):
        s.op("arrive", hexed(ipv4(17, b"\0" * 8, fill=False)))
    for _ in range(260):
        s.op("arrive", hexed(arp()))
    s.frame_at(FRAMES, ether(PEER, 0x86DD, b"\0" * 40))
    for k in range(260):
        s.tx_entry(k, FRAMES, 54)
        s.op("write", "244", k + 1)
    s.op("run")
    out.append(("counters-wrap", s.text()))

    # Each counter shows its drop at once: a `run` after each, with nothing
    # between that would write the counters again.
    s = Script()
    s.op("enable", 0)
    for f in [ether(MAC, 0x86DD, b"\0" * 40), ipv4(17, b"\0" * 8, fill=False), arp()]:
        s.op("arrive", hexed(f))
        s.op("run")
    s.frame_at(FRAMES, ether(PEER, 0x86DD, b"\0" * 40))
    s.tx_entry(0, FRAMES, 54)
    s.op("write", "244", 1)
    s.op("run")
    out.append(("counts-at-once", s.text()))

    # The index rules and the configuration's: each fault in <3>, each
    # refusal in <2>, a write of 240 clearing both; and what a disable, a
    # reset and the counters do.
    s = Script(tx_log2=2, rx_log2=2)
    s.op("write", "244", 1)                  # disabled: nowhere
    s.op("enable", 0)
    s.op("run")
    s.op("write", "244", 5)                  # more than the ring
    s.op("run")
    s.op("enable", 0)
    s.op("write", "250", 5)
    s.op("run")
    s.op("enable", 0)
    s.give(2)
    s.op("write", "252", 1)                  # past 251
    s.op("run")
    s.op("write", "250", 1)                  # backwards
    s.op("run")
    s.op("arrive", hexed(ether(MAC, 0x86DD, b"\0" * 40)))
    s.op("disable")
    s.op("run")
    s.op("rings", TX + 1, 2, RX, 2)          # off a line: refused
    s.op("enable", 0)
    s.op("run")
    s.op("rings", TX, 9, RX, 2)              # over 8
    s.op("enable", 0)
    s.op("run")
    s.op("rings", TX, 2, MEMORY - 16, 2)     # past main memory
    s.op("enable", 0)
    s.op("run")
    s.op("rings", TX, 2, RX, 2)
    s.op("enable", 1)
    s.op("write", "250", 9)
    s.op("run")
    s.op("reset")
    s.op("run")
    out.append(("registers", s.text()))

    # Another host: 253-257 read back, the filter takes the MAC address
    # given, and the default one no longer.
    s = Script(host="02:12:34:56:78:9a 192.0.2.10/24 192.0.2.1")
    s.op("enable", 0)
    s.give(2)
    s.op("arrive", hexed(ether(bytes.fromhex("02123456789a"), 0x0806, arp()[14:])))
    s.op("arrive", hexed(arp(dst=MAC)))
    s.op("run")
    out.append(("host", s.text()))

    # muir-sim's checksum vectors, whole, both ways: every `rx` frame
    # arrives at the device, and every `tx` frame is sent from the ring.
    rx, tx = vector_frames(vectors)
    for part in range(0, len(rx), 60):
        s = Script(rx_log2=6)
        s.op("enable", 0)
        s.give(64)
        for name, f in rx[part:part + 60]:
            s.op("#", name)
            s.op("arrive", hexed(f))
        s.op("run")
        out.append((f"vectors-rx-{part // 60}", s.text()))
    for part in range(0, len(tx), 60):
        s = Script(tx_log2=6)
        s.op("enable", 0)
        for name, f in tx[part:part + 60]:
            s.op("#", name)
            s.send(f)
        s.op("run")
        out.append((f"vectors-tx-{part // 60}", s.text()))
    return out
