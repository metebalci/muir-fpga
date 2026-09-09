<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Reaching the board

The board need not be attached to the machine that runs Vivado. `hw_server`
owns the JTAG cable and speaks to Vivado's hardware manager over TCP 3121, so
the tools can sit on one machine and the Arty on another. That is the
arrangement here: Vivado on a machine with the memory for it, the board on
whatever is convenient.

## On the machine holding the board

Install **Hardware Server** from the AMD unified installer --- not Vivado, and
not Vivado Lab Edition unless you also want to program from that machine. It is
the smallest of the three and it is `hw_server` plus the cable drivers.
Its version should match the Vivado it will talk to; mixing them sometimes
works and is a poor thing to be debugging on a first bring-up.

    ~/Xilinx/<version>/HWSRVR/bin/hw_server

There is no `settings64.sh` in that install; call the binary by its path. It
listens on `TCP::3121` unless `-s<url>` says otherwise, and `-d` daemonises it.

## The udev rules, which are not optional

The Arty Z7-20's JTAG is an onboard FTDI FT2232H, `0403:6010`, reporting
`manufacturer = Digilent`. Without rules its device node is `crw-rw-r--
root root`, so `hw_server` running as an ordinary user can read it and not
write it. **The symptom is not a permission error.** The server starts,
Vivado connects to it, and then:

    ERROR: [Labtoolstcl 44-199] No matching targets found on connected
    servers: <address>

which reads like a cable or a network problem and is neither.

The rules ship with Vivado, so take them from a machine that has it rather
than writing them:

    <Vivado>/data/xicom/cable_drivers/lin64/install_script/install_drivers/
        52-xilinx-digilent-usb.rules
        52-xilinx-ftdi-usb.rules
        52-xilinx-pcusb.rules

    sudo cp 52-xilinx-*.rules /etc/udev/rules.d/
    sudo udevadm control --reload-rules && sudo udevadm trigger

Then **unplug the board and plug it back in.** udev applies rules on `add`, so
a device already enumerated keeps the permissions it was born with, and the
whole thing looks unchanged until it is replugged. The device number changes
when it works.

The rule that does the work is

    ACTION=="add", ATTRS{idVendor}=="0403", ATTRS{manufacturer}=="Digilent", MODE:="666"

`:=` rather than `=` so that a later rules file cannot lower it.

## From Vivado

    open_hw_manager
    connect_hw_server -url <board-machine>:3121
    current_hw_target [lindex [get_hw_targets] 0]
    open_hw_target

These are Tcl commands inside Vivado, not programs: run them in the Tcl
console, in `vivado -mode tcl`, or from a script with `-mode batch -source`.
Over ssh the last is easiest, and a long run wants `nohup setsid ...
</dev/null &` with a poll, since the session will not outlive it.

A working chain on this board answers with two devices --- the ARM debug
access port and the part itself:

    device: arm_dap_0   part=arm_dap
    device: xc7z020_1   part=xc7z020   idcode=0x23727093

If `get_hw_targets` finds none but the server connected, it is the rules
above, not the network.

## The console

The same cable carries a UART. Interface 0 is JTAG and belongs to
`hw_server`; **interface 1 is the console** --- `/dev/ttyUSB1` where
`ttyUSB0` is the JTAG channel. The rules above leave both world read-write,
so `dialout` membership is not needed. If that is too permissive, join
`dialout` and tighten the rule to `0660` instead.

`ftdi_sio` claims both interfaces and creates both nodes. That is expected:
libusb detaches it from the JTAG interface once it has write permission.

## Programming a bitstream

    open_hw_manager
    connect_hw_server -url <board-machine>:3121
    current_hw_target [lindex [get_hw_targets] 0]
    open_hw_target
    current_hw_device [lindex [get_hw_devices xc7z020_1] 0]
    set_property PROGRAM.FILE build/bitstream/cadr_arty.bit [current_hw_device]
    program_hw_devices [current_hw_device]

`vivado/program.tcl` does this and checks the answer. **What says it worked is
the DONE bit**, not the absence of an error: `program_hw_devices` can complete
against a device that did not take the configuration.

    refresh_hw_device [current_hw_device]
    get_property REGISTER.IR.BIT5_DONE [current_hw_device]

