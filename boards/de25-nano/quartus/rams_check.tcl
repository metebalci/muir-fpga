# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# DOES EVERY BLOCK RAM WRITE WHERE THE RTL SAYS?  The DE25-Nano's half of
# `boards/arty-z7-20/vivado/rams_check.tcl`, which says what the fault was
# and why it is asked of the netlist rather than of a simulation.  Run by
# `boards/de25-nano/quartus/build.sh` in the build directory as
#
#     MACHINE=<cadr|quux> quartus_sta -t rams_check.tcl <snapshot>
#
# twice: on the `synthesized` snapshot straight after synthesis, so that a
# build whose RAMs write in the wrong place stops before the fitter, and on
# the `final` snapshot after it, because that is the netlist the bitstream
# is made from.  It exits non-zero on any failure, and every line it prints
# for the build log starts with `RAMS:`.
#
# **QUARTUS KEEPS THE MUX THAT VIVADO 2026.1 DROPPED**, measured, on the
# READ_FIRST PDL and on the reduced ten-line shape alike.  So this is not a
# check for a fault seen here.  It is here because the machine's RTL is one
# source for two tools, and a question asked of one netlist and not the
# other would pass on a Quartus fault of the same kind without a word.
#
# **WHAT IS ASKED** is the Vivado half's question in Quartus's names.  Each
# RAM of the machine whose read and write share one address chosen by the
# write enable has a rule: the memory it becomes, a register only its write
# enable reads, and a register only its WRITE address reads.  Every block of
# that memory, each port whose write-enable pin has the first register among
# its keepers, and that port's address pins must have the second among
# theirs.  A memory with no block, or a block with no such port, fails too:
# a check that finds nothing is not a pass.
#
# **QUARTUS NAMES THE CADR'S RAMS AND QUUX'S ALIKE.**  The PDL buffer and
# the control store are `processor|pdl_rtl_N` and `processor|imem_rtl_N` on
# both machines, where Vivado keeps the generate block's name, so the
# machine is taken from `MACHINE` and not from the netlist.  Only the
# block-disk's store is QUUX's by name, and a CADR build must not have it.

if {[llength $argv] != 1 || [lindex $argv 0] ni {synthesized final}} {
    puts "RAMS: FAILED --- usage: quartus_sta -t rams_check.tcl synthesized|final"
    exit 1
}
set snapshot [lindex $argv 0]
set machine [expr {[info exists ::env(MACHINE)] ? $::env(MACHINE) : "cadr"}]
if {$machine ni {cadr quux}} {
    puts "RAMS: FAILED --- MACHINE is '$machine', not cadr or quux"
    exit 1
}

project_open cadr_de25
create_timing_netlist -snapshot $snapshot

# Every block of every memory, by the memory's name: the part of a block's
# name before `|auto_generated|`.
set rams_blocks [dict create]
foreach_in_collection c [get_cells -hierarchical -nowarn *ram_block*] {
    set n [get_cell_info -name $c]
    if {[regexp {^(.*_rtl_[0-9]+)\|auto_generated\|} $n -> mem]} {
        dict lappend rams_blocks $mem $n
    }
}

# The keepers a block's pins of one kind reach back to, by name.
proc rams_keepers {block pins} {
    set p [get_pins -nowarn "$block|$pins"]
    if {[get_collection_size $p] == 0} { return {} }
    set names {}
    foreach_in_collection k [get_fanins -synch $p] { lappend names [get_node_info -name $k] }
    return $names
}

proc rams_any_matches {names pattern} {
    foreach n $names { if {[string match $pattern $n]} { return 1 } }
    return 0
}

# One rule; exits on a failure.
proc rams_rule {what mems we wa} {
    global rams_blocks snapshot
    set blocks {}
    foreach mem [lsort [dict keys $rams_blocks]] {
        if {[string match $mems $mem]} { lappend blocks {*}[dict get $rams_blocks $mem] }
    }
    if {[llength $blocks] == 0} {
        puts "RAMS: FAILED --- $what: no block RAM matches $mems in the $snapshot"
        puts "RAMS: netlist, so nothing was asked. A renamed memory is the likeliest reason."
        exit 1
    }
    set bad {}
    set ports 0
    foreach b $blocks {
        set mine 0
        foreach port {a b} {
            if {![rams_any_matches [rams_keepers $b "port${port}we*"] $we]} { continue }
            incr mine
            if {![rams_any_matches [rams_keepers $b "port${port}addr*"] $wa]} {
                lappend bad "$b|port${port}addr"
            }
        }
        if {$mine == 0} { lappend bad "$b (no port's write enable reaches $we)" }
        incr ports $mine
    }
    if {[llength $bad]} {
        puts "RAMS: FAILED --- $what: [llength $bad] of [llength $blocks] block RAMs write"
        puts "RAMS: where the RTL does not say: the write address ([string map {\\ {}} $wa]) reaches no"
        puts "RAMS: address pin of the port its write enable ($we) drives. First:"
        puts "RAMS:     [lindex $bad 0]"
        exit 1
    }
    puts "RAMS: ok      $what: [llength $blocks] block RAMs, $ports writing ports,"
    puts "RAMS:         the write address at every one ($snapshot netlist)"
}

# {what} {memories} {write-enable register} {write-address register}
set quux_rules {
    {QUUX's PDL buffer}        {*|processor|pdl_rtl_*}           {*|processor|pdlwrited*}          {*|processor|pwidx*}
    {QUUX's control store}     {*|processor|imem_rtl_*}          {*|processor|iwe_q*}              {*|processor|iwa_q\[*}
    {block-disk's block store} {*g_quux_disk.disk|blk_ram_rtl_*} {*g_quux_disk.disk|chb_we*}       {*g_quux_disk.disk|chb_a\[*}
}
# The CADR's PDL is known by the write pulse's edge register, as on the Zynq
# boards; its control store by the same, with the PC as its address.
set cadr_rules {
    {the CADR's PDL buffer}    {*|processor|pdl_rtl_*}           {*|processor|n_tpwp_q*}           {*|processor|pwidx*}
    {the CADR's control store} {*|processor|imem_rtl_*}          {*|processor|n_tpwpiram_q*}       {*|processor|pc\[*}
}
set quux_only {*g_quux_disk.disk|blk_ram_rtl_*}

if {$machine eq "quux"} {
    set n 0
    foreach {what mems we wa} $quux_rules { rams_rule $what $mems $we $wa; incr n }
    puts "RAMS: ok      QUUX: all $n RAMs whose read and write share an address"
    puts "RAMS:         chosen by the write enable were found, and write where the RTL says"
} else {
    foreach mem [dict keys $rams_blocks] {
        if {[string match $quux_only $mem]} {
            puts "RAMS: FAILED --- $mem, which only QUUX has, is in a CADR build:"
            puts "RAMS: the machine built is not the one named."
            exit 1
        }
    }
    puts "RAMS: the CADR: QUUX's block store is not here; no RAM of the CADR shares an"
    puts "RAMS: address chosen by the write enable, so its own write addresses are asked:"
    foreach {what mems we wa} $cadr_rules { rams_rule $what $mems $we $wa }
}
exit 0
