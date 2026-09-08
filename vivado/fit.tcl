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

read_xdc rtl/cadr_machine.xdc

opt_design
place_design
phys_opt_design
route_design

report_utilization        -file $outdir/utilisation.rpt
report_timing_summary -max_paths 10 -file $outdir/timing.rpt

# Say the two numbers that matter on the way out, so a run that is only read
# in a terminal still reports what it found.
set wns [get_property SLACK [get_timing_paths -max_paths 1 -delay_type max]]
set luts [get_property USED [get_cells -quiet -hier -filter {PRIMITIVE_GROUP == LUT}]]
puts "FIT: part $part"
puts "FIT: worst slack [format %.3f $wns] ns"
puts "FIT: reports in $outdir"
if {$wns < 0} { puts "FIT: timing is NOT met" } else { puts "FIT: timing is met" }
