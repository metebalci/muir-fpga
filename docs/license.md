<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# License, and what is not this project's work

This file is the long form of the license table on the site's
[front page](https://metebalci.github.io/muir-fpga/#license). It says what
license this repository's work is under, which files are under another, and
whose the third-party material is. Each entry says whose it is, under what
terms, and where in the repository those terms are recorded. Where nothing
records them, it says that instead of guessing.

## This repository

The work in this repository is free software under the **GNU Affero General
Public License, version 3 or later**. That is the fabric, the checks and their
reference traces, the programs that run beside the machine, the documents and
the site alike. The full text is [`LICENSE`](../LICENSE) at the root of the
repository. Almost every file in it repeats that in its own header as the SPDX
identifier `AGPL-3.0-or-later`, so a file taken out of the repository still
says what it is.

Eight files are under the **GNU General Public License, version 2 or later**
instead, four for each of the two Zynq boards. They are the Zynq start-up
routine `ps7_init_gpl.c`, U-Boot's default environment, the board's device tree
and the `-u-boot.dtsi` beside it.

Each of the eight is compiled into U-Boot, which is itself under that license.
The start-up routine's register tables are Digilent's board configuration as
Xilinx's tool writes it out, and that tool's own `ps7_init_gpl.c` carries the
same terms. Every one of the eight says so in its own header.

## Third-party material

Some of what these boards need is not this project's work, and some of it is
not in the repository at all.

### Digilent's pin files

Pins come from Digilent's published master constraint files and never from
memory, because a wrong pin is a light that does not come on. Digilent
publishes them under the **MIT License**.

The Cora Z7-07S's master file is in its board directory byte for byte as
published, beside a copy of that license as `Digilent-License.txt`. The Arty
Z7-20's own constraint file copies out the handful of pins that design uses
rather than carrying the master file. It cites the commit and digest it read
them from.

### muir

The simulator this machine is held to is a separate repository and is not
carried here. It sits beside this one, pinned by commit in `muir.commit`, so
that a reference trace names the muir it was taken from. It is under the same
AGPL, version 3 or later.

### Buildroot, U-Boot, Linux

The Linux side of a Zynq board is built rather than copied. The build fetches
Buildroot 2026.02.3, and through it U-Boot 2026.01 and Linux 6.19.14. Each is
under its own license, which for the loader and the kernel is the GPL, version
2. Nothing of theirs is in this repository. The only files of this project's
that are compiled into them are the four per board named above.

### The fonts

The site is set in three families: Dela Gothic One, Zen Maru Gothic and IBM
Plex Mono. Dela Gothic One is by The Dela Gothic Project Authors, Zen Maru
Gothic by The Zen Maru Gothic Authors, and IBM Plex Mono by IBM. All three are
under the **SIL Open Font License, Version 1.1**.

All three are in `pages/fonts/`, so that reading a page asks nothing of a third
party. The IBM Plex Mono files are the unmodified Latin subsets Google Fonts
serves. The other two are cut down from the upstream files to the characters
the pages draw. `pages/fonts/README.md` says where each came from and how it
was cut.

### The drawing style and the characters

The site's drawing style, its palette and its panels are those of Cold Boot, a
manga-style zine about the CADR, under **CC BY-SA 4.0**. So are the parts the
site's characters are drawn from: CADR's body, its face and its waving arm.
[muir](https://muir.metebalci.com) and [ozd](https://ozd.metebalci.com) are
drawn in the same hand.

### The board, the site's mascot

The board with CADR's face on it was drawn for this site by the
[ozd](https://github.com/metebalci/ozd) project, in Cold Boot's hand. It is
copied unchanged from ozd's `pages/index.html`, where it was added at ozd
commit `b707ecc`. ozd is under the **AGPL, version 3 or later**. The face and
the waving arm it wears are Cold Boot's parts, under **CC BY-SA 4.0**.
`pages/README.md` records the same.

### MIT's own files

The drawings on the page about the real machine, and the behavior every check
in this project is held to, are read from MIT's engineering files. Those are
the drawings, wire lists, print sets and PROM images the AI Laboratory wrote
between 1977 and 1981, and MIT's system software beside them.

None of it is in this repository. muir carries it, recovered from the ITS
backup tapes and unmodified. No statement of terms came with the engineering
files, and none is made up for them. The system release states its own terms,
which are the AGPL, version 3 or later.
