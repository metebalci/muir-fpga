<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Reaching the board

The board need not be attached to the machine that runs Vivado. `hw_server`
owns the JTAG cable. It speaks to Vivado's hardware manager over TCP 3121, so
the tools can sit on one machine and the Arty on another. That is the
arrangement here. Vivado runs on a machine with the memory for it, and the
board sits wherever is convenient.

## On the machine holding the board

Install **Hardware Server** from the AMD unified installer. Do not install
Vivado. Do not install Vivado Lab Edition either, unless you also want to
program from that machine. Hardware Server is the smallest of the three. It is
`hw_server` plus the cable drivers. Its version should match the Vivado it will
talk to. Mixing versions sometimes works, and it is a poor thing to be
debugging on a first bring-up.

    ~/Xilinx/<version>/HWSRVR/bin/hw_server

That install has no `settings64.sh`. Call the binary by its path. It listens on
`TCP::3121` unless `-s<url>` says otherwise. `-d` daemonizes it.

## The udev rules, which are not optional

The Arty Z7-20's JTAG is an onboard FTDI FT2232H, `0403:6010`. It reports
`manufacturer = Digilent`. Without rules its device node is `crw-rw-r--
root root`. `hw_server` running as an ordinary user can then read it but not
write it. **The symptom is not a permission error.** The server starts, Vivado
connects to it, and then Vivado says:

    ERROR: [Labtoolstcl 44-199] No matching targets found on connected
    servers: <address>

That reads like a cable or a network problem. It is neither.

The rules ship with Vivado. Take them from a machine that has it rather than
writing them yourself:

    <Vivado>/data/xicom/cable_drivers/lin64/install_script/install_drivers/
        52-xilinx-digilent-usb.rules
        52-xilinx-ftdi-usb.rules
        52-xilinx-pcusb.rules

    sudo cp 52-xilinx-*.rules /etc/udev/rules.d/
    sudo udevadm control --reload-rules && sudo udevadm trigger

Then **unplug the board and plug it back in.** udev applies rules on `add`. A
device that has already enumerated keeps the permissions it was born with. The
whole thing therefore looks unchanged until it is replugged. The device number
changes when it works.

The rule that does the work is

    ACTION=="add", ATTRS{idVendor}=="0403", ATTRS{manufacturer}=="Digilent", MODE:="666"

It writes `:=` rather than `=`, so that a later rules file cannot lower the
mode.

## From Vivado

    open_hw_manager
    connect_hw_server -url <board-machine>:3121
    current_hw_target [lindex [get_hw_targets] 0]
    open_hw_target

These are Tcl commands inside Vivado, not programs. Run them in the Tcl
console, in `vivado -mode tcl`, or from a script with `-mode batch -source`.
Over ssh the last is easiest. A long run wants `nohup setsid ...
</dev/null &` with a poll, because the session will not outlive it.

A working chain on this board answers with two devices. They are the ARM debug
access port and the part itself:

    device: arm_dap_0   part=arm_dap
    device: xc7z020_1   part=xc7z020   idcode=0x23727093

If `get_hw_targets` finds none but the server connected, the cause is the rules
above and not the network.

## The console

The same cable carries a UART. Interface 0 is JTAG and belongs to
`hw_server`. **Interface 1 is the console.** It is `/dev/ttyUSB1` where
`ttyUSB0` is the JTAG channel. The rules above leave both nodes world
read-write, so `dialout` membership is not needed. If that is too permissive,
join `dialout` and tighten the rule to `0660` instead.

`ftdi_sio` claims both interfaces and creates both nodes. That is expected.
libusb detaches it from the JTAG interface once it has write permission.

## Programming a bitstream

    open_hw_manager
    connect_hw_server -url <board-machine>:3121
    current_hw_target [lindex [get_hw_targets] 0]
    open_hw_target
    current_hw_device [lindex [get_hw_devices xc7z020_1] 0]
    set_property PROGRAM.FILE build/bitstream/cadr_arty.bit [current_hw_device]
    program_hw_devices [current_hw_device]

`boards/arty-z7-20/vivado/program.tcl` does this and checks the answer. **What
says it worked is the DONE bit**, not the absence of an error.
`program_hw_devices` can complete against a device that did not take the
configuration.

    refresh_hw_device [current_hw_device]
    get_property REGISTER.IR.BIT5_DONE [current_hw_device]

## A bitstream does not start the PS

**This is the one that will waste an afternoon.** Programming the PL over JTAG
configures the fabric and nothing else. The Zynq's processor system stays in
reset until `ps7_init` has run. That covers its PLLs, `FCLK_CLK0`, the DDR
controller and every `S_AXI_HP` port. `ps7_init` normally runs in the FSBL from
a boot image. It does not run at all when a `.bit` is downloaded on its own.

So a design whose fabric clock comes from `FCLK_CLK0` is *dead* on a
JTAG-programmed board. A design that reads DDR gets no answer. Neither failure
looks like a missing initialization. The first looks like a bitstream that did
not load, and the second looks like a broken memory path.

Two consequences, both deliberate in `boards/arty-z7-20/cadr_arty.sv`:

- **The fabric clock comes from an MMCM off the board's 125 MHz pin, not from
  the PS.** It runs the moment the bitstream loads. A bring-up where nothing
  moves until a second thing works has two unknowns in it. The MMCM makes
  100 MHz --- 125 x 8 at the VCO, divided by 10 --- so a tick is 10 ns.
  The machine's tick counts come from the grid in
  `rtl/machine/cadr_tick_pkg.sv` and not from this clock, and
  `docs/timing.md` says why the two are separate numbers.
- **Anything needing DDR is a debugger test and not a program-and-look one.**
  From XSDB the sequence is `connect`, `targets -set -filter {name =~ "APU*"}`,
  `source ps7_init.tcl`, `ps7_init`, `ps7_post_config`. **The order of those
  last two against the bitstream download is not free.** It is not the same for
  a witness board as for the machine. The next section gives both orders, and
  the measurement each rests on.

## Bringing the memory up, in four steps

Four steps have been run on this board, in this order. Each has a script that
is the record of it. Each adds exactly one unknown: the processing system, then
the fabric writing, then the fabric reading, then the machine. So each step is
worth running only once the one before it has passed.

    boards/arty-z7-20/vivado/ddr_check.tcl     the controller starts, DDR answers, no bitstream
    boards/arty-z7-20/vivado/prove_write.tcl   the fabric writes a word, the debugger reads it
    boards/arty-z7-20/vivado/prove_read.tcl    the fabric reads a word and echoes it, three cases
    boards/arty-z7-20/vivado/ddr_run.tcl       the machine runs its boot PROM out of real DDR3

These are **XSDB** scripts and not Vivado ones, and they run from the
repository root. What they need is a debugger on the APU, not a hardware
manager. Each takes `BOARD_URL` for a remote board and `PS7_INIT` for the
start-up routine. From step two on, each also takes `BIT` for the bitstream.
Every line each script prints is prefixed `DDR:`, `PROVE:` or `RUN:`. Every
failure names the address, the value wanted and the value read before it exits
1, because an exit code cannot tell two failures apart.

### What has to exist first

The start-up routine is generated and is not committed:

    vivado -mode batch -source boards/arty-z7-20/vivado/gen_ps7_init.tcl
    # writes build/ps7/ps7_init.tcl

From step two on, a bitstream of the board that step is about must exist too:

    PROVE=1 OUTDIR=build/prove-write vivado -mode batch -source boards/arty-z7-20/vivado/bitstream.tcl
    PROVE=2 OUTDIR=build/prove-read  vivado -mode batch -source boards/arty-z7-20/vivado/bitstream.tcl
    DDR=1   OUTDIR=build/ddr         vivado -mode batch -source boards/arty-z7-20/vivado/bitstream.tcl

**Step two's board and step three's are two different bitstreams with the same
file name**, one directory apart. Pointing step three at step two's bitstream
produces every symptom of a fabric that cannot read, on a perfectly good board.
The script recognizes that reading and says so rather than blaming the design.

### Run every invocation under `timeout`

Xilinx's `mask_poll` waits for DDR-init-complete at `0xF8006054`. It gives up
after a hundred million reads. Over JTAG that is not a bound anybody will wait
for, and the routine is not ours to change. **A controller that never comes up
therefore hangs rather than failing.**

    timeout 600 ~/Xilinx/2026.1/Vivado/bin/xsdb boards/arty-z7-20/vivado/ddr_check.tcl

Exit 124 means the poll never finished. That is its own finding and not a
crash.

### The two identity registers, before anything is initialized

`0xF8000530` is SLCR `PSS_IDCODE`, the part's identity. It reads
`0x23727093`, the same word as the JTAG IDCODE above, off a different register
on a different path. The low 28 bits of it are what is asserted. `0xF8007080`
is devcfg `MCTRL`. Its bits 31:28 are `PCAP_PS_VERSION`, which is what
`ps7_init`'s `ps_version` reads. **They answer two different questions, and the
first guard written here confused them.** It asserted the IDCODE against
`MCTRL` and stopped a good part that read `0x30800100`.

Both are asserted, and identity is asserted first, because `ps_version`
defaults **silently**. It dispatches with 3.0 as the `else` branch, so a failed
or garbage read selects the 3.0 tables without saying so. A live `PSS_IDCODE`
is what says the version nibble came off a live PS at all. This board is
silicon 3.1, `PS_VERSION = 3`, per `zynq_fsbl`'s `fsbl.h`. Silicon 3.1 shares
3.0's tables, so it reaches that `else` branch **on purpose**.

    DDR: SLCR PSS_IDCODE at 0xF8000530 reads 0x23727093
    DDR:   device identity              0x03727093  wanted 0x03727093 (XC7Z020)
    DDR: devcfg MCTRL at 0xF8007080 reads 0x30800100
    DDR:   PCAP_PS_VERSION 31:28        3

### Uninitialized DDR is not zero, so everything poisons first

The first bring-up read one word per megabyte across the whole 512 MB, before
anything had ever been written to it. It found bands of all-zeros and all-ones,
eleven or ten megabytes wide, repeating with a 64 MB period, with a handful of
lone flipped bits inside them. The cause is true and complement cells laid out
by row. **So an unwritten word reads `0x00000000` in some places and
`0xFFFFFFFF` in others.** Anything that takes either as evidence a write
happened is testing nothing.

Every step therefore fills the region it is about before the fabric can touch
it, and each checks the fill took before going on. Steps two and three use the
proving word's own complement `0x75A3C91E`. Step four uses 1,024 words
injective in the address, **with bit 0 clear in every one**. The reason is that
bit 0 of what an unanswered read leaves in MD is what the boot PROM's disk poll
takes for "the controller is ready".

Only the first run after a power cycle sees the bands. Nothing clears DDR
between runs. Written words survive a second full `ps7_init`, DDR retraining
included.

### The order, which is not the same for both kinds of board

`ps7_post_config` is the thing that brings `S_AXI_HP0` up. It writes
`LVL_SHFTR_EN` at `0xF8000900` and clears `FPGA_RST_CTRL` at `0xF8000240`.
**`SAXIHP0ARESETN` follows the level shifters and not `FPGA_RST_CTRL`.** That
was measured at `700b98a` with the port live and a block poisoned. Toggling
`FPGA_RST_CTRL` produced no write. Writing `LVL_SHFTR_EN` `0x0` then `0xF`
produced the word.

**SLCR keeps `LVL_SHFTR_EN` across `ps7_init` and across a bitstream
download.** That one fact is a hazard for one kind of board and the mechanism
for the other.

The witness boards, `PROVE=1` and `PROVE=2`, are held in reset until the port
answers. So the port must be **dead** until the observer has laid its block
out:

    ps7_init -> clear LVL_SHFTR_EN -> program -> poison -> ps7_post_config
             -> read

Without the clear, a second run inside one power-on finds `LVL_SHFTR_EN`
already `0xF`. The witness then fires the instant the part configures, before
the poison lands. The block reads thirty-two words of filler, which looks
exactly like a fabric that cannot write. It cost one run at `700b98a`.

The machine, `DDR=1`, has no such trigger. `boards/arty-z7-20/cadr_arty.sv`
resets it on the MMCM's lock or BTN1. It therefore starts the instant the part
configures, and reaches its memory cycles 118 ms of machine time later ---
about the same in real time, because the boot PROM runs at extra slow and the
10 ns grid keeps that microcycle at MIT's 220 ns --- whether or not anybody has
brought the port up. Poisoning 256 words over JTAG takes longer than either.
So the port must be **live before the bitstream loads**:

    ps7_init -> clear LVL_SHFTR_EN -> poison -> ps7_post_config -> program
             -> wait -> read

That order works only because of the same SLCR fact.
`boards/arty-z7-20/vivado/ddr_run.tcl` reads `0xF8000900` again after
programming and stops if it is not `0x0000000F`. It was measured on four runs
at `1709d60`. No RTL change was needed for the start problem.

**And the toggle re-arms a witness without reprogramming.** Writing
`LVL_SHFTR_EN` `0x0` then `0xF` is `SAXIHP0ARESETN`, so a `PROVE` board runs
its whole sequence again. That is how step three does three cases in one
session on one download.

### Step one --- the controller starts, and DDR answers

    timeout 600 ~/Xilinx/2026.1/Vivado/bin/xsdb boards/arty-z7-20/vivado/ddr_check.tcl

This step takes no bitstream and **no `ps7_post_config`**. It is the processor
side alone, and the point is that it depends on nothing this project built.
What says it worked is a read-back, because `ps7_init` **prints nothing**. Its
version lines are commented out in Xilinx's own output. Its return therefore
says only that no Tcl error was raised, and "no error" is not "DDR is up". That
is the same shape as the DONE bit above.

The script records uninitialized DDR and re-reads one block to see whether it
is stable. That reading is recorded and not asserted, because there is nothing
to assert. It then writes the proving word `0x8A5C36E1` at `0x18A72EE4`, and
its complement over it, with the low half of that beat asserted untouched. It
walks a one across every address bit of the 128 MB region, with everything
written before anything is read. It writes the top of the 512 MB last, so the
whole part is known to have enumerated.

    DDR: PASSED --- the memory controller is up and DDR answers at 0x18000000
    DDR:   through 0x1FFFFFFF, with no bitstream and no
    DDR:   ps7_post_config.

It passed twice at `398edfc`, and that is recorded in `700b98a`. A mismatch
names the address:

    DDR: FAILED at 0x18A72EE4 --- wrote the word
    DDR: FAILED   wanted 0x8A5C36E1, read 0x00000000

### Step two --- the fabric writes, the debugger reads it back

    BIT=build/prove-write/cadr_arty.bit \
        timeout 900 ~/Xilinx/2026.1/Vivado/bin/xsdb boards/arty-z7-20/vivado/prove_write.tcl

`PROVE=1` puts `0x8A5C36E1` at `0x18A72EE4` through the machine's own memory
port, as soon as `SAXIHP0ARESETN` says the port can answer, and then stops.
That port is the same `cadr_axi_master` -> `cadr_axi_widen` -> `cadr_ps7` chain
the machine will use. Nothing in the design says whether the word arrived. What
says so is the script. It reads DDR through the processing system's own path,
which shares nothing with the fabric's.

**Pass is two things, and the second is the one that can fail.** `0x18A72EE4`
holds the word. Every other word of the thirty-two still holds the filler, and
`0x18A72EE0` above all, which is the low half of the same 64-bit beat. The
address has bit 2 set for exactly that reason. Against a neighborhood of
zeros, a widening that opened both halves would be invisible.

    PROVE: PASSED --- the fabric wrote 0x8A5C36E1 to 0x18A72EE4
    PROVE:   through S_AXI_HP0, and every other word in the block, 0x18A72EE0
    PROVE:   included, still holds the filler.  The low half of the beat is
    PROVE:   untouched, so the strobes opened one half and not two.

It passed three times at `700b98a`, and that is recorded in `51bc74a`. Two
failures are worth knowing before they happen:

- **thirty-two words of filler and nothing else.** Either the port was already
  live when the part configured and the witness fired before the poison landed,
  or `ps7_post_config` never ran. The clear of `LVL_SHFTR_EN` above is what
  prevents the first.
- **`0x18A72EE0` among the differing words.** The write opened both halves of
  the beat. The script says so and names `cadr_axi_widen.sv`'s strobes.

LD4 carries the witness's own verdict on a `PROVE` board, and only there. On
the machine board it is the machine's own error halt and carries nothing else.
It blinks red for a
port still dead, shows steady red for a live port with nothing completed, green
for completed and right, and blue for completed and wrong. Nothing in either
script can read a lamp. The read-back is the honest observer anyway, because a
lamp is the design marking its own work.

### Step three --- the fabric reads, and echoes what it read

    BIT=build/prove-read/cadr_arty.bit \
        timeout 900 ~/Xilinx/2026.1/Vivado/bin/xsdb boards/arty-z7-20/vivado/prove_read.tcl

This step runs three cases, in one session and one download, with **no
button**. The fabric reads `0x18A72EE4` and writes what it read, raw, to
`0x18A72F18`. That address is seven beats away with bit 2 clear, so the read
takes a high half and the write-back opens a low one. It echoes a raw word and
not a match bit. A match bit would be the fabric comparing against a constant
the fabric itself holds, and a wrong lane and a wrong constant agree with each
other. A lane swap, a shift or a byte reversal is visible **in the value**.

The negatives come first and the order is not optional:

    wrong   0x8A5C36E0 put at 0x18A72EE4, the word with bit 0 cleared.
            0x8A5C36E0 must come back; 0x8A5C36E1 would mean the fabric
            echoes a constant it holds and not what the memory gave it.
    half    0x8A5C36E1 put at 0x18A72EE0, the LOW half of the beat, with the
            filler left at 0x18A72EE4.  The FILLER must come back, which is
            what says the widening takes the half the address asks for.
    right   0x8A5C36E1 at 0x18A72EE4.  The word must come back, and it means
            something only after the other two have come back wrong in their
            own two ways.

The echo beat gets a third filler of its own, `0x3C7A91D6`. Without it, the
`half` case's echo of `0x75A3C91E` would be indistinguishable from no
write-back at all. `0x18A72F1C`, the other half of the echo's beat, must still
hold that third filler afterwards.

    PROVE: case wrong PASSED
    PROVE: case half PASSED
    PROVE: case right PASSED
    PROVE: PASSED --- all three cases, in one session and one bitstream download.

It passed four times at `51bc74a`, and that is recorded in `d2bbba5`. One
failure is worth checking before any other, because it is not a fault at all:

    PROVE: FAILED   AND THIS IS WHAT A `PROVE=1` BITSTREAM LOOKS LIKE, which
    PROVE: FAILED   would be the wrong file and not a fault: nothing came

