# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# QUUX REVISION 14'S TLB, ASKED OF THE NETLIST (contract G3 revision 14,
# §5.4, §11.2 and A14.15).  Sourced by the Arty Z7-20's and the Kria KR260's
# flows.
#
#   - `assert_tlb_primitive`: after synthesis, the TLB is the memory the
#     board's setting asked for (`quux14_tlb_ram.xdc`): block RAM on the
#     Arty, one UltraRAM on the Kria, and no LUT RAM or registers in its
#     place.  Vivado builds block RAM where UltraRAM was asked for and the
#     write mode is one UltraRAM refuses, without failing (A14.15), so the
#     cells are counted rather than the setting trusted.  On a revision 13
#     build there must be none.
#   - `tlb_ports`: which primitive port is the RTL's port A, `VMA`'s, and
#     which port B, `MD`'s.  **A TOOL MAY SWAP A TRUE DUAL-PORT RAM'S PORTS**:
#     on every Arty fit M2 made, the RTL's port A was the primitive's B.  So
#     a port is told by what reaches its address: port A's carries the
#     walker's fill address (`w_va`), which port B's never does, and port
#     B's carries `MD` and not `w_va`.
#   - `report_tlb`: after routing, the TLB's paths by port, each with its
#     requirement, slack and logic levels, and the requirements every path
#     out of each port and into each address was given, into `tlb_paths.txt`
#     beside the bitstream.  This is the figure `docs/fits.md` quotes.
#   - `assert_tlb_addressed_at_the_tick`: the block-RAM rule (UG473;
#     `rams_enable_check.tcl`) on the TLB alone, asked with every timing
#     exception dropped: every path into either port's address within one
#     tick.  The TLB is enabled on the generator cycle's first tick and at
#     its writes, which `rams_enable_check.tcl`'s structural sort cannot
#     tell from an edge, so it is asked here by name, and on UltraRAM too.

