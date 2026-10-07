<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Fits

Each row is one fit of one machine on one board: its worst setup and hold
slack, the logic and block memory it takes, the commit it was built from, and
whether that tree was clean. The commit and the tree's state are the ones the
build stamp records (`tools/build_stamp.tcl`).

The parts are the Arty Z7-20's `xc7z020clg400-1`, the Cora Z7-07S's
`xc7z007sclg400-1` and the Kria KR260's `xck26-sfvc784-2LV-c`, fitted with
Vivado 2026.1, and the DE25-Nano's `A5EB013BB23BE4SCS`, fitted with Quartus
Prime Pro 26.1.1. Every fit has main memory in DDR (`DDR=1`). The Arty and
DE25-Nano fits carry the display output (`HDMI=1`), and the Kria KR260's
from `c28b67f` on carry it too, to the processing system's DisplayPort
controller; the Cora's do not.

A Vivado fit's slack is the timing summary's WNS and WHS. A Quartus fit's is
the worst over its four corners. Slices are what Vivado reports, which on the
Kria KR260's UltraScale+ part are CLBs of eight lookup tables each; Quartus
reports none.

## From a clean tree

These fits are QUUX revision 14's, built from `c24545e`: a processor's write
is no longer acknowledged while a side write waits for the write buffer,
with muir pinned at `203b1b4`. Revision 14 is at four ticks on all three
boards, with a 15 ns tick on the Arty Z7-20 and a 10 ns tick on the
DE25-Nano and the Kria KR260. Every stamp reads `c24545e0`, the tree clean.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | QUUX revision 14, K = 4, 15 ns | +0.479 ns | +0.024 ns | 19,994 of 53,200 LUTs, 37.58% | 89 of 140 BRAM tiles | 6,478 of 13,300 | `c24545e` | clean | 2026-10-07 |
| Kria KR260 | QUUX revision 14, K = 4 | +2.137 ns | +0.010 ns | 20,714 of 117,120 LUTs, 17.69% | 76 of 144 BRAM tiles, 1 of 64 URAM | 4,196 of 14,640 CLBs | `c24545e` | clean | 2026-10-07 |
| DE25-Nano | QUUX revision 14, K = 4 | +1.240 ns | 0.000 ns | 19,170 of 46,800 ALMs, 41% | 215 of 358 M20K | --- | `c24545e` | clean | 2026-10-07 |

Each Zynq fit passed its RAM enable check, the TLB's enables at the
machine's edges among them: the Arty Z7-20's over 131 ports, the Kria
KR260's over 101. The DE25-Nano's synthesis read back the machine, the
word, the revision and the PROM image by name. All three ran the board
list on these bitstreams, the DE25-Nano at 10 ns.

These fits are QUUX revision 14's, built from `6f119c1`: the TLB read at
the edge, the side seam registered, the wall clocks at any tick, with muir
pinned at `203b1b4`. Revision 14 is at four ticks on all three boards, with
a 15 ns tick on the Arty Z7-20 and a 10 ns tick on the DE25-Nano and the
Kria KR260. The Kria KR260's QUUX is 1920 by 1080 and the other boards'
1280 by 1024. Every stamp reads `6f119c10`, the tree clean.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | QUUX revision 14, K = 4, 15 ns | +0.655 ns | +0.027 ns | 19,987 of 53,200 LUTs, 37.57% | 89 of 140 BRAM tiles | 6,534 of 13,300 | `6f119c1` | clean | 2026-10-07 |
| Kria KR260 | QUUX revision 14, K = 4 | +1.726 ns | +0.012 ns | 20,704 of 117,120 LUTs, 17.68% | 76 of 144 BRAM tiles, 1 of 64 URAM | 4,006 of 14,640 CLBs | `6f119c1` | clean | 2026-10-07 |
| DE25-Nano | QUUX revision 14, K = 4 | +1.275 ns | +0.007 ns | 19,199 of 46,800 ALMs, 41% | 215 of 358 M20K | --- | `6f119c1` | clean | 2026-10-07 |

The TLB is block RAM on the Arty Z7-20, one UltraRAM on the Kria KR260 and
one true dual-port M20K memory on the DE25-Nano, each as its flow asks.
Each Zynq fit passed its RAM enable check, the TLB's enables at the
machine's edges among them: the Arty Z7-20's over 131 ports, the Kria
KR260's over 101. The DE25-Nano's synthesis read back the machine, the
word, the revision and the PROM image by name, and its timing analysis
found the side seam's one-tick clause on 14 nets.

**THESE BITSTREAMS LOSE A WRITE.** Revision 14 at `6f119c1` drops a
processor's write when a side write takes the write buffer between the
write's acknowledgment and its word's entry, which needs main memory slower
than muir's count, as the boards' is. The DE25-Nano read special
variables unbound in five trials of five, and the Kria KR260's high band
halted in a full garbage collection in four runs of six. Fits with the fix,
from the working tree, pass both: the DE25-Nano at 10 ns six trials of six,
the Kria KR260 six runs of six. `docs/timing.md` has the mechanism.

