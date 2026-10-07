# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# QUUX revision 14's TLB in UltraRAM on the Kria KR260 (contract G3 revision
# 14, §5.4): one URAM288, chosen here, outside `rtl/machine/`, and read by
# `bitstream.tcl` before synthesis at `REVISION=14` only.  UltraRAM refuses
# WRITE_FIRST, and Vivado then builds block RAM in its place without
# failing (A14.15), which is why `quux_tlb.sv` writes both ports NO_CHANGE;
# `boards/arty-z7-20/vivado/tlb_check.tcl` asks the synthesized netlist
# which cells it made.
set_property RAM_STYLE ULTRA [get_cells -hierarchical -filter {NAME =~ *g_rev14_mmu.mmu/tlb/tlb_mem_reg}]