A step-two bitstream never reads. It puts `0x8A5C36E1` at `0x18A72EE4` when the
port comes live. Check `BIT=`.

### Step four --- the machine runs out of real DDR3

    BIT=build/ddr/cadr_arty.bit \
        timeout 900 ~/Xilinx/2026.1/Vivado/bin/xsdb boards/arty-z7-20/vivado/ddr_run.tcl

`DDR=1` puts the processing system behind the machine's own memory port. The
boot PROM's whole main-memory traffic is `PAGE-0-PARITY-FIX`. It reads each of
the 256 words of physical page 0 and writes the same word straight back. That
is 512 bus cycles, between 118.0 and 118.4 ms of machine time after reset, and
the PROM never touches memory again.

**An identity copy leaves nothing behind.** Page 0 reading back unchanged says
the path did no harm. It cannot say the path was used, because a board whose
port is dead times all 512 cycles out and leaves page 0 exactly as unchanged.
No lamp can answer it either, as the section below says. And the processing
system ships nothing that could stand in. All 114 of its DDR controller's
registers were enumerated and none counts accesses, and Xilinx's own
performance tooling instantiates a counter IP in the fabric for exactly this
reason.

**So the fabric counts, at the processing system's own handshakes.**
`rtl/plumbing/cadr_mem_count.sv` keeps four fifteen-bit saturating counters.
Two of them count what the machine *asked* the port for, split by direction.
Two count what the processing system *answered*, which is `BVALID`/`BREADY` for
a write and the last `RVALID`/`RREADY` beat for a read. A fabric that never
issued a transaction cannot fabricate a B or an R beat. That is what makes the
answered pair a witness rather than the design marking its own work. The asked
pair is what makes a zero readable, since `256 asked, 0 answered` is a dead
port while `0 asked` is a machine that never reached its memory.

They come out on EMIO GPIO and the debugger reads them at two registers:

    0xE000A068  DATA_2_RO  EMIO 31:0    bits 14:0  answered reads
                                        bit  15    1
                                        bits 30:16 answered writes
                                        bit  31    0
    0xE000A06C  DATA_3_RO  EMIO 63:32   the same, asked reads and writes

Nothing has to be configured to read them. Both report the pin whatever the
direction registers say, `DIRM` comes up input, and `ps7_init` has already
turned the GPIO clock on. That is bit 22 of the `0x01DC044D` it writes to
`APER_CLK_CTRL` at `0xF800012C`. On a passing run both read `0x01008100`, which
is 256 in each fifteen-bit field with the marker bit set.

**The marker bits are why the fields are fifteen bits and not sixteen.** They
were put there because of what the negative control measured. Run against a
`DDR=0` bitstream, which is a board with no tally in it at all, both registers
read `0xFFFFFFFF`. With the level shifters on and nothing in the fabric driving
the EMIO pins, the processing system reads them all high. With the shifters off
it reads all zeros. **An absent instrument reads exactly like four saturated
counters**, and the failure would have been reported as "the machine asked
65,535 times". `(w & 0x80008000) == 0x00008000` is a pattern neither reading
can produce, so the register says who wrote it.

The script reads the tally cold, before anything is configured, where both
registers must read `0x00000000`. It reads them again after the run:

    RUN: the tally, first read:
    RUN:   DATA_2_RO 0xE000A068 0x01008100   answered 256 reads, 256 writes
    RUN:   DATA_3_RO 0xE000A06C 0x01008100   asked    256 reads, 256 writes

Pass is 256 of each of the four counters, page 0 and the 768 words above it
still holding their poison on two identical reads, and both AFI0 overflow bits
clear:

    RUN: PASSED --- the machine ran out of DDR.

It passed four times at `1709d60`. The script separates three failures, because
they are three different faults that would otherwise look alike:

    RUN: FAILED   ALL ONES IS WHAT NOTHING-DRIVING READS.  With the level

That means the bitstream has no tally in it. It is almost certainly a `DDR=0`
build.

    RUN: FAILED   NOTHING WAS ASKED FOR, on a word the fabric did write:

That means the tally is there and the machine never reached its memory cycles.
Either it is not running, or it is not the machine the bitstream was meant to
hold. LD0 and LD2 say which.

    RUN: FAILED   THE MACHINE ASKED AND NOTHING ANSWERED.  Every one of

That means every cycle ended on the NXM timer. The cause is a dead
`S_AXI_HP0`: the level shifters, the port's reset, or the adapter held in it.
It is not a machine that failed to run.

### When the DAP wedges

This was seen once, mid-`ps7_post_config`, and has not been reproduced:

    Memory read error at 0xF8000240. AP transaction timeout
    DAP (AHB AP transaction error, DAP status 0x30000021)

After that there is no APU target at all. `rst -por` is not supported for that
target. **`rst -srst` recovered it.** None of the four scripts tries to recover
on its own, because a script that reset the board on an error would be guessing
at which error it was.

## The buttons

The board has four push buttons and this design uses two of them.

    BTN0   boots the machine, as the light panel's button does
    BTN1   resets the whole fabric
    BTN2, BTN3   nothing

BTN0 is `-BOOT2`, the button MIT put on the CADR's light panel. Pressing it
restarts the machine from word 0 of its boot PROM. It does not clear main
memory, the control store, the scratchpads or the map, so it is a boot and not
a reset. Holding it down keeps the machine at the boot trap. Letting it go is
what starts the PROM running. The fabric debounces it for 4 ms. That is what
the Schmitt inverter on the light panel did with its own hysteresis.

BTN1 is the fabric's reset. It throws away the machine's whole state and every
register in the design. The fabric is also held in reset while the clock
generator has not locked, which is unchanged.

BTN0 and BTN1 are the same two buttons on every board in this repository. The
Cora Z7-07S has two buttons and no more, so the reset can only be BTN1 there,
and the boards with four follow it. The reset was BTN3 on this board for a
while, on the argument that the one control which throws the machine's state
away should be hard to press by accident. That argument lost to having the same
control be the same button everywhere.

**What the fabric reset is, and what it is not.** It resets the logic in the
fabric. That is the machine, the console's and the disk pack's register faces,
and the lamps. The processing system and Linux keep running across it, and it
does not reload the bitstream. So on a Zynq board the programs under Linux keep
the view of the register faces they had before, and after BTN1 the disk pack
program and the console are out of step with the fabric until they are
restarted. `rst -srst` over JTAG resets everything, and it is the reset to
reach for on a Zynq board. BTN1 exists for uniformity across the boards, and
for a part with no processing system and nothing else to reset it with.

Two other things press the same boot line. The first is the keyboard's boot
chord. Holding both Controls and both Metas with Rubout cold-boots the machine,
and with Return it warm-boots it. The keyboard sends one word for that, and the
I/O board decodes the word itself and pulses the line. The second is the
console. `cadr-console boot` presses the button from Linux or over the
network.

The pins are `D19` for BTN0 and `D20` for BTN1, `LVCMOS33`, from Digilent's
`Arty-Z7-20-Master.xdc`.

## The switches

The board has two slide switches and this design uses one of them.

    SW0   the no-auto-boot switch
    SW1   nothing

With SW0 off the machine comes out of reset running. It runs its boot PROM,
waits for a drive, and boots its band as soon as the disk pack program presents
one. That is what somebody switching a board on wants and it is what a card
does by default.

With SW0 on the machine comes out of reset with RUN clear. It has not run a
single microcycle and only the boot button starts it. That is what a CADR is
when the power comes on with nobody at it, and it is muir's `--no-auto-boot`.

**The switch is read at the fabric's reset and at no other instant.** Moving it
under a running machine does nothing until the next reset. Moving it back under
a held machine starts nothing. Only `-BOOT` takes the hold off, which is what a
button is for. A control that stopped the machine mid-instruction is not
something a CADR ever had.

The card's `fpgarc` has a `--no-auto-boot` flag that asks for the same thing.
The two are an OR. A flag can never turn the switch off, and the section below
has the whole of how the two work together.

The pin is `M20`, `LVCMOS33`, from Digilent's `Arty-Z7-20-Master.xdc`. SW1 is
`M19` and is brought out so that the design's port list matches the board.

## The Pmod headers

The board has two Pmod headers and this design uses one of them.

    JA   MIT's debug cable, both directions
    JB   nothing

MIT's cable joins one CADR's `DBGOUT` connector to another's `DBGIN`. Here the
whole of it is JA: four pins each way, of which two carry signals. The low four
are the debugger's and the high four the debuggee's, so a straight Pmod ribbon
from this board's JA to another board's connector maps every signal to its
counterpart. The pads are bidirectional, because the role is not fixed at
synthesis.

**The header's rows are coupled pairs, so each pair carries one signal.** Pins
1 and 2 are a pair, 3 and 4, 7 and 8, and 9 and 10. The strobe of a group is on
the first pair and its one data line on the second, and the other line of each
pair is a guard driven low beside it. A guard is driven and not left floating,
because a quiet line beside a switching one is only quiet if something holds
it. So the odd pin of each pair carries the signal and the even one is the
guard:

    pin 1   the debugger's strobe      pin 2   guard, driven low
    pin 3   the debugger's data line   pin 4   guard, driven low
    pin 7   the debuggee's strobe      pin 8   guard, driven low
    pin 9   the debuggee's data line   pin 10  guard, driven low

A group of four pads is driven whole or not at all, and a board listening to a
group drives no pin of it. One data line a direction makes a frame twenty-four
beats, 162 ticks, against the 1,105 the debugger's own interface allows a
cycle. `docs/debug-cable.md` has the reason and the budget.

**The far board's connector is JA too.** The Cora Z7-07S uses JA as this
board does. Every board indexes a header's eight signals in the same order, so
a straight ribbon maps each pin to its counterpart whichever headers the two
ends are. `docs/debug-cable.md` has the pins for both.

**A board is a debuggee with nothing set.** It answers a debugger that plugs
into JA exactly as MIT's board answers one on its DBGIN, and that is the
power-on state. `--debug-cable-connect` in the card's `fpgarc`, or
`cadr-console debug-cable-connect` at any time, asks for the other role.
`cadr-console debug-cable` says which role this board has.

**And which way round the ribbon was made is a setting, because one was made
the wrong way.** A Pmod header is two rows, pins 1 to 6 and 7 to 12, so a
ribbon whose connector was pressed on the other way up joins each board's pins
1 to 4 to the other's 7 to 10. Two boards were found on exactly such a cable on
14 September: the one told to connect drove four pins the far board never
listens to, and after the role was given back neither board could take it
again.

`--debug-cable-wiring auto|straight|crossover` in `fpgarc`, or `cadr-console
debug-cable-wiring` at any time, says which. `auto` is the default: the board
drives nothing while it listens on both pin groups, then assumes straight and
tries the other wiring in turn until something answers. Only a debugger applies
it. `cadr-console debug-cable` says which wiring the board found, and on the
far board it says when what is arriving is on the four pins that board answers
on --- which only a mirrored ribbon can do.

**The connector is in every bitstream this board builds**, memory on or off,
because a board is always a debuggee.

**A ribbon between two boards joins their supplies, and that has to be dealt
with before one is made.** A twelve-pin Pmod header carries ground on pins 5
and 11 and 3.3 V on 6 and 12. The grounds must be joined and the supplies must
not. A cable for this link joins pins 1 to 4, pins 7 to 10 and the grounds, and
leaves the supply pins open.

**And the pins of a Pmod row are coupled pairs, so no pair carries two
signals.** An edge on one line couples into the other, and the other could have
been the strobe. So each pair carries one signal with its partner held at zero,
which is the table above. A frame that catches a false edge moves nothing and
the next carries the levels again, so what a bad cable costs is lost frames and
never wrong values. The fabric counts frames heard and frames refused anyway,
and `cadr-console debug-cable` prints both: a guarded pair is an argument and a
count is a measurement.

**A cable exists and the link has come up over it.** Two boards were joined by
one on 14 September and the cable turned out to be mirrored, which is what the
wiring setting is for. On 15 September the fabric found the mirror by itself
and the two boards heard each other. A debug cycle has since crossed it in both
directions, which the section below on CC over the Pmod cable gives.
`docs/debug-cable.md` is the whole of the cable, and it has what the frame
counters said on those runs.

## What the LEDs say

The six lamps read left to right as the machine's own progress.

    LD0   MACHRUN            lit means the machine should be running
    LD1   the fabric clock   the slow blink, about 1.5 Hz at 100 MHz
    LD2   microcycles        the fast blink, and it freezes when the machine does
    LD3   disk activity      lit while the controller moves a block
    LD4   ERRHALT            dark normally, red once the machine halts itself
    LD5   PROMENABLE         blue while the machine runs out of its boot PROM

**LD1 and LD2 can hold a level instead of blinking**, with `--no-blinking-leds`
in `fpgarc` or `cadr-console blinking-leds off` at any time. The fabric comes up
blinking. What the two lamps say does not change, only how.

    LD1   the fabric clock   steady: lit while the clock generator is locked
    LD2   microcycles        steady: lit while the machine retires microcycles,
                             dark about 42 ms after it stops

**Each steady form still goes out when the thing it reports stops.** That is the
property a blink has by construction and a level has to be built for. LD1 is the
clock generator's lock rather than anything counted off the clock, because logic
clocked by a clock that has stopped cannot turn its own lamp off, and a clock
routed to a pad freezes at whatever level it stopped at. The lock drops when the
generator has no clock. LD2 is lit for 2^22 ticks after each retired microcycle,
about 42 ms. That is two thousand times the longest stall a running machine has,
so the lamp does not flicker, and short enough that a stopped machine reads as
stopped at once. It is the disk lamp's own persistence, so LD2 and LD3 go out at
the same pace.

The Cora Z7-07S has one lamp that takes the setting, LD1's green, with the
microcycle lamp's two forms. Red and blue do not change, and neither does the
order among the three.

The two lamps are `rtl/plumbing/cadr_lamp_clock.sv` and
`rtl/plumbing/cadr_lamp_microcycle.sv`, held by `build/blink_lamps.pass`. The
setting is the console's page 2 word 35, which `build/console.pass` holds. Which
nets the boards wire to the two modules stays lint-only.

**LD0 is a level and LD2 is a blink, and they say different things.** MACHRUN
is the machine's own run signal, the 9S42 at OLORD1 1A15. It drops during
every memory stall, `-WAIT` being one of its terms, so the lamp's brightness is
the fraction of time the machine computes rather than waits. A dim LD0 is a
machine that is thrashing. A level can be held high by a fabric that has
stopped, though. That is why LD2 carries the blink instead: motion cannot be
faked.

**LD4 is the machine's own error halt and nothing else. It is either off or
red.** No other color and no other meaning ever reaches it, at power-on,
during the PROM or while halted. Its green and blue channels are tied off.

ERRHALT is ERRSTOP and HALTED at OLORD1, and it is one of MACHRUN's own terms.
It means the machine executed a halt with the console's error-stop bit set and
stopped itself. On microcode 323 that is `(si:%halt)` reached through `ILLOP`,
`%HALT` and `ZERO`. MIT's own boards reach the same line from the memory parity
checkers, which this fabric does not have. Halting the machine from the console
is not it, because that clears RUN, so stopping the machine to look at it leaves
the lamp dark.

The lamp is sticky. It stays lit until the boot button is pressed or the fabric
is reset. Any boot clears it: BTN0, the keyboard's chord, or the debug cable.
Clearing ERRSTOP over the console does not, because what somebody at the board
saw should not be erased by a register write.

Dark being the good state is the point of it. It makes LD2's freeze readable:
LD2 stopped with LD4 dark means somebody halted the machine, and LD2 stopped
with LD4 red means it fell over.

**Three other things used to light it and no longer do.** They were a
non-existent-memory timeout, a block the disk's store could not supply, and the
statistics counter running out. None of the three belongs on this lamp. The
boot PROM makes two cycles to empty Xbus space on every boot, so a timeout lit
the lamp red on a machine that was perfectly well, and a lamp whose normal state
is red says nothing. A statistics halt is something the console asked for.

The disk's silent denial is a real defect and this was never the place for it.
When the block store cannot supply a block, the controller ends the transfer
with a clean status. The microcode believes it read a page that was never
written and nothing the CADR can read says otherwise. That belongs to
`rtl/machine/cadr_disk_controller.sv`, which should set a transfer error the
machine can see, and it is still open there.

The latch is `rtl/plumbing/cadr_lamp_errhalt.sv` and `build/errhalt_lamp.pass`
holds it. It is a module rather than four lines in the top level because the
top level is reached by lint alone, and lint cannot tell a lamp that latches
from one that does not. Which signal the board wires to it stays lint-only.

**LD5 is `PROMENABLE`, driven from the net itself.** It is lit blue while the
machine fetches its microinstructions out of the boot PROM and dark once it
runs the microcode it loaded from the disk. So a lit lamp means booting and a
dark one means booted. Blue is the only color it takes.

**It is the PROM's own select and not the mode register's bit.** MIT's
`-PROMENABLE` at PCTL 1C19 is `BOTTOM.1K` with `PROMDISABLED`, `IWRITEDA` and
`-IDEBUG`. It says whether the microinstruction being fetched comes out of the
PROM, so it follows the program counter. The visible consequence is that it
goes out on every control-store write while the PROM loads the store, and the
lamp therefore sits a little under full brightness during the load rather than
at full. Once `PROMDISABLE` is set it is dark for good.

The lamps are named for the machine's own signals: LD0 is `MACHRUN`, LD4 is
`ERRHALT`, LD5 is `PROMENABLE`. `build/promenable.pass` holds the net at the
machine's own port, because a board's top level is reached by lint and by
nothing else.

**The microcycle figures below were simulated at the 5 ns grid, and they are in
that machine's own time.** At that grid each of MIT's 5 ns steps took a 10 ns
tick on the board, so the machine ran at half the speed the hardware ran,
and a period given there as 0.14 s was 0.28 s at the board. At the 10 ns grid
the machine runs close to the hardware's speed. On 17 September the Arty Z7-20
retired 5.88 million microcycles a real second while running Lisp, so LD2's
blink, which toggles every 2^19 microcycles, had a period of 0.178 s. LD1
counts fabric ticks rather than microcycles, so its figure above is real time
on either grid.

Read the first three in order.

    LD1 dark                  not programmed, or the clock never locked
    LD1 blinking, LD2 dark    clocked, but not retiring microcycles
    LD1 and LD2 blinking      the machine is running

With the lamps steady the same three read the same way, with "lit" for
"blinking". A dark LD1 then says the clock generator has no lock. A blinking
LD1 whose clock stopped would instead have frozen, lit or dark.

