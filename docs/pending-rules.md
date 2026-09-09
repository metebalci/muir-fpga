# Makefile rules given by 85 at the stop, not applied

Both were sent as exact text and deliberately not applied: they arrived at a
stop, the Makefile has one writer, and an unverified rule is worse than none.
Apply them on muirhost, in this order, and read the notes first.

## 1. The no-memory harness --- phony on purpose

`tb/cadr_nomem_tb.cpp` is committed (8d14236) and its header carries the exact
verilator command, which 85 built and ran from that text rather than from
memory. The rule below is convenience, not a check.

    .PHONY: nomem
    nomem: $(BUILD)/obj_nomem/Vcadr_machine $(BUILD)/boot_prom.hex
    	$(BUILD)/obj_nomem/Vcadr_machine

    $(BUILD)/obj_nomem/Vcadr_machine: $(MACHINE) tb/cadr_nomem_tb.cpp | $(BUILD)
    	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl -Mdir $(BUILD)/obj_nomem \
    	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
    	    --top-module cadr_machine $(MACHINE) $(abspath tb/cadr_nomem_tb.cpp)

**Phony deliberately.** A `.pass` file would make `check_makefile` report a
check that nothing mutates.

## 2. The top-level lint --- and two traps worth more than the rule

`rtl/cadr_arty.sv` is the only file with no check of any kind. It cannot be
simulated (Verilator has no `MMCME2_BASE`) but it can be linted.

    $(BUILD)/arty.pass: $(MACHINE) rtl/cadr_arty.sv tb/cadr_arty_stubs.sv | $(BUILD)
    	$(VERILATOR) --lint-only -Wall -Irtl \
    	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
    	    --top-module cadr_arty tb/cadr_arty_stubs.sv rtl/cadr_arty.sv $(MACHINE)
    	@touch $@

**The stubs must live in `tb/` and never in `rtl/`.** Both vivado scripts read
`[glob rtl/*.sv]`, so a stub `MMCME2_BASE` there would replace the real
primitive in synthesis and hand the board a wire where its clock generator
belongs --- a bitstream that builds, programs and runs the machine at 125 MHz
with 8 ns taps. Also in CLAUDE.md.

**And `arty.pass` will make `make mutants` warn** --- "the Makefile runs 'arty'
and nothing here mutates it" --- until a record is aimed at the top level or
`arty` joins `ddr_map` in the runner's `known` set. Warning, not failure, on
stderr. That is `check_makefile` working, not the rule being wrong.

## 3. Then, and only then: `witness`

`rtl/cadr_arty.sv:147` folds every output of `cadr_machine` "so none of them is
dead". `dev_wdata` is committed and is not in the fold, so **the comment is
false**. The fix is one identifier in the `^{...}` list.

85 did not make it because the only way to verify an edit to that file is the
lint above, and committing unverified RTL at a stop is worse than a false
comment with a note against it. **Do the lint first, then this, in that order.**

Worth knowing why it matters more than documentation drift: the fold exists
*only* to make that claim true. The comment is the whole specification and the
register is its implementation, so a false comment there is the thing itself
being wrong.
