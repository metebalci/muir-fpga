# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# muir-fpga: the CADR in fabric.
#
#   make check      everything below
#   make cables     regenerate the processor's port list from muir
#   make clean      remove build/
#
# Everything is checked against muir, which must be checked out beside this
# repository. Nothing here vendors a copy of its netlists or part tables.

VERILATOR ?= verilator
CARGO     ?= cargo
TCLSH     ?= tclsh

BUILD := build
GOLDEN := $(CARGO) run --quiet --manifest-path golden/Cargo.toml

VFLAGS := --cc --exe --build -Wall

.PHONY: check cables current mutants mutants-selftest probe-selftest clean

check: $(BUILD)/phase_gen.pass $(BUILD)/cables.pass $(BUILD)/busint_xbus.pass \
       $(BUILD)/xbus_decode.pass $(BUILD)/ddr_map.pass \
       $(BUILD)/memory_path.pass $(BUILD)/axi_master.pass \
       $(BUILD)/microcycle.pass $(BUILD)/microcycle_sys.pass \
       $(BUILD)/machine.pass $(BUILD)/arty.pass $(BUILD)/probe.pass \
       $(BUILD)/probe_jtag.pass current

# ---------------------------------------------------------------- phase gen

# The reference trace, out of muir's own clock::Behavioural. It carries the
# stimulus as well as the expected outputs, so the testbench and the model
# cannot drift apart.
$(BUILD)/phase_gen.golden: golden/src/phase_gen.rs golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin phase_gen > $@

$(BUILD)/obj_phase_gen/Vcadr_phase_gen: rtl/cadr_phase_gen.sv tb/cadr_phase_gen_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -Mdir $(BUILD)/obj_phase_gen --top-module cadr_phase_gen \
	    rtl/cadr_phase_gen.sv $(abspath tb/cadr_phase_gen_tb.cpp)

$(BUILD)/phase_gen.pass: $(BUILD)/obj_phase_gen/Vcadr_phase_gen $(BUILD)/phase_gen.golden
	$(BUILD)/obj_phase_gen/Vcadr_phase_gen $(BUILD)/phase_gen.golden
	@touch $@

# ------------------------------------------------------------- busint, Xbus

$(BUILD)/busint_xbus.golden: golden/src/busint_xbus.rs golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin busint_xbus > $@

$(BUILD)/obj_busint_xbus/Vcadr_busint_xbus: rtl/cadr_busint_xbus.sv tb/cadr_busint_xbus_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -Mdir $(BUILD)/obj_busint_xbus --top-module cadr_busint_xbus \
	    rtl/cadr_busint_xbus.sv $(abspath tb/cadr_busint_xbus_tb.cpp)

$(BUILD)/busint_xbus.pass: $(BUILD)/obj_busint_xbus/Vcadr_busint_xbus $(BUILD)/busint_xbus.golden
	$(BUILD)/obj_busint_xbus/Vcadr_busint_xbus $(BUILD)/busint_xbus.golden
	@touch $@

# ------------------------------------------------------------- AXI adapter

# No muir reference: nothing in MIT's drawings is an AXI master. Held to the
# protocol, checked every tick, and to read-back.
$(BUILD)/obj_axi_master/Vcadr_axi_master: rtl/cadr_axi_master.sv tb/cadr_axi_master_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -Mdir $(BUILD)/obj_axi_master \
	    --top-module cadr_axi_master rtl/cadr_axi_master.sv $(abspath tb/cadr_axi_master_tb.cpp)

$(BUILD)/axi_master.pass: $(BUILD)/obj_axi_master/Vcadr_axi_master
	$(BUILD)/obj_axi_master/Vcadr_axi_master
	@touch $@

# -------------------------------------------------------------- memory path

# The pieces running together: decode, bus interface and DDR bridge, from the
# same trace. Checked two ways --- the timing still agrees with muir, and a read
# returns the word an earlier write put there.
MEMPATH := rtl/cadr_ddr_map.sv rtl/cadr_xbus_decode.sv rtl/cadr_busint_xbus.sv \
           rtl/cadr_xbus_ddr.sv rtl/cadr_memory_path.sv

$(BUILD)/obj_memory_path/Vcadr_memory_path: $(MEMPATH) tb/cadr_memory_path_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -Irtl -Mdir $(BUILD)/obj_memory_path \
	    --top-module cadr_memory_path $(MEMPATH) $(abspath tb/cadr_memory_path_tb.cpp)

