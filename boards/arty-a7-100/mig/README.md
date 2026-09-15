# The DDR3L controller

This directory holds the memory controller for the Arty A7-100's 256 MB of
DDR3L, and the project file it is generated from.

## This is the one generated IP in the repository

Everything else Xilinx offers as a directory of generated XML has been declined
here and hand-built instead. The clock generator is one `MMCME2_BASE`. The
capture instrument is one `BSCANE2` and a shift register, where an integrated
logic analyzer was available and was refused. The Zynq's processing system is
one `PS7` primitive with its port list derived by a script from Xilinx's own
library file.

A DDR3 controller is not that kind of thing. It is a calibration sequence, a
physical layer with per-bit deskew, a write leveling procedure, a refresh and
bank manager and a temperature monitor. Nothing in this repository could hold a
hand-written one to anything, and a memory controller that is wrong in a way no
check can see is the worst kind of thing this project can contain.

So the Memory Interface Generator is taken. What keeps the exception honest is
that it is generated the way everything else here is made: the input is a text
file in the repository, the run is a script with no project and no graphical
tool, and the output is committed and checked.

## The four files a reader should look at

| | |
|---|---|
| `mig-digilent-E.0-1.1.prj` | Digilent's published project file for this board, byte for byte |
| `mig.prj` | that file with four changes, and nothing else |
| `gen/` | what the generator writes from it |
| `../vivado/mig.tcl` | the script that writes `gen/` |

## Where the project file came from

Digilent publishes a board definition for the Arty A7-100, and a memory
controller's settings are part of it. Taking their file rather than typing the
memory part's timing parameters in again is the same rule this repository
applies to pin files: a wrong number here is a memory that fails at a
temperature nobody tested at.

| | |
|---|---|
| repository | `github.com/Digilent/vivado-boards` |
| commit | `36f34ab687b7fa9c778b779d027f3bce63b3ace9` |
| commit date | 2025-07-15 |
| original path | `new/board_files/arty-a7-100/E.0/1.1/mig.prj` |
| size | 9,202 bytes |
| sha256 | `3f72593b115e717bbc9a2e219cc321b36c2b7a5786ec32d9c6178390560862ec` |

**There are two revisions of that file and this is the newer one.** The E.0/1.0
file configures the controller for a 166.666 MHz input clock; E.0/1.1 takes the
board's own 100 MHz oscillator directly. The newer one is also the one whose
`Version` field matches the generator installed here.

## The four changes, and why each

`../vivado/mig_check.py` compares the two files line for line and fails if the
difference is anything but this list. A fifth change would be a different
memory, and it would pass unnoticed otherwise.

**The system clock is "No Buffer" rather than "Single-Ended", and the element
naming pad E3 is gone.** Digilent's file has the controller take the
oscillator's pin for itself. It cannot here. The board has one oscillator and
this design's top level already owns that pad: `cadr_arty_a7.sv`'s single
`MMCME2_BASE` takes E3 and makes the machine's 10 ns tick from it. Two input
buffers on one pad is an error. So the controller is given a clock this design
makes instead, which is what "No Buffer" means, and it is the machine's own
100 MHz. The 200 MHz reference the controller calibrates its input delays
against comes from the same clock manager.

**The port interface is the native user interface rather than the AXI4 slave,
and the AXI parameter block is gone.** `rtl/plumbing/cadr_mig_ui.sv`'s header
has the argument in full. The short form is that the AXI slave this board's
memory would present is 128 bits wide and refuses narrow bursts, so a
single-beat 32-bit master would need either an option turned on inside the
generated core or a widening of our own in front of it. That widening's whole
job is choosing a lane and a byte strobe, which is what the user interface's
own byte mask does directly.

**The user interface's extra clocks are turned off.** Digilent's file asks for
them and the generated design does not use them, which is harmless in the
Verilog and not in the constraints: the generated file placed a clock manager
that the generated Verilog does not instantiate, and Vivado reported
`set_property expects at least one object` as a critical warning on every
build. Turned off, the two agree and the warning is gone.

## What is committed, and what is not

The generator writes a great deal more than a design needs, and some of it
cannot be reproduced: a date stamp in two constraint files, a directory listing
in another, absolute paths in the tool's own scratch files, and a hash in the
packaging XML.

**A generated file that cannot be regenerated identically cannot be checked.**
So those are not kept. `../vivado/mig.tcl` copies out the design's own Verilog
and constraints, the instantiation template a reader checks the wrapper
against, the datasheet that says what was configured, and the project file the
generator actually consumed. The example design, its traffic generator, the
simulation scripts and the packaging XML belong to a design nobody here builds.

That is 73 files and about 2.5 MB, against 111 files and 11 MB.

## How it is checked

`make current` runs `../vivado/mig_check.py --check`, which asks three things.

The project file is Digilent's with the four changes above and no others. The
memory-off board's pin file, `../cadr_a7_ddr_off.xdc`, is what this script
derives from the generated constraints, so the two cannot come apart. And the
controller itself is regenerated into a scratch directory with the same
relative layout and compared file for file, with one line normalized: the
generator stamps the hour it ran into a comment at the top of each constraint
file.

The last of those needs Vivado. Without it the script says so and skips it; the
first two are pure Python and run anywhere.

## What was configured

Out of `gen/datasheet.txt`, which is the generator's own record.

| | |
|---|---|
| part | `xc7a100t-csg324`, speed grade -1 |
| memory | `MT41K128M16XX-15E`, DDR3L, 16 bits wide, 256 MB |
| interface | native |
| memory clock | 3,077 ps, which is 325 MHz |
| physical layer to controller ratio | 4:1, so the user clock is 81.25 MHz |
| user data width | 128 bits, which is eight 16-bit words |
| burst length | 8, fixed |
| address map | bank, row, column |
| input clock | 10,000 ps, this design's own 100 MHz |
| reference clock | supplied, 200 MHz |
| data mask | enabled, which is what lets a 32-bit write not disturb its block |
| ECC | disabled |

## The license

`create_ip -name mig_7series` and `generate_target all` checked out no license
feature at all under the BASIC license on this host, and the build that follows
reports `A valid Vivado Design Suite BASIC license has been detected`. The
generator is not a paid feature.
