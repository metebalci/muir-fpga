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

.PHONY: check cables current clean

check: $(BUILD)/phase_gen.pass $(BUILD)/cables.pass $(BUILD)/busint_xbus.pass current

# ---------------------------------------------------------------- phase gen

# The reference trace, out of muir's own clock::Behavioural. It carries the
# stimulus as well as the expected outputs, so the testbench and the model
# cannot drift apart.
$(BUILD)/phase_gen.golden: golden/src/phase_gen.rs golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin phase_gen > $@

$(BUILD)/obj_phase_gen/Vcadr_phase_gen: rtl/cadr_phase_gen.sv tb/cadr_phase_gen_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -Mdir $(BUILD)/obj_phase_gen --top-module cadr_phase_gen \
	    rtl/cadr_phase_gen.sv tb/cadr_phase_gen_tb.cpp

$(BUILD)/phase_gen.pass: $(BUILD)/obj_phase_gen/Vcadr_phase_gen $(BUILD)/phase_gen.golden
	$(BUILD)/obj_phase_gen/Vcadr_phase_gen $(BUILD)/phase_gen.golden
	@touch $@

# ------------------------------------------------------------- busint, Xbus

$(BUILD)/busint_xbus.golden: golden/src/busint_xbus.rs golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin busint_xbus > $@

$(BUILD)/obj_busint_xbus/Vcadr_busint_xbus: rtl/cadr_busint_xbus.sv tb/cadr_busint_xbus_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -Mdir $(BUILD)/obj_busint_xbus --top-module cadr_busint_xbus \
	    rtl/cadr_busint_xbus.sv tb/cadr_busint_xbus_tb.cpp

$(BUILD)/busint_xbus.pass: $(BUILD)/obj_busint_xbus/Vcadr_busint_xbus $(BUILD)/busint_xbus.golden
	$(BUILD)/obj_busint_xbus/Vcadr_busint_xbus $(BUILD)/busint_xbus.golden
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

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD) golden/target
