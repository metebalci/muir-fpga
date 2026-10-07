# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# IS EVERY BLOCK RAM'S ADDRESS STILL WHENEVER THE RAM IS ENABLED?  Asked of
# the routed design by `bitstream.tcl` on both Zynq boards, after the
# bitstream is written; a build that fails it loses its bitstream.
#
# **THE RULE, AND WHERE IT COMES FROM.**  UG473 (7 Series FPGAs Memory
# Resources), "Block RAM usage rules": "Violating the address setup time
# (even if write enable is Low) can corrupt the data contents of the block
# RAM", and note 1 of "Block RAM Timing Parameters": "While EN is active,
# ADDR inputs must be stable during the entire setup/hold time window, even
# if WE is inactive ... If ADDR timing could violate the specified
# requirements, EN must be inactive (disabled)."  So a block RAM that is
# enabled on a tick is a register on that tick, whatever reads its output,
# and a multicycle exception into its address pins is a claim that it is
# NOT enabled on the ticks between.
#
# **THE FAULT IT EXISTS FOR.**  QUUX's control store reads at the edge, at
# NPC, whose cone the constraint files give the whole microcycle.  Written
# `if (iwe_q ...) write; else if (cs_read) read;`, Vivado tied the port's
# enable high and held the word in fabric registers, so the RAM was enabled
# on every tick while its address rippled for up to 27 ns after each edge.
# The build met timing.  On the Arty the store lost words it had been
# loaded with --- 180 of them within 400 million microcycles, a few bits at
# a time in whichever block RAMs --- until the band ran one and stopped at
# ILLOP; one such run had first written pages over the pack's GPT.  At
# 25 MHz, where every path fits in a tick, the same netlist reached the
# Listener.  The cache's RAMs had the same shape: read on every idle tick at
# the map's rippling output.  `rtl/machine/cadr_microcycle.sv` and
# `rtl/machine/quux_mem_port.sv` enable both only on the ticks they use.
#
# **WHAT IS ASKED.**  Every port of every block RAM in the design is sorted
# by its enable pin: a constant zero is an unused port; an enable whose
# fan-in reaches both registers that make the boundary (the phase
# generator's `tpclk` and the processor's `tpclk_q`) is one the machine
# raises at its edges, and its address is the constraint files' business;
# anything else --- a constant one, or an enable made of other registers ---
# may be up on any tick, so every path into that port's address, write
# enable and enable pins must fit in ONE tick with every timing exception
# dropped.  A port that does not fails the build, and the log names the
# port, its path and the slack.  The boundary sort is structural and
# generous: an enable that is the boundary OR something else passes as
# gated, which is how the control store's write a tick after the edge is
# let through (its address then is `iwa_q`, a register of the tick).
#
# **IT DROPS THE DESIGN'S CONSTRAINTS TO ASK**, which is why it runs after
# the bitstream and the reports: `reset_timing`, the board clock alone, the
# machine's clock derived from it at the tick, and every other clock kept
# apart.  Nothing after it in the flow reads a timing constraint.
#
# **MEASURED on the Arty's QUUX build (DDR=1 HDMI=1).**  The routed netlist
# of the build that failed on the board fails 41 ports: the control store's
# 24 machine ports, enabled always, 26-27 ns into their address pins; the
# cache's 10 read ports, enabled by the port's state, 19-20 ns; and 7 of the
# readout's second ports, reached from `ro_a0` in up to 13.4 ns, which the
# one-tick clause in `rtl/plumbing/xilinx7/cadr_machine.xdc` now covers.  The
# fixed build passes, 105 ports asked.  A netlist mutation of the fixed tree
# through this flow, the cache's lookup at every idle tick again, fails the
# 10 cache ports and loses its bitstream.  The CADR reads its control store
# on every tick, and the Cora's CADR build failed on that store's write
# enable, 0.05 ns over a tick, until `cadr_machine.xdc` gave its pins the
# tick; with that clause the Arty's and the Cora's CADR builds pass.  The
# runner of `mutations/list.txt` simulates, and in simulation the two forms
# of each enable are the same machine, so the netlist mutation is not a
# record; `docs/mutations.md` has it.

proc rams_enable_classify {pin} {
    set net [get_nets -quiet -of $pin]
    if {![llength $net]} { return unused }
    set drv [get_pins -quiet -leaf -of [get_nets -quiet -segments $net] -filter {DIRECTION == OUT}]
    if {[llength $drv] == 1} {
        set ref [get_property REF_NAME [get_cells -of $drv]]
        if {$ref eq "GND"} { return unused }
        if {$ref eq "VCC"} { return always }
    }
    set starts [get_cells -quiet -of [all_fanin -quiet -flat -startpoints_only $pin]]
    set tp 0; set tq 0
    foreach s $starts {
        set n [get_property NAME $s]
        if {[string match {*u_phase_gen/tpclk_reg} $n]} { set tp 1 }
        if {[string match {*processor/tpclk_q_reg} $n]} { set tq 1 }
    }
    if {$tp && $tq} { return boundary }
    return anytick
}

