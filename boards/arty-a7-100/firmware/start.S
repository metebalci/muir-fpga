// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The reset vector, the trap vectors and the few instructions before C.
//
// **WHERE THESE ADDRESSES COME FROM IS IBEX AND NOT A CONVENTION.**  The core
// fetches its first instruction from `{boot_addr_i[31:8], 8'h80}` and
// initializes `mtvec` to `{boot_addr_i[31:8], 6'b0, 2'b01}` --- base zero,
// MODE vectored.  `rtl/plumbing/cadr_soc.sv` gives it `boot_addr_i` = 0, so
// the trap table is the 128 bytes at 0 and the reset address is 0x80, and
// `link.ld` puts the two sections exactly there.  Ibex asserts that the low
// byte of `boot_addr_i` is zero, so neither number is free.
//
// **VECTORED, SO THERE ARE THIRTY-TWO ENTRIES AND NOT ONE.**  In vectored
// mode an exception goes to the base and an interrupt of cause `n` goes to
// `base + 4n`.  Every entry here jumps to one handler, which then reads
// `mcause` to find out what happened: a firmware with one program has nothing
// to dispatch to, and a table of thirty-two different stubs would be
// thirty-two places for the answer to be wrong.  The entries are full-width
// jumps --- `.option norvc` --- because a compressed one would be two bytes
// and the table's stride is four.

	.section .vectors, "ax"
	.option norvc
	.globl _vectors
_vectors:
	.rept 32
	j _trap_entry
	.endr

	.section .text.start, "ax"
	.globl _start
_start:
	// **THE GLOBAL POINTER FIRST, AND LEAVING IT OUT COST AN AFTERNOON.**
	// The compiler puts small globals in `.sdata` and `.sbss` and reaches
	// them at an offset from `gp`, so a `gp` nobody set makes every one of
	// them an address somewhere else entirely.  What that looked like: the
	// firmware's log prefix is such a global, `gp` was zero, the pointer it
	// read was an address in the region the bridge's catch-all answers ---
	// and `cadr_gp0_default.sv` answers EVERY address there with "NONE", so
	// `fputs` walked a string that never reaches a zero byte and the board
	// said NONENONENONE for ever.  **A default slave that answers every
	// address with a word that is not zero turns a wild pointer into an
	// infinite string**, which is the price of the rule that nothing may
	// hang, and it is worth knowing before reading a board that is saying
	// one thing over and over.
	//
	// `norelax` around it because the linker would otherwise relax this very
	// `la` into a `gp`-relative load of `gp`, which cannot work.
.option push
.option norelax
	la	gp, __global_pointer$
.option pop
	// The stack, at the top of the memory and growing down.  `link.ld`
	// puts `__stack_top` there and nothing checks that the stack and the
	// data do not meet: 32 KB against a firmware of a few, and a guard
	// would be a page table this core has not got.
	la	sp, __stack_top
	// `.bss` is not in the hex --- it is `NOLOAD` --- so it is whatever the
	// block RAM came up holding, which on this part is zeros but is not
	// something a program may assume.  Clear it.
	la	t0, __bss_start
	la	t1, __bss_end
1:	bgeu	t0, t1, 2f
	sw	zero, 0(t0)
	addi	t0, t0, 4
	j	1b
2:
	// There is no `.data` to copy: this memory is both the image and the
	// working store, so an initialized variable is already initialized.
	// That is what a firmware in block RAM buys and it is why there is no
	// load-address arithmetic here.
	call	main
	// `main` does not return.  If it does, say nothing and stop --- a
	// firmware that fell off the end and then ran the trap handler would
	// report a fault that never happened.
3:	j	3b

	.globl _trap_entry
_trap_entry:
	// **ONE FAULT MAY BE ASKED FOR, AND THEN THIS RETURNS.**
	// `soc_probe_load` and `soc_probe_store8` below set `soc_fault` before
	// the one instruction that may fault and clear it after.  An exception
	// taken while it is set is recorded, the faulting instruction is stepped
	// over --- it is four bytes, this whole file being `norvc` --- and the
	// core goes on at the instruction after it.  That is what lets a firmware
	// show that a refusal is a refusal: the DDR window answers a byte store
	// with a store access fault, and a handler that could only park would
	// make the one check of it the last thing the firmware ever did.
	//
	// Only an exception, and only while asked.  `mcause` has its top bit set
	// for an interrupt, and nothing in this firmware enables one.  `t1` and
	// `t2` are the probes' own scratch, so the path that returns disturbs
	// nothing a probe's caller holds.
	la	t1, soc_fault
	lw	t2, 0(t1)
	beqz	t2, 5f
	csrr	t2, mcause
	bltz	t2, 5f
	sw	t2, 4(t1)
	sw	zero, 0(t1)
	csrr	t2, mepc
	addi	t2, t2, 4
	csrw	mepc, t2
	mret
5:
	// Nothing is saved on this path.  It does not return: it prints what
	// happened and parks, so the registers it stands on are the last
	// evidence anybody wanted and the stack pointer is the only thing that
	// has to be sound.
	la	sp, __stack_top
	csrr	a0, mcause
	csrr	a1, mepc
	csrr	a2, mtval
	call	soc_trap
4:	j	4b

	.section .text, "ax"

	// uint32_t soc_probe_load(uint32_t addr, uint32_t *cause)
	//
	// One load that may fault.  The word it read, or zero if it faulted, and
	// the fault's `mcause` in `*cause`, zero if there was none.
	.globl soc_probe_load
soc_probe_load:
	la	t1, soc_fault
	sw	zero, 4(t1)
	li	t2, 1
	sw	t2, 0(t1)
	mv	t0, a0
	li	a0, 0
	lw	a0, 0(t0)
	la	t1, soc_fault
	sw	zero, 0(t1)
	lw	t2, 4(t1)
	sw	t2, 0(a1)
	ret

	// void soc_probe_store8(uint32_t addr, uint8_t value, uint32_t *cause)
	//
	// One byte store that may fault, and its `mcause` in `*cause`.
	.globl soc_probe_store8
soc_probe_store8:
	la	t1, soc_fault
	sw	zero, 4(t1)
	li	t2, 1
	sw	t2, 0(t1)
	sb	a1, 0(a0)
	la	t1, soc_fault
	sw	zero, 0(t1)
	lw	t2, 4(t1)
	sw	t2, 0(a2)
	ret

	// uint32_t soc_read_mip(void)
	//
	// The pending interrupts, read without enabling any.  Ibex shows its
	// interrupt inputs in `mip` as they stand, so this is what the wires say.
	.globl soc_read_mip
soc_read_mip:
	csrr	a0, mip
	ret

	// Whether a fault is asked for, and the cause of the one that came.
	.section .bss
	.balign 4
	.globl soc_fault
soc_fault:
	.space 8