## A bitstream does not start the PS

**This is the one that will waste an afternoon.** Programming the PL over JTAG
configures the fabric and nothing else. The Zynq's processor system --- its
PLLs, `FCLK_CLK0`, the DDR controller, every `S_AXI_HP` port --- stays in reset
until `ps7_init` has run, which normally happens in the FSBL from a boot image
and does not happen at all when a `.bit` is downloaded on its own.

So a design whose fabric clock comes from `FCLK_CLK0` is *dead* on a
JTAG-programmed board, and a design that reads DDR gets no answer. Neither
looks like a missing initialisation: the first looks like a bitstream that did
not load and the second like a broken memory path.

Two consequences, both deliberate in `rtl/cadr_arty.sv`:

- **The fabric clock comes from an MMCM off the board's 125 MHz pin, not from
  the PS.** It runs the moment the bitstream loads. A bring-up where nothing
  moves until a second thing works has two unknowns in it.
- **Anything needing DDR is a debugger test and not a program-and-look one.**
  From XSDB: `connect`, `targets -set -filter {name =~ "APU*"}`, `source
  ps7_init.tcl`, `ps7_init`, `ps7_post_config`. **The order of those last two
  against the bitstream download is not free**, and it is not the same for a
  witness board as for the machine --- the next section has both, and the
  measurement each rests on.

## Bringing the memory up, in four steps

Four steps have been run on this board, in this order, each with a script that
is the record of it. Each adds exactly one unknown --- the processing system,
then the fabric writing, then the fabric reading, then the machine --- so each
is worth running only once the one before it has passed.

    vivado/ddr_check.tcl     the controller starts, DDR answers, no bitstream
    vivado/prove_write.tcl   the fabric writes a word, the debugger reads it
    vivado/prove_read.tcl    the fabric reads a word and echoes it, three cases
    vivado/ddr_run.tcl       the machine runs its boot PROM out of real DDR3

These are **XSDB** scripts and not Vivado ones, run from the repository root:
what they need is a debugger on the APU, not a hardware manager. Each takes
`BOARD_URL` for a remote board, `PS7_INIT` for the start-up routine and, from
step two on, `BIT` for the bitstream. Every line each prints is prefixed
`DDR:`, `PROVE:` or `RUN:`, and every failure names the address, the value
wanted and the value read before it exits 1 --- an exit code cannot tell two
failures apart.

### What has to exist first

The start-up routine, which is generated and not committed:

    vivado -mode batch -source vivado/gen_ps7_init.tcl
    # writes build/ps7/ps7_init.tcl

and, from step two on, a bitstream of the board that step is about:

    PROVE=1 OUTDIR=build/prove-write vivado -mode batch -source vivado/bitstream.tcl
    PROVE=2 OUTDIR=build/prove-read  vivado -mode batch -source vivado/bitstream.tcl
    DDR=1   OUTDIR=build/ddr         vivado -mode batch -source vivado/bitstream.tcl

**Step two's board and step three's are two different bitstreams with the same
file name**, one directory apart. Pointing step three at step two's produces
every symptom of a fabric that cannot read, on a perfectly good board; the
script recognises that reading and says so rather than blaming the design.

### Run every invocation under `timeout`

Xilinx's `mask_poll` waits for DDR-init-complete at `0xF8006054` for a hundred
million reads before giving up, which over JTAG is not a bound anybody will
wait for, and the routine is not ours to change. **A controller that never
comes up therefore hangs rather than failing.**

    timeout 600 ~/Xilinx/2026.1/Vivado/bin/xsdb vivado/ddr_check.tcl

Exit 124 is "the poll never finished", which is its own finding and not a
crash.

### The two identity registers, before anything is initialised

`0xF8000530` is SLCR `PSS_IDCODE`, the part's identity: it reads
`0x23727093`, the same word as the JTAG IDCODE above, off a different register
on a different path, and the low 28 bits of it are what is asserted. `0xF8007080` is devcfg `MCTRL`, whose
bits 31:28 are `PCAP_PS_VERSION` and are what `ps7_init`'s `ps_version` reads.
**They answer two different questions and the first guard written here
confused them**, asserting the IDCODE against `MCTRL` and stopping a good part
that read `0x30800100`.

