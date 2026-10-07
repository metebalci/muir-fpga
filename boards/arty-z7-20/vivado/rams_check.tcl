# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# DOES EVERY BLOCK RAM WRITE WHERE THE RTL SAYS?  Asked of the synthesized
# netlist, by `bitstream.tcl` on both Zynq boards, straight after
# `synth_design`.
#
# **THE FAULT IT EXISTS FOR.**  QUUX's PDL buffer was written READ_FIRST
# through one address chosen by a combinational write enable,
#
#     assign pdla = pdl_we ? pdla_write : pdla_read;
#     if (pdl_we) pdl[pdla] <= l;
#     pdl_rd <= pdl[pdla];
#
# and Vivado 2026.1's synthesis dropped the mux: the sixteen block RAMs had
# only the read address at their pins, every push landed at the read
# address, and the build met timing, wrote a bitstream and reported nothing.
# On the board the boot PROM halted at ERROR-PDL-BUFFER.  No simulation can
# see it, because the RTL is right.  `rtl/machine/cadr_microcycle.sv`'s
# header says what the PDL was changed to and why that is safe.
#
# **WHAT IS ASKED.**  Each RAM of the machine whose read and write share one
# address chosen by the write enable has a rule: the cells it becomes, a
# register only its write enable reads, and a register only its WRITE
# address reads.  Every port whose write enable is live and has the first
# register in its fan-in is the machine's writing port, and that port's
# address pins must have the second in theirs.  A RAM with no such port, or
# a rule matching no RAM, fails as well: a check that finds nothing is not a
# pass.  The block-disk's store has a second writer, the pack side, on the
# other port, and the write-enable register is what keeps that port out of
# the question rather than letting either port's address answer for both.
#
# **ON THE CADR THERE IS NO SUCH RAM** --- its PDL, control store and block
# store each write through an address of their own --- so the three QUUX
# rules must match NO cell, and the CADR's PDL and control store are asked
# the same question of their own write addresses, which is what shows the
# query finds RAMs at all on that build.
#
# **MEASURED through this flow, on the Arty's QUUX build (`DDR=1 HDMI=1`):**
# the READ_FIRST PDL stops the build on the PDL buffer, 16 of 16 RAMs; the
# WRITE_FIRST one passes; and two netlist mutations of the fixed tree stop
# it on the RAM they break:
#
#     pdla = pdla_read               the PDL buffer, 16 of 16
#     chb_port = ch_word             the block store, 8 of 8, with the PDL
#                                    buffer and the control store passing
#
# The rules are asked in turn and the first failure ends the build, so the
# first two say nothing about the rules after the PDL's.  The runner of
# `mutations/list.txt` simulates and never synthesizes, so a netlist
# mutation cannot be a record there; the first is a record as well,
# `quux-the-pdl-write-lands-at-the-read-address`, because in RTL it is a
# behavior the traces catch.  `docs/mutations.md` has both.
#
# **AND A CANARY**, `rams_canary`: the same shape in one memory, synthesized
# out of context before the board.  It prints a WARNING when the tool still
# drops the mux, and never fails the build, because the machine's RTL no
# longer has the shape.  It is there so that a new Vivado that fixes the
# fault, or one that starts dropping a mux of a milder shape, is seen in the
# log without anybody going to look.  About thirty seconds.

