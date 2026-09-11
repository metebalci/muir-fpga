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
resets it on the MMCM's lock or BTN0. It therefore starts the instant the part
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

LD4 carries the witness's own verdict on a `PROVE` board. It blinks red for a
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
hold. LD0 and LD1 say which.

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

## What the LEDs say

    LD0   the fabric is clocked           free-running, about 1.5 Hz at 100 MHz
    LD1   microcycles are retiring        beat[19], ~0.5 Hz with no memory
    LD2   NXM timeouts, at their rate     nxm_count[16], not the flag itself
    LD3   the datapath is moving          witness, a ~700-bit fold
    LD4   where the boot has got to       red not running, blue PROM, green PROMDISABLE
    LD5   was the last cycle answered     red the timer ended it, green a slave did,
                                          blue if S_AXI_HP0 refused it

**Every rate below LD0 is in the machine's own time, and a wristwatch reads
twice as long.** The tick is 10 ns rather than 5, so the machine runs at 50%
of the speed the hardware ran; every tick count in it is unchanged, which is
why none of the simulations these figures come from moved. A period given here
as 0.78 s is 1.56 s at the board, and 118 ms after reset is 236 ms. LD0 is the
exception because it counts fabric ticks and not microcycles, and its line
above is already real time.

**LD0 and LD1 are the two that earn their place.** Between them they say
whether the fabric is clocked and whether the machine is executing. That is the
whole of "is it working", and it is readable across a room. The other four are
bring-up instruments and will change as the machine grows.

**LD2 shows a rate, not a flag.** `timed_out` is a level that stands only while
an unanswered cycle is up. That is a sliver at the end of each 4.25 us timeout,
and it integrates to a light too faint to read. The board showed exactly that.
Counting its rising edges and lighting a bit of the count makes the rate
visible.

**And memory will not change it.** An earlier version of this paragraph said
"dark means timeouts have stopped, which is what a working memory looks like".
That was a prediction, and measured against a DDR model it is wrong. The boot
PROM's only main-memory traffic is 512 cycles, an identity copy of page 0. The
other 16,951 bus cycles are polls of a disk controller that DDR cannot answer.
Memory removes exactly 512 timeouts, once, in 380 us at 118 ms after reset.
After that, every cycle the machine makes is one of the polls. LD2's rate is
**identical** with and without memory, at 0.78 s a period, about 168 kHz. LD5
is green for those 380 us and red for ever after.

**And nothing else on the board changes either.** That is the stronger
statement, and it is the one that holds today. This paragraph used to end with
a halt. If bit 0 of the last word of page 0 was set, the PROM believed the disk
was ready, wrote one word and stopped at `ERROR-DISK-ERROR`, and LD1 and LD3
went dark. **That halt was a bug, and it is fixed.** `cadr_xbus_ddr` held its
`rdata` register past its own cycle, so every one of the 16,951 disk polls
loaded MD with whatever DDR had last returned. An unanswered read gives MD zero
now, decided and fixed at `05d28fa`. With that, 200 ms of machine time gives
852,515 microcycles and 514 timeouts **without** memory, against 862,932 and 2
**with**. LD1's blink moves by one part in a hundred, and nothing else moves at
all. (Those figures are with the disk controller's registers answering the boot
PROM's polls. Before `cadr_disk_controller.sv` existed the polls timed out, and
the same run gave 590,925 and 13,783.)

The lamps are therefore not how the memory path is checked, and they cannot be.
The evidence is `boards/arty-z7-20/vivado/ddr_run.tcl`'s four counters, read by
the debugger at the processing system's own boundary, together with page 0 read
back against the poison that was put there. The probe cannot answer it either.
It captures microcycles 0 to DEPTH-1, and the first `mem_req` is at 536,303.

**There are two signals called `nxm` and they mean opposite kinds of thing.**
The decode's signal says the *address* is Xbus space with nothing built there.
The bus interface's own register, carried out as `timed_out`, says *this cycle*
ended on the timer rather than on a slave. LD5 was first wired to the decode's
signal, and it came up **green on a board with no memory**. The reason is that
the boot PROM's traffic is 16,951 cycles to the disk registers at `0o17377774`,
which are in the decode's map and therefore not empty space. They are simply
unanswered.