These fits were built from `94a7771`, the release commit for Systems 1003
and 2001 with a key's release sent to the position its press went to, with
muir pinned at `b00f8f7`. QUUX is revision 13 only: revision 12 is retired.
The Kria KR260's QUUX is 1920 by 1080 and the other boards' 1280 by 1024.
Revision 13 is at five ticks on the Arty Z7-20 and four on the DE25-Nano and
the Kria KR260. Every stamp reads `94a77710`, the tree clean.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | CADR | +0.209 ns | +0.018 ns | 15,106 of 53,200 LUTs, 28.39% | 46 of 140 BRAM tiles | 5,517 of 13,300 | `94a7771` | clean | 2026-10-06 |
| Arty Z7-20 | QUUX revision 13, K = 5 | +0.183 ns | +0.029 ns | 22,608 of 53,200 LUTs, 42.50% | 84 of 140 BRAM tiles | 6,807 of 13,300 | `94a7771` | clean | 2026-10-06 |
| Cora Z7-07S | CADR | +0.695 ns | +0.041 ns | 13,949 of 14,400 LUTs, 96.87% | 43 of 50 BRAM tiles | 4,360 of 4,400 | `94a7771` | clean | 2026-10-06 |
| Kria KR260 | CADR | +1.406 ns | +0.013 ns | 15,331 of 117,120 LUTs, 13.09% | 41 of 144 BRAM tiles | 3,206 of 14,640 CLBs | `94a7771` | clean | 2026-10-06 |
| Kria KR260 | QUUX revision 13, K = 4 | +1.473 ns | +0.010 ns | 22,891 of 117,120 LUTs, 19.54% | 76 of 144 BRAM tiles | 4,483 of 14,640 CLBs | `94a7771` | clean | 2026-10-06 |
| DE25-Nano | CADR | +2.380 ns | 0.000 ns | 16,495 of 46,800 ALMs, 35% | 135 of 358 M20K | --- | `94a7771` | clean | 2026-10-06 |
| DE25-Nano | QUUX revision 13 | +1.613 ns | +0.001 ns | 29,779 of 46,800 ALMs, 64% | 205 of 358 M20K | --- | `94a7771` | clean | 2026-10-06 |

Each passed its RAM enable check: the Arty Z7-20's over 98 and 131 ports,
the Cora Z7-07S's over 92, and the Kria KR260's over 88 and 119. The
DE25-Nano's synthesis read back each machine, word and PROM image by name.
Every figure is the same as the fits from `774f360` below. Between the two,
the fabric's sources changed only where revision 12 was taken out, in
comments and in the checks that refuse a 32-bit QUUX.

These fits were built from `774f360`, the release commit for Systems 1003
and 2001: a slave that has taken a cycle and always answers holds off the
bus timeout, and the cards make the user's home directories, with muir
pinned at `071f9a6`. The Kria KR260's QUUX is 1920 by 1080 and the other
boards' 1280 by 1024. Revision 13 is at five ticks on the Arty Z7-20 and
four on the DE25-Nano and the Kria KR260. Every stamp reads `774f3600`, the
tree clean.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | CADR | +0.209 ns | +0.018 ns | 15,106 of 53,200 LUTs, 28.39% | 46 of 140 BRAM tiles | 5,517 of 13,300 | `774f360` | clean | 2026-10-05 |
| Arty Z7-20 | QUUX revision 13, K = 5 | +0.183 ns | +0.029 ns | 22,608 of 53,200 LUTs, 42.50% | 84 of 140 BRAM tiles | 6,807 of 13,300 | `774f360` | clean | 2026-10-05 |
| Cora Z7-07S | CADR | +0.695 ns | +0.041 ns | 13,949 of 14,400 LUTs, 96.87% | 43 of 50 BRAM tiles | 4,360 of 4,400 | `774f360` | clean | 2026-10-05 |
| Kria KR260 | CADR | +1.406 ns | +0.013 ns | 15,331 of 117,120 LUTs, 13.09% | 41 of 144 BRAM tiles | 3,206 of 14,640 CLBs | `774f360` | clean | 2026-10-05 |
| Kria KR260 | QUUX revision 13, K = 4 | +1.473 ns | +0.010 ns | 22,891 of 117,120 LUTs, 19.54% | 76 of 144 BRAM tiles | 4,483 of 14,640 CLBs | `774f360` | clean | 2026-10-05 |
| DE25-Nano | CADR | +2.380 ns | 0.000 ns | 16,495 of 46,800 ALMs, 35% | 135 of 358 M20K | --- | `774f360` | clean | 2026-10-05 |
| DE25-Nano | QUUX revision 13 | +1.613 ns | +0.001 ns | 29,779 of 46,800 ALMs, 64% | 205 of 358 M20K | --- | `774f360` | clean | 2026-10-05 |

Each passed its RAM enable check: the Arty Z7-20's over 98 and 131 ports,
the Cora Z7-07S's over 92, and the Kria KR260's over 88 and 119. The
DE25-Nano's synthesis read back each machine, word and PROM image by name.

Against the fits from `d0bd127` below, the three QUUX fits have the same
slack and the same figures. Of the CADR's, the Kria KR260's lost 0.555 ns;
its worst path is now inside the display output, from the rotation setting
into a pixel register through seven levels of logic. The Arty Z7-20's lost
0.034 ns, the Cora Z7-07S's gained 0.302 ns and the DE25-Nano's 0.142 ns.

