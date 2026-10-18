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

QUUX's address decides what `quux0` is, by one rule:

- **An address in 169.254.x.y makes a host-only tap.** The board's side
  has the address `--ip-gateway` names, on `--ip-address`'s subnet. Nothing is
  forwarded and no ARP is answered for QUUX on the board's network, so QUUX
  reaches the board's Linux alone and nothing on the network reaches QUUX.
  muir's defaults are link-local, so a card that names no address is
  host-only.
- **Any other address makes a LAN tap.** QUUX is then a computer on the
  board's LAN, with its own address on the LAN's subnet and the LAN's router
  as its gateway. The board's Linux answers ARP on its LAN interface for
  QUUX's address and no other, and forwards between the LAN interface and
  `quux0`.
- **A card that mixes the two is refused** before anything is touched: a
  link-local `--ip-address` with a gateway that is not link-local, or the
  reverse. So the board never holds the LAN router's address.

Link-local is the line because a router must not forward a packet with a
link-local source or destination address (RFC 3927, section 2.7). A link-local
QUUX cannot be on the LAN by forwarding, and a QUUX on the LAN is never
link-local. The rule reads QUUX's own flags only and adds no flag.

In either mode QUUX's MAC address stays on `quux0`: on a LAN tap the board
answers ARP on the LAN with its own MAC address. The board forwards no
broadcast from the LAN to QUUX.

### A host-only tap

Before the tap comes up, the init script gives it what muir-sim's `quux-taps`
gives every tap of a build host's pool:

- IPv6 off, where the kernel has IPv6, so Linux sends nothing of IPv6 on the
  link. The Arty Z7-20's kernel has no IPv6 at all.
- `arp_ignore` 2, so Linux answers an ARP request only for the tap's own
  address and from a sender on the tap's subnet.
- `rp_filter` 1, strict.
- `proxy_arp` 0 and `forwarding` 0.
- The MAC address `02:00:00:00:00:02` on the board's side, and an MTU of 1500,
  so no frame is longer than the device's 1,514 bytes.
- The address `--ip-gateway` names, with `--ip-address`'s prefix.

### A LAN tap

The init script sets it up in this order, so that nothing is touched before
the mode is certain and the board never answers for QUUX before it can
deliver to QUUX:

1. The flags are checked and the LAN interface is found. On any failure the
   script refuses and touches nothing.
2. `quux0` is made, if it is not there, and then the link-local rule below,
   before any forwarding is turned on.
3. On `quux0`: IPv6 off, `arp_ignore` 0, `arp_filter` 1, `rp_filter` 1,
   `proxy_arp` 1, `forwarding` 1, and the proxy delay 0.
4. The tap's MAC address and MTU as above, its addresses flushed, and **no
   address on the tap**, since one would be answered on the LAN too.
5. The tap comes up.
6. A host route, `QUUX's address/32 dev quux0`.
7. On the LAN interface: `forwarding` 1 and the proxy delay 0. Their old
   values are kept in a run file under `/var/run`.
8. One proxy entry for QUUX's address on the LAN interface, made with
   BusyBox's `arp -i L -Ds Q L pub`. A proxy entry the LAN interface has for
   any other address is removed first.
9. If the LAN interface has an address already, QUUX's must not be that
   address, and the script undoes the tap and refuses. If QUUX's address is
   off the LAN interface's subnet, or its prefix differs, the script warns.
10. The program starts.

`arp_ignore` 0 and `arp_filter` 1 let the board answer QUUX for the board's own
addresses, but only when the route back to the sender goes out of `quux0`.
`proxy_arp` 1 on `quux0` answers QUUX for every address routed out of another
interface: the LAN's machines, its router and anything beyond. The proxy
delay is 0 so that no first contact waits for a proxied reply.

Nothing else on the board changes. The LAN interface keeps its address, its
DHCP lease and its routes. It never gets `proxy_arp`, which would answer for
every address routed out of another interface. The global `ip_forward` is
never written, because writing it resets every interface's settings.

