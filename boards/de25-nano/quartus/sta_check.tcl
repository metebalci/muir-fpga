# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# What the timing analyzer says about the DE25-Nano's fit, asked rather than
# assumed.  Run by `boards/de25-nano/quartus/build.sh` as
#
#     quartus_sta -t sta_check.tcl
#
# in the build directory, after the fitter.  It writes `timing.txt` there,
# whose last line `boards/de25-nano/quartus/program.sh` reads before it will
# program a board, and it exits non-zero when any of the first three things
# below is not so.  The fourth is the verdict, which is written and not
# refused on.
#
#   1. THE CLOCKS ARE THE BOARD'S AND THE TICK.  Both periods come from the
#      generated PLL, through the constraints the IP writes for itself.  The
#      one on `clock50_0` must be 20 ns, the manual's 50 MHz, and the PLL's
#      output must be 10 ns: every board literal in
#      `boards/de25-nano/cadr_de25.sv` and in the lamp modules is written
#      against that tick, and the machine's own counts are MIT's instants on
#      a 10 ns grid.  A PLL generated from a mistyped parameter would still
#      lock, still light the lamps and run a different machine.
#
#   2. THE EXCEPTIONS REACH WHAT THEY NAME.  `cadr_de25.sdc` cuts the paths
#      from the two buttons and SW0 and to the eight LEDs.  A pattern that
#      matches nothing is silent in a log, so the collections are counted
#      here.  SW1 to SW3 reach no logic and have no port in the timing
#      netlist, measured, so `sw[*]` is one port.
#
#   3. THE MACHINE'S EXCEPTIONS REACH THE PATHS THEIR ARGUMENT IS ABOUT, AND
#      NO OTHERS.  `cadr_de25.sdc` writes `cadr_machine.xdc`'s three clauses
#      again, and `constraints_check.tcl`'s questions are asked of them here
#      in Quartus's words: the relaxed set reached the design; no register
#      outside the machine carries a relaxed requirement; and for the two
#      instance clauses, the named registers carry it and no other register
#      of the instance does.  A pattern that matches nothing, or matches too
#      much, looks exactly like one that works until a path is asked what it
#      is required to do.
#
#   And when the display is built, THE DISPLAY'S OWN THREE, from
#      `cadr_hdmi.sdc`: the pixel clock exists at the mode's frequency, which
#      `build.sh` passes in as `CADR_PIXEL_MHZ` from the mode it asked the PLL
#      generator for --- a PLL generated from a mistyped frequency would still
#      lock and draw a raster nothing can display; the forwarded clock exists
#      on `hdmi_pclk` and the twenty-seven video pins carry an output delay
#      against it, because a video pin with no output delay is a path nobody
#      is timing and a report with no failure on it; and nothing is timed
#      between the machine's clock and the pixel clock, which is what the
#      asynchronous group between them is for.
#
#   And when the probe is built, THE PROBE'S TWO CLAUSES, from
#      `cadr_probe.sdc`: the JTAG clock exists at its bound and nothing is
#      timed between it and the machine's clock, and of the probe's
#      registers `stable_q` carries the microcycle and no other does.
#
#   4. EVERY CORNER, SETUP AND HOLD.  Each operating condition the part has is
#      analyzed and its worst slack printed.  A negative one is reported as a
#      failure and written to `timing.txt`, and the bitstream is still
#      written, because a flow that works and a design that closes are two
#      questions.

package require ::quartus::sta

set tick_ns 10.000
set board_ns 20.000
set tick $tick_ns

project_open cadr_de25
create_timing_netlist
read_sdc
update_timing_netlist

set failures 0
set out [open timing.txt w]

