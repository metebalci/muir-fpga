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

.PHONY: check cables ps7 ps7-init current mutants mutants-selftest probe-selftest clean

check: $(BUILD)/phase_gen.pass $(BUILD)/cables.pass $(BUILD)/busint_xbus.pass \
       $(BUILD)/xbus_decode.pass $(BUILD)/ddr_map.pass \
       $(BUILD)/memory_path.pass $(BUILD)/axi_master.pass \
       $(BUILD)/axi_widen.pass $(BUILD)/prove.pass \
       $(BUILD)/microcycle.pass $(BUILD)/microcycle_sys.pass \
       $(BUILD)/machine.pass $(BUILD)/ddr_boot.pass \
       $(BUILD)/mem_count.pass \
       $(BUILD)/arty.pass $(BUILD)/probe.pass \
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

# ---------------------------------------------------------- the widening

# The 32-bit word in the port's 64-bit beat: `rtl/cadr_axi_widen.sv`. It lived
# in `rtl/cadr_arty.sv` as six assignments, where nothing could reach it ---
# Verilator has neither `MMCME2_BASE` nor `PS7`, so the top level is held by
# lint and the fitter and by nothing else, and a lane select taken from the
# wrong channel is neither a lint error nor a fitter one. It is a module so
# that this rule can exist.
#
# No muir reference, as there is none for the adapter. Held to the property:
# a word lands in the half of the beat its address selects and in no other,
# and a read of that address gives it back. The model memory is keyed by the
# stimulus and never by the DUT --- `tb/cadr_axi_widen_tb.cpp`'s header says
# why at length --- and it is poisoned rather than zeroed, so that a wrong
# lane always has a wrong answer to return.
$(BUILD)/obj_axi_widen/Vcadr_axi_widen: rtl/cadr_axi_widen.sv tb/cadr_axi_widen_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -Mdir $(BUILD)/obj_axi_widen \
	    --top-module cadr_axi_widen rtl/cadr_axi_widen.sv $(abspath tb/cadr_axi_widen_tb.cpp)

$(BUILD)/axi_widen.pass: $(BUILD)/obj_axi_widen/Vcadr_axi_widen
	$(BUILD)/obj_axi_widen/Vcadr_axi_widen
	@touch $@

# ------------------------------------------------------------- the witness

# `rtl/cadr_prove.sv` is what goes on the board ahead of the machine, in the
# two steps that decide whether the memory port works at all: one where the
# fabric writes a word and a debugger reads it, and one where a debugger
# writes and the fabric reads. Its other half on the board is an observer
# OUTSIDE the design, which is the whole reason those steps are worth doing;
# here that observer is a 64-bit AXI3 slave with a model memory the DUT
# reaches only through the port.
#
# THE HARNESS AND NOT THE MODULE, because the question is not whether a state
# machine sequences but whether a word ends up at an address, and there are
# three modules between the two. `tb/cadr_prove_harness.sv` wires the adapter
# and the widening underneath exactly as `rtl/cadr_arty.sv`'s `g_ddr` does.
# It is in `tb/` for the reason `tb/cadr_arty_stubs.sv` gives: both Vivado
# scripts read `[glob rtl/*.sv]`.
#
# No muir reference, as there is none for the adapter or the widening. Held to
# the property --- the word lands at the address it was asked for and nowhere
# else, the beat's neighbour is untouched, a wrong word does not read as a
# match --- and to the 80 ns the bus specification puts on a master, which is
# what `rtl/cadr_ddr.xdc` relaxes the adapter's address registers on.
PROVE_SRC := rtl/cadr_prove.sv rtl/cadr_axi_master.sv rtl/cadr_axi_widen.sv \
             tb/cadr_prove_harness.sv

$(BUILD)/obj_prove/Vcadr_prove_harness: $(PROVE_SRC) tb/cadr_prove_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -Irtl -Mdir $(BUILD)/obj_prove \
	    --top-module cadr_prove_harness $(PROVE_SRC) \
	    $(abspath tb/cadr_prove_tb.cpp)

$(BUILD)/prove.pass: $(BUILD)/obj_prove/Vcadr_prove_harness
	$(BUILD)/obj_prove/Vcadr_prove_harness
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

