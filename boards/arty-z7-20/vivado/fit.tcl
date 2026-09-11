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
# this reported -0.484 ns with 94 failing endpoints of 13,444, where the board
# flow reported -0.129 ns with 16 of 14,135, and the worst path was not even
# the same one. Almost nothing here is board I/O anyway; the outside world is
# DDR3 and the PS, which arrive through the Zynq PS block rather than through
# pins.
#
# BOTH FIGURES ABOVE WERE MEASURED AT A 5 ns TICK, which is what the board ran
# at until 2026-09-11; a tick is 6.25 ns now and this flow reports **+0.131 ns
# with 0 failing endpoints of 20,404**, hold +0.085, 6,411 Slice LUTs, 3,740
# registers, 37 block RAM tiles --- measured on the tree that made that change,
# parent 7eb6846. `boards/arty-z7-20/cadr_arty.sv`'s header is the argument
# for the tick; `bitstream.tcl`'s is the board flow's own pair of figures. The
# out-of-context flow is still the tighter of the two, which is what it has
# always been: the machine here has no MMCM in front of it and no fold behind
# it, and the two were never meant to agree.
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
# flow there is no such port --- `cadr_arty.sv` makes the 160 MHz with an MMCM
# from the board's 125 --- and `create_clock` on it reports "No valid
# object(s) found", which is indistinguishable in a log from a constraint that
# silently applied to nothing.  That failure has cost an evening in this
# project once already, so the two flows each name their own clock and
# `rtl/plumbing/xilinx7/cadr_machine.xdc` names none.
#
# **BUT THE PERIOD IS NOT THIS FLOW'S, AND THAT IS THE DANGEROUS HALF.**  A
# number written here is a number that can quietly disagree with the fabric,
# and this flow would never say so: it declares its own clock, so it would go
# on reporting what the machine costs at a tick nobody builds, for ever and
# with every figure looking plausible.  `tick.tcl` reads the MMCM's own
# parameters out of `boards/arty-z7-20/cadr_arty.sv` and fails loudly if it
# cannot, so the two cannot come apart.
source boards/arty-z7-20/vivado/tick.tcl
set tick [cadr_tick_ns]
create_clock -name clk -period [format %.3f $tick] [get_ports clk]

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
# fifteen periods where the multicycle arrived, one period everywhere it did
# not --- 93.750 ns against 6.250 at the tick this builds. A design where
# nothing asks for fifteen periods is the unconstrained design, whatever the
# exceptions report says.
#
# **THE REQUIREMENT IS MATCHED AS A STRING**, so the period handed to the
# assertion has to be the one the design is actually timed at. It is `$tick`
# from `tick.tcl` for that reason: a literal left behind after the fabric's
# divider moved would make this assertion fail saying the constraints reached
# NO PATH --- a false accusation of the one bug it exists to catch, pointing
# the reader at `cadr_machine.xdc`, which would be blameless.
source boards/arty-z7-20/vivado/constraints_check.tcl
assert_multicycle_applied $tick 15
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
