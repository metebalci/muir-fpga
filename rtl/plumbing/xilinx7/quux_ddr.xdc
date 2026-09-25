# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# QUUX's memory port's deadline into its adapter, `quux_axi_master.sv`, read
# after `cadr_ddr.xdc` and only for a QUUX build with `DDR=1`: its objects
# are inside `g_ddr` and are QUUX's, and a clause whose `-to` matches nothing
# is a clause on every path, so the CADR must never read this file.
#
# **ONLY THE PROCESSOR'S DEVICE CYCLE HAS THE BUS'S 80 ns, SO THE CLAUSE IS
# WRITTEN FROM ITS REGISTERS AND NOT TO THE ADAPTER.**  Three kinds of word
# reach the adapter's address and data, and they have different time:
#
#   - The processor's device cycle to MONO TV's frame buffer, passed straight
#     through the Xbus bridge and the port.  Its address `phys_r` and word
#     `wdata` are loaded at the grant, and `memstart`, which selects the live
#     address the map makes in the microcycle before, falls at that same
#     edge.  -XBUS.RQ comes `SETUP_T` ticks after the grant and the adapter
#     takes the word at the first edge it sees it: eight ticks, measured.  So
#     every register of the processor has eight, the live address's whole
#     datapath being behind `memstart` from the grant on; so do the console
#     registers that drive the processor (`spy_registers`, which QUUX loads
#     at the master clock edge) and MONO TV's held decode `fb`, which the
#     bridge's select is.
#   - The port's own cache operations (line fills, the write buffer's
#     drain): registers of the port loaded on the tick before the adapter
#     takes them.  One tick, which is the default.
#   - A block-disk transfer word, passed through like the processor's but
#     NOT with its time.  The channel loads its address, word and request at
#     one edge; `ch_own` takes the bus a tick later, the arbiter's idle tick
#     (`owner_d`) another, and the adapter takes the word at the next: three
#     ticks from the channel's registers, two from `ch_own`, one from
#     `owner_d`.  So the channel, the arbiter, the bridge and the adapter's
#     own state keep the one tick they have, which is the default.
#
# A clause written `-to` the adapter, with the port's registers written back
# to a tick after it, gave the channel's words eight ticks where they have
# one to three.  This one names its sources, so anything not named keeps a
# tick, and `bitstream.tcl` asserts the channel's paths ask for one.
# grid: 80 ns
# The strobes and the half a word read is taken from are the address's own
# bit 2, and are good when it is.
set qcontract [get_pins -quiet {g_ddr.g_qaxi.u_qaxi/m_awaddr_reg[*]/D \
                                g_ddr.g_qaxi.u_qaxi/m_araddr_reg[*]/D \
                                g_ddr.g_qaxi.u_qaxi/m_wdata_reg[*]/D \
                                g_ddr.g_qaxi.u_qaxi/m_wstrb_reg[*]/D \
                                g_ddr.g_qaxi.u_qaxi/half_reg/D}]
set qcycle [filter [all_registers] {NAME =~ u_machine/processor/* || \
                                    NAME =~ u_machine/memory/spy_registers/* || \
                                    NAME =~ u_machine/memory/g_quux_mono_tv.mono_tv/fb_reg*}]
set_multicycle_path -setup 8 -from $qcycle -to $qcontract
set_multicycle_path -hold  7 -from $qcycle -to $qcontract
