/* SPDX-FileCopyrightText: 2026 Mete Balci
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * One memory, and the two addresses Ibex decides.
 *
 * `rtl/plumbing/cadr_soc_ram.sv` is a single block RAM holding the firmware's
 * text, its constants and its variables, with the image already in it when
 * the part configures.  So there is no flash, no load address different from
 * the run address, and nothing for a start-up routine to copy.
 *
 * `.vectors` at 0 and `.text` at 0x80 are Ibex's: the core resets to
 * `boot_addr + 0x80` and vectors its traps at `boot_addr`, and `cadr_soc.sv`
 * gives it `boot_addr` = 0.  `start.S`'s header has the citation.
 *
 * LENGTH must match `RAM_WORDS` in the fabric.  It is stated in both places
 * and nothing checks that the two agree --- a firmware too big for the memory
 * links happily and then runs off the end of the hex, where `$readmemh` has
 * left whatever the RAM came up with.  What catches it is the build rule,
 * which refuses a hex longer than the memory, and `tb/cadr_soc_tb.cpp`, which
 * runs the firmware the fabric was built with.
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  ram (rwx) : ORIGIN = 0x00000000, LENGTH = 32K
}

SECTIONS
{
  .vectors 0x00000000 : { KEEP(*(.vectors)) } > ram

  .text 0x00000080 :
  {
    KEEP(*(.text.start))
    *(.text .text.*)
  } > ram

  .rodata : ALIGN(4) { *(.rodata .rodata.*) *(.srodata .srodata.*) } > ram

  .data : ALIGN(4)
  {
    __global_pointer$ = . + 0x800;
    *(.data .data.*)
    *(.sdata .sdata.*)
  } > ram

  .bss (NOLOAD) : ALIGN(4)
  {
    __bss_start = .;
    *(.bss .bss.*)
    *(.sbss .sbss.*)
    *(COMMON)
    . = ALIGN(4);
    __bss_end = .;
  } > ram

  __heap_start = .;
  __stack_top = ORIGIN(ram) + LENGTH(ram);

  /DISCARD/ : { *(.eh_frame*) *(.comment) *(.riscv.attributes) }
}
