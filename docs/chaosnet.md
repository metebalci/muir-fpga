<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# The Chaosnet, and the serial line beside it

Both are on the CADR's I/O board, and both are split between fabric and Linux.
This document covers the whole of each, because the two halves were built by
separate slices and neither is a thing on its own.

The fabric half is in `rtl/machine/cadr_io_board.sv`, held to muir's `ioboard`
model over a scripted trace. The Linux half is two Buildroot packages,
`cadr-chaosnet` and `cadr-serial`, ported from muir's `src/chaos/` and
`src/serial.rs`.

## Where the line between them falls

**Fabric holds anything with a clock edge the CADR can see. Linux holds
anything with a protocol, a file, or a name in it.** That is this project's
rule and it decides everything here.

So the fabric has the registers the machine reads and writes: the Chaosnet
interface's five registers from AIM-628 section 7, its two packet buffers of
256 words each, its bit counter and its lost count, and the serial port's four
2651 registers with their mode pointer and status byte. Nothing above that is
in fabric.

Linux has the rest: the cable, the frame, the check word, routing, the turn
timer, the baud-rate generator and the line. What crosses the boundary is a
buffer and a status register, and nothing more.

**Nothing on either side of that boundary answers a service.** A CADR has no
file or time server in it. The section on `ED-FILE` below says where that
server is instead.

## What the machine sees

`0o764140` to `0o764156` is the Chaosnet interface and `0o764160` to
`0o764176` is the serial port. Both are answered in full. The card's own check
prints `NOTHING IS EXEMPT`, and it answers 55 directions where it answered 28
before these two landed.

The Chaosnet's decode is subtle and the subtlety is MIT's. The 74LS138 at
LMUCON 0C18 decodes two address bits **and read against write**, so one
address is a different register depending on direction. Address bit 3 is
decoded only twice: it makes a read of `0o764152` the address START rather
than MY ADDRESS, and it disables the receive buffer's read at `0o764154`,
which is then unanswered. Writes reach the CSR and the transmit buffer at
`0o764150` and `0o764152` exactly as at `0o764140` and `0o764142`.

The serial port is simpler. Address bit 3 is not decoded at all, so
`0o764170` to `0o764176` are aliases of `0o764160` to `0o764166`, and every
address of the group is answered in both directions.

The interrupt vectors are `0o274` for the clock, `0o270` for the Chaosnet,
`0o264` for the serial port and the keyboard and mouse last. MIT's priority is
clock over Chaosnet over serial over keyboard. `0o270` is compared against
muir for the first time now, because the trace plugs a Chaosnet interface in
and uses Loop Back as the far end, which no trace against this model could do
before.

## What Linux sees

Two register faces, each behind one header so that a change of address touches
one file. `chaos_face.h` and `serial_face.h` are those headers.

The Chaosnet face is sixteen words with two windows of 256 words each, one for
each packet buffer. Its identity word is `CHAO`. The serial face is eleven
words. Both are on `M_AXI_GP0`, which is where the drawing has always put the
Chaosnet buffers.

**A read on a general-purpose port that nothing in the fabric answers does not
fault the Arm cores. It freezes them, and no software guard can catch it.**
That was measured on this board. So whatever owns that port must answer every
address in its window, and adding these two faces to a port the disk pack
program already answers end to end needs a decode in front of it.

What each program must do at the face is written in the two headers. The
shapes are worth knowing here: the Chaosnet program takes a frame off the
transmit window a word at a time after the machine starts a transmission, and
streams a received frame in and then reports its length in bits and whether
the check word was good. It does nothing else with the frame. Routing is by
the cable destination alone, which is the hardware's own addressing, and the
program never looks inside a packet except to print a trace line. The serial
program holds the modem-control lines while a client is connected and takes
every character waiting at each look. The fabric's side of the line reads the
character frame and the rate out of the mode registers and **paces the
transmitter at the rate those registers name**, because without that pacing
the transmitter never empties. It also holds up to 1,024 characters the
machine has sent until the program takes them, because a frame at 9,600 baud
is shorter than the interval the program looks at. `docs/io-board.md` has that
account.

## What is not built, and why each

**The mapped Unibus window is built now, and it was on this list.**
`rtl/machine/cadr_busint_regs.sv` translates a foreign master's cycles at
`0o140000` to `0o177777` through the map, so a debug cycle reaches main
memory. `busint_regs.pass` and `unibus.pass` hold it.

**All four of the things this document used to list here are built.** The SYN
and DLE registers and their pointer, the parity and framing flags, both
echoing modes and the Chaosnet's timer interrupt. The usual default was
reversed for them: a register the fabric does not have is a way this is not
the CADR, whether or not today's seam can observe it.
`docs/io-board.md`'s "What slice six built" says what holds each. Two are held
to muir, one to the Signetics sheet, and the fourth turned out to be nothing to
build at all, because MIT's own netlist says this version of the interface has
no interval timer.

**A far end that raises a parity or framing error.** The card has `SR3` and
`SR5` and the seam carries both. Nothing on this board drives either, because
what is behind `cadr-serial` is a TCP socket carrying bytes rather than bits.
One bit pair in the character-in word of `serial_face.h` would make them live.

**Reassembly of a control command split across two packets.** muir does not do
it either. If a band ever sends one longer than 488 bytes, both are wrong
together.

## How CHUDP frames a packet

