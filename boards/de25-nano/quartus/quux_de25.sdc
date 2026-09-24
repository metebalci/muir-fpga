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
# after the edge, and `quux_machine.xdc` says why.

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