# `tick` is the machine's period in ns, as `tick.tcl` computes it.  Returns
# only when every port passes; otherwise deletes `bit` and exits 1.
# Block RAM is `BMEM.*` on the 7 series and `BLOCKRAM.BRAM.*` on
# UltraScale+ (`RAMB36E2`, `RAMB18E2`), with the same enable, address and
# write-enable pins; UltraRAM is `BLOCKRAM.URAM.*` and is not asked for.
proc assert_rams_enabled_only_while_addressed {tick bit} {
    set rams [get_cells -quiet -hier -filter {PRIMITIVE_TYPE =~ BMEM.*.* || PRIMITIVE_TYPE =~ BLOCKRAM.BRAM.*}]
    if {![llength $rams]} {
        puts "RAMEN: FAILED --- no block RAM in the routed design; the query is wrong"
        file delete -force $bit
        exit 1
    }
    # Classified before the constraints go: the sort is the netlist's.
    set ports {}
    set counts [dict create unused 0 always 0 boundary 0 anytick 0]
    foreach b $rams {
        # Revision 14's TLB is asked by name below (`tlb_check.tcl`), block
        # RAM or UltraRAM alike, which this sort does not reach.
        if {[string match *g_rev14_mmu.mmu/tlb/* $b]} continue
        foreach {port en addr we} {A ENARDEN ADDRARDADDR WEA B ENBWREN ADDRBWRADDR WEBWE} {
            set enp [get_pins -quiet $b/$en]
            if {![llength $enp]} continue
            set cls [rams_enable_classify $enp]
            dict incr counts $cls
            if {$cls eq "always" || $cls eq "anytick"} {
                set pins [get_pins -quiet [list $b/$en "$b/$addr\[*\]" "$b/$we\[*\]"]]
                lappend ports [list $b $port $cls $pins]
            }
        }
    }
    puts "RAMEN: [llength $rams] block RAMs: [dict get $counts boundary] port(s) enabled at\
          the machine's edges, [dict get $counts always] enabled always,\
          [dict get $counts anytick] enabled by other registers,\
          [dict get $counts unused] unused"

    # The routed design with its own constraints, before they go, when a run
    # asks for it (RAMEN_DCP=<file>): what a failure here is read against.
    if {[info exists ::env(RAMEN_DCP)]} {
        write_checkpoint -force $::env(RAMEN_DCP)
        puts "RAMEN: the routed design, constraints and all, is $::env(RAMEN_DCP)"
    }

    # Every path at one tick, no exceptions.  The board's clock is put back
    # as it was --- the clock on the MMCM's input, its period and its port,
    # read before the constraints go --- so that the same check serves a
    # board whose input is 125 MHz on `sysclk` and one whose input is 25 MHz
    # on `clk25`.
    set inclk [get_clocks -quiet -of [get_pins -quiet u_mmcm/CLKIN1]]
    if {[llength $inclk] != 1} {
        puts "RAMEN: FAILED --- no single clock reaches u_mmcm/CLKIN1"
        file delete -force $bit
        exit 1
    }
    set inper  [get_property PERIOD $inclk]
    set inport [get_ports -quiet [get_property SOURCE_PINS $inclk]]
    if {[llength $inport] != 1} {
        puts "RAMEN: FAILED --- the MMCM's input clock does not come from one port"
        file delete -force $bit
        exit 1
    }
    puts "RAMEN: the board's clock is [get_property NAME $inport], $inper ns"
    reset_timing
    create_clock -name ramen_sys -period $inper $inport
    update_timing -full
    set mclk [get_clocks -quiet -of [get_pins -quiet u_mmcm/CLKOUT0]]
    if {[llength $mclk] != 1} {
        puts "RAMEN: FAILED --- the machine's clock was not derived from u_mmcm/CLKOUT0"
        file delete -force $bit
        exit 1
    }
    set period [get_property PERIOD $mclk]
    if {abs($period - $tick) > 0.001} {
        puts "RAMEN: FAILED --- the machine's clock came out $period ns where the tick is $tick"
        file delete -force $bit
        exit 1
    }
    set others [get_clocks -quiet -filter "NAME != [get_property NAME $mclk]"]
    if {[llength $others]} {
        set_clock_groups -asynchronous -group $mclk -group $others
    }

    # Revision 14's TLB, block RAM or UltraRAM, by name, on a build that has
    # one: the CADR and revision 13 have none, and `tlb_check.tcl`, which the
    # flows source for every build, would otherwise find no pin and refuse.
    if {[llength [info procs assert_tlb_enabled_at_the_edge]] && [llength [tlb_cells]]} {
        assert_tlb_enabled_at_the_edge $bit
    }

    set bad 0
    foreach p $ports {
        lassign $p b port cls pins
        set ps [get_timing_paths -quiet -setup -max_paths 1 -nworst 1 -to $pins]
        if {![llength $ps]} continue
        set path [lindex $ps 0]
        set slack [get_property SLACK $path]
        if {$slack eq "" || $slack eq "inf"} continue
        if {$slack < 0} {
            incr bad
            puts [format "RAMEN: FAILED %s port %s, enabled %s: %.3f ns from %s to %s, slack %.3f at one tick" \
                      $b $port [expr {$cls eq "always" ? "always" : "by other registers"}] \
                      [get_property DATAPATH_DELAY $path] [get_property STARTPOINT_PIN $path] \
                      [get_property ENDPOINT_PIN $path] $slack]
        }
    }
    if {$bad} {
        puts "RAMEN: FAILED --- $bad block RAM port(s) can be enabled on a tick whose address"
        puts "RAMEN: is still moving (UG473: the contents can be corrupted). The bitstream"
        puts "RAMEN: $bit is deleted. rams_enable_check.tcl says what to do."
        file delete -force $bit
        exit 1
    }
    puts "RAMEN: ok --- [llength $ports] block RAM port(s) that can be enabled on any tick,\
          every path into their address, write enable and enable within one tick"
}
