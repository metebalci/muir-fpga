<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# The interrupt handler, and the register every implementation must answer

This document is for anyone writing a CADR emulator or a second
implementation. It is about one Unibus register and what MIT's microcode
does with it. Getting this wrong does not produce an error. It produces a
machine that runs for a long time and then stops somewhere unrelated.

Everything here is read out of MIT's own sources in the System 100 release,
under `sys/ucadr/`. The line references are to that release.

## What the handler does first

`INTR` in `uc-interrupt.lisp` is where every interrupt arrives. Its first
acts are to save the address and data registers, because the interrupted
program owns them, and then to read one register:

```
INTR	(CALL-IF-BIT-SET M-INTERRUPT-FLAG ILLOP);Recursive interrupt!
	((A-INTR-VMA) VMA)			;Mustn't bash the VMA
	((A-INTR-MD) MD)			; nor the MD
	((M-INTERRUPT-FLAG) DPB (M-CONSTANT -1) A-FLAGS) ;No page faults allowed here
	((VMA-START-READ) (A-CONSTANT 77773020)) ;Unibus address 766040 (interrupt status)
	(CHECK-PAGE-READ-NO-INTERRUPT)
```

Virtual address `77773020` is Unibus `766040`, the bus interface's own
interrupt status register. The handler classifies every interrupt by what it
reads there.

## The bit that decides everything

Two instructions later the handler branches on bit 1:

```
	((A-INTR-LOCAL-UNIBUS-MODE) (BYTE-FIELD 1 1) MD)
	(JUMP-EQUAL A-INTR-LOCAL-UNIBUS-MODE M-ZERO INNL0)  ;jump on no local-enable, ie,
						; PDP11 arbritrating UNIBUS.
	(JUMP-IF-BIT-CLEAR (BYTE-FIELD 1 15.) MD INTRX0) ;If not Unibus, go check for XBUS
```

Bit 1 is `LOCAL-ENABLE`. MIT's own comment says what a zero means. The
machine concludes that a PDP-11 is arbitrating its Unibus, and takes a
different path through the whole handler.

**`LOCAL-ENABLE` is a jumper and not a software setting.** No microcode
anywhere writes it. It is strapped on a real board, so it comes up set, and
muir models it that way: `Machine::new` initialises the register to
`LOCAL_ENABLE` and nothing clears it.

So an implementation that does not answer `766040` gives the handler a zero.
The machine then believes it is a slave to a front-end processor that does
not exist, on every interrupt it ever takes.

## What the register holds

The bits an implementation has to get right, with muir's names for them from
`src/busint.rs`:

| bit | octal | name | what it is |
|---|---|---|---|
| 1 | `0o2` | `LOCAL_ENABLE` | the jumper, set on a board that arbitrates its own Unibus |
| 10 | `0o2000` | `ENABLE_UB_INTS` | Unibus interrupts are delivered only while this is set |
| 14 | `0o40000` | `XBUS_INTR` | a live wire, the Xbus interrupt as it stands now |
| 15 | `0o100000` | `UB_INT` | a Unibus interrupt has been taken |
| 2 to 9 | `0o1774` | `VECTOR_MASK` | the vector of the interrupt taken |

The vector field does not read back unless `UB_INT` is set, because the
74LS374 at UBINTC 0D17 is enabled by it. An implementation that returns the
stored vector unconditionally is wrong in a way nothing will tell it.

## The two other places the boot path touches these registers

The cold boot writes the register to turn Unibus interrupts on, in
`uc-cold-disk.lisp` at `BEG06`:

```
	((MD) (A-CONSTANT 6000))		;Enable Unibus interrupts
	((VMA-START-WRITE) (A-CONSTANT 77773020))  ;Unibus address 766040
```

Octal `6000` is bits 11 and 10, and bit 10 is `ENABLE_UB_INTS`. An
implementation that drops this write will deliver no Unibus interrupt at all,
however correctly it models the devices.

The cold boot also writes the error status register at Unibus `766044`, twice,
to clear the bus error indicators. It does that once at the very start and
once more before reading the label.

## What happens when you get it wrong

On this project's board the three register groups at `766040`, `766044` and
the Unibus map were not built. Every read of them timed out, and an
unanswered read gives zero here. The measured result:

| | without the registers | with them |
|---|---|---|
| state | halted, error flag up | running, error flag down |
| microcycles reached | 169,107,829, every run | past 2,425,000,000 |
| screen | the run bar only | the window system and a Lisp Listener |

The machine halted in the page fault handler with a word of the page hash
table holding a virtual address where a table word belonged. That is a long
way from the interrupt handler, and it took a night to work back from.

**The exact failure path is not proven and this document will not invent
one.** What is established is the branch above, that the machine takes it on a
zero, and that answering these registers is the difference between halting and
booting. `INND0` does have a route back to `INTRX0` when the Unibus channel
list runs out, so the wrong branch is not a dead end in the source, and
whatever went wrong on the board went wrong somewhere along the longer path.

## The lesson for an implementation

A missing Unibus slave is silent. The bus times out, the read gives a value,
and the microcode carries on with it. Nothing anywhere reports that the
machine just classified an interrupt using a register that does not exist.

So the check worth having is not a test of the interrupt handler. It is a
comparison of which addresses your implementation answers against which
addresses a reference answers, in both directions, over the whole address
space. This project's own check prints that list, and it had been naming these
exact registers on every run for days before anybody acted on it.