**The assignment before this one was a bring-up instrument and is superseded.**
LD0 was the fabric's clock, LD2 counted non-existent-memory timeouts, LD3 was
the datapath fold, LD4 carried three boot states in three colors and then four
kinds of fault at once, and LD5 showed whether the last bus cycle was answered.
Each of those answers a question nobody asks of a working machine. What is worth keeping from the
measurements behind them is below.

**The timeout rate said nothing, measured.** LD2 used to light a bit of a count
of `timed_out` edges, on the argument that the level itself is a sliver too
faint to read. That much was true. What was not true was the prediction that a
working memory would put the lamp out. The boot PROM's only main-memory traffic
is 512 cycles, an identity copy of page 0. Its other 16,951 bus cycles are
polls of the disk controller. With 200 ms of machine time the run gives 852,515
microcycles and 514 timeouts without memory against 862,932 and 2 with. The
lamp read the same either way. Before the disk controller's registers existed
the polls timed out too, and the same run gave 590,925 and 13,783.

**The lamps are not how the memory path is checked, and they cannot be.** The
evidence is `boards/arty-z7-20/vivado/ddr_run.tcl`'s four counters, read by the
debugger at the processing system's own boundary, together with page 0 read
back against the poison put there. The probe cannot answer it either: it
captures microcycles 0 to DEPTH-1, and the first `mem_req` is at 536,303.

**There are two signals called `nxm` and they mean opposite kinds of thing.**
The decode's signal says the address is Xbus space with nothing built there.
The bus interface's own register, carried out as `timed_out`, says this cycle
ended on the timer rather than on a slave. The old LD5 was first wired to the
decode's signal and came up green on a board with no memory. The reason is that
the boot PROM's traffic goes to the disk registers at `0o17377774`. Those are
in the decode's map and are therefore not empty space. They are simply
unanswered. LD4 took `timed_out` for the same reason until the lamp was reserved
to ERRHALT, and those two cycles on every boot are part of why it no longer
does.

**No memory means slow progress, not no progress.** An earlier prediction here
was that with nothing answering `mem_*` the machine would reach its first
main-memory cycle and stall there for ever. The board said otherwise first. The
NXM timer in `cadr_busint_xbus.sv` expires at about 4.25 us and the cycle
completes as a non-existent-memory reference, and the machine keeps going. It
was simulated afterwards to put numbers on it, with `cadr_machine` and
`mem_done` tied low, which is the step-1 bitstream exactly.

    first mem_req            microcycle 536,303
    NXM timeouts             514 in 200 ms --- the parity loop's 512 plus
                             the two cycles to empty Xbus space
    after the first cycle    0.26 us a microcycle, against 0.22 normal
    LD2 (beat[19])           toggles every 0.14 s, machine time at the 5 ns grid

    (before the disk controller's registers answered the polls, the same run
     gave 13,783 timeouts, 1.49 us a microcycle and the blink every 0.79 s;
     the 16,951 polls each cost a 4.25 us timeout)

So the microcycle blink's period is a little over a quarter of a second. That
is close to the 0.23 s it would be at full speed, because the disk polls are
answered now and no longer each cost a timeout.

`tb/cadr_nomem_tb.cpp` printed that line as `beat[23]` until `bffbe9c`. The
lamp has been `beat[19]` since `ad4a475`, and both now agree. What the
testbench measures is the microcycle rate. Which bit of the count reaches the
pin is `rtl/plumbing/cadr_lamp_microcycle.sv`'s to say, as `BLINK_BIT`, and this
table takes it from there.

**The general point is worth more than the correction.** The prediction was
that no memory means no progress. The fabric's answer is that no memory means
slow progress. That is the first behavior anyone here observed on silicon that
was predicted wrongly, and it was predicted wrongly in this file.

## Holding the machine at boot

The CADR starts the instant the part configures. With SW0 off,
`boards/arty-z7-20/cadr_arty.sv` keeps RUN preset at reset, which is muir's own
default, so a board that is switched on runs its boot PROM, waits for a drive,
and boots its band as soon as the disk pack program presents one. That is what
somebody switching a board on wants and it is what a card does by default.

**A board that is being worked on can be held at the button instead. There are
two ways to ask for it and they are an OR.**

The first is SW0 on the board. The fabric holds the machine: it comes out of
reset with RUN clear and has never run a microcycle. Nothing in Linux has to do
anything, and there is no window in which the machine ran.

The second is `--no-auto-boot` in `fpgarc` at the root of the card. Nothing in the
fabric changes for it. `S80cadr-disk-packs` reads the flag and halts the machine
before it starts the disk pack program, so no drive ever comes present and
nothing of a band is loaded.

**A flag can never turn the switch off.** A board whose switch is on is held
whatever the card says, and the init step does not halt a machine that has
already been stopped by the fabric.

Either way a marker stands at `/var/run/cadr-held` and its one line names which
of the two did it. While it stands, `cadr-console` refuses `start` and `step`.
`cadr-console boot` presses `-BOOT2`, which presets RUN and starts the PROM from
zero, and removes the marker. BTN0 on the board presses the same line in the
fabric, so a held machine can be booted by hand with nobody logged in. The
fabric's own push-button reset is BTN1.

The console says one of

    cadr-boot: SW0: the machine came up with RUN clear and has never run
    cadr-boot: --no-auto-boot: the machine is held with RUN clear

and then

    cadr-boot: `cadr-console boot` or BTN0 on the board presses the boot button

`cadr-console switch` asks the fabric directly. It prints what the switch did at
the last reset and where the switch is now, and it exits 0 when the switch held
the machine. `cadr-console status` says the same in its own report, which
matters because a machine the switch held reads exactly like one somebody
halted: both have SRUN down.

This is muir's flag and it means the same thing there: leave the boot button
unpressed, as a CADR is when the power comes on with nobody at it.

**The PROM has already run when the FLAG is what holds it.** The bitstream is
loaded seconds before Linux reaches that init step, and within a few hundred
milliseconds the machine has cleared its control store and is waiting for a
drive. It can go no further on its own. So the halt lands on a machine that has
done its PROM work and is waiting, and the gap costs nothing. The switch has no
such gap, because the machine never ran at all.

`boards/arty-z7-20/linux/mksd-buildroot.sh` writes the line commented out, with
the sentence that explains it, and `NO_AUTO_BOOT=1` in `local.conf` makes it
live. `docs/fpgarc.md` is that file and every flag in it.

## The machine booted Lisp, 12 September

![The CADR's screen on the board: the window system, a Lisp Listener and the
who-line](images/first-lisp-boot.png)

That is the CADR's own screen, read off the board over the network. It shows
MIT's Lisp Machine system running on the fabric. There is the window system, a
Lisp Listener, the error handler with a live backtrace, and the who-line
reading `USER: Keyboard Cold-booted`.

The error on the screen is a Chaosnet host lookup that found no server. That
is expected on a board with no Chaosnet, and it is not a fault of the machine.

The screen holds 20,741 lit pixels of 739,584. muir produces the same figure
for the same band booted to the same place, so the two agree.

The machine ran past 2,425,000,000 microcycles with its error flag down. Before
this it halted at 169,107,829 microcycles with the flag up.

What fixed it was the bus interface's own Unibus registers. The interrupt
handler reads bit 1 of `0o766040`, which is a jumper that comes up set. Nothing
answered that address, so the bit read clear and the handler took a branch that
never reaches the code which clears an Xbus interrupt level. The machine lived
inside that handler until it fell over.

## The machine on the network, 13 September

The board was booted on the System 304 band, which `docs/cc-pack.md`
describes, with the Chaosnet program running beside it.

The machine reaches its Lisp Listener. Its herald names the associated machine
the band talks to, and the who-line carries a date. That date comes from the
network. The band asks the time host for it at cold boot, and
`(time:print-current-time)` answers with the same date and time. A host-up
query for that host answers `T`, which is a STATUS request going out and an
answer coming back. The Chaosnet program's own tally reads seven frames from
the machine and one to it, seven out and one in over UDP, with none malformed,
none refused and none with nowhere to go. The screen at the herald holds 18,079
lit pixels of 739,584.

The machine tracks the mouse itself, with nothing typed and no
`(si:setup-cpt)`. `MOUSE READY` in the input face's status register is clear at
rest. Over a forty-step walk of a viewer's pointer it was set in 26 of 80
samples and clear in the other 54. The System 100 band left it set in all 60
samples of the same measurement, because nothing there was reading it. MIT's
mouse tracking runs off the display's frame interrupt, and this band's cold
boot leaves that interrupt enabled. The arrow glyph is on the screen and
follows the viewer's pointer, and `tv:mouse-x` and `tv:mouse-y` follow it too.

A viewer's keys reach the Listener. `(+ 1 2)` typed over RFB evaluates to `3`,
and the `+` arrives as a `+` rather than an `=`. That shifted character is what
the pacing rule exists for, and `docs/terminal.md` states the rule: one key
word every 4,096 microcycles, which is muir's own interval. The terminal's
tally over the session reads 722 input events, 394 key words to the machine,
none held back for pacing or room, none lost in the fabric, 354 pointer moves
and no keysym that nothing maps.

At the 5 ns grid the machine's clocks ran at half real time, which is what the
fabric said they should. The who-line clock advanced 31 seconds over 61 real
seconds, a ratio of 0.508. The microsecond clock then counted 200 ticks
(`rtl/machine/cadr_io_board.sv`), and at a 10 ns tick that was one count every
2.0 real microseconds. The section of 17 September gives the 10 ns grid's
figures, where the microsecond clock keeps real time and the who-line runs at
1.015 of it, and 0.508 turns out to be that same 1.016 times a half.

Two things are not shown yet. The serial port's registers are programmed and
its rate reads back, but characters do not flow, because the line's frame end
is presented early in `rtl/plumbing/cadr_serial_line.sv`. And nothing has
driven the debug cable from the board. So the terminal and Chaosnet blocks are
shown on this board and the I/O board is not: it stays checked here and not yet
shown on silicon. Both of those were shown later the same day, and the section
below supersedes this paragraph.

## The serial line and the debugger, 13 September

Two fixes in the fabric had to land before any of this. The baud-rate divider
counted the board's real 100 MHz, where every other timed thing in the machine
counts MIT's 5 ns grid, so every frame came out half as long as the chip's own
(`rtl/plumbing/cadr_serial_line.sv`). And the transmitter's empty flag rose on
the drain that follows the transmitter being turned off, which let the wrong
interrupt channel take the character (`rtl/machine/cadr_io_board.sv`).
`docs/io-board.md` states the contract the two halves hold to.

### Characters out of the machine, and back into it

The CADR's serial line works on the board. Three bursts at 300 baud arrived
whole and in order, with nothing lost and nothing extra. They arrived at 15.0
characters a second. A 10-bit frame at 300 baud is 30 characters a second of
real time, and at the 5 ns grid the machine ran at half real time, so 15.0 was
the rate the fabric said it should be. At the 10 ns grid the same bursts arrive
at 29.9 characters a second, measured on 17 September.

Every rate the chip offers was swept at the 5 ns grid, with two bursts at each:

| baud | characters a second | at full real time |
|---|---|---|
| 300 | 15.0 | 30 |
| 600 | 30.1 | 60 |
| 1200 | 59.9 | 120 |
| 2400 | 118.6 | 240 |
| 4800 | 236.2 | 480 |
| 9600 | 353.6 | 960 |

Every burst was whole at every rate. Up to 4800 baud each gap between
characters is the frame time exactly. At 9600 the gaps alternate between the
frame time and twice it, so about a quarter of the characters wait one extra
frame and the rate comes out at 354 a second rather than 480. Nothing is lost
and nothing stalls. That is the machine's interrupt latency showing at the rate
where a frame is shortest, and it is a slowdown rather than a failure.

A hundred characters written in one go arrived whole and in order. Characters
written to the program's socket are read by the machine: five characters
written came back from the Lisp side as their five character codes. The machine
stayed healthy throughout, running at its normal rate after every burst.

The status register says the fix is in. At rest after a burst the command
register reads the transmitter off, and the status byte reads transmit-empty
clear. Before the fix the same reading was the transmitter still enabled with
transmit-empty set, which is what let the wrong interrupt channel absorb the
transmit-ready interrupt.

### The debugger over the cable

muir runs on the board's own Arm cores and reaches the fabric CADR through the
register window that `docs/debug-cable.md` describes. The window's identity word
reads `DBUG`. The debugger's own band boots from the card as this board's muir
station, and takes its date from the network with nobody typing.

MIT's own CC, running on the machine muir simulates, halted the fabric CADR and
read it back. Every reading below is octal, and each was compared with the
console reading the same halted machine.

| register | over the cable | the console |
|---|---|---|
| `PC` | `0o3055` | `0o3055` |
| `IR` | `0o600132400251640` | `0o600132400251640` |
| `STATUS` | `0o37000140307` | `0o37000140307` |

The instruction register is all 48 bits of it and the status word all 32.

CC read main memory through the mapped Unibus window, which is the path only a
master that is not the board itself can take. Four physical words were compared
against the console reading the same addresses straight out of DDR. Word `0o0`
is `0o31001440000`, word `0o3` is `0o33427234015`, word `0o4` is
`0o34204140020`, and word `0o10` is `0o33427231333`. Each pair is equal.

A write through the map has run as well, on 14 September, once `-UB TO MD`
was built in the fabric. It moved MD and spent no microcycle.
`(cadr:cc-write-md #o1234567)` left the console reading MD as `0o1234567`
with the cycle counter unchanged. CC's shifting writer, which clocks the
machine to move the word, moved MD and moved the counter by 96.

With the machine single-stepped, CC read the scratchpad memories, which it does
by forcing a microinstruction and clocking the machine once. Six words were
compared against the readout program's second read port. `amem[1]` and
`mmem[1]` are both `0o74`, `amem[2]` and `mmem[0]` are both zero, `amem[36]` is
`0o34012223407` and `mmem[12]` is `0o3202045742`. Each pair is equal.

Every microcycle is accounted for. The machine's cycle counter moved by 16 over
those reads: five for CC's full save of the machine, one debug clock for each
of the six scratchpad reads, and five for the pushdown buffer read. The
window's own request count and muir's count of the debug cycles it drove agree
exactly, and the watchdog never fired.

### What the board has not shown yet

Nobody has put a monitor on the board's HDMI connector. The display output
block is built and checked and a bitstream with it in has been made.
`docs/display-output.md` and the section below say what should appear.

Nobody has typed at a keyboard plugged into the board. The USB input program is
built and checked. `docs/usb-input.md` says how it is arranged, and the section
below says what has to be in place first.

Both have been shown since. A monitor on the HDMI connector shows the
machine's screen, and a keyboard and a mouse on the USB host reach Lisp.

### One fault still open

The machine can deadlock when a debugger halts it while a memory read is
outstanding. The clock ring parks on `-HANG`, which stops the master clock;
with no master clock the bus interface never grants the cycle, so the read is
never acknowledged and `-HANG` never lifts. The sources are
`rtl/machine/cadr_microcycle.sv`, `rtl/machine/cadr_phase_gen.sv` and
`rtl/machine/cadr_busint_xbus.sv`.

The signature is that every one of the sixteen diagnostic registers reads the
same constant, including the one that has no read select of its own, while the
cycle counter stands still and the tick counter goes on. Nothing outside a
reset breaks the loop, which is why run, step, the console and the cable all
have no effect on it.

What frees it is the debuggee's own reset, pulsed through the window as four
stores. The cycle counter starts moving again and the machine runs on. Linux is
not disturbed and the Lisp world survives, with its who-line ticking at the
correct time afterwards. `boards/arty-z7-20/cadr_arty.sv` is where that reset
joins the machine's own.

It is a race rather than a consequence: the same halt wedged about one entry in
three, with the cable in the same state after each. The exact race is not
established.

This fault has been found and fixed since. The acknowledgment's level, and
not its edge alone, now holds the countdown flags cleared, and forty console
halts and eleven debugger entries have run on the board without a deadlock.

## A keyboard at the board

The board has a USB host port and Linux drives it, so a keyboard plugged in
appears as `/dev/input/event*`. `cadr-usb-input` reads it and hands the keys to
`cadr-terminal`, which is the one program that writes the I/O board's keyboard
and mouse registers. `docs/usb-input.md` says why it is arranged that way.

What has to be there first. The bitstream must be one with the I/O board's
input cables in it: `cadr-terminal` says so at start-up, naming the registers
it found and the flush it wrote. And `cadr-terminal` must be running, because
it owns the socket. A board where either is missing gives one line a scan from
`cadr-usb-input` saying the link is not answering, and it recovers on its own
when the terminal starts.

The program is started at boot by `S88cadr-usb-input`, after the terminal's
`S85`. Nothing has to be passed to it: it looks in `/dev/input` for a keyboard
and a mouse, opens what it finds, and keeps looking every second, so a keyboard
plugged in later works and one unplugged and plugged in again works.

### Putting it on a board that is already running

The root filesystem is a RAM disk, so a program can be copied onto a running
board without the reset that serving a new image would need. That matters when
the machine is up and its state is worth keeping.

    scp -O cadr-usb-input root@<board>:/usr/bin/
    scp -O S88cadr-usb-input root@<board>:/etc/init.d/
    ssh root@<board> /etc/init.d/S88cadr-usb-input start

`-O` because dropbear has no sftp. The binary is built by Buildroot, or by the
cross toolchain directly:

    make -C boards/arty-z7-20/linux/buildroot/package/cadr-usb-input/src \
        CC=<buildroot>/host/bin/arm-linux-gcc COMMON=host

### What it should say, and what should happen

The console says which node is a keyboard and which is a mouse, with the name
the device reports, and then that it has attached to the link. Typing at the
keyboard then types at the machine: the characters appear at the Lisp Listener,
which can be watched over RFB from another machine at the same time.

Shift and a digit is the interesting one to try. The shift level is applied in
`cadr-usb-input` and the word that reaches the machine is the shifted position
with Shift still down, so `!` must arrive as `!`. A program that sent the
unshifted keysym would give `1`, and the machine would see the Shift key lifted
and put back around it.

### Proving it with nobody at the board

There is no way to press a key from another machine on this image, and it is
worth saying which of the obvious ways do not work.

`evtest` only reads. It prints every event a device delivers, which is how the
USB port was proved in the first place, and it cannot deliver one.

`uinput` would do it --- a program opens `/dev/uinput`, says which key codes its
virtual keyboard reports, and writes `input_event` structures, and
`cadr-usb-input` finds the device on its next scan and reads it like any other.
But `CONFIG_INPUT_UINPUT` is not in this board's kernel configuration, so
`/dev/uinput` is not there. Turning it on is one line in
`boards/arty-z7-20/linux/buildroot/board/arty-z7-20/linux/linux.config` and a
kernel build, which is a change to the image rather than a thing to do to a
board that is running.

