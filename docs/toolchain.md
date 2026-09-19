<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# What you need, and why

There are two toolchains, and they answer different questions. **Keep them
apart in your head.** The checks say the fabric agrees with muir, and a
bitstream says nothing about that at all.

    make check                       Verilator + Rust + muir     no Vivado
    vivado -mode batch -source ...   Vivado                      no checks
    make de25                        Quartus Prime Pro           no checks

The third line is the DE25-Nano's, and it is a bitstream flow of the same kind
as the second, for the one board Vivado does not build.

`make check` is what `.github/workflows/check.yml` runs on every push, and
that workflow is disabled on GitHub today (`gh workflow list --all` reads
`disabled_manually`). A checkout without Vivado runs
every check that matters. Nothing in `make check` synthesizes anything.

## For the checks

**muir must sit beside this repository**, not inside it. `golden/Cargo.toml`
says `muir = { path = "../../muir" }`, and that is resolved from `golden/`. So
the layout is

    somewhere/
      muir/
      muir-fpga/

Nothing is vendored and nothing is fetched from crates.io. muir has no
dependencies, and `golden`'s only one is muir, by path.

**Rust** is pinned at the repository root by `rust-toolchain.toml`, currently
`1.99.0-beta.4`. The pin must track muir's. It exists because 1.98.0 and
1.98.1 miscompile `chaos::board::Turn::tc` at `opt-level = 3`. It is at the
root and not in `golden/` because rustup resolves from the working directory
and its ancestors, and `make` runs from the root. In `golden/` it would be
silently ignored. That was measured, not assumed.

**Verilator** is needed at 5.032 or near it. `sudo apt-get install verilator`
is what CI does, and it is the whole of the install.

**Python 3** runs `mutations/run.py`, with the standard library only. `make
mutants` needs it, and so does `make check`: `grid.pass` runs
`tools/grid_check.py` (`Makefile:136-140`), and `current` runs the generators'
own `--check` passes (`Makefile:1725-1734`).

## For a bitstream

**Vivado 2026.1** is what the flows here were run on. Any recent version should
do, because nothing here is version-bound that we know of. The reports quoted
in `rtl/plumbing/xilinx7/cadr_machine.xdc` and `docs/board.md` were taken on 2026.1.

**Install only the Zynq-7000 device family.** The installer lets you deselect
the rest and you should. The part is `xc7z020clg400-1`, and the other families
are approaching a hundred gigabytes you will never use. The install is about
65 GB with Zynq-7000 alone.

**A license is needed.** Vivado will not launch without one, even for the free
tier. The failure is `[Common 17-345]`, at startup, before anything is read.
The free license is node-locked to a host id. Generate it on AMD's licensing
site and install it with `vlm`, or point `XILINXD_LICENSE_FILE` at the `.lic`.

**The tier this project uses is BASIC, and the distinction matters.** The
license here reads `Vivado_Basic_Package` with `License_Tier:BASIC`. This
document said "ML Standard" for a while and that was wrong, and the error cost
a session: BASIC refuses `create_debug_core` outright, so Vivado's scripted
debug flow is unavailable and `mark_debug` is useless without a core. Nothing
here has needed more. Synthesis, place and route, the bitstream and the
hardware manager all run, and `xc7z020clg400-1` is covered. Read the license
and its stated limits before planning around a Vivado feature, or around its
absence.

**PetaLinux is not needed**, and it is not in the unified installer's product
list for this version. Both halves of the boot chain are already in Vivado.
`bin/bootgen` packages `boot.bin`, and `data/embeddedsw/lib/sw_apps/zynq_fsbl`
is the FSBL source, which any Zynq cross-toolchain compiles.

### On a distribution newer than Vivado

Vivado 2026.1 needs `libncurses.so.5` and `libtinfo.so.5`. Ubuntu 26.04 ships
neither and has neither in its repositories. The failure is at startup and does
not name a package:

    application-specific initialization failed: couldn't load file
    "libxv_commontasks.so": libncurses.so.5: cannot open shared object file

Symlinks to the installed `.so.6` are enough, and they need no root:

    mkdir -p ~/lib5 && cd ~/lib5
    ln -sf /usr/lib/x86_64-linux-gnu/libncurses.so.6  libncurses.so.5
    ln -sf /usr/lib/x86_64-linux-gnu/libncursesw.so.6 libncursesw.so.5
    ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.so.6    libtinfo.so.5
    export LD_LIBRARY_PATH=$HOME/lib5:$LD_LIBRARY_PATH

Put the export beside wherever `settings64.sh` is sourced. Note that Ubuntu's
`.bashrc` returns early for non-interactive shells. A block appended to it
therefore applies to your shells and not to `ssh host 'cmd'` or cron.

## For the DE25-Nano's bitstream

**Quartus Prime Pro 26.1.1** builds the DE25-Nano, with its Agilex 5 device
support installed. It is the one board here that Vivado does not build. The
free license covers the Agilex 5 E-series part this board carries.

    make de25            # the IP, the project, synthesis, fit, timing, a .sof
    make de25-program    # load that .sof over JTAG; volatile, never the flash

`make de25` runs `boards/de25-nano/quartus/build.sh`, whose header lists each
step and what stops it. Everything it writes is under `build/de25/`, and it
removes that directory first.

