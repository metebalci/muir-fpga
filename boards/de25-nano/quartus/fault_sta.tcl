# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The timing analyzer's verdict on the DE25-Nano's fault bitstream, run by
# `build.sh` in place of `sta_check.tcl` when `FAULT=1`.  That file asks its
# questions of the machine's exceptions, and this design has no machine, so
# what is left is its first and last parts: the two clocks are the board's
# 20 ns and the 10 ns tick; the processor system's three reset synchronizers
# are cut by `hps_reset.sdc` and nothing recovery or removal times ends at
# them; no asynchronous clear is timed from one clock into another; and every
# corner's worst setup, hold, recovery and removal slack, written to
# `timing.txt` in the same words, which `build.sh` and `program.sh` read.
# The last three are `sta_common.tcl`'s, the same procedures `sta_check.tcl`
# calls, because the fault bitstream carries the memory board's processor
# system and so its synchronizers.

package require ::quartus::sta

set tick_ns 10.000
set board_ns 20.000

project_open cadr_de25
create_timing_netlist
read_sdc
update_timing_netlist

set failures 0
set out [open timing.txt w]

source [file join [file dirname [file normalize [info script]]] sta_common.tcl]

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

# The processor system's reset synchronizers, asynchronous clears across two
# clocks, and the corners, as the CADR's builds ask them.
sta_hps_reset_sync
sta_async_across_clocks
set met [sta_corners $out]

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