Both are asserted, and identity first, because `ps_version` defaults
**silently**: it dispatches with 3.0 as the `else` branch, so a failed or
garbage read selects the 3.0 tables without saying so. A live `PSS_IDCODE` is
what says the version nibble came off a live PS at all. This board is silicon
3.1 --- `PS_VERSION = 3`, per `zynq_fsbl`'s `fsbl.h` --- and 3.1 shares 3.0's
tables, so it reaches that `else` branch **on purpose**.

    DDR: SLCR PSS_IDCODE at 0xF8000530 reads 0x23727093
    DDR:   device identity              0x03727093  wanted 0x03727093 (XC7Z020)
    DDR: devcfg MCTRL at 0xF8007080 reads 0x30800100
    DDR:   PCAP_PS_VERSION 31:28        3

### Uninitialised DDR is not zero, so everything poisons first

One word per megabyte across the whole 512 MB, read before anything had ever
been written to it on the first bring-up: bands of all-zeros and all-ones,
eleven or ten megabytes wide, repeating with a 64 MB period, with a handful of
lone flipped bits inside them. True and complement cells laid out by row. **So
an unwritten word reads `0x00000000` in some places and `0xFFFFFFFF` in
others**, and anything that takes either as evidence a write happened is
testing nothing.

Every step therefore fills the region it is about before the fabric can touch
it, and checks the fill took before going on. Steps two and three use the
proving word's own complement `0x75A3C91E`; step four uses 1,024 words
injective in the address, **with bit 0 clear in every one**, because bit 0 of
what an unanswered read leaves in MD is what the boot PROM's disk poll takes
for "the controller is ready".

Only the first run after a power cycle sees the bands. Nothing clears DDR
between runs, and written words survive a second full `ps7_init`, DDR
retraining included.

### The order, which is not the same for both kinds of board

`ps7_post_config` is the thing that brings `S_AXI_HP0` up: it writes
`LVL_SHFTR_EN` at `0xF8000900` and clears `FPGA_RST_CTRL` at `0xF8000240`.
**`SAXIHP0ARESETN` follows the level shifters and not `FPGA_RST_CTRL`** ---
measured at `700b98a` with the port live and a block poisoned: toggling
`FPGA_RST_CTRL` produced no write, writing `LVL_SHFTR_EN` `0x0` then `0xF`
produced the word.

**SLCR keeps `LVL_SHFTR_EN` across `ps7_init` and across a bitstream
download.** That one fact is a hazard for one kind of board and the mechanism
for the other.

The witness boards, `PROVE=1` and `PROVE=2`, are held in reset until the port
answers, so the port must be **dead** until the observer has laid its block
out:

    ps7_init -> clear LVL_SHFTR_EN -> program -> poison -> ps7_post_config
             -> read

Without the clear, a second run inside one power-on finds `LVL_SHFTR_EN`
already `0xF`, the witness fires the instant the part configures --- before the
poison lands --- and the block reads thirty-two words of filler, which looks
exactly like a fabric that cannot write. It cost one run at `700b98a`.

The machine, `DDR=1`, has no such trigger: `rtl/cadr_arty.sv` resets it on the
MMCM's lock or BTN0, so it starts the instant the part configures and reaches
its memory cycles 118 ms later whether or not anybody has brought the port up.
Poisoning 256 words over JTAG takes longer than that. So the port must be
**live before the bitstream loads**:

    ps7_init -> clear LVL_SHFTR_EN -> poison -> ps7_post_config -> program
             -> wait -> read

which works only because of the same SLCR fact, and `vivado/ddr_run.tcl` reads
`0xF8000900` again after programming and stops if it is not `0x0000000F`.
Measured on four runs at `1709d60`. No RTL change was needed for the start
problem.