These fits were built from `d0bd127`, the release candidate for Systems
1003 and 2001: the color map shown as 377 minus the stored value, with muir
pinned at `071f9a6`. The Kria KR260's QUUX is 1920 by 1080 and the other
boards' 1280 by 1024. Revision 13 is at five ticks on the Arty Z7-20 and
four on the DE25-Nano and the Kria KR260. Every stamp reads `d0bd1270`, the
tree clean.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | CADR | +0.243 ns | +0.014 ns | 15,107 of 53,200 LUTs, 28.40% | 46 of 140 BRAM tiles | 5,660 of 13,300 | `d0bd127` | clean | 2026-10-04 |
| Arty Z7-20 | QUUX revision 13, K = 5 | +0.183 ns | +0.029 ns | 22,608 of 53,200 LUTs, 42.50% | 84 of 140 BRAM tiles | 6,807 of 13,300 | `d0bd127` | clean | 2026-10-04 |
| Cora Z7-07S | CADR | +0.393 ns | +0.033 ns | 13,975 of 14,400 LUTs, 97.05% | 43 of 50 BRAM tiles | 4,331 of 4,400 | `d0bd127` | clean | 2026-10-04 |
| Kria KR260 | CADR | +1.961 ns | +0.010 ns | 15,308 of 117,120 LUTs, 13.07% | 41 of 144 BRAM tiles | 3,294 of 14,640 CLBs | `d0bd127` | clean | 2026-10-04 |
| Kria KR260 | QUUX revision 13, K = 4 | +1.473 ns | +0.010 ns | 22,891 of 117,120 LUTs, 19.54% | 76 of 144 BRAM tiles | 4,483 of 14,640 CLBs | `d0bd127` | clean | 2026-10-04 |
| DE25-Nano | CADR | +2.238 ns | 0.000 ns | 16,515 of 46,800 ALMs, 35% | 135 of 358 M20K | --- | `d0bd127` | clean | 2026-10-04 |
| DE25-Nano | QUUX revision 13 | +1.613 ns | +0.001 ns | 29,779 of 46,800 ALMs, 64% | 205 of 358 M20K | --- | `d0bd127` | clean | 2026-10-04 |

Each passed its RAM enable check: the Arty Z7-20's over 98 and 131 ports,
the Cora Z7-07S's over 92, and the Kria KR260's over 88 and 119. The
DE25-Nano's synthesis read back each machine, word and PROM image by name.

Against the fits from `6a4e960` below, the Cora Z7-07S's figures are the
same. The Kria KR260's QUUX lost 0.358 ns; its worst path is the machine's
reset into a register of the memory port's cache, with no logic between
them, so the slack is where the router put that net. The DE25-Nano's QUUX
lost 0.386 ns, inside the +1.564 ns to +2.155 ns it had measured before. The
Arty Z7-20's QUUX gained 0.058 ns and the Kria KR260's CADR 0.388 ns.

These fits were built from `6a4e960`, the video controller's size and the
board name per board, with muir pinned at `91ce0c9`. The Kria KR260's QUUX
is 1920 by 1080 and the other boards' 1280 by 1024. Revision 13 is at five
ticks on the Arty Z7-20 and four on the DE25-Nano and the Kria KR260. Every
stamp reads `6a4e9600`, the tree clean.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | CADR | +0.255 ns | +0.028 ns | 15,090 of 53,200 LUTs, 28.36% | 46 of 140 BRAM tiles | 5,490 of 13,300 | `6a4e960` | clean | 2026-10-04 |
| Arty Z7-20 | QUUX revision 13, K = 5 | +0.125 ns | +0.016 ns | 22,564 of 53,200 LUTs, 42.41% | 83 of 140 BRAM tiles | 7,142 of 13,300 | `6a4e960` | clean | 2026-10-04 |
| Cora Z7-07S | CADR | +0.393 ns | +0.033 ns | 13,975 of 14,400 LUTs, 97.05% | 43 of 50 BRAM tiles | 4,331 of 4,400 | `6a4e960` | clean | 2026-10-04 |
| Kria KR260 | CADR | +1.573 ns | +0.010 ns | 15,284 of 117,120 LUTs, 13.05% | 41 of 144 BRAM tiles | 3,269 of 14,640 CLBs | `6a4e960` | clean | 2026-10-04 |
| Kria KR260 | QUUX revision 13, K = 4 | +1.831 ns | +0.012 ns | 22,823 of 117,120 LUTs, 19.49% | 75 of 144 BRAM tiles | 4,587 of 14,640 CLBs | `6a4e960` | clean | 2026-10-04 |
| DE25-Nano | CADR | +2.249 ns | 0.000 ns | 16,529 of 46,800 ALMs, 35% | 135 of 358 M20K | --- | `6a4e960` | clean | 2026-10-04 |
| DE25-Nano | QUUX revision 13 | +1.999 ns | 0.000 ns | 29,754 of 46,800 ALMs, 64% | 203 of 358 M20K | --- | `6a4e960` | clean | 2026-10-04 |

Each passed its RAM enable check: the Arty Z7-20's over 98 and 129 ports,
the Cora Z7-07S's over 92, and the Kria KR260's over 88 and 117. The
DE25-Nano's synthesis read back each machine, word and PROM image by name.

The CADR's setup slack on the Arty Z7-20, the Cora Z7-07S and the
DE25-Nano is what the last fits of every board, from `8a651a0`, measured, to
the picosecond. Four figures moved.
The Arty Z7-20's QUUX lost 0.155 ns and the Kria KR260's 0.147 ns; both
worst paths are the machine's reset into a register of the machine, with no
logic between them, so the slack is where the router put that net. The Arty
Z7-20's QUUX has measured between +0.142 ns and +0.356 ns over the fits
above. The DE25-Nano's QUUX gained 0.435 ns, inside the +1.564 ns to
+2.155 ns it has measured. The Kria KR260's CADR lost 0.131 ns against
`c28b67f`, the trial fit of `28a6626`'s single-screen centering having
measured the same +1.573 ns; its worst path is now the disk controller's
reset into one of its registers, again a reset net with no logic on it.

