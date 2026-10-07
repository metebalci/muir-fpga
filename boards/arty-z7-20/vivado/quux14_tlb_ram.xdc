# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# QUUX revision 14's TLB in block RAM on the Arty Z7-20 (contract G3 revision
# 14, §5.4): the primitive is chosen here, outside `rtl/machine/`, and read
# by `bitstream.tcl` before synthesis at `REVISION=14` only.  M2 measured
# five RAMB36E1, 4K x 9 each, true dual port; `tlb_check.tcl` asks the
# synthesized netlist which cells it made.
set_property RAM_STYLE BLOCK [get_cells -hierarchical -filter {NAME =~ *g_rev14_mmu.mmu/tlb/tlb_mem_reg}]