# The canary.  Run before the board's sources are read, and removed from the
# in-memory project after, so that nothing of it reaches the board.
# Where the canary is, taken while this file is being sourced: inside a proc
# `info script` names the caller's script instead.
set rams_canary_src [file join [file dirname [file normalize [info script]]] rams_canary.sv]
proc rams_canary {part} {
    global rams_canary_src
    read_verilog -sv $rams_canary_src
    synth_design -top rams_canary -part $part -mode out_of_context
    set rams [get_cells -quiet -hier -filter {REF_NAME =~ RAMB*}]
    set wa 0; set ra 0
    foreach r $rams {
        foreach s [all_fanin -quiet -flat -startpoints_only \
                       [get_pins -of $r -filter {REF_PIN_NAME =~ ADDRARDADDR* || REF_PIN_NAME =~ ADDRBWRADDR*}]] {
            set n [get_property NAME $s]
            if {[string match {wa\[*} $n]} { incr wa }
            if {[string match {ra\[*} $n]} { incr ra }
        }
    }
    close_design
    remove_files [get_files -quiet *rams_canary.sv]
    if {[llength $rams] == 0 || $ra == 0} {
        puts "RAMS: WARNING --- the canary built [llength $rams] block RAMs with the read"
        puts "RAMS: address at none of them, so it tests nothing; see rams_canary.sv."
    } elseif {$wa == 0} {
        puts "RAMS: WARNING --- tool fault present: the canary's write address reaches"
        puts "RAMS: none of its [llength $rams] block RAMs. This Vivado drops an address mux"
        puts "RAMS: selected by a combinational write enable (READ_FIRST); the machine's"
        puts "RAMS: RAMs are asked below."
    } else {
        puts "RAMS: canary ok --- this Vivado keeps the canary's address mux"
        puts "RAMS: ([llength $rams] block RAMs): the tool fault is not present."
    }
}

# The registers a port's pins reach back to, as cell names.
proc rams_fanin_cells {pins} {
    if {[llength $pins] == 0} { return {} }
    return [get_cells -quiet -of [all_fanin -quiet -flat -startpoints_only $pins]]
}

# One rule: every RAMB cell matching `cells`, each port of it whose write
# enable is live and reaches `we`, and that port's address reaching `wa`.
# Returns the number of RAMs found; exits on a failure.
proc rams_rule {what cells we wa} {
    set rams [lsort [get_cells -quiet -hier -filter "REF_NAME =~ RAMB* && NAME =~ $cells"]]
    if {[llength $rams] == 0} {
        puts "RAMS: FAILED --- $what: no block RAM matches $cells, so nothing"
        puts "RAMS: was asked. A renamed cell is the likeliest reason."
        exit 1
    }
    set bad {}
    set ports 0
    foreach r $rams {
        set mine 0
        foreach {wpin apin} {WEA ADDRARDADDR WEBWE ADDRBWRADDR} {
            set wes [get_pins -quiet -of $r -filter "REF_PIN_NAME =~ ${wpin}*"]
            set live 0
            foreach w $wes {
                set n [get_nets -quiet -of $w]
                if {$n ne "" && ![string match *const* $n] && ![string match *GND* $n]} { set live 1 }
            }
            if {!$live} { continue }
            if {[llength [filter -quiet [rams_fanin_cells $wes] "NAME =~ $we"]] == 0} { continue }
            incr mine
            set addr [get_pins -quiet -of $r -filter "REF_PIN_NAME =~ ${apin}*"]
            if {[llength [filter -quiet [rams_fanin_cells $addr] "NAME =~ $wa"]] == 0} {
                lappend bad "$r/$apin"
            }
        }
        if {$mine == 0} { lappend bad "$r (no port's write enable reaches $we)" }
        incr ports $mine
    }
    if {[llength $bad]} {
        puts "RAMS: FAILED --- $what: [llength $bad] of [llength $rams] block RAMs write"
        puts "RAMS: where the RTL does not say: the write address ($wa) reaches no"
        puts "RAMS: address pin of the port its write enable ($we) drives. First:"
        puts "RAMS:     [lindex $bad 0]"
        exit 1
    }
    puts "RAMS: ok      $what: [llength $rams] block RAMs, $ports writing ports,"
    puts "RAMS:         the write address $wa at every one"
    return [llength $rams]
}

# The assertion.  `machine` is `cadr` or `quux`, and `revision` QUUX's.
#
# **REVISION 14'S TLB HAS THE SHAPE TOO, ON ITS FILL**: port A's address is
# the walker's fill address while a fill writes and `VMA`'s index while the
# port reads, chosen by the fill's own enable (`quux_mmu.sv`).  So in block
# RAM its writing port must have the fill's address, `w_va`, among its
# address pins' registers, found by the register only the fill's enable
# reads, `w_load`.  UltraRAM (the Kria KR260) has other pins and is not
# asked; its fills are what a walk's next lookup reads.
proc assert_rams_write_where_the_rtl_says {machine {revision 13}} {
    # {what} {cells} {write-enable register} {write-address register}
    # Block-disk's write port registers are its walk's, which each revision
    # has in a generate block of its own, `g_walk12` or `g_walk13`: the
    # patterns take either.
    set quux_rules {
        {QUUX's PDL buffer}        {*processor/g_quux_pdl.pdl_reg*}    {*processor/pdlwrited_reg*}     {*processor/pwidx_reg*}
        {QUUX's control store}     {*processor/imem_reg*}              {*processor/iwe_q_reg*}         {*processor/iwa_q_reg*}
        {block-disk's block store} {*g_quux_disk.disk/blk_ram_reg*}    {*g_quux_disk.disk/*chb_we_reg*} {*g_quux_disk.disk/*chb_a_reg*}
    }
    # The CADR's two RAMs with a register only the write address reads.  Its
    # disk controller's block store has none: one address serves both, made
    # of the channel's state, with no select.  The PDL's write enable is
    # known by the write pulse's edge register: synthesis of the CADR leaves
    # `pdlwrited` out of that cone, measured.
    set cadr_rules {
        {the CADR's PDL buffer}    {*processor/g_cadr_pdl.pdl_reg*}    {*processor/n_tpwp_q_reg*}      {*processor/pwidx_reg*}
        {the CADR's control store} {*processor/imem_reg*}              {*processor/n_tpwpiram_q_reg*}  {*processor/pc_reg*}
    }
    # QUUX's cells that are named for QUUX alone, which a CADR build must not have.
    set quux_only {*processor/g_quux_pdl.pdl_reg* *g_quux_disk.disk/blk_ram_reg*}
    if {$machine eq "quux"} {
        set n 0
        if {$revision eq "14"} {
            set tlb_ramb [get_cells -quiet -hier -filter {REF_NAME =~ RAMB* && NAME =~ *g_rev14_mmu.mmu/tlb/*}]
            if {[llength $tlb_ramb]} {
                lappend quux_rules {revision 14's TLB, its fill} {*g_rev14_mmu.mmu/tlb/tlb_mem_reg*} \
                    {*g_rev14_mmu.mmu/w_load_reg*} {*g_rev14_mmu.mmu/w_va_reg*}
            } else {
                puts "RAMS:         revision 14's TLB is in no block RAM here, so its fill is not asked"
            }
        }
        foreach {what cells we wa} $quux_rules { rams_rule $what $cells $we $wa; incr n }
        puts "RAMS: ok      QUUX: all $n RAMs whose read and write share an address"
        puts "RAMS:         chosen by the write enable were found, and write where the RTL says"
        return
    }
    foreach cells $quux_only {
        set n [llength [get_cells -quiet -hier -filter "REF_NAME =~ RAMB* && NAME =~ $cells"]]
        if {$n} {
            puts "RAMS: FAILED --- $n block RAMs match $cells, which only QUUX has,"
            puts "RAMS: on a CADR build: the machine built is not the one named."
            exit 1
        }
    }
    puts "RAMS: the CADR: looked for QUUX's [join $quux_only { and }], and"
    puts "RAMS: neither is here; no RAM of the CADR shares an address chosen by the"
    puts "RAMS: write enable, so its own write addresses are asked instead:"
    foreach {what cells we wa} $cadr_rules { rams_rule $what $cells $we $wa }
}
