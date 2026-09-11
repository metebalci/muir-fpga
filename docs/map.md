<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# The map, and the check that stands behind the board's halt

The CADR's virtual memory map is two levels of asynchronous RAM inside
`rtl/machine/cadr_microcycle.sv`. The first level is 2,048 five-bit entries
addressed by `VMA<23:13>`, and the second is 1,024 twenty-four-bit entries
addressed by `{VMAP<4:0>, VMA<12:8>}`. A lookup is a ripple through both inside
one microcycle. The top two bits of the second-level word are the access code,
and the fourteen bits under them are the physical page. `-LVMO23` becomes
`-PFR` at VCTL2 1D26, `-LVMO22` with `WRCYC` becomes `-PFW` at VCTL1 1D17, and
`-VMAOK` is the NAND of the two.

This document is about one question: **what says the fabric's map is right?**

## What the board did

On 2026-09-10 the board ran 351,093,872 microcycles of MIT's System 100 band
off its own disk and halted. The console read PC `0o25041`, OPC `0o25034`,
IR `1802 d004 9300`, FLAG-1 `0xfd00` and FLAG-2 `0xc0db`, with `-VMAOK` **not**
permitted. Both addresses are inside `PDL-BUFFER-REFILL` in MIT's
`ucadr/uc-page-fault.lisp`. The routine's shape is the whole of the problem:

```
      0o25022  ((MD Q-R) VMA)                        ; address the map with MD
      0o25023  ((M-PGF-TEM) MAP-SECOND-LEVEL-MAP MEMORY-MAP-DATA)
      0o25024  ((VMA-WRITE-MAP) IOR M-PGF-TEM ...)   ; give itself access code 3
      ...
P-R-1 0o25037  ((VMA-START-READ) SUB VMA (A-CONSTANT 1))
      0o25040  (ILLOP-IF-PAGE-FAULT)                 ; "Map should be hacked"
      0o25041  ((PDL-BUFFER-INDEX) SUB PDL-BUFFER-INDEX (A-CONSTANT 1))
```

The machine writes a second-level map entry and reads through it seven
microcycles later, and the read was refused. `ILLOP` popped `0o25041`, which
is what the console shows as PC.

## Two suspects, and what separates them — measured

Either the second-level map write did not take, or the address the machine
read is not the page the map was hacked for. Each was injected into muir's own
`rtl` engine, on the board's own pack, with nothing else changed:

| injection | what it does |
|---|---|
| the write does not take | the hacked entry is put back as it was |
| the write lands one entry along | the same, seen from the other side |
| the address moves one page | `VMA` is moved a page before `P-R-1` runs |

**All three reproduce the board's readout bit for bit** at microcycle
2,196,668: PC `0o25041`, OPC `0o25034`, FLAG-1 `0xfd00`, FLAG-2 `0xc0db`,
IR `0x1802d0049300`. Every register the console can read is identical across
the three. The sixteen diagnostic registers do not carry `VMA` or `Q`, and
those are the two that differ. `Q` holds the address the map was hacked for,
which `((MD Q-R) VMA)` put there, and `VMA` holds the address that faulted.
**So a halted board cannot be asked which suspect it is.** It would need either
two more registers on `rtl/plumbing/cadr_console.sv` or a microinstruction
stepped by hand to put `VMA` on `OB`.

The injections settle one more thing. muir reaches `PDL-BUFFER-REFILL`'s first
map hack at microcycle **2,196,653**, and it does all 105 of its calls, 63
hacks and 546 `P-R-1` reads inside the first twenty million microcycles. The
board ran **351,093,872**. A fault that bit every second-level map write would
have stopped the board 160 times sooner, so whatever the fabric does wrong it
does rarely. The other reading is that the board's path had already left
muir's long before, which the missing I/O board (no microsecond clock, no
keyboard, no Chaosnet) is enough to explain. Both readings refute the blanket
form of either suspect.

## The check that did not exist

`make check` had two halves of this claim and neither of the join.

- **`machine.pass`** runs `cadr_machine` from reset on MIT's boot PROM and
  holds every column against muir, including `-VMAOK`. But `mem_rdata` is
  muir's own `md` column **keyed by the row**, so the word is right whatever
  address the map produced. The physical address is never used to fetch
  anything, and a mistranslation that still permits the access is invisible.
- **`ddr_boot.pass`** has a real store behind `mem_*` and asserts the address
  sequence. But it has no muir reference at all, so it cannot compare
  `-VMAOK`, `MD`, or the instant of anything.

`build/map_boot.pass` is the join. It takes `machine.pass`'s reference with
`ddr_boot`'s memory. The word `MD` takes is fetched from a store keyed by
`mem_addr`. Page 0 holds what muir's memory holds, which is zero, so the
comparison against muir is exact with no exemption anywhere. Every other
address holds a poison injective in it. A read the map sends a page wide
therefore takes a word muir never had, and `MD` says so on the microcycle it
happens. The write half is held by the store. A word written outside page 0 is
named at its address, each of the 256 words must be read exactly once and
written exactly once, and page 0 must be zero at the end.

**And the boot PROM does exercise the property, which CLAUDE.md said it did
not.** This was measured against muir. `SET-UP-FOUR-PAGES` writes four
second-level entries at microcycles 536,290, 536,293, 536,297 and 536,299, and
each takes an entry from **zero — no access** — to `MAP-ACCESS-CODE 3`. The
first bus cycle is at 536,302. That is twelve microcycles after the first and
three after the last, against `PDL-BUFFER-REFILL`'s seven. The testbench
re-derives that gap from the trace's own `WMAPD` and `VMA<25>` columns at every
run. It fails if no second-level write falls in the sixty-four microcycles
before the first bus cycle, so a reference that stopped putting the two
together says so rather than passing.

## What it cannot reach, said on its own output

muir refuses the access on **none** of the 600,000 microcycles, and every map
word the boot PROM writes carries `MAP-ACCESS-CODE 3`, bits 23 and 22 alike.
So `-VMAOK` is compared only in its permitted direction, and the two access
bits cannot be told apart. Swapping them survives, and not by luck.
`PDL-BUFFER-REFILL`'s own entry is `0o27200352` before the hack, with bit 23
clear and bit 22 set. That is exactly where they differ, and it is the half of
the map the board halted in. Closing it needs a machine-level reference whose
program holds an asymmetric map word, which means the band on `cadr_machine`
and a pack.

## The records

There are five, in `mutations/list.txt`, and all are caught:

| record | what it breaks |
|---|---|
| `the-second-level-map-write-misses-its-entry` | the write does not take |
| `a-read-translates-through-a-stale-map-entry` | the page comes from the previous cycle's latch |
| `the-access-bit-comes-from-the-page-half-of-the-map-word` | the permission read from the wrong half |
| `the-physical-page-is-one-too-high` | the translation, inside main memory |
| `the-memory-address-loses-its-page-bit` | the last step to `mem_addr` |

The first four are caught by `machine` as well, each for a reason of its own
and none of them the address: two on `-VMAOK`, one on the NXM timer, and one
because the disk controller's four registers sit on the same physical address
and stop answering. The last is the one only this check sees.
`cadr_ddr_map::main_byte_address` is reached by the memory port and by nothing
else, so a fault there leaves every device where it was, and `machine.pass`
survives it with every column green.
