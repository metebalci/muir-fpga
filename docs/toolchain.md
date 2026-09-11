<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# What you need, and why

Two toolchains, and they answer different questions. **Keep them apart in your
head**: the checks say the fabric agrees with muir, and a bitstream says
nothing about that at all.

    make check                       Verilator + Rust + muir     no Vivado
    vivado -mode batch -source ...   Vivado                      no checks

`make check` is what CI runs on every push, and a checkout without Vivado runs
every check that matters. Nothing in `make check` synthesises anything.

## For the checks

**muir must sit beside this repository**, not inside it. `golden/Cargo.toml`
says `muir = { path = "../../muir" }`, resolved from `golden/`, so the layout is

    somewhere/
      muir/
      muir-fpga/

Nothing is vendored and nothing is fetched from crates.io: muir has no
dependencies and `golden`'s only one is muir, by path.

**Rust** is pinned at the repository root by `rust-toolchain.toml`, currently
`1.99.0-beta.4`. The pin must track muir's --- it exists because 1.98.0 and
1.98.1 miscompile `chaos::board::Turn::tc` at `opt-level = 3`. It is at the
root and not in `golden/` because rustup resolves from the working directory
and its ancestors, and `make` runs from the root; in `golden/` it would be
silently ignored. Measured, not assumed.

**Verilator**, 5.032 or near it. `sudo apt-get install verilator` is what CI
does and it is the whole of the install.

**Python 3** for `mutations/run.py`, standard library only. Not needed by
`make check`; needed by `make mutants`.

## For a bitstream

**Vivado 2026.1.** Any recent version should do; nothing here is version-bound
that we know of, and the reports quoted in `rtl/plumbing/xilinx7/cadr_machine.xdc` and
`docs/board.md` were taken on 2026.1.

**Only the Zynq-7000 device family.** The installer lets you deselect the rest
and you should: the part is `xc7z020clg400-1` and the other families are
approaching a hundred gigabytes you will never use. About 65 GB installed with
Zynq-7000 alone.

**A licence.** Vivado will not launch without one, even for the free tier ---
the failure is `[Common 17-345]`, at startup, before anything is read. A
Vivado ML Standard licence is free and node-locked to a host id; generate it on
AMD's licensing site and install it with `vlm`, or point `XILINXD_LICENSE_FILE`
at the `.lic`.

**PetaLinux is not needed** and is not in the unified installer's product list
for this version. Both halves of the boot chain are already in Vivado:
`bin/bootgen` packages `boot.bin`, and `data/embeddedsw/lib/sw_apps/zynq_fsbl`
is the FSBL source, which any Zynq cross-toolchain compiles.

### On a distribution newer than Vivado

Vivado 2026.1 needs `libncurses.so.5` and `libtinfo.so.5`. Ubuntu 26.04 ships
neither and has neither in its repositories, and the failure is at startup and
does not name a package:

    application-specific initialization failed: couldn't load file
    "libxv_commontasks.so": libncurses.so.5: cannot open shared object file

Symlinks to the installed `.so.6` are enough, and need no root:

    mkdir -p ~/lib5 && cd ~/lib5
    ln -sf /usr/lib/x86_64-linux-gnu/libncurses.so.6  libncurses.so.5
    ln -sf /usr/lib/x86_64-linux-gnu/libncursesw.so.6 libncursesw.so.5
    ln -sf /usr/lib/x86_64-linux-gnu/libtinfo.so.6    libtinfo.so.5
    export LD_LIBRARY_PATH=$HOME/lib5:$LD_LIBRARY_PATH

Put the export beside wherever `settings64.sh` is sourced. Note that Ubuntu's
`.bashrc` returns early for non-interactive shells, so a block appended to it
applies to your shells and not to `ssh host 'cmd'` or cron.

## Running the flows

    make build/boot_prom.hex                        # the PROM image, generated
    vivado -mode batch -source boards/arty-z7-20/vivado/fit.tcl       # synth, place, route, report
    vivado -mode batch -source boards/arty-z7-20/vivado/bitstream.tcl # the above, plus a .bit
    vivado -mode batch -source boards/arty-z7-20/vivado/program.tcl   # program a board

From the repository root. Each takes its settings from the environment:

    PART        default xc7z020clg400-1
    OUTDIR      default build/vivado or build/bitstream
    BOARD_URL   default localhost:3121   --- see docs/board.md
    BIT         default build/bitstream/cadr_arty.bit

**`fit.tcl` is out of context and `bitstream.tcl` is the board.** They will not
agree, and the difference is not a fault: the fit uses an ideal 5 ns clock,
the board derives 200 MHz through an MMCM from the board's 125, and an MMCM
costs on the order of two hundred picoseconds in jitter and uncertainty. A
design can meet out of context and miss on the board by that much. **The board
run is the one that decides.**

### Over ssh

A long Vivado run does not survive the session. Launch it detached, write to a
file, and poll for a sentinel:

    nohup setsid bash run.sh </dev/null >/dev/null 2>&1 &

and have `run.sh` append `EXIT=$?` when it is done. **An empty log means "not
finished", never "died"** --- that distinction has been got wrong here.

## What a run should say

`bitstream.tcl` checks its own output rather than trusting it, and the reason
is worth knowing before you read one. `cadr_machine` brings its whole datapath
out for the testbenches; a top level that left those unconnected would
synthesise to almost nothing, route in seconds, and **write a perfectly good
bitstream of an empty part.** Not an error --- a plausible artefact. So the
utilisation is compared against what the machine is known to cost:

    about 2,800 LUTs of 53,200, 29 block RAMs of 140, no DSPs

If a run reports far less than that, it did not build this machine.