**And the toggle re-arms a witness without reprogramming.** Writing
`LVL_SHFTR_EN` `0x0` then `0xF` is `SAXIHP0ARESETN`, so a `PROVE` board runs
its whole sequence again; that is how step three does three cases in one
session on one download.

### Step one --- the controller starts, and DDR answers

    timeout 600 ~/Xilinx/2026.1/Vivado/bin/xsdb vivado/ddr_check.tcl

No bitstream, and **no `ps7_post_config`**: this is the processor side alone,
and the point is that it depends on nothing this project built. What says it
worked is a read-back, because `ps7_init` **prints nothing** --- its version
lines are commented out in Xilinx's own output --- so its return says only
that no Tcl error was raised, and "no error" is not "DDR is up". The same
shape as the DONE bit above.

It records uninitialised DDR and re-reads one block to see whether it is
stable (recorded, not asserted --- there is nothing to assert), then writes the
proving word `0x8A5C36E1` at `0x18A72EE4` and its complement over it with the
low half of that beat asserted untouched, walks a one across every address bit
of the 128 MB region with everything written before anything is read, and
writes the top of the 512 MB so the whole part is known to have enumerated.

    DDR: PASSED --- the memory controller is up and DDR answers at 0x18000000
    DDR:   through 0x1FFFFFFF, with no bitstream and no
    DDR:   ps7_post_config.

Passed twice at `398edfc`, recorded in `700b98a`. A mismatch names the address:

    DDR: FAILED at 0x18A72EE4 --- wrote the word
    DDR: FAILED   wanted 0x8A5C36E1, read 0x00000000

### Step two --- the fabric writes, the debugger reads it back

    BIT=build/prove-write/cadr_arty.bit \
        timeout 900 ~/Xilinx/2026.1/Vivado/bin/xsdb vivado/prove_write.tcl

`PROVE=1` puts `0x8A5C36E1` at `0x18A72EE4` through the machine's own memory
port --- the same `cadr_axi_master` -> `cadr_axi_widen` -> `cadr_ps7` chain the
machine will use --- as soon as `SAXIHP0ARESETN` says the port can answer, and
then stops. Nothing in the design says whether it arrived. What says so is the
script, reading DDR through the processing system's own path, which shares
nothing with the fabric's.

**Pass is two things and the second is the one that can fail**: `0x18A72EE4`
holds the word, *and* every other word of the thirty-two still holds the
filler --- `0x18A72EE0` above all, the low half of the same 64-bit beat. The
address has bit 2 set for exactly that reason; against a neighbourhood of
zeros a widening that opened both halves would be invisible.

    PROVE: PASSED --- the fabric wrote 0x8A5C36E1 to 0x18A72EE4
    PROVE:   through S_AXI_HP0, and every other word in the block, 0x18A72EE0
    PROVE:   included, still holds the filler.  The low half of the beat is
    PROVE:   untouched, so the strobes opened one half and not two.

Passed three times at `700b98a`, recorded in `51bc74a`. Two failures worth
knowing before they happen:

- **thirty-two words of filler and nothing else.** The port was already live
  when the part configured and the witness fired before the poison landed, or
  `ps7_post_config` never ran. The clear of `LVL_SHFTR_EN` above is what
  prevents the first.
- **`0x18A72EE0` among the differing words.** The write opened both halves of
  the beat; the script says so and names `cadr_axi_widen.sv`'s strobes.

LD4 carries the witness's own verdict on a `PROVE` board --- blinking red for a
port still dead, steady red for live with nothing completed, green for
completed and right, blue for completed and wrong --- and nothing in either
script can read a lamp. The read-back is the honest observer anyway: a lamp is
the design marking its own work.

### Step three --- the fabric reads, and echoes what it read

    BIT=build/prove-read/cadr_arty.bit \
        timeout 900 ~/Xilinx/2026.1/Vivado/bin/xsdb vivado/prove_read.tcl

Three cases, one session, one download, **no button**. The fabric reads
`0x18A72EE4` and writes what it read, raw, to `0x18A72F18` --- seven beats
away, bit 2 clear, so the read takes a high half and the write-back opens a
low one. A raw word and not a match bit, because a match bit is the fabric
comparing against a constant the fabric itself holds, and a wrong lane and a
wrong constant agree with each other. A lane swap, a shift or a byte reversal
is visible **in the value**.

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

