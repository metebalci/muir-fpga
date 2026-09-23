# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# THE FAULT BITSTREAM FOR A ZYNQ BOARD: no machine, every lamp blinking.
#
#     BOARD=arty|cora OUTDIR=<dir> vivado -mode batch -source tools/fault_zynq.tcl
#
# `make fault-arty` and `make fault-cora` run it.  The top level is the
# board's `cadr_<board>_fault.sv`, whose header says what it is and when
# U-Boot loads it; the pins and the board's clock are the board's own
# constraints file, unchanged, because the fault top level has the CADR
# top level's port list.
#
# **WHAT THIS REFUSES.**  A design much larger than the fault top level is
# something else: the machine cannot be in it, so a fit of more than a few
# hundred lookup tables means the wrong top was built.  A stamp without the
# fault mark (`tools/build_stamp.tcl`) would make this bitstream read as a
# CADR over JTAG, so the stamp is checked before it is applied.  Timing that
# is not met is reported and the bitstream is still written, as the CADR's
# flow does, and the line says so.

set board [expr {[info exists ::env(BOARD)] ? $::env(BOARD) : ""}]
switch -- $board {
    arty {
        set part  xc7z020clg400-1
        set dir   boards/arty-z7-20
        set top   cadr_arty_fault
        set xdc   boards/arty-z7-20/cadr_arty.xdc
        set floor 3000000
    }
    cora {
        set part  xc7z007sclg400-1
        set dir   boards/cora-z7-07s
        set top   cadr_cora_fault
        set xdc   boards/cora-z7-07s/cadr_cora.xdc
        set floor 2000000
    }
    default {
        puts "FAULT: BOARD is '$board'; it is arty or cora"
        exit 1
    }
}
set outdir [expr {[info exists ::env(OUTDIR)] ? $::env(OUTDIR) : "build/fault-$board"}]
file mkdir $outdir

set sources [list rtl/plumbing/cadr_fault_lamp.sv rtl/plumbing/cadr_gp0_default.sv \
                  $dir/cadr_ps7.sv $dir/$top.sv]
read_verilog -sv $sources
synth_design -top $top -part $part
read_xdc $xdc

opt_design
place_design
phys_opt_design
route_design

set luts  [llength [get_cells -quiet -hier -filter {PRIMITIVE_GROUP == LUT}]]
set brams [llength [get_cells -quiet -hier -filter {PRIMITIVE_TYPE =~ BMEM.*.*}]]
set ffs   [llength [get_cells -quiet -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
set ps7   [llength [get_cells -quiet -hier -filter {REF_NAME == PS7}]]
puts "FAULT: $luts LUTs, $ffs registers, $brams block RAMs, $ps7 PS7"
if {$luts > 500 || $brams > 0} {
    puts "FAULT: FAILED --- that is not the fault top level, which has no machine."
    exit 1
}
if {$ps7 != 1} {
    puts "FAULT: FAILED --- the processing system is not in the design, so"
    puts "FAULT: nothing answers its general-purpose ports."
    exit 1
}
report_utilization                  -file $outdir/utilisation.rpt
report_timing_summary -max_paths 10 -file $outdir/timing.rpt
report_clocks                       -file $outdir/clocks.rpt

set paths [get_timing_paths -quiet -max_paths 1 -delay_type max]
set hpaths [get_timing_paths -quiet -max_paths 1 -delay_type min]
set wns ""
set whs ""
if {[llength $paths]}  { set wns [get_property SLACK [lindex $paths 0]] }
if {[llength $hpaths]} { set whs [get_property SLACK [lindex $hpaths 0]] }
set failing [llength [get_timing_paths -quiet -max_paths 1000 -slack_lesser_than 0]]
puts "FAULT: worst setup [format %.3f $wns] ns, worst hold [format %.3f $whs] ns, $failing failing endpoints"
if {$failing > 0 || ($wns ne "" && $wns < 0) || ($whs ne "" && $whs < 0)} {
    puts "FAULT: TIMING IS NOT MET"
} else {
    puts "FAULT: timing is met"
}

source [file join [file dirname [file normalize [info script]]] build_stamp.tcl]
set stamp [build_stamp_of_tree 1]
if {![build_stamp_is_fault [lindex $stamp 0]]} {
    puts "FAULT: FAILED --- the stamp [lindex $stamp 0] does not carry the fault mark"
    exit 1
}
puts "FAULT: build [lindex $stamp 0] --- commit [lindex $stamp 1], tree [lindex $stamp 2]"
build_stamp_apply [current_design] [lindex $stamp 0]
set bit $outdir/$top.bit
write_bitstream -force $bit
if {![file exists $bit]} {
    puts "FAULT: FAILED --- write_bitstream left no file at $bit"
    exit 1
}
set size [file size $bit]
if {$size < $floor} {
    puts "FAULT: FAILED --- $bit is $size bytes, too small to configure $part"
    exit 1
}
if {![build_stamp_stamped "FAULT:" $bit $stamp]} { exit 1 }
puts "FAULT: wrote $bit, $size bytes"