These fits were built from `c28b67f`, the Kria KR260's display output: the
machine's screens on the DisplayPort controller's live video input at
1920x1080 at 60 Hz, read over `S_AXI_HP3`, with the pixel clock grouped
apart from the machine's. muir is pinned at `a6fa3b3`. Revision 13 is at four
ticks. Both stamps read `c28b67f0`, the tree clean.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Kria KR260 | CADR | +1.704 ns | +0.011 ns | 15,177 of 117,120 LUTs, 12.96% | 41 of 144 BRAM tiles | 3,183 of 14,640 CLBs | `c28b67f` | clean | 2026-10-03 |
| Kria KR260 | QUUX revision 13, K = 4 | +1.978 ns | +0.010 ns | 22,658 of 117,120 LUTs, 19.35% | 75 of 144 BRAM tiles | 4,335 of 14,640 CLBs | `c28b67f` | clean | 2026-10-03 |

They passed the RAM enable check over 88 ports (the CADR) and 117 (QUUX).
The display's crossings were found by name, 524 registers on the CADR and 58
on QUUX, and all 39 live video pins were connected.

This fit was built from `3261986`, the Kria KR260's first QUUX: revision 13
at four ticks, QUUX's 64-bit memory master on the 128-bit port through
narrow bursts, with muir pinned at `a6fa3b3`. The stamp reads `32619860`, the
tree clean.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Kria KR260 | QUUX revision 13, K = 4 | +0.810 ns | +0.015 ns | 22,226 of 117,120 LUTs, 18.98% | 73 of 144 BRAM tiles | 4,201 of 14,640 CLBs | `3261986` | clean | 2026-10-03 |

It passed the RAM enable check over 113 ports, every clause of
`quux_machine.xdc` took, and it holds no cell of the debug cable.

These fits were built from `78f0f67`, which finishes QUUX's memory master's
write split at 4 KiB, with muir pinned at `a6fa3b3`. Revision 13 is at five
ticks on the Arty Z7-20 and four on the DE25-Nano. Both stamps read
`78f0f670`, the tree clean.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | QUUX revision 13, K = 5 | +0.280 ns | +0.035 ns | 22,523 of 53,200 LUTs, 42.34% | 83 of 140 BRAM tiles | 7,119 of 13,300 | `78f0f67` | clean | 2026-10-03 |
| DE25-Nano | QUUX revision 13 | +1.564 ns | +0.003 ns | 29,743 of 46,800 ALMs, 64% | 203 of 358 M20K | --- | `78f0f67` | clean | 2026-10-03 |

The Arty Z7-20's fit passed the RAM enable check over 129 ports. The
DE25-Nano's synthesis read back revision 13's machine, word and PROM image by
name.

These fits were built from `857e7bb`, QUUX revision 13 with its own boot
PROM, version 2001, and 32MW of main memory out of reset, with muir pinned at
`a6fa3b3`. Revision 13 is at five ticks on the Arty Z7-20 and four on the
DE25-Nano. Both stamps read `857e7bb0`, the tree clean.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | QUUX revision 13, K = 5 | +0.356 ns | +0.027 ns | 22,547 of 53,200 LUTs, 42.38% | 83 of 140 BRAM tiles | 7,252 of 13,300 | `857e7bb` | clean | 2026-10-03 |
| DE25-Nano | QUUX revision 13 | +2.155 ns | +0.007 ns | 29,790 of 46,800 ALMs, 64% | 203 of 358 M20K | --- | `857e7bb` | clean | 2026-10-03 |

The Arty Z7-20's fit passed the RAM enable check over 129 ports. The
DE25-Nano's synthesis read back revision 13's PROM image by name.

These fits were built from `d708429`, the combined tree: the CADR's
reservation of 16 MB of main memory and 1 MB of display, and QUUX's bitstreams
with no debug cable (contract Q5), with muir pinned at `fc654c1`. QUUX revision
13 is at five ticks on the Arty Z7-20. Every bitstream's stamp reads
`d7084290`: that commit, with the tree clean.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | QUUX revision 13, K = 5 | +0.142 ns | +0.044 ns | 22,453 of 53,200 LUTs, 42.20% | 83 of 140 BRAM tiles | 7,001 of 13,300 | `d708429` | clean | 2026-10-02 |
| Arty Z7-20 | CADR | +0.126 ns | +0.021 ns | 15,048 of 53,200 LUTs, 28.29% | 46 of 140 BRAM tiles | 5,547 of 13,300 | `d708429` | clean | 2026-10-02 |
| Cora Z7-07S | CADR | +0.158 ns | +0.036 ns | 13,952 of 14,400 LUTs, 96.89% | 43 of 50 BRAM tiles | 4,335 of 4,400 | `d708429` | clean | 2026-10-02 |
| Kria KR260 | CADR | +3.528 ns | +0.013 ns | 14,017 of 117,120 LUTs, 11.97% | 38 of 144 BRAM tiles | 3,029 of 14,640 CLBs | `d708429` | clean | 2026-10-02 |
| DE25-Nano | QUUX revision 13 | +1.910 ns | 0.000 ns | 29,659 of 46,800 ALMs, 63% | 203 of 358 M20K | --- | `d708429` | clean | 2026-10-02 |
| DE25-Nano | CADR | +2.422 ns | +0.001 ns | 16,480 of 46,800 ALMs, 35% | 135 of 358 M20K | --- | `d708429` | clean | 2026-10-02 |

