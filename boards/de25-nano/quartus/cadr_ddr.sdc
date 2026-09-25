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
set ddr_contract [get_pins -nowarn {u_memory|u_axi|m_axi_awaddr[*]|d
                                u_memory|u_axi|m_axi_araddr[*]|d
                                u_memory|u_axi|m_axi_wdata[*]|d}]
# Only where it names something: QUUX's build removes the CADR's adapter.
if {[get_collection_size $ddr_contract] > 0} {
    # grid: 80 ns
    set_multicycle_path -setup 8 -to $ddr_contract
    set_multicycle_path -hold  7 -to $ddr_contract
}

# **AND QUUX'S ADAPTER**, `quux_axi_master.sv`, written FROM the processor's
# registers rather than to the adapter, because only the processor's device
# cycle has the bus's 80 ns.  Its address and word are loaded at the grant
# and `memstart`, which selects the map's live address, falls there; the
# adapter takes them `SETUP_T` ticks later, eight, measured.  So every
# register of the processor has eight, with the console registers that
# drive it and MONO TV's held decode `fb`, which is the bridge's select.
# What else reaches the adapter keeps the tick it has, the default: the
# port's cache operations, registers of the port loaded a tick before the
# adapter takes them, and a block-disk transfer word, which the channel
# loads three ticks, `ch_own` two and the arbiter's idle tick one before the
# adapter takes it.  An exception written to the adapter gave those eight.
# `rtl/plumbing/xilinx7/quux_ddr.xdc` is the same clause.  Nothing on the
# CADR, which has not got the adapter.
set qddr_contract [get_pins -nowarn {u_memory|u_qaxi|m_awaddr[*]|d
                                     u_memory|u_qaxi|m_araddr[*]|d
                                     u_memory|u_qaxi|m_wdata[*]|d
                                     u_memory|u_qaxi|m_wstrb[*]|d
                                     u_memory|u_qaxi|half|d}]
set qddr_cycle [get_registers -nowarn {u_machine|processor|*
                                       u_machine|memory|spy_registers|*
                                       u_machine|memory|g_quux_mono_tv.mono_tv|fb}]
set qddr_port [get_registers -nowarn {u_machine|memory|g_quux_port.port|*}]
if {[get_collection_size $qddr_contract] > 0} {
    # grid: 80 ns
    set_multicycle_path -setup 8 -from $qddr_cycle -to $qddr_contract
    set_multicycle_path -hold  7 -from $qddr_cycle -to $qddr_contract
}

# ------------------------------------------ the debug cable's carrier latch
#
# **THE WORD THE DEBUGGEE DRIVES IS NOT A ONE-TICK SIGNAL, AND WHERE THE
# CARRIER LATCHES IT IS OUTSIDE THE MACHINE.**  This is
# `rtl/plumbing/xilinx7/cadr_debug.xdc`'s one clause written again, with the
# same register, the same count and the same split, because it is the same
# path in the same two modules; that file has the whole argument and what
# follows is what makes it this board's.
#
# MEASURED HERE, on the first fit with the faces attached: worst setup
# **-1.542 ns** at the slow corner at 0 C, on
#
#     u_machine|processor|md[13] -> u_debug_window|sts_dbd[0]
#     11.825 ns of data delay, requirement 10.000 ns
#
# which is `MD` through the processor's sixteen-way diagnostic mux, the
# register block, the arbiter and MIT's DBGIN page, out of `cadr_machine` on
# `DBD<15:0>` and into the carrier's latch.  The Zynq boards' worst on the
# same arc was -8.772 ns before their clause; this part is kinder to it and
# still does not close it at one tick.
#
# **THE DEADLINE IS THE CABLE'S OWN AND IS NOT CHOSEN HERE.**  A debug cycle
# is answered by the diagnostic register block `busint::DIAGNOSTIC_NS` = 250 ns
# after `-UB MSYN`, twenty-five ticks, and the address that selects the word is
# a latched register that has not moved since the previous request was lifted.
# So by the tick `DEBUG IN ACK` rises and this register captures, the word has
# had twenty-five ticks to settle.  Six is a floor with four times margin, and
# it is six rather than two because one number covers this latch and the Pmod
# carrier's frame register on the Zynq boards, neither written to its own
# convenience.  Twenty-five is what this latch alone could claim and is not
# claimed.
#
# **THE `|d` PINS AND NOT THE REGISTERS**, which is the split every clause in
# this file makes: this register's clock enable is
# `dbg_in_req && dbg_in_ack && !sts_ack`, the acknowledgment, which is the
# signal that says the word is good and the one thing that must not be
# relaxed.  And `sts_dbd` alone of the carrier: `sts_ack` is a constant,
# `sts_drv` is two levels deep, and the watchdog and the lead are counters
# that must keep their tick.  `sta_check.tcl` asserts exactly that split, so a
# clause that reached nothing is a failure and not a plausible number.
#
# WHAT IT DOES NOT EXCUSE.  The 74LS244s drive `SPY<15:0>` asynchronously, so
# a running machine moves the lines under a standing acknowledgment; a word a
# tick or two stale on a running machine is already this bus's semantics, and
# CC halts the debuggee before it does anything else.  A two-tick arrival
# inside a twenty-five-tick window is invisible to it.
# grid: 60 ns
set cable_word [get_pins -nowarn {u_debug_window|sts_dbd[*]|d}]
set_multicycle_path -setup 6 -to $cable_word
set_multicycle_path -hold  5 -to $cable_word

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