LD5 latches `timed_out` now, which is the question anyone actually wants. Red
means the timer ended the cycle, and green means something replied. The signal
was there all along. The LED was reading the wrong one.

**And the same conflation explains LD2's rate.** LD2 counts `timed_out` edges.
On a board where nothing answers the disk polls it therefore counts **16,951 in
a boot-PROM run, not 2**. The 2 are the cycles whose *address* was empty space,
which is a different question. LD2 blinking steadily is the machine faithfully
polling a controller that is not built, at the rate the census predicts.

**LD0 is the one to look at first, and that is why it is first.** It answers
"is this running at all". Every other light is meaningless until it says yes.
Without it, "not programmed", "the MMCM never locked" and "the machine stalled"
are three different problems that all look like a dark board.

Read them in order:

    LD0 dark                  not programmed, or the MMCM never locked
    LD0 blinking, LD1 dark    clocked, but not retiring microcycles
    LD0 and LD1 blinking      the machine is running

This was observed on the board, with no memory and the boot PROM only: **LD0
blinking, LD1 blinking slowly, LD2 blinking, LD3 faint, LD4 blue, LD5 red.**
LD3 faint is correct. `witness` only toggles when the datapath changes, and the
machine spends almost all its time parked in timeouts. A faint LD3 is a machine
that is mostly waiting.

**With no memory behind `mem_*`**, the expected reading is **LD0 blinking, LD1
blinking very slowly, LD2 blinking at about 0.78 s, LD3 lit**. That is what a
`PROVE` board is, and what every build before the PS block landed was. An
earlier version of this line said LD2 would be "lit or dim". That was true of
the lamp while it showed `timed_out` itself, and it stopped being true when the
lamp started counting the edges.

An earlier version of this table said LD1 would be *dark*. The reasoning was
that with nothing answering `mem_*` the machine reaches its first main-memory
cycle and stalls there for ever. **That is wrong, and the board said so
first.** Nothing answering does not mean the cycle never ends. The NXM timer in
`cadr_busint_xbus.sv` expires at about 4.25 us, and the cycle completes as a
non-existent-memory reference. The machine keeps going. The timer is a real
part of the design doing its job, and it turns "no memory" from a stall into a
slowdown.

It was simulated afterwards to put numbers on it, with `cadr_machine` and
`mem_done` tied low, which is the step-1 bitstream exactly:

    first mem_req            microcycle 536,303
    NXM timeouts             514 in 200 ms --- the parity loop's 512 plus
                             the two cycles to empty Xbus space
    after the first cycle    0.26 us a microcycle, against 0.22 normal
    LD1 (beat[19])           toggles every 0.14 s

    (before the disk controller's registers answered the polls, the same run
     gave 13,783 timeouts, 1.49 us a microcycle and LD1 every 0.79 s; the
     16,951 polls each cost a 4.25 us timeout)

So LD1's period is a little over a quarter of a second. That is close to the
0.23 s it would be at full speed, because the boot PROM's 16,951 disk polls are
answered now and no longer each cost a timeout. LD2 is nearly dark. 514
timeouts in 200 ms is about 2.6 kHz, and 65,536 of them a toggle is a period
near a minute. **This is the reading the original prediction expected from
memory and got from the disk controller's registers instead.** The timeouts
that stopped were the polls, never the memory cycles.

`tb/cadr_nomem_tb.cpp` printed that line as `beat[23]` until `bffbe9c`. LD1 has
been `beat[19]` since `ad4a475`, and both now agree. What the testbench
measures is the microcycle rate. Which bit of the beat reaches the pin is
`boards/arty-z7-20/cadr_arty.sv`'s to say, and this table takes it from there.

**The general point is worth more than the correction.** The prediction was
that no memory means no progress. The fabric's answer is that no memory means
*slow* progress. That is the first behaviour anyone here observed on silicon
that was predicted wrongly, and it was predicted wrongly in this file.
