# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Timing constraints for the composed machine.
#
# 200 MHz exists only to resolve the 5 ns delay-line taps. Netlist logic
# settles *between* phases, where the 75 ns fast read tap is the real
# constraint. Hold all 1,821 registers to the tick and the routed report says
# WNS -17.265 ns on the map lookup rippling into the control store's address,
# 21.615 ns over 26 logic levels --- a path that has a phase to happen in.
# (That register count is of the design as it then was. At 712909e the machine
# is 769 registers placed and routed out of context, and the experiment has
# not been repeated at that size.)
# That is the pessimistic version CLAUDE.md says not to spread, and it
# distorts placement as well as the report: the placer spends itself on 6,637
# impossible paths.
#
# **But relaxing everything outside the generator is wrong**, and an earlier
# version of this file did exactly that and reported all timing met. It is
# not the module that decides; it is whether a register's input is stable
# across the microcycle and its consumer reads it only at the end.
#
#   - The scratchpad latches qualify. `amem[aadr]` is constant for the whole
#     microcycle because `aadr` comes off IR, so the latch captures the same
#     value every tick and only the last is read. `imem_q` and `prom_q` too.
#   - A free-running counter does not: it is its own input, and a 15-tick
#     multicycle says its increment may take 75 ns, at which point it does not
#     count. `mfinish_t`, `rdfinish_t`, `elapsed`, `vco_count`, `arb_t`,
#     `phase_t`.
#   - An edge detector does not: it exists to spot a transition and is read
#     the next tick. `n_memack_q`, `n_loadmd_q`, `n_tpwpiram_q`, `n_tpwp_q`,
#     `tpclk_q`. Note these are named, not matched on `_q`, because the
#     scratchpad latches share that suffix and must not be caught.
#
# Paths *into* the generator are already tick-rate and must stay so: they are
# slow-to-fast, which `-from $slow -to $slow` does not match. `speed`
# especially --- the synchroniser updates it at phase 12 and the 74S151 samples
# it at phase 13, one tick.

# NO `create_clock` HERE, and that is the point of the file.  This is timing
# *exception* policy --- what may take a microcycle and what may not --- and
# it is read by both the out-of-context fit and the board flow, which do not
# agree about what the clock is.  Out of context `clk` is a port and
# `vivado/fit.tcl` declares it; on the board it is an MMCM output and
# `rtl/cadr_arty.xdc` constrains the 125 MHz pin it is derived from.  A
# `create_clock` on `[get_ports clk]` here is a critical warning in one of
# those two flows, and a critical warning that means nothing is how a
# constraint that means nothing goes unnoticed.

# One `filter` call, because an XDC is a restricted Tcl subset: `foreach` and
# `concat` are rejected with a critical warning and the constraint then applies
# to nothing at all. An earlier version of this file built the set with a loop,
# which works when sourced as plain Tcl and silently does nothing when read as
# an XDC --- the report then shows the unconstrained design and looks like a
# real result.
#
# The five edge detectors are named individually rather than matched on `_q`,
# because the scratchpad latches share that suffix --- `amem_q`, `mmem_q`,
# `pdl_q`, `spc_q` --- and they are exactly the registers that should be
# relaxed.
set slow [filter [all_registers] {NAME !~ *u_phase_gen*      && \
                                  NAME !~ *mfinish_t_reg*    && \
                                  NAME !~ *rdfinish_t_reg*   && \
                                  NAME !~ *elapsed_reg*      && \
                                  NAME !~ *vco_count_reg*    && \
                                  NAME !~ *arb_t_reg*        && \
                                  NAME !~ *phase_t_reg*      && \
                                  NAME !~ *n_memack_q_reg*   && \
                                  NAME !~ *n_loadmd_q_reg*   && \
                                  NAME !~ *n_tpwpiram_q_reg* && \
                                  NAME !~ *n_tpwp_q_reg*     && \
                                  NAME !~ *tpclk_q_reg*}]

# 15 ticks, not 29: the tightest instant a datapath register is read at is the
# fast read tap.
set_multicycle_path -setup 15 -from $slow -to $slow
set_multicycle_path -hold  14 -from $slow -to $slow

# THE MEMORY PORT'S OWN DEADLINE IS NOT HERE, AND IT CANNOT BE.
#
# `mem_addr`, `mem_wdata` and `mem_write` leave this module for whatever is
# behind the memory port, and the bus specification --- quoted in
# `rtl/cadr_xbus_ddr.sv` --- makes the master responsible for asserting them
# 80 ns before the request.  That is sixteen ticks, and it is a timing
# exception waiting to be written.  It is written in `rtl/cadr_ddr.xdc`
# instead, for a reason worth recording rather than rediscovering:
#
# **THIS FILE IS READ SCOPED, `read_xdc -ref cadr_machine`, and the registers
# that receive those three signals are outside the module.**  A scoped file
# cannot name them.  Nor can it name the ports they leave by: `set_multicycle
# _path -through [get_ports {mem_addr[*] ...}]` was tried and Vivado 2026.1
# answered
#
#     CRITICAL WARNING: [Vivado 12-4739] set_multicycle_path:No valid
#     object(s) found for '-through [get_ports -quiet {...}]'
#
# twice, and `report_exceptions` then counted two exceptions where there
# should have been four.  Measured on the board flow at 1d3a9bc plus this
# work.  It is the `foreach` failure again in a new costume --- a constraint
# that reads cleanly and reaches nothing --- and the only thing that caught it
# was the critical warning being read.
#
# Nor do the hierarchical pins survive to be named from outside: on the board
# netlist `get_pins u_machine/mem_addr[*]` and `u_machine/mem_wdata[*]` are
# both empty, the buses having been dissolved by synthesis --- 32 bits of
# address arrive as 23 registers, the rest of the byte address being constant.
# `u_machine/mem_write` does survive, alone.  So the exception has to name the
# far side, which is the top level's business and not this file's.

