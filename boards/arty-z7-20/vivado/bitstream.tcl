# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build a bitstream for the Arty Z7-20.
#
#     make build/boot_prom.hex
#     vivado -mode batch -source boards/arty-z7-20/vivado/bitstream.tcl
#
# Run from the repository root. This is `fit.tcl`'s sibling: that one asks
# what the machine costs, out of context and with no pins; this one asks
# whether it can be built at all, against a real part with the board's own
# package pins, through to a `.bit`.
#
# THREE THINGS IT CHECKS BEYOND "DID IT FINISH", because all three have gone
# wrong in this project already and none of them produces an error:
#
#   1. THAT THE CONSTRAINTS APPLIED. `rtl/plumbing/xilinx7/cadr_machine.xdc` once built its
#      relaxed register set with a `foreach`, which an XDC rejects outright:
#      the file read cleanly, applied to nothing, and the timing report showed
#      the unconstrained design at -16.405 ns instead of -6.602. A file whose
#      failure mode is a plausible worse number. So the exceptions are counted
#      after reading, and a run with none stops --- and then, because a
#      counted exception can still have reached no path, the paths themselves
#      are asked what setup requirement they carry.
#
#   2. THAT THE MACHINE IS STILL THERE. `cadr_machine` brings its whole
#      datapath out for the testbenches, and a top level that left those
#      unconnected would synthesise to nearly nothing and write a perfectly
#      good bitstream of an empty part. `cadr_arty.sv` folds every output into
#      one register to prevent it; this checks that it worked, against what the
#      machine is known to cost --- 2,795 Slice LUTs and 28 block RAM tiles
#      placed and routed out of context at 712909e, which the check sees as
#      2,101 LUT cells and 29 BMEM cells for the reason given at the check.
#
#   3. THAT THE BITSTREAM IS A BITSTREAM. `write_bitstream` reporting success
#      and leaving a file too small to be one is the same class of thing.
#
# TIMING IS MET, AND WHAT MADE IT MET WAS THE TICK AND NOT THE DESIGN. For as
# long as this file has existed a tick was 5 ns and the board did not close:
# -0.129 ns at 712909e, -0.384 at b1bcc34, -0.054 at cc6b9ce, -0.233 on 79
# endpoints by the time the disk, the display and the console had landed. Mete
# decided on 2026-09-11 to stop chasing it and remove timing as a threat to
# the machine's correctness instead. THE TICK MOVED TWICE THAT DAY: to 6.25 ns
# in the morning, where both boards closed for the first time, and to 10 ns in
# the afternoon, when a one-character change to a multiplexer cost a third of
# a nanosecond and the memory-on board read -0.261 ns and did not close again.
# A design sitting near zero turns every edit into a timing question, which is
# what the second move buys off; Mete's words were "if you have timing
# concern, we can even increase the tick to 10ns". So `cadr_arty.sv`'s MMCM
# divides its 1000 MHz VCO by 10 rather than by 5, a tick is 10 ns, and the
# machine runs at 50% of the speed the hardware ran. **Not one tick COUNT in
# the design changed and no check moved**, because the machine's own clock is
# the only clock it has; `cadr_arty.sv`'s header is the whole argument.
#
# Measured at `822535c` with that change and nothing else, both boards, this
# flow:
#
#     board          WNS        failing   hold      LUTs    registers   BRAM
#     memory-off    +1.537 ns   0/25,525  +0.073    5,194     1,848      37
#     DDR=1         +0.657 ns   0/38,593  +0.030    9,543     5,894      39.5
#
# (`report_utilization`'s Slice LUTs and Slice Registers, and Block RAM Tiles.
# The `BIT:` line below prints CELL counts instead, 3,508 and 8,219 LUT cells
# and 38 and 41 BMEM cells, and the two do not agree by construction --- the
# note at that check says why.) At the same commit, with only the divider back
# at 6.250, the DDR board reads -0.261 ns; at 7.000 it reads +0.160. The worst
# path on the memory-off board is
#
#     +1.537 ns  mach_rst_reg__0/C
#             -> u_machine/processor/iwr_reg[46]/R
#             7.724 ns data path (logic 0.456, route 7.268), 0 logic levels
#
# and on the DDR board it is the disk's channel request reaching MD's clock
# enable, nine logic levels and 8.688 ns of which 7.116 is routing --- which
# is what a design with headroom looks like: placement, not depth.
#
# **THE NET IS THE PLACEMENT AND THE FAMILY IS THE FINDING**, and that was
# worth writing down when this flow was failing for exactly the reason it is
# worth writing down now. Three revisions at the 5 ns tick gave three
# different worst nets in the 0.1 to 0.4 ns band. Quote a net from here only
# with the commit beside it.
#
# The bitstream is written even when timing fails, and the failure reported: a
# bitstream that fails timing is not a working machine, but it is a working
# flow, and the two unknowns are worth separating rather than compounding.