The echo beat gets a third filler of its own, `0x3C7A91D6`, or the `half`
case's echo of `0x75A3C91E` would be indistinguishable from no write-back at
all. `0x18A72F1C`, the other half of the echo's beat, must still hold it
afterwards.

    PROVE: case wrong PASSED
    PROVE: case half PASSED
    PROVE: case right PASSED
    PROVE: PASSED --- all three cases, in one session and one bitstream download.

Passed four times at `51bc74a`, recorded in `d2bbba5`. The failure to check
before any other, because it is not a fault at all:

    PROVE: FAILED   AND THIS IS WHAT A `PROVE=1` BITSTREAM LOOKS LIKE, which
    PROVE: FAILED   would be the wrong file and not a fault: nothing came

--- a step-two bitstream never reads, and puts `0x8A5C36E1` at `0x18A72EE4`
when the port comes live. Check `BIT=`.

### Step four --- the machine runs out of real DDR3

    BIT=build/ddr/cadr_arty.bit \
        timeout 900 ~/Xilinx/2026.1/Vivado/bin/xsdb vivado/ddr_run.tcl

`DDR=1` puts the processing system behind the machine's own memory port. The
boot PROM's whole main-memory traffic is `PAGE-0-PARITY-FIX`: it reads each of
the 256 words of physical page 0 and writes the same word straight back, 512
bus cycles between 118.0 and 118.4 ms after reset, and never touches memory
again.

**An identity copy leaves nothing behind.** Page 0 reading back unchanged says
the path did no harm; it cannot say the path was used, because a board whose
port is dead times all 512 cycles out and leaves page 0 exactly as unchanged.
No lamp can answer it either --- see below. And the processing system ships
nothing that could stand in: all 114 of its DDR controller's registers were
enumerated and none counts accesses, and Xilinx's own performance tooling
instantiates a counter IP in the fabric for exactly this reason.

**So the fabric counts, at the processing system's own handshakes.**
`rtl/cadr_mem_count.sv` keeps four fifteen-bit saturating counters --- what the
machine *asked* the port for, split by direction, and what the processing
system *answered*, `BVALID`/`BREADY` for a write and the last
`RVALID`/`RREADY` beat for a read. A fabric that never issued a transaction
cannot fabricate a B or an R beat, which is what makes the answered pair a
witness rather than the design marking its own work; and the asked pair is
what makes a zero readable, since `256 asked, 0 answered` is a dead port while
`0 asked` is a machine that never reached its memory.

They come out on EMIO GPIO and the debugger reads them at two registers:

    0xE000A068  DATA_2_RO  EMIO 31:0    bits 14:0  answered reads
                                        bit  15    1
                                        bits 30:16 answered writes
                                        bit  31    0
    0xE000A06C  DATA_3_RO  EMIO 63:32   the same, asked reads and writes

Nothing has to be configured to read them: both report the pin whatever the
direction registers say, `DIRM` comes up input, and `ps7_init` has already
turned the GPIO clock on --- bit 22 of the `0x01DC044D` it writes to
`APER_CLK_CTRL` at `0xF800012C`. On a passing run both read `0x01008100`: 256
in each fifteen-bit field, with the marker bit set.

**The marker bits are why the fields are fifteen bits and not sixteen**, and
they were put there because of what the negative control measured. Run against
a `DDR=0` bitstream --- a board with no tally in it at all --- both registers
read `0xFFFFFFFF`: with the level shifters on and nothing in the fabric
driving the EMIO pins, the processing system reads them all high. With the
shifters off it reads all zeros. **An absent instrument reads exactly like
four saturated counters**, and the failure would have been reported as "the
machine asked 65,535 times". `(w & 0x80008000) == 0x00008000` is a pattern
neither reading can produce, so the register says who wrote it.

The script reads the tally cold before anything is configured, where both
registers must read `0x00000000`, and again after the run:

    RUN: the tally, first read:
    RUN:   DATA_2_RO 0xE000A068 0x01008100   answered 256 reads, 256 writes
    RUN:   DATA_3_RO 0xE000A06C 0x01008100   asked    256 reads, 256 writes