A CHUDP datagram carries one Chaos packet over UDP, on port 42042 unless a
flag names another. This is what `cbridge` speaks, and `cbridge` is the
reference for it. The CADR's own sources define the packet's words, how data
bytes go into them, and the 9401 CRC-16 the interface puts on its cable. They
do not define how CHUDP lays those words out in a datagram, or which check
word it carries. No CADR ever sent a UDP packet.

| bytes | field |
|---|---|
| 0 | version, 1 |
| 1 | function, 1, a Chaos packet |
| 2 to 3 | two argument bytes, sent as zero |
| 4 to 19 | the packet's eight header words |
| 20 onward | the data, as whole 16-bit words |
| last 6 | the trailer: destination, source, checksum |

**Every 16-bit word goes most significant byte first.** That holds in the
header, in the data and in the trailer.

The data is packed into words as AIM-628 section 3.6 says, with the first byte
of each pair in the word's least significant half. The word is then written
most significant byte first, so each pair of data bytes appears swapped on the
wire. `STATUS` goes out as `TSTASU`. An odd byte count is padded to a whole
word with a zero in the high half, which is the byte that comes first on the
wire. `cbridge` always pads, and a datagram that does not is refused here: a
lone trailing byte sits exactly where the pad byte would be, so reading it as
data is a guess.

The trailer holds the three words the CADR's interface adds on its cable. The
first is the address the packet is sent to on this subnet, which is the next
hop and not necessarily the header's destination. The second is the sender's
own address. The third is the checksum.

**The trailer's third word is the Internet checksum, not the CADR's CRC.** It
is the one's complement of the one's complement sum of every word before it:
the eight header words, the data words, and the trailer's destination and
source. The carry out of sixteen bits is added back in at each step. A frame
is good when all of its words, the checksum included, sum to 0xFFFF. `cbridge`
drops a frame whose words do not sum right, and so does this program. Carrying
one would mean handing the machine a check word this program made for it,
which would say the frame arrived whole when it did not.

**The fabric keeps its own check word, and the conversion is at the UDP edge.**
`cadr_chaos_cable.sv` computes the 9401's CRC-16 on transmit and streams the
trailer's three words into the machine's buffer as they are given on receipt.
So the frame that crosses the register face carries the CADR's check word in
both directions. `chudp_wrap` puts the Internet checksum in its place on the
way out, and `chudp_unwrap` verifies the Internet checksum and makes the CRC
for the frame on the way in. Nothing else about a frame is changed, and no
fabric file is touched by any of this.

**A board and its peers must move to this framing together.** The old framing
wrote the packet's own words least significant byte first and carried the
CADR's CRC in the trailer. The two cannot talk: a datagram in the old framing
is refused here for its data count, which reads as 1,536 bytes when its two
halves are swapped, or for its checksum when the count happens to read the
same either way.

**Both Zynq boards have spoken this framing to a peer that speaks it.** The
datagrams were captured on the peer's own machine and decoded from their
literal bytes: every field is as this section lays it out, every check word
verifies in both directions, and a datagram in the old framing goes
unanswered. `docs/board.md` has the measurement.

## `ED-FILE` is a hole in the band's host table, not a missing server

The board's screen, with Lisp booted, shows this:

    >>ERROR: #<ZWEI::ZWEI-FILE-HOST "ED-FILE"> is not a known host.

**No Chaosnet server can answer it.** The failure is in `SI:PARSE-HOST`,
before a single packet is sent. The band's whole host table is two lines:

    HOST MIT-LISPM-1,	CHAOS 3050,USER,LISPM,LISPM,[CADR-1,CADR1,LM1]
    HOST MIT-OZ,		CHAOS 3060,SERVER,UNIX,VAX,[OZ]

`ED-FILE` is in neither. It is a name ZWEI's site configuration still refers
to and the restorers' trimmed table no longer contains, so making it resolve
is a change on the pack.

**The host the band wants is `MIT-OZ` at 3060, and it is a machine on the
network.** It is not `cadr-chaosnet` and it never should have been. A CADR has
no file or time server inside it, and the Lisp Machine's own word for the
machine that holds those is the **associated machine**, which the boot banner
names. muir carried such a server for a while and removed it at its own
`79c7590`, in these words: "A CADR has no file or time server in it, so muir
has none either." This program was ported from muir before that commit and
carried the same services across. They are gone.

So what `cadr-chaosnet` buys is the cable, and the cable is what the band
needs. Give the host its own Chaosnet address on the network and name it with
`--chaos-udp-peer 3060@<where the host is>`. A host beyond a bridge is reached
with `--chaos-udp-default-peer <where the bridge is>` instead. The band then
resolves `SYS:` to
it, the TIME lookup is answered and the machine has a date instead of stopping
to ask for one, `(hostat)` sees it, and anything loading through the system
host reaches its FILE service. That last is how CC is loaded in muir's own
tests, which is what the debug cable needs. `metebalci/ozd` is a host that
boots a band.

**The three flags that used to configure those services are refused by name.**
`--chaos-file-root`, `--chaos-file-peers` and `--server-name` each print where
the host went and exit, rather than being ignored. A boot that silently
dropped `--file-root` would look exactly like a boot that served it.
`--chaos-address` now takes one address, this machine's, and a comma in it is
refused the same way.

## The board can be that host itself

