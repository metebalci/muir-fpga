# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The timing analyzer's verdict on the DE25-Nano's fault bitstream, run by
# `build.sh` in place of `sta_check.tcl` when `FAULT=1`.  That file asks its
# questions of the machine's exceptions, and this design has no machine, so
# what is left is its first and last parts: the two clocks are the board's
# 20 ns and the 10 ns tick, and every corner's worst setup and hold slack,
# written to `timing.txt` in the same words, which `build.sh` and
# `program.sh` read.

package require ::quartus::sta

set tick_ns 10.000
set board_ns 20.000

project_open cadr_de25
create_timing_netlist
read_sdc
update_timing_netlist

set failures 0
set out [open timing.txt w]

set machine_clocks {}
set board_clocks {}
foreach_in_collection c [get_clocks] {
    set name   [get_clock_info -name $c]
    set period [get_clock_info -period $c]
    puts "sta: clock $name, $period ns"
    puts $out "clock $name $period"
    if {[string match {*u_pll*outclk*} $name] || [string match {*u_pll*out_clk*} $name]} {
        lappend machine_clocks $name $period
    }
    foreach_in_collection target [get_clock_info -targets $c] {
        if {[get_object_info -name $target] eq "clock50_0"} {
            lappend board_clocks $name $period
        }
    }
}
if {[llength $machine_clocks] != 2
        || [format %.3f [lindex $machine_clocks 1]] ne [format %.3f $tick_ns]} {
    puts "sta: FAIL: wanted one clock out of the PLL at $tick_ns ns, found: $machine_clocks"
    incr failures
} else {
    puts "sta: the fabric's clock is [lindex $machine_clocks 0], $tick_ns ns, the tick"
}
if {[llength $board_clocks] != 2
        || [format %.3f [lindex $board_clocks 1]] ne [format %.3f $board_ns]} {
    puts "sta: FAIL: wanted one clock on clock50_0 at $board_ns ns, found: $board_clocks"
    incr failures
} else {
    puts "sta: the board's clock is [lindex $board_clocks 0] on clock50_0, $board_ns ns"
}

set worst_setup ""
set worst_hold ""
foreach cond [get_available_operating_conditions] {
    set_operating_conditions $cond
    update_timing_netlist
    set s [report_timing -setup -npaths 1 -detail full_path -file timing_setup_$cond.txt]
    set h [report_timing -hold  -npaths 1 -detail full_path -file timing_hold_$cond.txt]
    set s_slack [lindex $s 1]
    set h_slack [lindex $h 1]
    puts "sta: $cond: setup [format %+.3f $s_slack] ns, hold [format %+.3f $h_slack] ns"
    puts $out "corner $cond setup $s_slack hold $h_slack"
    if {$worst_setup eq "" || $s_slack < $worst_setup} { set worst_setup $s_slack }
    if {$worst_hold  eq "" || $h_slack < $worst_hold}  { set worst_hold  $h_slack }
}
puts "sta: worst setup [format %+.3f $worst_setup] ns, worst hold [format %+.3f $worst_hold] ns, over every corner"
puts $out "worst setup $worst_setup hold $worst_hold"

set met [expr {$worst_setup >= 0 && $worst_hold >= 0}]
if {!$met} {
    puts "sta: TIMING IS NOT MET.  The bitstream will still be written, and"
    puts "sta: program.sh will refuse it."
}
if {$failures > 0} {
    puts $out "verdict refused"
} elseif {$met} {
    puts $out "verdict met"
} else {
    puts $out "verdict failed"
}
close $out

delete_timing_netlist
project_close
exit [expr {$failures > 0 ? 1 : 0}]
