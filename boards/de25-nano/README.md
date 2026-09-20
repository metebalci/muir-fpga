# DE25-Nano

The [Terasic DE25-Nano](https://www.terasic.com.tw/cgi-bin/page/archive.pl?Language=English&CategoryNo=115&No=1384)
is a small board built around an Altera Agilex 5 SoC. It is an SoC board in
the same sense as the two Zynq-7000 boards here. Hard Arm cores sit beside the
fabric, and a bridge lets the fabric reach their memory.

**The machine is built for this board without its memory, and it meets
timing.** This directory holds the top level, `cadr_de25.sv`, a Quartus flow
under `quartus/`, this README and a pin file, `de25_nano_pins.tcl`. The top level is the Arty Z7-20's memory-off board on
this part: the machine running its boot PROM with nothing behind its memory
port. There is no processor configuration, no device tree and no image yet.
`docs/toolchain.md` says how to build the bitstream and load it.

**What this part computes has been compared with muir.** The probe, built in
with `PROBE_DEPTH=1024`, recorded the machine's first 1,024 microcycles on
the board, and they agree with muir's trace column for column. "The probe"
below has the figures.

## What the board is

Every fact in this section comes from Terasic's specification page, its
manuals or its resource package, and each one is cited. The user manual is the
rev B manual, version 1.1, and its page numbers are the ones printed on its
pages. The resource package is the rev B package, described under "Where the
pins are" below.

| | |
|---|---|
| part | A5EB013BB23BE4SCS, an Agilex 5 E-series device of group B |
| logic | 138,060 logic elements, 46,800 adaptive logic modules and 376 DSP multipliers |
| memory in the part | 6.99 Mb of M20K and 1.43 Mb of MLAB |
| hard processor system | two Cortex-A76 cores and two Cortex-A55 cores |
| processor memory | 1 GB of LPDDR4 on the LPDDR4A bank, which the fabric may use instead when the processor does not |
| fabric memory | 1 GB of LPDDR4 on the LPDDR4B bank, and 128 MB of SDRAM |
| fabric clocks | three 50 MHz inputs: `CLOCK0_50` at 1.1 V, `CLOCK1_50` and `CLOCK2_50` at 3.3 V |
| HDMI | an Analog Devices ADV7513 transmitter, fed a 24-bit parallel video bus by the fabric and configured over I2C |
| Ethernet | gigabit, a KSZ9031RN PHY on the processor's RGMII |
| USB | USB 2.0 on-the-go, a USB3320 ULPI PHY on the processor, at a Type-C connector |
| microSD | on the processor |
| serial | an FT4232H behind the USB-Blaster III's Type-C connector, giving the processor's UART and a two-pin fabric UART |
| buttons | two push buttons, `KEY0` and `KEY1`, debounced and active low, and one more on the processor |
| switches | four slide switches, at 1.1 V |
| lamps | eight green LEDs, active low, at 1.1 V, and one more on the processor |
| headers | two 2x20 GPIO headers, JP1 and JP2, with 36 fabric pins each at 3.3 V |
| configuration | a 128 Mbit QSPI flash in Active Serial x4 mode by default, or JTAG, chosen by `MSEL` on the DIP switch SW5 |

The sources, row by row: the part and its group are in the package's
`golden_top.qsf` and in Altera's device overview inside the package
(`Datasheet/FPGA/ug_762191_762192-3601469.pdf`, section 2.2, the E-series
table), which also gives the logic and memory counts. The cores and the two
memory banks are the manual's section 2.2 and section 3.7.4, pages 8 and 28.
The clocks are Table 3-6 on page 18, the HDMI transmitter is section 3.7.3 on
pages 26 to 28, and the processor's peripherals are sections 3.8.2 to 3.8.5 on
pages 39 to 42. The serial ports are the Getting Started Guide's section 5.6 on
page 20 and the fabric UART's two pins in `golden_top.qsf`. The buttons,
switches and lamps are section 3.7.1 on pages 20 to 22, the headers section
3.7.2 on pages 22 to 26, and the configuration modes section 3.1 on pages 10
and 11.

**Terasic's documents disagree in three places, and the files decide.** The
manual's feature list on page 6 names the part A5EB013BB23BE4SR1 with "130K
LEs", while page 8 gives 138K, and Terasic's specification page and both
`golden_top.qsf` files name A5EB013BB23BE4SCS. The same list says four push
buttons, while the manual's own pin table on page 22, the specification page
and both golden tops give two. And the list says "HDMI 2.0", while section
3.7.3 names a transmitter with "HDMI v1.4 features". A `.qsf` is what Quartus
reads, so this directory takes its part and its two buttons.

**Terasic sells two revisions, and they differ in the LPDDR4.** Terasic's
revision page gives rev A as running its LPDDR4 up to 1066 MHz and rev B up to
1333 MHz, and tells them apart by a seal mark on the bottom of the board, `A0`
or `B0`. Terasic publishes a resource package for each. This README was read
against rev B's.

## What the port is made of

A port is the same four things the Zynq boards have, made with another
vendor's tools:

- a top level in this directory, the counterpart of
  `boards/arty-z7-20/cadr_arty.sv`. It is `cadr_de25.sv`, without the
  processor;
- the pins, which `de25_nano_pins.tcl` carries, and an `.sdc` carrying the
  clocks and the exceptions. `quartus/cadr_de25.sdc` has the board's
  asynchronous pins and the machine's exceptions;
- the hard processor system's configuration, generated by Platform Designer,
  in place of the Zynq boards' `vivado/ps7_config.tcl` and `cadr_ps7.sv`;
- a device tree and a Linux image.

**The machine does not change for this board.** It does not know what part
it is on, and that is the promise the two Zynq boards already keep. The one
addition to `rtl/machine/` is a check's variant, `CADR_RDW_POISON`, which
only Verilator compiles; without the define the file preprocesses to exactly
what it was.

## What is genuinely new

**A second toolchain.** Every other flow script, constraint file and vendor
primitive in this repository is Vivado's. `rtl/plumbing/xilinx7/` holds the
build stamp's `USR_ACCESSE2`, the HDMI clocking and serializers, and five XDC
files, and the Zynq top levels hold the debug probe's `BSCANE2`. None of it
carries over. The probe's capture, `rtl/plumbing/cadr_probe.sv`, is plain
SystemVerilog and does, and this board's own vendor RTL is under
`rtl/plumbing/agilex5/`. The relaxed
register set in `cadr_machine.xdc` is built out of Vivado's own queries, so it
has to be written again for Quartus, together with the assertion that its
exceptions reach the design. It has been, and the first fit showed it was
needed: see "The fit and the timing" below.

Quartus Prime Pro 26.1.1 is installed, with a no-cost license that covers the
Agilex 5 E-series only, and `make de25` builds the machine with it. Ubuntu
26.04 is not on Quartus's list of supported operating systems. Terasic's own
material for this board was made with Quartus Prime Pro 25.1.1.

**The two vendor pieces are Altera IP, generated at every build.** The clock
is an I/O PLL from `CLOCK0_50`, 50 MHz in and 100 MHz out. The Agilex 5 PLL
primitive takes 94 parameters, and the IP is what chooses them. The Reset
Release is the IP that says the whole part has entered user mode, and it
holds the PLL in reset until then. For this family the IP's generated code is
one instance of a primitive, and that primitive was tried alone first.
Quartus then issued critical warning 20759 and failed design rule RES-10204,
"No reset release IP detected in project", because both look for the IP.
Neither IP's output is committed, because it carries Altera's license terms.
`quartus/build.sh` generates both from the parameters written in it.

**aarch64 rather than armhf.** Every Linux program here is cross-built for the
Zynq's 32-bit Cortex-A9. This board's cores are 64-bit, so the Buildroot
configuration, the kernel and every package build are new. Terasic's own
image is Ubuntu 22.04.3 on a 6.12.11 kernel, according to its resources page.

**A different boot chain.** The Zynq's boot ROM reads `BOOT.BIN` off the card.
On this board Terasic's reference design merges U-Boot's first stage into the
fabric's configuration image with `quartus_pfg`, and writes the result to the
QSPI flash. The first stage then loads Arm Trusted Firmware and U-Boot proper
from the card, and U-Boot loads the kernel from there. That is the package's
`Demonstration/SoC_FPGA/GHRD/sof_with_hps.bat` and `sof_to_jic.bat`, and
Terasic's "Build Linux image from scratch" guide. So the fabric's image and
the first-stage loader are one file here, and a card holds no first stage.
`boards/README.md` keeps three names at the root of every card's boot
partition because the Zynq's boot ROM, its SPL and U-Boot look for them there.
That root would differ on this board.

**The FPGA-to-SDRAM bridge in place of `S_AXI_HP0`.** Terasic's reference
design configures the processor with one `f2sdram` interface, an AXI4
subordinate with 256 data bits and 32 address bits. Altera's bridge
demonstration, named at the end of this README, documents the width as 64, 128
or 256 bits, and the bridge as reaching only the memory on the processor's own
memory controller. The Zynq's `S_AXI_HP` ports are AXI3 at 64 bits. Where
the machine's reservation would sit in the bridge's address space has not been
read.

**And there is one such port where the Zynq has four.** On the Zynq boards the
machine's memory, the disk's block fetch and the display's scan-out each have
an `S_AXI_HP` port. The disk has its own so that its traffic adds nothing to
the machine's memory path. Here all three would share `f2sdram` behind an
interconnect, so that reason has to be met another way or measured.

## What has a counterpart, and what does not

| On the Zynq boards | On the DE25-Nano |
|---|---|
| `M_AXI_GP0`, the register faces | a processor-to-FPGA bridge. The reference design has two: `hps2fpga` at 128 bits and `lwhps2fpga` at 32 bits. |
| `M_AXI_GP1`, the console and the debug window | the other of those two bridges |
| `S_AXI_HP0`, `S_AXI_HP2` and `S_AXI_HP3` | the single `f2sdram` interface |
| `IRQ_F2P`, the fabric's interrupts to Linux | the processor's FPGA-to-HPS interrupt inputs |
| microSD, gigabit Ethernet, USB and Linux's serial console on the processing system | the same four on the hard processor system |
| HDMI made in fabric: `cadr_tmds_encode.sv`, `cadr_hdmi_tx.sv` and `xilinx7/cadr_hdmi_phy.sv` | the ADV7513 does the encoding. The raster in `cadr_display_out.sv` has a counterpart, and the encoder and the serializers do not. |
| the clock generator, an `MMCME2_BASE` from the board's 125 MHz | an I/O PLL from `CLOCK0_50`, Altera's IP, generated at each build |
| the debug probe and the build stamp | the same probe behind Altera's Virtual JTAG IP, and the build stamp in the JTAG USERCODE register, read back after every download |
| `SW0`, the no-auto-boot switch | `SW0`, the same switch. `SW1` to `SW3` are not assigned. |
| `BTN0` boots and `BTN1` resets the fabric | `KEY0` boots and `KEY1` resets the fabric. Both are debounced on the board. |
| six lamps, two of them RGB | `LEDR0` to `LEDR5` carry the Arty Z7-20's six in its order, all green. `LEDR6` and `LEDR7` are dark. |
| the debug cable on Pmod JA | no Pmod header. The two 2x20 GPIO headers are the candidate, and nothing is decided. |

**The GPIO headers carry supplies, as a Pmod does, on other pins.** Each has
5 V on pin 11 and 3.3 V on pin 29, with ground on pins 12 and 30, according to
the manual's Figure 3-18 on page 23. A cable from one of them to a Zynq
board's Pmod is therefore an adapter, and the rule in `docs/debug-cable.md`
that a cable leaves the supply pins open applies with a different pin list.
That document also asks which header to take on a part whose headers are not
alike. These two are alike.

**What a read nobody answers does on this board's bridges is not measured.**
On the Zynq such a read hangs both cores, which is why the register faces there
answer every address, and a port here should answer every address too until
the question is settled. Altera's own bridge demonstration puts a default
subordinate on the lightweight bridge, so that an undecoded address answers
with an error.

## The three asynchronous memories

**The dispatch memory and both levels of the map are MLABs.** The machine
reads the three asynchronously, as MIT's board does. By default Quartus
builds an asynchronously read array out of registers: about 70,000 of them,
three quarters of the part, and a fitter that ran for more than half an hour.
Altera's Agilex 5 embedded memory guide gives the MLAB alone "asynchronous
memory ... for flow-through read memory operations". So the flow asks for an
MLAB, with read-during-write checking off, by an assignment in
`quartus/project.tcl`. Nothing in `rtl/` names a vendor's memory, and
`quartus/build.sh` refuses a synthesis in which the three are not MLABs.

**What "checking off" gives away is one tick, and three checks hold it.**
The word read at an address in the tick after the edge that wrote it is then
not specified. Built with `CADR_RDW_POISON`, the processor returns the
complement of the word in exactly that tick. The processor checks on both
programs and the map check's patched PROM still agree with muir, and the
checks count the poisoned ticks. The last section of
`rtl/machine/cadr_microcycle.sv` has the argument.

## The fit and the timing

Measured with `make de25` at the default optimization, on the machine
without its memory:

| | |
|---|---|
| ALMs | 5,162 of 46,800, 11%, of which 1,920 hold the three MLAB memories |
| M20K blocks | 95 of 358, 27%, 1,762,880 bits |
| DSP blocks | 0 |
| worst setup slack | +3.731 ns, at the slow corner at 0 C |
| worst hold slack | +0.054 ns, at the fast corner |

One clock carries every register path, the PLL's 100 MHz, and both figures
are that clock's. The build takes about eight minutes.

**The machine does not close at one tick with no exception on this part,
and it closes with `cadr_machine.xdc`'s.** The first fit had no exception in
the machine and missed by 2.012 ns on 135 endpoints, every one a register
the processor loads at the microcycle boundary: `md`, `pc`, `md_held`, the
console's read-back, `ir`, `vma` and a few more. Those are the paths that
file gives eight ticks on the Zynq boards. `quartus/cadr_de25.sdc` writes its
three clauses again with the same register sets, the same names and the same
counts: the relaxed set at eight ticks, the display board's word at eight,
and the Unibus map's word at fifteen, the last two on the registers' data
pins only. `quartus/sta_check.tcl` then asks each path what it is required
to do, as the Zynq flow does:

| | |
|---|---|
| the relaxed set | 4,055 registers, less 122 tick-rate registers, with 23 held decodes put back |
| endpoints whose worst path asks for 80 ns | 54 |
| the display board's word, at 80 ns | all 36 of its data pins, and none of the board's other 137 registers |
| the Unibus map's word, at 150 ns | all 256 of its data pins, and none of the block's other 60 registers |
| registers outside the machine carrying a relaxed requirement | none of 95 |

Register retiming is off, so these names match the registers the design
has. Quartus retimes by default, and the first fit had moved 233 registers.

**The control store is in the fit twice.** The second copy is the console
readout's port. Its address is tied off on this board, and the register that
selects it powers up at zero, because the flow turns Quartus's power-up
don't-care off so that every register starts at zero as it does in Verilator
and on the Zynq boards. With the setting on, the readout would fold away.

## The memory board

`make de25 DDR=1` builds the machine with the processor behind its memory
port, which is what `DDR=1` does for the Arty Z7-20. The pieces are the
processor system, generated from `quartus/hps.tcl` at every build, and
`rtl/plumbing/cadr_f2sdram_port.sv`, whose header is the argument for the
memory path.

**The machine's memory is the FPGA-to-SDRAM bridge.** It is AXI4 at 64 bits,
and every beat must be the full bus width, so the path is the Zynq boards'
with one piece changed: `cadr_axi_master.sv` and `cadr_axi_widen.sv` are
unchanged, and `cadr_f2sdram_share.sv` takes their AXI3 shape to the bridge's
AXI4 one, with the bridge's own attributes on every transaction. The
machine's 128 MB are at `0xB000_0000`, the second 128 MB from the top of the
processor's 1 GB, and `rtl/plumbing/cadr_ddr_map.sv` says why they are not at
the top.

**One port, three masters, the machine first.** The disk pack side and the
display have ports of their own on the Zynq and share this one here, so the
arbiter is in the design now, with the machine on port 0 and the other two
tied off until their slices arrive. It grants by burst, lets each master have
one burst in flight in each direction, and grants the others nothing new
while the machine is asking for a word or waiting for one. That hold is what
bounds a machine cycle --- what the machine waits for is what was already in
flight when it asked --- and priority by port alone does not do it: with one
burst in flight per master, a master waiting for its answer is not asking, so
reversing the priority moved not one number of the check. The measured worst
is 27 ticks of growth with both other ports streaming.

**The port is shut until software opens it**, on bit 0 of `h2f_gp_out`. The
first-stage loader calibrates the memory and opens its firewall, and the
secure firmware releases the bridge when U-Boot runs `bridge enable`; until
then a memory cycle would meet a bridge in reset. So the fabric holds its
master off, and every memory cycle ends on the NXM timer, exactly as on a
board with no memory. The processor's warm-reset handshake is answered the
same way: while it asks for quiet nothing new is put to the bridge, and the
acknowledgment follows once nothing is outstanding.

**The tally is one word here and two on the Zynq boards.** It is
`cadr_mem_count.sv`'s sixty-four bits, and `h2f_gp_in` carries thirty-two, so
bit 1 of `h2f_gp_out` chooses the half: low the answers, high the requests.
Software reads it at the system manager's GPI register, and each half carries
the marker that says the fabric and not an undriven register wrote it.

| what | where |
|---|---|
| main memory | `0xB000_0000`, 128 MB reserved, 15 MB reachable |
| the display's buffer | `0xB400_0000` |
| the gate | `h2f_gp_out[0]`, the system manager's GPO at `0x10D1_20E4` |
| the tally's half | `h2f_gp_out[1]` |
| the tally | `h2f_gp_in`, its GPI at `0x10D1_20E8` |
| the processor-to-fabric bridges | 1 GB at `0x4000_0000` and 512 MB at `0x2000_0000`, both answered end to end |

`build/f2sdram.pass` is the check: the machine through this path against a
model of the bridge, five configurations, with the region poisoned from
outside. Its header has them.

### The memory board's fit

Measured with `make de25 DDR=1` at the default optimization, the LPDDR4 at
1066.667 MHz:

| | |
|---|---|
| ALMs | 5,735 of 46,800, 12%, of which 2,030 hold the three MLAB memories |
| M20K blocks | 95 of 358, 27%, 1,762,880 bits |
| pins | 127 of 351 |
| worst setup slack | +3.343 ns, at the slow corner at 0 C |
| worst hold slack | +0.000 ns, at the fast corner |

The worst setup path is the machine's own, `busint`'s elapsed counter into
MD, ten levels of logic and 6.654 ns of delay, which is the family of paths
the board without memory is critical on too. The worst hold path is inside
Altera's ready-latency adapter between the bridge and the memory controller,
launched and latched by the machine's clock, zero logic levels, arrival
2.357 ns against a requirement of 2.357 ns.

**AND THE FIRST FIT OF THIS BOARD CLOSED AT +0.028 ns, ON A PATH THAT IS NOT
A PATH.** It ran from the fabric's handshake acknowledgment into the
processor's hard block --- zero logic levels, 0.795 ns of data delay --- and
was timed against `hps_internal_osc`, the processor's own 200 MHz
oscillator, which has no relation to the machine's clock at all: 3.953 ns of
that figure was skew between two clocks that are not related. The
acknowledgment and the tally are the only two things the fabric drives into
the processor asynchronously, and `quartus/cadr_ddr.sdc` cuts both and says
why each may be cut. With them cut the board closes at +3.343 ns, and
`quartus/sta_check.tcl` counts what the cut reached so that it cannot
quietly reach more.

### How the processor boots

`DE25_HPS_BOOT` chooses, and `DE25_SPL_HEX` names the first-stage loader the
Linux side builds:

| | |
|---|---|
| `hps-first` | the default. `quartus_pfg` writes the phase-1 bitstream for the flash and `cadr_de25.core.rbf` for the card, and the processor configures the fabric from U-Boot. |
| `fpga-first` | `cadr_de25_hps.sof`, one file the programmer loads over JTAG that configures the fabric and starts the processor's first stage. This is the board with no flash written. |

A bare `.sof` cannot configure a part with a processor in it, which the HPS
Booting User Guide says in its section 4.5.1, so `quartus/program.sh` loads
`cadr_de25_hps.sof` when the flow has written one.

## Loading it

`make de25-program` loads the bitstream over JTAG, into the part's
configuration memory, and a power cycle clears it. Nothing here writes the
QSPI flash. The board's configuration switch was not moved, and JTAG
configuration worked with it where it was. The programmer must report that
configuration succeeded.

**Then the part must hold the bitstream's build.** The build stamp is in the
JTAG USERCODE register, and `quartus/usercode.tcl` reads it back before the
download and after it, with the USERCODE instruction, `00 0000 0111`, from
Altera's JTAG boundary-scan guide for the family (document 820038, table 5).
It reads the IDCODE first, against the part's `4362C0DD`, which is what says
the scans return a register the right way round. On the board, the part read
back the stamp of each bitstream loaded into it.

**The plain build and the probe's carry the same stamp when they come from
one tree**, so USERCODE cannot tell them apart. The JTAG server can. It shows
a design hash for a design whose SLD hub has a node, and that hash is the
hub's own `DESIGN_HASH`, which Quartus writes into the build's `.sld` file.
It is not the assembler's design hash, as measured. The probe's build shows its
hash and the plain build shows none, and `program.sh` holds each build to
that.

## The probe

`make de25 PROBE_DEPTH=1024` builds the machine with `rtl/plumbing/cadr_probe.sv`,
the Zynq boards' capture, which records one sample a microcycle from the
machine's reset and freezes when it is full. Its JTAG side is this vendor's.
Altera's Virtual JTAG IP, generated by the flow as `cadr_de25_vjtag`, puts a
node on the SLD hub that Quartus builds around it, and
`rtl/plumbing/agilex5/cadr_probe_vjtag.sv` connects that node to the probe.
The node's virtual instruction is one bit. A 1 selects the sample register
and a 0 selects a bypass bit.

**On the board, the first 1,024 microcycles agree with muir.**
`make de25-probe` reads the capture with `quartus/probe.tcl` and compares it
with `build/rtl.golden` using `tools/probe_check.py`. Before it reads a
sample, the reader checks that the part holds the probe's build. It also
checks that a bypass scan returns its pattern one bit late and that the node
reads back the instruction shifted into it. Then all 1,024 samples agree with
the trace on 23 columns, the cycle counter and the probe's 22 columns. Eight of
those columns are constant over the window and so are checked vacuously:
`dc`, `st`, `lc`, `iwrited`, `n_vmaok`, `pcs0`, `vma` and `promdis`. A
second readout returned the same file. The window is structural, as on the
Zynq boards. The boot PROM's first memory cycle comes long after it, so the
memory path is not in it.

The probe's build, measured with `make de25 PROBE_DEPTH=1024`:

| | |
|---|---|
| ALMs | 5,594 of 46,800, 12% |
| M20K blocks | 118 of 358, 33%, of which the probe's 1,024 words of 454 bits take 23 |
| worst setup slack | +4.816 ns, at the slow corner at 0 C |
| worst hold slack | +0.055 ns, at the fast corner |

`quartus/cadr_probe.sdc` gives the probe two constraints. The JTAG clock,
`altera_reserved_tck`, is declared at 30 ns and made asynchronous to the
machine's clock. The probe's `stable_q` takes the machine's eight-tick
exception, as `boards/arty-z7-20/cadr_probe.xdc` gives it on the Zynq
boards. `quartus/sta_check.tcl` asks whether each of these reached what it
names. With either constraint removed, or the exception widened to the rest
of the probe, the build is refused.

**What holds each piece without a board.** `build/probe.pass` reads the
probe through the Altera node in Verilator, with TCK running in every state,
and compares every sample with the trace. `build/de25_jtag.pass` runs the
reader and `usercode.tcl` against a model of the `quartus_stp` commands they
use, with the command shapes measured on the board. `build/de25.pass` lints
the probe's configuration of the top level.

## Where the pins are

**The pin file is this project's own, transcribed from Terasic's user
manual.** `de25_nano_pins.tcl` gives the three 50 MHz clock inputs, the four
slide switches, the two push buttons, the eight LEDs, both GPIO headers and
the fabric's connections to the HDMI transmitter. Each line carries a port
name of this project's own, the manual's name for the signal, the package pin
and the Quartus I/O standard. Each group cites the manual's table and page. A
Quartus Tcl flow sources the file with a project open. The LPDDR4 banks, the
SDRAM, the MIPI connector, the ADC and the processor's pins are not in it yet,
and neither is the fabric UART, which the manual does not list.

**The pins are rev B's.** The file is transcribed from the rev B manual.
Terasic's revision page gives the difference between the two revisions as the
LPDDR4's speed, so the pins are taken to stand for a rev A board too. No rev A
manual was read to confirm it.

**The headers are named by header pin.** `jp1_pin13` is pin 13 of JP1, which
the manual calls GPIO 0, so choosing pins for a cable is a matter of naming
header pins. The four supply pins of each header, 5 V on 11, 3.3 V on 29 and
ground on 12 and 30, have no port. The ports are single wires rather than a
bus, because a bus would have four bits with no package pin. Quartus places
such a bit on a pin of its own choosing and finishes the fit with only a
critical warning, which was measured.

**One line departs from the manual, the HDMI pixel clock.** Table 3-13 on page
28 prints 3.3 V for `HDMI_TX_CLK` at pin DJ24. Quartus puts that pin in bank
2A_T, a high-speed I/O bank shared with the switches, the LEDs and
`CLOCK0_50`. Table 14 of Altera's device overview in the package gives that
kind of bank single-ended standards from 1.0 V to 1.2 V. Quartus refuses 3.3 V
on the pin even with nothing else in its bank:

    Error (179009): Could not find enough available I/O pin locations that supports the 3.3-V LVCMOS standard (1 location affected)

So the pin file gives the pixel clock "1.1-V". All fourteen `.qsf` files in
Terasic's package agree with that. How a 1.1 V output meets the transmitter's
inputs is not in the manual, and the package carries no schematic. The
ADV7513's data sheet in the package gives its video and audio data inputs a
high level of at least 1.35 V.

**A check holds the pin file to itself, and to the package when it is here.**
`tools/de25_pins_check.py` runs as part of `make check`. It always checks that
the file parses, that ports, pins and the manual's names are each unique, that
each port's name matches the manual's name beside it, and that each header has
exactly its 36 signal pins. When the package is present, it also compares
every port's pin and I/O standard with the package's
`Demonstration/FPGA/Golden_top/golden_top.qsf`, whose sha256 must be the one
in the table below. The package is named by `TERASIC_DE25_PACKAGE` in the
environment or by a line of that form in `local.conf` in this directory, which
git ignores. Without a package the comparison skips and says so. All 124 pins
agree with the package. For those 124 pins, the manual and the package's
`.qsf` differ in how they name the LEDs, the header signals and the video bus,
and otherwise only in the pixel clock's standard.

## The resource package

The manual and Terasic's golden top are both inside Terasic's DE25-Nano
Resource Package for rev B. Terasic's resources page lists that package as
version 1.0.0 of 10 November 2025, and downloading it requires a Terasic
account. The package carries no version file of its own.

| file inside the package | size | sha256 |
|---|---|---|
| `Demonstration/FPGA/Golden_top/golden_top.qsf` | 44,678 bytes | `de1431e72627743c7fa3ba7d6b8a833c54a28b9a3c0bfa76292126175bcea105` |
| `Demonstration/FPGA/Golden_top/golden_top.v` | 6,040 bytes | `edd355291a22e52c94ddf57c6845479a2e5bc5cf084debafc9bbd0e746da3f76` |
| `Demonstration/FPGA/Golden_top/golden_top.sdc` | 2,397 bytes | `98e5e597cf975e15827b226a76e38d21a78283f2223c1b5d34f14d467719dffd` |
| `Demonstration/SoC_FPGA/GHRD/golden_top.qsf` | 47,543 bytes | `bc80837d530aaebc3966a30e17bfa330b5c36603f17dcfc52c15496a85e155a1` |
| `Demonstration/SoC_FPGA/GHRD/hps_subsys/hps_subsys.qsys` | 612,853 bytes | `94e6828c17dc501d216d867ba41e44adb7c468d41250b650c9bbbbbc7fe9e05f` |
| `Manual/DE25-Nano_User_manual_revB.pdf` | 5,561,593 bytes | `22d74c3d0fa1e969636ea6b90983871505141616e97e9878cd878c1c22328bb6` |

`Golden_top` is the plain top level with every pin of the board, and
`SoC_FPGA/GHRD` is Terasic's reference design with the hard processor system
in it. The whole package, as read, is 6,745 files and 504,800,193 bytes, and
this command run at its root prints
`d1bac9168669b079feffd5c74227db2e1dec1d5c359499e760fd62cf08838cb8`:

    LC_ALL=C find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum

**Nothing of it is copied here, because nothing grants redistribution.**
`golden_top.v` carries Terasic's permission to use and modify the code for
synthesis on Terasic's boards, and prohibits the duplication of any portion of
it. The `.qsf` and `.sdc` files carry no terms at all. The user manual's
copyright statement on page 51 reads "All Rights Reserved". The Cora Z7-07S
directory vendors Digilent's pin file because Digilent publishes it under the
MIT license, and nothing comparable is published for this board.

**The pins are also in the user manual, which needs no account.** Terasic
serves the rev B manual directly from the board's resources page, and that
download is byte-identical to the copy inside the package, with the sha256
above. Its tables give the pins of the clocks, the buttons, the switches, the
lamps, the headers, HDMI and both memories with their I/O standards. That is
why the pin file is transcribed from the manual and not from the `.qsf`. The
fabric UART's two pins are in the `.qsf` and not in the manual.

**Altera publishes a DE25-Nano rev B build of its HPS bridge demonstration**
under MIT-0, in `github.com/altera-fpga/agilex5-demo-hps2fpga-interfaces` at
`brd_terasic_de25nano_revb`, read at commit
`064c0cf2f7e749b72add75d3ac3845f20af63dc8`. It names the same part, and its
`documentation/09_menu_p_hw_f2sdram_bridge.md` is where the bridge's widths
above are documented. Its project script assigns only the processor's memory,
clock and UART pins, so it is a reference for the processor's configuration and
not a pin file for the board.
