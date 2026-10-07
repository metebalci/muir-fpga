# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# QUUX's own exceptions on the DE25-Nano, read after `cadr_de25.sdc` and only
# for a QUUX build: `rtl/plumbing/xilinx7/quux_machine.xdc` gives each its
# argument, and this is the same set in this tool's words, at this board's
# K, four ticks (`boards/de25-nano/cadr_de25.sv`'s SYNC_K), which
# `tools/grid_check.py` holds every `# sync:` count to.
#
# Every clause of `cadr_de25.sdc` is re-issued, the unchanged ones too,
# because the relaxed set's clause below comes after them and would take
# their paths.  What differs from the Zynq file is what `cadr_de25.sdc`
# says: the latches are the M20K blocks' own address registers, and the
# maps' and the dispatch memory's writes into MLABs have no arc Quartus
# times.  On QUUX that write is on the edge, and the MLAB gives the new word
# from the edge after, so the rest of the path, from the map's output to the
# next edge, has K - 1 ticks and is timed as the path out of the latches is.
#
# The tick needs no clause: its write reaches its countdown from `L`, a tick
# after the edge, and `quux_machine.xdc` says why.  What a microcycle reads of
# the clocks has one, below.

# The relaxed set: a register loaded at the edge and read at the next.
# sync: K
set_multicycle_path -setup 4 -from $slow -to $slow
set_multicycle_path -hold  3 -from $slow -to $slow

# The every-tick registers, two ticks in and the rest of the microcycle out.
# grid: 0 ns + 2 ticks
set_multicycle_path -setup 2 -from $slow -to $split_every_tick
set_multicycle_path -hold  1 -from $slow -to $split_every_tick
# sync: K - 2
set_multicycle_path -setup 2 -from $split_every_tick -to $slow
set_multicycle_path -hold  1 -from $split_every_tick -to $slow

# Into the latches, which load every tick: one tick.
# grid: 0 ns + 1 tick
set_multicycle_path -setup 1 -from $split_latch_addr -to $split_latch
set_multicycle_path -hold  0 -from $split_latch_addr -to $split_latch

# Out of the latches: the tick after the edge to the next edge.
# sync: K - 1
set_multicycle_path -setup 3 -from $split_latch -to $slow
set_multicycle_path -hold  2 -from $split_latch -to $slow

# Out of the latches into the dispatch memory's write.
# sync: K - 1
set_multicycle_path -setup 3 -from $split_latch -to $split_dmem
set_multicycle_path -hold  2 -from $split_latch -to $split_dmem

# The control store's word, read at the edge from NPC.
# sync: K
set_multicycle_path -setup 4 -from $split_cstore -to $slow
set_multicycle_path -hold  3 -from $split_cstore -to $slow

# MD into the writes' address: MD moves at master clock edges alone.
# sync: K
set_multicycle_path -setup 4 -from $split_md -to $split_md_writes
set_multicycle_path -hold  3 -from $split_md -to $split_md_writes

# MD_HELD into MD: a tick.
# grid: 0 ns + 1 tick
set_multicycle_path -setup 1 -from $split_md_held -to $split_md
set_multicycle_path -hold  0 -from $split_md_held -to $split_md

# What a microcycle reads of QUUX's clocks, out of the relaxed set with the
# rest of `quux_clocks.sv` and given its own time here, which
# `quux_machine.xdc` argues.  Source 15, `usec_s`, is loaded at the master
# clock edge, the edge the processor's registers move on, and read at the
# next: K ticks.  Source 17 read Q1's status until revision 10, which has it
# read all ones (contract Q11): its clauses are gone, and `flag_s`, now what
# the register page reads at the tick it takes a read, stays at the tick.
# Since destination 3 writes only M, `L` does not reach it.
set quux_usec_s [get_registers -nowarn [cadr_leaves {u_machine|processor|g_quux_tick.clocks|} {usec_s}]]
# sync: K
set_multicycle_path -setup 4 -from $quux_usec_s -to $slow
set_multicycle_path -hold  3 -from $quux_usec_s -to $slow

# The divider's operands, taken K ticks into the microcycle, from the edge's
# registers, the control store and the latches, and from the every-tick
# registers' second hop; and a read's word, which the divider takes from
# `md_held` a tick after the strobe (`cadr_microcycle.sv`, "A `DIV` OF `MD`").
set quux_divider [get_registers -nowarn {u_machine|processor|*muldiv|dv_*}]
# sync: K
set_multicycle_path -setup 4 -from $slow -to $quux_divider
set_multicycle_path -hold  3 -from $slow -to $quux_divider
# sync: K
set_multicycle_path -setup 4 -from $split_cstore -to $quux_divider
set_multicycle_path -hold  3 -from $split_cstore -to $quux_divider
# sync: K - 1
set_multicycle_path -setup 3 -from $split_latch -to $quux_divider
set_multicycle_path -hold  2 -from $split_latch -to $quux_divider
# sync: K - 2
set_multicycle_path -setup 2 -from $split_every_tick -to $quux_divider
set_multicycle_path -hold  1 -from $split_every_tick -to $quux_divider
# grid: 0 ns + 1 tick
set_multicycle_path -setup 1 -from $split_md_held -to $quux_divider
set_multicycle_path -hold  0 -from $split_md_held -to $quux_divider

