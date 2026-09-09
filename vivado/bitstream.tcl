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
#      after reading, and a run with none stops.
#
#   2. THAT THE MACHINE IS STILL THERE. `cadr_machine` brings its whole
#      datapath out for the testbenches, and a top level that left those
#      unconnected would synthesise to nearly nothing and write a perfectly
#      good bitstream of an empty part. `cadr_arty.sv` folds every output into
#      one register to prevent it; this checks that it worked, against what
#      the machine is known to cost placed and routed out of context --- 2,764
#      LUTs and 28 block RAM tiles.
#
#   3. THAT THE BITSTREAM IS A BITSTREAM. `write_bitstream` reporting success
#      and leaving a file too small to be one is the same class of thing.
#
# Timing is expected to fail today. `md` reaches the tick-rate counters
# through both map levels and the decode, about 11.6 ns of logic arriving
# somewhere that has 5 ns, and that is a real finding rather than an artefact
# of this script. The bitstream is written anyway and the failure reported: a
# bitstream that fails timing is not a working machine, but it is a working
# flow, and the two unknowns are worth separating rather than compounding.

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

# The board's pins and clock, then the machine's timing exceptions. Order
# matters only in that the clock has to exist before anything references it.
read_xdc rtl/cadr_arty.xdc
read_xdc rtl/cadr_machine.xdc

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
# positions 4 and 5 of the report, `cycles=15` setup and `cycles=14` hold. A
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

opt_design
place_design
phys_opt_design
route_design

# --- 2. is the machine still there?
set luts  [llength [get_cells -quiet -hier -filter {PRIMITIVE_GROUP == LUT}]]
set brams [llength [get_cells -quiet -hier -filter {PRIMITIVE_TYPE =~ BMEM.*.*}]]
set ffs   [llength [get_cells -quiet -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
puts "BIT: $luts LUTs, $ffs registers, $brams block RAMs"
# Out of context the machine is 2,764 LUTs and 28 block RAM tiles. A top level
# adds a little and optimisation across pins may remove a little; an order of
# magnitude below that is not this design.
if {$luts < 1500 || $brams < 20} {
    puts "BIT: FAILED --- that is not the whole machine."
    puts "BIT: Placed and routed out of context it is 2,764 LUTs and 28 block"
    puts "BIT: RAMs. Something upstream has optimised the datapath away, which"
    puts "BIT: happens when the top level does not use what cadr_machine brings"
    puts "BIT: out. A bitstream of an empty part is the failure to look for."
    exit 1
}

report_utilization                     -file $outdir/utilisation.rpt
report_timing_summary -max_paths 10    -file $outdir/timing.rpt
report_clocks                          -file $outdir/clocks.rpt

set wns [get_property SLACK [get_timing_paths -max_paths 1 -delay_type max]]
puts "BIT: worst slack [format %.3f $wns] ns"
if {$wns < 0} {
    puts "BIT: TIMING IS NOT MET --- the bitstream below is of a design that"
    puts "BIT: does not close. It proves the flow, not the machine."
} else {
    puts "BIT: timing is met"
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
