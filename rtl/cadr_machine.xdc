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

# WHAT THIS CURRENTLY REPORTS, placed and routed on an xc7z020clg400-1:
# timing is NOT met. Five paths violate, and they are one path fanned across
# the counter's bits:
#
#     -3.957 ns   processor/memstart_reg_replica_1/C
#              -> processor/rdfinish_t_reg[1]/R
#              8.349 ns (logic 2.349, route 6.001)
#
# `memstart` reaching the synchronous reset of the -RDFINISH counter, 72% of
# it routing. Everything else meets. Utilisation is not the problem: 2,764
# LUTs of 53,200 and 28 block RAM tiles of 140.
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
# NOT YET MEASURED. `make check` is green on all nine, which says the holdings
# changed no behaviour; what they were for is a slack figure, and this has not
# been placed and routed since. The numbers above are the last report and are
# left as the last report.
