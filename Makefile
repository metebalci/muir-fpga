# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# muir-fpga: the CADR in fabric.
#
#   make check     regenerate the reference traces and check the RTL against them
#   make clean     remove build/

VERILATOR ?= verilator
CARGO     ?= cargo

BUILD := build

VFLAGS := --cc --exe --build -Wall -Wno-fatal \
          -Mdir $(BUILD)/obj_phase_gen \
          --top-module cadr_phase_gen

.PHONY: check clean golden

check: $(BUILD)/phase_gen.pass

# The reference trace, out of muir's own clock::Behavioural. It carries the
# stimulus as well as the expected outputs, so the testbench and the model
# cannot drift apart.
$(BUILD)/phase_gen.golden: golden/src/phase_gen.rs golden/Cargo.toml | $(BUILD)
	$(CARGO) run --quiet --manifest-path golden/Cargo.toml --release --bin phase_gen > $@

$(BUILD)/obj_phase_gen/Vcadr_phase_gen: rtl/cadr_phase_gen.sv tb/cadr_phase_gen_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) rtl/cadr_phase_gen.sv tb/cadr_phase_gen_tb.cpp

$(BUILD)/phase_gen.pass: $(BUILD)/obj_phase_gen/Vcadr_phase_gen $(BUILD)/phase_gen.golden
	$(BUILD)/obj_phase_gen/Vcadr_phase_gen $(BUILD)/phase_gen.golden
	@touch $@

golden: $(BUILD)/phase_gen.golden

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD) golden/target