# **QUUX'S MEMORY PORT** (contract Q6), out of the relaxed set whole
# (`cadr_de25.sdc`) but for what the cache holds of the microcycle: its M20K
# blocks, read at every master clock edge the port is idle, and the address they were
# read at, `idx_q`, `tag_q` and `off_q`.  The map's output into them has the
# whole microcycle; everything out of them is timed at the tick.
# `rtl/plumbing/xilinx7/quux_machine.xdc` has the argument.
set quux_cache_held [add_to_collection \
    [get_keepers -nowarn {u_machine|memory|g_quux_port.port|cache|*ram_rtl_*}] \
    [get_registers -nowarn [cadr_leaves {u_machine|memory|g_quux_port.port|cache|} {idx_q tag_q off_q}]]]
# Each source the time it has, as for the divider above.
# sync: K
set_multicycle_path -setup 4 -from $slow -to $quux_cache_held
set_multicycle_path -hold  3 -from $slow -to $quux_cache_held
# sync: K
set_multicycle_path -setup 4 -from $split_cstore -to $quux_cache_held
set_multicycle_path -hold  3 -from $split_cstore -to $quux_cache_held
# sync: K - 1
set_multicycle_path -setup 3 -from $split_latch -to $quux_cache_held
set_multicycle_path -hold  2 -from $split_latch -to $quux_cache_held
# sync: K - 2
set_multicycle_path -setup 2 -from $split_every_tick -to $quux_cache_held
set_multicycle_path -hold  1 -from $split_every_tick -to $quux_cache_held
# grid: 0 ns + 1 tick
set_multicycle_path -setup 1 -from $split_md_held -to $quux_cache_held
set_multicycle_path -hold  0 -from $split_md_held -to $quux_cache_held

# **REVISION 14'S TLB** (contract G3 revision 14), an M20K read on the
# generator cycle's first tick, a tick after the edge:
# `rtl/plumbing/xilinx7/quux14_machine.xdc` has the argument, and this is
# the same set in this tool's words.  Quartus keeps a RAM out of a register
# collection, so the TLB is in no relaxed set here: every path into it and out
# of it is the tick unless a clause below says otherwise.  Out of it, one
# tick less than each clause gives the edge's registers: K - 1 to the next
# edge and into the divider's operands and the cache's address, and one into
# the every-tick registers, which the edge's registers reach in two.  Into
# it, the address of either port stays at the tick; its words, its write
# enables and its read enables take the edge's registers' K, a write
# landing at the master clock edge or the cpu edge and the generator's edge
# terms, which are at the tick, holding the enables off on the ticks
# between; and the TLB's own word into them, a write-back's OR, K - 1.  A
# revision 13 build has no TLB, and then no clause is written.
set quux_tlb [get_keepers -nowarn {u_machine|processor|g_rev14_mmu.mmu|tlb|*}]
if {[get_collection_size $quux_tlb] > 0} {
    set quux_tlb_in [get_pins -nowarn -compatibility_mode \
        {u_machine|processor|g_rev14_mmu.mmu|tlb|*|portadatain* u_machine|processor|g_rev14_mmu.mmu|tlb|*|portawe*
         u_machine|processor|g_rev14_mmu.mmu|tlb|*|portare* u_machine|processor|g_rev14_mmu.mmu|tlb|*|portbdatain*
         u_machine|processor|g_rev14_mmu.mmu|tlb|*|portbwe* u_machine|processor|g_rev14_mmu.mmu|tlb|*|portbre*}]
    # sync: K - 1
    set_multicycle_path -setup 3 -from $quux_tlb -to $slow
    set_multicycle_path -hold  2 -from $quux_tlb -to $slow
    # grid: 0 ns + 1 tick
    set_multicycle_path -setup 1 -from $quux_tlb -to $split_every_tick
    set_multicycle_path -hold  0 -from $quux_tlb -to $split_every_tick
    # sync: K - 1
    set_multicycle_path -setup 3 -from $quux_tlb -to $quux_divider
    set_multicycle_path -hold  2 -from $quux_tlb -to $quux_divider
    # sync: K - 1
    set_multicycle_path -setup 3 -from $quux_tlb -to $quux_cache_held
    set_multicycle_path -hold  2 -from $quux_tlb -to $quux_cache_held
    # sync: K
    set_multicycle_path -setup 4 -from $slow -through $quux_tlb_in -to $quux_tlb
    set_multicycle_path -hold  3 -from $slow -through $quux_tlb_in -to $quux_tlb
    # sync: K
    set_multicycle_path -setup 4 -from $split_cstore -through $quux_tlb_in -to $quux_tlb
    set_multicycle_path -hold  3 -from $split_cstore -through $quux_tlb_in -to $quux_tlb
    # sync: K - 1
    set_multicycle_path -setup 3 -from $split_latch -through $quux_tlb_in -to $quux_tlb
    set_multicycle_path -hold  2 -from $split_latch -through $quux_tlb_in -to $quux_tlb
    # sync: K - 2
    set_multicycle_path -setup 2 -from $split_every_tick -through $quux_tlb_in -to $quux_tlb
    set_multicycle_path -hold  1 -from $split_every_tick -through $quux_tlb_in -to $quux_tlb
    # sync: K - 1
    set_multicycle_path -setup 3 -from $quux_tlb -through $quux_tlb_in -to $quux_tlb
    set_multicycle_path -hold  2 -from $quux_tlb -through $quux_tlb_in -to $quux_tlb
}