Pass is 256 of each of the four, page 0 and the 768 words above it still their
poison on two identical reads, and both AFI0 overflow bits clear:

    RUN: PASSED --- the machine ran out of DDR.

Passed four times at `1709d60`. The three failures the script separates,
because they are three different faults that would otherwise look alike:

    RUN: FAILED   ALL ONES IS WHAT NOTHING-DRIVING READS.  With the level

the bitstream has no tally in it --- almost certainly a `DDR=0` build.

    RUN: FAILED   NOTHING WAS ASKED FOR, on a word the fabric did write:

the tally is there and the machine never reached its memory cycles: it is not
running, or it is not the machine the bitstream was meant to hold. LD0 and LD1
say which.

    RUN: FAILED   THE MACHINE ASKED AND NOTHING ANSWERED.  Every one of

every cycle ended on the NXM timer: a dead `S_AXI_HP0` --- the level shifters,
the port's reset, or the adapter held in it --- and not a machine that failed
to run.

### When the DAP wedges

Seen once, mid-`ps7_post_config`, and not reproduced:

    Memory read error at 0xF8000240. AP transaction timeout
    DAP (AHB AP transaction error, DAP status 0x30000021)

after which there is no APU target at all. `rst -por` is not supported for
that target; **`rst -srst` recovered it.** None of the four scripts tries to
recover on its own --- a script that reset the board on an error would be
guessing at which error it was.

## What the LEDs say

    LD0   the fabric is clocked           free-running, about 3 Hz at 200 MHz
    LD1   microcycles are retiring        beat[19], ~0.6 Hz with no memory
    LD2   NXM timeouts, at their rate     nxm_count[16], not the flag itself
    LD3   the datapath is moving          witness, a ~700-bit fold
    LD4   where the boot has got to       red not running, blue PROM, green PROMDISABLE
    LD5   was the last cycle answered     red the timer ended it, green a slave did,
                                          blue if S_AXI_HP0 refused it

**LD0 and LD1 are the two that earn their place.** Between them they say
whether the fabric is clocked and whether the machine is executing, which is
the whole of "is it working" and is readable across a room. The other four are
bring-up instruments and will change as the machine grows.

**LD2 shows a rate, not a flag.** `timed_out` is a level that stands only while
an unanswered cycle is up --- a sliver at the end of each 4.25 us timeout ---
which integrates to a light too faint to read; the board showed exactly that.
Counting its rising edges and lighting a bit of the count makes the rate
visible.

**And memory will not change it.** An earlier version of this paragraph said
"dark means timeouts have stopped, which is what a working memory looks like".
That was a prediction, and measured against a DDR model it is wrong: the boot
PROM's only main-memory traffic is 512 cycles, an identity copy of page 0, and
the other 16,951 bus cycles are polls of a disk controller that DDR cannot
answer. Memory removes exactly 512 timeouts, once, in 380 us at 118 ms after
reset, and after that every cycle the machine makes is one of the polls. LD2's
rate is **identical** with and without memory --- 0.78 s a period, about
168 kHz --- and LD5 is green for those 380 us and red for ever after.

**And nothing else on the board changes either**, which is the stronger
statement and is the one that holds today. This paragraph used to end with a
halt: if bit 0 of the last word of page 0 was set, the PROM believed the disk
was ready, wrote one word and stopped at `ERROR-DISK-ERROR`, and LD1 and LD3
went dark. **That halt was a bug, and it is fixed.** `cadr_xbus_ddr` held its
`rdata` register past its own cycle, so every one of the 16,951 disk polls
loaded MD with whatever DDR had last returned; an unanswered read gives MD
zero now, decided and fixed at `05d28fa`. With that, 200 ms of machine time
gives 590,925 microcycles and 13,783 timeouts **without** memory against
592,681 and 13,710 **with** --- LD1's blink moves by three parts in a
thousand, and nothing else moves at all.

