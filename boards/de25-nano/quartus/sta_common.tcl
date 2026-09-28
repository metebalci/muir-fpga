# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The timing analyzer's questions that the CADR's builds and the fault
# bitstream both ask, written once.  `sta_check.tcl` and `fault_sta.tcl`
# source this file after `read_sdc`, and each of the three procedures below
# adds to the caller's global `failures` rather than exiting, so that each
# script still writes its own `timing.txt` and its own verdict.
#
#   sta_hps_reset_sync      the processor system's three reset synchronizers:
#                           `hps_reset.sdc`'s cut reached their six clear pins
#                           and the processor's one reset output, and no
#                           recovery or removal path ends at those pins.
#   sta_async_across_clocks no asynchronous clear is timed from one clock into
#                           another, whatever its slack.
#   sta_corners             every corner's worst setup, hold, recovery and
#                           removal, printed and written to `timing.txt`; it
#                           returns whether all of them are met.

# **THE PROCESSOR SYSTEM'S THREE RESET SYNCHRONIZERS**, `hps_reset.sdc`'s cut
# from `s2f_rst` to their six `clrn` pins, which that file gives Altera's
# reason for.  Six and one: a renamed register or a renamed pin leaves the cut
# reaching nothing, and a pattern grown wider takes in a clear that is not a
# synchronizer's.  And a cut that reached its pins leaves no recovery or
# removal path ending at them; `sta_corners` then asks every other
# asynchronous clear in the design.  Asked of every build with the processor
# system in it, the memory board and the fault bitstream alike.
proc sta_hps_reset_sync {} {
    global failures
    foreach {sta_what sta_var sta_want} {{the reset synchronizers' clears} hps_rst_clrn 6
                                         {the processor's reset output} hps_s2f_rst 1} {
        if {![info exists ::$sta_var]} {
            puts "sta: FAIL: hps_reset.sdc left no collection named $sta_var"
            incr failures
        } elseif {[get_collection_size [set ::$sta_var]] != $sta_want} {
            puts "sta: FAIL: $sta_what: [get_collection_size [set ::$sta_var]], wanting $sta_want"
            incr failures
        } else {
            puts "sta: $sta_what: $sta_want"
        }
    }
    if {[info exists ::hps_rst_clrn] && [get_collection_size $::hps_rst_clrn] > 0} {
        set sta_rec [get_collection_size [get_timing_paths -recovery -to $::hps_rst_clrn -npaths 100]]
        set sta_rem [get_collection_size [get_timing_paths -removal  -to $::hps_rst_clrn -npaths 100]]
        if {$sta_rec + $sta_rem > 0} {
            puts "sta: FAIL: $sta_rec recovery and $sta_rem removal paths end at the reset synchronizers' clears"
            incr failures
        } else {
            puts "sta: no recovery or removal path ends at the processor system's reset synchronizers"
        }
    }
}

# **AN ASYNCHRONOUS CLEAR TIMED FROM ONE CLOCK INTO ANOTHER IS REFUSED,
# WHATEVER ITS SLACK.**  A clear released by one clock and checked against
# another's edge is a clock crossing, and a recovery or removal slack between
# two clocks with no fixed relation measures only where the fitter happened
# to put the two ends: the processor system's synchronizers failed removal
# by 0.67 ns, and the same crossing placed further from the processor would
# have passed and been no safer.  The answer to one is a reset synchronizer
# whose clear is cut, as `hps_reset.sdc` cuts the processor system's.  So
# every recovery and removal path is asked for its two clocks, and one whose
# launching clock is not its latching clock stops the flow.
proc sta_async_across_clocks {} {
    global failures
    foreach sta_kind {recovery removal} {
        set sta_n 0
        set sta_first ""
        foreach_in_collection p [get_timing_paths -$sta_kind -npaths 100000 -nworst 1] {
            set sta_from ""
            set sta_to ""
            catch {set sta_from [get_clock_info -name [get_path_info $p -from_clock]]}
            catch {set sta_to   [get_clock_info -name [get_path_info $p -to_clock]]}
            if {$sta_from ne $sta_to} {
                incr sta_n
                if {$sta_first eq ""} {
                    set sta_first "[get_node_info -name [get_path_info $p -from]] ($sta_from) ->\
                                   [get_node_info -name [get_path_info $p -to]] ($sta_to)"
                }
            }
        }
        if {$sta_n > 0} {
            puts "sta: FAIL: $sta_n $sta_kind paths are timed from one clock into another; first: $sta_first"
            incr failures
        } else {
            puts "sta: no $sta_kind path is timed from one clock into another"
        }
    }
}

# **SETUP, HOLD, RECOVERY AND REMOVAL, AT EVERY CORNER.**  Recovery and
# removal are setup and hold for an asynchronous clear or preset: how long
# before and after the capturing clock's edge a register's clear may be
# released.  They were not asked until a fit whose summary said "met" had six
# endpoints failing removal by 0.67 ns, which the timing analyzer's own report
# showed and no script here read.  A design with no asynchronous-clear path
# at all has no recovery or removal path, and `report_timing` then gives
# "0 0.000"; that is written as "none" rather than as a slack nobody
# measured.  Each corner's line and the worst line go to `out`, the caller's
# `timing.txt`, and the return value is 1 when every kind that has a path
# has met at every corner.
proc sta_corners {out} {
    global failures
    set sta_kinds {setup hold recovery removal}
    foreach sta_kind $sta_kinds { set sta_worst($sta_kind) "" }
    foreach cond [get_available_operating_conditions] {
        set_operating_conditions $cond
        update_timing_netlist
        set sta_said {}
        set sta_line "corner $cond"
        foreach sta_kind $sta_kinds {
            set r [report_timing -$sta_kind -npaths 1 -detail full_path -file timing_${sta_kind}_$cond.txt]
            if {[lindex $r 0] == 0} {
                lappend sta_said "$sta_kind none"
                append sta_line " $sta_kind none"
                continue
            }
            set slack [lindex $r 1]
            lappend sta_said "$sta_kind [format %+.3f $slack] ns"
            append sta_line " $sta_kind $slack"
            if {$sta_worst($sta_kind) eq "" || $slack < $sta_worst($sta_kind)} { set sta_worst($sta_kind) $slack }
        }
        puts "sta: $cond: [join $sta_said {, }]"
        puts $out $sta_line
    }
    set sta_said {}
    set sta_line "worst"
    set met 1
    foreach sta_kind $sta_kinds {
        if {$sta_worst($sta_kind) eq ""} {
            lappend sta_said "no $sta_kind path"
            append sta_line " $sta_kind none"
            continue
        }
        lappend sta_said "worst $sta_kind [format %+.3f $sta_worst($sta_kind)] ns"
        append sta_line " $sta_kind $sta_worst($sta_kind)"
        if {$sta_worst($sta_kind) < 0} { set met 0 }
    }
    # Setup and hold always have paths in a design with a clocked register in
    # it, the fault bitstream's lamp among them, and a build that reports none
    # of either has lost its clocks.
    foreach sta_kind {setup hold} {
        if {$sta_worst($sta_kind) eq ""} {
            puts "sta: FAIL: no $sta_kind path at any corner"
            incr failures
        }
    }
    puts "sta: [join $sta_said {, }], over every corner"
    puts $out $sta_line
    return $met
}
