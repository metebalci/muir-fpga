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
`TCP::3121` unless `-s<url>` says otherwise. `-d` daemonises it.

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
looks like a missing initialisation. The first looks like a bitstream that did
not load, and the second looks like a broken memory path.

Two consequences, both deliberate in `boards/arty-z7-20/cadr_arty.sv`:

- **The fabric clock comes from an MMCM off the board's 125 MHz pin, not from
  the PS.** It runs the moment the bitstream loads. A bring-up where nothing
  moves until a second thing works has two unknowns in it. The MMCM makes
  100 MHz --- 125 x 8 at the VCO, divided by 10 --- so a tick is 10 ns.
  Every tick count in the machine is unchanged by that; `cadr_arty.sv`'s
  header is the whole argument.
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
The script recognises that reading and says so rather than blaming the design.

### Run every invocation under `timeout`

Xilinx's `mask_poll` waits for DDR-init-complete at `0xF8006054`. It gives up
after a hundred million reads. Over JTAG that is not a bound anybody will wait
for, and the routine is not ours to change. **A controller that never comes up
therefore hangs rather than failing.**

    timeout 600 ~/Xilinx/2026.1/Vivado/bin/xsdb boards/arty-z7-20/vivado/ddr_check.tcl

Exit 124 means the poll never finished. That is its own finding and not a
crash.

### The two identity registers, before anything is initialised

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

### Uninitialised DDR is not zero, so everything poisons first

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
configures, and reaches its memory cycles 118 ms of machine time later --- 236
ms of real time, the tick being 10 ns --- whether or not anybody has brought
the port up. Poisoning 256 words over JTAG takes longer than either.
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

The script records uninitialised DDR and re-reads one block to see whether it
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
address has bit 2 set for exactly that reason. Against a neighbourhood of
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
reach for on a Zynq board. BTN1 exists for the Arty A7-100, which has no
processing system and nothing else to reset it with, and for uniformity across
the boards.

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
whole of it is JA: four pins each way, one strobe and three data lines a
direction. The low four are the debugger's and the high four the debuggee's, so
a straight Pmod ribbon from this board's JA to another board's connector maps
every signal to its counterpart. The pads are bidirectional, because the role
is not fixed at synthesis.

**The far board's connector is not always JA.** The Cora Z7-07S uses JA as
this board does. The Arty A7-100 uses JB, because that board has four headers
and Digilent publishes two of them as high-speed while JA and JD are its
standard ports, with a series resistor in line with every signal. Every board
indexes a header's eight signals in the same order, so a straight ribbon still
maps each pin to its counterpart whichever headers the two ends are.
`docs/debug-cable.md` has the pins for all three.

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

**And the pins of a Pmod row are coupled pairs, which this link drives
single-ended.** An edge on one line can couple into the strobe beside it and
misalign a frame. A misaligned frame moves nothing and the next carries the
levels again, so what it costs is lost frames and never wrong values --- and how
often is a number nobody has. The fabric counts frames heard and frames
refused, and `cadr-console debug-cable` prints both. If the number turns out
bad the fallback is one signal per pair, which is a parameter and a pin map.

**A cable exists and the fabric's side of it has not been shown on silicon.**
Two boards were joined by one on 14 September and the cable turned out to be
mirrored, which is what the wiring setting is for; the fabric that answers it
has not been on a board since. `docs/debug-cable.md` is the whole of the cable.

## What the LEDs say

The six lamps read left to right as the machine's own progress.

    LD0   MACHRUN            lit means the machine should be running
    LD1   the fabric clock   the slow blink, about 1.5 Hz at 100 MHz
    LD2   microcycles        the fast blink, and it freezes when the machine does
    LD3   disk activity      lit while the controller moves a block
    LD4   ERRHALT            dark normally, red once the machine halts itself
    LD5   PROMENABLE         blue while the machine runs out of its boot PROM

**LD0 is a level and LD2 is a blink, and they say different things.** MACHRUN
is the machine's own run signal, the 9S42 at OLORD1 1A15. It drops during
every memory stall, `-WAIT` being one of its terms, so the lamp's brightness is
the fraction of time the machine computes rather than waits. A dim LD0 is a
machine that is thrashing. A level can be held high by a fabric that has
stopped, though. That is why LD2 carries the blink instead: motion cannot be
faked.

**LD4 is the machine's own error halt and nothing else. It is either off or
red.** No other colour and no other meaning ever reaches it, at power-on,
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
dark one means booted. Blue is the only colour it takes.

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