# ------------------------------------------------- the machine behind memory

# The machine with a modelled DDR3 behind `mem_*`, which is what `DDR=1` puts
# on the part. The one check here that muir cannot back past microcycle
# 537,900 --- muir has a modelled disk controller and the board has none --- so
# its reference is the boot PROM's own page-0 parity loop, poisoned from
# outside, and what the machine may NOT do with what it reads.
#
# It runs the machine twice, 200 ms of machine time each way, and takes about
# twenty seconds.
$(BUILD)/obj_ddr_boot/Vcadr_machine: $(MACHINE) tb/cadr_ddr_boot_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl -Mdir $(BUILD)/obj_ddr_boot \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    --top-module cadr_machine $(MACHINE) $(abspath tb/cadr_ddr_boot_tb.cpp)

$(BUILD)/ddr_boot.pass: $(BUILD)/obj_ddr_boot/Vcadr_machine $(BUILD)/boot_prom.hex
	$(BUILD)/obj_ddr_boot/Vcadr_machine
	@touch $@

# ------------------------------------------------- the memory port's tally

# `rtl/cadr_mem_count.sv` is the board's only positive witness that the
# machine's memory cycles were answered, and an instrument nothing checks is
# worse than no instrument --- it will be read on a board, once, and believed.
# The boot PROM's memory traffic is an identity copy, so page 0 reading back
# unchanged says the same thing whether the port answered or was never brought
# up, and no lamp tells the two apart either.
#
# THE HARNESS AND NOT THE MODULE, because the claim is not that a counter
# counts: it is that the number a debugger reads says what happened, and that
# has the machine, the bridge, the adapter and the widening in it.
# `tb/cadr_mem_count_harness.sv` wires them as `rtl/cadr_arty.sv`'s `g_ddr`
# does and brings out the 64-bit AXI3 port.
#
# TWO CONFIGURATIONS, and the second is the one the instrument exists for: the
# port held in reset, where the machine asks for exactly as much as it always
# does and NOTHING answers. A counter of the fabric's own intentions reads the
# same in both.
#
# It runs the machine twice, 200 ms of machine time each way.
MEM_COUNT_SRC := $(MACHINE) rtl/cadr_axi_master.sv rtl/cadr_axi_widen.sv \
                 rtl/cadr_mem_count.sv tb/cadr_mem_count_harness.sv

$(BUILD)/obj_mem_count/Vcadr_mem_count_harness: $(MEM_COUNT_SRC) \
                                                tb/cadr_mem_count_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl -Mdir $(BUILD)/obj_mem_count \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    --top-module cadr_mem_count_harness $(MEM_COUNT_SRC) \
	    $(abspath tb/cadr_mem_count_tb.cpp)

