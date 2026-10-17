<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# QUUX's Ethernet device

QUUX revision 16 adds an Ethernet device to the register page, at words 240
to 257, with its interrupt at word 100 `<8>` and its feature bit at word 15
`<2>`. QUUX moves Ethernet frames through two rings in its main memory: a
transmit ring of frames to send, and a receive ring of buffers to fill. The
device understands IPv4. It fills in the IPv4 header checksum and the TCP, UDP
and ICMP checksums of every frame it sends, checks them on every frame it
receives, and takes only IPv4 and ARP. muir's `src/ethernet_device.rs` and
`src/ethernet_offload.rs` define the machine's side: what each register reads,
what each write does, the rings, and what is done to a frame's bytes.

On a board the registers are in the fabric, and the device's other half is a
Linux program, `quux-ethernet-device`. It sends each frame the transmit ring
names to a tap on the board's Linux, `quux0`, and delivers each frame the tap
gives into the receive ring. This page describes the program and the fabric's
page it reaches.

The device is QUUX revision 16's alone. A CADR bitstream and older QUUX
revisions have no page for it, and the default slave answers its address.

## What QUUX reaches on a board

`quux0` is a host-only link between the board's Linux and QUUX. The board's
side has the address `--ip-gateway` names, on `--ip-address`'s subnet, and
QUUX has `--ip-address`. Nothing is forwarded, translated or routed onto the
board's network. So QUUX reaches the board's Linux alone, and nothing on the
network reaches QUUX. QUUX's MAC address never appears on
the network, and no frame from the network reaches QUUX's memory.

Before the tap comes up, the init script gives it what muir-sim's `quux-taps`
gives every tap of a build host's pool:

- IPv6 off, where the kernel has IPv6, so Linux sends nothing of IPv6 on the
  link. The Arty Z7-20's kernel has no IPv6 at all.
- `arp_ignore` 2, so Linux answers an ARP request only for the tap's own
  address and from a sender on the tap's subnet.
- `rp_filter` 1, strict.
- The MAC address `02:00:00:00:00:02` on the board's side, and an MTU of 1500,
  so no frame is longer than the device's 1,514 bytes.

BusyBox's `tunctl` makes `quux0` as a persistent tap. The program opens it
`IFF_TAP | IFF_NO_PI`, never with a virtio-net header, and never asks for an
offload. The kernel therefore takes each frame the program writes as complete,
with its checksums filled in, and checks every one of them as it would a frame
off a wire. The board's Linux is one witness that the device's checksums are
right.

## The flags

The flags are muir's, with muir's meanings, defaults and refusals. The card
gives them in `fpgarc` (`docs/fpgarc.md`).

    --ethernet-mac XX:XX:XX:XX:XX:XX   words 253-254, and the address the
                                       filter takes besides broadcast
                                       [default 02:00:00:00:00:01]
    --ip-address A.B.C.D/N             words 255-256, QUUX's address and
                                       prefix length, N from 1 to 30
                                       [default 169.254.100.2/30]
    --ip-gateway A.B.C.D               word 257, the gateway: the tap's address
                                       [default 169.254.100.1]
    --ethernet-trace                   every frame sent and received, and why
                                       one is refused or dropped, to the log

The defaults are QUUX's side of `quux0` and the link's other end, the same
addresses muir uses behind a build host's first tap. A MAC address with the
group bit set is refused. An address that is no host's is refused: in 0/8,
127/8 or from 224.0.0.0 up, or its subnet's network or broadcast address.
There is always a gateway, and it is refused when it is 0.0.0.0, QUUX's own
address, off the address's subnet, or the subnet's network or broadcast
address. Each refusal is muir's sentence, word for word.

The program also takes `--no-guard`, which skips the fabric guard, and
`--log <file>`, which may be given more than once. `cadr_daemon` gives it the
console and `/var/log/quux-ethernet-device.log`.

## What the program does with a frame

**Transmit.** The program takes the entries from 245 up to 244, in order. An
entry is refused when its length is outside 14 to 1,514 bytes, when its frame
is off an 8-word line or runs past main memory, when its type is neither IPv4
nor ARP, or when an IPv4 frame is not well-formed. A refused entry is counted
in 241 `<31:24>`, and 245 passes it. Every other frame is read out of main
memory, its checksums are filled in on the copy, and the copy is written to
the tap. A transmit writes no word of QUUX's memory.

**Receive.** A frame the tap gives while the device is disabled is read and
discarded, and counted nowhere. Otherwise the checks come in muir's order:

1. the MAC address filter, the device's own address or broadcast, which
   counts nothing;
2. the type filter, IPv4 and ARP only, counted in 241 `<7:4>`;
3. the IPv4 checks, a malformed frame or a wrong checksum, counted in 241
   `<15:9>`;
4. a buffer: none given (250 = 251), one shorter than the frame, one off a
   line or past main memory, or a frame longer than 1,514 bytes, counted in
   241 `<23:16>`.

None of these touches QUUX's memory. A frame that passes is written into the
buffer at slot 251, the bytes past its end in the last word 0 and no word past
it. Its length goes into the entry's word 2, every word a fixnum, and then 251
moves.

