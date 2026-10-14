# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The timing analyzer's checks of QUUX revision 15 on the DE25-Nano
# (`boards/de25-nano/quux15_de25.sv`), run by `build.sh` in the build
# directory after the fit as
#
#     QUUX15_PERIOD_NS=<period> CADR_PIXEL_MHZ=<mode> quartus_sta -t quux15_sta_check.tcl
#
# `sta_check.tcl`'s questions for a machine with no exception: every line it
# prints for the build log starts with `sta:`, it writes `timing.txt`, and it
# exits non-zero on a failure, which `build.sh` refuses.
#
#   1. The clocks.  Exactly one out of the machine's PLL, at the period
#      `build.sh` asked the PLL for, to the picosecond, and so not the tick:
#      the analyzer's clock is what the constraints describe, so a PLL that
#      made another period is a build whose constraints describe another
#      machine.  The board's 20 ns on `clock50_0`.
#   2. The pixel clock and the display's crossings, as `sta_check.tcl` asks
#      them, the same file's clauses.
#   3. The pins: KEY1, the LEDs and the board's clock are ports, and the
#      debug cable's eight pads are ports no timed path reaches.
#   4. **NO PATH ON THE MACHINE'S CLOCK ASKS FOR MORE THAN THE PERIOD**:
#      revision 15 is timed at one clock, so a relaxed requirement anywhere
#      would be an exception nobody wrote down.
#   5. The PLL's lock into the fabric reset's synchronizer, and the
#      processor's crossings (`quux15_de25.sdc`): the five first
#      synchronizer registers and the registers the processor samples, each
#      named and none timed; and the processor system's reset synchronizers.
#   6. Asynchronous clears across two clocks, refused (`sta_common.tcl`).
#   7. Every corner's worst slack of each kind, written to `timing.txt`.

package require ::quartus::sta

set board_ns 20.000
if {![info exists ::env(QUUX15_PERIOD_NS)]} {
    puts "sta: FAIL: no QUUX15_PERIOD_NS: build.sh says which period it asked the PLL for"
    exit 1
}
set period_ns $::env(QUUX15_PERIOD_NS)

project_open cadr_de25
create_timing_netlist
read_sdc
update_timing_netlist

set failures 0
set out [open timing.txt w]

source [file join [file dirname [file normalize [info script]]] sta_common.tcl]

# ------------------------------------------------------------- the clocks
set machine_clocks {}
foreach_in_collection c [get_clocks] {
    set name   [get_clock_info -name $c]
    set period [get_clock_info -period $c]
    puts "sta: clock $name, $period ns"
    puts $out "clock $name $period"
    if {[string match {*u_pll*outclk*} $name] || [string match {*u_pll*out_clk*} $name]} {
        lappend machine_clocks $name $period
    }
}
if {[llength $machine_clocks] != 2} {
    puts "sta: FAIL: wanted exactly one clock out of the PLL, found [expr {[llength $machine_clocks] / 2}]"
    incr failures
} else {
    set period [lindex $machine_clocks 1]
    if {abs($period - $period_ns) > 0.0005} {
        puts "sta: FAIL: the machine's clock is $period ns, and the period asked is $period_ns ns"
        incr failures
    } else {
        puts "sta: the machine's clock is [lindex $machine_clocks 0], $period ns, the period asked"
    }
}

set board_clocks {}
foreach_in_collection c [get_clocks] {
    foreach_in_collection target [get_clock_info -targets $c] {
        if {[get_object_info -name $target] eq "clock50_0"} {
            lappend board_clocks [get_clock_info -name $c] [get_clock_info -period $c]
        }
    }
}
if {[llength $board_clocks] != 2} {
    puts "sta: FAIL: wanted exactly one clock on clock50_0, found [expr {[llength $board_clocks] / 2}]"
    incr failures
} elseif {[format %.3f [lindex $board_clocks 1]] ne [format %.3f $board_ns]} {
    puts "sta: FAIL: the clock on clock50_0 is [lindex $board_clocks 1] ns, and the board's is $board_ns"
    incr failures
} else {
    puts "sta: the board's clock is [lindex $board_clocks 0] on clock50_0, [lindex $board_clocks 1] ns"
}

