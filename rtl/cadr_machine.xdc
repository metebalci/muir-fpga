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

create_clock -name clk -period 5.000 [get_ports clk]

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
