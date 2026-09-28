<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Fits

Each row is one fit of one machine on one board: its worst setup and hold
slack, the logic and block memory it takes, the commit it was built from, and
whether that tree was clean. The commit and the tree's state are the ones the
build stamp records (`tools/build_stamp.tcl`).

The parts are the Arty Z7-20's `xc7z020clg400-1` and the Cora Z7-07S's
`xc7z007sclg400-1`, fitted with Vivado 2026.1, and the DE25-Nano's
`A5EB013BB23BE4SCS`, fitted with Quartus Prime Pro 26.1.1. Every fit has main
memory in DDR (`DDR=1`). The Arty and DE25-Nano fits carry the display output
(`HDMI=1`), the Cora's does not.

A Vivado fit's slack is the timing summary's WNS and WHS. A Quartus fit's is
the worst over its four corners. Slices are what Vivado reports; Quartus
reports none.

## From a clean tree

These fits were built from `3dad80b`, QUUX's revision 11 with the register
page at `17777400` (contract Q13), with muir pinned at `7bc901f`.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | QUUX | +0.113 ns | +0.029 ns | 15,529 of 53,200 LUTs, 29.19% | 62 of 140 BRAM tiles | 5,178 of 13,300 | `3dad80b` | clean | 2026-09-28 |
| Arty Z7-20 | CADR | +0.222 ns | +0.042 ns | 15,050 of 53,200 LUTs, 28.29% | 46 of 140 BRAM tiles | 5,529 of 13,300 | `3dad80b` | clean | 2026-09-28 |
| Cora Z7-07S | CADR | +0.210 ns | +0.041 ns | 14,024 of 14,400 LUTs, 97.39% | 43 of 50 BRAM tiles | 4,325 of 4,400 | `3dad80b` | clean | 2026-09-28 |
| DE25-Nano | QUUX | +2.288 ns | 0.000 ns | 17,557 of 46,800 ALMs, 38% | 191 of 358 M20K | --- | `3dad80b` | clean | 2026-09-28 |
| DE25-Nano | CADR | +1.663 ns | 0.000 ns | 16,451 of 46,800 ALMs, 35% | 135 of 358 M20K | --- | `3dad80b` | clean | 2026-09-28 |

The CADR fits are the same, figure for figure, as those of the working tree
on `681a08a` below, since revision 11 changes nothing of the CADR's. The Arty
Z7-20's QUUX fit meets timing by 0.113 ns; its worst setup path is the
machine's reset into the readout's word, which has one tick. Each Zynq fit
also passed `boards/arty-z7-20/vivado/rams_enable_check.tcl`, over 105, 98
and 92 block RAM ports.

These fits were built from `7f44547`.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | QUUX | +0.176 ns | +0.028 ns | 15,568 of 53,200 LUTs, 29.26% | 62 of 140 BRAM tiles | 5,339 of 13,300 | `7f44547` | clean | 2026-09-27 |
| Arty Z7-20 | CADR | +0.225 ns | +0.028 ns | 15,054 of 53,200 LUTs, 28.30% | 46 of 140 BRAM tiles | 5,523 of 13,300 | `7f44547` | clean | 2026-09-27 |
| Cora Z7-07S | CADR | +0.277 ns | +0.021 ns | 14,040 of 14,400 LUTs, 97.50% | 43 of 50 BRAM tiles | 4,347 of 4,400 | `7f44547` | clean | 2026-09-27 |
| DE25-Nano | QUUX | +2.299 ns | 0.000 ns | 17,526 of 46,800 ALMs, 37% | 191 of 358 M20K | --- | `7f44547` | clean | 2026-09-27 |
| DE25-Nano | CADR | +2.327 ns | 0.000 ns | 16,452 of 46,800 ALMs, 35% | 135 of 358 M20K | --- | `7f44547` | clean | 2026-09-27 |

On the DE25-Nano the worst setup path of both fits is an HDMI output pin. The
machine clock's own worst setup slack is +2.909 ns for QUUX and +2.347 ns for
the CADR.

## From a modified tree

These fits were built from `4dcae2e` with the constraint change that was then
committed as `5fe33d6`.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | CADR | +0.193 ns | +0.038 ns | 15,049 of 53,200 LUTs, 28.29% | 46 of 140 BRAM tiles | 5,521 of 13,300 | `4dcae2e` | modified | 2026-09-27 |
| Cora Z7-07S | CADR | +0.282 ns | +0.053 ns | 14,037 of 14,400 LUTs, 97.48% | 43 of 50 BRAM tiles | 4,328 of 4,400 | `4dcae2e` | modified | 2026-09-27 |
| DE25-Nano | CADR | +1.663 ns | 0.000 ns | 16,451 of 46,800 ALMs, 35% | 135 of 358 M20K | --- | `4dcae2e` | modified | 2026-09-27 |