The section above says the host the band calls is a machine on the network.
That is still what a CADR sees, and nothing in the fabric or in
`cadr-chaosnet` has changed. What has changed is where the machine stands: it
runs on the board's own processing system, beside the programs that serve the
disk packs and the screen. A board with a card and nothing plugged into it is
then a whole site. The machine boots, asks for the time, is answered, resolves
`SYS:` and finds its file host, and none of that needs a network.

The program is `ozd`, which is another project. It is packaged here and never
patched, which is the rule this project holds for muir as well. It is built
from its own source at the commit `ozd.commit` pins, so no binary is carried
in this repository.

**It is on unless the card turns it off.** `--no-ozd` is the flag, in the
spelling this board already uses for a thing that runs until somebody says no.
Every other setting is spelled `--ozd-`, because a word like `--root`,
`--host`, `--name` or `--port` is a word another program could want, and the
card's one file of flags cannot carry a word two programs answer to.
`docs/fpgarc.md` has the whole list.

### What it costs, measured

The program is 811,640 bytes for the 64-bit boards and 789,548 for the 32-bit
ones, stripped, and about 394,000 bytes of the compressed root filesystem. The
root filesystem is unpacked into memory at every boot, so that is what a board
pays whether or not anybody asks it for a file. Nothing else is paid, because
the default serves no tree.

**The tree lives on the card and not in memory.** A card that carries a pack
carries the band's files beside it, and there are two trees because the band
uses them two different ways:

    sys/    the band's sources, named as --ozd-root sys=/mnt/card/sys,ro
    site/   the band's site configuration, named as --ozd-root site=/mnt/card/site

**`sys/` is read-only and `site/` is not, and the difference is the point.**
Sources are a tree nothing reaching the host's socket should write in, so the
`,ro` is there. A site is the few files that say what this site is --- its host
table, its logical pathname translations --- and a site is a thing its owner
changes, so that root is served read-write and carries no `,ro`. The two are
not the same size: the sources are the table below, and a site configuration
is a handful of files and a few tens of kilobytes. One band and the files that
belong to it are one thing, and they go on one card together.

The three places they could have gone were measured, on a real FAT32 image made
by the same `mkfs.vfat -F 32` a card is made with, with the real files copied in
and the free space read back afterwards. The sources are 513 files in 25
directories and 15,857,581 bytes of content.

| where | on the card | in memory, on every board |
|---|---|---|
| the root filesystem | 4,309,541 bytes | 17,027,072 bytes |
| the card, as files | 17,031,168 bytes | nothing |
| a read-only image on the card | 3,932,160 bytes | nothing but what is read |

The first is the root filesystem, which is compressed on the card and unpacked
into memory at every boot: the whole of the tree, on every board, for a
service that is on by default and whose files many boards will never ask for.
The second is the card itself, which is already there, is already mounted, and
costs no memory at all. The third is the card with the tree inside one
compressed read-only image, which is smaller on the card and demand-paged in
use, at the price of a loop mount and a filesystem the kernel would have to
carry.

**The second is what the card writes.** It costs the most card and the least
of everything else, it needs nothing added to the kernel, and the files can be
read and changed with the card in a reader, which is the reason the settings
files are on the card too. The third is what to reach for if a card ever runs
short.

**Nothing is served when no tree is named**, which is what a board with an
empty bay gets. The host still answers the time and the host table, and those
are the two things that were actually stopping a board with no network. A line
naming a tree that is not there stops the host in its own words, so the card
writes that line live exactly when it carries a tree. A release ships `sys/`
and `site/` on the card empty and both lines commented, because a release
carries no band.

### What a band takes on the card

The figures are read off a FAT32 image rather than derived:

| | bytes | |
|---|---|---|
| the cluster `mkfs.vfat` chooses at these sizes | 4,096 | 8 sectors of 512 |
| a T-300 pack | 269,565,952 | the file is 269,562,880 |
| the sources | 17,031,168 | 513 files, 25 directories |

So a pack and its sources together want about 274 MiB of card, and that is what
decides how big a card to buy: everything a board itself needs is 12.5 MB on a
Zynq board and 49.4 MB on the DE25-Nano. **How big the card is is the user's
own decision**, because the user formats it; nothing in this project sizes a
partition any more. `docs/boot.md` has the sizes and how to format.


### What address it answers at, and where it listens

**The address is not free to choose.** A band holds a host table and calls its
file and time host at the address that table gives. A host answering anywhere
else is a host the band never calls, and a service that runs and is never
reached looks exactly like one that works. So the default is the address the
band this project ships beside names for its own associated machine, and a
board running another band says so on the card: System 100 calls 3060 and
System 304 calls 4403.

That means every board runs a copy at one address. **They do not collide,
because none of them claims that address on a network.** The host listens on
the loopback and nowhere else. The only thing that can reach it is the board
it runs on, so the address is a name inside one board, as `127.0.0.1` is.

The loopback is a decision and not a default. This host authenticates nobody:
anything that reaches its socket may read every root it serves and may write
every root not marked read-only. A card can name the port it listens on and
cannot name the address, so putting it on a network is not something that can
be done by uncommenting a line with the card in a reader.

The port is 42142. CHUDP's own port is 42042 and the CADR in the fabric takes
it, and the CADR inside muir takes 42043, so a third station on one board
needs a third number.

It runs as a user of its own, because it refuses to run as root. That refusal
is right: nothing it does needs a privilege, and as root a path check it got
wrong would reach the whole filesystem rather than one directory.

### How the machine reaches it, and the one collision

