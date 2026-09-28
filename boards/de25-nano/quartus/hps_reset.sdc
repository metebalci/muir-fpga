# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The DE25-Nano's processor system's own reset synchronizers, for every build
# that has the processor system in it: the memory board, `DDR=1`, and the
# fault bitstream, `FAULT=1`.  `project.tcl` reads this file for both, beside
# `cadr_ddr.sdc` on the one and `cadr_de25_fault.sdc` on the other, because
# both carry the same generated processor system, `cadr_de25_hps`, with the
# same three bridges, and so the same three synchronizers.
#
# **THREE TWO-REGISTER RESET SYNCHRONIZERS INSIDE THE GENERATED PROCESSOR
# SYSTEM**, one for each bridge's ready-latency adapter: `hps2fpga_...`,
# `lwhps2fpga_...` and the FPGA-to-SDRAM port's `hps_ready_latency_adp_...`.
# They are Altera's `ready_latency_reset_synchronizer`, which the HPS IP
# instantiates by itself, and `boards/de25-nano/cadr_de25.sv` and
# `boards/de25-nano/cadr_de25_fault.sv` give each bridge `h2f_reset` as its
# reset, as the IP's header asks.  Each register is cleared asynchronously by
# the processor's reset output `s2f_rst`, which the timing analyzer launches
# from `hps_internal_osc`, and is clocked by the machine's clock out of the
# I/O PLL.  The two clocks are unrelated, so the analyzer's recovery and
# removal checks on those six clears compare edges that have no fixed
# relation: measured on both fits at `3dad80b`, six endpoints failed removal
# by up to 0.672 ns with 3.98 ns of skew between the two clocks.
#
# **WHAT ALTERA SAYS.**  The synchronizer's own source, generated from the
# Quartus installation's `ip/altera/intel_hps/sm/ready_latency/`, calls its
# input "an asynchronous, active high reset input", asserts it
# asynchronously and releases it through the two registers: release is the
# edge a synchronizer exists to take, and the second register holds its
# output until the first has settled.  The IP's generated constraints
# (`intel_hps_sundancemesa.sdc`) name neither the synchronizers nor `s2f_rst`.
# Altera's general reset synchronizer, `altera_reset_synchronizer`, which the
# same processor system's memory controller also carries, says why the cut
# goes where it does: "Instead of cutting the timing path to the d-input on
# the first flop we need to cut the aclr input", and its
# `altera_reset_controller.sdc` does exactly that, a false path to the
# chain's `clrn` pins.  And AN 917 (document 683539), section 1.3.1.1,
# "Adding SDC Constraints to Asynchronous Reset Circuitry", constrains a
# reset synchronizer's asynchronous input with a false path, which is what
# the Design Assistant's rule RES-50003 asks for.
#
# **SO THE CUT IS THOSE SIX `clrn` PINS, AND ONLY FROM `s2f_rst`.**  Not a
# clock group between the two clocks, which would also hide any other
# crossing between them; and through the processor's reset output, so that a
# clear driven from the fabric's own logic into the same pins would still be
# timed.  Not `-from [get_clocks hps_internal_osc]`: this file is read before
# the processor system's generated one, which is what creates that clock.
# The two registers' data paths keep their tick.  `sta_common.tcl`'s
# `sta_hps_reset_sync`, which `sta_check.tcl` and `fault_sta.tcl` both call,
# asserts that the collections hold six pins and one, and that no recovery or
# removal path ends at those pins.
set hps_rst_clrn [get_pins -nowarn {u_hps|hps|hps|sm_hps|hps2fpga_axi4_rl_adp_inst_reset_sync|sync_reg[*]|clrn
                                    u_hps|hps|hps|sm_hps|lwhps2fpga_axi4_rl_adp_inst_reset_sync|sync_reg[*]|clrn
                                    u_hps|hps|hps|sm_mpfe|hps_ready_latency_adp_axi4_reset_sync|sync_reg[*]|clrn}]
set hps_s2f_rst [get_pins -nowarn {u_hps|hps|hps|sm_hps|sundancemesa_hps_inst|s2f_rst}]
if {[get_collection_size $hps_rst_clrn] > 0 && [get_collection_size $hps_s2f_rst] > 0} {
    set_false_path -through $hps_s2f_rst -to $hps_rst_clrn
}