# ------------------------------------------------------ the pixel clock
#
# **WHEN THE DISPLAY IS BUILT.**  `build.sh` puts the mode's frequency in
# `CADR_PIXEL_MHZ`, and zero when there is no display; the clock the analyzer
# derived from the generated PLL is compared with it.
#
# **THE TOLERANCE IS HALF A PER CENT, AND THAT IS A NUMBER WITH A REASON.**  A
# counter chain rarely lands on a frequency exactly: 108 MHz from 50 is 54
# over 25 and is exact, but 101 is 101 over 50 and its oscillator would be
# 5.05 GHz, so that mode's clock is whatever the generator can reach.  A
# monitor accepts far more --- the Arty Z7-20's three modes are 0.17, 0.22 and
# 0.04 per cent low, and `docs/display-output.md` says why that does not
# matter.  What the bound is for is a mistyped parameter, and those are not
# roundings: the three frequencies differ from each other by six per cent and
# thirty, and a transposed digit by hundreds.
set pixel_mhz 0
if {[info exists ::env(CADR_PIXEL_MHZ)]} { set pixel_mhz $::env(CADR_PIXEL_MHZ) }
set display_built [expr {[get_collection_size [get_registers -nowarn {u_display|*}]] > 0}]
if {!$display_built} {
    puts "sta: the display output is not in this build"
    if {$pixel_mhz > 0} {
        puts "sta: FAIL: the flow asked for a pixel clock of $pixel_mhz MHz and there is no display"
        incr failures
    }
} else {
    if {$pixel_mhz <= 0} {
        puts "sta: FAIL: the display is in this build and the flow named no pixel clock"
        incr failures
    }
    set pixel_clocks {}
    foreach_in_collection c [get_clocks] {
        set name [get_clock_info -name $c]
        if {[string match {*u_pixel_clock*outclk*} $name]
            || [string match {*u_pixel_clock*out_clk*} $name]} {
            lappend pixel_clocks $name [get_clock_info -period $c]
        }
    }
    if {[llength $pixel_clocks] != 2} {
        puts "sta: FAIL: wanted exactly one clock out of the pixel PLL, found [expr {[llength $pixel_clocks] / 2}]"
        incr failures
    } elseif {$pixel_mhz > 0} {
        set got [lindex $pixel_clocks 1]
        set want [expr {1000.0 / $pixel_mhz}]
        if {abs($got - $want) > 0.005 * $want} {
            puts "sta: FAIL: the pixel clock is $got ns and the mode's is [format %.4f $want] ns"
            incr failures
        } else {
            puts "sta: the pixel clock is [lindex $pixel_clocks 0], [format %.4f $got] ns,\
                  [format %.4f [expr {1000.0 / $got}]] MHz, and the mode asks $pixel_mhz MHz"
        }
        # **AND THE TRANSMITTER'S OWN CEILING, AGAINST WHAT THE PLL MADE AND
        # NOT AGAINST WHAT IT WAS ASKED FOR.**  The ADV7513's data sheet in
        # the board's resource package --- Rev. B, page 3 of 12, Table 1 under
        # AC SPECIFICATIONS --- gives its Input Video Clock Frequency a
        # maximum of 165 MHz.  `build.sh` refuses a mode whose specification
        # asks more than that; this one refuses a clock the generator actually
        # made above it, which is the number the part will see.  The two are
        # not the same check: a PLL asked for 148.5 and landing on 166 would
        # pass the first and fail this.
        set made_mhz [expr {1000.0 / $got}]
        if {$made_mhz > 165.0} {
            puts "sta: FAIL: the pixel clock is [format %.4f $made_mhz] MHz and the\
                  ADV7513 takes 165 MHz at most (data sheet Rev. B, Table 1)"
            incr failures
        }
    }
    # **THE FORWARDED CLOCK, AND THE PINS TIMED AGAINST IT.**  A video pin
    # with no output delay is a path nobody is timing, and a report with
    # nothing failing on it.
    set fwd [get_clocks -nowarn {cadr_hdmi_pclk}]
    if {[get_collection_size $fwd] != 1} {
        puts "sta: FAIL: cadr_hdmi.sdc left no generated clock on hdmi_pclk"
        incr failures
    } else {
        puts "sta: the forwarded clock on hdmi_pclk is [format %.4f [get_clock_info -period $fwd]] ns"
    }
    set video [get_ports -nowarn {hdmi_d[*] hdmi_de hdmi_hsync hdmi_vsync}]
    if {[get_collection_size $video] != 27} {
        puts "sta: FAIL: the video bus names [get_collection_size $video] ports, wanting 27"
        incr failures
    }
    # **AND IT IS ASKED AS A PATH AND NOT AS A CONSTRAINT.**  Reading the
    # constraint back would say an output delay was written; what matters is
    # that the analyzer TIMES the path, which is the thing an output delay
    # exists to make it do.  A port with no output delay has no timing path
    # to it, so the path is the honest question --- and the first writing of
    # this asked `get_output_delay_info`, which is not a command this tool
    # has, and the whole check died at the unknown name.
    set untimed 0
    foreach_in_collection port $video {
        set name [get_object_info -name $port]
        if {[get_collection_size [get_timing_paths -setup -to $name -npaths 1]] == 0} {
            incr untimed
        }
    }
    if {$untimed > 0} {
        puts "sta: FAIL: $untimed of the video pins have no timed path to them"
        incr failures
    } else {
        puts "sta: all [get_collection_size $video] video pins are timed against the forwarded clock"
    }
    # AND THE PIXEL PLL'S LOCK IS CUT AT ITS SYNCHRONIZER'S FIRST REGISTER,
    # which `cadr_hdmi.sdc` does and gives the reason for.  Both halves are
    # asked: that the cut named the register, and that nothing timed ends
    # there.  A cut that reached nothing looks exactly like one that worked.
    if {![info exists ::cadr_prst_first]} {
        puts "sta: FAIL: cadr_hdmi.sdc left no collection named cadr_prst_first"
        incr failures
    } elseif {[get_collection_size $::cadr_prst_first] != 1} {
        puts "sta: FAIL: the raster's reset synchronizer's first register:\
              [get_collection_size $::cadr_prst_first], wanting 1"
        incr failures
    } else {
        # The register's own data pin, named here rather than through
        # `data_pins`: that proc is declared further down this file, with the
        # machine's clauses, and calling it from up here died on an unknown
        # command the first time.
        set timed [get_collection_size [get_timing_paths -setup \
                       -to [get_pins -nowarn {prst_sync[0]|d}] -npaths 10]]
        if {$timed > 0} {
            puts "sta: FAIL: $timed timed paths end at the raster's reset synchronizer's first register"
            incr failures
        } else {
            puts "sta: the pixel PLL's lock is cut at the raster's reset synchronizer's first register"
        }
    }
    # AND THE TWO CLOCKS DO NOT MEET.  The display crosses between the
    # machine's clock and the pixel clock only through its own handshakes, and
    # a path timed between them is what the asynchronous group is for.
    if {[llength $machine_clocks] == 2 && [llength $pixel_clocks] == 2} {
        set mclk [get_clocks [lindex $machine_clocks 0]]
        set pclk [get_clocks [lindex $pixel_clocks 0]]
        set there [get_collection_size [get_timing_paths -setup -from_clock $mclk -to_clock $pclk -npaths 10]]
        set back  [get_collection_size [get_timing_paths -setup -from_clock $pclk -to_clock $mclk -npaths 10]]
        if {$there + $back > 0} {
            puts "sta: FAIL: $there paths from the machine's clock to the pixel clock and $back back are timed"
            incr failures
        } else {
            puts "sta: the display crosses between the machine's clock and the pixel clock,\
                  and no path between them is timed"
        }
    }
}