The machine reaches it over the cable, exactly as it reaches a host on a
network. The frames go out of `cadr-chaosnet`'s socket and come back to it,
and nothing above the cable knows the far end is on the same board.

So the cable has to be plugged in. A released card now carries
`--chaos-udp 127.0.0.1:42042` live, which plugs it into the board and into no
network. That line used to be commented out, on the argument that a release
with the cable live would put a station on a network the user has not got,
listening on a port nobody named, with no peer it could reach. Two of those
three are still true of a cable on every interface and none of them is true of
a cable on the loopback. A user who wants a station on their own network
changes `127.0.0.1` to `0.0.0.0`.

The machine is then told where the host is. The host's init script writes its
own endpoint down when it has really started, and `S87cadr-chaosnet` reads
that one line and passes `--chaos-udp-peer` for it. A card's flag names one
program, so neither script reads the other's flags; what passes between them
is a fact about the boot.

**And one Chaos address may not be placed twice.** `cadr-chaosnet` refuses a
second endpoint for an address a peer line already placed, and the refusal
stops the program, which would leave the board with no cable at all. A board
whose network really does have a file host is therefore the case the off
switch is for. A card that names a peer for the host's address keeps its own
host and is told so on the console, and the card script writes `--no-ozd` live
on any card that names a peer, so the two states cannot be reached by
accident.

### The wait for the network is only for a name

`cadr-chaosnet` resolves each peer's name once, when it starts, and exits if a
name has no address, so its init script waits for the network first. That wait
asks for an address and a default route before it looks at a single name, and
a card whose peers are all written as addresses has nothing for a resolver to
answer about. Such a card used to spend the whole bound at every boot waiting
for something it was not going to use, which the section on the wait above
already claimed it did not.

A board that is its own file host is exactly such a card, at every boot, so
the wait is now entered only when a peer is named by name. A board with
nothing plugged in says that there is no name to wait for and starts at once.

## How the board tells the program its address

The card carries one file of flags for each of the two CADRs this board runs,
both at its root. `fpgarc` configures the machine in the fabric and `muirrc`
configures the machine inside muir, which is the debugger. Both are in muir's
own rc format, so the two stations are configured the same way with the same
flag names. `docs/fpgarc.md` is that file, its format and every program's
flags; this section is the Chaosnet's own.

`S87cadr-chaosnet` hands `fpgarc` to the shared reader and names the flags
below, and it is given those lines and no others. The file serves several
programs and each of them refuses a flag it does not know, so none of them is
given it whole.

**The address switches are always set and the cable is not.** A Chaosnet
interface has an address whether or not anything is plugged into it, so the
script passes System 100's own address wherever `fpgarc` says nothing about
one. The cable is `--chaos-udp`, and a card that is there and does not name it
is a card that was asked and said no: no cable is plugged in, the program says
that this cable reaches nothing off the board, and the init script does not
wait for a network it has nothing to reach. A released card ships in exactly
that state, with the line commented out under the sentence that explains it.

A board with no `fpgarc` at all is the other case. Nobody has been asked, so it
runs both defaults, which are System 100's own address and CHUDP's own port.

The three flags this program refuses by name are not in that list:
`--chaos-file-root`, `--chaos-file-peers` and `--server-name`. A card still
carrying one of them is named at boot by the report on lines no program takes,
and the Chaosnet starts. In the list instead, the line would reach the program
and stop it.

`--time` was a fourth until the word was given another meaning. It named a
time host that lived inside this program and does not any more. It now names
the time of day on the card, which the disk pack program's init script reads
to set a clock no board here keeps, and `docs/fpgarc.md` has that section. One
name for one thing is the rule, so this program no longer knows the word at
all: it is neither claimed by the Chaosnet's list nor refused by name. A card's
clock line reaches the clock and nothing else.

    --chaos-address 3050         this machine's Chaosnet address, in octal.
                                 It is the DIP switches on MIT's card, so it
                                 is not configuration: it is what the hardware
                                 is. System 100 is 3050 and System 304 is
                                 4401.
    --chaos-udp 0.0.0.0:42042    the cable, plugged in. Without this line the
                                 program sends nothing, whatever the address
                                 switches read, and no cable is plugged in on
                                 its behalf. 42042 is the protocol's own port
                                 and this machine takes it.
    --chaos-udp-peer 3060@<host>:<port>
                                 another station on this machine's cable, once
                                 a line. The band's file and time host goes
                                 here. It needs the cable.
    --chaos-udp-default-peer <host>:<port>
                                 where a frame goes whose destination no peer
                                 line names. This is a bridge, and it is what
                                 carries the machine's traffic on to the wider
                                 Chaosnet. It needs the cable.

No peers is legal. A board on a network with no other station is a machine
whose band will say its file host is not answering, which is true and is
better than a guess.

**The switches are one flag and the cable is another.** On MIT's card the
sixteen address switches are set whether or not anything is plugged in, and a
cable can be unplugged. So `--chaos-address` sets the switches and nothing
else, and `--chaos-udp` is the cable. A file with peer lines and no
`--chaos-udp` line is refused rather than quietly given a cable of its own,
because a run that only said who its file host was would otherwise find itself
on a network it had not asked for, listening on a port nobody had named. muir
separated the two at `0851fa7` and the refusal here is in muir's own words:
`--chaos-udp-peer is part of the CHUDP link: it needs --chaos-udp, which is
the cable`.