The lamps are therefore not how the memory path is checked, and cannot be.
The evidence is `vivado/ddr_run.tcl`'s four counters, read by the debugger at
the processing system's own boundary, and page 0 read back against the poison
that was put there. The probe cannot answer it either: it captures microcycles
0 to DEPTH-1 and the first `mem_req` is at 536,303.

**There are two signals called `nxm` and they mean opposite kinds of thing.**
The decode's says the *address* is Xbus space with nothing built there; the bus
interface's own register, carried out as `timed_out`, says *this cycle* ended
on the timer rather than on a slave. LD5 was first wired to the decode's and
came up **green on a board with no memory** --- because the boot PROM's traffic
is 16,951 cycles to the disk registers at `0o17377774`, which are in the
decode's map and therefore not empty space. They are simply unanswered.

It latches `timed_out` now, which is the question anyone actually wants: red
means the timer ended the cycle, green means something replied. The signal was
there all along; the LED was reading the wrong one.

**And the same conflation explains LD2's rate.** It counts `timed_out` edges,
so on a board where nothing answers the disk polls it counts **16,951 in a
boot-PROM run, not 2** --- the 2 being cycles whose *address* was empty space,
a different question. LD2 blinking steadily is the machine faithfully polling a
controller that is not built, at the rate the census predicts.

**LD0 is the one to look at first and that is why it is first.** It answers
"is this running at all", and every other light is meaningless until it says
yes. Without it, "not programmed", "the MMCM never locked" and "the machine
stalled" are three different problems that all look like a dark board.

Read them in order:

    LD0 dark                  not programmed, or the MMCM never locked
    LD0 blinking, LD1 dark    clocked, but not retiring microcycles
    LD0 and LD1 blinking      the machine is running

Observed on the board, no memory, boot PROM only: **LD0 blinking, LD1 blinking
slowly, LD2 blinking, LD3 faint, LD4 blue, LD5 red.** LD3 faint is correct
--- `witness` only toggles when the datapath changes, and the machine spends
almost all its time parked in timeouts, so a faint LD3 is a machine that is
mostly waiting.

**With no memory behind `mem_*`** --- which is what a `PROVE` board is, and
what every build before the PS block landed was --- the expected reading is
**LD0 blinking, LD1 blinking very slowly, LD2 blinking at about 0.78 s, LD3
lit**. An earlier version of this line said LD2 would be "lit or dim", which
was true of the lamp while it showed `timed_out` itself and stopped being true
when it started counting the edges.

An earlier version of this table said LD1 would be *dark*, on the reasoning
that with nothing answering `mem_*` the machine reaches its first main-memory
cycle and stalls there for ever. **That is wrong, and the board said so
first.** Nothing answering does not mean the cycle never ends: the NXM timer
in `cadr_busint_xbus.sv` expires at about 4.25 us and the cycle completes as a
non-existent-memory reference. The machine keeps going. It is a real part of
the design doing its job, and it turns "no memory" from a stall into a
slowdown.

Simulated afterwards to put numbers on it --- `cadr_machine` with `mem_done`
tied low, which is the step-1 bitstream exactly:

    first mem_req            microcycle 536,303
    NXM timeouts             30,590 in 300 ms
    after the first cycle    1.49 us a microcycle, against 0.22 normal
    LD1 (beat[19])           toggles every 0.79 s

So LD1's period is about a second and a half, which is what "blinking very
slowly" looks like against the 0.23 s it would be at full speed, and LD2
blinks at about 0.78 s --- 65,536 timeouts a toggle, at 168 kHz.

**`tb/cadr_nomem_tb.cpp` prints that line as `beat[23]`, and LD1 has been
`beat[19]` since `ad4a475`**: the lamp is sixteen times faster than the
testbench's own comment says. What the testbench measures is the microcycle
rate; which bit of the beat reaches the pin is `rtl/cadr_arty.sv`'s to say,
and this table takes it from there.

**The general point is worth more than the correction.** The prediction was
that no memory means no progress; the fabric's answer is that no memory means
*slow* progress. That is the first behaviour anyone here observed on silicon
that was predicted wrongly, and it was predicted wrongly in this file.
