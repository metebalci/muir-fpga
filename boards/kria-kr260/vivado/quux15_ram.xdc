# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Revision 15's memories on the Kria KR260 (contract G3 revision 15,
# A15b.4, A15b.6): the control store and the cache's lines in UltraRAM, the
# store's not cascaded; the TLB in block RAM.  Chosen here and not in
# `rtl/machine/`, which infers each RAM the same way on every board.
set_property RAM_STYLE ULTRA [get_cells -hier -filter {NAME =~ *u_core/store/ram/mem_reg*}]
set_property CASCADE_HEIGHT 1 [get_cells -hier -filter {NAME =~ *u_core/store/ram/mem_reg*}]
set_property RAM_STYLE ULTRA [get_cells -hier -filter {NAME =~ *u_core/port/lines0/mem_reg* || NAME =~ *u_core/port/lines1/mem_reg*}]
set_property RAM_STYLE BLOCK [get_cells -hier -filter {NAME =~ *u_core/mmu/tlb_a/mem_reg* || NAME =~ *u_core/mmu/tlb_b/mem_reg*}]
