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

Three ports cross the boundary. `S_AXI_HP0` is the memory bridge's, and it is
the one at machine speed. `S_AXI_HP1` is the disk's. A Trident turns 60 times a
second with 17 blocks to the track --- 1,020 blocks a second of 256 words each
--- so a streaming pack is 261,120 words a second, just over a megabyte.
Bandwidth was never the point. The point is that on a port the PS masters those
are 261,120 stalled CPU stores a second, against a 968 us deadline for each
block. So fabric fetches the block out of DDR itself, off the block's address
written by Linux, and no CPU is in the per-word path. Its own port rather than
a share of `HP0`, so that disk traffic adds no arbitration to the memory path.
`M_AXI_GP0` and AXI4-Lite carry what is left: the disk's registers, the
Chaosnet buffers, the console. The Zynq-7000 PS-PL ports are **AXI3**, not
AXI4; the logic here is AXI4 and Vivado's converter bridges the two.

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