**The three files this replaced were one value each, and a shell read each of
them.** They were `chaosnet.addr.txt`, `chaosnet.over.udp.port.txt` and
`chaosnet.over.udp.peers.txt`. One of those readers stripped a carriage return
and the other did not, so every peer reached the program with a `\r` on the
end of its port and was refused by name. That was measured on the board. A
file of flags has no values for a shell to get wrong, and it is the same text
the program would have been given on a command line.

## The program waits for the network, and stops waiting

`cadr-chaosnet` resolves each peer's name once, when it starts, and exits if a
name has no address. That follows muir. A name with no address is a refusal at
the start rather than a peer that is never reached.

The init script therefore has to start the program on a network that works.
On this image the network is not up at the moment init would reach it.
`/etc/network/interfaces` says `iface eth0 inet dhcp`, so `S40network` runs
`ifup -a`, which starts BusyBox udhcpc. BusyBox is built here with `-b` among its udhcpc options, so the
client forks into the background when its first request is not answered at
once. `ifup -a` then prints `OK` with the interface still bare. The link
itself comes up later still: the console shows the Ethernet at 1Gbps several
seconds after every init script has run. The program was started before any
of that, printed that a peer's name had no address this host can reach, and
exited, while the init script printed `OK` and left a pid file. That was
measured on the board on two boots.

An S-number cannot fix this. Ordering orders scripts, and what is late here is
an event rather than a script. A higher number would lose the same race on a
slower switch.

So `S87cadr-chaosnet` waits for the network before it starts the program. It
waits for three things, and each of them is something udhcpc's own script does
when the lease arrives. There has to be an address on an interface other than
the loopback. There has to be a default route. And the resolver has to answer
for every name the flags carry, which the script reads out of those flags
rather than from a list of its own. A peer written as an address is skipped,
because there is nothing for a resolver to answer about it.

The wait is bounded at thirty seconds, and on expiry the program is started
anyway. That matters in two cases. A card whose peers are all addresses, or
which names no peer at all, is never held up by a network that may never
arrive. And when a name really cannot be resolved, the message that reaches
the console is the program's own, with the name in it, rather than a script
that quietly did nothing.

**A board with no cable does not wait at all.** The wait is for the lease, and
what it is really for is the resolver, so a board whose `fpgarc` says nothing
about `--chaos-udp` has nothing to bind, nothing to resolve and nothing to
send. It would otherwise spend the whole bound at every boot waiting for a
network it is not going to use, which is what a released card out of the box
would do. The script says which state the board is in instead.

    cadr-chaosnet: no --chaos-udp in /mnt/card/fpgarc, so the cable is not plugged in:
    cadr-chaosnet: the address switches are set and nothing is sent or received.
    cadr-chaosnet: uncomment --chaos-udp in that file, and the peer lines under it,
    cadr-chaosnet: to put this machine on a network.

The script says what it is waiting for and how long it waited. A boot on a
working network prints one line. A boot that waits prints the reason and then
the time.

    cadr-chaosnet: the network is ready
    cadr-chaosnet: waiting up to 30s for the network: no address yet on anything but the loopback
    cadr-chaosnet: the network is ready after 4s
    cadr-chaosnet: the network is still not ready after 30s: no default route yet; starting anyway, and what it says next is its own

`chaos_test_boot.sh` holds all of this. It runs the real init script with
stubs for `ip`, `nslookup` and `start-stop-daemon`, and it rewrites two
constants in a copy of the script, asserting that each rewrite matched exactly
once. Renaming either constant therefore fails the check by name instead of
leaving it testing nothing.

## The default peer is the way out, and nothing is learned

A peer line says that one Chaosnet address lives at one endpoint. A frame for
any other address therefore has nowhere to go, and naming a bridge as a peer
does not help: that only says the bridge's own address lives there.
`--chaos-udp-default-peer` is where such a frame goes instead. It is the route
of last resort and it is the whole of this program's routing, which reads no
routing packet and keeps no routing table.

It takes an endpoint and no Chaosnet address, and that is what tells it from a
peer. The CHUDP frame carries the real destination in its hardware trailer,
and the bridge at the far end routes on that. With no default peer a frame no
peer line names is dropped, which is what this program did with every one of
them before the flag existed.

**A broadcast is not sent to the default peer.** The named peers are stations
on this machine's own cable, so a broadcast is theirs. The default peer is the
way out to a wider network, and handing it a broadcast would put this cable's
broadcast on a network it was never meant to reach.

**Nothing is learned from a packet.** An endpoint typed in a file is a
statement about where a host is. A table filled in from what arrives is state
nobody wrote down, and it puts the naming in the hands of whoever can reach
the port. muir removed its own `--chaos-udp-dynamic` for those two reasons at
`d6eac6d`, and this program has none either.

So a datagram is judged by what is in the frame and never by the socket it
came off. A host no flag named is heard exactly as a named peer is, which is
what lets a bridge relay for hosts this machine was never told about. What
such a host cannot get is an answer, unless a peer line or the default peer
says where to send one.

The one thing a datagram may not claim is a Chaosnet address this cable
already carries. A frame saying it came from the machine itself is one the
interface would take for its own, so it is dropped. muir refuses it in the
same place.

## Every datagram that arrives is counted

The program says how it is getting on once a minute, when anything has moved.
The line names what the machine sent and received, what went out over the
network, and what the link did with everything that arrived:

    N from the machine, N to it, N in and N out over UDP; N datagrams
    arrived, N refused for their shape, N with a bad checksum, N not for this
    cable; N with nowhere to go, N malformed, N refused because the machine
    had not emptied its buffer