The worst setup path of each Zynq fit but the Kria KR260's is the machine's
reset into a register of the machine, which has one tick; the Kria KR260's is
the board's reset into the Chaosnet face. Every Zynq fit passed
the RAM enable check, over 129, 98, 92 and 82 ports in the order above. The
QUUX fits have no cell of the debug cable and the CADR fits carry it, with both
of its six-tick clauses reaching their registers. The DE25-Nano's CADR fit
counts 82 pins of its memory adapter's address and data.

This fit was built from `e7aaa18`, the Kria KR260's first top level, with
muir pinned at `fc654c1`.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Kria KR260 | CADR | +2.848 ns | +0.014 ns | 14,014 of 117,120 LUTs, 11.97% | 38 of 144 BRAM tiles | 2,956 of 14,640 CLBs | `e7aaa18` | clean | 2026-10-01 |

Its worst setup path is the machine's memory busy flag into the enable of
the memory master's write data, 6.862 ns of the 10 ns tick; no UltraRAM is
used. It also passed `boards/arty-z7-20/vivado/rams_enable_check.tcl` over
82 block RAM ports, and the constraint check counted its 38 multicycle
exceptions on its two clocks.

This fit was built from `9695172`, the CADR as it was before its word's
width became a parameter, and is what the fit of that change below is
compared with. Its figures are those of the `aec5f54` fit below, figure for
figure.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | CADR | +0.264 ns | +0.010 ns | 15,070 of 53,200 LUTs, 28.33% | 46 of 140 BRAM tiles | 5,553 of 13,300 | `9695172` | clean | 2026-09-29 |

These fits were built from `74c2cf9`, the tree of QUUX's revision 11 with
the register page at `17777400` (contract Q13), with muir pinned at
`a2ae522`.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | CADR | +0.222 ns | +0.042 ns | 15,050 of 53,200 LUTs, 28.29% | 46 of 140 BRAM tiles | 5,529 of 13,300 | `74c2cf9` | clean | 2026-09-28 |
| Cora Z7-07S | CADR | +0.210 ns | +0.041 ns | 14,024 of 14,400 LUTs, 97.39% | 43 of 50 BRAM tiles | 4,325 of 4,400 | `74c2cf9` | clean | 2026-09-28 |
| DE25-Nano | CADR | +1.663 ns | 0.000 ns | 16,451 of 46,800 ALMs, 35% | 135 of 358 M20K | --- | `74c2cf9` | clean | 2026-09-28 |

The CADR fits are the same, figure for figure, as those of the working tree
on `ab41da7` below, since revision 11 changes nothing of the CADR's. Each
Zynq fit also passed `boards/arty-z7-20/vivado/rams_enable_check.tcl`, over
98 and 92 block RAM ports.

These fits were built from `10cf117`.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | CADR | +0.225 ns | +0.028 ns | 15,054 of 53,200 LUTs, 28.30% | 46 of 140 BRAM tiles | 5,523 of 13,300 | `10cf117` | clean | 2026-09-27 |
| Cora Z7-07S | CADR | +0.277 ns | +0.021 ns | 14,040 of 14,400 LUTs, 97.50% | 43 of 50 BRAM tiles | 4,347 of 4,400 | `10cf117` | clean | 2026-09-27 |
| DE25-Nano | CADR | +2.327 ns | 0.000 ns | 16,452 of 46,800 ALMs, 35% | 135 of 358 M20K | --- | `10cf117` | clean | 2026-09-27 |

On the DE25-Nano the worst setup path is an HDMI output pin. The machine
clock's own worst setup slack is +2.347 ns.

## From a modified tree

These fits were built from the working tree on `2df53b7` with the CADR's
reservation shrunk to 17.125 MB on every board: main memory moved to 16 MB
below the display, which stayed where it was, and the disk pack program's
records to just above the display's 1 MB. muir is pinned at `fc654c1`.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | CADR | +0.536 ns | +0.024 ns | 15,065 of 53,200 LUTs, 28.32% | 46 of 140 BRAM tiles | 5,578 of 13,300 | working tree on `2df53b7` | modified | 2026-10-01 |
| Cora Z7-07S | CADR | +0.158 ns | +0.036 ns | 13,952 of 14,400 LUTs, 96.89% | 43 of 50 BRAM tiles | 4,335 of 4,400 | working tree on `2df53b7` | modified | 2026-10-02 |
| Kria KR260 | CADR | +3.528 ns | +0.013 ns | 14,017 of 117,120 LUTs, 11.97% | 38 of 144 BRAM tiles | 3,029 of 14,640 CLBs | working tree on `2df53b7` | modified | 2026-10-02 |
| DE25-Nano | CADR | +2.422 ns | +0.001 ns | 16,480 of 46,800 ALMs, 35% | 135 of 358 M20K | --- | working tree on `2df53b7` | modified | 2026-10-02 |

The Arty fit passed `boards/arty-z7-20/vivado/rams_enable_check.tcl` over
98 block RAM ports, the Cora's over 92 and the Kria KR260's over 82,
with its 38 multicycle exceptions on its two clocks. On the DE25-Nano the
CADR's adapter keeps 82 address and data registers, where it kept 80 with
the base at `0xB000_0000`: main memory's top byte is now `0xB3` against the
display's `0xB4`, so one more address bit varies in each of the two
addresses (`boards/de25-nano/quartus/sta_check.tcl` says which).