**`PROBE_DEPTH` builds the instrumented board, as it does for the Zynq
boards.** The probe records the machine's first microcycles, and a reader
compares them with muir:

    make de25 PROBE_DEPTH=1024           # into build/de25-probe/
    make de25-program PROBE_DEPTH=1024   # load that build instead
    make de25-probe                      # read the capture and compare it

The probe's JTAG side is Altera's Virtual JTAG IP, which the flow generates
beside the PLL. `make de25-probe` runs `boards/de25-nano/quartus/probe.tcl`
under `quartus_stp` and then `tools/probe_check.py` against
`build/rtl.golden`.

**Vendor RTL lives under `rtl/plumbing/<family>/`, and each flow reads only
its own family.** The Vivado flows skip every directory under
`rtl/plumbing/` but `xilinx7/`, and the Quartus flow refuses any file from
`rtl/plumbing/` one level down that is not under `agilex5/`.

**Quartus is found by `QUARTUS_ROOTDIR`,** from the environment or from a
`QUARTUS_ROOTDIR=` line in the gitignored `boards/de25-nano/local.conf`. It
names the installation's `quartus` directory, the one holding
`bin/quartus_sh`. Nothing is taken from a login shell's settings, which a
non-interactive shell does not read.

**The flow refuses to build without the Agilex 5E license.** Before
synthesis it runs `quartus_sh --check_license` and reads the license mode it
reports, which must be "Agilex 5E (no-cost)". The command exits with 3 whether
a license is there or not, so the flow reads the text. The fitter's
`Info (24849): Successfully acquired license` line is not the gate. Quartus
prints it on the fit that fetches the license and keeps the license it
fetched, so every later fit prints no license line at all. The flow quotes
the line when it appears.

**The board is named by its USB serial.** `make de25-program` reads
`DE25_SERIAL=` from the same `local.conf` and finds the JTAG cable Quartus
names after that USB device. It refuses a bitstream whose timing was not met,
unless `FORCE=1` is set, and it loads the part's configuration memory only.
The probe's reader selects its cable the same way. With no serial it goes
ahead only when exactly one cable is attached.

**The build a part holds is read back after every download.** `build.sh`
writes the build stamp into the JTAG USERCODE register, and
`boards/de25-nano/quartus/usercode.tcl` reads it back with the USERCODE
instruction from Altera's boundary-scan guide for the family, before the
download and after it. The part must hold the bitstream's build afterwards.

## Running the flows

    make build/boot_prom.hex                        # the PROM image, generated
    vivado -mode batch -source boards/arty-z7-20/vivado/fit.tcl       # synth, place, route, report
    vivado -mode batch -source boards/arty-z7-20/vivado/bitstream.tcl # the above, plus a .bit
    vivado -mode batch -source boards/arty-z7-20/vivado/program.tcl   # program a board

Run these from the repository root. Each takes its settings from the
environment:

    PART        default xc7z020clg400-1
    OUTDIR      default build/vivado or build/bitstream
    BOARD_URL   default localhost:3121   --- see docs/board.md
    BIT         default build/bitstream/cadr_arty.bit

**`fit.tcl` is out of context and `bitstream.tcl` is the board.** They will not
agree, and the difference is not a fault. The fit uses an ideal clock of the
machine's own period; the board makes that clock with an MMCM from the board's
125 MHz pin, and an MMCM costs on the order of two hundred picoseconds in
jitter and uncertainty. A design can meet out of context and miss on the board
by that much. **The board run is the one that decides.**

**Neither flow holds a clock period of its own.** The machine's tick is 10 ns
--- 100 MHz --- and the only place that is decided is `CLKOUT0_DIVIDE_F` in
`boards/arty-z7-20/cadr_arty.sv`. `boards/arty-z7-20/vivado/tick.tcl` parses
the MMCM's four parameters out of that file --- the crystal's period, the input
divider, the feedback multiplier and the output divider --- and returns the
tick they make; `fit.tcl` writes its `create_clock` from what it returns, and
both flows hand the same number to `constraints_check.tcl`'s assertions. If the
parse cannot find exactly one of each parameter the run stops and names the
file. It fails rather than defaulting on purpose: a period written a second
time in a Tcl script is a period that can disagree with the fabric, and a
default that is right today leaves the flow working after the RTL moves while
it reports a design nobody meant to build.

### Over ssh

A long Vivado run does not survive the session. Launch it detached, write to a
file, and poll for a sentinel:

    nohup setsid bash run.sh </dev/null >/dev/null 2>&1 &

Have `run.sh` append `EXIT=$?` when it is done. **An empty log means "not
finished", never "died".** That distinction has been got wrong here.

## What a run should say

`bitstream.tcl` checks its own output rather than trusting it, and the reason
is worth knowing before you read one. `cadr_machine` brings its whole datapath
out for the testbenches. A top level that left those unconnected would
synthesize to almost nothing, route in seconds, and **write a perfectly good
bitstream of an empty part.** That is not an error but a plausible artifact. So
the flow refuses a run with fewer than 1,500 LUT cells or 20 block RAMs
(`boards/arty-z7-20/vivado/bitstream.tcl:612`). The floors were set an order of
magnitude under what the machine cost at `712909e`:

    about 2,800 LUTs of 53,200, 29 block RAMs of 140, no DSPs

The machine is several times larger than that now. If a run reports less than
the floors, it did not build this machine.
