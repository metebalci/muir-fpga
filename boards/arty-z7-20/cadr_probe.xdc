# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The JTAG clock the capture is read out on, and the fact that it has nothing
# to do with the machine's.
#
# READ ONLY WHEN THE PROBE IS IN THE DESIGN.  `boards/arty-z7-20/vivado/bitstream.tcl` reads
# this behind `PROBE_DEPTH > 0`, because a `create_clock` on a cell that is
# not there is "No valid object(s) found" --- a critical warning that reads
# exactly like a constraint which applied, and this project has already lost
# an evening to one.
#
# WHY DRCK NEEDS A CLOCK AT ALL.  `rtl/plumbing/xilinx7/cadr_probe.sv` clocks its shift
# register and its read pointer on the BSCANE2's DRCK, which Vivado does not
# know is a clock unless it is told: left alone the whole readout is
# unconstrained, timed against nothing, and reported as nothing --- the same
# silence as a constraint that reached no path.  The period is the cable's,
# not the fabric's: 30 MHz is the fastest a Digilent FT2232H runs TCK and DRCK
# follows TCK through the primitive, so 33.333 ns is a bound and not a
# measurement.  Nothing here needs it to be tight; it needs it to exist.
#
# AND WHY THE TWO DOMAINS ARE ASYNCHRONOUS.  They are: TCK comes off a cable
# and the fabric's 200 MHz comes off an MMCM.  What crosses between them is
# `rd_addr` --- through a two-flop synchroniser --- and `mem_q`, which is
# quasi-static by construction: the pointer moves once a scan, 454 TCKs apart,
# and the 200 MHz side re-reads the word every 5 ns, so it has been standing
# for thousands of ticks before the JTAG side loads it.  Saying "asynchronous"
# is what keeps the placer from spending itself on a path that has tens of
# microseconds and is reported as if it had five nanoseconds.
#
# The cell is found by what it is rather than by where it is: the probe is
# inside a generate block, and a hierarchical name is the thing that goes
# stale when somebody renames one.

set bscan [get_cells -hier -filter {REF_NAME == BSCANE2}]
create_clock -name jtag_drck -period 33.333 \
    [get_pins -of_objects $bscan -filter {REF_PIN_NAME == DRCK}]

set_clock_groups -asynchronous \
    -group [get_clocks jtag_drck] \
    -group [get_clocks -include_generated_clocks sysclk]

# ------------------------------------------------- and the microcycle, again
#
# **WHAT THE MACHINE BRINGS OUT IS MOSTLY COMBINATIONAL**, and anything that
# samples it needs the exception `rtl/plumbing/xilinx7/cadr_machine.xdc` gives the machine's own
# registers. The A and M buses, the ALU, R, OB and the four sequencing flags
# are not registers: they are the read phase, settling somewhere inside a
# 145 ns microcycle and read at the end of it. A register outside the machine
# taking those nets in one 5 ns tick asks for something no path in this design
# has ever met --- 18.048 ns from `memstart_reg` through 24 levels of the
# dispatch memory, measured --- and the first instrumented board came out at
# **-13.156 ns on 2,400 endpoints of 16,053** for exactly that reason, against
# -0.054 on one endpoint without the probe.
#
# THIS IS NOT A PECULIARITY OF THIS PROBE. An ILA's own sampling registers
# would have met it identically and with no comment to explain it, which is
# worth knowing before anyone reaches for one: the cost of watching this
# machine is a timing exception on whatever does the watching.
#
# `stable_q` is the half of the holding register that may take it, and the
# split is `rtl/plumbing/xilinx7/cadr_probe.sv`'s: its inputs stand still from one microcycle
# boundary to the next, which is this project's own test for what may be
# relaxed. `late_q` --- `lpc`, `md`, `vma`, `promdis` --- deliberately may not.
# `md` is the column CLAUDE.md's entry about sampling before a stall is about:
# `-LOADMD` strobes it while the clock is held off, and a register given 75 ns
# to notice might not have. All four come straight off registers in the
# machine and meet one tick without help.
#
# 15 and 14, the same numbers and for the same reason: the tightest instant a
# datapath register is read at is the fast read tap.
set probe_stable [get_cells -hier -filter {NAME =~ *u_probe/stable_q_reg*}]
set_multicycle_path -setup 15 -to $probe_stable
set_multicycle_path -hold  14 -to $probe_stable
