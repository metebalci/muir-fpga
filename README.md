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

`S_AXI_HP0` for the memory bridge, `M_AXI_GP0` and AXI4-Lite for the console
and the buffers. The Zynq-7000 PS-PL ports are **AXI3**, not AXI4; the logic
here is AXI4 and Vivado's converter bridges the two.

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
ceiling. Its *virtual* address is 24 bits, which is what the 64 MB is room for.

## The plan

Port muir's behavioural models board by board, keeping the boundaries where the
hardware's are. **The processor's boundary is `data/cables.txt`** --- the 92
wires on the five cables, pin for pin off MIT's wire lists.

1. **The clock generator**, `clock.rs`. Done.
2. **The port list**, `cables.txt` as SystemVerilog. Done.
3. **The bus interface and main memory**: the Xbus cycle, the NXM timeout, the
   address decode, the DDR bridge and its AXI adapter. Done. `-HANG` needs
   VCTL1, which needs the microinstruction, so it moves to 4.
4. **The processor**, from `rtl.rs`: 2,721 lines, the largest port here and the
   last. VCTL1 and `-HANG` come with it.

Then the Unibus path, the interface's own registers, the debug cable, and the
device boards.

## Checking

    make check

Needs [Verilator](https://verilator.org), a Rust toolchain, and muir checked
out beside this repository. Nothing here vendors a copy of muir's netlists or
part tables.

| | Checked against |
|---|---|
| `cadr_phase_gen.sv` | `clock::Behavioural`, 12,000 ticks |
| `cadr_cables.svh` | muir's netlists via `part::pinout`, and `cable.rs`'s table |
| `cadr_busint_xbus.sv` | `busint::Busint`, 40,000 ticks over 146 cycles |
| `cadr_xbus_decode.sv` | `busint::decode`, every address of the 22-bit space |
| `cadr_memory_path.sv` | muir for the timing, the stimulus for the data |
| `cadr_axi_master.sv` | the AXI protocol, every tick, and read-back |

Every check is mutation-tested and every check requires coverage, so none can
pass while exercising nothing. `CLAUDE.md` has what each is holding to, where
the fabric parts from muir, and what went wrong getting here.

## Layout

`rtl/` is the usual name for HDL sources and also muir's name for this fidelity
level; here the two coincide.

    rtl/      SystemVerilog
    tb/       Verilator testbenches
    golden/   Rust, depends on muir by path; writes the reference traces
    build/    generated, not committed
