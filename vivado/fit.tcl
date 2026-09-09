# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Synthesise, place and route the composed machine, and report what it costs.
#
#     make build/boot_prom.hex
#     vivado -mode batch -source vivado/fit.tcl
#
# Run from the repository root. Out of context: there is no top level with
# real pins yet, because almost nothing here is board I/O --- the outside world
# is DDR3 and the PS, which arrive through the Zynq PS block rather than
# through package pins. When there is one, the board's own XDC goes with it;
# Digilent publishes it at github.com/Digilent/digilent-xdc.
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

read_verilog -sv [glob rtl/*.sv]
synth_design -top cadr_machine -part $part -mode out_of_context \
    -generic PROM_HEX=[file normalize $prom]

# THE CLOCK IS THIS FLOW'S, NOT THE DESIGN'S.  Out of context `cadr_machine`
# is the top and `clk` is a port, so the period is declared here.  In a board
# flow there is no such port --- `cadr_arty.sv` makes the 200 MHz with an MMCM
# from the board's 125 --- and `create_clock` on it reports "No valid
# object(s) found", which is indistinguishable in a log from a constraint that
# silently applied to nothing.  That failure has cost an evening in this
# project once already, so the two flows each name their own clock and
# `rtl/cadr_machine.xdc` names none.
create_clock -name clk -period 5.000 [get_ports clk]

read_xdc rtl/cadr_machine.xdc

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