# ------------------------------------------------------------- the pins
foreach {pattern want} {{btn[1]} 1 {led[*]} 8 {clock50_0} 1 {jp1_pin3*} 8} {
    set n [get_collection_size [get_ports -nowarn $pattern]]
    if {$n != $want} {
        puts "sta: FAIL: `$pattern` names $n ports, wanting $want"
        incr failures
    } else {
        puts "sta: `$pattern` names $n ports"
    }
}
if {![info exists ::dbg_pads]} {
    puts "sta: FAIL: quux15_de25.sdc left no collection named dbg_pads"
    incr failures
} else {
    set timed [expr {[get_collection_size [get_timing_paths -setup -from $::dbg_pads -npaths 20]] \
                     + [get_collection_size [get_timing_paths -setup -to $::dbg_pads -npaths 20]]}]
    if {$timed > 0} {
        puts "sta: FAIL: $timed timed paths reach JP1's pads, which QUUX neither drives nor reads"
        incr failures
    } else {
        puts "sta: JP1's 8 pads are ports of this build and no path through them is timed"
    }
}

# ------------------------------------- one clock, and no exception in it
if {[llength $machine_clocks] == 2} {
    set mclk [get_clocks [lindex $machine_clocks 0]]
    set hist {}
    set over 0
    set first ""
    foreach_in_collection p [get_timing_paths -setup -from_clock $mclk -to_clock $mclk \
                                 -npaths 200000 -nworst 1] {
        set rel [get_path_info $p -clock_relationship]
        dict incr hist [format %.3f $rel]
        if {$rel > $period_ns + 0.001} {
            incr over
            if {$first eq ""} {
                set first "[get_node_info -name [get_path_info $p -from]] ->\
                           [get_node_info -name [get_path_info $p -to]] at $rel ns"
            }
        }
    }
    set n [expr {[dict exists $hist [format %.3f $period_ns]] ? [dict get $hist [format %.3f $period_ns]] : 0}]
    if {$over > 0} {
        puts "sta: FAIL: $over endpoints on the machine's clock ask for more than $period_ns ns; first: $first"
        incr failures
    } elseif {$n == 0} {
        puts "sta: FAIL: no endpoint on the machine's clock asks for $period_ns ns"
        incr failures
    } else {
        puts "sta: $n endpoints on the machine's clock, every one at $period_ns ns or less: no exception"
    }
}