# The TLB's primitive cells.
proc tlb_cells {} {
    return [get_cells -quiet -hier -filter {NAME =~ *g_rev14_mmu.mmu/tlb/* && IS_PRIMITIVE &&
                                            REF_NAME != GND && REF_NAME != VCC}]
}

# The board's setting, read before synthesis and for synthesis alone: the
# RTL memory it names, `tlb_mem_reg`, is gone from the netlist synthesis
# writes, where the flow's later constraints would ask for it again.
proc read_tlb_ram_style {xdc} {
    read_xdc $xdc
    set_property USED_IN_IMPLEMENTATION false [get_files $xdc]
}

proc assert_tlb_primitive {revision style} {
    set cells [tlb_cells]
    if {$revision ne "14"} {
        if {[llength $cells]} {
            puts "TLB: FAILED --- [llength $cells] cells of a TLB on a revision $revision build"
            exit 1
        }
        return
    }
    # Synthesis names the logic around the memory by the scope it came from,
    # so lookup tables and carries under the TLB's name are the tag compare's
    # and the entry's select, and not a memory.  What would be a memory built
    # some other way is LUT RAM, or registers by the thousand: a word of each
    # port's output is 41 of them, so more than 128 is a memory.
    set block {}; set ultra {}; set lutram {}; set ffs {}
    foreach c $cells {
        set ref [get_property REF_NAME $c]
        set grp [get_property PRIMITIVE_GROUP $c]
        if {[string match RAMB* $ref]} { lappend block $c } \
        elseif {[string match URAM* $ref]} { lappend ultra $c } \
        elseif {$grp eq "DMEM" || [string match RAM* $ref]} { lappend lutram $c } \
        elseif {$grp eq "FLOP_LATCH" || $grp eq "REGISTER"} { lappend ffs $c }
    }
    set refs [lsort -unique [get_property REF_NAME [concat $block $ultra $lutram]]]
    puts "TLB: [llength $block] block RAM, [llength $ultra] UltraRAM, [llength $lutram] LUT RAM,\
          [llength $ffs] registers under the TLB's name"
    foreach c [concat $block $ultra] {
        puts "TLB:   $c [get_property REF_NAME $c]\
              WRITE_MODE_A=[get_property -quiet WRITE_MODE_A $c] WRITE_MODE_B=[get_property -quiet WRITE_MODE_B $c]\
              READ_WIDTH_A=[get_property -quiet READ_WIDTH_A $c]"
    }
    set bad ""
    if {[llength $lutram] || [llength $ffs] > 128} {
        set bad "[llength $lutram] LUT RAM and [llength $ffs] registers hold part of it"
    } elseif {$style eq "block" && ([llength $block] == 0 || [llength $ultra])} {
        set bad "it is [llength $block] block RAM and [llength $ultra] UltraRAM, wanting block RAM alone"
    } elseif {$style eq "ultra" && ([llength $ultra] != 1 || [llength $block])} {
        set bad "it is [llength $ultra] UltraRAM and [llength $block] block RAM, wanting one UltraRAM"
    }
    if {$bad ne ""} {
        puts "TLB: FAILED --- the TLB is not the memory quux14_tlb_ram.xdc asked for ($style): $bad"
        exit 1
    }
    puts "TLB: ok --- the TLB is [llength [concat $block $ultra]] $refs, as $style asks"
}

# The RAM cells of the TLB, and for each of its two ports the RTL's name.
# Returns a list of {cell primitive-port rtl-port address-pins output-pins}.
proc tlb_ports {} {
    set out {}
    foreach c [tlb_cells] {
        set ref [get_property REF_NAME $c]
        if {![string match RAMB* $ref] && ![string match URAM* $ref]} { continue }
        foreach {pp apat dpat} {A {ADDRARDADDR* ADDR_A*} {DOADO* DOUTADOUT* DOUT_A*}
                                B {ADDRBWRADDR* ADDR_B*} {DOBDO* DOUTBDOUT* DOUT_B*}} {
            set f {}; foreach x $apat { lappend f "REF_PIN_NAME =~ $x" }
            set ap [get_pins -quiet -of $c -filter [join $f " || "]]
            set f {}; foreach x $dpat { lappend f "REF_PIN_NAME =~ $x" }
            set dp [get_pins -quiet -of $c -filter [join $f " || "]]
            set fin [get_property NAME [get_cells -quiet -of [all_fanin -quiet -flat -startpoints_only $ap]]]
            set fill [expr {[lsearch -glob $fin *g_rev14_mmu.mmu/w_va_reg*] >= 0}]
            set md   [expr {[lsearch -glob $fin *processor/md_reg*] >= 0}]
            if {$fill} { set rtl A } elseif {$md} { set rtl B } else { set rtl ? }
            lappend out [list $c $pp $rtl $ap $dp]
        }
    }
    return $out
}

proc tlb_line {fh label ps} {
    if {[llength $ps] == 0} { puts $fh [format "%-34s | no path" $label]; return }
    set p [lindex $ps 0]
    puts $fh [format "%-34s | slack %7.3f | req %7.3f | data %6.3f (logic %5.3f, route %6.3f) | levels %2s | %s -> %s" \
        $label [get_property SLACK $p] [get_property REQUIREMENT $p] [get_property DATAPATH_DELAY $p] \
        [get_property DATAPATH_LOGIC_DELAY $p] [get_property DATAPATH_NET_DELAY $p] \
        [get_property LOGIC_LEVELS $p] [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]]
}

proc tlb_hist {fh label ps} {
    set h {}
    foreach p $ps { dict incr h [format %.3f [get_property REQUIREMENT $p]] }
    puts $fh [format "%-34s | requirements: %s" $label $h]
}

# The worst path through `through` (pins), optionally to `to` (pins).
proc tlb_worst {through {to {}}} {
    if {[llength $through] == 0} { return {} }
    if {[llength $to]} {
        return [get_timing_paths -quiet -setup -max_paths 1 -through $through -to $to]
    }
    return [get_timing_paths -quiet -setup -max_paths 1 -through $through]
}

proc tlb_dpins {pat} {
    return [get_pins -quiet -of [get_cells -quiet -hier -filter "NAME =~ $pat && IS_SEQUENTIAL"] \
                -filter {REF_PIN_NAME == D}]
}

proc report_tlb {outdir} {
    set fh [open $outdir/tlb_paths.txt w]
    puts $fh "# QUUX revision 14's TLB, routed: its ports told apart by the address that reaches them"
    set ports [tlb_ports]
    set out(A) {}; set out(B) {}; set adr(A) {}; set adr(B) {}
    foreach p $ports {
        lassign $p c pp rtl ap dp
        puts $fh "port: $c [get_property REF_NAME $c] primitive port $pp is the RTL's port $rtl"
        if {$rtl eq "?"} { continue }
        set out($rtl) [concat $out($rtl) $dp]
        set adr($rtl) [concat $adr($rtl) $ap]
    }
    set every [concat [tlb_dpins *processor/memgo_q_reg*] [tlb_dpins *memory/is_memory_reg*] \
                      [tlb_dpins *memory/device_reg*] [tlb_dpins *memory/nxm_reg*]]
    set mmu [tlb_dpins *processor/g_rev14_mmu.mmu/*]
    set pc  [tlb_dpins *processor/pc_reg*]
    tlb_line $fh "worst setup"                     [get_timing_paths -quiet -setup -max_paths 1]
    tlb_line $fh "worst hold"                      [get_timing_paths -quiet -hold -max_paths 1]
    foreach r {A B} {
        tlb_line $fh "port $r out, worst"              [tlb_worst $out($r)]
        tlb_line $fh "port $r out, every-tick regs"    [tlb_worst $out($r) $every]
        tlb_line $fh "port $r out, the walker's regs"  [tlb_worst $out($r) $mmu]
        tlb_line $fh "port $r out, the next address"   [tlb_worst $out($r) $pc]
        tlb_line $fh "port $r address in, worst"       [get_timing_paths -quiet -setup -max_paths 1 -to $adr($r)]
    }
    foreach r {A B} {
        if {[llength $out($r)]} {
            tlb_hist $fh "out of port $r" [get_timing_paths -quiet -setup -max_paths 20000 -nworst 1 -through $out($r)]
        }
        if {[llength $adr($r)]} {
            tlb_hist $fh "into port $r's address" [get_timing_paths -quiet -setup -max_paths 20000 -nworst 1 -to $adr($r)]
        }
    }
    close $fh
    puts "TLB: the TLB's paths, port by port, are in $outdir/tlb_paths.txt"
}

# Asked after `reset_timing`, with the machine's clock re-derived at the tick
# and every exception gone (`rams_enable_check.tcl`).  Deletes `bit` and
# exits on a path into either address that misses one tick.
proc assert_tlb_addressed_at_the_tick {bit} {
    set ports [tlb_ports]
    if {[llength $ports] == 0} { return }
    set n 0; set bad 0; set worst ""
    foreach p $ports {
        lassign $p c pp rtl ap dp
        foreach path [get_timing_paths -quiet -setup -max_paths 1000 -nworst 1 -to $ap] {
            incr n
            set slack [get_property SLACK $path]
            if {$worst eq "" || $slack < [lindex $worst 0]} {
                set worst [list $slack [get_property STARTPOINT_PIN $path] [get_property ENDPOINT_PIN $path] \
                               [get_property DATAPATH_DELAY $path]]
            }
            if {$slack < 0} { incr bad }
        }
    }
    if {$n == 0} {
        puts "RAMEN: FAILED --- no path reaches the TLB's addresses; the query is wrong"
        file delete -force $bit
        exit 1
    }
    lassign $worst slack from to delay
    if {$bad} {
        puts "RAMEN: FAILED --- the TLB: $bad of $n paths into its addresses miss one tick;"
        puts [format "RAMEN: worst %.3f ns from %s to %s, slack %.3f. The bitstream %s is deleted." \
                  $delay $from $to $slack $bit]
        file delete -force $bit
        exit 1
    }
    puts [format "RAMEN: ok --- the TLB: %d paths into both ports' addresses within one tick,\
                  every exception dropped; worst %.3f ns, %s to %s, slack %.3f" $n $delay $from $to $slack]
}