# WHAT THIS REPORTED BEFORE THE TWO HOLDINGS BELOW, placed and routed on an
# xc7z020clg400-1: timing NOT met, five paths violating, and they were one
# path fanned across the counter's bits:
#
#     -3.957 ns   processor/memstart_reg_replica_1/C
#              -> processor/rdfinish_t_reg[1]/R
#              8.349 ns (logic 2.349, route 6.001)
#
# `memstart` reaching the synchronous reset of the -RDFINISH counter, 72% of
# it routing. Everything else met. Utilisation was not the problem then and is
# not now: 2,795 LUTs of 53,200 and 28 block RAM tiles of 140 at 712909e.
#
# A later report named a second endpoint of the same family:
#
#     -6.542 ns   processor/vma_reg[13]_replica/C
#              -> processor/n_loadmd_q_reg/D
#
# THE FAMILY, AND WHY IT IS NOT ANSWERED HERE. Both are the map arriving at a
# register this file deliberately refuses to relax --- a counter in the first,
# an edge detector in the second. That refusal is right: `rdfinish_t` really
# does count every tick and `n_loadmd_q` really does have to see -LOADMD move
# within one. What is wrong is the path, not the exception. `VMAOK` and the
# address decode are the far end of two asynchronous RAMs and are constant
# for the microcycle they belong to, so the fix is to hold that decision in a
# register of its own and let the tick-rate logic start from there.
#
# Two holdings do it, and neither is a constraint:
#
#   - `cadr_memory_path.sv` registers the decode, so `is_memory` no longer
#     carries the map into `cadr_xbus_ddr`'s `sel` and out through -MEMACK
#     and -LOADMD. `ub_addr` is held with it, for the register block's
#     `elapsed`.
#   - `cadr_microcycle.sv` holds `MEMSTART AND VMAOK` as `memgo_q` for the
#     two countdowns, so the map no longer reaches `mfinish_t/R` or
#     `rdfinish_t/R`.
#
# Each new register is stable across the microcycle and read at the end of
# one, so each is in `slow` by this file's own test and needs no naming.
#
# THE RULE THAT TELLS THE TWO REMEDIES APART, because there are two and they
# are not interchangeable. A fifth destination in the same family --- the
# Unibus SSYN time reaching `mfinish_t` and `rdfinish_t`, 198 ps on the board
# flow --- did NOT take the holding above. It took the other one: the sums
# were moved off the comparator's path, `ssyn_at + UB_ACK_T` becoming a held
# `ub_ack_at`, which is what `cadr_phase_gen.sv` does for its taps.
#
# The deciding question is **when the signal is read**, not what it is:
#
#   - Read once, at a known instant, with the value settled long before?
#     Hold the decision in a register. The map's decode is read at the grant
#     and `MEMSTART AND VMAOK` at the microcycle boundary, so a tick of
#     holding cannot reach across the twenty-odd ticks they have been stable.
#   - Read every tick, because it exists to catch something moving? Then
#     holding it is wrong at any depth, and the only remedy is to make the
#     path shorter --- move an adder to where it has a whole tick, leave the
#     comparator alone with a register.
#
# `MEMRQ` and `MBUSY` are the two halves of one expression and fall on
# opposite sides of that line, which is why `cadr_microcycle.sv` holds one and
# not the other. Pattern-matching the family would have got the fifth one
# wrong.
#
# MEASURED AT 712909e, and the holdings did what they were for. Placed and
# routed out of context by `vivado/fit.tcl`: WNS -0.484 ns, 94 failing
# endpoints of 13,444, hold met at +0.061 ns. On the board through
# `vivado/bitstream.tcl`, where this file is read scoped: WNS -0.129 ns, 16
# failing endpoints of 14,135, hold met at +0.079 ns.
#
# NEITHER ENDPOINT NAMED ABOVE IS ANYWHERE NEAR THE TOP NOW. `n_loadmd_q_reg`
# and `memstart` between them appear not once in the ten worst paths of either
# flow --- the reports are `report_timing_summary -max_paths 10`, so that is
# what "no longer near the top" is measured against and not more. What is
# worst out of context is a third member of the same family, and it is the one
# this file's policy predicts:
#
#     -0.484 ns   processor/ir_reg[26]/C
#              -> processor/mfinish_t_reg[1]/R
#              4.971 ns (logic 1.076, route 3.895), 5 logic levels
#
# A datapath register into a tick-rate counter's reset: slow-to-fast, so the
# `-from $slow -to $slow` multicycle does not match it and must not, and it
# has one tick to arrive in. It is within half a nanosecond of doing so, and
# on the board the same family is worst at -0.384 ns from `ir_reg[25]` at
# b1bcc34 --- where at 712909e the board's worst was somewhere else entirely,
# the phase generator's write pulse into the dispatch memory's LUTRAM write
# enables, 3 logic levels and 80% route delay. Two revisions, two worst nets:
# the family is stable and the net is placement, so a net quoted from a timing
# report belongs with the commit it was measured at.
#
# The 10,972 paths this file relaxes to 75.000 ns out of context, and the
# 10,929 it relaxes on the board --- 10,956 there once routed --- are what
# `vivado/constraints_check.tcl` asserts on: a count of zero at that
# requirement is the `foreach` bug back again, and both flows now stop on it
# before they place anything.
