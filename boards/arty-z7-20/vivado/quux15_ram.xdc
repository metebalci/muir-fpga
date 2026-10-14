# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Revision 15's memories on the Arty Z7-20 (contract G3 revision 15,
# A15b.4, A15b.6): the control store, the cache's lines and the TLB in block
# RAM, where the Kria KR260 puts the first two in UltraRAM, which this part
# has not got (`boards/kria-kr260/vivado/quux15_ram.xdc`).  Chosen here and
# not in `rtl/machine/`, which infers each RAM the same way on every board;
# `quux15_bitstream.tcl` asks after synthesis that each landed there.
set_property RAM_STYLE BLOCK [get_cells -hier -filter {NAME =~ *u_core/store/ram/mem_reg*}]
set_property RAM_STYLE BLOCK [get_cells -hier -filter {NAME =~ *u_core/port/lines0/mem_reg* || NAME =~ *u_core/port/lines1/mem_reg*}]
set_property RAM_STYLE BLOCK [get_cells -hier -filter {NAME =~ *u_core/mmu/tlb_a/mem_reg* || NAME =~ *u_core/mmu/tlb_b/mem_reg*}]
