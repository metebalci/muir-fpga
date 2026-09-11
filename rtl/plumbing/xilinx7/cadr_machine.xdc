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
#   - Nor does an acknowledgement. `deskewed`, `ub_acked` and `ub_loadmd` are
#     the bus interface's three taps --- the 60 ns tap of the TD100 at REQLM
#     0C09, and the Unibus's 150 and 100 ns instants --- written as registers
#     rather than as comparisons against `elapsed`; the long notes in
#     `rtl/machine/cadr_busint_xbus.sv` say why. They are what -MEMACK and -LOADMD are
#     made of, so they are read every tick and are named here for that reason.
#     They are the only registers in the design that had to be named rather
#     than falling into `slow` on their own, and the reason is worth keeping:
#     a comparison moved into a register is invisible to this file's own test,
#     which asks what a register's consumers do and not what it replaced.
#
# Paths *into* the generator are already tick-rate and must stay so: they are
# slow-to-fast, which `-from $slow -to $slow` does not match. `speed`
# especially --- the synchroniser updates it at phase 12 and the 74S151 samples
# it at phase 13, one tick.

# NO `create_clock` HERE, and that is the point of the file.  This is timing
# *exception* policy --- what may take a microcycle and what may not --- and
# it is read by both the out-of-context fit and the board flow, which do not
# agree about what the clock is.  Out of context `clk` is a port and
# `boards/arty-z7-20/vivado/fit.tcl` declares it; on the board it is an MMCM output and
# `boards/arty-z7-20/cadr_arty.xdc` constrains the 125 MHz pin it is derived from.  A
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
#
# **THE DISK CONTROLLER IS OUT OF THE SET, WHOLE, BUT FOR ITS TWO HELD
# DECODES.**  `all_registers` under `cadr_machine` took every register of
# `rtl/machine/cadr_disk_controller.sv` the day that module landed, and by this
# file's own test nearly none of them qualifies: the spindle adds five
# nanoseconds a tick, the busy counter and the eight attention countdowns
# subtract five a tick, `elapsed` counts the walk, and the channel moves a
# word a tick through a state machine whose every register is its own input.
# The one register the name list happened to catch was `elapsed` --- the bus
# interface's pattern matched the disk's too --- and everything else was
# relaxed to seventy-five nanoseconds.  Asked of the routed DDR=1 board at
# ef9dee9: 3,904 of the disk's 4,000 internal paths carried the exception,
# and the longest of them was 20.1 ns, seventeen logic levels from
# `ch_state_reg[1]` back into `ch_state_reg[2]`.  Every timing figure that
# board reported with the drive in it was of a design a quarter of which was
# not being timed.  This is the too-wide exemption CLAUDE.md warns looks
# exactly like one that is right, found by asking the checkpoint what
# requirement the paths carried rather than reading the summary.
#
# The two that stay are `mine` and `which`: the slave's address match and
# register number, taken once from the far end of the map and constant for
# the microcycle --- `cadr_memory_path.sv`'s held decode one slave along, and
# the same argument.  Paths INTO them from the map need the microcycle and
# get it; paths OUT of them are timed at the tick wherever they land on a
# register that is not in this set, which is every register in the disk.
#
# **THE DISPLAY IS OUT OF THE SET THE SAME WAY, BUT FOR ITS THREE HELD
# DECODES**, `ctl`, `fb` and `which` in `rtl/machine/cadr_tv.sv`, held from `phys`
# for the disk's reason.  Nothing else there qualifies: the frame counter
# adds one a tick and presets the flag as it wraps, `taken` is the cycle's
# latch, and the mode register's clock enable is -XBUS.RQ through the held
# match --- read at the tick, so its D from the cpu's word is timed at the
# tick too, as the disk's registers are.
#
# **AND THE CONSOLE'S READ-BACK IS IN THE SET, WHICH IS THE WHOLE REASON IT
# IS INSIDE THIS MACHINE.**  `rtl/plumbing/cadr_console.sv` is an AXI slave on
# `M_AXI_GP1` a level above, beside the PS7, and it reads the sixteen
# diagnostic registers --- which is `Engine::spy_read`, a sixteen-way mux over
# `IR`, `PC`, `OPC`, `OB`, the A and M buses, `ST` and the two flag words.
# With the register that catches that mux's answer up there in the console,
# this file could not name it: it is read `read_xdc -ref cadr_machine` and
# cannot reach a level above, which is the same wall `mem_addr` met and the
# reason `rtl/plumbing/xilinx7/cadr_ddr.xdc` exists.  The board flow then asked the mux to
# settle in one tick and reported
#
#     -12.837 ns  u_machine/processor/md_reg[15]/C
#              -> g_ddr.u_console/eng_rdata_reg[1]/D
#              17.703 ns over 24 logic levels, 70% of it routing
#
# on 5,698 endpoints of 27,144, where the commit before the console read
# -0.148 ns on the same board.  Two and a half ticks, and the worst this
# project has measured.
#
# `rtl/machine/cadr_console_bus.sv` moves that register in here, where it falls into
# the set with no naming --- and it earns the set on this file's own test
# rather than by being in the right module.  Its input is the mux, whose every
# source is a register that moves at the microcycle boundary and stands still
# between; and it is loaded AT THE BOUNDARY AND NOWHERE ELSE, `mclk` being its
# whole clock enable, so it is launched at one boundary and captured at the
# next with twenty-nine ticks to settle in at normal speed and forty-four at
# extra slow. Loaded every tick it would be a register holding whatever a
# relaxed path had reached, which is the too-wide exemption in its purest
# form; `console-read-back-is-not-held-to-the-boundary` is the mutation that
# says so, and `build/console.pass` catches it by MEASURING the lag --- reading
# `PC` with the machine running and asking which row the answer belongs to.
# A halted read cannot resolve it, the machine having stopped moving.
#
# **AND ITS CLOCK ENABLE WAS ASKED ABOUT RATHER THAN REASONED ABOUT**, which
# is the trap this file already records one register along --- `elapsed ->
# md/CE`, where a relaxed register's enable went with it. The prose written
# here first said the enable was not relaxed at all, because `mclk` is made
# from `tpclk` and `tpclk_q` and both are excluded above. `get_property
# REQUIREMENT` says otherwise, and it is the third startpoint that does it.
# Synthesised at this slice with this file read scoped, every path into
# `con_rdata_reg[*]/CE`:
#
#     5.000 ns   u_machine/processor/u_phase_gen/tpclk_reg   x64
#     5.000 ns   u_machine/processor/tpclk_q_reg             x64
#    75.000 ns   u_machine/processor/started_reg             x64
#
# The two that make the edge stay at one tick, which is what matters: a
# boundary that arrived a microcycle late would put the capture anywhere.
# `started` is relaxed, and is the one register in the design for which that
# cannot mean anything --- it goes high at the first boundary out of reset and
# never changes again, so "its input is stable across the microcycle and its
# consumer reads it only at the end" is true of it more completely than of
# anything else in the set.
#
# The reasoning was right about the half that decides and wrong about the
# whole, and only the question told the difference. The same query says every
# one of 400 paths into `con_rdata_reg[*]/D` asks for 75.000, worst
# `vma_reg[14]/C` at 24 logic levels with 57.148 ns of slack --- so the
# naming took, which a slack figure alone could never have said.

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
                                  NAME !~ *deskewed_reg*     && \
                                  NAME !~ *ub_acked_reg*     && \
                                  NAME !~ *ub_loadmd_reg*    && \
                                  NAME !~ *tpclk_q_reg*      && \
                                  (NAME !~ *disk/* || NAME =~ *disk/mine_reg* || \
                                                      NAME =~ *disk/which_reg*) && \
                                  (NAME !~ *memory/tv/* || NAME =~ *memory/tv/ctl_reg* || \
                                                           NAME =~ *memory/tv/fb_reg* || \
                                                           NAME =~ *memory/tv/which_reg*)}]

# 15 ticks, not 29: the tightest instant a datapath register is read at is the
# fast read tap.
set_multicycle_path -setup 15 -from $slow -to $slow
set_multicycle_path -hold  14 -from $slow -to $slow

# THE MEMORY PORT'S OWN DEADLINE IS NOT HERE, AND IT CANNOT BE.
#
# `mem_addr`, `mem_wdata` and `mem_write` leave this module for whatever is
# behind the memory port, and the bus specification --- quoted in
# `rtl/plumbing/cadr_xbus_ddr.sv` --- makes the master responsible for asserting them
# 80 ns before the request.  That is sixteen ticks, and it is a timing
# exception waiting to be written.  It is written in `rtl/plumbing/xilinx7/cadr_ddr.xdc`
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
# THE RULE APPLIED AGAIN, WITH THE MEMORY SWITCHED ON, and it sent the two
# arcs different ways for the third and fourth time. `DDR=1` puts the
# processing system behind the memory port, which is the first build that
# times `mem_addr` and `mem_wdata` at all --- `rtl/plumbing/xilinx7/cadr_ddr.xdc` has that
# story. At a840c85 that board reported WNS -0.446 ns on 86 endpoints, where
# the same commit with the memory off reported -0.054 on one. Every one of the
# 86 was inside the machine and none in the new logic, and they were two arcs
# rather than eighty-six:
#
#     61  md_reg/CE, md_held_reg/CE, md_pending_reg/D  <- busint/elapsed_reg/C
#     13  mfinish_t_reg/CE and /D, rdfinish_t_reg/D    <- busint/answered_at_reg/C
#     12  mfinish_t_reg/R, rdfinish_t_reg/R            <- processor/ir_reg/C
#      1  u_phase_gen/tpclk_reg/D                      <- processor/ir_reg/C
#
# The first two rows are one thing seen from both ends: the read deskew
# written as `elapsed >= answered_at + DESKEW_T`, a ten-bit magnitude compare
# standing between the interface's counter and -MEMACK/-LOADMD, which cross to
# the processor and land on MD's clock enables and on the two countdowns. The
# last two are the -WAIT decode: `ir` through DESTM, DESTLC and NEEDFETCH into
# MACHRUN, and MACHRUN into a countdown's reset.
#
#   - The deskew is read every tick. It *is* the acknowledgement, so holding
#     it is wrong at any depth and the path is shortened instead: the
#     comparison is made one tick early and registered, which is the move
#     `cadr_phase_gen.sv` makes for its own taps. `elapsed >= X` at tick t is
#     `elapsed >= X - 1` at t-1, so the value arrives on the same tick with
#     the carry chain off the acknowledgement's path. The Unibus's two
#     instants took the same treatment once the deskew stopped being worst,
#     which is the rest of the move begun when `ssyn_at` became `ub_ack_at`.
#   - MACHRUN is read at one instant and one only --- `cpu_edge` is
#     `mclk_edge && machrun`, one tick a microcycle --- and the IR-derived
#     half of each -WAIT term has been settled since the boundary before. So
#     `DESTMEM`, `USE.MD` and `LCINC AND NEEDFETCH` are held, as `destmem_q`,
#     `use_md_q` and `ifetch_q`. The other half of each term is `MBUSY.SYNC`,
#     `MBUSY` and `-MEMGRANT`, which move within the microcycle and are left
#     alone: -MFINISHD clearing MBUSY in the very tick MCLK1A samples it is
#     where a 220 ns wait cycle turns on, and a tick of holding there would
#     lose a boundary and cost a microcycle.
#
# Same rule, same file, opposite answers, and the three taps are the reason
# this file now names registers that are not edge detectors.
#
# AND THAT WAS ASKED OF THE DESIGN RATHER THAN ASSUMED, synthesised out of
# context with this file read: every path out of `deskewed`, `ub_acked` and
# `ub_loadmd` asks for 5.000 ns, so the naming took; 181 of the first 200 out
# of `destmem_q`, `use_md_q` and `ifetch_q` ask for 75.000 and the other 19 for
# 5.000, which is those three landing in `slow` and their arcs into the
# countdowns and the edge detectors staying at one tick. A register named here
# by mistake and one that should have been and was not look identical in a
# slack figure; they do not look identical to `get_property REQUIREMENT`.
#
# MEASURED AT a840c85 PLUS THIS WORK, board flow, both configurations:
#
#                            DDR=1                    DDR=0
#     worst negative slack   -0.446 -> -0.012 ns      -0.054 -> +0.077 ns
#     failing endpoints      86 of 14787 -> 6         1 of 14058 -> 0
#     total negative slack   -12.534 -> -0.074 ns     -0.054 -> 0
#     hold                   +0.040 -> +0.041 ns      +0.084 -> +0.097 ns
#     LUTs                   2136 -> 2177             2072 -> 2005
#     registers              954 -> 957               748 -> 752
#     block RAM tiles        29, unchanged            29, unchanged
#
# **THE BOARD WITH THE MEMORY OFF NOW MEETS TIMING**, and its worst path has
# moved to the phase generator's TPCLK into the control store's write address,
# a family this file has never had to argue about. The board with the memory
# on does not, by twelve picoseconds on six endpoints --- which is inside the
# quarter of a nanosecond CLAUDE.md calls placement noise, so it is reported
# as a number and not as closure.
#
# AND WHAT IS LEFT CANNOT TAKE EITHER REMEDY, which is worth writing down
# before somebody tries. All six are
#
#     -0.012 ns   busint/elapsed_reg[6]/C -> processor/md_reg[*]/CE
#              4.128 ns over five LUTs, no carry chain
#
# and the arc is `elapsed >= SETUP_T` making -XBUS.RQ, the bridge answering it
# combinationally, and `write && answering` making -MEMACK on a write. That
# last gate is the 74S64 at REQLM 0C11 and it is a gate on purpose:
# `cadr_busint_xbus.sv` says so and `memack-registered-on-a-write` is the
# mutation that holds it, because registering it puts the acknowledgement a
# tick late on every write. Holding is refused by the rule and registering is
# refused by the machine.
#
# MEASURED AT 712909e, and the holdings did what they were for. Placed and
# routed out of context by `boards/arty-z7-20/vivado/fit.tcl`: WNS -0.484 ns, 94 failing
# endpoints of 13,444, hold met at +0.061 ns. On the board through
# `boards/arty-z7-20/vivado/bitstream.tcl`, where this file is read scoped: WNS -0.129 ns, 16
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
# `boards/arty-z7-20/vivado/constraints_check.tcl` asserts on: a count of zero at that
# requirement is the `foreach` bug back again, and both flows now stop on it
# before they place anything.
