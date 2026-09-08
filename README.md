# muir-fpga

The MIT CADR on an FPGA, at **rtl level**, at the speed the hardware ran.

[muir](https://github.com/metebalci/muir) simulates the CADR at three
fidelities. `rtl` is the middle one: the machine's own two-phase clock, every
datapath signal on it, and everything that is a matter of *when* --- bus waits
and hangs, arbitration, timeouts. It is hand-written and checked against MIT's
netlists rather than being them, and it runs at about half real time in
software. This is that machine in fabric, at the CADR's own 145 ns microcycle.

`rtl` is muir's word for this level and it is the word used throughout here.
muir's netlists are read to **derive** things --- the port list's directions,
the address decode's boundaries, every constant that came off a drawing --- but
nothing in fabric is a netlist and nothing here claims to be. Whether a
gate-level implementation ever follows is an open question and not a promise
this repository makes.

Separate from muir because the toolchain is: Vivado, Verilator and a Zynq
build have nothing to do with muir's property of building and testing offline
with no crate dependencies. muir stays the reference, and everything here is
checked against it.

## Target

Digilent **Arty Z7-20**, `XC7Z020-1CLG400C`: 53,200 LUTs, 106,400 flip-flops,
630 KB of block RAM, dual Cortex-A9 at 650 MHz, 512 MB of PS DDR3, gigabit
Ethernet, microSD.

The processor's own memories are 980 Kb --- the 16K x 48 control store, the
scratchpads, the maps --- and the display's frame buffer is another 1,060 Kb.
Main memory cannot live in fabric at all: 60 boards of 64K words is 66 Mb, and
the Xbus carries 22 address bits, so 3,932,160 words is the ceiling with the
top four slots taken by the display and the device registers. That lives in PS DDR3
behind an Xbus bridge, and so does the frame buffer.

## Where the CADR's memory lives in DDR

The one map in the project that is expensive to change, because it is shared
with the Linux side --- a reserved-memory node, whatever loads a band, whatever
reads the frame buffer. So it is settled early, in `rtl/cadr_ddr_map.sv`, and
**reserved at the size the machine could one day want rather than the size it
can reach**. Reserving costs nothing: this is a quarter of the board's 512 MB
and Linux keeps 384 MB.

| base | reserved | reachable today | |
|---|---|---|---|
| `0x1800_0000` | 64 MB, 16M words | **15 MB, 3,932,160 words** | main memory |
| `0x1C00_0000` | 8 MB, 2M words | **128 KB, 32,768 words** | display |
| `0x1C80_0000` | 56 MB | --- | spare |

What limits main memory is not DDR and never was. The CADR's physical address
is 22 bits: the level-2 map entry carries a 14-bit page frame and `VMA<7:0>` is
the offset within the page, so `-PMA21..8` and `-VMA7..0` are all that cross
the cables and all the Xbus carries. The machine's *virtual* address is 24 bits
--- 16M words --- which is what the 64 MB is room for. Widening the physical
side is not blocked by the map RAM, whose level-2 word is 24 bits with only 16
used, but by wires and microcode: new lines out of VMEMDR, new cable wires, new
`-XADDR`s, and microcode that writes the wider frame. That is a fork of the
machine, a project of its own, and not a change to this map.

The display's 8 MB is room for 1920 x 1080 at 32 bits a pixel. The CADR's own
screen is 768 x 963 at one bit and 32bpp is not a size its window system could
drive, so that room is for a display that is not the CADR's: **the Linux side
serves a 1080p canvas over RFB and composites the machine's screen into it.**
The CADR keeps addressing its 32,768 words either way.

## What is fabric and what is Linux

The rule: **fabric holds anything with a clock edge the CADR can see; Linux
holds anything with a protocol, a file, or a name in it.**

| Fabric | Linux on the PS |
|---|---|
| The boards: datapath, bus, device logic | RFB: TCP, encoding, keysym mapping |
| Xbus to DDR (main memory, frame buffer) | The pack as a file on microSD |
| Trident bus timing, seek and rotation | Chaosnet routing and its services |
| Chaosnet cable encode, decode, collision | The console |

Main memory is the only seam that runs at machine speed, and it is the one
with no software in it. Everything else is millisecond- or human-scale.

Ports: `S_AXI_HP0` for the memory bridge, `M_AXI_GP0` and AXI4-Lite for the
console and the buffers. Note the Zynq-7000 PS-PL interfaces are **AXI3**, not
AXI4; the logic here is AXI4 and Vivado's converter bridges the two.

## The plan

Port muir's behavioural models, board by board, and keep the boundaries between
them where the hardware's are. **The processor's boundary is
`data/cables.txt` --- the 92 wires on the five cables between the processor and
the bus interface, pin for pin off MIT's wire lists.** A boundary shaped to a
Rust API instead would be muir's shape rather than the machine's, and would
have to be unpicked by anything that ever wanted to be closer to the hardware.

1. **The clock generator.** `clock.rs`, ported. **Done.**
2. **The port list.** `cables.txt` as SystemVerilog, direction derived from
   muir's netlists and pinouts rather than asserted. **Done.**
3. **The bus interface and the DDR bridge**, driven by a test master on the
   92 cable wires --- the Xbus handshake, `-HANG`, the NXM timeout and the
   AXI plumbing proved without a processor. The memory cycle and the NXM
   timeout are **done**, the address decode is **done**, and so is the bridge
   in front of DDR and the path that puts the three together; the AXI adapter
   behind it, `-HANG`, the Unibus path and its arbitration, the interface's own
   registers and the debug cable are each their own slice.
4. **The processor**, ported from `rtl.rs`, behind those 92 ports and checked
   against muir as everything else here is. The largest single port in the
   project at 2,721 lines, and the last.

Of the 92 wires, 15 are inputs, 29 outputs, and 48 --- `MEM<31:0>` and
`SPY<15:0>` --- are driven from both ends. Fabric has no bus to fight over, so
those are carried as a value and an enable out with the resolved wire back in,
and the resolution is the cable's rather than either board's.

The five cables are named by both ends, because the processor end alone is
ambiguous: `1AJ1` is the CADR board's connector **and** the ICMEM board's.
They are `1AJ1-J11` (20 wires), `1AJ1-J08` (12, the ICMEM board's),
`1BJ1-J12` (20), `1CJ1-J09` (20) and `3AJ1-J07` (20).

Names are mangled to legal identifiers, and this is where that was settled,
because everything generated later inherits it: a leading `-` becomes `n_`,
`.` and space and `/` and `>` become `_`, a leading digit takes an `x`, and a
collision is an error rather than a warning. `rtl/cadr_cables.map` holds every
identifier against the name MIT wrote.

## Checking

Everything is held to muir. A reference trace comes out of muir's own model
and carries the stimulus as well as the expected outputs, so the testbench and
the model cannot drift apart.

    make check

The address decode is checked at **every** one of the 4,194,304 addresses the
22-bit Xbus can carry, for four board counts --- 16.7 million evaluations in
about half a second, so there is no reason to sample. The reference for it is
written as runs of equal answer, eight per board count, which keeps the file
readable against the constants it came from while the check stays exhaustive.

Needs [Verilator](https://verilator.org) and a Rust toolchain, and muir
checked out beside this repository. Nothing here vendors a copy of muir's
netlists or part tables: they are the source of truth for every constant that
came off a drawing, and a copy would go stale silently.

| | Checked against | State |
|---|---|---|
| `rtl/cadr_phase_gen.sv` | `clock::Behavioural`, 12,000 ticks | passing |
| `rtl/cadr_cables.svh` | muir's netlists through `part::pinout`, and `cable.rs`'s own table | passing |
| `rtl/cadr_busint_xbus.sv` | `busint::Busint`, 40,000 ticks over 146 cycles | passing |
| `rtl/cadr_xbus_decode.sv` | `busint::decode`, every address of the 22-bit space | passing |
| `rtl/cadr_memory_path.sv` | the three together: muir for the timing, the stimulus for the data | passing |

Every check is mutation-tested, and every check requires coverage, so none can
pass while exercising nothing. Moving the clock's normal tap by one tick or the
`TPTSE` window by five nanoseconds fails the first; moving the Xbus setup or
deskew by five nanoseconds, or acknowledging a read as promptly as a write,
fails the third.

Three things the Xbus check found, all in what was written here rather than in
muir. `-MEMACK` on a **write** is combinational in the slave's answer --- XACK
is made from XBUS ACK IN by the 74S64 at REQLM 0C11, a gate, and only a read
goes through the 60 ns tap of the TD100 at 0C09 --- so registering it puts the
acknowledgement a tick late. A request **standing at the master clock edge** is
granted at that edge: the priority logic registers `-MEMRQ` and does not care
how long it has been up. And the timeout oscillator at REQTIM 0A01 **free-runs
from power-on**, the grant only opening its output, so restarting it at the
grant --- which is the obvious way to write it --- gives the wrong instant on
every cycle but the lucky ones. All three are caught by mutation.

## The first piece with no reference

Everything else here is a port, held to muir tick for tick. Nothing in MIT's
drawings is a DDR controller, and `busint::MemoryBoard` models a board of 4116s
refreshing itself, which is not what this is --- so `cadr_xbus_ddr.sv` is held
to what has to be true of it instead: **a read returns the word an earlier
write put at that address**, while the cycle around it still keeps muir's
timing.

The bridge is deliberately thin. It adds no ticks: `mem_req` follows
`-XBUS.RQ` and `dev_ack` follows `mem_done`, neither with a register in the
way, so the whole latency belongs to the AXI adapter behind it and shows up as
the device's answer time. That is what keeps it comparable with a model whose
device answers `device_ns` after `-XBUS.RQ` and not `device_ns` plus whatever
the slave costs. Registering it later would not be wrong --- the interface
waits for any slow slave --- but it would be a change to measure.

Two things about the integrity half are worth writing down, because both were
wrong first.

**The shadow has to come from the stimulus, never from the DUT.** Keyed by the
bridge's own `mem_addr` and filled from its own `mem_wdata`, it moves with the
bug: a bridge that wrote the address instead of the data, or dropped an address
bit, wrote consistent nonsense and every read agreed with it. Both pass only
because the shadow is now keyed by the trace's `phys` and filled with the
trace's `wdata`, and both are in the mutation list.

**Reads and writes have to be able to meet.** The addresses are visited in
rotation and a write happens every third cycle, so an address count sharing a
factor with three means writes land only on one residue and reads on the
others --- the integrity check then passes while testing nothing, with every
timing comparison still green. The generator asserts the counts are coprime
rather than trusting a comment.

Known and untested: the bridge holds `mem_req` up until `mem_done`, and a
mutation that leaves it up afterwards is not caught, because nothing in this
model looks. It will matter to the AXI adapter, where a request left asserted
would re-issue.

## Where this differs from muir

Deliberate divergences, each with a reason.

**The timeout races, where the model decides.** `busint.rs` works out at the
grant whether a cycle will be answered or will time out, because it can see
which responder is at the address; the board cannot, so its timer runs on every
cycle and whichever comes first wins. They agree wherever the model is
exercised --- a real slave answers far inside 4.25 us --- and the traces keep
`device_ns` well within the timeout so that the two are comparable. Here the
fabric is closer to the board than the model is.

**`busint.rs` sees the future.** The same shortcut in the ordinary case: the
model computes when the device *will* answer at the moment of the grant.
Fabric cannot, so the request goes out and the answer comes back when it comes
back. Tick for tick the two agree; the structure differs, which is why the
Xbus slave lives in the testbench rather than in the module.

**`-TPR60` under `RESET`.** `clock.rs` says "RESET holds the ring cleared: no
transition until it lifts", and `next_at` answers `None` for as long as it is
held. But `chip.rs`'s `apply_clock` still derives `-TPR60` from `phase_ns`,
which is `time - cycle_start` with `cycle_start` left wherever the last cycle
put it. Time runs while reset is held, so `phase_ns` sweeps through 60..100
and the reference emits a read tap off a ring it has just called cleared ---
40 ns of `-TPR60`, which OLORD1 turns into `SPEEDCLK` and which clocks the
speed synchroniser at 1A01. Here the ring is cleared and `-TPR60` stays
deasserted. The testbench does not compare it while `RESET` is high.

## Layout

`rtl/` is the usual name for HDL sources and it is also muir's name for this
fidelity level. Here the two coincide: what is in `rtl/` is rtl level.

    rtl/      SystemVerilog
    tb/       Verilator testbenches
    golden/   Rust, depends on muir by path; writes the reference traces
    build/    generated, not committed
