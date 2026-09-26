# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The memory port's deadline: the 80 ns the bus gives the address, and the one
# tick it does not give the request.
#
# READ ONLY BY THE `DDR=1` BOARD, on `boards/arty-z7-20/cadr_probe.xdc`'s precedent. Every
# object it names is inside `g_ddr`, which exists only when
# `boards/arty-z7-20/cadr_arty.sv`'s `DDR` parameter is set; read against the default board
# it would be four critical warnings about objects that are not there, and a
# critical warning that means nothing is how a constraint that means nothing
# goes unnoticed.
#
# WHY THERE IS A DEADLINE HERE AT ALL. Until `cadr_arty.sv` grew a `DDR` arm,
# `mem_addr` and `mem_wdata` left `cadr_machine` and went nowhere but the
# `witness` fold --- and `witness_reg` carries a `set_false_path`. So **every
# fit and every bitstream this project has measured was silent about them**.
# Compose the obvious thing and the design comes out at -3.932 ns on 747
# endpoints of 14,787, worst path
# `processor/memstart_reg/C -> u_axi/m_axi_awaddr_reg[18]/D`, 8.802 ns over
# ten logic levels: `memstart` through the level-1 map, through
# `main_byte_address`, into the AXI address register. Measured at 499d7f2.
# The fold was doing its job and could never have timed it.
#
# AND THE DEADLINE IS 80 ns, WRITTEN DOWN, NOT CHOSEN. `rtl/plumbing/cadr_xbus_ddr.sv`
# quotes the bus specification: "it is the responsibility of the bus master to
# assert good address, write, and data lines 80 ns. prior to asserting
# -XBUS.RQ". `cadr_busint_xbus.sv` implements that as `SETUP_T =
# cadr_tick_pkg::ticks(80)`, eight ticks between the grant and the request at
# the 10 ns grid, and the trace holds it tick for tick against muir. The
# address register is loaded at the first edge that sees `mem_req`, which is
# `SETUP_T` ticks after the address settled, so that count is the machine's
# own construction and not an indulgence.
#
# `mem_req` IS NOT RELAXED, WHICH IS THE POINT OF THE SPLIT. It is -XBUS.RQ:
# the signal the other lines are early *for*, the one that arrives last and
# says they are good. It is captured by the adapter's state register and its
# `aw_sent`/`w_sent` flags, none of which is named below, so it keeps the one
# tick it has always had.
#
# HOW THIS IS KEPT FROM BEING TOO WIDE, because an exemption that is too wide
# tests nothing and looks exactly like one that is right. Not by mutating a
# constraint --- a mutation cannot reach one, and trying asks a two-level
# question. By a mutation of the DESIGN just outside the bound, and
# `mutations/list.txt` already had one: `the-setup-time-is-short` makes
# `SETUP_T` a tick short of what this claims, and `busint_xbus` catches
# it at tick 56 of the trace, on the first cycle --- a request a tick early is
# an acknowledgment a tick early, so `-MEMACK` and `-LOADMD` both disagree
# with muir. That record's note now says it holds this file as well as the
# fabric, because nothing else about it would show that.
#
# WHY THE PINS AND NOT THE PORTS, AND NOT THE CELLS.
#
#   - Not the ports. `rtl/plumbing/xilinx7/cadr_machine.xdc` is read `-ref cadr_machine` on the
#     board, and a scoped file cannot name what is outside its module:
#     `-through [get_ports {mem_addr[*] ...}]` there is "No valid object(s)
#     found", twice, and `report_exceptions` counts two where there should be
#     four. Measured. Nor can this file reach them from outside ---
#     `get_pins u_machine/mem_addr[*]` and `u_machine/mem_wdata[*]` are both
#     empty on the synthesized board, the buses having been dissolved. Only
#     `u_machine/mem_write` survives, alone.
#
#   - The `/D` pins and not the cells. `-to [get_cells ...]` is every input
#     pin of the register, `CE` among them, and what drives `CE` is the state
#     machine looking at `mem_req`. Relaxing the cell would relax the request
#     along with the address, which is exactly the thing this file refuses to
#     do. `/D` is the data pin and the data is the address.
#
# AND THAT SPLIT IS MEASURED, not assumed, because it depends on how synthesis
# chose to build the register and could have gone the other way. On the
# synthesized board `m_axi_awaddr_reg[2]` is an FDRE with a real `CE`, driven
# by `g_ddr.u_axi/E[0]` --- the state machine --- and the whole fanin cone of
# its `D` pin is three startpoints:
#
#     u_machine/processor/phys_r_reg[0]/C
#     u_machine/processor/memstart_reg/C
#     u_machine/processor/vma_reg[0]/C
#
# all of them the machine's datapath, none of them the request. Had the load
# been built as a mux in the `D` LUT instead, `mem_req` would have been in
# that cone and this exception would have relaxed it silently. The two
# `set_multicycle_path` calls below reach 76 setup paths of 14,754 at 80.000
# ns, and `boards/arty-z7-20/vivado/bitstream.tcl` asserts that count is not zero the way it
# does for the machine's own relaxed set.
#
# WHAT IS NOT RELAXED AND ARGUABLY COULD BE: `mem_write`. The bus rule names
# it beside the address and the data --- "good address, write, and data
# lines" --- so it has the same 80 ns by the same sentence. It is left at one
# tick because it cannot be separated: it is read by the adapter's state
# register, and so is `mem_req`, and both arrive at the same `D` pin. An
# exception written for one would relax the other. A tighter constraint than
# the rule requires is the safe direction to be wrong in, and it is written
# here rather than discovered later.
#
# **AND ONLY THE PROCESSOR'S CYCLE HAS THE 80 ns, SO THE CLAUSE IS WRITTEN
# FROM ITS REGISTERS.**  Two other masters reach the adapter through the same
# bridge since the cone above was measured: the disk controller's channel and
# the Unibus map's window, `cadr_memory_path.sv`'s arbiter handing each the
# bus.  Neither is the bus master the 80 ns sentence is about, and neither
# waits for it.  Each loads its address, word and request at one edge; the
# arbiter's owner flag (`ch_own`, `mp_own`) follows a tick later, its idle
# tick (`owner_d`) another, and the adapter takes the word at the next.
# Measured with instrumented copies of the machine's and the Unibus's
# testbenches, timing every take: three ticks from the master's registers,
# two from the owner flag, one from the idle tick, for 1,632 channel words
# in the machine and the six mapped cycles of `build/unibus.pass` that reach
# main memory.  A clause written `-to` the adapter gave them all
# eight.  So the eight go to the processor's registers, whose address and
# word are loaded at the grant with `memstart` falling there (every
# processor take of the boot trace: `phys_r` and `memstart` exactly eight
# ticks, the word at least eight), to the console registers that drive the
# processor, and to the display boards' held decode `fb`, which is the
# bridge's display select and stands from before the grant.  Everything else
# keeps its tick: the channel, the map's window, the arbiter, and the bus
# interface's own state, which the fanin now reaches.  The fanin of the
# three registers' `D` pins, measured on the synthesized board: the
# processor's datapath, `spy_registers`, both displays' `fb`, the channel's
# `ch_addr_r` and `ch_wdata_r`, the map window's address and word in
# `busint_regs`, `ch_own`, `mp_own` and the bus interface's state.  The flows
# assert that the channel, the map's window and the arbiter ask for one tick.
#
# `cadr_tick_pkg::ticks(80)`: eight at a 10 ns grid.
# grid: 80 ns
set contract [get_pins -quiet {g_ddr.u_axi/m_axi_awaddr_reg[*]/D \
                               g_ddr.u_axi/m_axi_araddr_reg[*]/D \
                               g_ddr.u_axi/m_axi_wdata_reg[*]/D}]
set cycle [filter [all_registers] {NAME =~ u_machine/processor/* || \
                                   NAME =~ u_machine/memory/spy_registers/* || \
                                   NAME =~ u_machine/memory/tv/fb_reg* || \
                                   NAME =~ u_machine/memory/g_color_tv.tv_color/fb_reg*}]
set_multicycle_path -setup 8 -from $cycle -to $contract
set_multicycle_path -hold  7 -from $cycle -to $contract