$(BUILD)/mem_count.pass: $(BUILD)/obj_mem_count/Vcadr_mem_count_harness \
                         $(BUILD)/boot_prom.hex
	$(BUILD)/obj_mem_count/Vcadr_mem_count_harness
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
# THREE TIMES, BECAUSE THERE ARE THREE BOARDS. `PROBE_DEPTH` and `DDR` are
# both zero by default and the generate blocks that instantiate
# `rtl/cadr_probe.sv`, `rtl/cadr_ps7.sv` and `rtl/cadr_axi_master.sv` are then
# not elaborated at all --- so a lint of the default says nothing whatever
# about the configurations `vivado/probe.tcl` and `DDR=1` build and program.
# A branch only one build reaches is a branch only one build checks.
#
# The `DDR` pass is the only thing anywhere that elaborates `cadr_ps7.sv`
# without Vivado, and what it holds is that all 620 PS7 pins are connected:
# a pin the generator did not write is a PINMISSING against
# `tb/cadr_ps7_stub.sv`, which carries the same 620 off the same parse.
#
# FIVE TIMES NOW, and `$(MACHINE)` COMES FIRST IN EVERY ONE. The top level
# takes the witness's address from `cadr_ddr_map::main_byte_address`, and a
# package has to be parsed before the file that reads it --- so the machine's
# sources, which carry the package, precede `rtl/cadr_arty.sv` on every
# command line. `mutations/run.py`'s `arty_check` already ordered them that
# way; this is the two descriptions coming back into agreement.
#
# The two new boards are the ones `rtl/cadr_prove.sv` builds: the fabric
# writing a word, and the fabric reading one back and writing it out again at
# a second address. They are a branch only those builds reach, and nothing
# else elaborates `cadr_prove.sv` at all.
$(BUILD)/arty.pass: $(MACHINE) rtl/cadr_arty.sv rtl/cadr_probe.sv \
                    rtl/cadr_ps7.sv rtl/cadr_axi_master.sv \
                    rtl/cadr_axi_widen.sv rtl/cadr_mem_count.sv \
                    rtl/cadr_prove.sv \
                    tb/cadr_arty_stubs.sv tb/cadr_ps7_stub.sv | $(BUILD)
	$(VERILATOR) --lint-only -Wall -Irtl \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    --top-module cadr_arty tb/cadr_arty_stubs.sv $(MACHINE) rtl/cadr_arty.sv
	$(VERILATOR) --lint-only -Wall -Irtl \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GPROBE_DEPTH=1024 \
	    --top-module cadr_arty tb/cadr_arty_stubs.sv $(MACHINE) \
	    rtl/cadr_arty.sv rtl/cadr_probe.sv
	$(VERILATOR) --lint-only -Wall -Irtl \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GDDR=1 \
	    --top-module cadr_arty tb/cadr_arty_stubs.sv tb/cadr_ps7_stub.sv \
	    $(MACHINE) rtl/cadr_arty.sv rtl/cadr_ps7.sv rtl/cadr_axi_master.sv \
	    rtl/cadr_axi_widen.sv rtl/cadr_mem_count.sv
	$(VERILATOR) --lint-only -Wall -Irtl \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GPROVE=1 \
	    --top-module cadr_arty tb/cadr_arty_stubs.sv tb/cadr_ps7_stub.sv \
	    $(MACHINE) rtl/cadr_arty.sv rtl/cadr_ps7.sv rtl/cadr_axi_master.sv \
	    rtl/cadr_axi_widen.sv rtl/cadr_mem_count.sv rtl/cadr_prove.sv
	$(VERILATOR) --lint-only -Wall -Irtl \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GPROVE=2 \
	    --top-module cadr_arty tb/cadr_arty_stubs.sv tb/cadr_ps7_stub.sv \
	    $(MACHINE) rtl/cadr_arty.sv rtl/cadr_ps7.sv rtl/cadr_axi_master.sv \
	    rtl/cadr_axi_widen.sv rtl/cadr_mem_count.sv rtl/cadr_prove.sv
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

# ---------------------------------------------------------------------- PS7

# The Zynq processing system's wrapper and its lint stub, off Xilinx's own
# PS7.v. Generated, and committed, for the same reason the cables are: a
# checkout builds without the tool. `current` is what keeps the committed copy
# honest, and it skips where Vivado is not installed --- CI has none.
#
# Generated because an unconnected PS7 *input* produces no warning of any
# kind: 620 pins, and the ~300 the fabric does not use are silent if a
# hand-written instantiation forgets them. vivado/gen_ps7.py has the
# measurement.
ps7:
	python3 vivado/gen_ps7.py

# -------------------------------------------------------- the PS7 routine

# What `ps7_init` writes, as an ordered list of register operations.
# Generated, and committed, for the same reason the cables and the PS7
# wrapper are: a checkout without Vivado still carries the claim, and
# `current` is what keeps the committed copy honest --- it skips where
# Vivado is not installed, and CI has none.
#
# Programming a `.bit` over JTAG does not start the PS, so without this
# routine the memory controller, the three PLLs and the pin multiplexing
# stay unconfigured and DDR does not answer. The configuration it is
# generated from is Digilent's and is board-specific;
# vivado/ps7_config.tcl says exactly where it came from, and
# vivado/ps7_ops.py what it was measured against.
ps7-init:
	python3 vivado/ps7_ops.py

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
	@python3 vivado/gen_ps7.py --check
	@python3 vivado/ps7_ops.py --check

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
