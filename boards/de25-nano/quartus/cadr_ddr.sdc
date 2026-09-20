# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The DE25-Nano's memory board, `DDR=1`: the memory port's deadline, and the
# processor's asynchronous inputs to the fabric.
#
# **READ ONLY BY THE MEMORY BOARD**, as `cadr_probe.sdc` is read only by the
# probe's.  Everything it names is under `u_memory`, which exists only when
# `boards/de25-nano/cadr_de25.sv` is built with `CADR_DE25_DDR`, and a
# constraint on something that is not in the design is a warning that reads
# like a constraint that applied.  `sta_check.tcl` counts what each clause
# reaches.
#
# The processor system's own constraints are its generated files', which
# Quartus reads with the IP.  The three bridges' fabric sides are clocked by
# the machine's 100 MHz, so every path between them and this design is an
# ordinary path at the tick, and nothing here relaxes one.
#
# ------------------------------------------------ the memory port's deadline
#
# **THE ADAPTER'S ADDRESS AND DATA REGISTERS ARE GIVEN THE BUS'S 80 ns**, which
# is `rtl/plumbing/xilinx7/cadr_ddr.xdc`'s one clause written again, with the
# same registers and the same count.  That file has the argument: the
# address and data the machine hands `cadr_xbus_ddr.sv` are good 80 ns before
# `-XBUS.RQ` rises, by the bus specification and by `cadr_busint_xbus.sv`'s
# `SETUP_T`, and the adapter loads them at the first edge that sees the
# request, so the path into those three registers has eight ticks and the
# request itself keeps one.  The `|d` pins and not the registers, so that the
# clock enables keep their tick.
# grid: 80 ns
set ddr_contract [get_pins -nowarn {u_memory|u_axi|m_axi_awaddr[*]|d
                                u_memory|u_axi|m_axi_araddr[*]|d
                                u_memory|u_axi|m_axi_wdata[*]|d}]
set_multicycle_path -setup 8 -to $ddr_contract
set_multicycle_path -hold  7 -to $ddr_contract

# ------------------------------------------- the processor's asynchronous bits
#
# `h2f_reset`, `h2f_gp_out[1:0]` and the warm-reset handshake's request leave
# the processor with no relation to the fabric's clock that this design may
# rely on, and each enters through three registers in
# `cadr_f2sdram_gate.sv` or `cadr_f2sdram_port.sv`.  The first of each is cut
# from whatever the timing analyzer thinks drives it; the other two are timed
# as they are.  So are the default slaves' reset synchronizer's.
set ddr_crossing [get_registers -nowarn {u_memory|u_gate|rst_s[0] u_memory|u_gate|open_s[0]
                                     u_memory|u_gate|req_s[0] u_memory|half_s[0]
                                     h2f_rst_s[0]}]
set_false_path -to $ddr_crossing

# **AND THE TWO THAT GO THE OTHER WAY**, which the processor samples on a clock
# of its own: the warm-reset handshake's acknowledgment and the tally on
# `h2f_gp_in`.  Both are registers of the machine's clock feeding the
# processor's hard block, and the timing analyzer times them against
# `hps_internal_osc`, the processor's 200 MHz internal oscillator, as though
# the two clocks were related.  They are not: the machine's comes from the
# board's crystal through the I/O PLL.  Measured on the first memory board
# build, that pair was the whole critical path: the acknowledgment's register
# to the processor's input, zero logic levels, 0.795 ns of data delay against
# 3.953 ns of clock skew between two unrelated clocks.
#
# NEITHER NEEDS THE PROCESSOR TO SAMPLE IT ON ANY PARTICULAR EDGE.  The
# acknowledgment is a level the processor's reset manager polls, for up to
# 300 ms; Altera's own reference design drives it combinationally from the
# request.  The tally is four counters that stand still for good once a
# program has run --- the boot PROM asks 512 times and never again --- and
# software reads it long afterwards, which is the same thing the Zynq boards'
# EMIO tally relies on.
set ddr_to_hps [get_registers -nowarn {u_memory|u_gate|ack_n u_memory|gp_in[*]}]
set_false_path -from $ddr_to_hps