# ------------------------------------------------------------- the clocks
set machine_clocks {}
foreach_in_collection c [get_clocks] {
    set name   [get_clock_info -name $c]
    set period [get_clock_info -period $c]
    puts "sta: clock $name, $period ns"
    puts $out "clock $name $period"
    # The PLL's output counter drives the machine.  The IP names it after the
    # instance, `u_pll`, and its output counter.
    if {[string match {*u_pll*outclk*} $name] || [string match {*u_pll*out_clk*} $name]} {
        lappend machine_clocks $name $period
    }
}
if {[llength $machine_clocks] != 2} {
    puts "sta: FAIL: wanted exactly one clock out of the PLL, found [expr {[llength $machine_clocks] / 2}]"
    incr failures
} else {
    set period [lindex $machine_clocks 1]
    if {[format %.3f $period] ne [format %.3f $tick_ns]} {
        puts "sta: FAIL: the machine's clock is $period ns, and the tick is $tick_ns"
        incr failures
    } else {
        puts "sta: the machine's clock is [lindex $machine_clocks 0], $period ns, the tick"
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

# --------------------------------------------------------- the exceptions
foreach {pattern want} {{btn[*]} 2 {sw[*]} 1 {led[*]} 8 {clock50_0} 1} {
    set n [get_collection_size [get_ports -nowarn $pattern]]
    if {$n != $want} {
        puts "sta: FAIL: `$pattern` names $n ports, wanting $want"
        incr failures
    } else {
        puts "sta: `$pattern` names $n ports"
    }
}

# ------------------------------------------ the machine's three clauses
#
# Every setup requirement below is read off a path, as the clock
# relationship Quartus gives it, and compared with a count of ticks: the
# multicycle that made it and the argument that allowed it.

# The worst setup path into each of `targets`, as a dict of requirement in ns
# to the number of endpoints asking for it.
proc requirements {targets} {
    set hist {}
    if {[get_collection_size $targets] == 0} { return $hist }
    foreach_in_collection path [get_timing_paths -setup -to $targets -npaths 200000 -nworst 1] {
        dict incr hist [format %.3f [get_path_info -clock_relationship $path]]
    }
    return $hist
}

# The `d` pins of a set of registers: a requirement is a property of the
# data pin, and an exception written on the register would have reached its
# clock enable too.
proc data_pins {registers} {
    set names {}
    foreach_in_collection r $registers { lappend names "[get_register_info -name $r]|d" }
    if {[llength $names] == 0} { return [get_pins -nowarn {cadr_no_such_pin}] }
    return [get_pins -nowarn $names]
}

proc said {hist} {
    set words {}
    foreach k [lsort -real [dict keys $hist]] { lappend words "[dict get $hist $k] at $k ns" }
    return [join $words ", "]
}

# THE RELAXED SET REACHED THE DESIGN: some endpoint's worst setup path asks
# for `cycles` ticks.  A set that matched nothing leaves every path at one
# tick, and that is the unconstrained design reported as if it were this one.
proc assert_multicycle_applied {period cycles} {
    global failures
    set want [format %.3f [expr {$period * $cycles}]]
    set hist [requirements [get_keepers -nowarn *]]
    set n [expr {[dict exists $hist $want] ? [dict get $hist $want] : 0}]
    if {$n == 0} {
        puts "sta: FAIL: no endpoint asks for $want ns, so the relaxed set reached nothing; endpoints: [said $hist]"
        incr failures
    } else {
        puts "sta: $n endpoints ask for $want ns: the machine's relaxed set reached the design"
    }
    return $n
}

# NOTHING OUTSIDE THE MACHINE IS RELAXED: every register outside `u_machine`
# is timed at no more than a period and a half of the clock that latches it.
# The latching clock's own period and not the tick, because the probe's JTAG
# side is clocked by TCK, whose 30 ns is a clock and not an exception.
# `exempt` is registers another clause relaxes on purpose and asserts itself.
proc assert_constraints_scoped {exempt} {
    global failures
    set outside [remove_from_collection [get_registers -nowarn *] [get_registers -nowarn {u_machine|*}]]
    # An empty collection is not one `remove_from_collection` takes, and the
    # plain build's exemption is empty.
    if {[get_collection_size $exempt] > 0} {
        set outside [remove_from_collection $outside $exempt]
    }
    set caught 0
    set targets [data_pins $outside]
    if {[get_collection_size $targets] > 0} {
        foreach_in_collection path [get_timing_paths -setup -to $targets -npaths 200000 -nworst 1] {
            set period [get_clock_info -period [get_path_info -to_clock $path]]
            if {[get_path_info -clock_relationship $path] > 1.5 * $period} { incr caught }
        }
    }
    if {$caught > 0} {
        puts "sta: FAIL: $caught registers outside the machine carry a relaxed requirement"
        incr failures
    } else {
        puts "sta: no register outside the machine is relaxed ([get_collection_size $outside] registers asked,\
              [get_collection_size $exempt] exempt by the probe's and the memory port's own clauses)"
    }
}

# THE SPLIT OF ONE INSTANCE TOOK: of the registers under `instance`, those
# whose leaf is one of `relaxed` must carry `cycles` ticks on at least one
# path, and no other may, except those whose leaf is one of `elsewhere`,
# which another clause relaxes to the same count and are left out of both.
proc assert_instance_timing {period cycles instance relaxed {elsewhere {}}} {
    global failures
    set want [format %.3f [expr {$period * $cycles}]]
    set all [get_registers -nowarn "${instance}|*"]
    if {[get_collection_size $all] == 0} {
        puts "sta: FAIL: no register matched ${instance}|*, so the clause naming it is empty"
        incr failures
        return
    }
    set named [get_registers -nowarn [cadr_leaves "${instance}|" $relaxed]]
    set rest [remove_from_collection $all $named]
    set n_other 0
    if {[llength $elsewhere] > 0} {
        set other [get_registers -nowarn [cadr_leaves "${instance}|" $elsewhere]]
        set n_other [get_collection_size $other]
        set rest [remove_from_collection $rest $other]
    }
    set kept [requirements [data_pins $named]]
    set swallowed [requirements [data_pins $rest]]
    set n_kept [expr {[dict exists $kept $want] ? [dict get $kept $want] : 0}]
    set n_swallowed [expr {[dict exists $swallowed $want] ? [dict get $swallowed $want] : 0}]
    puts "sta: $instance: [get_collection_size $all] registers, [get_collection_size $named] meant relaxed,\
          [get_collection_size $rest] meant at the tick, $n_other relaxed by another clause"
    if {$n_swallowed > 0} {
        puts "sta: FAIL: $n_swallowed registers of $instance that must be timed at the tick ask for $want ns"
        incr failures
    } elseif {$n_kept == 0} {
        puts "sta: FAIL: no register $relaxed of $instance asks for $want ns, so the clause reached nothing"
        incr failures
    } else {
        puts "sta: $instance: $n_kept capture registers at $want ns and none of the others: the split took"
    }
}

# The same leaf patterns `cadr_de25.sdc` names registers by.
if {[llength [info procs cadr_leaves]] == 0} {
    proc cadr_leaves {prefix names} {
        set patterns {}
        foreach name $names { lappend patterns "${prefix}${name}" "${prefix}${name}\[*\]" }
        return $patterns
    }
}

# THE THREE COLLECTIONS THEMSELVES, as `cadr_de25.sdc` left them.  An empty
# one is a clause that reached nothing, whatever the paths below then say.
# **THE LOOP'S VARIABLES ARE NAMED APART FROM EVERY SHORT WORD**, because the
# constraint files share this interpreter: the processor system's generated
# SDC files are read into it too, and one of them leaves an ARRAY called
# `var`, on which `foreach {what var}` fails with "variable is array".
# Measured on the first memory board build.
foreach {sta_what sta_var} {{the relaxed set} slow {its tick-rate exclusions} fast
                    {the held decodes put back} held {the display's word pins} bus_word
                    {the Unibus map's word pins} ub_strobe} {
    if {![info exists ::$sta_var]} {
        puts "sta: FAIL: cadr_de25.sdc left no collection named $sta_var"
        incr failures
        continue
    }
    set n [get_collection_size [set ::$sta_var]]
    puts "sta: $sta_what: $n"
    if {$n == 0 && $sta_var ne "bus_word"} {
        puts "sta: FAIL: $sta_what is empty"
        incr failures
    }
}
# THE PROBE, WHEN IT IS BUILT.  Its registers are under `g_probe.u_probe`.
set probe [get_registers -nowarn {g_probe.u_probe|*}]
set probe_stable [get_registers -nowarn {g_probe.u_probe|stable_q[*]}]
if {[get_collection_size $probe] == 0} {
    puts "sta: the probe is not in this build"
} else {
    # The JTAG clock `cadr_probe.sdc` declares, at the bound it gives.
    set tck [get_clocks -nowarn {altera_reserved_tck}]
    if {[get_collection_size $tck] != 1} {
        puts "sta: FAIL: the probe is built and there is no clock altera_reserved_tck"
        incr failures
    } elseif {[format %.3f [get_clock_info -period $tck]] ne "30.000"} {
        puts "sta: FAIL: altera_reserved_tck is [get_clock_info -period $tck] ns, and cadr_probe.sdc says 30"
        incr failures
    } else {
        puts "sta: the probe's JTAG clock is altera_reserved_tck, 30.000 ns"
    }
    # AND NOTHING IS TIMED BETWEEN IT AND THE MACHINE'S CLOCK, although the
    # probe crosses between them: its read pointer's first synchronizer
    # stage is a register of the machine's clock fed from TCK's.  A crossing
    # that exists and is timed as if the two clocks were related is what the
    # asynchronous group is for, and a group that reached nothing leaves it.
    set crossing [get_registers -nowarn {g_probe.u_probe|rd_addr_s1[*]}]
    if {[get_collection_size $crossing] == 0} {
        puts "sta: FAIL: the probe has no rd_addr_s1, so there is no crossing to ask about"
        incr failures
    } elseif {[llength $machine_clocks] == 2} {
        set mclk [get_clocks [lindex $machine_clocks 0]]
        set there [get_collection_size [get_timing_paths -setup -from_clock $tck -to_clock $mclk -npaths 10]]
        set back  [get_collection_size [get_timing_paths -setup -from_clock $mclk -to_clock $tck -npaths 10]]
        if {$there + $back > 0} {
            puts "sta: FAIL: $there paths from TCK to the machine's clock and $back back are timed"
            incr failures
        } else {
            puts "sta: the probe crosses between TCK and the machine's clock, and no path between them is timed"
        }
    }
    # The split `cadr_probe.sv` makes: `stable_q` at the microcycle, and
    # every other register of the probe at its clock's own period.
    # grid: 75 ns
    assert_instance_timing $tick 8 g_probe.u_probe {stable_q}
}
# THE MEMORY BOARD, WHEN IT IS BUILT, and `cadr_ddr.sdc`'s two clauses: the
# adapter's address and data registers at the bus's 80 ns and no other
# register of the adapter, and the processor's four asynchronous bits and the
# default slaves' reset cut at their first register and nowhere else.
set ddr_exempt [get_registers -nowarn {u_memory|u_axi|m_axi_awaddr[*] u_memory|u_axi|m_axi_araddr[*]
                                       u_memory|u_axi|m_axi_wdata[*]
                                       u_debug_window|sts_dbd[*]}]
if {[get_collection_size [get_registers -nowarn {u_memory|*}]] == 0} {
    puts "sta: the memory port is not in this build"
} else {
    # **AND THIRTY-TWO AND NOT THIRTY-THREE** for the other clause: the
    # acknowledgment's register and thirty-one of the tally's thirty-two
    # bits.  Bit 31 is the tally's own marker, a constant zero in both halves,
    # and the fitter keeps no register for it; bit 15, the marker's constant
    # one, it keeps.  Measured.
    #
    # **EIGHTY AND NOT NINETY-SIX.**  The clause names three registers of
    # thirty-two bits, and the top eight bits of both addresses are the
    # region's base, `0xB0`, which is a constant: the fitter keeps no
    # register for them, so the pins are 24 + 24 + 32.
    foreach {sta_what sta_var sta_want} {{the adapter's address and data pins} ddr_contract 80
                             {the registers the processor samples on its own clock} ddr_to_hps 32
                             {the processor's asynchronous bits' first registers} ddr_crossing 5
                             {the debug cable's carrier latch} cable_word 16} {
        if {![info exists ::$sta_var]} {
            puts "sta: FAIL: cadr_ddr.sdc left no collection named $sta_var"
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
    # grid: 80 ns
    assert_instance_timing $tick 8 u_memory|u_axi {m_axi_awaddr m_axi_araddr m_axi_wdata}
    # And the debug cable's carrier: `sts_dbd` at the cable's six ticks and no
    # other register of the window, which is `cadr_ddr.sdc`'s split for it and
    # the reason that clause names the `|d` pins.
    # grid: 60 ns
    assert_instance_timing $tick 6 u_debug_window {sts_dbd}
    # And a cut that reached its registers leaves no timed path out of them.
    if {[info exists ::ddr_to_hps] && [get_collection_size $::ddr_to_hps] > 0} {
        set timed [get_collection_size [get_timing_paths -setup -from $::ddr_to_hps -npaths 100]]
        if {$timed > 0} {
            puts "sta: FAIL: $timed timed paths start at a register the processor samples on its own clock"
            incr failures
        } else {
            puts "sta: no timed path starts at the registers the processor samples on its own clock"
        }
    }
    # A cut that reached its registers leaves no timed path into them.
    if {[info exists ::ddr_crossing] && [get_collection_size $::ddr_crossing] > 0} {
        set timed [get_collection_size [get_timing_paths -setup -to [data_pins $::ddr_crossing] -npaths 100]]
        if {$timed > 0} {
            puts "sta: FAIL: $timed timed paths end at a first synchronizer register"
            incr failures
        } else {
            puts "sta: no timed path ends at the processor's bits' first registers"
        }
    }
}
set exempt $probe_stable
if {[get_collection_size $ddr_exempt] > 0} {
    if {[get_collection_size $exempt] > 0} {
        set exempt [add_to_collection $exempt $ddr_exempt]
    } else {
        set exempt $ddr_exempt
    }
}
assert_constraints_scoped $exempt
# At a 10 ns grid this count is shared: the bus's setup below is eight ticks
# too, so a relaxed set that reached nothing would still find the display's
# eight here.  The instance assertions are the sharp half.
# grid: 75 ns (shared with 80 ns)
assert_multicycle_applied $tick 8
# The display board's word, relaxed at its `d` pins only.  Its three held
# decodes are in the relaxed set, at the same eight ticks, and are left out of
# both halves.
# grid: 80 ns
assert_instance_timing $tick 8 u_machine|memory|tv {color_map pointer} {ctl fb which}
# The bus interface's register block: the Unibus map and its write buffer at
# the register strobe.
# grid: 150 ns
assert_instance_timing $tick 15 u_machine|memory|busint_regs {wr_buf ub_map}
# The transaction audit has no register on a board with no console to read
# it, and `cadr_machine.xdc`'s clause for it is then empty by construction, as
# the Zynq flow says of its own memory-off board.
if {[get_collection_size [get_registers -nowarn {u_machine|audit|*}]] == 0} {
    puts "sta: the audit has no registers on a board with no console to read it, so its split is not asked about"
}

# ------------------------------------------------------------ the corners
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