**The middle group adds up, taking `N in` from the group before it.** What
arrived equals what came in plus the three ways a datagram can fail to come
in. That is the point of counting them, and the check asserts the identity
over a stimulus that drives every road once.

The three refusals are the link's own, and they are three because they say
three different things.

**Refused for their shape** is `chudp_unwrap` turning a datagram away for one
of six rules: it is longer than any Chaos packet, it is too short to be one,
it carries a version this does not speak, it carries a function that is not
"here is a Chaos packet", its data count is absurd, or its length does not
answer that count. Six rules share one count because what a person does with
the number is notice that it is not zero and turn the trace on, and the trace
names the rule and the sender.

**With a bad checksum** is a datagram whose words do not sum right. It is kept
apart because it says something the shape refusals do not: the far end is
speaking CHUDP and the network between here and it is damaging packets.

**Not for this cable** is a whole frame that belongs to somebody else. Either
it claims to come from an address this cable already carries, which is a frame
the interface would take for its own, or it is addressed on the cable to a
station a peer line names. Nothing is wrong with either datagram, and a leaf
does not forward them.

**Only the bad checksum used to be counted.** The other seven refusals were
printed under `--chaos-trace` and nowhere else, so a line reading "0 in, 0
with a bad checksum" said the same thing whether nothing had arrived or
everything had arrived and been thrown away. Those are the two states somebody
reads the line to tell apart, and telling them apart at the board took hours.

**A datagram that was refused now counts as something having happened.** The
line is printed when anything has moved, and that used to mean a frame
delivered or sent. A link hearing datagrams and throwing every one of them
away therefore printed nothing at all, which is what a link hearing nothing
prints.

muir counts none of this and has no words to follow here. Its CHUDP link
traces a refusal when `--chaos-trace` is on and keeps no tally, because it has
a prompt somebody is sitting at rather than a daemon writing one line a minute
to a log. So the four names are this program's own.

## The machine holds one packet, and a frame it refuses goes again

The Chaosnet interface has one incoming packet buffer. A frame given to it
while the machine has not read the last packet out is refused, and the refusal
is counted at both ends of the seam. The machine's end is the Lost Count, the
four-bit field of AIM-628 section 7 that `CHAOS:PKTS-LOST` reads. The
program's end is the `LOST` register of `chaos_face.h`. One condition in the
fabric raises both, so they move on the same events.

The two are not the same number. The Lost Count is four bits of a 74LS161 and
wraps at sixteen. Clear Receiver and Reset each put it back to zero, because
it counts what has been lost since the machine last emptied its buffer. `LOST`
is thirty-two bits and survives a reset, because `chaos_face_give` reads any
change in it as a refusal and a count that went backwards would make the
program read a stored frame as a refused one.

The program offers the machine a frame only when the frame is a broadcast or
is addressed to this machine. A third party's frame is never offered, which
agrees with muir on what is counted. It also means Spy is not implemented: a
machine that set the Spy bit would expect every frame on the cable, and this
program does not offer them.

So a host that sends two frames back to back offers the second one while the
machine is still copying the first out of the buffer. A form longer than 488
bytes is two packets, which makes this the common case rather than a rare one.

### What the cable did, which is not losing the frame

AIM-628 section 2.5 says a receiver whose buffer is full does not silently
drop a frame addressed to it. It sends an abort signal, which stops the
transmitter. The sending interface reads Transmit Abort, and section 2.6 says
what the sender does about it: "we recover from it (in software) by
retransmitting the packet again a couple of times, hoping that the receiver
will soon clear its packet buffer."

The CADR's own driver does exactly that. `CHAOS-NUMBER-TRANSMIT-RETRIES` is 3
in `ucadr/uc-chaos.lisp`, with MIT's comment "Send once and retry twice if
aborted". An aborted packet stays at the head of the transmit list until it is
done with, so packets queued behind it stay behind it. Past the third offer
the driver gives up and the packet is lost.

### What this program does

The program is the cable, and the station that sent a frame is at the far end
of a UDP socket and has gone on. So the retry is here, in `chaos_inject.c`,
standing in for the sending station's interface as the rest of the program
stands in for the cable.

A frame the buffer refuses waits for a turn. It goes again when the machine
has emptied its buffer, which the fabric latches as `CHAOS_IRQ_RX_FREE` and
`chaos_face_rx_freed` reads and clears. The bit is cleared immediately before
every offer, so a drain from before a refusal is never read as the turn to go
again after it.

Three offers in all, which is the CADR's own bound. A frame that has waited
twenty milliseconds without the machine emptying its buffer goes again anyway,
which is what makes the bound reachable on a machine that has stopped
listening. Past the third offer the frame is given up and counted.

Frames that arrive while one is waiting queue behind it, in order, up to
sixty-four of them. Sixty-four is one turn's drain off the socket, so a burst
that arrives together is never dropped here for want of room. A frame that
arrives with the queue full is dropped and counted, as the cable would have
lost it.

Frames for anywhere else are not affected. The program routes by the cable
destination alone, so a frame for another station goes straight out over UDP
and never reaches this queue.

### The counts, and the sum that closes

The traffic line carries five counts for the machine's side:

- **offers refused because the machine had not emptied its buffer.** These are
  offers and not frames, which is what makes them comparable with the
  interface's own Lost Count: one frame offered three times moves both by
  three.