What can be done from another machine is to feed the link directly, which
proves everything except the read of the device: a client connects to
`/var/run/cadr-input`, sends the greeting, and then sends key records.
`cadr/cadr_input_link.h` has the format. That is what the host check does, and
on the board it would show the terminal's half --- the mapping, the pacing and
the registers --- carrying a key to the machine.

So the first run with a finger on a real keyboard is still owed, and until it
happens the USB input block is checked here and not yet shown on silicon. That
run has happened since, and the section of 14 September has it.

## The display, the keyboard and the mouse, 14 September

**A monitor on the HDMI TX connector shows the machine's screen.** It is
1280x1024 at 60 Hz with the CADR's own 768x963 screen centered in it, white on
black, and the rest of the frame black. That is the display output block as it
was built then. That build centered the first display, where the block now puts
it at the raster's left edge and the color board at the right, which is what
`docs/display-output.md` describes. The picture comes out of DDR over
`S_AXI_HP3` with no software anywhere in the path, so the block and the port
are both shown by the same monitor.

**A USB keyboard plugged into the board reaches Lisp.** `cadr-usb-input` reads
the keyboard as an evdev device and hands each key to `cadr-terminal`, which is
the one program that writes the I/O board's keyboard register and which paces
the words onto it. The keys arrive in the machine as a person typing at a
viewer's keys do.

**A USB mouse reaches it too.** Its movement and its buttons go down the same
path. The arrow on the screen follows the hand and a click registers in the
machine.

So every block on this board's drawing has now been shown on the board itself.

## The switch, the boot button and the lamps, 14 September

**SW0 holds the machine at power-on.** With the switch on and the board reset,
the machine comes up with RUN clear and nothing running: LD0 is dark, LD5 is
blue and steady, LD2 does not blink, and the screen stays black. The console's
`switch` command says the switch held it. Pressing BTN0 starts the boot PROM,
LD5 goes dark once the microcode is loaded, and the machine boots to the
Listener. With the switch off the board boots by itself as before.

**LD4 is ERRHALT and clears at the boot button.** A normal boot leaves LD4
dark throughout. Typing `(si:%halt)` in the Listener turns it red, LD0 goes
dark and LD2 stops. Pressing BTN0 clears the lamp at the press and the machine
boots again.

**LD5 is PROMENABLE.** It is blue for under a second while the PROM loads the
microcode and dark from then on.

Each step above was taken one at a time at the board and behaved as written.

## CC over the Pmod cable

A ribbon joins the Arty Z7-20's Pmod JA connector to the Cora Z7-07S's. MIT's
own CC, running in the Lisp world of the CADR in one board's fabric, has halted
the CADR in the other board's fabric over that ribbon, read its registers and
its scratchpads, and started it again. It has been done both ways round. So a
CADR has debugged a CADR over a real cable, which is what MIT's debug cable is
for and what the register window stands in for when there is only one board.

`cadr-console debug-cable-connect` is what takes the debugger's role and
`cadr-console debug-cable-disconnect` gives it back. A board that has been told
nothing is a debuggee, which is what a CADR is with nothing set.

**The board found the ribbon's wiring itself.** The cable on the bench is
mirrored: its connector was pressed on the other way up, so each board's pins 1
to 4 land on the other board's 7 to 10. The board taking the role listened on
both groups and reported `crossover, detected`, and the far board reported a
debugger on the connector rather than a disagreement. Forced to `straight`,
which is the wrong setting for this ribbon, the debugger said nothing was
answering and the far board said the two ends disagreed about the cable. That
is the fault the detection exists to remove, and it was shown once on purpose.

**Neither machine noticed.** Both ran Lisp at their normal rate while the role
was taken, swapped and given back, and neither Lisp world lost its place.

Every reading below was compared with the far board's own console or readout
program at the same halt, and the two paths share nothing but the register
itself. The far machine was halted from its own console first, so that no
instruction had been forced and both ends look at the same instant. CC prints
octal and the console prints each register as the halves it reads it in, so a
row is one word written two ways. CC's status word is one word of 32 bits whose
halves are `FLAG-1` and `FLAG-2`, and the last two rows of each table are those
halves.

The Arty Z7-20 as the debugger, reading the Cora Z7-07S:

| word | over the cable | the Cora's console |
|---|---|---|
| `PC` | `0o1370` | `0o1370` |
| `IR` | `0o600626060011100` | `0x180c_b0c0_1240` |
| `OB` | `0o11200003116` | `0x4a00_064e` |
| `FLAG-1` | `0xf800` | `0xf800` |
| `FLAG-2` | `0xc0c7` | `0xc0c3` |

The Cora Z7-07S as the debugger, reading the Arty Z7-20:

| word | over the cable | the Arty's console |
|---|---|---|
| `PC` | `0o17700` | `0o17700` |
| `IR` | `0o600125000511640` | `0x1802_a802_93a0` |
| `OB` | `0o2202007153` | `0x1208_0e6b` |
| `FLAG-1` | `0xf800` | `0xf800` |
| `FLAG-2` | `0xc1d7` | `0xc1d7` |

All 48 bits of the instruction register and all 32 of the output bus are equal
in both directions.

**The one row that differs is CC's own correction.** `CC-READ-STATUS` inverts
bit 2 of the second flag word when bit `0o100` of `IR-LOW` is set, under MIT's
comment saying the hardware reads JC-TRUE incorrectly. In the first direction
that bit is set and CC prints `0xc0c3` exclusive-ored with 4, which is
`0xc0c7`. In the second it is clear, the correction does not apply, and the two
readers agree exactly. The second direction is therefore the control for the
first.

The scratchpads were read at each direction's own halt, and each figure is two
readings that were equal: CC's over the cable, and the far board's readout
program on the same word.

| word | the Cora, read by the Arty's CC | the Arty, read by the Cora's CC |
|---|---|---|
| `amem[1]` | `0o56` | `0o72` |
| `amem[7]` | `0o1240005413` | `0o2` |
| `mmem[1]` | `0o56` | `0o72` |
| `mmem[7]` | `0o1240005413` | `0o2` |

Every microcycle is accounted for. A scratchpad read is one forced
microinstruction, and the far machine's cycle counter moved by exactly one for
each: five for five reads one way and four for four the other. CC's own
program counter is what the console reads after the entry, less five, which is
the five instructions `CC-FULL-SAVE` forces on the way in.

**None of it went through a register window.** The Cora Z7-07S's window, read
while it was the debuggee, reported no requests and no faults at all, so the
ribbon carried the halt, the reads and the start.

**Loading CC takes a recipe on these bands**, because the file host serving
`SYS:` carries CC's sources and no compiled files, so `make-system` fails and
CC has to be loaded from source and interpreted. `docs/debug-cable.md` has the
two forms it needs and the list of files. That load took an hour and a half the
first time and seventeen minutes the second, and what it loads is lost when
that machine is rebooted.

**One start did not take, once.** A call that starts the far machine answered
as it does when it works, the machine's own program counter moved, and the
machine stayed halted until a second call started it. It was not reproduced:
the same sequence taken again started the machine on the first call. The one
difference in the failing case is that reads had been made before CC had done
a full save, and no mechanism is claimed.

**What the cable has not shown.** Nothing has been written to the far machine
over it: what has run is the halt, the reads and the start. Nothing has been
measured about its timing either. The frames-heard counter saturates within a
tenth of a second of a connect and only a fabric reset clears it, so what the
console's two counters give is a trajectory rather than a rate.

## The cable with one signal to a pair, 15 September

The carrier on the ribbon was rebuilt so that each signal has a pair of the
header's pins to itself, with the other pin of the pair driven low as a guard.
Both boards were served that fabric and the ribbon between them was not
touched. `docs/debug-cable.md` says why the pairs matter and what the guards
cost.

**The refused frames are gone.** As the debugger the Arty Z7-20 read 0 refused
against a saturated 65,535 heard on every one of twenty-four readings, taken
ten seconds apart over four minutes and forty-eight seconds, and on the first
reading after the connect as well. With the earlier carrier the same board in
the same role refused 163 frames on one connect and 185 on the other, in
bursts, with the counter at its ceiling within 300 milliseconds. The Cora
Z7-07S refused none as the debugger over two minutes, as it had before.

**Two frames on the Cora Z7-07S are not accounted for.** It ended the session
at 2 refused against a saturated 65,535 heard. Five disconnect and reconnect
cycles added none, a repeat of the forced `straight` control added none, and
5,020 debug cycles added none, so the two arrived at moments nobody caught.
`docs/debug-cable.md` names the two candidates. Neither is a measurement and no
cause is claimed.

**Two resting boards now drive nothing.** Both consoles read a debuggee with
nothing on the connector. On the earlier carrier each board on this same
mirrored ribbon heard the other's idle frames, called them a debugger's, and
could not take the role until it was reset.

**The wiring was found again, both ways round.** Each board took the role in
turn and read `crossover, detected`, while the far board reported a debugger on
the connector. Forced to `straight`, the debugger read that nothing was
answering and the far board read that what is on the connector arrives on the
four pins it answers on. Set back to `auto` after the role had been given back,
the detection found the crossover again.

**A debug cycle crossed without CC.** A Unibus read of `0o766104` from the
debugger board's own Listener is the `-DB READ STATUS` strobe, and
`(si:%unibus-read #o766104)` read `0o177400` while connected and `0o177777`
while disconnected, on each board in turn. The first is what a far end that
answers gives and the second is the debugger's own timeout, which is what an
unplugged connector reads as. Sixteen reads in one form gave `0o177400`
thirteen times and `0o177500` three, and the bit that moves is the far bus
interface's own busy, so the byte is the far machine's work rather than a
pull-up. No register of the far machine was read over this carrier, and CC has
not been run on it.

**A board says which build it carries.** The USERCODE register read over JTAG
gave the previous bitstream's stamp on both parts before they were served and
the new one afterwards. The fabric is configured by the loader through the
processing system rather than over JTAG, so this is the reading that says a
board which has been running for hours still names the build in it.

## The build stamp, the sync program and a checkpoint, 15 September

Both Zynq boards were served the set built at commit `261547d` and left
running on it. The measurements below were taken on the two boards over half
an hour.

**A board says which build it carries, and four readers of that one value
agree.** The last line of `cadr-console status` reads the same on both boards:

    fabric: build 261547d0 --- commit 261547d, tree clean

That figure is read out of the configuration logic by the fabric itself, so it
is the bitstream in the part naming itself from inside. `cadr-console
--version` prints `cadr-console 0-261547d-release` on both boards, which is the
same commit arriving by another route: Vivado stamped the one and Buildroot
stamped the other, and the two toolchains share nothing but the commit. The
USERCODE register read over JTAG moved from `782e3a90` to `261547d0` on both
parts. The loader's own reading of the bitstream header at boot says
`UserID=261547D0`. So four readers now name one value and all four agree.
Neither board could say any of this on the set before it, where `cadr-console
--version` was an unrecognized option and `status` ended at the `FLAG-1` line
with no fabric line at all.

**The display's sync program runs on silicon, and nothing about the machine's
timekeeping moved.** The vertical flag and the sync bits now come from the
program the display block runs rather than from a fixed frame boundary. Both
boards boot to a Lisp Listener with a dated who-line. The who-line's rate was
read off the screen twice on each board, 137.9 real seconds apart with nothing
touching either machine: 0.5077 of real time on the Arty Z7-20 and 0.5150 on
the Cora Z7-07S. The who-line ticks once a machine second, so a reading of that
length resolves to about seven parts in a thousand, and both figures are the
rate of 0.508 this file measured above at the 5 ns grid, within that
resolution.

The rate was measured a second way, off the fabric's own tick counter, which
touches neither the screen nor the network. Two readings 118.3 real seconds
apart give 99.9989 MHz on the Arty Z7-20 and 99.9934 MHz on the Cora Z7-07S,
against the 100 MHz a 10 ns tick is by design. At the 5 ns grid the CADR's
microsecond clock counted one per 200 ticks, so those were 0.499994 and
0.499967 of real time. The
two methods agree, and the second one does not depend on the screen, the
network or anything outside the board.