The DE25-Nano's worst setup path is an HDMI output pin; the machine clock's
own worst setup slack is +2.769 ns. QUUX's fits from the same tree, on the
Arty Z7-20 and the DE25-Nano, give the same figures as the clean fits above.

These fits were built from the working tree on `bccc2fb` with the change in
which destination 3 no longer controls timer 0 (QUUX revision 10, contract
Q11 as amended) and muir pinned at `bbc47f3`.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | QUUX | -0.013 ns | +0.020 ns | 15,560 of 53,200 LUTs, 29.25% | 62 of 140 BRAM tiles | 5,297 of 13,300 | working tree on `bccc2fb` | modified | 2026-09-27 |
| Arty Z7-20 | CADR | +0.193 ns | +0.038 ns | 15,049 of 53,200 LUTs, 28.29% | 46 of 140 BRAM tiles | 5,521 of 13,300 | working tree on `bccc2fb` | modified | 2026-09-27 |
| Cora Z7-07S | CADR | +0.282 ns | +0.053 ns | 14,037 of 14,400 LUTs, 97.48% | 43 of 50 BRAM tiles | 4,328 of 4,400 | working tree on `bccc2fb` | modified | 2026-09-27 |
| DE25-Nano | QUUX | +2.049 ns | 0.000 ns | 17,531 of 46,800 ALMs, 37% | 191 of 358 M20K | --- | working tree on `bccc2fb` | modified | 2026-09-27 |
| DE25-Nano | CADR | +1.663 ns | 0.000 ns | 16,451 of 46,800 ALMs, 35% | 135 of 358 M20K | --- | working tree on `bccc2fb` | modified | 2026-09-27 |

**The Arty Z7-20's QUUX fit missed timing** by 13 ps and 8 ps, on two paths
from the processor's memory start (`memstart`) into the memory interface's
`nxm` and `device` registers, which have two ticks, 20 ns, and took
20.013 ns. The same path is the worst in the clean QUUX fit above, with
+0.176 ns. The change that followed gives QUUX's control store an explicit
block RAM enable and has the cache read only at master clock edges
(`docs/mutations.md`); it was fitted on this tree, and its fits below meet
timing. On the DE25-Nano the worst setup path of both fits is an HDMI output
pin; the machine clock's own worst setup slack is +2.768 ns for QUUX and
+2.769 ns for the CADR.

These fits were built from the working tree on `681a08a` with that change
and muir pinned at `92dc864`. Each Zynq fit also passed
`boards/arty-z7-20/vivado/rams_enable_check.tcl`, which asked 105 block RAM
ports of the Arty Z7-20's QUUX build, 98 of its CADR build and 92 of the Cora
Z7-07S's, and found every path into their address, write enable and enable
within one tick.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | QUUX | +0.117 ns | +0.035 ns | 15,584 of 53,200 LUTs, 29.29% | 62 of 140 BRAM tiles | 5,330 of 13,300 | working tree on `681a08a` | modified | 2026-09-27 |
| Arty Z7-20 | CADR | +0.222 ns | +0.042 ns | 15,050 of 53,200 LUTs, 28.29% | 46 of 140 BRAM tiles | 5,529 of 13,300 | working tree on `681a08a` | modified | 2026-09-27 |
| Cora Z7-07S | CADR | +0.210 ns | +0.041 ns | 14,024 of 14,400 LUTs, 97.39% | 43 of 50 BRAM tiles | 4,325 of 4,400 | working tree on `681a08a` | modified | 2026-09-27 |
| DE25-Nano | QUUX | +2.294 ns | 0.000 ns | 17,499 of 46,800 ALMs, 37% | 191 of 358 M20K | --- | working tree on `681a08a` | modified | 2026-09-27 |
| DE25-Nano | CADR | +1.663 ns | 0.000 ns | 16,451 of 46,800 ALMs, 35% | 135 of 358 M20K | --- | working tree on `681a08a` | modified | 2026-09-27 |

The Arty Z7-20's QUUX fit meets timing by 0.117 ns; its worst setup path is
now the disk controller's request into the transaction audit's first
physical address, which has one tick. On the DE25-Nano the worst setup path
of both fits is an HDMI output pin; the machine clock's own worst setup slack
is +2.734 ns for QUUX and +2.769 ns for the CADR.