These fits were built from the working tree on `2df53b7`, which takes the
debug cable out of QUUX's builds (contract Q5): neither the connector, nor the
join of its two debuggers, nor the register window is in a QUUX bitstream, and
the connector's pads are left undriven with their pull-downs. muir is pinned at
`fc654c1`; QUUX revision 13 is at five ticks on the Arty Z7-20.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | QUUX revision 13, K = 5 | +0.241 ns | +0.036 ns | 22,459 of 53,200 LUTs, 42.22% | 83 of 140 BRAM tiles | 7,331 of 13,300 | working tree on `2df53b7` | modified | 2026-10-02 |
| Arty Z7-20 | CADR | +0.185 ns | +0.019 ns | 15,052 of 53,200 LUTs, 28.29% | 46 of 140 BRAM tiles | 5,593 of 13,300 | working tree on `2df53b7` | modified | 2026-10-02 |
| Arty Z7-20 | CADR | +0.186 ns | +0.034 ns | 15,046 of 53,200 LUTs, 28.28% | 46 of 140 BRAM tiles | 5,564 of 13,300 | `2df53b7` | clean | 2026-10-02 |
| Cora Z7-07S | CADR | +0.495 ns | +0.016 ns | 13,942 of 14,400 LUTs, 96.82% | 43 of 50 BRAM tiles | 4,332 of 4,400 | working tree on `2df53b7` | modified | 2026-10-02 |
| Kria KR260 | CADR | +2.848 ns | +0.014 ns | 14,014 of 117,120 LUTs, 11.97% | 38 of 144 BRAM tiles | 2,956 of 14,640 CLBs | working tree on `2df53b7` | modified | 2026-10-02 |
| DE25-Nano | QUUX revision 13 | +1.540 ns | +0.001 ns | 29,707 of 46,800 ALMs, 63% | 203 of 358 M20K | --- | working tree on `2df53b7` | modified | 2026-10-02 |
| DE25-Nano | CADR | +2.550 ns | 0.000 ns | 16,500 of 46,800 ALMs, 35% | 135 of 358 M20K | --- | working tree on `2df53b7` | modified | 2026-10-02 |
| DE25-Nano | CADR | +2.550 ns | 0.000 ns | 16,500 of 46,800 ALMs, 35% | 135 of 358 M20K | --- | `2df53b7` | clean | 2026-10-02 |

The two clean rows are the CADR before the change, for comparison. On the
DE25-Nano the CADR is the same fit, figure for figure. On the Arty Z7-20 the
CADR's logic is the same, 14,498 LUT cells and 11,277 registers both times; it
moved from the top level into a generate block, which renames the cable's cells,
and the placement differs by 6 lookup tables and 0.001 ns of setup slack. The
Cora Z7-07S's and the Kria KR260's top levels are unchanged, and their flows'
Pmod constraint reaches the same 24 pins with the widened name pattern as with
the old one.

The worst setup path of revision 13 at five ticks is now the virtual address
into the prefetcher's fetch address, +0.241 ns, where the fit on `f00f376`
above was limited by the reset of the debug window, +0.153 ns. The Arty
Z7-20's QUUX fit passed the RAM enable check over 129 ports and found no cell
of the debug cable; the eight pads of Pmod JA are placed and carry their
pull-downs, with no net on them.

These fits were built from the working tree on `f00f376` with QUUX revision
13 at a microcycle of five ticks on the Arty Z7-20 (`SYNC_K13`), revision 12
still at four, and muir pinned at `fc654c1`. The machine's clock stays at
100 MHz, so its timers count true time; `docs/timing.md` says why the
microcycle is longer and not the tick.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | QUUX revision 13, K = 5 | +0.153 ns | +0.060 ns | 22,836 of 53,200 LUTs, 42.92% | 83 of 140 BRAM tiles | 7,195 of 13,300 | working tree on `f00f376` | modified | 2026-09-30 |
| Arty Z7-20 | CADR | +0.375 ns | +0.019 ns | 15,042 of 53,200 LUTs, 28.27% | 46 of 140 BRAM tiles | 5,620 of 13,300 | working tree on `f00f376` | modified | 2026-09-30 |

A fit of revision 13 at four ticks, from `15e14fd`, misses by 1.140 ns on 37
endpoints. Six of them are the map through both levels into the memory
path's decode, which has two ticks at K = 4 and three at K = 5, where it
meets by 1.206 ns. The other 31 have one tick at either K and meet at five
by placement: the cache's RAM address has +0.676 ns. The worst path at five
is the reset of the debug window from the processor's general-purpose port,
+0.153 ns. The block RAM enable check passes over 129 ports, where at four
it failed one PDL buffer port by 0.063 ns. The CADR's figures are the same, figure for
figure, as a fit of `15e14fd` made the same day.

These fits were built from the working tree on `0ecbeed` with QUUX revision
13's devices (contract G2 §4): block-disk's pages, its packed and 4-byte
transfers and its channel's 28-bit addresses and 40-bit words, packed by the
memory port; the file device's rings at 28 bits; revision 13's feature
words; and the file device's page named "QF13". muir is pinned at
`ffc5ba5`. Main memory is still at the CADR's main memory base, and the
boot PROM image is still QUUX's version 2000.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | QUUX revision 13 | -1.181 ns | +0.024 ns | 23,055 of 53,200 LUTs, 43.34% | 83 of 140 BRAM tiles | 7,415 of 13,300 | working tree on `0ecbeed` | modified | 2026-09-30 |
| DE25-Nano | QUUX revision 13 | +1.873 ns | +0.006 ns | 30,043 of 46,800 ALMs, 64% | 203 of 358 M20K | --- | working tree on `0ecbeed` | modified | 2026-09-30 |