$(BUILD)/memory_path.pass: $(BUILD)/obj_memory_path/Vcadr_memory_path $(BUILD)/busint_xbus.golden
	$(BUILD)/obj_memory_path/Vcadr_memory_path $(BUILD)/busint_xbus.golden
	@touch $@

# ------------------------------------------------------------------ DDR map

# Constants only, and shared with the Linux side, so all lint can do is prove
# they elaborate. What keeps them honest is that they are in one place.
$(BUILD)/ddr_map.pass: rtl/cadr_ddr_map.sv rtl/cadr_xbus_decode.sv | $(BUILD)
	$(VERILATOR) --lint-only -Wall --top-module cadr_xbus_decode \
	    rtl/cadr_ddr_map.sv rtl/cadr_xbus_decode.sv
	@touch $@

# ------------------------------------------------------------ address decode

# Checked at every one of the 4,194,304 addresses the 22-bit Xbus can carry,
# for each board count, so the reference is written as runs and expanded.
$(BUILD)/xbus_decode.golden: golden/src/xbus_decode.rs golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin xbus_decode > $@

$(BUILD)/obj_xbus_decode/Vcadr_xbus_decode: rtl/cadr_xbus_decode.sv tb/cadr_xbus_decode_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Mdir $(BUILD)/obj_xbus_decode \
	    --top-module cadr_xbus_decode rtl/cadr_xbus_decode.sv $(abspath tb/cadr_xbus_decode_tb.cpp)

$(BUILD)/xbus_decode.pass: $(BUILD)/obj_xbus_decode/Vcadr_xbus_decode $(BUILD)/xbus_decode.golden
	$(BUILD)/obj_xbus_decode/Vcadr_xbus_decode $(BUILD)/xbus_decode.golden
	@touch $@

# ------------------------------------------------------------- the microcycle

# The processor, slice by slice, against muir's `rtl` engine running MIT's own
# boot PROM. Not a scripted stimulus: a real program, one line a microcycle.
# The trace carries what the fabric cannot yet compute as well as what it must,
# and the testbench prints which is which.
$(BUILD)/rtl.golden: golden/src/rtl.rs golden/src/trace.rs \
                    golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin rtl > $@

# MIT's boot PROM as a $$readmemh image, read at elaboration. Generated, never
# committed: the microcode is muir's to carry, as the netlists are.
$(BUILD)/boot_prom.hex: golden/src/prom.rs golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin prom > $@

MICROCYCLE := rtl/cadr_phase_gen.sv rtl/cadr_microcycle.sv

# The PROM image is named at verilation, absolute, rather than left to the
# module's relative default: $$readmemh resolves against the working directory,
# so a model built with the default runs only from the repository root with the
# default BUILD, and elaborates a control store of x's anywhere else.
$(BUILD)/obj_microcycle/Vcadr_microcycle: $(MICROCYCLE) tb/cadr_microcycle_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Mdir $(BUILD)/obj_microcycle \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    --top-module cadr_microcycle $(MICROCYCLE) $(abspath tb/cadr_microcycle_tb.cpp)

$(BUILD)/microcycle.pass: $(BUILD)/obj_microcycle/Vcadr_microcycle \
                          $(BUILD)/rtl.golden $(BUILD)/boot_prom.hex
	$(BUILD)/obj_microcycle/Vcadr_microcycle $(BUILD)/rtl.golden
	@touch $@

# ------------------------------------------------------- the whole machine

# The processor and the memory path joined by the cables. Both halves have
# their own checks and pass them; this is the one that asks them to agree with
# each other about a single cycle. MD is no longer a column of the trace: it
# is the word the fabric's own bus interface strobes into it, at the instant
# that interface says, and the stall timing has to come out right with the
# real interface underneath.
MACHINE := rtl/cadr_phase_gen.sv rtl/cadr_microcycle.sv rtl/cadr_ddr_map.sv \
           rtl/cadr_xbus_decode.sv rtl/cadr_busint_xbus.sv rtl/cadr_xbus_ddr.sv \
           rtl/cadr_spy_registers.sv rtl/cadr_memory_path.sv rtl/cadr_machine.sv

$(BUILD)/obj_machine/Vcadr_machine: $(MACHINE) tb/cadr_machine_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl -Mdir $(BUILD)/obj_machine \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    --top-module cadr_machine $(MACHINE) $(abspath tb/cadr_machine_tb.cpp)

$(BUILD)/machine.pass: $(BUILD)/obj_machine/Vcadr_machine \
                       $(BUILD)/rtl.golden $(BUILD)/boot_prom.hex
	$(BUILD)/obj_machine/Vcadr_machine $(BUILD)/rtl.golden
	@touch $@

# ------------------------------------------------- the machine with no memory