**The mouse tracks on both boards, which is the vertical interrupt's own
witness.** MIT's `TRACK-MOUSE` runs from `60CYC-1` out of `INTRX0`, which tests
the vertical flag the sync program now presets, so a pointer that follows the
hand says the interrupt is arriving from the program. On each board
`tv:mouse-x` and `tv:mouse-y` moved in the direction the pointer moved and
saturated at the screen's own limits, and the arrow glyph followed. `MOUSE
READY` in the input face's status register is clear at rest on both, so the
machine is reading the card. The screens hold 18,170 lit pixels of 739,584 on
the Arty Z7-20 and 18,033 on the Cora Z7-07S, which is a System 304 Listener.

**A checkpoint written on the board was opened by the muir in the same image on
the same board.** The Arty Z7-20's machine was halted from its console with the
disk idle, and `cadr-checkpoint` wrote a format 25 file in 16.4 seconds: 32
memory boards, 3,084,509,683 microcycles retired, PC `0o313`, and 8,694,566
bytes of body packed, read out over the console's window in 74,052 reads and
24,669 writes. Its sidecar binds the one pack by name, geometry and SHA-256,
and `cadr-checkpoint --verify` said the binding holds.

The pack was copied before the resume, so that muir could not write the pack
the running CADR reads, and the live pack's digest was unchanged afterwards.
muir in this image is the pinned commit, and its own line reads:

    resumed: 20260915-143001.chk at 3084509683 microcycles,
    648946286205 ns, 32 memory boards

It then ran 30,000,000 microcycles in 88.428 seconds and stopped at PC `0o313`.
The resumed screen, read over muir's own RFB port, is the board's own Lisp
world: it carries the three forms typed at the board minutes earlier with their
answers. Nothing else could have put those lines inside muir.

**Lisp resumed after the halt.** `cadr-console start` put the machine back at
6,592 microcycles per 2,000 microseconds, and the who-line went on advancing.
The machine had been halted for 7 minutes and 26 seconds and its Lisp world
did not lose its place.

**The who-line advances through a halt, which looks like a jump and is not
one.** Across that halt the who-line gained about three minutes and forty-seven
seconds more than the running time accounts for, and three minutes and
forty-three seconds is the halt itself at the 5 ns grid's half rate. The
microsecond clock is in fabric and counts ticks, so it free-runs while
`MACHRUN` is down. A machine restarted after a halt therefore reads a clock
that never stopped.

**The cable held at zero refused frames a second time.** Each board took the
debugger's role in turn over the same mirrored ribbon, found the wiring, and
read 0 refused against a saturated 65,535 heard on every reading over a minute.
Both machines ran Lisp throughout. The section above has the first session on
this carrier and the counts it replaced.

**One defect was found, and it is in the checkpoint program's reading of a
flag.** `cadr-checkpoint --chaos-address` reads its number in decimal, where
muir reads the same flag in octal. So `--chaos-address 177100` writes
`0o131714` into the checkpoint, and muir refuses to resume the file, naming
both addresses:

    checkpoint: the Chaosnet interface's switches read 131714, this
    machine's 177100

The refusal is the guard working as it should, on a value that should never
have been written. The spelling that works today is `cadr-checkpoint
--chaos-address 0177100`, and with it the two programs agreed and the resume
ran. The behavior predates this set, and a fix is in hand.
The fix has landed since: `chk_chaos_address` in `cadr-checkpoint`'s
`chk_rtl.c` reads an address in octal as muir does, so `177100` is right as
written.

## The Chaosnet framing on the wire, 15 September

Both Zynq boards were served the root filesystem built at commit `1515934`,
which carries the CHUDP framing `docs/chaosnet.md` describes: every 16-bit
word most significant byte first, and the Internet checksum in the trailer.
The OZ host at `0o177002` speaks that framing, and every datagram between it
and the boards was captured on the peer's own machine. Forty-five datagrams
were captured, none dropped by the kernel, and each was decoded from its
literal bytes. So this is the framing measured against another implementation
rather than against itself.

**The bytes match the specification in every field.** The first datagram the
Cora Z7-07S sent is its cold boot asking the OZ host for the time. It is
thirty bytes:

    01 01 00 00 01 00 00 04 fe 02 00 00 fe 42 18 0b 00 00 00 00
    49 54 45 4d fe 02 fe 42 5f c3

The first four bytes are CHUDP's own header: version 1, function 1, and two
argument bytes sent as zero. Eight header words follow, each most significant
byte first. Word 0 is `0x0100`, an opcode of 1, which is RFC. Word 1 is
`0x0004`, a forwarding count of 0 and a data byte count of 4. Words 2 and 3
are the destination, `0xfe02` = `0o177002`, at index 0, and words 4 and 5 are
the source, `0xfe42` = `0o177102`, at index `0o14013`. Words 6 and 7 are the
packet number and the acknowledgment, both 0. The four data bytes are `49 54
45 4d`, which are the words `0x4954` and `0x454d`. Unpacked as AIM-628 section
3.6 says, with the first byte of each pair in the word's low half, they read
`TIME`; read straight off the wire they read `ITEM`, which is the pair swap
the framing requires. The trailer is the destination `0o177002`, the source
`0o177102` and the check word `0x5fc3`. The Internet checksum over the twelve
covered words is `0x5fc3`, and every word of the datagram including the
checksum sums to `0xffff`.

**The OZ host answered that request 65 microseconds later.** Its answer is
thirty bytes as well: opcode 5, which is ANS, four data bytes carrying the
time, addressed to `0o177102` at the index the request asked from, from
`0o177002`, with the check word `0x1322`, which verifies the same way.

**Six exchanges, three from each board, and every check word was good in both
directions.** Each board asked for the time at its cold boot and made two
status requests afterwards. Every one of the six was answered, so nothing was
retransmitted, and the answers came back between 65 and 710 microseconds. All
twelve datagrams sum to `0xffff`.

**The peer's own meters read off the wire are the meters the machine prints.**
A status answer is 94 bytes, of which 68 are data: the host's name, then for
each subnet a word of `0400` plus the subnet number, a word saying how many
counter words follow, and the counters. The name comes out with each pair of
bytes swapped, in the same way `STATUS` goes out as `TSTASU`. In the last
answer of the session, word 16 is `0x01fe`, which is `0400` plus subnet
`0o376`, and word 17 is 16. The eight counters unpacked out of those bytes are
the eight the machine printed:

| meter | out of the datagram | on the machine's screen |
|---|---|---|
| datagrams in | 42 | 42 |
| datagrams out | 10 | 10 |
| abort | 0 | 0 |
| lost | 0 | 0 |
| crc | 0 | 0 |
| ram | 0 | 0 |
| bad bit count | 28 | 28 |
| other discarded | 3 | 3 |

That datagram is the answer to a `chaos:hostat` form typed at a Lisp Listener
on the Arty Z7-20, so the two columns are one answer read twice: once by MIT's
own microcode and Lisp, and once by a decoder here reading the captured bytes.
The two paths share nothing but the datagram itself.

**The negative control is in the bytes too.** For part of the window the Arty
Z7-20 was still on the previous image and sent the previous framing, which
wrote the packet's own words least significant byte first and carried the
CADR's CRC-16 in the trailer. One of those datagrams is 32 bytes and is well
formed under the old rule: an RFC of six data bytes reading `STATUS`, from
`0o177100` to `0o177002`, with the check word `0x00f3`, which is the CADR's
CRC and not the Internet checksum, that being `0x3c78` over the same words.
Read as the specification requires, the same bytes are nonsense. Word 0 is
`0x0001`, an opcode of 0, which is no Chaosnet opcode. Word 1 is `0x0600`, a
data byte count of 1,536 in a datagram of 32 bytes. The addresses come out
byte-swapped as `0o1376` and `0o40376`. So the refusal happens at the length
test and never reaches the checksum. The peer answered none of the twenty such
datagrams it was sent, and the meter it keeps for a refusal of that kind is
the bad bit count column above. That column stood at 28 and stopped moving
once both boards were on the new image: between two readings four minutes
apart it stayed at 28 and other discarded stayed at 3, while the datagrams in
went from 39 to 42 and the datagrams out from 7 to 10. Nothing in the meters
names a sender, so which datagrams make up the 28 is not established. What the
pair of readings says is that nothing either board sent afterwards was
refused.

**Where the two boards were left.** Both run the image built at `1515934` over
the fabric built at `261547d`, which is the image having moved while the
fabric did not. On each board `chaos:host-up-p` answers T for the OZ host, the
herald names it as the associated machine, `time:print-current-time` gives the
date and the time of day, and the who-line is dated. Both machines were
running Lisp throughout, at 6,556 and 6,767 microcycles per 2,000
microseconds. The program's own traffic line is the same on both:

    3 from the machine, 3 to it, 3 in and 3 out over UDP; 0 with nowhere to
    go, 0 malformed, 0 with a bad checksum, 0 refused because the machine had
    not emptied its buffer

## The second display board, fitted at run time, 15 September

Both Zynq boards were served the set built at commit `52b7b3a` and left
running on it. The measurements below were taken on the two boards over half
an hour. No card was written and nothing on either card was changed.

**The two halves name one build, and the part agrees.** On both boards
`cadr-console --version` prints `cadr-console 0-52b7b3a-release`, and the last
line of `cadr-console status` reads `fabric: build 52b7b3a0 --- commit
52b7b3a, tree clean`. The USERCODE register read over JTAG moved from
`261547d0` to `52b7b3a0` on `xc7z020_1` and on `xc7z007s_1` alike, and the
loader's own reading of the bitstream header at boot says `UserID=52B7B3A0`.
The section above says what those four readers are for; this is the second set
to pass that check.

**With nothing set, both boards say the machine has one display board.**
`cadr-console tv-board` prints the two lines below and exits 0, and
`cadr-console color-tv` prints the same two and exits 1:

    display: the first board is a SIMPLE TV
    display: no color TV --- those addresses give the NXM, which is how the
             band finds out

Neither card names `--tv-board` or `--color-tv`, so `S80cadr-disk-packs` skips
its display step at a boot and no `cadr-display:` line appears on either
console. That is what the color board being off by default looks like.

**MIT's own probe had to be made out of the band's primitives.** The System
304 band carries MIT's `COLOR` package --- `(pkg-find-package "COLOR" :find)`
answers with it --- but not the `COLOR` system's functions, and
`color:xbus-location-exists-p` is undefined. So `COLOR-EXISTS-P` is not run at
this band's cold boot, and the caution about a band walking into
`COLOR:SETUP`'s sync loops does not apply to this band as it stands, there
being nothing loaded to walk into. Whether a band with the `COLOR` system
loaded would walk into them is untouched by this session.

The four primitives the probe is built from are all there: `%xbus-write`,
`%xbus-read`, `%unibus-write` and `bit-test` each answer `T` to `fboundp`. So
the body of `COLOR-EXISTS-P`, `sys/window/color.lisp` lines 95 to 104, was
typed at a Lisp Listener as one form and the probe made with it. It writes a
marker into the color buffer's first word, reads the word back with the error
stop off so that the NXM cannot halt the machine, restores the error stop, and
answers whether the marker came back. Every number was written explicitly in
octal, because MIT's file is `Base: 8` and the Listener is not.

**The probe answered NIL with no board fitted, T with one, and NIL again after
it was taken away.** `cadr-console color-tv on` fitted the board on the Arty
Z7-20 with the machine running:

    display: the first board is a SIMPLE TV
    display: a color TV is fitted, at 0o17200000 with its registers at
             0o17377750

Nothing on the card changed and no `fpgarc` line was uncommented. The probe
then answered `T`, where minutes earlier it had answered `NIL`, and
`cadr-console color-tv off` gave back the unfitted words and the probe
answered `NIL` once more. That is two witnesses meeting: the console's own
register face on one side and MIT's software doing a bus cycle at `0o17200000`
on the other, sharing nothing but the backplane. The machine kept running
across all of it, 6,643 microcycles per 2,000 microseconds before and 6,454
after, with ERR down each time.

**The color screen is served, and it is black because the map is.**
`cadr-terminal` was restarted by hand with `--color-terminal 0.0.0.0:5903`,
and it said what it had found: the color window is 128 KB at `0x1c020000`, the
screen is 576 by 454, 72 words a line, 32,688 of the window's 32,768 words,
four bits a pixel through sixteen colors. A viewer on 5903 sees a black 576 by
454 screen named `CADR color`, and that was measured as bytes rather than
inferred. All 261,504 pixels read back as zero in the server's default
true-color format.

The black is the map's doing and not the window's. Asked for a color-mapped
format instead, the same screen sends `SetColourMapEntries` with sixteen
entries all red 0, green 0, blue 0, and the pixel indices behind them are not
zero: sixteen distinct values, 260,533 of the 261,504 of them non-zero, the
commonest `0x0f`, `0x0e`, `0x07` and `0x0d`. That is unwritten memory in the
color window, which is what the plan allowed for. So nothing has drawn a
picture here --- the machine has written neither a map nor a pixel --- and
every index in that window maps to black.

**The map port reads sixteen zero entries for either board.** `cadr-console
color-map first` reads the first board's sixteen on a band that has never
written one, and `cadr-console color-map` with the color board fitted reads
the color board's sixteen. All thirty-two are red 0, green 0, blue 0.

**The Chaosnet's traffic line closes.** Every such line on both boards adds
up, which is what the new counters were added for: `arrived` equals `in` plus
the three refusals. The Arty Z7-20 read 1 datagram arrived against 1 in, 0
refused for their shape, 0 with a bad checksum and 0 not for this cable, and
later the same line with 2 in every place; the Cora Z7-07S read 1 in every
place. So the three refusal counts are at zero, and a link reporting nothing
in really did hear nothing.

**The packet trace can be turned on while the machine runs, and it writes one
line a datagram.** `cadr-console trace-chaos on` printed its whole sentence
and exited 0 on both boards, and the program then wrote a line for every
datagram into its own log. Traffic was made from Lisp by asking whether the OZ
host was up, which answered `T` on both:

    onto the network: RFC 177100 -> 177002, 6 bytes, check good
    to the machine:   ANS 177002 -> 177100, 68 bytes, check good

The Cora Z7-07S's pair reads the same with `177102` in place of `177100`.
`trace-chaos off` stopped it, both exits 0. No register is touched for any of
this and both machines were running throughout.

**Nothing else about either machine moved.** Both were RUNNING on every
reading, 6,364 to 6,819 microcycles per 2,000 microseconds, with `FLAG-1`
`0xf900` every time. Both screens carry a System 304 Lisp Listener two minutes
after the boot, 18,080 lit pixels on the Arty Z7-20 and 18,048 on the Cora
Z7-07S, with who-lines dated after this boot began and advancing at 0.509 of
real time on both. The mouse tracks on both, read off `tv:mouse-x` and
`tv:mouse-y` rather than off the arrow alone. The Arty Z7-20 took the
debugger's role over the mirrored ribbon, found the wiring crossover, and read
0 refused against a saturated 65,535 heard across a minute, with the Cora
Z7-07S reporting a debugger on its connector and no `peer_far` line. The
sections above say what each of those measurements means; this set moved none
of them.

**Two facts were found, and neither is a fault in the fabric.**
`--color-terminal` does not refuse when no board is fitted. With the board
unfitted the program printed exactly the sentence it should, naming the NXM
and naming `--color-tv` in `fpgarc` as what fits one, and then carried on,
bound 5903 and served a black screen. The words are right and the verb is not:
that branch says and does not return. So fitting the board before the terminal
is started is good practice rather than a requirement.

And both development cards predate the color flags entirely. Neither card's
`fpgarc` contains `--tv-board` or `--color-tv` in any form, commented or
otherwise, because both were written before this commit's menu existed. The
effect is the same, since both settings are off without them, but a card
written from this commit's script carries all four of the display lines
commented out.

## The 10 ns grid on the board, 17 September

The Arty Z7-20 was served a set built from a clean tree at `9d1cf26`, the
commit that moves MIT's grid from 5 ns to 10 ns. The part's USERCODE reads
`9d1cf260`, and `cadr-console status` says `commit 9d1cf26, tree clean`. The
Cora Z7-07S was not reset.

**The machine boots MIT's Lisp on the 10 ns grid.** The drive came present,
43,484 blocks were served and 21,096 written back, and a Lisp Listener was
painted 84 seconds after the reset, with 18,116 lit pixels and no trap.
`FLAG-1` reads `0xf900`, with `ERR` down.

**It retires 1.880 times as many microcycles.** Over 195.406 seconds of the
fabric's own ticks the machine retired 0.058757 microcycles a tick. That is
5.876 million a real second, and 88.1% of the one in 15 a microcycle at normal
speed allows. Read the same way just before the reset, on the 5 ns grid, the
same board retired 0.031256 a tick, which is 3.126 million a second and 90.6%
of one in 29. The console's 2,000-microsecond window reads 12,359 to 12,546
retired, where it read 6,577 to 6,658. The smaller share of a microcycle is
consistent with memory stalls costing more of a shorter cycle, and it has not
been examined.

**The microsecond clock keeps real time.** `(time:microsecond-time)` read three
times about 62.5 seconds apart gave 387,418,772, 449,945,806 and 512,475,250.
That is 62,527,034 microseconds in 62.530 real seconds, 0.99995 of real time,
and 62,529,444 in 62.529, 1.00001. At the 5 ns grid the same clock ran at half.

**The who-line runs at 1.015 of real time, and that is the band's and not the
grid's.** Fourteen readings 15 seconds apart gave 198 seconds of who-line in
195.0 real seconds, which is 1.0154 with an uncertainty of 0.005 from the
one-second display. It gains a second about every 65 seconds. At the 5 ns grid
this file recorded 0.508, and 0.508 is 1.016 times 0.5. So the who-line has
always run about 1.6% ahead of the microsecond clock, and the grid moved both
by the same factor. After a console boot the same drift appeared again: 209
seconds of who-line in 206.4 real seconds, 1.013.

The cause is not established. A time base in units of 2^14 microseconds read
as sixtieths of a second would give 1.01725. That is a candidate only, because
the System 304 sources were not at hand to check it against.

**Chaosnet, the mouse and the keys work.** `(chaos:host-up-p)` on the file and
time host answers `T`, and `(time:print-current-time)` prints the right date.
The arrow moves with a viewer's pointer, and `tv:mouse-x` and `tv:mouse-y` went
from 767 and 923 to 376 and 710 on a walk of -400 and -320. On the 5 ns grid
the same walk moved y by 342. MIT's speed-dependent mouse scaling now sees real
speed, which is a candidate for the difference and is not established. `(+ 1
2)` typed over RFB answers `3`, and the auto-shifted `+` arrives as a `+`.

**The serial line is whole at 300 baud.** Two bursts of `HELLO CADR` arrived
whole at 29.9 characters a second, which is the full real rate of a 10-bit
frame at 300 baud. At the 5 ns grid the same bursts came at 15.0.

**At 9600 baud characters were lost, and this is open.** Two bursts arrived as
`HELO AD` and `HELO ADR`, at 474 characters a second. The serial face's dropped
counter read 5, and `cadr-serial` reported that the port dropped 5 of its own.
The machine sent those characters, and the program had not yet taken the
previous one out of the one-character holding register. The program looks at
the port every 2,000 microseconds, and a 9600-baud frame is now 1.04 ms of real
time. Run by hand with `--poll-us 500`, three bursts gave `HLLO CADR`, `HELLO
CADR` and `HELLO CADR` at about 700 characters a second, and the counter went
from 5 to 6. Faster polling mostly cures it and does not remove it. Receiving
at 9600 works: `ABCDE` written to the program's socket reads back in Lisp as
`(65 66 67 68 69)`.
The fabric has changed since: the line now keeps a store of 1,024 characters
behind the holding register (`STORE_DEPTH` in
`rtl/plumbing/cadr_serial_line.sv`), and `docs/io-board.md` describes it.
This file has no 9600 baud run on that fabric yet.

**The cold load takes the same real time as on the 5 ns grid.** After
`cadr-console boot` the screen cleared at 58.6 seconds and was repainted at
60.0 seconds. Another 43,483 blocks were served and 21,095 written back, with
no failure and no denial. At the 5 ns grid the clear came at 57.16 to 57.50
seconds. The processor now runs 1.88 times as fast, but the cold load is bound
by the disk path, about 64,500 block moves in 58 seconds through the Linux
program, and not by the machine.

## A placement fault fixed, and the serial store, 17 September

**Builds of the 10 ns grid's fabric halted depending on their placement.**
The served build of `9d1cf26` ran Lisp. The same RTL placed with
`-directive Explore` halted at 1.07 G microcycles, and two placements of a
slice beside it halted on every boot. The halts landed in the page-fault code
with stray pixels in the frame buffer, and every build met timing.

**The cause was a one-tick request granted as a bus cycle.** `memgo_q` is
MEMSTART AND VMAOK registered every tick, with the map before it. Its path is
allowed eight ticks and routes at about 19 ns, so on an access that faults the
tick after the boundary can hold a VMAOK that has not settled. The bus
interface granted on that tick. The grant ran a cycle at the last address used
with stale write data. At `80e92d2` the interface samples -MEMRQ again at the
master clock, as MIT's priority logic does. The unfixed Explore placement
halted again at 331,783,208 microcycles. Four placements with the fix ran
4.08 G microcycles each with forms typed and a clean screen.

**Main's fabric at `80e92d2` on the Arty Z7-20.** Two placements were built
with `DDR=1 HDMI=1 LMTV=1`: the default at +0.253 ns and Explore at +0.239 ns,
both with 5,366 slices and 46 block RAM tiles. Explore ran 4.11 G microcycles
and the default 4.78 G, and then 8.08 G after the serial test, with no halt.

**Serial at 9600 baud now loses nothing.** The line keeps a store of 1,024
characters behind RDATA (`3f7829f`). Measured on the default build:

| Test | Result |
|---|---|
| ten bursts of `HELLO CADR` | 10 of 10 whole |
| a hundred characters in one `dotimes` | 100 of 100 |
| 342 characters with `cadr-serial` stopped for 3 s | 342 of 342; WAITING and DEEPEST reached 342; DROPPED 0 |
| `ABCDE` typed into the socket | read by Lisp, 5 of 5 |
| the same at 300 baud | whole, at 30.0 characters a second |

Each build had one boot, so an intermittent fault is not ruled out by these
runs.

## Looking at the display output

The display output block scans the CADR's screen out of DDR and drives the
board's HDMI TX connector from the fabric, with no software in the path.
`docs/display-output.md` is the design. These are the steps that were followed,
written before the fact so that what counted as a pass was fixed in advance.

### What to build and serve

The display is built into the bitstream and is off by default. Build it with
both the memory and the display:

    DDR=1 HDMI=1 OUTDIR=build/hdmi vivado -mode batch -nojournal -nolog \
        -source boards/arty-z7-20/vivado/bitstream.tcl

That writes `build/hdmi/cadr_arty.bit`. Serve it the way any other bitstream is
served: copy it over the `cadr.bit` the board fetches, and reset the board.
Nothing else changes. The start-up routine is unaffected, because enabling
`S_AXI_HP3` changes `ps7_init` by nothing, and the root filesystem is
unaffected, because no program is involved.

### What to connect

An HDMI cable from the board's **HDMI TX** connector to a monitor that does
1280x1024 at 60 Hz. That is the connector nearer the Ethernet jack; the board
has an HDMI RX beside it and a cable in the wrong one shows nothing.

The monitor must accept 1280x1024 at 60 Hz. It is the most widely supported
mode after 640x480, but a small panel with a fixed lower resolution will
refuse it, and there is no fallback: the block sends one mode and does not
read the monitor's EDID.

### What should appear

The machine's own screen, 768 by 963, at the LEFT of a 1280 by 1024 raster:
columns 0 to 767, rows 30 to 992, with 512 columns of black to the right of it
and about 30 rows above and below. White on black. With a color board fitted
and `--hdmi-output both` on the card, the color screen's 576 by 454 sits at the
right of the same raster, columns 704 to 1279, over the first display in the 64
columns they share.

**The sessions recorded below were taken on a build that centered the first
display**, with a border 256 columns wide on each side, and they describe what
was on the monitor then.

The board takes about fifteen seconds to boot Linux and the CADR takes a while
longer to load its microcode off the pack and paint anything, so the first
thing on the monitor is a black screen with the run bar and the disk light
blinking on one line near the bottom. What should follow is the window system
and a Lisp Listener, which is the same picture the remote viewer serves on
port 5900 — so **the viewer is the control**. If the viewer shows the screen
and the monitor does not, the fault is in this block or in the cable; if
neither shows it, the machine has not got there yet and this block is not the
thing to look at.

### What the failures would mean

**No signal at all, or the monitor reporting no input.** The serializers are
not sending, which is the clock rather than the picture: either the bitstream
is not the `HDMI=1` one, or the display's MMCM is not locked. The CADR itself
runs either way, so LD1 and LD2 say nothing about this. The cheapest check is
that the bitstream served is the one that was built with `HDMI=1`.

**A signal the monitor syncs to, showing black everywhere.** The raster is
running and the picture is not arriving. That is the memory side: either
`S_AXI_HP3` is not answering, or the display's region of DDR is empty because
the machine has not painted anything yet. The remote viewer separates the two
in one step, because it reads the same words over the same DDR by a different
path.

**A signal the monitor syncs to, showing noise.** The picture is arriving and
is being read wrongly. That would be new: the raster, the line buffer handoff
and every read burst are checked against a modeled memory poisoned
injectively in the address, which is exactly the stimulus that makes a
misread show as noise rather than as black.

**A picture that tears when the machine draws.** Expected, and not a fault.
The machine writes the bitmap whenever it likes and the raster reads it
whenever it likes, with no buffering — which is what MIT's display controller
did. See `docs/display-output.md`.

**A stable picture with the wrong geometry — shifted, or wrapped diagonally.**
The monitor has picked a different mode from the one being sent. Check what it
reports the incoming timing as; it should say 1280x1024 at about 60 Hz.

## LMZ System 1001 on both boards, 18 September 2026

The Arty Z7-20 and Cora Z7-07S both booted
[LMZ System 1001](https://github.com/metebalci/lmz/releases/tag/lmz-1001),
tag `lmz-1001` at `1c5494d8891d73627a5a3307e3c83649ba627630`.
Neither needed a new bitstream: the Arty still runs fabric build `44eff450`
and the Cora `0966ffd0`. Both report microcode 323.

The release assets were checked against their published SHA-256 digests:

| Asset | SHA-256 |
|---|---|
| `lmz-1001-pack.img.gz` | `70a620e28feade762f27a0b4d6408e942e4d9495b3c81a6f0530dd7e28070b05` |
| `lmz-1001-sys.tar.gz` | `dc83a333f2f2703ef224c1551406e5d208c94b0ced6d44827fe0b35caf4c6378` |
| Uncompressed pack, 269,562,880 bytes | `35b15e7e947bdcd0e3b3994ca107c247d599ac6127b13b5d8d9029281de1364c` |

Each uploaded pack was synced, read back from its SD card after dropping the
Linux page cache, and hashed before boot. Both matched the uncompressed
release. The running machine writes its pack, so that digest identifies the
installed release bytes, not the pack after use.

### Two machines on one site

The Arty is LISPM-1 at Chaosnet address `177201`; the Cora is LISPM-2 at
`177202`. OZ is `177200`. All three addresses are octal. The development
server runs ozd against the release's source tree and a separate copy of its
site files extended with LISPM-2's host and machine location. The original
release site files are kept unchanged.

The Cora's card configuration and its build host's private `local.conf`
both name its new address and OZ peer. A stock band knows only LISPM-1, so
setting the hardware address alone initially leaves the Cora's local host
unnamed. On the Cora, after logging in to OZ, these forms loaded the two-host
site configuration and saved it in the spare `LOD2` partition:

```lisp
(chaos:generate-host-table)
(load "SYS: SITE; HSTTBL LISP")
(load "SYS: SITE; LMLOCS LISP")
(chaos::setup-my-address)
(si::set-local-host-variables)
(si:disk-save "LOD2" t)
```

The save reloads the world it wrote. Once it had returned to a Listener,
`(si:set-current-band "LOD2")` made that the default for the next boot.
The disk label was read back to confirm the selection, and a subsequent
`cadr-console boot` verified that the default band retained the LISPM-2
identity. The distribution's pack name remains LISPM-1 in the herald's
first line; `si:local-host` is LISPM-2 and the machine description is
"Lisp Machine Two, with associated machine OZ."

The Cora's original `LOD1` remains byte-identical to the release: its 49,419
blocks starting at block 65,569 have SHA-256
`002e925bee9c832da5260ea04cd976bb81e2508aa16f47381cb8fddf4dd750aa`.
The Arty's previous pack and the Cora's previous configuration were retained
for rollback. System 100 reference packs and golden traces were not changed.

### What was checked on the boards

Both machines reported System 1001 from `si:get-system-version`, answered
`(chaos:host-up-p "OZ")` with `T`, logged in successfully, and read the
expected first line of `SYS: SYS; LTOP LISP`. These were observed through
RFB, with the server log independently recording each login and file read.
The Arty's file read was repeated after the server acquired the Cora's peer.

Both console counters showed the processors running. The Cora's final disk
sample reported 128,847 blocks served, 62,297 written back, no lost blocks
and no failures. This establishes boot and basic network file access, not
a full SYSTEM build on either FPGA.

## The DE25-Nano against muir, 19 September 2026

The DE25-Nano is reached through Quartus rather than Vivado.
`boards/de25-nano/README.md` has its flow, and `docs/toolchain.md` has the
commands. The board was loaded over JTAG only. Its flash was not written,
and no switch was moved.

The probe's build was loaded with `make de25-program PROBE_DEPTH=1024`. The
part read back the previous build's stamp before the download and the new
build's stamp after it. The JTAG server then reported the probe build's own
hub hash. `make de25-probe` found the part holding that build. A bypass scan
of the probe's node came back one bit late, as it should, and the node read
back the instruction shifted into it. The reader then took the 1,024
samples. All of them agree with `build/rtl.golden` on the cycle counter and
the probe's 22 columns. Eight of those columns are constant in this window.
A second readout returned the same file.

The plain build was then loaded again, and the board was left running it.

## The DE25-Nano's processor and its memory, 19 September 2026

The memory board, `make de25 DDR=1`, is the machine with the Agilex 5's
processor behind its memory port: the FPGA-to-SDRAM bridge, the LPDDR4 the
processor's own controller drives, and both processor-to-fabric bridges
answered end to end.  `boards/de25-nano/README.md` has the design and the
figures.

**A part with a processor in it is not configured by a bare bitstream.**  The
HPS Booting User Guide says so, and the flow writes the file the board needs
instead: with the first-stage loader added, one file that configures the
fabric and starts the processor.  That is the board a JTAG cable can load
with nothing written to the flash and no card in the socket, and it is
FPGA-first, because a processor that boots first takes its first stage from
the flash.

**The processor's debug port joins the JTAG chain.**  Altera's boundary-scan
guide for the family says the processor's TAP appears only once a design with
the processor in it is configured, and it does: the chain that held one part
holds two, the port first and the FPGA second.  It joins DURING
configuration, and the programmer says so itself --- it reported the
configuration as succeeding at device index 2 for a part that was index 1
when the download began, and added a line naming what had arrived.  The port
is an Arm CoreSight SoC-600 debug port, IDCODE `0x4BA06477`, four bits of
instruction register.  `quartus/jtag.tcl` and `quartus/program.sh` take that
chain, pick this board's FPGA out of it by its IDCODE, and refuse anything on
the chain that is neither.  The build stamp was then read back through the
two-part chain by a raw scan, and it is this build's.

**The processor's memory calibrated.**  The first-stage loader in that file
ran and printed what it did on the processor's serial line: the initial
calibration of the memory interface succeeded, the memory is 1,024 MiB, the
size check passed, the firewall that lets the fabric reach it was opened, and
the memory came up.  That is this project's own description of the memory ---
the controller's parameters, its speed and the board's byte lanes --- proved
on the part.  The loader then looked for the next stage on the card, in the
flash and in memory, found none of the three, and stopped, which is what a
board with no card and a flash nobody has written must do.

**So the machine's memory cycles cannot be proved yet, and what is missing is
software.**  The gate stays shut until U-Boot has run `bridge enable` and
raised it, and U-Boot comes from the card.  What the board showed is the two
things that had to be true before that: the memory works at the settings this
project generated, and the fabric holding the machine is the build it says it
is.

**The processor's debug port is reachable over the same cable**, which is the
other way software could be replaced: OpenOCD, with the adapter Quartus
ships, attaches to the chain, names both TAPs, and examines a memory access
port on the debug port.  Walking its debug ROM table then hangs in that
version, so reading the processor's memory that way is not established here.


## The DE25-Nano's memory on silicon, 20 September 2026

The machine's memory cycles reach the board's LPDDR4 through the processor
system's SDRAM bridge. The proof is one instrument read in two gate states, and
its figures were written down before the run.

The board was prepared so that nothing could touch memory before the
measurement. Its card was written and verified, the processor calibrated the
LPDDR4 and U-Boot stopped at the empty fabric slot, and the slide switch SW0
held the machine unbooted. The data cache was turned off, so the processor and
the fabric see one memory. Then 1,024 words from the machine's base were
poisoned with a pattern that depends on the address, read back word for word,
and checksummed. The gate word read zero, so the port was shut.

The first press of the boot button ran the machine against that shut port. The
counters at the bridge read 256 reads and 256 writes asked and none answered,
which is the boot PROM's page-0 parity pass exactly once, every cycle ending on
the machine's own timeout. The poisoned block was unchanged, which is what a
shut port has to mean. The counters carry a marker bit in each half, so a word
of all ones or all zeros cannot be mistaken for a reading.

The bridges were then enabled and the gate raised by the board's own boot
commands. The secure firmware accepted the fabric's warm-reset acknowledgment
inside its own timeout, which is that handshake's first run on silicon. With
the gate open and no new press, the counters and the memory did not move, so
whatever followed belonged to the next press.

The second press gave the three figures exactly as predicted: 512 reads and 512
writes asked in all, 256 reads and 256 writes answered, and the poisoned block
unchanged. The answers being exactly half the cumulative requests is the whole
instrument in one reading. The first run met a shut port and was never
answered; the second met an open one and was answered at the bridge's own
handshakes, which a fabric that issued no transaction cannot fabricate. Page 0
was read twice, identically, and every one of its 1,024 words read back as its
poison.

What this does not cover is worth stating. The window is the boot PROM's parity
pass alone: 256 word reads and 256 word writes of one page, with no other
master on the shared port. It does not exercise the disk pack side, the
display, their arbitration, or any address outside that page. Page 0 matching
is not the proof, because an identity copy leaves nothing behind; the counters
are what say the path was used.

One ordering matters on this board. The gate is raised by software, seconds
after the fabric is configured, while the machine reaches its only memory pass
about 118 ms after its own reset. A machine left to start by itself therefore
spends that pass against a shut port. The Zynq boards escape this only because
their port comes up in the first-stage loader, inside that window. Until the
machine is held until the gate is up, SW0 stays up and the machine is started
by the boot button.

## A band on the DE25-Nano, 20 September 2026

A machine on this board ran a band for the first time. The fabric is build
`bd749d20`, the band is LMZ System 1001 from the card, and the shipped boot
path ran all the way through with nothing typed.

**The board still needs a cable at every power-on.** Its flash has not been
written, so the fabric and the first-stage loader arrive over JTAG in one
file. The part read back `ffffffff` before the download and `bd749d20` after
it. The JTAG hub reported a design before the download and none after, which
is a second and independent witness that the fabric changed, because the image
in the flash carries a hub node and this build carries none. This family gives
the fabric no way to read its own stamp, so the console reports none, and that
JTAG reading is the only witness of what the part holds.

**The whole boot ran with nothing typed.** The first-stage loader calibrated
the memory and loaded the next stage from the card. U-Boot then read the
card's `uEnv.txt` of 1,942 bytes, the fabric image of 2,052,096 bytes, which
it did not use because `uEnv.txt` says the fabric is configured already, the
device tree of 23,733 bytes, the kernel of 41,921,024 bytes and the initial
ramdisk of 4,225,544 bytes, and started the kernel. Reading an image it does
not use cost 381 ms and nothing else. Linux then started five programs from
the card's own `fpgarc`, and nothing was started by hand.

**Both processor-to-fabric bridges carried their faces.** The console answers
at `0x2000_0000` on the lightweight bridge with its own identifier. On the
main bridge the pack side answers at `0x4000_0000`, the Chaosnet interface at
`0x4000_1000` holding this machine's Chaosnet address `177203`, the keyboard
and mouse at `0x4000_3000`, and the serial port at its own window. Each of the
five was read, and the pack side then carried the band.

**The drive came present and the machine booted its band.** The disk pack
program found one writable drive of 815 cylinders, 19 heads and 17 blocks a
track, 263,245 blocks in all, and read a labeled pack at block 0. The
machine's first three requests were block 1, block 0 and block 17, which are
the three the Zynq boards' boot PROM asks for, in the same order. The machine
then reported RUNNING with PROMDISABLE set, which is what says it has left its
boot PROM and is running microcode it loaded from the pack. A machine that
finds no drive stays in its boot PROM with that bit clear, which is the
reading this board gives with an empty bay.

**The counters are the measurement.** The disk pack program prints its summary
at most once a minute and only when a count has moved, so the absence of a
later line is itself a reading. Its final tally is 42,170 blocks served and
20,493 written back, with none denied, none refused, none deferred, none lost
and no failures, over 214,360 polls. The bay was looked at 214 times: one
drive appeared, none went away, none was write-protected and no block was
lost. A count that rises with the work beside counts that stay at zero is what
tells a working path from a busy one. Nothing was printed after the band's
load finished, so the machine asked for no block while it sat at its prompt.

**The write-backs reached the card.** The pack file is still 269,562,880
bytes, the length of the release asset, and its SHA-256 is now
`97505e9468668cd64470d977e7bf5d5bb4554d63c3a81edec9e95d77bdc95c91` where the
release's uncompressed pack is
`35b15e7e947bdcd0e3b3994ca107c247d599ac6127b13b5d8d9029281de1364c`. So the
write-backs landed in the file, in place and without changing its length. A
pack a machine has run is no longer the release asset byte for byte, and a
digest taken against the release will fail from here on.

**A halt made the register reading exact.** The cycle counter read
3,790,835,915 twice running on the halted machine, which is what says the halt
took, while the tick counter moved between the two reads, because the fabric
clock runs whether the machine does or not. One counter frozen beside one
moving is what a real halt looks like. The flag register read `0xf800`: the
run flag down, no error, PROMDISABLE still set, and every one of the eight
parity bits zero, so no A memory, M memory, pushdown buffer, micro-stack,
dispatch, control store or main memory parity error. Starting the machine
again moved the cycle counter. The disk pack program said nothing across the
halt, which is what it must do, since halting the machine does not touch its
cable to Linux.

**The machine retired about 5.75 million microcycles a second while the band
loaded**, from two cycle counter readings 2,000 us apart, and about 6.0
million a second with no disk traffic. The Arty Z7-20 retired 5.88 million
microcycles a real second while running Lisp.

**The machine drew its own screen.** A sample of 1,024 words taken evenly
across the machine's display window, every twenty-second word, had 192 of its
32,768 pixels lit, 0.59 per cent. The control is the same sample of the color
board's window, which no fitted board and no program writes: 15,494 of 32,768
lit, 47.3 per cent. The terminal's own reading of the whole main window
seconds after the boot was 356,824 of 739,584 lit, 48.2 per cent. The two
unwritten readings agree with each other at about half the bits set, which is
what uninitialized memory looks like, and the main window has since been
written down to under one per cent. Eight minutes later the same sample read
194, so the screen is drawn and static, which is a band sitting at a prompt
rather than one still loading.

**The boot PROM's memory pass was answered.** The gate word read 1, so the
port was open, and the tally read 256 reads and 256 writes answered with its
marker bit present. That is the boot PROM's page-0 parity pass, all 512 cycles
of it, answered at the bridge's own handshakes. The same half of the same
instrument read nothing answered in the memory session earlier the same day,
when the machine ran that pass against a shut port.

### What this does not establish

The tally's four counters are fifteen bits, and by the time anything read them
again they were saturated, all four fields at 32,767. They are a witness for
the boot PROM's pass and for nothing after it, so no figure here is a count of
the band's own memory traffic.

Nothing timed when the machine left reset against when the memory gate was
opened. The pass was answered, so on this boot the gate was up in time, but
what ordered the two is not established by this session, and the previous
session's figures say a machine left to start by itself can meet a shut port.

No viewer connected to the RFB server and no key was typed, so the terminal's
path into the machine was not exercised. The serial line carried nothing. The
display output has never left the board, its connector being unwired. The
Chaosnet program reached nothing: ten frames came from the machine and ten had
nowhere to go, because this board's Ethernet transmit path does not work, so
it never took an address and had no route. The board's clock read the epoch,
this card's root filesystem being older than the flags that set one.

### The first-stage loader decides whether this kernel lives

At a cold power-on with no download, the board boots the first-stage loader in
its QSPI flash as shipped, `U-Boot SPL 2025.01`. That loader reads the second
stage from this card, so everything after it is this project's: the same
U-Boot, the same device tree, the same kernel and the same card. The kernel
then takes an asynchronous SError in `cqspi_wait_idle`, called from
`cqspi_probe`, and panics.

Nineteen kernels started that way in one log, and every one of them died
there: seventeen panicking on the SError and two killing init with the same
function in the backtrace. Six kernels started under this project's own
first-stage loader in the same log, and none panicked. Under it the same
driver probes the same controller and says only `unrecognized JEDEC id bytes:
90 5d 8c 08 22 00`, and the boot goes on.

The comparison is tightest across the download that ended the loop. The boot
before it and the boot after it read the same six files from the same card at
the same six sizes, ran the same second-stage U-Boot, loaded the same device
tree of 23,733 bytes and the same kernel of 41,921,024 bytes, and reported the
same kernel version. Only the first-stage loader changed, and the kernel died
on one side of the download and lived on the other.

The two loaders differ in more than the outcome. That same kernel read from
the card at 18.6 MiB/s under the shipped loader and at 5.4 MiB/s under this
project's, so they leave the card interface at different speeds, and whatever
separates them is not confined to the QSPI controller. Which of their settings
accounts for the panic is not established here.

## The DE25-Nano's display on a monitor, 20 September 2026

A monitor was wired to this board's HDMI connector for the first time, and a
signal left that connector. The fabric is build `321a7510`, built with both the
memory and the display, and the card is a new one, written whole from a single
image and booted here for the first time.

**The bitstream and the tree are one commit.** The file downloaded carries the
processor's first stage as well as the fabric, which the packager reports as
`HPS present: TRUE`, and it was checked for that before anything was sent, the
bare fabric file beside it being the one that would leave the processor to the
flash. The part read back `ffffffff` before the download and `321a7510` after
it. The JTAG chain held one part before and two after, the processor's debug
port joining during configuration, and the hub reported a design before the
download and none after, because the image in the flash carries a hub node and
this build carries none. The build's own report gives mode 1280x1024 at 60 Hz,
a pixel clock of 108.0030 MHz where the mode asks 108.0, 16,076 ALMs and 135
M20K, with timing met. The board still needs a cable at every power-on, since
its flash has not been written and this configuration is volatile.

**A signal leaves the board's video connector.** The control was taken from
outside and before anything was done to the board: the same monitor on the
same cable reported no signal with the part unconfigured. The reading after the
download, by the same eye on the same monitor and the same cable, is that the
display works. The transmitter does nothing at all until its registers are
written, and `rtl/plumbing/cadr_adv7513.sv` writes them out of the fabric's
reset with no program, no face and no boot in the path, so a monitor that syncs
at all says the register program reached the part and made it transmit.
`docs/display-output.md` records that nothing held that these registers make an
ADV7513 transmit, and that the connector had never been wired to a monitor;
both of those are superseded here. That document also leaves one question open
for the first time a monitor is attached, which is that the pixel clock's pin
sits in a bank whose standards stop at 1.2 V while the part's data sheet asks
at least 1.35 V of its video inputs. A monitor syncing at this mode is the
first evidence that the two meet on this board, and it is evidence from one
board at one mode.

**The raster is running, and that is measured inside the fabric rather than
inferred from the picture.** The instrument is the sleep mute, because of where
it lives: in `rtl/plumbing/cadr_display_out.sv` the timer runs on the machine's
clock, but the mute is assigned only at the last pixel of the last line of a
frame, in the pixel clock's own domain, and what the console reports is that
bit brought back through two flip-flops. With the sleep set to five seconds the
console read awake at once and again a second later, so the bit is not stuck
and the timer had restarted at the write. Eight seconds later it read asleep,
which is reachable only through a frame boundary of the pixel raster. Turning
the sleep off read asleep in the same command, which is right, because the mute
is released at the next frame boundary and a console read microseconds after
the write falls inside that window; a later read said awake. That is two frame
boundaries, one in each direction, so the pixel-clock domain advanced through
whole frames while it was measured.

**The machine's screen is in the memory the display reads**, by three readings
on three code paths. A sample of 1,000 words taken across the machine's display
window at a stride of 23 words, which is coprime with the line of 24 and so
walks every position in a line, had 854 of its 32,000 bits lit, 2.67 per cent,
and 862 on a repeat minutes later, so the screen is drawn and static. The
terminal's own reading of the whole screen was 17,999 of 739,584, 2.43 per
cent. One frame read over RFB from the build host was 18,016 of 739,584, and it
is a Lisp Listener with its herald, its mode line and a status line. The
control is the color board's window, which no fitted board and no program
writes: 16,367 of 32,768 bits lit, 49.9 per cent, half its bits set, which is
what uninitialized memory looks like. The terminal's own reading of the main
window before the machine had painted was 368,831 of 739,584, 49.87 per cent,
which agrees with that control at a different address by a different program.
An earlier sample of the same window at a stride of 22 read 1.08 per cent, and
that is explained rather than explained away: 22 shares a factor with the line
of 24, so it only ever lands on even word positions and never sees the other
twelve.

**The card boots by itself.** The shipped boot path ran all the way through
with nothing typed once the fabric was loaded. This project's own first-stage
loader replaced the factory one that had been panicking the kernel in a loop,
and then U-Boot read the card's `uEnv.txt` of 1,942 bytes, the device tree of
23,737 bytes, the kernel and the ramdisk, and started Linux, which started six
programs from the card's own `fpgarc`. The drive came present at 815 cylinders,
19 heads and 17 blocks a track, 263,245 blocks in all, with a labeled pack, and
the machine reported RUNNING with PROMDISABLE set. The disk pack program's
final tally is 42,371 blocks served and 20,493 written back, with none denied,
none refused, none deferred, none lost and no failures, over 213,582 polls. Two
cycle counter readings 2,000 us apart differ by 11,637 microcycles, which is
5.82 million a second.

**The board's clock reads the epoch, and that is the right reading for this
card.** The root filesystem is the first that carries the flags which set a
date and a time, but both lines are commented out on this card, and a fresh
card has no saved clock from a previous clean shutdown, so there is nothing to
restore and nothing to set. The board has no real-time clock. These are the
flags being absent, not the flags failing.

**The Ethernet transmits, and the Chaosnet program carried a round trip.** This
was found while measuring the display and was not what the session set out to
do. The board took an address by DHCP, where the first attempt had reported no
lease, it answers a ping from the build host in under a millisecond, and its
RFB server accepted a connection from the build host, which is how the frame
above was read. The Chaosnet program's own tally reads one frame from the
machine and one to it, one out and one in over UDP, one datagram arrived, none
refused for its shape, none with a bad checksum and **none with nowhere to go**.
The machine asked the associated machine for the time at cold boot and was
answered: the associated machine's own log, on another host, records answering
a time request from this machine's Chaosnet address, and the band's status line
carries today's date at a local time two hours ahead of UTC while Linux
underneath it still reads the epoch. The board has no real-time clock, so that
date came over the network. The section above records ten frames from the
machine with nowhere to go, because this board's Ethernet transmit path did not
work; that is superseded here, and what changed between the two is not
established by this session.

### What this does not establish

**Nothing ties the pixels at the connector to that memory.** Everything
measured here is what is *in* the display's window, and nothing on the board
can read what leaves the connector, so the tie between the two is one pair of
eyes. That the picture is the machine's own screen, and that it is centered in
the raster as built, have not been confirmed at the monitor. Nor was the
sequence that would have settled it recorded as it happened: black while the
memory gate is still shut, then a block of noise 768 by 963 centered with a
black border, then the machine's screen. The one test that would close it is to
write a run of known words into the window and see a bar appear where the
arithmetic says, which needs somebody at the monitor and has not been done.

**The monitor's own reading of its mode has not been taken.** The fabric was
built for 1280x1024 at 60 Hz and the pixel clock measures 108.0030 MHz against
the 108.0 the mode asks, but nothing on the board can ask the monitor what it
thinks it is receiving. A monitor that picked a different mode would show a
picture with the wrong geometry, and that is exactly the failure this reading
exists to separate.

**Five signals that would report the transmitter's state and the display's own
faults reach no register on any board.** The transmitter's `configured` and
`failed`, and its count of the registers the part acknowledged, together with
the display's sticky `underrun` and its read-error bit, all go into an unused
fold in the board's top level, and the console has no command that reports any
of them. So whether the two-wire program was acknowledged byte by byte is not
established, and neither is whether the display has ever been starved. **A
static screen being starved looks exactly like one being fed**, which is what
that sticky bit exists to tell apart. The underrun and the read-error bit are
folded on the Arty Z7-20 in the same way, so they are unreadable there too; the
three that report the two-wire program are particular to this board, which is
the only one with a transmitter to program. One console word would carry all
five.

**The sleep was not seen from outside.** The fabric entered the mute and left
it, each at a frame boundary, but nobody was watching the monitor at the time,
so whether it dropped to standby and came back is a separate claim and is not
made here. The two rotations, the output selection and the second display board
are all built and none of them has been seen.

**Nothing was typed into the machine by any path.** So the terminal's path into
the machine was not exercised, no key reached the band, and the serial line
carried nothing. No USB keyboard is attached to this board.

### What this settles, and what it does not

The Chaosnet block is shown on this board, on the grounds the Arty Z7-20's
block was shown on and one witness more: the band's date comes from the
network, the program's own tally accounts for every frame, and the associated
machine's log on another host records the answer. The I/O board is not shown,
because only its Chaosnet half was used, so it stays checked here and not yet
shown on silicon. The terminal block is not either, its path into the machine
being untouched.

The display output block is not shown here. Silicon has shown that the block
drives a link a monitor accepts and that its raster runs, which is more than
was known before it, but what makes this block the display output — that the
pixels it fetches from memory are the pixels that leave the connector — is the
one thing above that nothing has yet read. Confirming the geometry at the
monitor, or the pattern test, would settle it.

## The DE25-Nano's keyboard, its picture and its sleep, 21 September 2026

The session above left one thing unread: nothing tied the pixels at the
connector to the memory the display reads. That tie has now been made at the
board, and how it was made matters more than the fact of it.

**What is typed at the board's own keyboard appears on the monitor.** A USB
keyboard plugged into the board is read by `cadr-usb-input`, which hands each
key to `cadr-terminal`, the one program that maps and paces words onto the I/O
board's keyboard register. The machine reads that register, paints its frame
buffer in memory, the display output scans that memory, and the transmitter
sends it. One keystroke crosses every one of those links, and the far end of it
is a character on the glass that was not there a moment before.

**That is the reading the rest of this section rests on**, because it is a
change the observer caused arriving at the connector, which is a stronger thing
than a picture somebody recognizes. A picture somebody recognizes can be a
frame that stopped arriving minutes before, or a recognition loose enough to
fit more than one thing. A character that appears when a key is pressed and at
no other time can be neither, and
it runs the whole path in one direction, from the I/O board's keyboard register
through the machine's own memory to the pixels that leave the board.

**The mouse moves the pointer on the screen.** Its movement and its buttons go
down the same path, through the same program and onto the I/O board's own
registers, and the arrow on the glass follows the hand.

**The monitor's own menu reports the mode.** It reports the mode the bitstream
sends, 1280x1024 at 60 Hz. The section above names that reading as the one that
separates a monitor which has picked a different mode, since such a monitor
shows a picture with the wrong geometry; it has now been taken.

**The picture is the one this project describes.** It sits centered in the
raster with its border rather than filling the screen, and it is the same
picture the Arty Z7-20 shows: the machine's own 768 by 963 screen in a 1280 by
1024 raster, white on black, with a black border 256 pixels wide on each side
and about 30 rows deep above and below. The section above records that the
geometry and the centering had not been confirmed at the monitor. That is
superseded here.

### Nothing inside the board was read while this happened

**A keyboard and the cable that programs the board are not attached at the same
time.** Attaching the keyboard meant unplugging that cable, and that connector
also carries the processor's serial console, so the console fell silent at the
moment the keyboard arrived.

So no counter, no tally and no status word stands beside any reading above.
This session's evidence is entirely what a person saw. That does not weaken the
tie the typing makes, which is a tie no instrument inside the board could have
made anyway, since nothing on the board can read what leaves the connector. It
does mean that nothing here is corroborated from inside, and the record should
not be read as though it were.

**It makes the demonstration stronger in one way.** With that cable out, the
board was running on its own, from its own card, on a fabric already
configured, with nothing attached to it but power, a monitor and a keyboard.
That is closer to what the board is meant to be than any reading taken with a
programmer plugged into it.

**And it is a standing constraint on this board rather than an accident of this
session.** A test that wants the keyboard and the console at the same time
cannot have both as the board is wired today. Such a test has to be split in
two, or take its evidence from one side only. Why the two exclude each other is
not established here; that they do is.

### The sleep, seen from the other side

**The monitor goes into its own standby and comes back.** The sleep had been
set to never, which is why it appeared to do nothing overnight: that was the
setting and not the mechanism. Set to fifteen seconds, with nobody touching the
board's keyboard or mouse, the monitor went into standby by itself, and a key
pressed at the board brought the picture back. Both directions were seen. The
section above records the fabric entering the mute and leaving it at a frame
boundary, measured from inside, and says that nobody was watching the monitor
at the time; that is superseded here, and the two are the same event read from
the two sides.

Two further things are inside that one result. The sleep on this board stops
the clock the fabric hands the transmitter rather than holding lanes of its
own, and the transmitter's register program is written again at every wake, so
a monitor that locks again afterwards says the program ran a second time and
was taken. And only a key or the mouse at the board is allowed to wake it,
which is a decision `cadr-terminal` makes rather than the fabric; the wake is
therefore a second reading of the same input path the typing runs.

### What this does not establish

**Five signals that would report the transmitter's state and the display's own
faults still reach no register on any board.** The transmitter's `configured`
and `failed`, and its count of the registers the part acknowledged, together
with the display's sticky `underrun` and its read-error bit, all go into an
unused fold in the board's top level, and no console command reports any of
them. So whether the two-wire program was acknowledged byte by byte is still
not established, and neither is whether the display has ever been starved. **A
static screen being starved looks exactly like one being fed**, which is what
that sticky bit exists to tell apart. A picture therefore remains the whole of
the evidence that the display is being fed correctly, and this session adds a
person's eye to it rather than an instrument. One console word would carry all
five.

**The geometry was read against a description and not measured on the glass.**
What was compared is one board's picture with another's, by an eye that knows
both. The pattern test — writing a run of known words into the display's window
and seeing a bar appear where the arithmetic says it must — would measure it,
and it has not been done.

**The part's stamp was not read again.** The cable that reads it was out, so the
bitstream under the monitor is taken to be the one the section above
downloaded, on the grounds that a configured part is not disturbed by
unplugging the cable. Nothing in this session read it back.

**The keys came over the terminal's input link and not from a viewer.** In
`screen_server.c` a key from the link and a key from a viewer enter the same
queue, the same mapping, the same pacing and the same register writer, and they
differ only in the message that carries them; but that is what the source says,
not what this session showed. No viewer's key or pointer event has been carried
on this board.

**The serial line on this board has still carried nothing.** The second display
board, the two rotations and the output selection are all built and none of
them has been seen here.

### What this settles, and what it does not

**The display output block is shown on this board.** The section above names
what would move it, before the evidence existed: confirming the geometry at the
monitor, or the pattern test. The geometry is confirmed, and the typing does
more than confirm it, since it ties the pixels at the connector to the
machine's own memory in the one direction a coincidence cannot run.

**The USB input block is shown.** The whole of what the block does — reading
the board's own keyboard and mouse and putting them onto the I/O board through
the terminal — has now happened on this board, and the keys and the pointer
arrived in the machine.

**The terminal block is shown.** The section above holds it back for one
stated reason, that its path into the machine was untouched; that path carried
this session's keys and pointer motion. Its other half, the RFB server's
screen, was read from the build host in that same session.

**The I/O board is still not shown whole.** Its keyboard and its mouse have now
carried a person's typing, and its Chaosnet registers carried a round trip in
the session above, so the reason given there — that only its Chaosnet half had
been used — no longer holds as written. The rule behind it does: a block counts
as shown when the block has been shown and not when a part of it has. The
serial line on this board has carried nothing, and no reading here covers the
card's two clocks. A character on the serial line would settle it.

**The TV block and the Color TV block are not shown whole either.** The machine
painting a screen that reaches the glass says the machine paints, which the
session above already had; nothing here reads the TV's scan counters or its
mode register, and no color screen has been composited on this board.

**The serial block is not shown**, its line having carried nothing.

## The DE25-Nano's flash, and a boot from power alone, 21 September 2026

This board's QSPI flash now carries this project's phase-1 bitstream. The board
comes up from power on its own, with nothing attached to it but a monitor and a
keyboard, and runs its band. Before this it came up on the image the maker
shipped in that flash, which has no CADR in it, and every power-on needed a
cable and a download.

**What the flash holds.** The phase-1 bitstream in it was built at commit
`f5ca348`, HPS-first, with the processor's first-stage loader from the same
build as the card's contents. `QSPI_OWNERSHIP` is `HPS`, which gives the flash
controller to the processor; the other value is what the shipped image sets,
and a kernel that finds the controller owned by the device manager dies on the
driver's first register read.

**The two phases agree on the processor's I/O settings, and the tools say so.**
`quartus_pfg` reports an I/O hash for each image it writes and checks a pair
against each other, and that hash is what says a phase-1 bitstream and a core
bitstream came from one processor configuration. The image written to the flash
and the `cadr.core.rbf` on the card both report `26EE4912...`. A pair that
disagrees is a pair the processor will not configure the fabric from.

**The card needed two changes and they were made from the running board.** Its
boot partition was remounted read-write by the board itself, `cadr.core.rbf`
was added under the board's own folder, and `uEnv.txt`'s `cadr_fabric_loaded=1`
was commented out, since the fabric is no longer configured before U-Boot runs.
Both files were fetched by the board's own TFTP client, each was verified by a
digest read back off the card, and the partition was remounted read-only. The
card never left the board.

**It cold-booted.** The power was pulled and the board came back by itself,
running its band, with its picture on the monitor again. Everything the band
needs was therefore in place: the fabric configured from the card, Linux up,
and the programs started from the card's own file of flags. No cable and no
build host were in the path. Every earlier display reading on this board came
from a boot a cable had started, so this is the first time the whole chain has
been shown with nothing else attached.

**Two statements in the sessions above are superseded.** "A band on the
DE25-Nano" and "The DE25-Nano's display on a monitor" each say that the board
still needs a cable at every power-on because its flash has not been written.
Both were true when they were written.

**The recovery path was run rather than asserted.** The flash was written with
this project's image and verified; the factory image was then written back over
it and verified against a copy read off the board beforehand; and this
project's image was written again. So a bad image in this flash is a repeat and
not a brick. The part takes a JTAG download whatever the flash holds, because
the programmer puts its own helper design into the fabric and reaches the flash
through that, which is how the flash is reached at all.

**Each write was checked by reading the whole flash back** and comparing it
with the file that had been written, rather than by the programmer's own report
of what it had done.

**There is no copy of the factory image here any more.** The copy read off the
board, 16,777,460 bytes and identical on two reads, was lost. Recovery from now
on means fetching the maker's published image from its resource package. That
is possible because the copy read off the board matched that published file
byte for byte apart from the file's own trailer, which was measured while the
copy still existed. The published file will not program this part as it stands,
for the reason below, so such a recovery needs the image packaged again with a
flash loader this part accepts. That repackaging has not been done or tried.

**Two traps here read as a broken board.** The maker's published image names
flash loader `A5EB013BB23B` and the IDCODE `0xC362C0DD`, where this part
answers `0x4362C0DD`, and the programmer refuses it; the loader that works is
`A5EB013BB23BCS`. And the part's index in the JTAG scan chain moves with what
the part is holding. It is 2 with a design that has the processor in it,
because the processor's debug port joins the chain during configuration, and 1
with the programmer's helper design or with the part unconfigured. A wrong
index is reported as `Error (213001): Device name <garbage> is illegal`, which
names neither the index nor the chain.

**And the programmer's report of which build the part holds is not a witness.**
It reported one build's stamp before and after three downloads of differently
stamped images, and reported it again while the part was holding the
programmer's helper design. The readings recorded in the sessions above did
change with their downloads: two took the part from `ffffffff` to the new
build's stamp, one of those recording the JTAG chain going from one device to
two as it happened, and one took a configured part from one build's stamp to
another's and was corroborated by a second reader that found the part holding
the build it named. What separates a reading that follows the part from one
that does not has not been established, and until it has, this is the project's
only witness that a download took at all. It wants a session of its own.

### What this does not establish

**Nothing inside the board was read while it cold-booted.** The cable that
reads the part's stamp also carries the processor's serial console, and it was
out, as it must be when the keyboard is in. So the evidence for the cold boot
is what a person saw at the monitor, and no counter, tally or status word
stands beside it. This family gives the fabric no way to read its own stamp, so
there is no reading from inside to be had in any case.

**What the flash holds is established by reading the flash**, against the file
written, and by nothing the board says about itself.

**The earlier account of why the kernel died is superseded**, and this session
does not re-test it. "The first-stage loader decides whether this kernel lives"
above attributes the death to the first-stage loader, on nineteen deaths under
one loader and six clean boots under another. The correlation was real and the
cause was wrong: the loader and the fabric image had changed together, and the
variable is the fabric image's ownership of the flash controller. With this
project's image in the flash, neither the shipped loader nor the shipped image
is in the path any longer, so nothing here tests either.

**No boot from the flash has been read from the console.** The console and the
keyboard cannot both be attached, and the keyboard was in, so the boot the
flash starts has been seen at the monitor and not on the console.

### What this settles, and what it does not

**The board is a standalone board now.** It needs power and nothing else, which
is what the two Zynq boards have had since their cards were written, and the
first phase is the last part of this board's boot chain that a cable was still
supplying.

**Nothing about the machine changed here.** This is a session about
configuration and about what the part holds, and the machine, its fabric and
its band are the same as in the sessions above.

## A write over the ribbon, 21 September 2026

A word was written into one board's machine by the other board's machine, over
MIT's debug cable on the ribbon between the two Pmod JA connectors, and read
back on the far board's own console. Before this every reading the cable had
carried was a read. The boards are an Arty Z7-20, which took the debugger's
role, and a Cora Z7-07S, which was the debuggee, and each was running its own
Lisp world throughout.

**Both boards carry the guarded carrier, and the ribbon was not touched.** Each
board's own console printed the stamp the bitstream carries: the Arty Z7-20 was
running fabric `44eff450` and the Cora Z7-07S `0966ffd0`, each with a clean
tree. Neither is the tree's own commit, and the question that decides whether
this session says anything is whether the cable's own logic differs.
`cadr_dbg_tx.sv`, `cadr_dbg_rx.sv`, `cadr_dbg_join.sv`, `cadr_dbgin.sv` and
`cadr_busint_regs.sv` are byte for byte the same at those two commits and at
the tree's head, and `cadr_dbg_cable.sv` differs between them by one comment
and not a line of logic. So the carrier under all of this is the one signal to
a pair that `docs/debug-cable.md` describes, and it is the carrier the tree
describes.

**The wiring was found again.** Both boards rest as debuggees with nothing
driving the connector, which is what two boards on a ribbon look like whether
the ribbon is there or not, so the first thing done was to give one board the
role. Under `auto` it read `crossover, detected` within three seconds and said
the far end was answering; the far board read that a debugger was on the
connector, and not that the two ends disagreed. Neither machine noticed, and
both went on running Lisp.

**The forms are MIT's own.** `sys/cc/ldbg.lisp` on the band these boards run
gives the sequence for a cycle on the debuggee's Unibus: write the modifier
register at `0o766110` with address bit 17, write the address latch at
`0o766114` with the address shifted right one place, then read or write
`0o766100`. Those three were typed at the debugger board's own Lisp Listener as
two functions, a reader and a writer, and every reading below was made with
them. `cadr_dbgin.sv` builds the same address, `{modifier[0], address, 1'b0}`.

**The status strobe first, as the control.** A Unibus read of `0o766104` gave
`0o177400` twice and `0o177500` once, which is `0xff00 | status` with the far
interface's own busy bit moving under a machine that is running. An unplugged
connector would have given `0o177777`, the debugger's own timeout. This repeats
the 15 September reading on this carrier and establishes nothing new.

### All sixteen diagnostic registers, read over the guarded carrier

The far machine was halted from its own console first, so that no instruction
had been forced and both readers look at the same instant. Its console reported
not running, with the microcycle counter reading the same figure twice two
milliseconds apart. Then each of MIT's sixteen registers was read over the
ribbon, at `0o766000` plus twice the register number, and compared with
`cadr-console regs` on the far board at that same halt.

| register | over the ribbon | the far board's own console |
|---|---|---|
| `IR-LOW` | 423 | `0x01a7` |
| `IR-MED` | 0 | `0x0000` |
| `IR-HIGH` | 2048 | `0x0800` |
| (open) | 65535 | `0xffff` |
| `OPC` | 284 | `0x011c` |
| `PC` | 1474 | `0x05c2` |
| `OB-LOW` | 55086 | `0xd72e` |
| `OB-HIGH` | 2561 | `0x0a01` |
| `FLAG-1` | 63488 | `0xf800` |
| `FLAG-2` | 49367 | `0xc0d7` |
| `M-LOW` | 942 | `0x03ae` |
| `M-HIGH` | 2560 | `0x0a00` |
| `A-LOW` | 942 | `0x03ae` |
| `A-HIGH` | 2560 | `0x0a00` |
| `STAT-LOW` | 0 | `0x0000` |
| `STAT-HIGH` | 0 | `0x0000` |

Sixteen of sixteen. The Listener prints decimal and the console prints
hexadecimal, so a row is one word written two ways. The two paths share the
register and nothing else: one is MIT's cable on the ribbon, the other is that
board's own console on its own general-purpose port.

`FLAG-2` agrees exactly here where the 15 September session had it differing by
one bit. That difference was CC's own correction of JC-TRUE and not the cable's,
and nothing in this session runs the correction, so the two readers are reading
the register verbatim and agree on it.

This is `-DB NEED UB`, the strobe that runs a cycle on the debuggee's Unibus,
and it is the one thing the guarded carrier had never carried. What had crossed
it before was a status strobe, which is acknowledged the instant it is made and
runs no cycle at all.

### The write, and the path it was read back on

**The reader was named before anything was written.** A read that goes wrong
gives a wrong answer and a comparison catches it; a write that goes wrong
changes the far machine and nothing compares it afterwards. So the read-back is
the far board's own console, which reads `MD` out of the console face on its own
general-purpose port, and never the cable that did the writing.

The target is `MD`, reached by `-UB TO MD`. CC's own `CC-WRITE-MD` writes map
register octal 16 with `0o177000`, which is valid, write-enabled and the five
high ones that address `MD`, and then writes the low half-word at `0o174000` and
the high half-word at `0o174002`. Such a cycle never takes the Xbus and spends
no microcycle, so it writes a register of the far machine and touches no memory
at all.

| | |
|---|---|
| map register octal 16, read over the ribbon before anything | 0 |
| written over the ribbon | `0o177000` |
| `MD` on the far board's own console, before | `0x0a0005c2` |
| written over the ribbon, low half then high half | 23235 and 42300 |
| **`MD` on the far board's own console, after** | **`0xa53c5ac3`** |
| written over the ribbon, the original halves back | 1474 and 2560 |
| `MD` on the far board's own console, after that | `0x0a0005c2` |

The word `0xa53c5ac3` has each half the complement of the other, so neither is a
value the machine could have been left holding and neither half can be mistaken
for the other. It arrived whole, all thirty-two bits of it. The map register was
put back to nought afterwards and read back as nought.

**The write spent no microcycle and moved nothing else.** The far board's own
microcycle counter read `1091826969744` before the write and the same figure
after it, its program counter stood at 2702 either side, and its virtual address
register did not move. That is what `-UB TO MD` is supposed to do and it is
measured here rather than argued.

### The far machine stepped and started over the cable

CC's control vocabulary is writes to the clock control register, which is
`0o766006` on the debuggee's Unibus. With the machine halted, `2` then `0` is
`CC-CLOCK`, one microcycle, and `1` is run. Both were written over the ribbon
and counted on the far board's own console.

| | |
|---|---|
| the far board's microcycle counter, before | 1091826969744 |
| `2` then `0` written over the ribbon | |
| the far board's microcycle counter, after | 1091826969745 |
| its program counter | 2702, then 2703 |
| `1` written over the ribbon | |
| the far board afterwards | running, 12,489 microcycles in 2,000 microseconds |

Exactly one microcycle, counted by the machine that ran it. A silent no-op and a
silent runaway are the two failures this project keeps meeting, and a counter
that moves by one tells all three apart. The rate after the start is the rate
that board runs at.

**The far machine's Lisp world kept its place.** Its screen afterwards carries
its own Lisp Listener reading at top level, with a live who-line, and its idle
counter had not been reset, so nothing had typed at it.

### None of it went through the register window

The far board's own register window, read while it was the debuggee, names
itself `DBUG` and its fault word reads `0x00004000`: the marker, a request count
of nought in the high half and all three sticky faults clear. So the window
served no request at all, and what carried the sixteen reads, the six writes,
the step and the start was the ribbon and nothing else.

**No frame was refused.** Both boards read 0 refused against a saturated 65,535
heard, before the session and after it, across every reading above. The heard
counter saturates within a tenth of a second of a connect and is not a rate; the
refused counter is a total since the fabric came up, and on this ribbon it
stayed at nought on both boards.

### What this does not establish

**CC itself was not run.** What crossed the cable is CC's own sequences, read
out of `ldbg.lisp` and `lcadrd.lisp` and typed at a Listener by hand: the cycle,
the register reads, `CC-WRITE-MD` and `CC-CLOCK`. The program was not loaded and
none of its state-saving ran, so nothing here says that a CC session works over
this carrier, only that every cycle such a session is built out of does.

**The halt came from the far board's own console and not over the cable.** A
machine to be read has to be halted first, and it was halted the safe way so
that the two readers would look at the same instant. The start and the step did
go over the cable.

**Nothing was written to the far machine's memory.** `-UB TO MD` writes a
register and takes no bus, which is why it was chosen: it is the deepest write
this cable makes that leaves the far machine's memory untouched. A mapped write
that lands in main memory is a different cycle and has not crossed a ribbon.

**Nothing was measured about the cable's timing.** No beat rate, no round trip
and no comparison against the 11.05 microseconds the debugger's own interface
allows a cycle. Those figures are still arithmetic and the checks' own
measurements.

**The two frames one board refused in the 15 September session are still
unexplained**, and this session added none to either board.

### What this settles, and what it does not

**The guarded carrier carries the debugger and not merely a strobe.** Every
register of MIT's diagnostic block crossed it and agreed with the far board's
own console, and the far machine was stepped and started over it.

**A write crosses it, and the word arrives whole.** That is the direction
nothing had exercised, on either board pair and over either carrier, and the
reader is a path that shares nothing with the writer.

**Nothing about the fabric changed here**, and nothing about either board's
bitstream. Both boards were left running their own bands, as debuggees with
nothing driving the connector, which is how they were found.

## The DE25-Nano over TFTP, 22 September 2026

The DE25-Nano booted over the network. Its card was told to name a TFTP
server, the board was reset, and it fetched the boot command, the fabric's
image, the device tree, the kernel and the root filesystem from that server by
itself, configured its fabric from what it had fetched, started Linux and came
up running its band. The card was then put back as it was, and the board was
reset again and came up from the card. Both boots were captured on the serial
console.

This is the path the board's own boot environment has always described and
that nothing had run. The account below is of one session, and every number in
it was read off the console.

**The board was found on the card path.** Its `uEnv.txt` named no server, so
`cadr_try` took the `else` branch and `cadr_card` loaded everything off the
FAT partition. The card is this board's development card and still has the old
two-partition shape: the boot partition is mounted read-only at `/mnt/card`
and the drive bay read-write at `/mnt/packs`. So the edit below needed a
remount, where on the one-partition card a release ships the partition is
already read-write and a copy is enough.

**The served set was made byte-identical to the card's.** The five files
`uEnv.net` asks for were put in a directory named for the board on the TFTP
server, and the four that also exist on the card were checked by digest
against the card's own copies rather than against the build they came from.
They matched. So the test compares two paths and not two sets of files, which
is the only way its answer means anything: a network boot from a different
kernel would boot and would say nothing about the path.

**The way back was established before the card was touched.** The risk is
stated in `uEnv.net`'s own header: the network path never falls back to the
card, so a board whose card names a server it cannot reach loops in the loader
for ever and Linux never starts, which leaves the board unable to repair its
own card. Two things were shown on the board first, and neither needs the
network. U-Boot offers three seconds of `Hit any key to stop autoboot` on
every reset, before `bootcmd` runs and therefore before the loop can begin; a
byte sent in that window gives a prompt. And at that prompt `run cadr_card`
boots the board off its card whatever `uEnv.txt` says, because `cadr_card`
never reads `serverip`. Both were run, and the second one booted the board to
a login prompt. A copy of the original `uEnv.txt` was also put on the
read-write partition, so the repair itself needs nothing off the board either.

**Then the path was run by hand from that prompt, with the card untouched.**
`setenv serverip <the TFTP server>` and `run cadr_net` fetched all five files
and booted. That proved the path before anything on the card depended on it.

**The card was then edited from the running board.** The new `uEnv.txt` was
generated from the tracked template by the same substitution the card script
uses, and the control is that generating it with no server reproduces the
card's own file byte for byte. The board fetched the new file, the boot
partition was remounted read-write, the file was written, the partition was
remounted read-only, and the digest was read back off the card. The card never
left the board.

**The board then took the network path on its own.** The console said `cadr:
uEnv.txt names a server; fetching over TFTP`, and what followed was five TFTP
transfers, the fabric's four steps, and Linux:

    de25-nano/uEnv.net                            1,568 B
    de25-nano/cadr.core.rbf                   2,125,824 B   5.5 MiB/s
    de25-nano/socfpga_agilex5_de25_nano_cadr.dtb 23,737 B   2.8 MiB/s
    de25-nano/Image                          41,921,024 B   5.5 MiB/s
    de25-nano/rootfs.cpio.uboot               4,619,731 B   5.4 MiB/s

That is 48,691,884 bytes over the network. `...FPGA reconfiguration OK!` came
after the fabric's image, as it does on the card path, so the CADR entered the
fabric from a file the board had just fetched.

**`uEnv.txt` was read off the card twice, and the console shows both reads.**
`1979 bytes read in 16 ms` appears once before the DHCP broadcasts and once
after the bind. That is the second import the environment does deliberately,
so that a lease cannot displace the server the card named, and this is the
first time it has been seen happen. The 1,979 bytes are the card's own file
with the server line in it; without that line it is 1,943.

**From the reset to the login prompt took 28 seconds, against 25 off the
card.** Both were measured on this board in this session, from the first line
U-Boot's first stage prints after the reset, with the same logger:

    from the reset          over TFTP    off the card
    autoboot expires           4.0 s         4.0 s
    the fabric configured      9.8 s         5.6 s
    the kernel started        17.2 s        14.0 s
    the login prompt          28.4 s        25.0 s

**Nearly all of the difference is the link coming up, and it is not the
transfers.** The bind took 3,534 ms in the run above, and the console says why:
`Waiting for PHY auto negotiation to complete.. done` comes first, and then
five BOOTP broadcasts are sent before one is answered. Two binds taken by hand
from the U-Boot prompt in the same session, on a link that was already up from
an earlier `dhcp`, printed no negotiation line, needed one broadcast, and took
3 ms and 4 ms. So the 3.5 seconds is what a cold link costs, which is the real
case, and 28 seconds is one honest measurement of one boot rather than a figure
to hold the path to. The transfers themselves were marginally faster than the
card's reads, at 5.5 against 5.2 MiB/s for the fabric's image and 5.5 against
5.4 for the kernel.

**Every program came up as it does on the card path.** The tree reserved the
CADR's 128 MB at `0xB0000000`, the clock came back from the drive bay, the
drive came present with a labeled pack on unit 0, and the screen, the serial
line, Chaosnet at 177203 and the USB input program all started. ozd stayed off,
because this card's file of flags says `--no-ozd`.

**The card was put back, and the board came up from it.** The original
`uEnv.txt` was written back from the copy on the read-write partition, its
digest was read off the card and matched, the partition was remounted
read-only, and the temporary copy was removed. The board was reset and took
the card path: no server line, no DHCP, no `Filename`, and the five
`bytes read` lines it has always printed. The machine was then halted, read,
and started again, and it is running its band.

### What this does not establish

**The fabric was not identified from inside the board.** This part gives the
fabric no way to read its own stamp, so `cadr-console status` reports no build
stamp whatever is configured, which the flash session above already recorded.
What identifies the fabric here is the file: `quartus_pfg -i` on the
`cadr.core.rbf` that both paths loaded reports `JTAG user code: 0xF5CA3480`,
which is this project's stamp for commit `f5ca348` with a clean tree. That is
a reading of a file on the build host and not of the part, and nothing in this
session corroborates it from the board.

**So the bitstream and the tree are not the same commit, and the reason that
is tolerable here is narrow.** The fabric is `f5ca348` and the tree is thirty
commits later. What this session tests is the loader, and the
three files that define the boot path --- the board's U-Boot environment, the
served boot command and the card's template --- have not changed in any of
those commits. They are byte-identical between the two, which was checked
rather than assumed. Nothing here is evidence about the fabric's logic, and a
session about the machine would need a bitstream of the tree.

**The card was not written from a reader and no release card was made.** The
one file that changed was written by the board onto its own card and then
written back. The card script was not run, and no zip was built or unpacked.

**No release or standalone card was booted over the network**, because a
release card carries no server and is the card path by definition.

**The DHCP server was not exercised as a fixture.** This board has no MAC of
its own: U-Boot makes a fresh locally administered one at every boot and Linux
carries whatever U-Boot made, so the board's address changes from boot to
boot. The boot above worked with a lease the server chose. A pinned lease was
not tried and `ethaddr` was not set.

**Nothing was measured about the TFTP server's behavior under load**, and no
failure of the path was induced. The board was never made to loop, so the
message the loader prints when a fetch fails was not seen in this session, and
the ten-second retry was not observed.

### What this settles, and what it does not

**The DE25-Nano's network boot path runs on the board.** Every step in it
happened: the card's file chose the path, DHCP gave the board an address, the
boot command came from the server, the fabric was configured from a file
fetched over the network, and the kernel and the root filesystem followed it.
The path is no longer something built and not run.

**The fabric can be configured from the network.** That is the step this board
has that the Zynq boards' path does not exercise the same way, since it runs
through the processor's own configuration of the fabric rather than through a
bitstream loader, and it ran here with the image arriving over TFTP.

**A card that names a server is recoverable from the console alone.** The
three-second window and `run cadr_card` were both run, in that order, before
the card was changed. That is now a known way back and not an assumption.

**Nothing about the machine changed here.** The fabric is the one the board
was already running, the band is the same band, and the card's boot partition
ends the session byte-identical to how it started. The drive bay was written
to only by the band itself, as it is whenever the board runs.