The Arty Z7-20 misses timing on 812 endpoints:

- Three are the map chain into the memory path's decode, which has two
  ticks: -1.181 ns into `nxm` and -0.981 ns into `device`, over 20 logic
  levels.
- 809 have one tick. Most start at the memory port's cycle state and end
  at the dispatch memory's and the two map levels' write enables, -0.353 ns
  at worst, and at the cache's RAM addresses, -0.558 ns. The file device's
  enable check, now 28 bits wide, reaches the response ring's index at
  -0.090 ns.

The block-disk's own paths meet: its walk into the adapter's address has
+0.954 ns. The block RAM enable check fails on one PDL buffer port by
0.098 ns. On the DE25-Nano every corner meets, but the timing checks refuse
the build on two register counts: 31 of the 32 registers the processor
samples on its own clock, and 2 of the 6 reset synchronizer clears. In this
build Quartus merged equal registers that a fit of `0ecbeed` itself, made
the same day, keeps apart: the tally's constant bit 15 into the memory
bridge's constant address bits, and the processor system's three reset
synchronizers into one.

These fits were built from the working tree on `90603c1` with QUUX revision
13's memory port and cache (contract G2 §3): the 28-bit physical space,
40-bit words on the cables, 8-word lines of packed storage at five bytes a
word, the frame buffer window at four, the prefetch's page reach, and the
adapter's five-beat lines and five-byte writes with the split at a 4 KiB
boundary; muir pinned at `ffc5ba5`. The boot PROM image is still QUUX's
version 2000, which does not run on revision 13, and revision 13's main
memory is at the CADR's main memory base, since the DDR layout for it is
not settled: the fits measure the machine, not one that boots.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | QUUX revision 13 | -0.727 ns | +0.034 ns | 22,672 of 53,200 LUTs, 42.62% | 83 of 140 BRAM tiles | 7,466 of 13,300 | working tree on `90603c1` | modified | 2026-09-30 |
| DE25-Nano | QUUX revision 13 | +2.181 ns | +0.001 ns | 29,790 of 46,800 ALMs, 64% | 203 of 358 M20K | --- | working tree on `90603c1` | modified | 2026-09-30 |

The Arty Z7-20 misses timing on 3 endpoints:

- Two are the map chain into the memory path's decode, which has two ticks:
  from `MEMSTART` through both map levels into `device` and `nxm`, -0.727
  and -0.703 ns over 21 and 23 logic levels.
- One is the divider's step, which has one tick: -0.146 ns over 19 levels.

The cache's paths meet: its RAMs' address from the divider's hold has
+0.312 ns, a hit's word into `MD` +0.574 ns, and a write into the port's
cache +0.170 ns. The fit also ran `rams_enable_check.tcl` over 89 block
RAMs, and two of the PDL buffer's ports, enabled always, miss it by 0.021
and 0.177 ns from the PDL write index; none of the cache's does. On the
DE25-Nano every corner meets, and the adapter's clauses reach 88 endpoints
at one tick.

This fit was built from the working tree on `a8f08b4` with QUUX revision
13's processor (contract G2 and its appendix A1), `WORD_BITS=40`, and muir
pinned at `ffc5ba5`. The memory port is still revision 12's, and the boot
PROM image is QUUX's version 2000, which does not run on revision 13: the
fit measures the processor, not a machine that boots.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | QUUX revision 13 | -1.092 ns | +0.014 ns | 22,539 of 53,200 LUTs, 42.37% | 68 of 140 BRAM tiles | 7,027 of 13,300 | working tree on `a8f08b4` | modified | 2026-09-29 |

The Arty Z7-20 misses timing on 165 endpoints, in three groups:

- Four are the map chain into the memory path's decode, which has two
  ticks: from `MEMSTART`, `VMA` or `MD` through both map levels into
  `device`, the Unibus address and `nxm`. The worst is -1.092 ns, into
  `device`, over 23 logic levels with 16.0 ns of routing.
- 160 are the maps' write enables, which have one tick: from the divider's
  hold through the write pulse into the level-2 map's LUT RAM, 7 logic
  levels, the worst -0.322 ns. Level 2 is 4,096 entries of 28 bits, so one
  enable drives many more cells than before.
- One is the cache's tag RAM address from the divider's hold, -0.024 ns.

The divider's own path, one tick, has +0.970 ns, so the divider keeps its
two steps a tick. The dispatch memory's path into the next address has
+6.668 ns of its 40. The fit also passed `rams_check.tcl` (the PDL buffer is
20 block RAMs) and `rams_enable_check.tcl` over 117 block RAM ports.

The constraints check's path queries were raised from 100,000 to 400,000
paths for this build, which has more than 100,000 timing endpoints.

This fit was built from the tree committed as `90a3436`, which makes the
word's width a parameter of the processor, `WORD_BITS`, 32 on the CADR
(contract G2 §2.1), and moves muir's pin. The boot PROM image the fit reads
is the same bytes at both pins.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | CADR | +0.193 ns | +0.041 ns | 15,063 of 53,200 LUTs, 28.31% | 46 of 140 BRAM tiles | 5,669 of 13,300 | `90a3436` | see above | 2026-09-29 |