# Not a check: it asserts nothing and cannot fail. `tb/cadr_nomem_tb.cpp` runs
# the exact configuration `rtl/cadr_arty.sv` puts on the board --- `mem_done`
# tied low, `mem_rdata` zero --- and prints what it measures. Every number in
# `docs/board.md`'s no-memory paragraph comes from it, and it dies with that
# paragraph.
#
# Phony deliberately. A `.pass` file would make `check_makefile` report a check
# that nothing mutates.
.PHONY: nomem
nomem: $(BUILD)/obj_nomem/Vcadr_machine $(BUILD)/boot_prom.hex
	$(BUILD)/obj_nomem/Vcadr_machine

$(BUILD)/obj_nomem/Vcadr_machine: $(MACHINE) tb/cadr_nomem_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl -Mdir $(BUILD)/obj_nomem \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    --top-module cadr_machine $(MACHINE) $(abspath tb/cadr_nomem_tb.cpp)

# ------------------------------------------------------------- the top level

# `rtl/cadr_arty.sv` is the only file with no check of any kind. It cannot be
# simulated --- Verilator has no `MMCME2_BASE` --- but it can be linted, and
# lint is what says the port list matches, that nothing is undriven, and that
# the `witness` fold really names every output of `cadr_machine`.
#
# The stubs are in `tb/` and must stay there: both vivado scripts read
# `[glob rtl/*.sv]`, so a stub `MMCME2_BASE` in `rtl/` would replace the real
# primitive in synthesis and hand the board a wire where its clock generator
# belongs. `tb/cadr_arty_stubs.sv` says the same at greater length.
#
# TWICE, BECAUSE THERE ARE TWO BOARDS. `PROBE_DEPTH` is zero by default and
# the generate block that instantiates `rtl/cadr_probe.sv` is then not
# elaborated at all --- so a lint of the default says nothing whatever about
# the configuration `vivado/probe.tcl` builds and programs. A branch only one
# build reaches is a branch only one build checks.
$(BUILD)/arty.pass: $(MACHINE) rtl/cadr_arty.sv rtl/cadr_probe.sv \
                    tb/cadr_arty_stubs.sv | $(BUILD)
	$(VERILATOR) --lint-only -Wall -Irtl \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    --top-module cadr_arty tb/cadr_arty_stubs.sv rtl/cadr_arty.sv $(MACHINE)
	$(VERILATOR) --lint-only -Wall -Irtl \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GPROBE_DEPTH=1024 \
	    --top-module cadr_arty tb/cadr_arty_stubs.sv rtl/cadr_arty.sv \
	    rtl/cadr_probe.sv $(MACHINE)
	@touch $@

# --------------------------------------------------------------- the probe

# `rtl/cadr_probe.sv` is what will be read off the board. It is checked the
# way everything else here is checked --- against muir's own trace --- and not
# merely instantiated: `tb/cadr_probe_harness.sv` wires it to `cadr_machine`
# exactly as `rtl/cadr_arty.sv` does, and the testbench shifts all 1,024
# samples out through the probe's own JTAG shift register and compares every
# column against `build/rtl.golden`. The window needs no stimulus: the boot
# PROM's first memory cycle is at microcycle 535,791.
#
# The harness is in `tb/` for the reason `tb/cadr_arty_stubs.sv` gives: both
# Vivado scripts read `[glob rtl/*.sv]`.
PROBE_SRC := $(MACHINE) rtl/cadr_probe.sv tb/cadr_probe_harness.sv

$(BUILD)/obj_probe/Vcadr_probe_harness: $(PROBE_SRC) tb/cadr_probe_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl -Mdir $(BUILD)/obj_probe \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    --top-module cadr_probe_harness $(PROBE_SRC) \
	    $(abspath tb/cadr_probe_tb.cpp)

$(BUILD)/probe.pass: $(BUILD)/obj_probe/Vcadr_probe_harness \
                       $(BUILD)/rtl.golden $(BUILD)/boot_prom.hex
	$(BUILD)/obj_probe/Vcadr_probe_harness $(BUILD)/rtl.golden
	@touch $@

