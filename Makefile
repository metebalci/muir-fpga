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

BUILD := build
GOLDEN := $(CARGO) run --quiet --manifest-path golden/Cargo.toml

VFLAGS := --cc --exe --build -Wall

.PHONY: check cables current mutants clean

check: $(BUILD)/phase_gen.pass $(BUILD)/cables.pass $(BUILD)/busint_xbus.pass \
       $(BUILD)/xbus_decode.pass $(BUILD)/ddr_map.pass \
       $(BUILD)/memory_path.pass $(BUILD)/axi_master.pass \
       $(BUILD)/microcycle.pass current

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
$(BUILD)/rtl.golden: golden/src/rtl.rs golden/Cargo.toml | $(BUILD)
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

mutants: $(BUILD)/phase_gen.golden $(BUILD)/busint_xbus.golden \
         $(BUILD)/xbus_decode.golden | $(BUILD)
	python3 mutations/run.py --goldens $(BUILD) --work $(MUTDIR) \
	    --verilator '$(VERILATOR)' --cargo '$(CARGO)'

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD) golden/target