Against the `9695172` fit above it has 7 lookup tables fewer, the same 46
block RAM tiles, 4 DSPs and 11,278 registers. The worst setup path of each
is a reset's fan-out outside the processor, and the 0.071 ns between them
is placement. Both passed `rams_enable_check.tcl` over 98 block RAM ports.

These fits were built from the tree committed as `aec5f54`, the tree of
QUUX's revision 12, the fused return and its cache-only prefetch (contract
H8a), and muir pinned at `fdc1503`, whose sources `a2f3f81` keeps
unchanged; the commit pins muir at `a2f3f81`.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | CADR | +0.264 ns | +0.010 ns | 15,070 of 53,200 LUTs, 28.33% | 46 of 140 BRAM tiles | 5,553 of 13,300 | `aec5f54` | see above | 2026-09-28 |
| Cora Z7-07S | CADR | +0.494 ns | +0.024 ns | 13,894 of 14,400 LUTs, 96.49% | 43 of 50 BRAM tiles | 4,350 of 4,400 | `aec5f54` | see above | 2026-09-28 |
| DE25-Nano | CADR | +2.443 ns | 0.000 ns | 16,466 of 46,800 ALMs, 35% | 135 of 358 M20K | --- | `aec5f54` | see above | 2026-09-28 |

These fits were built from `8f2e34e` with the change that cuts the processor
system's three reset synchronizers' clears
(`boards/de25-nano/quartus/cadr_ddr.sdc`) and has
`boards/de25-nano/quartus/sta_check.tcl` check recovery and removal, with muir
pinned at `a2ae522`.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| DE25-Nano | CADR | +1.663 ns | 0.000 ns | 16,451 of 46,800 ALMs, 35% | 135 of 358 M20K | --- | `8f2e34e` | modified | 2026-09-28 |

The fit has no recovery or removal path at any of the four corners: the
only asynchronous clears in the design were those six, and they are now
cut. The setup, hold and size figures are the same as those of the clean fit
of `74c2cf9` above. That fit, analyzed again with the new check, fails
removal at all four corners, worst -0.672 ns, while recovery passes by
+3.802 ns.

These fits were built from `66a9eb5` with the constraint change that was then
committed as `208b903`.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | CADR | +0.193 ns | +0.038 ns | 15,049 of 53,200 LUTs, 28.29% | 46 of 140 BRAM tiles | 5,521 of 13,300 | `66a9eb5` | modified | 2026-09-27 |
| Cora Z7-07S | CADR | +0.282 ns | +0.053 ns | 14,037 of 14,400 LUTs, 97.48% | 43 of 50 BRAM tiles | 4,328 of 4,400 | `66a9eb5` | modified | 2026-09-27 |
| DE25-Nano | CADR | +1.663 ns | 0.000 ns | 16,451 of 46,800 ALMs, 35% | 135 of 358 M20K | --- | `66a9eb5` | modified | 2026-09-27 |

The DE25-Nano's worst setup path is an HDMI output pin; the machine clock's
own worst setup slack is +2.769 ns.

These fits were built from the working tree on `e764825` with the change in
which destination 3 no longer controls timer 0 (QUUX revision 10, contract
Q11 as amended) and muir pinned at `9f432a6`.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | CADR | +0.193 ns | +0.038 ns | 15,049 of 53,200 LUTs, 28.29% | 46 of 140 BRAM tiles | 5,521 of 13,300 | working tree on `e764825` | modified | 2026-09-27 |
| Cora Z7-07S | CADR | +0.282 ns | +0.053 ns | 14,037 of 14,400 LUTs, 97.48% | 43 of 50 BRAM tiles | 4,328 of 4,400 | working tree on `e764825` | modified | 2026-09-27 |
| DE25-Nano | CADR | +1.663 ns | 0.000 ns | 16,451 of 46,800 ALMs, 35% | 135 of 358 M20K | --- | working tree on `e764825` | modified | 2026-09-27 |

On the DE25-Nano the worst setup path is an HDMI output pin; the machine
clock's own worst setup slack is +2.769 ns.

These fits were built from the working tree on `ab41da7` with the change
that gives QUUX's control store an explicit block RAM enable and has the
cache read only at master clock edges (`docs/mutations.md`), and muir pinned
at `66408f8`. Each Zynq fit also passed
`boards/arty-z7-20/vivado/rams_enable_check.tcl`, which asked 98 block RAM
ports of the Arty Z7-20's CADR build and 92 of the Cora Z7-07S's, and found
every path into their address, write enable and enable within one tick.

| Board | Machine | Setup slack | Hold slack | Logic | Block memory | Slices | Commit | Tree | Date |
|---|---|---|---|---|---|---|---|---|---|
| Arty Z7-20 | CADR | +0.222 ns | +0.042 ns | 15,050 of 53,200 LUTs, 28.29% | 46 of 140 BRAM tiles | 5,529 of 13,300 | working tree on `ab41da7` | modified | 2026-09-27 |
| Cora Z7-07S | CADR | +0.210 ns | +0.041 ns | 14,024 of 14,400 LUTs, 97.39% | 43 of 50 BRAM tiles | 4,325 of 4,400 | working tree on `ab41da7` | modified | 2026-09-27 |
| DE25-Nano | CADR | +1.663 ns | 0.000 ns | 16,451 of 46,800 ALMs, 35% | 135 of 358 M20K | --- | working tree on `ab41da7` | modified | 2026-09-27 |

On the DE25-Nano the worst setup path is an HDMI output pin; the machine
clock's own worst setup slack is +2.769 ns.