# ------------------------------------------------- the probe's other half
#
# `vivado/probe.tcl` is the script that reads the capture off the board over
# JTAG, and until this rule it was the one program here that nothing could
# run: it needs a board, and it shipped with a one-character bug --- TDI
# driven with zeros where the chain terminates itself only on ones --- that
# made every readout fail. Nothing could have caught it, because nothing
# could exercise it.
#
# `tb/cadr_jtag_chain.tcl` is a shift-chain model of the two devices a Zynq
# presents, and `tb/cadr_probe_jtag_tb.tcl` runs the script against seven
# chains and asserts, for each, the LINE it must print --- not merely its exit
# code, because "fails on the check that names it, not on a sample of zeros"
# is a claim `vivado/probe.tcl`'s own header makes and an exit code cannot
# tell the two apart.
#
# IN `check`, and it earns the place: it is a check of a script the repository
# ships and will depend on, it needs neither Vivado nor a board nor a
# bitstream, and it costs 80 ms. What it does NOT check is written at length
# in `tb/cadr_jtag_chain.tcl`'s header --- there is no TAP state machine here,
# no DRCK and no silicon, so a green run says the script reads a chain
# correctly and says nothing whatever about the readout being verified.
$(BUILD)/probe_jtag.pass: vivado/probe.tcl tb/cadr_jtag_chain.tcl \
                          tb/cadr_probe_jtag_tb.tcl | $(BUILD)
	OUTDIR=$(BUILD)/probe_jtag $(TCLSH) tb/cadr_probe_jtag_tb.tcl
	@touch $@

# ------------------------------------------- the hardware capture, checked
#
# The probe is the instrument; a capture is what it produces, and this is what
# reads one. `tools/probe_check.py` compares a capture read off the board
# against the same reference trace every other check uses. It is the only
# thing that will ever be able to say the *board* computes what muir computes
# --- six LEDs cannot --- so a bug in it would not be caught by anything
# downstream. Its self-test makes fifteen captures out of `rtl.golden` and
# requires the right verdict on each: agreement at two lengths and two
# radixes, and a NAMED failure on a wrong cell, a wrong column, an offset of
# one with and without a cycle column to say so, a truncated readout, a ragged
# row, an unknown column, an empty capture, and a trigger that does not mark
# sample zero.
#
# Phony, and not in `check`, on `mutants-selftest`'s precedent: it tests a
# tool rather than the fabric, and a `.pass` would make `check_makefile`
# report a check that nothing mutates. It should join `check` the day a
# mutation record is aimed at it. Three seconds, and it needs only the trace.
.PHONY: probe-selftest
probe-selftest: $(BUILD)/rtl.golden
	python3 tools/probe_check.py --self-test

# ------------------------------------------------------------------- cables

# The processor's port list. Generated, and committed, so that a checkout
# builds without muir; `current` is what keeps the committed copy honest.
cables:
	$(GOLDEN) --bin cables

$(BUILD)/cables.pass: rtl/cadr_cables.svh rtl/cadr_cables_lint.sv | $(BUILD)
	$(VERILATOR) --lint-only -Wall --top-module cadr_cables_lint -Irtl \
	    rtl/cadr_cables_lint.sv
	@touch $@

# The generated files have to be the ones the generator writes today. Same
# discipline as cadr4 next door: regenerate, and fail if anything moved.
current:
	@$(GOLDEN) --bin cables
	@git diff --quiet --exit-code HEAD -- rtl/cadr_cables.svh rtl/cadr_cables.map \
	    rtl/cadr_cables_lint.sv \
	    || { echo "generated files are stale: run 'make cables' and commit"; exit 1; }
	@echo "ok: generated files are current"

# ------------------------------------------------------------ the mutations
#
# The checks, checked. Every entry in mutations/list.txt is a bug one of the
# checks has to catch --- the ones found the hard way among them, each of
# which passed something before it was found.
#
# The runner copies rtl/ and tb/ per mutation and builds from the copy: the
# working tree is never mutated. A mutation that fails to apply, or that lint
# rejects, is a failure of the run and not a caught mutation --- two were once
# reported as surviving when the build had failed and a stale binary ran. One
# that survives is a hole in a check.
#
# Not part of `check`: it verilates the design once per mutation. The copies go
# under BUILD, so `clean` takes them with it.
MUTDIR ?= $(BUILD)/mutants

# Mutate a commit, not the files on disk. Three sessions share this tree, and
# a run that reads it reports on whatever it held at the time --- a baseline
# that passed at one moment failing twenty-four microcycles in at the next,
# with the results either side belonging to two different designs. To try
# uncommitted work, call `mutations/run.py` directly and read its dirty-tree
# warning.
MUTREV ?= HEAD

