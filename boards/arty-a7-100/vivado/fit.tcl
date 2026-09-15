# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Synthesize, place and route the composed machine for the Artix part, and
# report what it costs.
#
#     make build/boot_prom.hex build/sync_prom.hex
#     vivado -mode batch -source boards/arty-a7-100/vivado/fit.tcl
#
# Run from the repository root. Out of context: no top level, no output fold,
# no MMCM and no package pins --- `bitstream.tcl` is the sibling that asks
# whether the design builds for the board, and this asks what the machine
# costs on its own. The two give different answers and are meant to.
#
# **WHY THIS EXISTS BESIDE THE OTHER BOARD'S, WHICH ALREADY TAKES `PART` FROM
# THE ENVIRONMENT.** `boards/arty-z7-20/vivado/fit.tcl` would very nearly do
# this job --- it is out of context, so the part is the only thing that should
# matter --- and two things in it are tied to that board. It reads
# `boards/arty-z7-20/*.sv` along with `rtl/`, and `cadr_ps7.sv` there
# instantiates a `PS7`, which is not a primitive on an Artix. And it takes the
# tick by parsing the MMCM out of that board's top level, which is right only
# while both boards aim at the same one. Neither is a deep difference and both
# are real, so this is that script with the board's two names changed and its
# prose kept.
#
# Nothing in `make check` runs this. The checks prove the fabric agrees with
# muir, and a checkout without Vivado should not try to synthesize anything.

set part   [expr {[info exists ::env(PART)]   ? $::env(PART)   : "xc7a100tcsg324-1"}]
set outdir [expr {[info exists ::env(OUTDIR)] ? $::env(OUTDIR) : "build/a7-vivado"}]
file mkdir $outdir

set prom build/boot_prom.hex
if {![file exists $prom]} {
    puts "fit: $prom is missing; run `make $prom` first"
    exit 1
}

# And MIT's TV sync PROM, which the display runs from power-on.  Checked here
# for the reason the boot PROM is: `$readmemh` on a file that is not there is
# a WARNING, and a sync program of zeros is a display that never interrupts
# --- which synthesizes, routes and writes a bitstream.
set sync_prom build/sync_prom.hex
if {![file exists $sync_prom]} {
    puts "fit: $sync_prom is missing; run `make $sync_prom` first"
    exit 1
}

read_verilog -sv [glob rtl/*/*.sv rtl/*/*/*.sv boards/arty-a7-100/*.sv]
synth_design -top cadr_machine -part $part -mode out_of_context \
    -generic PROM_HEX=[file normalize $prom] \
    -generic SYNC_PROM_HEX=[file normalize $sync_prom]

# THE CLOCK IS THIS FLOW'S, NOT THE DESIGN'S.  Out of context `cadr_machine`
# is the top and `clk` is a port, so the period is declared here.  In a board
# flow there is no such port --- the top level makes the machine's clock with
# an MMCM --- and `create_clock` on it reports "No valid object(s) found",
# which is indistinguishable in a log from a constraint that silently applied
# to nothing.
#
# **BUT THE PERIOD IS NOT THIS FLOW'S, AND THAT IS THE DANGEROUS HALF.**  A
# number written here is a number that can quietly disagree with the fabric,
# and this flow would never say so: it declares its own clock, so it would go
# on reporting what the machine costs at a tick nobody builds, for ever and
# with every figure looking plausible.  `tick.tcl` reads the MMCM's own
# parameters out of this board's top level and fails loudly if it cannot.
source boards/arty-z7-20/vivado/tick.tcl
set tick [cadr_tick_ns boards/arty-a7-100/cadr_arty_a7.sv]
create_clock -name clk -period [format %.3f $tick] [get_ports clk]

read_xdc rtl/plumbing/xilinx7/cadr_machine.xdc

# ...and then ask the design whether that worked, rather than trusting it.
# `bitstream.tcl`'s header says why these two files are read from the other
# board's directory and where they ought to live instead.
source boards/arty-z7-20/vivado/constraints_check.tcl
assert_multicycle_applied $tick 15
# And the transaction audit's own two halves. Out of context the instance is
# one level shallower, `cadr_machine` being the top here rather than
# `u_machine` inside a board's top level --- and out of context the audit is
# NOT folded away, because its readout is a port of the module rather than
# something a console reaches. That is why this assertion runs here and is
# absent from this board's `bitstream.tcl`.
assert_instance_timing $tick 15 *audit/* \
    {*audit/first_* *audit/micro_reg* *audit/word_reg*}
# And the other half of the same policy: nothing outside the machine may take
# the relaxation. Out of context the machine IS the top, so this can only pass
# --- which is the point of running it here. If it ever fails, a top level has
# appeared in a flow that is not supposed to have one.
assert_constraints_scoped "" $tick

opt_design
place_design
phys_opt_design
route_design

report_utilization        -file $outdir/utilisation.rpt
report_timing_summary -max_paths 10 -file $outdir/timing.rpt

# Say what it found on the way out, so a run read only in a terminal still
# reports. Guarded because `get_timing_paths` returns an empty list when there
# is nothing to report --- which is what *success* looks like, so an unguarded
# `format` made a met design exit non-zero and read as a failure.
set paths [get_timing_paths -quiet -max_paths 1 -delay_type max]
puts "FIT: part $part"
if {[llength $paths]} {
    set wns [get_property SLACK [lindex $paths 0]]
    puts "FIT: worst slack [format %.3f $wns] ns"
    if {$wns < 0} { puts "FIT: timing is NOT met" } else { puts "FIT: timing is met" }
} else {
    puts "FIT: no timing path reported --- timing is met"
}
puts "FIT: reports in $outdir"