**Every rate here is in the machine's own time, and a wristwatch reads twice as
long.** The tick is 10 ns rather than 5, so the machine runs at half the speed
the hardware ran. Every tick count in it is unchanged, which is why none of the
simulations these figures come from moved. A period given as 0.14 s is 0.28 s
at the board. LD1 is the exception, because it counts fabric ticks rather than
microcycles and its figure above is already real time.

Read the first three in order.

    LD1 dark                  not programmed, or the clock never locked
    LD1 blinking, LD2 dark    clocked, but not retiring microcycles
    LD1 and LD2 blinking      the machine is running

**The assignment before this one was a bring-up instrument and is superseded.**
LD0 was the fabric's clock, LD2 counted non-existent-memory timeouts, LD3 was
the datapath fold, LD4 carried three boot states in three colours and then four
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
    LD2 (beat[19])           toggles every 0.14 s

    (before the disk controller's registers answered the polls, the same run
     gave 13,783 timeouts, 1.49 us a microcycle and the blink every 0.79 s;
     the 16,951 polls each cost a 4.25 us timeout)

So the microcycle blink's period is a little over a quarter of a second. That
is close to the 0.23 s it would be at full speed, because the disk polls are
answered now and no longer each cost a timeout.

`tb/cadr_nomem_tb.cpp` printed that line as `beat[23]` until `bffbe9c`. The
lamp has been `beat[19]` since `ad4a475`, and both now agree. What the
testbench measures is the microcycle rate. Which bit of the beat reaches the
pin is `boards/arty-z7-20/cadr_arty.sv`'s to say, and this table takes it from
there.

**The general point is worth more than the correction.** The prediction was
that no memory means no progress. The fabric's answer is that no memory means
slow progress. That is the first behaviour anyone here observed on silicon that
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

The second is `--no-auto-boot` in `fpgarc` on the pack partition. Nothing in the
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

The machine's clocks run at half real time, which is what the fabric says they
should. The who-line clock advanced 31 seconds over 61 real seconds. That is a
ratio of 0.508, and the readings are to the second, so it is a half. The
microsecond clock counts 200 ticks (`rtl/machine/cadr_io_board.sv`), and at a
10 ns tick that is one count every 2.0 real microseconds.

Two things are not shown yet. The serial port's registers are programmed and
its rate reads back, but characters do not flow, because the line's frame end
is presented early in `rtl/plumbing/cadr_serial_line.sv`. And nothing has
driven the debug cable from the board. So the terminal and Chaosnet blocks on
the drawing go green, and the I/O board keeps the colour that says checked here
and not yet on silicon. Both of those were shown later the same day, and the
section below supersedes this paragraph.

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
real time, and the machine runs at half real time at a 10 ns tick, so 15.0 is
the rate the fabric says it should be.

Every rate the chip offers was swept, with two bursts at each:

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
happens the drawing's USB input block says checked here and not yet on silicon.

## The display, the keyboard and the mouse, 14 September

**A monitor on the HDMI TX connector shows the machine's screen.** It is
1280x1024 at 60 Hz with the CADR's own 768x963 screen centred in it, white on
black, and the rest of the frame black. That is the display output block as it
was built and as `docs/display-output.md` describes it. The picture comes out
of DDR over `S_AXI_HP3` with no software anywhere in the path, so the block and
the port are both shown by the same monitor.

**A USB keyboard plugged into the board reaches Lisp.** `cadr-usb-input` reads
the keyboard as an evdev device and hands each key to `cadr-terminal`, which is
the one program that writes the I/O board's keyboard register and which paces
the words onto it. The keys arrive in the machine as a person typing at a
viewer's keys do.

**A USB mouse reaches it too.** Its movement and its buttons go down the same
path. The arrow on the screen follows the hand and a click registers in the
machine.

So every block on the drawing is now green. Nothing is turquoise.

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

That writes `build/hdmi/cadr.bit`. Serve it the way any other bitstream is
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

The machine's own screen, 768 by 963, centred in a 1280 by 1024 raster with a
black border 256 pixels wide on each side and about 30 rows deep above and
below. White on black.

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

**No signal at all, or the monitor reporting no input.** The serialisers are
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
and every read burst are checked against a modelled memory poisoned
injectively in the address, which is exactly the stimulus that makes a
misread show as noise rather than as black.

**A picture that tears when the machine draws.** Expected, and not a fault.
The machine writes the bitmap whenever it likes and the raster reads it
whenever it likes, with no buffering — which is what MIT's display controller
did. See `docs/display-output.md`.

**A stable picture with the wrong geometry — shifted, or wrapped diagonally.**
The monitor has picked a different mode from the one being sent. Check what it
reports the incoming timing as; it should say 1280x1024 at about 60 Hz.
