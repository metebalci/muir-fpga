# muir-fpga

The MIT CADR on an FPGA, at netlist level, at the speed the hardware ran.

[muir](https://github.com/metebalci/muir) simulates the CADR down to its
chips. Its `chip` engine runs the netlists themselves and runs them at about
1/4,000 of real time. This is the same machine in fabric instead, where the
netlist runs at the machine's own 145 ns microcycle.

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
Main memory is not a netlist: 60 boards of 64K words is 66 Mb, and the Xbus
carries 22 address bits, so 3,932,160 words is the ceiling with the top four
slots taken by the display and the device registers. That lives in PS DDR3
behind an Xbus bridge, and so does the frame buffer.

## What is fabric and what is Linux

The rule: **fabric holds anything with a clock edge the CADR can see; Linux
holds anything with a protocol, a file, or a name in it.**

| Fabric | Linux on the PS |
|---|---|
| The netlists --- gates, registers, RAMs | RFB: TCP, encoding, keysym mapping |
| Xbus to DDR (main memory, frame buffer) | The pack as a file on microSD |
| Trident bus timing, seek and rotation | Chaosnet routing and its services |
| Chaosnet cable encode, decode, collision | The console |

Main memory is the only seam that runs at machine speed, and it is the one
with no software in it. Everything else is millisecond- or human-scale.

Ports: `S_AXI_HP0` for the memory bridge, `M_AXI_GP0` and AXI4-Lite for the
console and the buffers. Note the Zynq-7000 PS-PL interfaces are **AXI3**, not
AXI4; the logic here is AXI4 and Vivado's converter bridges the two.

## The plan

Two implementations of the processor behind one port interface, as muir has
three engines behind one trait. **The interface is `data/cables.txt` --- the
92 wires on the five cables between the processor and the bus interface, pin
for pin off MIT's wire lists.** Anything shaped to a Rust API instead would
take the ported model and refuse the netlist.

1. **The clock generator.** `clock.rs`, ported. **Done.**
2. **The port list.** `cables.txt` as SystemVerilog, direction derived from
   the two netlists rather than asserted. **Done.**
3. **The bus interface and the DDR bridge**, driven by a test master on the
   92 cable wires --- the Xbus handshake, `-HANG`, the NXM timeout and the
   AXI plumbing proved without a processor. The memory cycle and the NXM
   timeout are **done**; the DDR bridge, `-HANG`, the Unibus path and its
   arbitration, the interface's own registers and the debug cable are each
   their own slice.
4. **The processor**, ported from `rtl.rs` first, then the netlist behind the
   same ports, each checked against the other and against muir.

Of the 92 wires, 15 are inputs, 29 outputs, and 48 --- `MEM<31:0>` and
`SPY<15:0>` --- are driven from both ends. Fabric has no bus to fight over, so
those are carried as a value and an enable out with the resolved wire back in,
and the resolution is the cable's rather than either board's.

Names are mangled to legal identifiers, and this is where that was settled,
because everything generated later inherits it: a leading `-` becomes `n_`,
`.` and space and `/` and `>` become `_`, a leading digit takes an `x`, and a
collision is an error rather than a warning. `rtl/cadr_cables.map` holds every
identifier against the name MIT wrote.

Alongside, a spike on one page of `CADR.netlist` --- `ALU0`, four `74S181`s,
no state and no tri-state --- to settle how netlists become SystemVerilog
before there are 50 cell models depending on the answer.

## Checking

Everything is held to muir. A reference trace comes out of muir's own model
and carries the stimulus as well as the expected outputs, so the testbench and
the model cannot drift apart.

    make check

Needs [Verilator](https://verilator.org) and a Rust toolchain, and muir
checked out beside this repository. Nothing here vendors a copy of muir's
netlists or part tables: they are the source of truth and a copy would go
stale silently.

| | Checked against | State |
|---|---|---|
| `rtl/cadr_phase_gen.sv` | `clock::Behavioural`, 12,000 ticks | passing |
| `rtl/cadr_cables.svh` | both netlists through `part::pinout`, and `cable.rs`'s own table | passing |
| `rtl/cadr_busint_xbus.sv` | `busint::Busint`, 40,000 ticks over 146 cycles | passing |

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

    rtl/      SystemVerilog
    tb/       Verilator testbenches
    golden/   Rust, depends on muir by path; writes the reference traces
    build/    generated, not committed