set part   [expr {[info exists ::env(PART)]   ? $::env(PART)   : "xc7z020clg400-1"}]
set outdir [expr {[info exists ::env(OUTDIR)] ? $::env(OUTDIR) : "build/bitstream"}]
file mkdir $outdir

# HOW LONG A TICK IS, ASKED OF THE FABRIC THAT DECIDES IT.  The board's own
# 125 MHz is declared in `boards/arty-z7-20/cadr_arty.xdc` and never moves;
# the machine's clock is derived from it by the MMCM in
# `boards/arty-z7-20/cadr_arty.sv`, so Vivado works the generated clock out on
# its own and no `create_clock` is needed for it here.  What IS needed is the
# same number in Tcl, because the two assertions below match a setup
# requirement as a formatted string.  `tick.tcl` parses the MMCM's four
# parameters and fails loudly if it cannot find exactly one of each, so a
# period written here can never come apart from the one being built.
source boards/arty-z7-20/vivado/tick.tcl
set tick [cadr_tick_ns]

# AND ONE SWITCH, WHICH BUILDS A DIFFERENT BOARD.
#
#     PROBE_DEPTH=1024 OUTDIR=build/probe vivado -mode batch -source boards/arty-z7-20/vivado/bitstream.tcl
#
# puts `rtl/plumbing/xilinx7/cadr_probe.sv` in the design: one sample a microcycle of the
# columns `build/rtl.golden` carries, in block RAM, shifted out over JTAG by
# `boards/arty-z7-20/vivado/probe.tcl`. Zero, the default, is the machine and nothing else ---
# the same LUTs, the same registers, the same 28 block RAM tiles --- so every
# number this script has ever printed still describes the design it described.
#
# **THE SWITCH IS HERE RATHER THAN IN A FLOW OF ITS OWN** because the three
# checks below are policy and not convenience: a second script that placed and
# routed a bitstream would have to repeat them, and a repeated check is a check
# that goes stale on one side. What the instrumented build needs beyond them is
# one constraint file, read only when the cell it names exists --- a
# `create_clock` on an absent object is the "No valid object(s) found" warning
# `rtl/plumbing/xilinx7/cadr_machine.xdc`'s header is about.
set probe_depth [expr {[info exists ::env(PROBE_DEPTH)] ? $::env(PROBE_DEPTH) : 0}]

# AND A SECOND SWITCH, ON THE SAME ARGUMENT.
#
#     DDR=1 OUTDIR=build/ddr vivado -mode batch -source boards/arty-z7-20/vivado/bitstream.tcl
#
# puts the Zynq processing system and DDR3 behind the machine's memory port:
# `boards/arty-z7-20/cadr_ps7.sv`, `rtl/plumbing/cadr_axi_master.sv`, and the widening between the
# machine's 32-bit word and `S_AXI_HP0`'s 64-bit one. Zero, the default, ties
# `mem_done` low exactly as this flow has always tied it, so every number
# printed below still describes the design it has always described.
#
# It is a switch and not a second script for the reason the probe's is: the
# three checks below are policy, and a flow that repeated them would be a
# second copy to go stale.
set ddr [expr {[info exists ::env(DDR)] ? $::env(DDR) : 0}]

