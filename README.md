# muir-fpga

This is the MIT CADR on an FPGA, at **rtl level**, at the speed the hardware
ran.

[muir](https://github.com/metebalci/muir) simulates the CADR at three
fidelities. `rtl` is the middle one. It has the machine's own two-phase clock,
every datapath signal on it, and everything that is a matter of *when*. That
means bus waits and hangs, arbitration, and timeouts. This repository is that
machine in fabric, at the CADR's own 145 ns microcycle.

muir's netlists are read to **derive** things. They give the port list's
directions, the address decode's boundaries, and every constant that came off
a drawing. But nothing here is a netlist. Whether a gate-level implementation
ever follows is an open question. It is not a promise this repository makes.

This is separate from muir because the toolchain is separate. muir stays the
reference, and everything here is checked against it. `muir.commit` names the
commit of muir the traces were generated against, and `make muir-pin` says
whether the muir beside you is that one.

## Where the machine ends and the board begins

The CADR is one machine, and it is the whole point. Everything else is what it
takes to run that machine on a particular part. The source tree draws that line
explicitly, and it draws it where the checks already drew it.

    rtl/machine/            muir is the reference, tick for tick
    rtl/plumbing/           held to a protocol or a property
    rtl/plumbing/xilinx7/   the vendor's primitives and constraint syntax
    boards/arty-z7-20/      pins, the processing system, the operating system

Every file in `rtl/machine/` has a muir type it is compared against, over a
trace, cycle for cycle. Every file in `rtl/plumbing/` says in its own header
that no muir reference exists for it, because it is held to a bus protocol or
to a property instead. The AXI master is the clearest case. Nothing in muir
corresponds to it, so it is held to the protocol and to read-back and to
nothing else.

The vendor-specific pieces are in the plumbing rather than in the machine. The
scan primitive the debug probe uses and the syntax of the two constraint files
are Xilinx's, and keeping them out of `rtl/machine/` is what keeps the promise
that the machine is plain SystemVerilog.

**Another Zynq board is a small thing.** It needs a top level, a pin file, a
processing-system configuration and a device tree. That is one directory under
`boards/`, and nothing in `rtl/` changes.

**A part with no processing system is not a port but a second set of
plumbing.** An Artix or a Spartan is the same seven-series fabric, so the
machine and even the clock and scan primitives carry over unchanged. What does
not carry over is everything the processing system does today: main memory,
Linux, and therefore the disk pack program, the console's path and the
display's. Each of those needs a fabric answer instead. Nearly all of that work
lands in `rtl/plumbing/`, where it is reusable, and the board directory stays
thin. The disk controller would ask for a block exactly as it does now and
would not care who answered.

**It is one repository and not one per family, deliberately.** The value here
is the CADR held to muir. Two repositories would mean two copies of the machine
drifting apart, with the checks duplicated and rotting in whichever copy nobody
was looking at.

## The board this runs on today

The board is the Digilent **Arty Z7-20**, `XC7Z020-1CLG400C`. It has 53,200
LUTs, 106,400 flip-flops, 630 KB of block RAM, a dual Cortex-A9 at 650 MHz,
512 MB of PS DDR3, gigabit Ethernet and microSD.

**Fabric holds anything with a clock edge the CADR can see. Linux holds
anything with a protocol, a file, or a name in it.** So the boards, the Xbus,
the Trident bus timing and the Chaosnet cable are in fabric. The RFB server,
the packs on microSD, Chaosnet routing and the console are on the processing
system. Main memory is the only seam that runs at machine speed, and it is the
one with no software in it.

Four of the Zynq's nine ports cross the boundary today, and a fifth is planned
for the display's own output.

`S_AXI_HP0` is the memory bridge's, and it is the one at machine speed.

`S_AXI_HP2` is the disk's. A Trident turns 60 times a second with 17 blocks to
the track, which is 1,020 blocks a second of 256 words each. A streaming pack
is therefore 261,120 words a second, just over a megabyte. Bandwidth was never
the point. The point is that on a port the processing system masters, those are
261,120 stalled CPU stores a second, against a 968 us deadline for each block.
So fabric fetches the block out of DDR itself, at the block's address Linux
writes, and no CPU is in the per-word path. The disk gets a port of its own
rather than a share of `HP0`, so that disk traffic adds no arbitration to the
memory path. It is the third port rather than the second because `HP0` and
`HP1` share one port on the DDR controller, and `HP2` and `HP3` share the
other. A disk on `HP1` would have met the machine at that shared port, which is
the thing a separate port was for.

`M_AXI_GP0` carries the disk's registers, the Chaosnet buffers and the block's
address. `M_AXI_GP1` carries the console. The debug cable adapter will need one
of the two, and which one is decided when it is built.

The Zynq-7000's PS-PL ports are **AXI3** and the logic here is AXI4, but no
protocol converter is needed. The `PS7` primitive takes `AWLEN[3:0]`,
`AWSIZE[1:0]`, `AxLOCK[1:0]`, six-bit IDs and a `WID`, so a single-beat AXI4
master reaches it through a handful of wires.

## The processor's boundary

`data/cables.txt` in muir holds the 92 wires on the five flat cables between
the processor and the bus interface, pin for pin off MIT's wire lists. That is
the machine's own boundary, so it is the module's ports.

The cables are named by both ends, because the processor end alone is
ambiguous. `1AJ1` is the CADR board's connector **and** the ICMEM board's. The
five are `1AJ1-J11` (20 wires), `1AJ1-J08` (12, the ICMEM board's), `1BJ1-J12`
(20), `1CJ1-J09` (20) and `3AJ1-J07` (20).

Of the 92, 15 are inputs and 29 are outputs. The other 48 are exactly
`MEM<31:0>` and `SPY<15:0>`, and they are driven from both ends. Fabric has no
bus to fight over, so those are carried as a value and an enable out, with the
resolved wire back in.

Net names are mangled to legal identifiers. A leading `-` becomes `n_`. A `.`,
a space, a `/` and a `>` each become `_`. A leading digit takes an `x`. A
collision is an error. `rtl/machine/cadr_cables.map` holds every identifier
against the name MIT wrote.

## The debug cable

This is the other cable in the machine, and the one that makes two of them. A
CADR debugs a CADR. The debugger's `DBGOUT` connector goes to the debuggee's
`DBGIN`, over the 21 wires of `data/busint-connectors.txt`. Through them the
debugger reaches four registers on the debuggee's Unibus: `766100` cycle,
`766104` status, `766110` modifier and `766114` address. Those are the strobes
the 74S139 at DBGIN 0A15 makes of `DEBUG IN A<1:0>`.

Four wires go out (`-DEBUG OUT REQ`, `DEBUG OUT A<1:0>`, `DEBUG OUT WR`) and
one comes back (`DEBUG IN ACK`). `DBD<15:0>` goes both ways. It is one bus on
each board with both connectors on it, and its direction follows `WR`. So 21
wires are 20 signals out and 17 back. They are carried the way the processor
cables carry their 48 both-ends wires, as a value and an enable out with the
resolved wire back in. The enables are byte-wise, since `DBD` is driven by two
octal Am8304s at DBGOUT 0B21 and 0B22.

What crosses is levels rather than pulses. The wires are held for the whole
request, as the debugger's own Unibus cycle holds them. Two figures constrain
anything that carries them. The data, the address bits and the write flag are
on the cable **100 ns before** the request, because the request is `NAND(SELECT
DEBUG, SELECT DEBUG DLYD)` at DBGOUT 0A11. So a carrier must sample every wire
at one instant and replay it at one instant, or that ordering inverts. And the
debug block's timeout is **11.05 us**, thirteen intervals of the 74LS124 at
REQTIM 0A01 off the REQTIM PROM's second table, rather than the Xbus's 4.25 us.

That budget is microseconds, so a carrier's delay need only be constant rather
than small.

**The debugger is muir, on the processing system.** It holds the cable's levels
as registers. It drives `DBGIN` as machine A's `DBGOUT` page would, or as the
PDP-11 once did, with the phase generator held at a microcycle boundary while
muir computes its side. Machine-time stays exact and only wall-clock stretches.
muir already runs the lashup, so the debugger is software that works before the
fabric it is pointed at does.

A second board is the same cable on two Pmods, one clock and seven data each
way. Outgoing there are 22 things: `DBD<15:0>`, the two byte-wise enables, and
the four control signals. Coming back there are 17, since there are no enables
on the return path. That is four beats and three, tens of nanoseconds against
those 11.05 us. Whoever builds the adapter confirms this arithmetic rather than
inheriting it.

**The console is not this, and the difference is worth keeping.** It masters
the machine's own Unibus to reach the diagnostic registers. No CADR had that
path, where the debugger was another machine's `DBGOUT` page or a PDP-11
playing it. So the console exercises nothing of the machine, and that is
exactly its use. It works when the debug block does not, which is when it is
wanted. muir through the real debug block does test that block. **A check may
reach the machine through the debug cable and never through the console.**
Otherwise it would be holding the fabric to a path the hardware never had.

## Memory in DDR

Memory is shared with the Linux side. It is settled early in
`rtl/plumbing/cadr_ddr_map.sv` and **reserved at the size the machine could one
day want**. That is a quarter of the board's 512 MB, and Linux keeps 384.

| base | reserved | reachable today | |
|---|---|---|---|
| `0x1800_0000` | 64 MB, 16M words | 15 MB, 3,932,160 words | main memory |
| `0x1C00_0000` | 8 MB, 2M words | 128 KB, 32,768 words | display |
| `0x1C80_0000` | 56 MB | --- | spare |

DDR was never the limit. The CADR's physical address is 22 bits, a 14-bit page
frame out of the map with `VMA<7:0>` as the offset, so 3,932,160 words is the
ceiling. The top four of the 64 slots are taken by the display, the disk
controller and the Unibus. The CADR's *virtual* address is 24 bits, which is
what the 64 MB is room for.

The display's 8 MB is room for 1920 x 1080 at 32 bits a pixel. The CADR's own
screen is 768 x 963 at one bit, so that room is for a display that is not the
CADR's. The Linux side serves a 1080p canvas over RFB and composites the
machine's screen into it.

## Building

This needs [Verilator](https://verilator.org), a Rust toolchain, and muir
checked out beside this repository. Nothing here vendors a copy of muir's
netlists or part tables.

    make check

## Layout

    rtl/machine/           the CADR, held to muir tick for tick
    rtl/plumbing/          held to a protocol or a property; no muir reference
    rtl/plumbing/xilinx7/  family primitives and constraints, not the machine
    boards/arty-z7-20/     pins, the processing system, the operating system
    tb/                    Verilator testbenches
    golden/                Rust, depends on muir by path; writes the traces
    mutations/             the mutation list, and the runner that applies it
    docs/                  one document a block, and the board bring-up
    site/                  the architecture drawing, and nothing else
    build/                 generated, not committed
