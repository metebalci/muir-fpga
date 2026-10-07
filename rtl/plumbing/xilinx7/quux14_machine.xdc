# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# QUUX revision 14's own exceptions, read scoped to `cadr_machine` after
# `quux_machine.xdc` and only for a revision 14 build (`REVISION=14`): every
# object this file names is in `quux_mmu.sv`'s TLB, which no other build has,
# and Vivado 2026.1 drops a clause whose `-from` or `-to` matched nothing
# with a critical warning (12-4739), measured on a three-register design.
#
# **THE TLB IS READ ON THE GENERATOR CYCLE'S FIRST TICK, A TICK AFTER THE
# EDGE** (`quux_mmu.sv`, "THE HOLD, AND WHEN IT IS DECIDED"): its address is
# `VMA`'s or `MD`'s index as the edge leaves them, its enable is `g1`, and
# its word is out at the end of that tick.  So the TLB is two things the
# relaxed set cannot be at once:
#
#   - **INTO ITS ADDRESS, ONE TICK** (contract G3 revision 14, A14.15, M2's
#     note: "a one-tick constraint into port B's address").  `VMA` and `MD`
#     are in the relaxed set and so is the RAM, so without this clause their
#     paths into the address would be given the microcycle where they have
#     the tick after the edge; and a block RAM enabled while its address
#     still moves can lose words (UG473; `boards/arty-z7-20/vivado/
#     rams_enable_check.tcl`).  Both ports' address pins, whichever the tool
#     calls A: Vivado swaps a true dual-port RAM's ports (M2).  Its data and
#     write enables keep the relaxed set's K: a write lands at the master
#     clock edge (the write-back's OR) or at the cpu edge (an operation), K
#     ticks after the edge's registers moved, and on the ticks between the
#     enable is held off by the generator's own edge terms, which are not in
#     the set and are timed at the tick.
#   - **OUT OF IT, ONE TICK LESS THAN EACH CLAUSE GIVES THE EDGE'S
#     REGISTERS**, the word leaving the RAM a tick after theirs: K - 1 to the
#     next edge, and K - 3 into the every-tick registers, whose first hop the
#     relaxed set's registers have K - 2 for (`quux_machine.xdc`, "THE
#     EVERY-TICK REGISTERS, SPLIT TO SUM TO K").  At K = 4 that is the tick
#     itself: the port's entry through the tag compare into `MEMGO`'s held
#     copy and the memory path's held decode.
#
# The TLB is out of `cadr_machine.xdc`'s control-store split by name, so the
# clauses here are the only ones written from it.  The flow asserts each
# took (`boards/arty-z7-20/vivado/bitstream.tcl`), and `tools/grid_check.py`
# holds each `# sync:` count to its tag.

set quux_tlb [filter [all_registers] {NAME =~ *processor/g_rev14_mmu.mmu/tlb/*}]
set quux_tlb_addr [get_pins -quiet -of $quux_tlb -filter {REF_PIN_NAME =~ ADDR*}]

# Out of the TLB, to the next edge.
# sync: K - 1
set_multicycle_path -setup [expr {$sync_k - 1}] -from $quux_tlb -to $slow
set_multicycle_path -hold  [expr {$sync_k - 2}] -from $quux_tlb -to $slow

# Out of the TLB into the every-tick registers' first hop.
# sync: K - 3
set_multicycle_path -setup [expr {$sync_k - 3}] -from $quux_tlb -to $split_every_tick
set_multicycle_path -hold  [expr {$sync_k - 4}] -from $quux_tlb -to $split_every_tick

# Out of the TLB into the divider's operands and the cache's address, each
# of which the edge's registers have K for.
# sync: K - 1
set_multicycle_path -setup [expr {$sync_k - 1}] -from $quux_tlb -to $quux_divider
set_multicycle_path -hold  [expr {$sync_k - 2}] -from $quux_tlb -to $quux_divider
# sync: K - 1
set_multicycle_path -setup [expr {$sync_k - 1}] -from $quux_tlb -to $quux_cache_held
set_multicycle_path -hold  [expr {$sync_k - 2}] -from $quux_tlb -to $quux_cache_held

# Into both ports' addresses, from every register: the tick.  Last, so that
# it outranks every clause above that names the RAM as a destination.
# grid: 0 ns + 1 tick
set_multicycle_path -setup 1 -from [all_registers] -to $quux_tlb_addr
set_multicycle_path -hold  0 -from [all_registers] -to $quux_tlb_addr