# AND A THIRD, WHICH BUILDS THE BOARD THAT ANSWERS WHETHER ANY OF IT WORKS.
#
#     PROVE=1 OUTDIR=build/prove-write vivado -mode batch -source boards/arty-z7-20/vivado/bitstream.tcl
#     PROVE=2 OUTDIR=build/prove-read  vivado -mode batch -source boards/arty-z7-20/vivado/bitstream.tcl
#
# `rtl/plumbing/cadr_prove.sv` in the design, driving the machine's own memory port ---
# the same adapter, the same widening, the same PS7 --- with one word at one
# address. `PROVE=1` writes it as soon as `SAXIHP0ARESETN` says the port is
# live and stops; `PROVE=2` reads it back as soon as the port comes live and
# writes what it read, raw, to a second address for the debugger to compare
# --- no button, and the lamp is not the observer. The observer for both is a
# debugger reading DDR from outside the design, which is the whole point: the
# design cannot mark its own work.
#
# A `PROVE` BOARD IS A `DDR` BOARD, and `boards/arty-z7-20/cadr_arty.sv` makes it one --- its
# `PORT` localparam is set by either generic --- so `PROVE=1` alone is a
# complete instruction and everything below that asks "is the processing
# system in this design" has to ask about both.
set prove [expr {[info exists ::env(PROVE)] ? $::env(PROVE) : 0}]
if {$prove != 0 && $prove != 1 && $prove != 2} {
    puts "BIT: FAILED --- PROVE=$prove is not a board. 1 writes a word, 2 reads"
    puts "BIT: one back, 0 is the machine. See rtl/plumbing/cadr_prove.sv."
    exit 1
}
# Everything below asks this rather than `$ddr`.
set port [expr {($ddr > 0 || $prove > 0) ? 1 : 0}]

set prom build/boot_prom.hex
if {![file exists $prom]} {
    puts "BIT: $prom is missing; run `make $prom` first"
    exit 1
}