- **frames given up after three.**
- **broadcasts lost to a full buffer.** These are their own count and not part
  of the frames given up, which mean a machine that has stopped listening. A
  count that can mean two things is one nobody reads. The subsection below says
  why a broadcast is never retried.
- **frames with no room to wait.**
- **frames waiting.**

Every frame the program took for the machine is stored, given up, lost as a
broadcast, dropped for want of room, or still waiting. The check asserts that
identity after every case, so a road out that counts nothing breaks the sum and
the check says so. It is the same rule as the datagram counts above and for the
same reason.

### A broadcast is counted and not retried

The frames a busy receiver counts and the frames it aborts are different sets.
AIM-628 section 2.5, having described the abort, adds this. "Note that a
receiver whose packet buffer is full will only generate an abort signal if the
packet was specifically addressed to it."

So a broadcast into a full buffer is counted in Lost Count and no abort goes
out. No sending interface reads Transmit Abort for it, and no driver anywhere
sends it again.

| the frame | counted in Lost Count | sender aborted |
|---|---|---|
| addressed to this interface | yes | yes |
| a broadcast, destination zero | yes | no |
| anything taken under Spy | yes | no |
| another station's frame | no | no |

MIT's card wires the two conditions apart, and the net names invite the
opposite reading. The broad set is `ITS.ME`, which the 74S08 at LMMYNM 0C02
makes from `DEST MATCH` and `GENCLK`. `DEST MATCH` is an output of the 74S287
at 0D01. The PROM listing asserts it at the end of the destination word in
four cases, commented `MATCH`, `DEST ZERO`, `ZERO=US`, and `NO MATCH` with the
spy bit `MATCH.ANY.DEST` up. The narrow net is `MATCH SO FAR`, which is what
the listing's own header calls that signal line during the destination word.
It is one wire with three names, driven by the sixth output of the 74S174 at
0E01.

The count is clocked by the broad set and the abort is gated by the narrow
one. `ITS.ME` reaches the clock of the 74LS161 at 0F04 through the inverter at
0D03. That counter's count enable is `-RACT` and its clear is `-11.SAYS.GO`,
and its four outputs are the Lost Count that the readback buffer at LMDATP
0D17 puts in the register. The 74S10 at LMMYNM 0D02 takes `MATCH SO FAR`,
`ITS.ME` and `-RACT` together, and its output has exactly two pins in the wire
list. They are its own and the `-SET1` preset of the 74S112 at LMMODU 0A09.
That output is named `-LOST.ONE`, which is the trap here. The net that sounds
like the count is the one that aborts.

All of this is read from `mit/cadrio/iob.wlr` and `mit/chaos/lmmynm.promt`. It
corrects the mechanism and not the behavior. The table above stands, and so
does the fabric, which counts on the broad set and aborts on the narrow one.

The retry in this program stands in for a driver answering an abort. A
broadcast produces no abort, so retrying one would invent a retransmission the
hardware never made, and it would delay the frames behind it while it did. A
broadcast is therefore offered once. If the buffer refuses it, it is counted
and dropped there and then. It never joins the queue, so nothing waits behind
it, and it never waits behind anything else.

The counting does not follow this split, and that is the easiest thing here to
get wrong. The fabric counts a refused commit in `LOST` whatever the frame was
addressed to, and the card's four-bit Lost Count counts a broadcast exactly as
it counts a frame addressed by name. It is the abort, and therefore the retry,
that is by name alone.

The rule is `chaos_inject.c`'s. It reads the cable destination out of the
frame's own words, which is the word the card's destination comparator reads as
the frame goes by. The routing hands a broadcast down exactly as it hands down
a frame addressed by name, because a broadcast does still have to be offered.
What differs is only what happens when the buffer refuses it.

A broadcast touches no state of the queue's. It does not take the head. It
spends none of a waiting frame's three offers. It does not restart a waiting
frame's deadline. It does not read the latched bit that makes a waiting frame's
turn an edge. One consequence is worth stating rather than discovering. A
broadcast that takes a buffer the machine has just emptied can cost a frame
waiting behind it one of its three offers, refused against a buffer the
broadcast filled. That is what the cable charged the sender too, which retried
blind into a busy receiver and was aborted again.

### What it measures, on the build host

The package's check runs a burst against a model of the fabric with a machine
that empties its buffer after a service time. The first table is the program
as it was, the second is the program as it is:

| a burst of | reached the machine before | after |
|---|---|---|
| 2 frames | 1 | 2 |
| 3 frames | 1 | 3 |
| 64 frames | 1 | 64 |

The refusals are unchanged: a burst of 64 costs 63 refusals either way, one
for every frame after the first. That is what the cable charged too, since
each frame was aborted once and sent again.

Spacing the frames 20 milliseconds apart delivers all of them without any
retry at all, which is the contrast the first measurement of this drew on
another machine. What the retry buys is that the sender no longer has to know
to do it.

### The machine's service time, derived

`CHAOS-INTR` in microcode 323 is at control store `0o25762`. Its prologue runs
to `0o26006`, which is 21 microinstructions, and it calls `CHAOS-LIST-GET` for
a free packet. The copy loop at `0o26007` reads two 16-bit words out of the
interface and writes one word of main memory, and one pass of it is 19
microinstructions. The tail from `0o26032` to the Clear Receiver write at
`0o26040` is 8 more.