# ------------------------------------------- the processor's crossings
foreach {sta_what sta_var sta_want} {{the processor's asynchronous bits' first registers} ddr_crossing 5} {
    if {![info exists ::$sta_var]} {
        puts "sta: FAIL: quux15_de25.sdc left no collection named $sta_var"
        incr failures
        continue
    }
    set n [get_collection_size [set ::$sta_var]]
    if {$n != $sta_want} {
        puts "sta: FAIL: $sta_what: $n, wanting $sta_want"
        incr failures
    } else {
        puts "sta: $sta_what: $n"
    }
}
if {![info exists ::ddr_to_hps] || [get_collection_size $::ddr_to_hps] < 2} {
    puts "sta: FAIL: quux15_de25.sdc names fewer than two registers the processor samples"
    incr failures
} else {
    set timed [get_collection_size [get_timing_paths -setup -from $::ddr_to_hps -npaths 100]]
    if {$timed > 0} {
        puts "sta: FAIL: $timed timed paths start at a register the processor samples on its own clock"
        incr failures
    } else {
        puts "sta: [get_collection_size $::ddr_to_hps] registers the processor samples, and no timed path starts at one"
    }
}
if {[info exists ::ddr_crossing] && [get_collection_size $::ddr_crossing] > 0} {
    set to_d {}
    foreach_in_collection r $::ddr_crossing { lappend to_d "[get_register_info -name $r]|d" }
    set timed [get_collection_size [get_timing_paths -setup -to [get_pins -nowarn $to_d] -npaths 100]]
    if {$timed > 0} {
        puts "sta: FAIL: $timed timed paths end at a first synchronizer register"
        incr failures
    } else {
        puts "sta: no timed path ends at the processor's bits' first registers"
    }
}
# The lock reaches two synchronizers: the fabric reset's, with KEY1, and the
# machine's hard reset's, the lock alone.
if {![info exists ::lock_crossing] || [get_collection_size $::lock_crossing] != 2} {
    puts "sta: FAIL: quux15_de25.sdc does not name both registers the PLL's lock's synchronizers start at"
    incr failures
} else {
    set timed [get_collection_size [get_timing_paths -setup -to [get_pins -nowarn {rst_sync[0]|d lock_sync[0]|d}] -npaths 10]]
    if {$timed > 0} {
        puts "sta: FAIL: $timed timed paths end at the PLL's lock's first synchronizer registers"
        incr failures
    } else {
        puts "sta: no timed path ends at the PLL's lock's first synchronizer registers, the fabric reset's and the hard reset's"
    }
}
sta_hps_reset_sync

# ------------------------------------ asynchronous clears across two clocks
sta_async_across_clocks

# ------------------------------------------------------------ the corners
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