read_verilog -sv [glob rtl/*/*.sv rtl/*/*/*.sv boards/arty-z7-20/*.sv]
synth_design -top cadr_arty -part $part \
    -generic PROM_HEX=[file normalize $prom] \
    -generic PROBE_DEPTH=$probe_depth \
    -generic DDR=$ddr \
    -generic PROVE=$prove
if {$probe_depth > 0} {
    puts "BIT: PROBE_DEPTH=$probe_depth --- this is the instrumented board,"
    puts "BIT: not the one the utilisation and timing prose below describes."
}
if {$port > 0} {
    puts "BIT: the processing system is behind the memory port, so this board"
    puts "BIT: is neither the design the utilisation prose below describes nor"
    puts "BIT: the one the timing prose does."
}
if {$prove > 0} {
    puts "BIT: PROVE=$prove --- rtl/plumbing/cadr_prove.sv drives that port and the"
    puts "BIT: machine does not. The machine is still in the design and still"
    puts "BIT: stalls on its own memory exactly as the default board does;"
    puts "BIT: what this bitstream is for is [expr {$prove == 1 ? {one write a debugger reads back} : {one read a debugger set up}}]."
}

# The board's pins and clock, then the machine's timing exceptions.
#
# THE MACHINE'S FILE IS READ SCOPED, and that is not tidiness. Unscoped, its
# `$slow` set is `all_registers` minus a name list, and on a board `all_
# registers` includes the top level's own --- 26 of them when this was written,
# the reset synchroniser and the free-running heartbeat, each taking a
# fifteen-tick multicycle written for a datapath. `-ref cadr_machine` makes
# `all_registers` mean the machine's, which is what the file's prose has
# always said it meant.
#
# THE COUNT IS NOT THE CHECK, and it has already moved: `cadr_arty.sv` at
# b1bcc34 declares 55 registers of its own --- `rst_sync` is 4 bits now and
# not 2, plus `beat` 24, `tick` 26 and `witness` 1 --- so a run that matched
# on 26 would be matching on nothing in particular. What holds the property is
# `assert_constraints_scoped` below, which asks the design whether any
# register outside `u_machine` carries a relaxed requirement, and does not
# care how many there are.
read_xdc boards/arty-z7-20/cadr_arty.xdc
read_xdc -ref cadr_machine rtl/plumbing/xilinx7/cadr_machine.xdc
# Only when the BSCANE2 it names is in the design. See the switch above.
if {$probe_depth > 0} { read_xdc boards/arty-z7-20/cadr_probe.xdc }
# And the same rule for the memory port's own deadline: every object
# `rtl/plumbing/xilinx7/cadr_ddr.xdc` names is inside `g_ddr`, so reading it against the
# default board would be four critical warnings about absent objects.
if {$port > 0} { read_xdc rtl/plumbing/xilinx7/cadr_ddr.xdc }

# ...and then ask the design whether that worked, rather than trusting it.
source boards/arty-z7-20/vivado/constraints_check.tcl
# The list of places the microcycle exception is allowed to live. One when
# this is the machine on a board; two when the probe is in it, because
# `boards/arty-z7-20/cadr_probe.xdc` relaxes the register that holds the machine's
# combinational outputs and says at length why. Nothing else, either way.
#
# A THIRD ENTRY WITH `DDR=1`, and it is the memory's own contract rather than
# a convenience. `rtl/plumbing/xilinx7/cadr_machine.xdc` gives `mem_addr`, `mem_wdata` and
# `mem_write` sixteen ticks --- the 80 ns the bus specification makes the
# master responsible for --- and what receives them is `cadr_axi_master`'s
# address and data registers, which are outside `u_machine` by construction.
# So the adapter joins the list, and what the invariant still says is that
# nothing ELSE outside the machine is relaxed: the port's reset synchroniser
# and the held error bit sit beside it in `g_ddr` and are not exempt.
set inside u_machine
if {$probe_depth > 0} { lappend inside g_probe.u_probe }
if {$port > 0}        { lappend inside g_ddr.u_axi }
assert_constraints_scoped $inside $tick

# --- 1. did the constraints apply?
#
# `report_exceptions` rather than a `get_*`: there is no
# `get_timing_exceptions` in Vivado 2026.1, which is worth knowing because the
# obvious name is the one that does not exist and an unguarded call to it
# aborts the script two hundred lines before anything is built.
#
# AND IT IS COUNTED ON `cycles=`, NOT ON THE WORD "multicycle", WHICH THE
# REPORT NEVER WRITES. The first version of this check looked for that word,
# found none, and stopped a run whose constraints had applied perfectly ---
# `cycles=15` setup and `cycles=14` hold, at positions 4 and 5 of the report
# when that was written and 5 and 6 at b1bcc34, `witness_reg`'s false path
# having joined the list in between. Position is not the thing to match on. A
# guard that cries wolf is worse than no guard, and this one was written
# against a report format nobody had read. The same mistake as the `foreach`
# it exists to catch, one level up.
report_exceptions -file $outdir/exceptions.rpt
set fh [open $outdir/exceptions.rpt r]
set exception_text [read $fh]
close $fh
set exceptions [regexp -all {cycles=} $exception_text]
set clocks     [llength [get_clocks -quiet]]
puts "BIT: $exceptions multicycle exceptions, $clocks clocks"
# Two: a setup and a hold. One alone would mean half the pair went missing.
if {$exceptions < 2} {
    puts "BIT: FAILED --- no timing exceptions were created."
    puts "BIT: cadr_machine.xdc's multicycle set applied to nothing, so every"
    puts "BIT: number this run would print is of a design constrained wrongly."
    exit 1
}
if {$clocks < 2} {
    puts "BIT: FAILED --- $clocks clock(s); expected the board's 125 MHz and"
    puts "BIT: the MMCM's 100 MHz derived from it. A generated clock that did"
    puts "BIT: not appear means the fabric is being timed against the wrong one."
    exit 1
}

# AND THE COUNT ABOVE IS THE WEAKER TEST OF THE TWO, which is why this follows
# it rather than replacing it. `report_exceptions` lists a `set_multicycle_path`
# whose object queries matched nothing exactly as it lists one that reached
# 10,929 paths --- the statement was read either way, so the exception exists
# either way, and the `foreach` bug would pass the count. What separates them
# is the setup requirement the paths ask for. The count still earns its place:
# it is the half that says a setup exception has a hold exception beside it.
assert_multicycle_applied $tick 15
# And the memory port's own deadline, which has a destination only on this
# board: with `DDR` off, `mem_addr` reaches nothing but a false-pathed fold
# and the exception is real, legal and connected to nothing. Asserting it
# there would fail on a healthy design; not asserting it here would leave the
# 80 ns claim exactly as unchecked as it was before it existed.
if {$port > 0} { assert_multicycle_applied $tick 16 }

opt_design
place_design
phys_opt_design
route_design

# --- 2. is the machine still there?
set luts  [llength [get_cells -quiet -hier -filter {PRIMITIVE_GROUP == LUT}]]
set brams [llength [get_cells -quiet -hier -filter {PRIMITIVE_TYPE =~ BMEM.*.*}]]
set ffs   [llength [get_cells -quiet -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
puts "BIT: $luts LUTs, $ffs registers, $brams block RAMs"
# THESE THREE ARE CELL COUNTS AND NOT THE UTILISATION REPORT'S, and the two do
# not agree by construction --- so the floors below must be read against these
# and not against the figures anybody quotes. Measured on the board's routed
# design at 712909e: `PRIMITIVE_GROUP == LUT` is 2,101 cells where
# `report_utilization` says 2,876 Slice LUTs, because the report counts sites
# (1,755 as logic, two LUT5 cells often sharing one) and adds the 1,121 sites
# holding distributed RAM, which are not in the LUT group at all --- they are
# `PRIMITIVE_GROUP == DMEM`, 1,411 cells of it. Block RAM goes the other way:
# 29 BMEM cells against 28 tiles, a tile holding two RAMB18s. The registers are
# the one pair that match, 773 either way. Out of context the report says 2,795
# Slice LUTs, 769 registers, 28 tiles.
#
# At b1bcc34 this line printed `2088 LUTs, 746 registers, 29 block RAMs`
# against 2,871 Slice LUTs and 746 registers in the report, so both counts
# move a percent or two with the top level and neither is a constant.
#
# The floors are an order of magnitude under all of that on purpose. What this
# has to tell apart is the machine from an empty part, not one revision from
# the next, and a floor that tracked the design would be edited every time it
# moved.
if {$luts < 1500 || $brams < 20} {
    puts "BIT: FAILED --- that is not the whole machine."
    puts "BIT: Routed on the board it is 2,101 LUT cells and 29 BMEM cells."
    puts "BIT: Something upstream has optimised the datapath away, which"
    puts "BIT: happens when the top level does not use what cadr_machine brings"
    puts "BIT: out. A bitstream of an empty part is the failure to look for."
    exit 1
}

report_utilization                     -file $outdir/utilisation.rpt
report_timing_summary -max_paths 10    -file $outdir/timing.rpt
report_clocks                          -file $outdir/clocks.rpt

# Guarded, because `get_timing_paths` returns an empty list when there is
# nothing to report --- and nothing to report is what SUCCESS looks like. The
# unguarded `format` below threw on a met design in `fit.tcl`, which exited 1
# and printed nothing, so success read exactly like failure.
#
# It is the sharpest of a family: a diagnostic gets less testing than the
# thing it diagnoses, and this one lives in **the path that only exists once
# the thing works**. A project that has been failing at something has never
# run its own success case. This branch had never executed here at all until
# the tick became 6.25 ns --- the design had never met its clock --- so it was
# fixed on the strength of what happened next door rather than after it
# happened twice, and the first run that exercised it found it correct.
set paths [get_timing_paths -quiet -max_paths 1 -delay_type max]
if {[llength $paths]} {
    set wns [get_property SLACK [lindex $paths 0]]
    puts "BIT: worst slack [format %.3f $wns] ns"
    if {$wns < 0} {
        puts "BIT: TIMING IS NOT MET --- the bitstream below is of a design that"
        puts "BIT: does not close. It proves the flow, not the machine."
    } else {
        puts "BIT: timing is met"
    }
} else {
    puts "BIT: no timing path reported --- timing is met"
}

# --- 3. and is it a bitstream?
set bit $outdir/cadr_arty.bit
write_bitstream -force $bit
if {![file exists $bit]} {
    puts "BIT: FAILED --- write_bitstream left no file at $bit"
    exit 1
}
set size [file size $bit]
# An XC7Z020 configuration is a little over 4 MB. Anything much smaller is a
# header and not a bitstream.
if {$size < 3000000} {
    puts "BIT: FAILED --- $bit is $size bytes, too small to configure an xc7z020"
    exit 1
}
puts "BIT: wrote $bit, $size bytes"
puts "BIT: part $part, reports in $outdir"
