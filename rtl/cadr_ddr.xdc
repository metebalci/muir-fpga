# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The memory port's deadline: the 80 ns the bus gives the address, and the one
# tick it does not give the request.
#
# READ ONLY BY THE `DDR=1` BOARD, on `rtl/cadr_probe.xdc`'s precedent. Every
# object it names is inside `g_ddr`, which exists only when
# `rtl/cadr_arty.sv`'s `DDR` parameter is set; read against the default board
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
# `main_byte_address`, into the AXI address register. Measured at 1d3a9bc.
# The fold was doing its job and could never have timed it.
#
# AND THE DEADLINE IS 80 ns, WRITTEN DOWN, NOT CHOSEN. `rtl/cadr_xbus_ddr.sv`
# quotes the bus specification: "it is the responsibility of the bus master to
# assert good address, write, and data lines 80 ns. prior to asserting
# -XBUS.RQ". `cadr_busint_xbus.sv` implements that as `SETUP_T = 80 / 5`,
# sixteen ticks between the grant and the request, and the trace holds it tick
# for tick against muir. The address register is loaded at the first edge that
# sees `mem_req`, which is `SETUP_T` ticks after the address settled, so
# sixteen ticks is the machine's own construction and not an indulgence.
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
# `SETUP_T` fifteen ticks where this claims sixteen, and `busint_xbus` catches
# it at tick 56 of the trace, on the first cycle --- a request a tick early is
# an acknowledgement a tick early, so `-MEMACK` and `-LOADMD` both disagree
# with muir. That record's note now says it holds this file as well as the
# fabric, because nothing else about it would show that.
#
# WHY THE PINS AND NOT THE PORTS, AND NOT THE CELLS.
#
#   - Not the ports. `rtl/cadr_machine.xdc` is read `-ref cadr_machine` on the
#     board, and a scoped file cannot name what is outside its module:
#     `-through [get_ports {mem_addr[*] ...}]` there is "No valid object(s)
#     found", twice, and `report_exceptions` counts two where there should be
#     four. Measured. Nor can this file reach them from outside ---
#     `get_pins u_machine/mem_addr[*]` and `u_machine/mem_wdata[*]` are both
#     empty on the synthesised board, the buses having been dissolved. Only
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
# synthesised board `m_axi_awaddr_reg[2]` is an FDRE with a real `CE`, driven
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
# ns, and `vivado/bitstream.tcl` asserts that count is not zero the way it
# does for the machine's own fifteen.
#
# WHAT IS NOT RELAXED AND ARGUABLY COULD BE: `mem_write`. The bus rule names
# it beside the address and the data --- "good address, write, and data
# lines" --- so it has the same 80 ns by the same sentence. It is left at one
# tick because it cannot be separated: it is read by the adapter's state
# register, and so is `mem_req`, and both arrive at the same `D` pin. An
# exception written for one would relax the other. A tighter constraint than
# the rule requires is the safe direction to be wrong in, and it is written
# here rather than discovered later.
set contract [get_pins -quiet {g_ddr.u_axi/m_axi_awaddr_reg[*]/D \
                               g_ddr.u_axi/m_axi_araddr_reg[*]/D \
                               g_ddr.u_axi/m_axi_wdata_reg[*]/D}]
set_multicycle_path -setup 16 -to $contract
set_multicycle_path -hold  15 -to $contract