# The goldens every check needs, including the processor's two: the stage-4
# mutations are of `cadr_microcycle.sv`, so a run from a clean build directory
# needs the traces they are checked against. Without them the runner stops and
# says which trace is missing, which is how this was found.
mutants: $(BUILD)/phase_gen.golden $(BUILD)/busint_xbus.golden \
         $(BUILD)/xbus_decode.golden $(BUILD)/rtl.golden \
         $(BUILD)/boot_prom.hex $(BUILD)/rtl_sys.golden | $(BUILD)
	python3 mutations/run.py --goldens $(BUILD) --work $(MUTDIR) \
	    --verilator '$(VERILATOR)' --cargo '$(CARGO)' --tclsh '$(TCLSH)' \
	    --rev $(MUTREV)

# The runner's own guarantees, against lists written to fail: a mutation
# that does not apply, one that lint rejects, a survivor with nothing
# recorded, a hole that has closed, one that is still open, and a run from
# another directory with relative paths --- which is how `make mutants`
# itself is invoked, and where it was once wrong.
mutants-selftest: $(BUILD)/phase_gen.golden $(BUILD)/busint_xbus.golden \
                  $(BUILD)/xbus_decode.golden $(BUILD)/rtl.golden \
                  $(BUILD)/boot_prom.hex $(BUILD)/rtl_sys.golden | $(BUILD)
	python3 mutations/run.py --goldens $(BUILD) --work $(MUTDIR) \
	    --verilator '$(VERILATOR)' --cargo '$(CARGO)' --tclsh '$(TCLSH)' \
	    --self-test

# ------------------------------------------- the processor, on a System pack

# A second reference for the processor, and an optional one: the same engine
# and the same columns as rtl.golden, with a System 100 pack under it. It
# reaches the dispatch memory's read, the map, the stack RAM and Q's shifter,
# none of which the boot PROM does --- and it does not reach IR<46> or MACHRUN
# down, which no observed program does. rtl.golden stays primary: a checkout
# without the release still runs every check that matters.
#
# Skipped, and says so, when the release archive is not here. It is fetched
# material and gitignored, as muir's own vendor/ is; CI does not have it and
# is not meant to. muir's tools/fetch-system-100.sh is what fetches it.
#
# The archive is kept here rather than read out of muir's vendor/ because a
# drive writes its pack: any working image drifts under a run that opens it,
# and a reference trace taken against one would not be reproducible --- it
# would be wrong in a way nothing reports.
#
# The sum is checked before the archive is used. The trace is reproducible
# only if the starting state is exactly these bytes, and the archive sits
# where git does not track it, so nothing else would notice it being replaced.
#
# The pack is decompressed for each run and removed after, so BUILD needs
# 269 MB free while this runs and keeps the 297 MB trace. `clean` takes
# whichever is there.
#
# The trace runs from microcycle zero, and that is not a choice: a window into
# the middle of a run cannot be checked by a fabric that boots from reset,
# which has none of the machine's state at the window's first row.
# golden/src/rtl_sys.rs has the whole account.
SYS100_GZ  := vendor/system-100-0/disk-sys-100-0.img.gz
SYS100_SHA := bab08874cc35ab129b40daf1602dbaf28e9fe818a81042148c3deb8d70a465a0

$(BUILD)/rtl_sys.golden: golden/src/rtl_sys.rs golden/src/trace.rs \
                        golden/Cargo.toml | $(BUILD)
	@if [ ! -f $(SYS100_GZ) ]; then \
	    echo "# skipped: the System 100 release is not here" > $@; \
	    echo "rtl_sys: skipped --- no System 100 release; muir's tools/fetch-system-100.sh fetches it"; \
	else \
	    set -e; \
	    echo "$(SYS100_SHA)  $(SYS100_GZ)" | sha256sum -c --quiet - \
	        || { echo "rtl_sys: $(SYS100_GZ) is not the release this trace was measured against"; exit 1; }; \
	    trap 'rm -f $(BUILD)/disk-sys-100-0.img $@.part' EXIT; \
	    gunzip -c $(SYS100_GZ) > $(BUILD)/disk-sys-100-0.img; \
	    $(GOLDEN) --release --bin rtl_sys -- --pack $(BUILD)/disk-sys-100-0.img > $@.part; \
	    mv $@.part $@; \
	fi

# The processor against the pack trace. Same testbench, same module: what
# differs is the program, and it reaches the map, the dispatch memory, Q's
# shifts and the control store, which the boot PROM never does. The testbench
# reads which generator wrote the trace out of its header and asserts what
# that trace is for.
$(BUILD)/microcycle_sys.pass: $(BUILD)/obj_microcycle/Vcadr_microcycle \
                              $(BUILD)/rtl_sys.golden $(BUILD)/boot_prom.hex
	$(BUILD)/obj_microcycle/Vcadr_microcycle $(BUILD)/rtl_sys.golden
	@touch $@

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD) golden/target
