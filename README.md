# muir-fpga

The MIT CADR on an FPGA, at **rtl level**, at the speed the hardware ran.

[muir](https://github.com/metebalci/muir) simulates the CADR at three
fidelities. `rtl` is the middle one: the machine's own two-phase clock, every
datapath signal on it, and everything that is a matter of *when* --- bus waits
and hangs, arbitration, timeouts. This is that machine in fabric, at the CADR's
own 145 ns microcycle.

muir's netlists are read to **derive** things --- the port list's directions,
the address decode's boundaries, every constant that came off a drawing --- but
nothing here is a netlist. Whether a gate-level implementation ever follows is
an open question and not a promise this repository makes.

Separate from muir because the toolchain is. muir stays the reference, and
everything here is checked against it.

## Target

Digilent **Arty Z7-20**, `XC7Z020-1CLG400C`: 53,200 LUTs, 106,400 flip-flops,
630 KB of block RAM, dual Cortex-A9 at 650 MHz, 512 MB of PS DDR3, gigabit
Ethernet, microSD.

**Fabric holds anything with a clock edge the CADR can see; Linux holds
anything with a protocol, a file, or a name in it.** So: the boards, the Xbus,
the Trident bus timing and the Chaosnet cable in fabric; RFB, the pack on
microSD, Chaosnet routing and the console on the PS. Main memory is the only
seam that runs at machine speed, and it is the one with no software in it.

Four of the Zynq's nine ports cross the boundary. `S_AXI_HP0` is the memory
bridge's, and it is the one at machine speed. `S_AXI_HP1` is the disk's. A
Trident turns 60 times a second with 17 blocks to the track --- 1,020 blocks a
second of 256 words each --- so a streaming pack is 261,120 words a second,
just over a megabyte. Bandwidth was never the point. The point is that on a
port the PS masters those are 261,120 stalled CPU stores a second, against a
968 us deadline for each block. So fabric fetches the block out of DDR itself,
off the block's address written by Linux, and no CPU is in the per-word path.
Its own port rather than a share of `HP0`, so that disk traffic adds no
arbitration to the memory path. `M_AXI_GP0` and AXI4-Lite carry what is left:
the disk's registers, the Chaosnet buffers, the console. `M_AXI_GP1` carries
the debug cable, which has a section of its own below. The Zynq-7000 PS-PL
ports are **AXI3**, not AXI4; the logic here is AXI4 and Vivado's converter
bridges the two.

## The processor's boundary

`data/cables.txt` in muir: the 92 wires on the five flat cables between the
processor and the bus interface, pin for pin off MIT's wire lists. That is the
machine's own boundary, so it is the module's ports.

The cables are named by both ends, because the processor end alone is
ambiguous --- `1AJ1` is the CADR board's connector **and** the ICMEM board's:
`1AJ1-J11` (20 wires), `1AJ1-J08` (12, the ICMEM board's), `1BJ1-J12` (20),
`1CJ1-J09` (20), `3AJ1-J07` (20).

Of the 92, 15 are inputs, 29 outputs, and 48 --- exactly `MEM<31:0>` and
`SPY<15:0>` --- are driven from both ends. Fabric has no bus to fight over, so
those are carried as a value and an enable out with the resolved wire back in.

Net names are mangled to legal identifiers: a leading `-` becomes `n_`; `.`,
space, `/` and `>` become `_`; a leading digit takes an `x`; a collision is an
error. `rtl/cadr_cables.map` holds every identifier against the name MIT wrote.

## The debug cable

The other cable in the machine, and the one that makes two of them. A CADR
debugs a CADR: the debugger's `DBGOUT` connector to the debuggee's `DBGIN`, the
21 wires of `data/busint-connectors.txt`. Through them the debugger reaches
four registers on the debuggee's Unibus --- `766100` cycle, `766104` status,
`766110` modifier, `766114` address --- which are the strobes the 74S139 at
DBGIN 0A15 makes of `DEBUG IN A<1:0>`.

Four wires go out (`-DEBUG OUT REQ`, `DEBUG OUT A<1:0>`, `DEBUG OUT WR`), one
comes back (`DEBUG IN ACK`), and `DBD<15:0>` goes both ways: one bus on each
board with both connectors on it, its direction following `WR`. So 21 wires are
20 signals out and 17 back, and they are carried the way the processor cables
carry their 48 both-ends wires --- value and enable out, resolved wire back in.
The enables are byte-wise, since `DBD` is driven by two octal Am8304s at DBGOUT
0B21 and 0B22.

What crosses is levels rather than pulses: the wires are held for the whole
request, as the debugger's own Unibus cycle holds them. Two figures constrain
anything that carries them. The data, the address bits and the write flag are
on the cable **100 ns before** the request, because the request is `NAND(SELECT
DEBUG, SELECT DEBUG DLYD)` at DBGOUT 0A11 --- so a carrier must sample every
wire at one instant and replay it at one instant, or that ordering inverts. And
the debug block's timeout is **11.05 us**, thirteen intervals of the 74LS124 at
REQTIM 0A01 off the REQTIM PROM's second table, not the Xbus's 4.25 us.

That budget is microseconds, so a carrier's delay need only be constant rather
than small.

**The debugger is muir, on the PS, over `M_AXI_GP1`.** It holds the cable's
levels as registers and drives `DBGIN` as machine A's `DBGOUT` page would ---
or as the PDP-11 once did --- with the phase generator held at a microcycle
boundary while muir computes its side. Machine-time stays exact and only
wall-clock stretches. muir already runs the lashup, so the debugger is software
that works before the fabric it is pointed at does.

A second board is the same cable on two Pmods, one clock and seven data each
way: 22 bits out and 19 back, four beats and three, tens of nanoseconds against
those 11.05 us.

**The console is not this, and the difference is worth keeping.** It masters
the machine's own Unibus over `M_AXI_GP0` to reach SPY --- a path no CADR had,
where the debugger was another machine's `DBGOUT` page or a PDP-11 playing it.
So the console exercises nothing of the machine, and that is exactly its use:
it works when the debug block does not, which is when it is wanted. muir over
`M_AXI_GP1` goes through the real debug block and so tests it. **A check may
reach the machine through the debug cable and never through the console**, or
it would be holding the fabric to a path the hardware never had.

## Memory in DDR

Shared with the Linux side, so it is settled early in `rtl/cadr_ddr_map.sv` and
**reserved at the size the machine could one day want**. A quarter of the
board's 512 MB; Linux keeps 384.

| base | reserved | reachable today | |
|---|---|---|---|
| `0x1800_0000` | 64 MB, 16M words | 15 MB, 3,932,160 words | main memory |
| `0x1C00_0000` | 8 MB, 2M words | 128 KB, 32,768 words | display |
| `0x1C80_0000` | 56 MB | --- | spare |

DDR was never the limit. The CADR's physical address is 22 bits --- a 14-bit
page frame out of the map, `VMA<7:0>` the offset --- so 3,932,160 words is the
ceiling, with the top four of the 64 slots taken by the display, the disk
controller and the Unibus. Its *virtual* address is 24 bits, which is what the
64 MB is room for.

The display's 8 MB is room for 1920 x 1080 at 32 bits a pixel. The CADR's own
screen is 768 x 963 at one bit, so that room is for a display that is not the
CADR's: the Linux side serves a 1080p canvas over RFB and composites the
machine's screen into it.

## Building

Needs [Verilator](https://verilator.org), a Rust toolchain, and muir checked
out beside this repository. Nothing here vendors a copy of muir's netlists or
part tables.

    make check

## Layout

`rtl/` is the usual name for HDL sources and also muir's name for this fidelity
level; here the two coincide.

    rtl/      SystemVerilog
    tb/       Verilator testbenches
    golden/   Rust, depends on muir by path; writes the reference traces
    build/    generated, not committed
