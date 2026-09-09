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
- **Anything needing DDR is a program-then-`ps7_init` test**, not a
  program-and-look one. From XSDB: `connect`, `targets -set -filter {name =~
  "APU*"}`, `source ps7_init.tcl`, `ps7_init`, `ps7_post_config`.

## What the LEDs say

    LD0   the fabric is clocked           free-running, about 3 Hz at 200 MHz
    LD1   microcycles are retiring        beat[19], ~0.6 Hz with no memory
    LD2   NXM timeouts, at their rate     nxm_count[16], not the flag itself
    LD3   the datapath is moving          witness, a ~700-bit fold
    LD4   where the boot has got to       red not running, blue PROM, green PROMDISABLE
    LD5   was the last cycle answered     red the timer ended it, green a slave did

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
168 kHz --- and LD5 is green for those 380 us and red for ever after. The one
lamp-visible consequence of the memory path working is a halt: if bit 0 of the
last word of page 0 is set, the PROM believes the disk is ready, writes one
word and stops at `ERROR-DISK-ERROR`, and LD1 and LD3 go dark while LD0 keeps
blinking. The lamps are not how memory is checked; the debugger reading DDR
from outside is.

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

**With no memory behind `mem_*`** --- which is every build before the PS block
lands --- the expected reading is **LD0 blinking, LD1 blinking very slowly,
LD2 lit or dim, LD3 lit**.

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
    LD1 (beat[23])           toggles every 12.5 s

So LD1's period is about twenty-five seconds, which is what "blinking very
slowly" looks like, and LD2 is lit or dim rather than blinking --- the
timeouts come at about 168 kHz and the eye integrates them.

**The general point is worth more than the correction.** The prediction was
that no memory means no progress; the fabric's answer is that no memory means
*slow* progress. That is the first behaviour anyone here observed on silicon
that was predicted wrongly, and it was predicted wrongly in this file.