The program's log names the cause of every refusal and drop counted in 241,
since each is a fault in the band. It says at most ten lines a second and
counts the rest. `--ethernet-trace` says every frame, with no limit.

The program waits in `poll()` on the tap with a 1 ms timeout, which also paces
its reads of the page. A transmit posted while the tap is quiet goes out
within a millisecond.

## The page

One 4 KB page on the processor-to-fabric port the other faces use, at the pack
side's base + `0x5000` on every board. It is the sixth page and the first free
one above the file device's. Every access is one aligned 32-bit word.

| Offset | | |
|---|---|---|
| `0x000` IDENT | read | `QE16`, `0x51453136` |
| `0x004` MEM_WORDS | read | main memory, in words |
| `0x100` STATE | read | `<0>` enabled, `<1>` interrupt enable, `<2>` busy, `<3>` quiet, `<31:16>` the epoch |
| `0x104` CLAIM | read, write | `{epoch, <0> 1}` takes the claim if enabled and the epoch matches; `<0>` 0 drops it; reads busy |
| `0x108` TX_BASE, `0x10C` TX_LOG2 | read | 242 `<27:0>` and 243 |
| `0x110` RX_BASE, `0x114` RX_LOG2 | read | 246 `<27:0>` and 247 |
| `0x118` TX_PROD | read | 244, once the processor's writes before it have drained |
| `0x11C` TX_CONS | read, write | 245; `{epoch, index}` moves it, ignored under a stale epoch |
| `0x120` RX_PROD | read | 250, once the processor's writes before it have drained |
| `0x124` RX_CONS | read, write | 251; `{epoch, index}` makes the cache coherent and then moves it, ignored under a stale epoch |
| `0x128` RX_TAKEN | read | 252 |
| `0x12C` COUNTS | read, write | 241's four counters in 241's own places; a write sets all four |
| `0x130`-`0x140` | read, write | 253-257, the host's |

**The claim and the epoch are the file device's.** A disable is the device's
reset, and after it the machine may reuse its rings and buffers once 241
`<1>`, quiet, reads 1. On a board, quiet means not enabled and not busy, and
busy is the program's claim. The program takes the claim before it touches
QUUX's memory and drops it after. The fabric counts every disable in the
epoch, and it refuses a claim, a TX_CONS write or an RX_CONS write that carries
an epoch other than its own. So a delivery that a disable overtakes may write
memory while its claim holds quiet low, but it never moves 251. The program
drops any claim it finds at its start.

**The four counters are the program's to count and the fabric's to keep.**
Only the program sees a dropped frame, because the fabric never reads a frame's
bytes. The fabric holds the counters, at 0 from power-on, and no disable or
reset changes them. A program started again reads them back and counts on.

**253-257 come up holding muir's defaults**, and the program writes the
card's values at its start. No reset changes them.

**The barrier before the delivery.** A buffer's words and the entry's word 2
are written through an uncached mapping of DDR, and RX_CONS is written after
`__sync_synchronize()` and a `dsb sy`, as the file device's completion is.

**The fabric's side of this page is not built yet.** It belongs with revision
16's machine side. Besides the offsets above, the fabric owes the rules of
muir's device that are the machine's: the configuration and its refusal at
the enable, the index rules and their fault, the indexes reading 0 while
disabled, status `<8>` and word 100 `<8>`, and the cache's coherence when
RX_CONS moves. The program's check runs against a model of exactly those
rules (below).

## What holds it

`make check`'s `quux_ethernet_device.pass` runs the package's own check:

- **muir's device and the program agree.** `golden/src/quux_ethernet_device.rs`
  runs muir's `EthernetDevice` over each of the package's scripts
  (`qed_scenarios.py`). `qed_test` runs the program's own step, face and rules
  over the same scripts, against a model of the fabric's page. The two
  transcripts must be the same bytes: every trace line, every frame sent,
  registers 240 to 257 and a digest of main memory, after every step. The
  scripts cover every refusal and every drop, each counter past its width,
  rings of 1, 2 and 256 entries, the index and configuration rules, the host's
  words, and every frame of the checksum vectors through both devices.
- **The checksum vectors.** muir-sim's `tests/ethernet_vectors.txt` is read
  from the pinned muir. Every case must give the file's result, and the
  file's results come from frames Linux made and from a checker written apart
  from both implementations.
- **The flags.** `qed_flags.txt` is a list of questions about the three
  flags, answered by muir's own parsers and by the program's. The answers must
  be the same bytes.
- **The unit checks**: the page's offsets on a plain page, the order of a
  delivery on the page, a disable in the middle of a delivery, an epoch moved
  before the claim, the counters read back by a program started again, both
  directions across 2^16, packed storage's alignment from any word, the log,
  and the tap's flags.
- **The mutation list.** Every record in `qed_mutations.txt` breaks the
  program in one way, and the check must fail on each one.

The model of the page is what the fabric owes, written from muir's device. The
fabric itself is held to muir with the rest of revision 16's machine side.
