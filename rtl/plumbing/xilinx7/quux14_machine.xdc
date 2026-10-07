# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# QUUX revision 14's own exceptions, read scoped to `cadr_machine` after
# `quux_machine.xdc` and only for a revision 14 build (`REVISION=14`): every
# object this file names is in `quux_mmu.sv` or its seam to the memory
# port, which no other build has, and Vivado 2026.1 drops a clause whose
# `-from` or `-to` matched nothing with a critical warning (12-4739),
# measured on a three-register design.
#
# **THE TLB IS READ AT THE EDGE** (`quux_mmu.sv`, contract G3 revision 14,
# A14.4 and A14.5): its address is `VMA`'s or `MD`'s next value, its enable
# the generator's last tick, and its word is out from the next cycle's
# first tick.  So it is one of the edge's registers, in the relaxed set by
# `cadr_machine.xdc`'s own pattern, and every clause the edge's registers
# have is its own: K into the relaxed set, K - 2 into the every-tick
# registers, and the microcycle into its address from the registers the
# ALU's output comes from.  Its writes are on the ticks between, from the
# memory system's pending writes, which are out of the set and so at the
# tick.  The edge's own registers of `quux_mmu.sv` (`e_*`, the forwards,
# the walk's entries, the writes landing at the edge and the write-back's
# grant) are in the set by the same pattern.  This file writes what is left:
#
#   - **MD_HELD INTO THE TLB'S PORT B, ONE TICK** (M2's note 4): a word the
#     bus strobed on the tick before an edge is `MD`'s next value there, so
#     the path from `md_held` into port B's address has the tick, as its
#     path into MD has (`quux_machine.xdc`).
#   - **THE SIDE SEAM'S LOOKS INTO THE CACHE'S RAMS, ONE TICK**: the walk's
#     first look, on the generator cycle's first tick, is addressed from
#     `VMA`, `MD`, the directory base and the TLB's word, and the
#     write-back's first, on the tick after the grant, from the grant's
#     registers; every one of them in the relaxed set, whose clause into the
#     cache's held address (`quux_machine.xdc`) would give these looks the
#     microcycle.  Named by the memory system's two outputs the looks leave
#     it by, `sd_look` and `sd_phys`.
#
# The flow asserts each clause took (`boards/arty-z7-20/vivado/
# bitstream.tcl`), and `tools/grid_check.py` holds each `# grid:` count to
# its tag.

set quux_tlb [filter [all_registers] {NAME =~ *processor/g_rev14_mmu.mmu/tlb/*}]

# MD_HELD into port B's address: the tick.
# grid: 0 ns + 1 tick
set_multicycle_path -setup 1 -from $split_md_held -to $quux_tlb
set_multicycle_path -hold  0 -from $split_md_held -to $quux_tlb

# The side seam's looks into the cache's RAMs: the tick, from every register.
set quux_side_look [get_pins -quiet -hier -filter {NAME =~ *processor/g_rev14_mmu.mmu/sd_look || \
                                                   NAME =~ *processor/g_rev14_mmu.mmu/sd_phys[*]}]
# grid: 0 ns + 1 tick
set_multicycle_path -setup 1 -from [all_registers] -through $quux_side_look -to $quux_cache_held
set_multicycle_path -hold  0 -from [all_registers] -through $quux_side_look -to $quux_cache_held
