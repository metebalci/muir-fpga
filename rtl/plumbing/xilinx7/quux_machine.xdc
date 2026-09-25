# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# QUUX's own exceptions, read scoped to `cadr_machine` after
# `cadr_machine.xdc` and only for a QUUX build: an XDC cannot ask which
# machine it is reading, and a clause whose `-to` matches nothing is a clause
# on every path, so the CADR must never read this file.
#
# **QUUX'S MICROCYCLE IS K TICKS, FOUR ON THE ARTY Z7-20** (H1a, the top
# level's `SYNC_K`, muir's `--timing-model sync --sync-cycle-ticks 4`).  The
# CADR's file counts from a microcycle of fourteen ticks at the least, with a
# read phase and a write pulse inside it; QUUX's has neither.  Every register
# of the processor moves on the edge that ends the boundary's tick, every
# write lands on that same edge (`quux_phase_gen.sv`'s write pulse), the
# scratchpad latches load every tick and hold the word from the tick after
# the edge to the next, and the control store is read at the edge from NPC.
# So every clause of the CADR's file is re-issued here at QUUX's counts, and
# ALL of them are re-issued, the unchanged ones too: a clause is ranked by
# its place among clauses of equal specificity, and the relaxed set's own
# clause below would otherwise take every path the CADR's narrower clauses
# had.  The counts are literal, K being the board's, and `tools/grid_check.py`
# holds each `# sync:` count to `boards/arty-z7-20/cadr_arty.sv`'s SYNC_K.
# The flow asserts each clause applied and none wider
# (`boards/arty-z7-20/vivado/bitstream.tcl`).
#
# MEASURED FOR THE PLAN, on the routed QUUX Arty placed against eight ticks,
# as delay against what K = 4 leaves (the requirement less about 0.66 ns of
# setup, uncertainty and skew): the map chain into the next address,
# MEMSTART, VMA or MD through both map levels, the M bus, the rotator and the
# dispatch memory into the control store's address, 33.5 ns of 39.3; the
# multiplier out of the A memory's latch, 28.3 ns of 29.8 at K - 1; the
# stack's latch through the dispatch memory to the PC 22.7 ns of 29.8; IR to
# MD 28.6 of 39.3; the maps' write clock to the PC 28.2 of 39.3.  The fit's
# own report is the figure that counts.
#
# **THE TICK NEEDS NO CLAUSE.**  Its countdown and its flag run every tick and
# stay out of the relaxed set, and a write of destination 3 or 4 reaches them
# from `L`, a register, a tick after the edge (`cadr_microcycle.sv` has why),
# so every path into them is a register a tick away and is timed so.

# ------------------------------------------------ THE RELAXED SET
#
# A register loaded at the edge and read at the next: the whole microcycle.
# sync: K
set_multicycle_path -setup 4 -from $slow -to $slow
set_multicycle_path -hold  3 -from $slow -to $slow

# ------------------------------------------------ THE SPLIT PATHS
#
# **THE EVERY-TICK REGISTERS, SPLIT TO SUM TO K**: `memgo_q`, the held halves
# of -WAIT and the memory path's held decode are loaded every tick from the
# edge's registers and read at the next edge, so a path through one is two
# hops.  Two ticks in and two out: measured 19.0 ns in (the held decode) and
# 11.6 ns out, neither of which fits one tick.
# grid: 0 ns + 2 ticks
set_multicycle_path -setup 2 -from $slow -to $split_every_tick
set_multicycle_path -hold  1 -from $slow -to $split_every_tick
# sync: K - 2
set_multicycle_path -setup 2 -from $split_every_tick -to $slow
set_multicycle_path -hold  1 -from $split_every_tick -to $slow

# Into the scratchpad latches: one tick, each latch loading every tick and
# holding the microcycle's word from the tick after the edge.  Measured
# 2.85 ns into them.
# grid: 0 ns + 1 tick
set_multicycle_path -setup 1 -from $split_latch_addr -to $split_latch
set_multicycle_path -hold  0 -from $split_latch_addr -to $split_latch

# Out of the latches: the tick after the edge to the next edge.
# sync: K - 1
set_multicycle_path -setup 3 -from $split_latch -to $slow
set_multicycle_path -hold  2 -from $split_latch -to $slow

# The scratchpads' writes, on the edge, into the latches that follow them on
# the next tick.  After the clause above, which names both.
# grid: 0 ns + 1 tick
set_multicycle_path -setup 1 -from $split_latch -to $split_latch
set_multicycle_path -hold  0 -from $split_latch -to $split_latch

# Out of the latches into the dispatch memory's write, on the next edge.
# sync: K - 1
set_multicycle_path -setup 3 -from $split_latch -to $split_dmem
set_multicycle_path -hold  2 -from $split_latch -to $split_dmem