With a LAN tap, packets for link-local destinations (169.254.x.y) arriving
on the LAN interface or from QUUX's tap are dropped. Routers never forward a
link-local address (RFC 3927, section 2.7), so nothing on the LAN, and no QUUX
on a LAN tap, reaches a host-only tap's machine through the board. Two routing
rules of type blackhole do it, `iif` the LAN interface and `iif quux0`, at
priority 1169. That is after the local table's rule at priority 0, so the
board's own link-local addresses still answer, and the board's own traffic is
not touched, since each rule names an input interface. The start first
removes every rule at priority 1169, which belongs to these two alone, and a
host-only start removes them and adds none. The rules need the kernel's
policy routing (`CONFIG_IP_ADVANCED_ROUTER` and `CONFIG_IP_MULTIPLE_TABLES`,
which every board's kernel sets). Without it `ip rule add` fails, and the
script undoes the tap, says so, naming `CONFIG_IP_MULTIPLE_TABLES`, and starts
nothing.

The stop undoes the start in reverse: it stops the program, removes the proxy
entry the start made, puts the LAN interface's `forwarding` and proxy delay
back to the values the start found, removes the rules at priority 1169, and
removes the tap, which takes its route and its settings with it.

### The LAN interface on each board

The LAN interface is the image's DHCP interface. The script reads it from the
one `iface X inet dhcp` line in `/etc/network/interfaces`, which Buildroot
writes from the defconfig's `BR2_SYSTEM_DHCP`. With no such line, or with
more than one, a LAN tap is refused.

| Board | LAN interface |
|---|---|
| Arty Z7-20 | `eth0` |
| Cora Z7-07S | `eth0` |
| DE25-Nano | `eth0` |
| Kria KR260 | `eth1`, the J10C jack (GEM1) |

On a board with more than one Ethernet port, such as the Kria KR260, QUUX is
reached only through the LAN interface. The proxy entry is on that interface
alone, and forwarding is on for it and `quux0` alone. The other ports neither
answer ARP for QUUX nor forward to it. The LAN interface is the one port the
board's own image brings up with an address, so it is the port the board is
reached by.

The script never waits for the DHCP lease, which may come after it runs. No
step needs the LAN interface's address, and step 9 is skipped while the
interface has none.

### The tap itself

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
                                       on a host-only tap, the LAN's router
                                       on a LAN tap [default 169.254.100.1]
    --ethernet-trace                   every frame sent and received, and why
                                       one is refused or dropped, to the log

The defaults are QUUX's side of `quux0` and the link's other end, the same
addresses muir uses behind a build host's first tap. A MAC address with the
group bit set is refused. An address that is no host's is refused: in 0/8,
127/8 or from 224.0.0.0 up, or its subnet's network or broadcast address.
There is always a gateway, and it is refused when it is 0.0.0.0, QUUX's own
address, off the address's subnet, or the subnet's network or broadcast
address. Each refusal is muir's sentence, word for word. The init script
refuses a mixed card before the program starts, and on a LAN card also an
address that is not `A.B.C.D/N` with N from 1 to 30.

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

**The fabric's side** is `rtl/machine/quux16_ethernet.sv`, inside revision
16's register-page devices, and `rtl/plumbing/quux_ed_face.sv`, the page. It
holds the rules of muir's device that are the machine's: the configuration
and its refusal at the enable, the index rules and their fault, the indexes
reading 0 while disabled, status `<8>` and word 100 `<8>`. The core holds a
write of 244 or 250 until every write before it is answered, as it holds the
file device's 164. A TX_CONS or RX_CONS write is accepted when the device is
enabled, the epoch is the current one and the index moves forward no further
than its producer, and RX_CONS by at least one. It lands the clock after its
write, as a file device completion does, and a disable in the clock between
drops it. A COUNTS write lands at its edge.

**Line clearing, and 251 after it.** RX_CONS's landing moves a target, and the
host reads RX_CONS back as that target at once. The machine reads 251, which
follows the target one entry at a time. For each entry the fabric's engine
reads the entry's three words from main memory: the buffer, its room and the
length. It reads them over block-disk's transfer channel while no transfer
holds it, after dropping the line that channel holds, so the words are main
memory's. With n the length clamped to the room and to 1,514 bytes, it clears
the cache line of every word from the buffer's first to its ceil(n / 4)th, and
then the entry's own line, one set a clock: at most 49. Only then does 251 move
by one. Lookups never wait for the engine. A disable or a reset stops it, and
the halt's drain waits until it is done.

With nothing else on the transfer channel or the cache's valid maps, 251 moves
at the edge of the clock T = R + 9 + L after the landing's clock, where R is
the port's read latency in clocks at the board's period (the first figure of a
trace's `# port` line) and L the number of the buffer's lines cleared (0 when
n is 0). So 251 reads the new index from clock T + 1 after the landing. At 10 ns, with R = 35, a 42-byte frame in an
aligned buffer gives T = 46, and a 1,514-byte one T = 92. A walk holding the
channel, a processor's fill holding the port's fill, and a fill's install in
the clock of a clear each add their clocks. muir sweeps the whole cache at the
landing instead, so its 251 moves at the landing's edge.

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

`make check`'s `fpgarc.pass` holds the init script (`docs/fpgarc.md`, What
holds all of this). With BusyBox's `tunctl`, `sysctl`, `ip` and `arp` stubbed,
it compares every call the script makes to a list, line for line and in order:
a host-only card's start, a LAN card's start and its stop. A mixed card, and a
LAN card on an image with no DHCP line or with two, must make no call at all.

The model of the page is what the fabric owes, written from muir's device.

`make check`'s `quux16_ethernet_module.quux.pass` holds the fabric's side. It
drives the page over AXI through the program's own `qed_face_fabric.c`, with
revision 16's register-page devices behind it, over scripts of muir's
`EthernetDevice` (`golden/src/quux16_ethernet.rs`). After each step every
register 240 to 257 must read as muir's. Then it checks each rule of the
host's side with the case just outside it. The core's `ethernet` group at
revision 16 (`golden/src/quux15_ethernet.rs`, `quux15_ethernet.quux.r16.pass`)
holds the rest clock for clock to muir's pipeline: the registers, the held
writes, transmits and deliveries with the testbench as the program, and the
interrupt. The module check plays the core's side of the engine too, its
grant, its fill and its clears each delayed at random, and holds each
delivery's clears, line by line, and 251's move after the last. The core's
`lineclear` group at revision 16 (`quux15_lineclear.quux.r16.pass`) is a run
judged by its results: through a ring of one entry, a 42-byte frame and then a
1,514-byte one, the processor reading a word of the buffer's lines and the
entry before each delivery, so the cache holds them, and again after, into a
page held to muir's.