So a frame of `n` 16-bit words costs about 38 + 19 x ceil(n / 2) microcycles.
A microcycle on this board is 150 nanoseconds, fifteen ticks of MIT's 10 ns
grid. The longest packet is 255 words and takes about 371 microseconds; a
six-byte packet is 14 words and takes about 26.

One term of that loop is a delay the microcode takes when the disk is busy or
when a PDP-11 arbitrates the Unibus. This board's LOCAL ENABLE bit reads set,
which the microcode takes into `A-INTR-LOCAL-UNIBUS-MODE`, so the delay count
is zero and a pass is 19 microinstructions rather than 51.

That figure is the copy loop alone. The whole time from a frame arriving to
the Clear Receiver write also includes the machine reaching its interrupt
handler, which has not been measured for this interrupt. The serial line's own
measurement on this board brackets the same latency at a couple of
milliseconds at worst.

**No answer above rests on the figure being exact.** The check runs at both
service times and gets the same table, because what decides a loss is an order
of events rather than a duration. A burst handed down in one turn cannot
outlast any service time at all, and a burst that waits for the buffer cannot
lose to one.

## The trace switches while the program runs

`--chaos-trace` says every frame as it goes by and every datagram refused,
with the reason and the endpoint it came from. It used to be a flag read once
at the start. Watching a link that was quietly refusing datagrams therefore
meant stopping the program, adding the flag and starting it again, and on this
board that means the machine's world has to be booted off the disk afterwards.

So the trace is switched by signal as well. `SIGUSR1` turns it on and
`SIGUSR2` turns it off, which is what `cadr-terminal` and `cadr-usb-input`
already do for their key traces.

    cadr-console trace-chaos on
    cadr-console trace-chaos off

That word reads `/var/run/cadr-chaosnet.pid` and sends one of the two signals.
It touches no register, so it works on a board whose fabric has no console in
it. `docs/console.md` has it beside `trace-keys`.

The handler does the one thing a handler may, which is set a flag. The program
acts on it once a pass of its own loop and says one line when the setting
changes, so asking twice is not two lines. A run started with `--chaos-trace`
is not turned off by the first pass of its own loop, because "nothing was
asked" and "turn it off" are different answers. The flag stays, since a run
that wants the trace from its first line is a real case and is muir's own
spelling of it.

The card's `fpgarc` carries `--chaos-trace` commented out, which is how a
board is told to trace from its first line. There is no line for the switch,
because a signal is not a setting.

## What the checks hold to

`iob` compares the card against muir's model over a scripted trace at the
Unibus: 41,290,024 ticks, 1,589 bus cycles, 55 directions answered and 524,233
silent over all 524,288 directions of an eighteen-bit address, read and
written, a real bus cycle each. 68 mutation records name the check.

It has a second configuration now. The 2651's parity and framing flags cannot
be held to muir at all, because muir's behavioral chip raises neither, so that
configuration drives the two seam inputs itself and holds the Signetics sheet.

`unibus` holds the composed claim, that the machine's own bus cycle reaches
the card and that the three slaves' address sets are disjoint over the whole
address space in both directions, read out of muir's two traces rather than
transcribed.

`chaosnet` and `serial` hold the two programs on the build host with no board:
955 checks and 49 mutation records for the first, 165 and 28 for the second.
Thirty-four of those checks and seven of those records are the counters and
the trace switch above: every road out of the link driven once, the four
counts added up, and the two signals told apart. Three hundred and seventy-one
more checks and eight more records are the burst above: two, three and
sixty-four frames back to back against a machine that empties its buffer at
its own pace, how many reached it and in what order, the bound counted against
a machine that never empties it at all, and the queue's own bound. Thirty-six
more checks and four more records are the rule that a broadcast is not retried.

The figures were 548 and 37 before the burst checks, and 772 and 61 while the
program carried services. The checks and records that went at that point are
the ones written for the connection protocol and for STATUS, TIME, UPTIME and
FILE. A check for code that should not exist is not a check, so they went with
the code.

What is left is the whole of what the program does: the packet's word layout
and its check word, the register face's handshake with the fabric, and CHUDP's
frame against a datagram's literal bytes. The check touches no filesystem any
more.

**The check word is held to silicon rather than to itself.** muir pins
`0o135771` as the word the netlist board produced for twelve given words, so a
wrong polynomial or bit order disagrees with a measurement off hardware and
not with a round trip that agrees with itself.

**And the CHUDP framing is held to `cbridge` rather than to itself, for the
same reason.** Two datagrams are pinned as literal bytes. The first is a
32-byte RFC for `STATUS`, built here from its fields, whose Internet checksum
is 0xEA6D. The second is a 94-byte answer that `cbridge` itself sent, which is
read here with a good checksum and written back byte for byte. A check that
built a datagram with the code it was checking would agree with any byte order
and any check word. There is a negative case beside them: a datagram in the
old framing must be refused, so that the two cannot both be readable.

## One measurement worth not re-deriving

The serial port answers off the 10 ns grid, on every cycle of its group. Two
constants put muir's answer at 953 nanoseconds plus a multiple of 500,000, and
the fabric counts the same edges at 960, which is the first grid point at or
after it.

**That is exact rather than close, and the reason is that nothing can happen
in between.** The next multiple of ten at or after 203 is 210, so no grid
point lies strictly between the two, and "strictly after the strobe" therefore
selects the same edge whether it is measured on the grid or on the netlist.
The trace carries the seven-nanosecond slip on all 87 cycles rather than
hiding it.