# The control store's word, read at the edge from NPC and standing until the
# next: the whole microcycle.
# sync: K
set_multicycle_path -setup 4 -from $split_cstore -to $slow
set_multicycle_path -hold  3 -from $split_cstore -to $slow

# The maps' write and the dispatch memory's, on the edge, to the next edge
# that reads them.
# sync: K
set_multicycle_path -setup 4 -from $split_maps -to $slow
set_multicycle_path -hold  3 -from $split_maps -to $slow
# sync: K
set_multicycle_path -setup 4 -from $split_dmem -to $slow
set_multicycle_path -hold  3 -from $split_dmem -to $slow

# The three memories' writes into the readout's copies, loaded every tick.
# After the two clauses above, which name them too.
# grid: 0 ns + 1 tick
set_multicycle_path -setup 1 -from $split_md_writes -to $split_readout
set_multicycle_path -hold  0 -from $split_md_writes -to $split_readout

# MD into the maps' and the dispatch memory's write: MD moves at master clock
# edges alone on QUUX (a foreign master's word is taken on the boundary's
# tick), and the write is at the next edge that runs a microcycle.
# sync: K
set_multicycle_path -setup 4 -from $split_md -to $split_md_writes
set_multicycle_path -hold  3 -from $split_md -to $split_md_writes

# MD_HELD into MD, and the stack's write into its latch: a tick, as on the
# CADR, re-issued because the relaxed set's clause above names them.
# grid: 0 ns + 1 tick
set_multicycle_path -setup 1 -from $split_md_held -to $split_md
set_multicycle_path -hold  0 -from $split_md_held -to $split_md
# grid: 0 ns + 1 tick
set_multicycle_path -setup 1 -from $split_spcm -to $split_spc_q
set_multicycle_path -hold  0 -from $split_spcm -to $split_spc_q

# **THE DIVIDER TAKES ITS OPERANDS K TICKS INTO THE MICROCYCLE**, on the tick
# of the next master clock edge (`cadr_microcycle.sv`'s `DIV_LOAD_T`).  Its
# steps, `dv_*` in `quux_muldiv.sv`, run a tick at a time and stay out of the
# relaxed set, so each path into it is given the time its source has: the
# edge's registers K ticks, the latches K - 1, the every-tick registers their
# second hop.  A read's word it takes from `md_held` a tick after the strobe
# loaded it (`cadr_microcycle.sv`, "A `DIV` OF `MD`"), which is one tick.  Its
# words go out to the output bus a tick at a time and need no clause.
set quux_divider [filter [all_registers] {NAME =~ *processor/g_quux_muldiv.muldiv/dv_*}]
# sync: K
set_multicycle_path -setup 4 -from $slow -to $quux_divider
set_multicycle_path -hold  3 -from $slow -to $quux_divider
# sync: K
set_multicycle_path -setup 4 -from $split_cstore -to $quux_divider
set_multicycle_path -hold  3 -from $split_cstore -to $quux_divider
# sync: K
set_multicycle_path -setup 4 -from $split_maps -to $quux_divider
set_multicycle_path -hold  3 -from $split_maps -to $quux_divider
# sync: K - 1
set_multicycle_path -setup 3 -from $split_latch -to $quux_divider
set_multicycle_path -hold  2 -from $split_latch -to $quux_divider
# sync: K - 2
set_multicycle_path -setup 2 -from $split_every_tick -to $quux_divider
set_multicycle_path -hold  1 -from $split_every_tick -to $quux_divider
# grid: 0 ns + 1 tick
set_multicycle_path -setup 1 -from $split_md_held -to $quux_divider
set_multicycle_path -hold  0 -from $split_md_held -to $quux_divider

# **WHAT A MICROCYCLE READS OF QUUX'S CLOCKS** (`quux_clocks.sv`).  Source
# 15, `usec_s`, is loaded at the master clock edge, the edge the processor's
# registers move on, and read at the next, so it is in the relaxed set and
# has K ticks there.  Source 17's `flag_s` and `en_s` are loaded at a held
# edge too, but at an edge that runs a microcycle they are loaded a tick
# AFTER it, with that edge's write in them (`w`, from `L`), and stand from
# there to the next edge: K - 1.  They are out of the relaxed set by name
# (`cadr_machine.xdc`), so `L` into them keeps its tick.
set quux_status_s [filter [all_registers] {NAME =~ *processor/g_quux_tick.clocks/flag_s_reg* || \
                                           NAME =~ *processor/g_quux_tick.clocks/en_s_reg*}]
# sync: K - 1
set_multicycle_path -setup 3 -from $quux_status_s -to $slow
set_multicycle_path -hold  2 -from $quux_status_s -to $slow
