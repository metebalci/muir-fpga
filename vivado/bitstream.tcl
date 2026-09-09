# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build a bitstream for the Arty Z7-20.
#
#     make build/boot_prom.hex
#     vivado -mode batch -source vivado/bitstream.tcl
#
# Run from the repository root. This is `fit.tcl`'s sibling: that one asks
# what the machine costs, out of context and with no pins; this one asks
# whether it can be built at all, against a real part with the board's own
# package pins, through to a `.bit`.
#
# THREE THINGS IT CHECKS BEYOND "DID IT FINISH", because all three have gone
# wrong in this project already and none of them produces an error:
#
#   1. THAT THE CONSTRAINTS APPLIED. `rtl/cadr_machine.xdc` once built its
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
# TIMING STILL FAILS, BUT NOT WHERE THIS USED TO SAY IT DID. What stood here
# named `md` reaching the tick-rate counters through both map levels and the
# decode, about 11.6 ns of logic arriving somewhere that has 5 ns. That figure
# predates the two holdings in `cadr_memory_path.sv` and `cadr_microcycle.sv`,
# and it was arithmetic rather than a routed report. The first board run to
# measure it, at 712909e, found something else:
#
#     -0.129 ns  u_machine/processor/u_phase_gen/n_tpwp_reg/C
#             -> u_machine/processor/dmem_reg_1536_1791_7_7/RAMS64E_A/WE
#             4.186 ns data path (logic 0.828, route 3.358), 3 logic levels
#
# The phase generator's write pulse arriving at the dispatch memory's LUTRAM
# write enables. All 16 failing endpoints of 14,135 are that one net fanned
# across the LUTRAM slices, 80% of the delay is routing, and hold is met at
# +0.079 ns. Out of context the same design is -0.484 ns, 94 failing endpoints
# of 13,444.
#
# AND THE ENDPOINT IS NOT STABLE ACROSS REVISIONS, which is worth writing down
# because the paragraph it replaced was wrong in exactly that way. Run again
# on the tree at b1bcc34 --- two commits later, both of them in the top level
# --- this flow gives -0.384 ns, 10 failing endpoints of 14,054, and the worst
# path is not that net at all:
#
#     -0.384 ns  u_machine/processor/ir_reg[25]/C
#             -> u_machine/processor/mfinish_t_reg[2]/R
#
# which is the family the out-of-context run has at the top, a datapath
# register reaching a tick-rate counter's reset. Two commits apart, two
# different worst nets, both in the 0.1 to 0.4 ns band. **The family is the
# finding; the net is the placement.** Quote a net from here only with the
# commit beside it.
#
# So what is left is fanout and placement rather than depth of logic, and `md`
# through the map is not the finding any more.
#
# The bitstream is written anyway and the failure reported: a bitstream that
# fails timing is not a working machine, but it is a working flow, and the two
# unknowns are worth separating rather than compounding.

set part   [expr {[info exists ::env(PART)]   ? $::env(PART)   : "xc7z020clg400-1"}]
set outdir [expr {[info exists ::env(OUTDIR)] ? $::env(OUTDIR) : "build/bitstream"}]
file mkdir $outdir

set prom build/boot_prom.hex
if {![file exists $prom]} {
    puts "BIT: $prom is missing; run `make $prom` first"
    exit 1
}

read_verilog -sv [glob rtl/*.sv]
synth_design -top cadr_arty -part $part \
    -generic PROM_HEX=[file normalize $prom]

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
read_xdc rtl/cadr_arty.xdc
read_xdc -ref cadr_machine rtl/cadr_machine.xdc

# ...and then ask the design whether that worked, rather than trusting it.
source vivado/constraints_check.tcl
assert_constraints_scoped u_machine 5.0

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
    puts "BIT: the MMCM's 200 MHz derived from it. A generated clock that did"
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
assert_multicycle_applied 5.0 15

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
# run its own success case. This branch had never executed here either --- the
# design has not met 200 MHz until now --- so it is being fixed on the
# strength of what happened next door rather than after it happens twice.
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
