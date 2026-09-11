# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Synthesise, place and route the composed machine, and report what it costs.
#
#     make build/boot_prom.hex
#     vivado -mode batch -source boards/arty-z7-20/vivado/fit.tcl
#
# Run from the repository root. Out of context, and still out of context now
# that a top level with real pins exists: `boards/arty-z7-20/cadr_arty.sv` and
# `boards/arty-z7-20/vivado/bitstream.tcl` ask whether the design builds for a board, and this
# asks what the machine costs on its own --- no output fold, no MMCM, no
# package pins. The two give different answers and are meant to: at 712909e
# this reports -0.484 ns with 94 failing endpoints of 13,444, where the board
# flow reports -0.129 ns with 16 of 14,135, and the worst path is not even the
# same one. Almost nothing here is board I/O anyway; the outside world is DDR3
# and the PS, which arrive through the Zynq PS block rather than through pins.
#
# Nothing in `make check` runs this. The checks prove the fabric agrees with
# muir, and a checkout without Vivado should not try to synthesise anything.

set part   [expr {[info exists ::env(PART)]   ? $::env(PART)   : "xc7z020clg400-1"}]
set outdir [expr {[info exists ::env(OUTDIR)] ? $::env(OUTDIR) : "build/vivado"}]
file mkdir $outdir

set prom build/boot_prom.hex
if {![file exists $prom]} {
    puts "fit: $prom is missing; run `make $prom` first"
    exit 1
}

read_verilog -sv [glob rtl/*/*.sv rtl/*/*/*.sv boards/arty-z7-20/*.sv]
synth_design -top cadr_machine -part $part -mode out_of_context \
    -generic PROM_HEX=[file normalize $prom]

# THE CLOCK IS THIS FLOW'S, NOT THE DESIGN'S.  Out of context `cadr_machine`
# is the top and `clk` is a port, so the period is declared here.  In a board
# flow there is no such port --- `cadr_arty.sv` makes the 200 MHz with an MMCM
# from the board's 125 --- and `create_clock` on it reports "No valid
# object(s) found", which is indistinguishable in a log from a constraint that
# silently applied to nothing.  That failure has cost an evening in this
# project once already, so the two flows each name their own clock and
# `rtl/plumbing/xilinx7/cadr_machine.xdc` names none.
create_clock -name clk -period 5.000 [get_ports clk]

read_xdc rtl/plumbing/xilinx7/cadr_machine.xdc

# ...and then ask the design whether that worked, rather than trusting it.
#
# THIS SCRIPT IS THE ONE WHOSE NUMBERS GET QUOTED as what the machine costs,
# and until now it was the one flow with nothing between `read_xdc` and a
# slack figure. `boards/arty-z7-20/vivado/bitstream.tcl` has counted its exceptions since it was
# written; this had the blind spot the `foreach` bug lived in --- an XDC that
# reads cleanly, applies to nothing, and reports a plausible worse number
# --- -16.405 ns unconstrained, where the constrained design is -0.484 at
# 712909e. (The constrained figure recorded beside that -16.405 at the time is
# -6.602 in `bitstream.tcl` and -6.542 in CLAUDE.md; they are two reports of
# two revisions and both predate the timing holdings, so neither is quoted
# here as the pair.)
#
# The count of exception objects is the weaker test, and that is why the
# assertion is not one: `report_exceptions` lists a `set_multicycle_path`
# whose `-from`/`-to` matched nothing exactly as it lists one that reached
# 10,972 paths --- the statement was read either way, so the exception exists
# either way. What separates them is the SETUP REQUIREMENT the paths ask for:
# 75.000 ns where the multicycle arrived, 5.000 ns everywhere it did not. A
# design where nothing asks for 75 ns is the unconstrained design, whatever
# the exceptions report says.
source boards/arty-z7-20/vivado/constraints_check.tcl
assert_multicycle_applied 5.0 15
# And the other half of the same policy: nothing outside the machine may take
# the relaxation. Out of context the machine IS the top, so this can only pass
# --- which is the point of running it here. If it ever fails, a top level has
# appeared in a flow that is not supposed to have one.
assert_constraints_scoped "" 5.0

opt_design
place_design
phys_opt_design
route_design

report_utilization        -file $outdir/utilisation.rpt
report_timing_summary -max_paths 10 -file $outdir/timing.rpt

# Say what it found on the way out, so a run read only in a terminal still
# reports. Guarded because `get_timing_paths` returns an empty list when there
# is nothing to report --- which is what *success* looks like, so an
# unguarded `format` made a met design exit non-zero and read as a failure.
set paths [get_timing_paths -max_paths 1 -delay_type max]
puts "FIT: part $part"
if {[llength $paths]} {
    set wns [get_property SLACK [lindex $paths 0]]
    puts "FIT: worst slack [format %.3f $wns] ns"
    if {$wns < 0} { puts "FIT: timing is NOT met" } else { puts "FIT: timing is met" }
} else {
    puts "FIT: no timing path reported --- timing is met"
}
puts "FIT: reports in $outdir"
