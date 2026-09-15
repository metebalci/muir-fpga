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

# **A RECIPE THAT FAILS LEAVES NO TARGET BEHIND.**  Without this, a rule whose
# command redirects into `$@` leaves whatever the command managed to write ---
# and `$(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex` is written by `... --bin prom > $@`, so a cargo
# failure left a ZERO-BYTE file that make then believed was up to date.  An
# empty `$$readmemh` is a WARNING, not an error, so the control store
# elaborates empty and the machine runs zeros: the check fails on the symptom
# twenty lines below the one line that named the cause.  That is the same
# shape as the stale binary carrying another machine's PROM path, and this
# closes the half of it make can close.
#
# Surveyed before it was added: thirteen recipe lines here redirect into `$@`
# and six compile or link into it, the two expensive traces already wrote
# `$@.part` and renamed, no recipe anywhere reads its own target, and no rule
# ignores an error with a `-` prefix or `|| true` after a command that has
# already written one.  So nothing depended on a partial target surviving.
# Make already deletes a target when it is interrupted; this extends that to a
# recipe that fails, which is what the GNU manual says it is for.
#
# One target here is a DIRECTORY, `$(BUILD)`, and make deletes with `unlink`.
# If its `mkdir -p` ever failed, the deletion would fail too and print
# `unlink: ... Is a directory` on top of an error that had already stopped the
# run.  That is noise in a case that is fatal anyway, which is why the
# directory is not exempted: an exemption is a thing to keep in step.
.DELETE_ON_ERROR:

.PHONY: check cables ps7 ps7-cora ps7-init ps7-init-cora current mutants \
        mutants-selftest probe-selftest \
        disk-golden disk-boot-golden iob-golden busint-regs-golden muir-pin clean

check: $(BUILD)/phase_gen.pass $(BUILD)/cables.pass $(BUILD)/busint_xbus.pass \
       $(BUILD)/xbus_decode.pass $(BUILD)/ddr_map.pass \
       $(BUILD)/memory_path.pass $(BUILD)/axi_master.pass \
       $(BUILD)/axi_widen.pass $(BUILD)/prove.pass \
       $(BUILD)/microcycle.pass $(BUILD)/microcycle_sys.pass \
       $(BUILD)/sstep.pass \
       $(BUILD)/md_hold.pass $(BUILD)/md_hold_sys.pass \
       $(BUILD)/md_compose.pass \
       $(BUILD)/park.pass \
       $(BUILD)/machine.pass $(BUILD)/ddr_boot.pass $(BUILD)/kbd_boot.pass \
       $(BUILD)/no_auto_boot.pass $(BUILD)/errhalt_lamp.pass \
       $(BUILD)/promenable.pass \
       $(BUILD)/map_boot.pass $(BUILD)/map_access.pass \
       $(BUILD)/mem_count.pass $(BUILD)/bus_audit.pass \
       $(BUILD)/bus_audit_unit.pass $(BUILD)/axi_channel.pass \
       $(BUILD)/audit_window.pass \
       $(BUILD)/pack_channel.pass \
       $(BUILD)/arty.pass $(BUILD)/cora.pass $(BUILD)/arty_a7.pass \
       $(BUILD)/a7_mem.pass $(BUILD)/soc.pass \
       $(BUILD)/probe.pass \
       $(BUILD)/probe_jtag.pass $(BUILD)/program_tcl.pass \
       $(BUILD)/disk.pass $(BUILD)/disk_pack.pass \
       $(BUILD)/disk_boot.pass \
       $(BUILD)/gp0_default.pass $(BUILD)/gp0_split.pass \
       $(BUILD)/gp1_split.pass $(BUILD)/tv.pass $(BUILD)/color_tv.pass \
       $(BUILD)/display_out.pass $(BUILD)/hdmi_tx.pass \
       $(BUILD)/console.pass $(BUILD)/readout.pass \
       $(BUILD)/dbgin.pass $(BUILD)/dbg_pmod.pass $(BUILD)/dbg_cable.pass \
       $(BUILD)/console_face.pass $(BUILD)/readout_face.pass \
       $(BUILD)/checkpoint.pass \
       $(BUILD)/chaosnet.pass $(BUILD)/serial.pass $(BUILD)/terminal.pass \
       $(BUILD)/usb_input.pass $(BUILD)/fpgarc.pass \
       $(BUILD)/iob.pass $(BUILD)/busint_regs.pass $(BUILD)/unibus.pass \
       muir-pin current

# ----------------------------------------------------------------- muir's pin

# `muir.commit` names the commit of muir every reference trace in `golden/`
# was generated against, and this says whether the muir beside us is it.  It
# WARNS rather than fails: a trace is generated from the muir on disk, so a
# mismatch means the traces in `build/` may be of a different reference, and
# saying so is the useful part --- failing would stop somebody who is
# deliberately mid-bump.  `MUIR=..` if muir is somewhere else.
MUIR ?= ..
muir-pin:
	@pin=$$(grep -v '^#' muir.commit | tr -d '[:space:]'); \
	 have=$$(git -C $(MUIR)/muir rev-parse HEAD 2>/dev/null); \
	 if [ -z "$$have" ]; then \
	   echo "muir-pin: no git repository at $(MUIR)/muir; the pin says $$pin"; \
	 elif [ "$$have" != "$$pin" ]; then \
	   echo "muir-pin: WARNING --- muir is at $$have"; \
	   echo "muir-pin:           the pin says   $$pin"; \
	   echo "muir-pin: the traces in $(BUILD) are of whichever muir made them."; \
	   echo "muir-pin: to move the pin: write the SHA into muir.commit, rm -f $(BUILD)/*.golden,"; \
	   echo "muir-pin: make check, and commit the pin with every trace that changed."; \
	 else \
	   echo "muir-pin: muir is at the pinned $$pin"; \
	 fi

# ---------------------------------------------------------------- phase gen

# The reference trace, out of muir's own clock::Behavioral. It carries the
# stimulus as well as the expected outputs, so the testbench and the model
# cannot drift apart.
$(BUILD)/phase_gen.golden: golden/src/phase_gen.rs golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin phase_gen > $@

$(BUILD)/obj_phase_gen/Vcadr_phase_gen: rtl/machine/cadr_phase_gen.sv tb/cadr_phase_gen_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -Mdir $(BUILD)/obj_phase_gen --top-module cadr_phase_gen \
	    rtl/machine/cadr_phase_gen.sv $(abspath tb/cadr_phase_gen_tb.cpp)

$(BUILD)/phase_gen.pass: $(BUILD)/obj_phase_gen/Vcadr_phase_gen $(BUILD)/phase_gen.golden
	$(BUILD)/obj_phase_gen/Vcadr_phase_gen $(BUILD)/phase_gen.golden
	@touch $@

# ------------------------------------------------------------- busint, Xbus

$(BUILD)/busint_xbus.golden: golden/src/busint_xbus.rs golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin busint_xbus > $@

$(BUILD)/obj_busint_xbus/Vcadr_busint_xbus: rtl/machine/cadr_busint_xbus.sv tb/cadr_busint_xbus_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -Mdir $(BUILD)/obj_busint_xbus --top-module cadr_busint_xbus \
	    rtl/machine/cadr_busint_xbus.sv $(abspath tb/cadr_busint_xbus_tb.cpp)

$(BUILD)/busint_xbus.pass: $(BUILD)/obj_busint_xbus/Vcadr_busint_xbus $(BUILD)/busint_xbus.golden
	$(BUILD)/obj_busint_xbus/Vcadr_busint_xbus $(BUILD)/busint_xbus.golden
	@touch $@

# ------------------------------------------------------------- AXI adapter

# No muir reference: nothing in MIT's drawings is an AXI master. Held to the
# protocol, checked every tick, and to read-back.
$(BUILD)/obj_axi_master/Vcadr_axi_master: rtl/plumbing/cadr_axi_master.sv tb/cadr_axi_master_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -Mdir $(BUILD)/obj_axi_master \
	    --top-module cadr_axi_master rtl/plumbing/cadr_axi_master.sv $(abspath tb/cadr_axi_master_tb.cpp)

$(BUILD)/axi_master.pass: $(BUILD)/obj_axi_master/Vcadr_axi_master
	$(BUILD)/obj_axi_master/Vcadr_axi_master
	@touch $@

# ---------------------------------------------------------- the widening

# The 32-bit word in the port's 64-bit beat: `rtl/plumbing/cadr_axi_widen.sv`. It lived
# in `boards/arty-z7-20/cadr_arty.sv` as six assignments, where nothing could reach it ---
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
$(BUILD)/obj_axi_widen/Vcadr_axi_widen: rtl/plumbing/cadr_axi_widen.sv tb/cadr_axi_widen_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -Mdir $(BUILD)/obj_axi_widen \
	    --top-module cadr_axi_widen rtl/plumbing/cadr_axi_widen.sv $(abspath tb/cadr_axi_widen_tb.cpp)

$(BUILD)/axi_widen.pass: $(BUILD)/obj_axi_widen/Vcadr_axi_widen
	$(BUILD)/obj_axi_widen/Vcadr_axi_widen
	@touch $@

# ------------------------------------------------------------- the witness

# `rtl/plumbing/cadr_prove.sv` is what goes on the board ahead of the machine, in the
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
# and the widening underneath exactly as `boards/arty-z7-20/cadr_arty.sv`'s `g_ddr` does.
# It is in `tb/` for the reason `tb/cadr_arty_stubs.sv` gives: both Vivado
# scripts read `[glob rtl/*/*.sv rtl/*/*/*.sv boards/arty-z7-20/*.sv]`.
#
# No muir reference, as there is none for the adapter or the widening. Held to
# the property --- the word lands at the address it was asked for and nowhere
# else, the beat's neighbor is untouched, a wrong word does not read as a
# match --- and to the 80 ns the bus specification puts on a master, which is
# what `rtl/plumbing/xilinx7/cadr_ddr.xdc` relaxes the adapter's address registers on.
PROVE_SRC := rtl/plumbing/cadr_prove.sv rtl/plumbing/cadr_axi_master.sv rtl/plumbing/cadr_axi_widen.sv \
             tb/cadr_prove_harness.sv

$(BUILD)/obj_prove/Vcadr_prove_harness: $(PROVE_SRC) tb/cadr_prove_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_prove \
	    --top-module cadr_prove_harness $(PROVE_SRC) \
	    $(abspath tb/cadr_prove_tb.cpp)

$(BUILD)/prove.pass: $(BUILD)/obj_prove/Vcadr_prove_harness
	$(BUILD)/obj_prove/Vcadr_prove_harness
	@touch $@

# -------------------------------------------------------------- memory path

# The pieces running together: decode, bus interface and DDR bridge, from the
# same trace. Checked two ways --- the timing still agrees with muir, and a read
# returns the word an earlier write put there.
#
# **`cadr_spy_registers.sv` AND `cadr_dbgin.sv` ARE NAMED HERE THOUGH VERILATOR
# WOULD FIND THEM ANYWAY.**  `cadr_memory_path.sv` instantiates both and `-I`
# resolves a module by its file name, so leaving them out built a correct
# binary that make believed was current when either file changed.  That was
# harmless while nothing drove them from outside; `build/unibus.pass` drives
# the debug cable through `cadr_dbgin.sv` now, so a prerequisite that is not
# listed is a check that silently runs yesterday's module.  Same family as the
# build artifact carrying the old machine's PROM path.
MEMPATH := rtl/plumbing/cadr_ddr_map.sv rtl/machine/cadr_xbus_decode.sv rtl/machine/cadr_busint_xbus.sv \
           rtl/plumbing/cadr_xbus_ddr.sv rtl/machine/cadr_tv.sv rtl/machine/cadr_console_bus.sv \
           rtl/machine/cadr_io_board.sv rtl/machine/cadr_busint_regs.sv \
           rtl/machine/cadr_spy_registers.sv rtl/machine/cadr_dbgin.sv \
           rtl/machine/cadr_memory_path.sv

$(BUILD)/obj_memory_path/Vcadr_memory_path: $(MEMPATH) tb/cadr_memory_path_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_memory_path \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_memory_path $(MEMPATH) $(abspath tb/cadr_memory_path_tb.cpp)

$(BUILD)/memory_path.pass: $(BUILD)/obj_memory_path/Vcadr_memory_path $(BUILD)/busint_xbus.golden $(BUILD)/sync_prom.hex
	$(BUILD)/obj_memory_path/Vcadr_memory_path $(BUILD)/busint_xbus.golden
	@touch $@

# ---------------------------------------------------------------- the display

# The display controller --- the TV --- against muir's own `simpletv::SimpleTv`
# driven through `busint::Busint`: `golden/src/tv.rs` is a scripted program,
# because neither reference program touches a control register of it, and it
# reaches the register face, the sync RAM, the vertical interrupt at every
# tick of twenty-five frames, and the frame buffer as a window into DDR.
#
# THE DUT IS `cadr_memory_path`, NOT A HARNESS: `rtl/machine/cadr_tv.sv` is
# instantiated inside it, its frame buffer being that module's bridge at the
# display's base, so the wiring checked is the wiring on the board.  Same
# sources as `memory_path`, another trace and another testbench; the modeled
# DDR answers at once so that the timing is comparable with muir, whose TV
# takes no time of its own.
#
# The trace is 77 million ticks --- twenty-five frames, because a write
# landing on the very tick a frame begins first becomes reachable at the
# twenty-fifth --- and takes a minute or so.
$(BUILD)/tv.golden: golden/src/tv.rs golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin tv > $@

# **AND THE SAME PROGRAM ON THE OTHER BOARD.**  muir has one display model
# and `--tv-board` says which board it is playing; the two differ in one bit
# a bus cycle can see, mode bit 7, so the two traces are the same program and
# part only on reads of the mode register with the sync RAM selected.  The
# testbench straps the fabric from the trace's own header, so a trace and a
# strap cannot be paired wrongly.
$(BUILD)/tv_lispm.golden: golden/src/tv.rs golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin tv -- lispm-tv > $@

$(BUILD)/obj_tv/Vcadr_memory_path: $(MEMPATH) tb/cadr_tv_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_tv \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_memory_path $(MEMPATH) $(abspath tb/cadr_tv_tb.cpp)

$(BUILD)/tv.pass: $(BUILD)/obj_tv/Vcadr_memory_path $(BUILD)/tv.golden \
                  $(BUILD)/tv_lispm.golden $(BUILD)/sync_prom.hex
	$(BUILD)/obj_tv/Vcadr_memory_path $(BUILD)/tv.golden $(BUILD)/tv_lispm.golden
	@touch $@

# ------------------------------------------------------- the second display

# The color TV --- MIT's second display board, `lmtv.order`'s "for the color
# TV, x is 5" --- against muir's `tv::Tv::color()` on a backplane that also
# carries the first board.  Two instances of `rtl/machine/cadr_tv.sv` at two
# straps, two windows in DDR, one `-XBUS.INTR` between them, and the color
# map, which is write only on the bus and is read out of the fabric's own map
# port.  Configuration B is the backplane with no second board, which is what
# `COLOR-EXISTS-P` probes for.
$(BUILD)/color_tv.golden: golden/src/color_tv.rs golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin color_tv > $@

$(BUILD)/obj_color_tv/Vcadr_memory_path: $(MEMPATH) tb/cadr_color_tv_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_color_tv \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_memory_path $(MEMPATH) $(abspath tb/cadr_color_tv_tb.cpp)

$(BUILD)/color_tv.pass: $(BUILD)/obj_color_tv/Vcadr_memory_path $(BUILD)/color_tv.golden \
                        $(BUILD)/sync_prom.hex
	$(BUILD)/obj_color_tv/Vcadr_memory_path $(BUILD)/color_tv.golden
	@touch $@

# --------------------------------------------------------------- the I/O board

# The I/O board --- MIT's own name for the card, the keyboard, the mouse, the
# two clocks and their status register on the Unibus --- against muir's own
# `ioboard::IoBoard`.  `golden/src/iob.rs` is a scripted program, because
# neither reference program asks anything of the card: measured, MIT's boot
# PROM never addresses it at all in 600,000 microcycles, and a System 100
# band reaches three of its registers in 271 bus cycles of 141,849 --- one
# read of the status register, 135 reads of each half of the microsecond
# counter, and one write of the keyboard's interrupt enable.
#
# `docs/io-board.md` says what each slice builds and what seam it hangs on.
#
# The trace is 81 million ticks --- 404 ms of the card's own time, which is
# what it takes for the microsecond counter to carry into its high half twice
# and for fourteen boundaries of the sixty-cycle clock to be read on
# alternating sides --- and the generator takes about a second.  It asserts as
# it runs: time never runs backwards, every instant is a multiple of five
# nanoseconds, every register the decoder names is reached, all two hundred
# phases of `-UB MSYN` inside the card's microsecond are used, the mouse's
# counters wrap both ways and take over two hundred values each, the scan
# codes cover all twenty-four bits and no two are alike, and each of the three
# reachable interrupt vectors is asked for.
.PHONY: iob-golden
iob-golden: $(BUILD)/iob.golden

$(BUILD)/iob.golden: golden/src/iob.rs golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin iob > $@

# Slice two: the card itself, one module and one testbench at the Unibus seam,
# as the disk controller's check lives at its four registers.  The run replays
# the whole trace tick for tick, then sweeps the decode over all 262,144
# addresses in both directions with a real bus cycle each, then holds the
# priority chain to page IOBINT's own equations --- which is the only part no
# trace against this model can reach, the Chaosnet interface being `None`
# unless one is plugged in.
$(BUILD)/obj_iob/Vcadr_io_board: rtl/machine/cadr_io_board.sv tb/cadr_io_board_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Mdir $(BUILD)/obj_iob \
	    --top-module cadr_io_board rtl/machine/cadr_io_board.sv $(abspath tb/cadr_io_board_tb.cpp)

$(BUILD)/iob.pass: $(BUILD)/obj_iob/Vcadr_io_board $(BUILD)/iob.golden
	$(BUILD)/obj_iob/Vcadr_io_board $(BUILD)/iob.golden
	@touch $@

# ----------------------------------- the bus interface's own Unibus registers

# The interrupt block at `0o766040`-`0o766076` and the Unibus map at
# `0o766140`-`0o766176`, against muir's own `busint::register` and
# `Machine::interface_read` and `interface_write`.  `golden/src/busint_regs.rs`
# is a scripted program for `iob.rs`'s reason: MIT's boot PROM reaches this
# block once in 600,000 microcycles and that once is the mode register in the
# DIAGNOSTIC group, which is `cadr_spy_registers.sv`; a System 100 band
# reaches `0o766040` 240 times and neither `0o766044` nor any map register at
# all, and the band trace runs against `Vcadr_microcycle`, where the memory
# path is stimulus.
#
# `rtl/machine/cadr_busint_regs.sv` says what each register is and what is
# deliberately not built --- the map's read and write buffers, `UB MAP ERROR`
# and the debug block, all three of which have the debug cable as their one
# master.
#
# The run is a few seconds: 251 rows replayed with two face reads each, and
# then a real bus cycle at every one of the 524,288 addresses and directions
# an eighteen-bit `ub_addr` can carry.
.PHONY: busint-regs-golden
busint-regs-golden: $(BUILD)/busint_regs.golden

$(BUILD)/busint_regs.golden: golden/src/busint_regs.rs golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin busint_regs > $@

$(BUILD)/obj_busint_regs/Vcadr_busint_regs: rtl/machine/cadr_busint_regs.sv tb/cadr_busint_regs_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Mdir $(BUILD)/obj_busint_regs \
	    --top-module cadr_busint_regs rtl/machine/cadr_busint_regs.sv $(abspath tb/cadr_busint_regs_tb.cpp)

$(BUILD)/busint_regs.pass: $(BUILD)/obj_busint_regs/Vcadr_busint_regs $(BUILD)/busint_regs.golden
	$(BUILD)/obj_busint_regs/Vcadr_busint_regs $(BUILD)/busint_regs.golden
	@touch $@

# ------------------------------------------- the Unibus, with both its slaves

# Slice three: the card under the machine.  `iob.pass` above holds the card at
# its own seam, with a Unibus master in the testbench.  This holds the
# composition: the machine's own memory cycle arbitrating for the Unibus,
# putting the strobe out with the address the map produced, taking the card's
# answer back and turning it into -MEMACK and -LOADMD, and the word the card
# drove arriving on MEM<15:0>.
#
# THE DUT IS `cadr_memory_path`, as it is for the display, because the card is
# instantiated inside it and the wiring checked is the wiring the board has.
#
# **NO OTHER CHECK RUNS A UNIBUS READ.**  Measured: MIT's boot PROM runs one
# Unibus cycle in 17,466 and it is the write of the mode register, so
# `cadr_busint_xbus.sv`'s MD strobe --- the one instant on either bus where the
# word and the acknowledgment come apart --- had never carried a word anybody
# compared.
#
# The reference is `iob.golden`, for its decode table: that trace carries
# `ioboard::answers` for all 262,144 Unibus addresses in both directions, which
# is what says which of these cycles must be answered and by whom.  Everything
# else the run compares is its own stimulus.  About twenty seconds, most of it
# the 13.1 million ticks the microsecond counter takes to carry into its high
# half.
$(BUILD)/obj_unibus/Vcadr_memory_path: $(MEMPATH) tb/cadr_unibus_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_unibus \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_memory_path $(MEMPATH) $(abspath tb/cadr_unibus_tb.cpp)

$(BUILD)/unibus.pass: $(BUILD)/obj_unibus/Vcadr_memory_path $(BUILD)/iob.golden \
                      $(BUILD)/busint_regs.golden $(BUILD)/sync_prom.hex
	$(BUILD)/obj_unibus/Vcadr_memory_path $(BUILD)/iob.golden $(BUILD)/busint_regs.golden
	@touch $@

# ------------------------------------------------------------------ DDR map

# Constants only, and shared with the Linux side, so all lint can do is prove
# they elaborate. What keeps them honest is that they are in one place.
$(BUILD)/ddr_map.pass: rtl/plumbing/cadr_ddr_map.sv rtl/machine/cadr_xbus_decode.sv | $(BUILD)
	$(VERILATOR) --lint-only -Wall --top-module cadr_xbus_decode \
	    rtl/plumbing/cadr_ddr_map.sv rtl/machine/cadr_xbus_decode.sv
	@touch $@

# ------------------------------------------------------------ address decode

# Checked at every one of the 4,194,304 addresses the 22-bit Xbus can carry,
# for each board count, so the reference is written as runs and expanded.
$(BUILD)/xbus_decode.golden: golden/src/xbus_decode.rs golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin xbus_decode > $@

$(BUILD)/obj_xbus_decode/Vcadr_xbus_decode: rtl/machine/cadr_xbus_decode.sv tb/cadr_xbus_decode_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Mdir $(BUILD)/obj_xbus_decode \
	    --top-module cadr_xbus_decode rtl/machine/cadr_xbus_decode.sv $(abspath tb/cadr_xbus_decode_tb.cpp)

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

# And MIT's TV sync PROM, `cadrtv/cpt.prom`, the same way and for the same
# reason: the display runs that program from power-on until the software loads
# the RAM and selects it, and MIT's material is muir's to carry.
$(BUILD)/sync_prom.hex: golden/src/sync_prom.rs golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin sync_prom > $@

MICROCYCLE := rtl/machine/cadr_phase_gen.sv rtl/machine/cadr_microcycle.sv

# The PROM image is named at verilation, absolute, rather than left to the
# module's relative default: $$readmemh resolves against the working directory,
# so a model built with the default runs only from the repository root with the
# default BUILD, and elaborates a control store of x's anywhere else.
$(BUILD)/obj_microcycle/Vcadr_microcycle: $(MICROCYCLE) tb/cadr_microcycle_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Mdir $(BUILD)/obj_microcycle \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    --top-module cadr_microcycle $(MICROCYCLE) $(abspath tb/cadr_microcycle_tb.cpp)

$(BUILD)/microcycle.pass: $(BUILD)/obj_microcycle/Vcadr_microcycle \
                          $(BUILD)/rtl.golden $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_microcycle/Vcadr_microcycle $(BUILD)/rtl.golden
	@touch $@

# ------------------------------------------------- the clock control register
#
# What a console does to a halted machine: step it, and force a
# microinstruction into IR to read a scratchpad with. `golden/src/sstep.rs`
# scripts muir's own `rtl` engine the way CC does --- `CC-CLOCK`, then
# `CC-NOOP-DEBUG-CLOCK` and `CC-DEBUG-CLOCK` over a debug IR --- and this
# compares the fabric row for row against it, every column read back through
# `spy_eadr`/`spy_rdata`.
#
# **IT IS THE PROCESSOR ALONE AND NOT THE COMPOSED MACHINE, ON PURPOSE.** The
# five bits of the clock control register are ports of `cadr_microcycle.sv`,
# as the mode register's bits already were; the register that HOLDS them is
# `cadr_spy_registers.sv` and what lands its word at the machine's next look
# is `build/console.pass`'s. So this check holds what the processor does with
# the bits once they are there, which is the half no reference program could
# ever reach: MIT's boot PROM never writes the register and neither does any
# band, the register being the console's.
#
# It shares `MICROCYCLE` and the PROM image with `microcycle.pass` and takes
# under a second: the script is a few dozen master clocks after a short
# warm-up.
$(BUILD)/sstep.golden: golden/src/sstep.rs golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin sstep > $@

$(BUILD)/obj_sstep/Vcadr_microcycle: $(MICROCYCLE) tb/cadr_sstep_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Mdir $(BUILD)/obj_sstep \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    --top-module cadr_microcycle $(MICROCYCLE) $(abspath tb/cadr_sstep_tb.cpp)

$(BUILD)/sstep.pass: $(BUILD)/obj_sstep/Vcadr_microcycle \
                     $(BUILD)/sstep.golden $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_sstep/Vcadr_microcycle $(BUILD)/sstep.golden
	@touch $@

# ------------------------------------------------------- the whole machine

# The processor and the memory path joined by the cables. Both halves have
# their own checks and pass them; this is the one that asks them to agree with
# each other about a single cycle. MD is no longer a column of the trace: it
# is the word the fabric's own bus interface strobes into it, at the instant
# that interface says, and the stall timing has to come out right with the
# real interface underneath.
#
# `rtl/machine/cadr_disk_controller.sv` is in the list because it is instantiated
# inside `cadr_machine`, which is where the boot PROM's 16,951 device cycles
# now land: they used to be answered from the trace by the testbench, and that
# line is gone. It joins `nomem`, `ddr_boot`, `mem_count`, `arty` and `probe`
# through this variable, all of which build the whole machine.
MACHINE := rtl/machine/cadr_phase_gen.sv rtl/machine/cadr_microcycle.sv rtl/plumbing/cadr_ddr_map.sv \
           rtl/machine/cadr_xbus_decode.sv rtl/machine/cadr_busint_xbus.sv rtl/plumbing/cadr_xbus_ddr.sv \
           rtl/machine/cadr_spy_registers.sv rtl/machine/cadr_disk_controller.sv rtl/machine/cadr_tv.sv \
           rtl/machine/cadr_io_board.sv rtl/machine/cadr_busint_regs.sv \
           rtl/machine/cadr_console_bus.sv rtl/machine/cadr_console_state.sv \
           rtl/machine/cadr_dbgin.sv \
           rtl/plumbing/cadr_bus_audit.sv \
           rtl/machine/cadr_memory_path.sv rtl/machine/cadr_machine.sv

# `M_AXI_GP0` split five ways: the decode, the AXI3 register face the three
# card faces share, and the far ends of the I/O board's four cables.  Named
# once, because it goes on every board that brings the port out --- the disk
# board and both proving boards --- and a list that is not named once is a
# list that drifts.
GP0 := rtl/plumbing/cadr_gp0_split.sv rtl/plumbing/cadr_gp_regs.sv \
       rtl/plumbing/cadr_chaos_cable.sv rtl/plumbing/cadr_serial_line.sv \
       rtl/plumbing/cadr_input_cables.sv

# `M_AXI_GP1` split three ways: the decode, and the console and the debug
# cable's carrier behind it.  Named here beside GP0's for the same reason ---
# every board that brings the port out takes it --- and named HERE rather than
# beside its own check because `:=` is expanded where it is read and
# `arty.pass`'s prerequisites are read before that.
GP1 := rtl/plumbing/cadr_gp1_split.sv

# MIT's debug cable on the two Pmod headers: the carrier and the join that
# lets the connector and the window share one DBGIN page.  Named here for the
# same reason GP0 and GP1 are, and it goes on EVERY board rather than only the
# ones with a processing system, because the pins are the top level's and a
# top-level output nothing drives is a PINMISSING.  Not in `$(MACHINE)`:
# `cadr_machine` does not instantiate either of them, and a check that builds
# a module nothing in it reaches is a check with a source it cannot mutate.
DBGPMOD := rtl/plumbing/cadr_dbg_tx.sv rtl/plumbing/cadr_dbg_rx.sv \
           rtl/plumbing/cadr_dbg_join.sv rtl/plumbing/cadr_dbg_cable.sv

# The display output, named here beside the others for the same reason the
# note above gives: `:=` is expanded where it is read and `arty.pass`'s
# prerequisites are read before the rules further down.  The phy is last
# because it is the only one of the three that needs the primitive stubs.
DISPLAY := rtl/plumbing/cadr_display_out.sv rtl/plumbing/cadr_tmds_encode.sv \
           rtl/plumbing/cadr_hdmi_tx.sv rtl/plumbing/xilinx7/cadr_hdmi_phy.sv

# The Xilinx primitives every board instantiates, as shells, so that a top
# level can be elaborated and linted.  Two files and not one: the first says
# of itself that nothing in it models anything and that lint is all it is for,
# and the second returns a value, which is the only behavior
# `USR_ACCESSE2` has.  Named here for the reason GP0, GP1 and DISPLAY are
# named here --- `:=` is expanded where it is read and `arty.pass`'s
# prerequisites are read before the rules further down.  **Neither may move
# to `rtl/`**: the board flows glob that tree and would hand synthesis a stub
# in place of a primitive, which is a board that reports a build compiled in
# rather than the one in its own bitstream.
BOARD_STUBS := tb/cadr_arty_stubs.sv tb/cadr_usr_access_stub.sv

$(BUILD)/obj_machine/Vcadr_machine: $(MACHINE) tb/cadr_machine_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_machine \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE) $(abspath tb/cadr_machine_tb.cpp)

$(BUILD)/machine.pass: $(BUILD)/obj_machine/Vcadr_machine \
                       $(BUILD)/rtl.golden $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_machine/Vcadr_machine $(BUILD)/rtl.golden
	@touch $@

# ------------------------------------------------- the machine behind memory

# The machine with a modeled DDR3 behind `mem_*`, which is what `DDR=1` puts
# on the part. The one check here that muir cannot back past microcycle
# 537,900 --- muir has a modeled disk controller and the board has none --- so
# its reference is the boot PROM's own page-0 parity loop, poisoned from
# outside, and what the machine may NOT do with what it reads.
#
# It runs the machine twice, 200 ms of machine time each way, and takes about
# twenty seconds.
$(BUILD)/obj_ddr_boot/Vcadr_machine: $(MACHINE) tb/cadr_ddr_boot_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_ddr_boot \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE) $(abspath tb/cadr_ddr_boot_tb.cpp)

$(BUILD)/ddr_boot.pass: $(BUILD)/obj_ddr_boot/Vcadr_machine $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_ddr_boot/Vcadr_machine
	@touch $@

# ------------------------------------------ the boot lines, on the whole machine

# **THE KEYBOARD BOOTS THE MACHINE, AND SO DOES THE LIGHT PANEL'S BUTTON.**
# `iob.pass` above holds the card's own decode of the keyboard's boot word
# against muir --- which eight bits the 25LS2521 at IOBCSR 0A20 compares, and
# how wide a pulse it makes of a match --- and says nothing about what the
# pulse reaches.  This is the other half: `cadr_machine` running MIT's boot
# PROM, a word at the keyboard's cable, and the PROM running from word 0
# again.  muir's own `tests/keyboard_boot.rs` is the same claim on `micro`,
# `rtl` and `chip`.
#
# No memory is modeled, deliberately: the PROM's first main-memory cycle is
# at microcycle 536,303 and nothing here runs that far.  It takes a second.
$(BUILD)/obj_kbd_boot/Vcadr_machine: $(MACHINE) tb/cadr_kbd_boot_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_kbd_boot \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE) $(abspath tb/cadr_kbd_boot_tb.cpp)

$(BUILD)/kbd_boot.pass: $(BUILD)/obj_kbd_boot/Vcadr_machine $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_kbd_boot/Vcadr_machine
	@touch $@

# ------------------------------ the state the machine comes up in

# **THE NO-AUTO-BOOT SWITCH: A CADR WHOSE BUTTON HAS NOT BEEN PRESSED.**  The
# check above holds the three boot lines; this one holds the other half of the
# same page of MIT's drawings, which is what `RUN` is at reset.  A CADR whose
# power has just come on has `RUN` clear and runs nothing, and the button is
# what starts it --- muir's `--no-auto-boot` in its own words.  On this board
# SW0 says which of the two states the machine comes up in.
#
# What it holds: the machine retires no microcycle at all with the switch on,
# `-BOOT2` starts the PROM from word 0 and it goes on running at the rate the
# control measured, and the switch is read AT RESET and at no other instant ---
# both directions of that, since a fabric taking the level live one way round
# passes one of the two cases alone.
#
# No memory, for the check above's reason.  It takes about a second.
$(BUILD)/obj_no_auto_boot/Vcadr_machine: $(MACHINE) tb/cadr_no_auto_boot_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_no_auto_boot \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE) $(abspath tb/cadr_no_auto_boot_tb.cpp)

$(BUILD)/no_auto_boot.pass: $(BUILD)/obj_no_auto_boot/Vcadr_machine $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_no_auto_boot/Vcadr_machine
	@touch $@

# ------------------------------------------------------ LD5, the blue lamp

# **`-PROMENABLE` AT PCTL 1C19, WHICH THE BLUE LAMP SHOWS.**  All three boards
# drive that lamp from the net itself rather than from the mode register's
# `PROMDISABLE` bit, and the two agree almost everywhere --- which is the trap.
# A board's top level is reached by `arty.pass`'s lint and by nothing else, so
# what can be held is the net as `cadr_machine` presents it at its port: up on
# a fetch, down on the control-store writes the PROM's own clearing pass makes,
# and dark for good once `PROMDISABLE` is set over the console's Unibus port.
# The identity is asserted on every tick of both phases and both states are
# counted, so neither claim is a window that caught the right instant.
#
# No memory, for `kbd_boot`'s reason: the PROM's first main-memory cycle is at
# microcycle 536,303 and nothing here runs that far.  It takes a few seconds.
$(BUILD)/obj_promenable/Vcadr_machine: $(MACHINE) tb/cadr_promenable_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_promenable \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE) $(abspath tb/cadr_promenable_tb.cpp)

$(BUILD)/promenable.pass: $(BUILD)/obj_promenable/Vcadr_machine $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_promenable/Vcadr_machine
	@touch $@

# ---------------------------------------------------------------- LD4

# **THE LAMP THAT SAYS THE MACHINE FELL OVER.**  Four lines of fabric, and a
# module rather than four lines in the top level because the top level is
# reached by `arty.pass`'s lint and by nothing else --- and lint cannot tell a
# lamp that latches from one that does not.  What this holds: dark at reset and
# while the machine runs, lit by `ERRHALT`, still lit when `ERRHALT` goes away,
# out at `-BOOT` and at a reset, not lit under a held button, and lit again at
# the next halt.  Which signal the board wires to it is the top level's and
# stays lint-only; the claim that nothing else lights it is the port list.
$(BUILD)/obj_errhalt_lamp/Vcadr_lamp_errhalt: rtl/plumbing/cadr_lamp_errhalt.sv \
                                              tb/cadr_lamp_errhalt_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -Mdir $(BUILD)/obj_errhalt_lamp \
	    --top-module cadr_lamp_errhalt rtl/plumbing/cadr_lamp_errhalt.sv \
	    $(abspath tb/cadr_lamp_errhalt_tb.cpp)

$(BUILD)/errhalt_lamp.pass: $(BUILD)/obj_errhalt_lamp/Vcadr_lamp_errhalt
	$(BUILD)/obj_errhalt_lamp/Vcadr_lamp_errhalt
	@touch $@

# --------------------------------------- the map, read through a real memory

# `machine.pass` and `ddr_boot.pass` each hold half of what a map does and
# neither holds the join.  There the word `mem_rdata` carries is muir's own MD
# column keyed by the ROW, so it is right whatever address the map produced and
# a mistranslation is invisible; here it is fetched from a store keyed by
# `mem_addr`.  `ddr_boot` has a real store and no muir reference at all, so it
# cannot compare -VMAOK, MD or the instant of anything.
#
# The boot PROM does write a second-level map entry and read through it:
# `SET-UP-FOUR-PAGES` writes four at microcycles 536,290 to 536,299, each from
# no access to MAP-ACCESS-CODE 3, and the first bus cycle is at 536,302 ---
# twelve microcycles after the first and three after the last.  That is
# `PDL-BUFFER-REFILL`'s own shape, which is where the board halted on
# 2026-09-10, and the testbench re-derives the gap from the trace at every run
# so that a reference which stopped exercising it says so.
#
# Page 0 holds what muir's memory holds --- zero --- so the comparison against
# muir is exact with no exemption anywhere; every other address holds a poison
# injective in it, so a read the map sends a page wide takes a word muir never
# had.  Thirteen seconds, the same 600,000 microcycles as `machine.pass`.
$(BUILD)/obj_map_boot/Vcadr_machine: $(MACHINE) tb/cadr_map_boot_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_map_boot \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE) $(abspath tb/cadr_map_boot_tb.cpp)

$(BUILD)/map_boot.pass: $(BUILD)/obj_map_boot/Vcadr_machine \
                        $(BUILD)/rtl.golden $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_map_boot/Vcadr_machine $(BUILD)/rtl.golden
	@touch $@

# ------------------------------ the whole machine on a band, with a real pack

# `cadr_machine` from reset against the SYSTEM trace rather than the boot
# PROM's, with a real memory keyed by `mem_addr`, a drive on the cable and a
# real System 100 pack behind the block store's seam.  1,062,507 microcycles
# agree exactly, the two clocks the same to the nanosecond throughout, and
# 524,650 of them are past the point where this trace and the boot PROM's part
# company --- a program no other check runs on the whole machine, with the disk
# controller answering out of a real drive instead of the no-drive constant.
#
# **IT STOPS AT THE MACHINE'S FIRST DISK TRANSFER AND IT CANNOT BE MADE NOT
# TO.**  muir's channel writes main memory directly and finishes at the instant
# it starts; the fabric's is a second Xbus master.  `tb/cadr_band_tb.cpp`'s
# header has the three ways round it that were built and measured, and
# `docs/band.md` has the account and what would close it.  The run asserts the
# floor, the clocks and the pack's seam, and prints where it ends and why.
#
# **PHONY, AND NOT YET IN `check`.**  A `.pass` file here would make
# `mutations/run.py`'s `check_makefile` report a check that nothing mutates,
# and aiming a record at it first needs an entry in that runner's `CHECKS` ---
# which is the booby trap in it, a record naming a check the runner has no
# entry for killing the whole run at parse.  Promoting this is those two
# changes together, and `docs/band.md` writes both of them out.
#
# It skips, and says so, when the System 100 release is not here, as its
# neighbors do; the sum is checked before the archive is used and the pack is
# decompressed fresh for the run and removed after.  Twenty-five seconds.
$(BUILD)/obj_band/Vcadr_machine: $(MACHINE) tb/cadr_band_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_band \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE) $(abspath tb/cadr_band_tb.cpp)

.PHONY: band
band: $(BUILD)/obj_band/Vcadr_machine $(BUILD)/rtl_sys.golden $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	@if [ ! -f $(SYS100_GZ) ]; then \
	    echo "band: skipped --- no System 100 release; muir's tools/fetch-system-100.sh fetches it"; \
	else \
	    set -e; \
	    echo "$(SYS100_SHA)  $(SYS100_GZ)" | sha256sum -c --quiet - \
	        || { echo "band: $(SYS100_GZ) is not the release this trace was measured against"; exit 1; }; \
	    trap 'rm -f $(BUILD)/band-pack.img' EXIT; \
	    gunzip -c $(SYS100_GZ) > $(BUILD)/band-pack.img; \
	    $(BUILD)/obj_band/Vcadr_machine $(BUILD)/rtl_sys.golden --pack $(BUILD)/band-pack.img; \
	fi

# ------------------------------- the whole machine, run at the board's fault

# `hash-watch` is `band` run free rather than compared, with four instruments
# on it: a watchpoint on one physical word, a transaction counter per bus
# cycle, an invariant that no write goes out that the processor did not ask
# for, and a count of the lit pixels on the screen.  It exists because the
# board halts at about 169 million microcycles with one word of MIT's page
# hash table holding the faulting virtual address instead of a page table
# word, and the question was whether the fabric does that in simulation.
#
# **IT DOES NOT, and that is the result.**  Measured 12 Sep at `efeccac`: the
# machine boots to a painted screen at about 8 million microcycles, runs past
# 170,000,000 with no halt, `PC 0o23555` with `OPC 0o23560` occurs zero times,
# and `map2[777]` reads `000000` rather than `0x4FC9F9`.  The watchpoint sees
# `PGF-RWF` write the very word the board gets wrong, at the address the
# board's own arithmetic named, and get it right.  Over 12,039,354 bus cycles
# not one carried more than one transaction and not one write went out with
# WRCYC down.
#
# So the defect is NOT in `rtl/machine/`, and what this harness replaces with
# a model is where it must be: `cadr_axi_master`, `cadr_axi_widen`, the PS7
# and the DDR3 controller on one side, and `cadr_disk_pack.sv` with
# `S_AXI_HP2` and the Linux program on the other.
#
# Not in `make check`: a run to the board's own fault is an hour of Verilator.
# `make band` is the check; this is the instrument.  `WATCH=<physical word in
# OCTAL>` names a word to report every transaction against, `STOP=<microcycles>`
# gives it a length, and `FREE=1` runs it without comparing --- which is what a
# run past the band trace's 2,800,000 rows needs.  The testbench's own header
# lists the rest of its flags.  A SHORT run needs `FLOOR=0`: the harness holds
# itself to the band's own 1,062,507-microcycle floor and to having fetched a
# block, and a run stopped before either is a failure by design rather than an
# instrument that quietly did nothing.
$(BUILD)/obj_hash_watch/Vcadr_machine: $(MACHINE) tb/cadr_hash_watch_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_hash_watch \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE) $(abspath tb/cadr_hash_watch_tb.cpp)

.PHONY: hash-watch
hash-watch: $(BUILD)/obj_hash_watch/Vcadr_machine $(BUILD)/rtl_sys.golden $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	@if [ ! -f $(SYS100_GZ) ]; then \
	    echo "hash-watch: skipped --- no System 100 release; muir's tools/fetch-system-100.sh fetches it"; \
	else \
	    set -e; \
	    echo "$(SYS100_SHA)  $(SYS100_GZ)" | sha256sum -c --quiet - \
	        || { echo "hash-watch: $(SYS100_GZ) is not the release this was measured against"; exit 1; }; \
	    trap 'rm -f $(BUILD)/hash-watch-pack.img' EXIT; \
	    gunzip -c $(SYS100_GZ) > $(BUILD)/hash-watch-pack.img; \
	    $(BUILD)/obj_hash_watch/Vcadr_machine $(BUILD)/rtl_sys.golden \
	        --pack $(BUILD)/hash-watch-pack.img \
	        $${WATCH:+--watch $$WATCH} $${STOP:+--stop-at $$STOP} \
	        $${FREE:+--free} $${FLOOR:+--floor $$FLOOR}; \
	fi

# ------------------ a pack block into main memory, through the whole path

# THE CHECK THE COMPOSITION HAD NEVER HAD.  `axi_master.pass` and
# `axi_widen.pass` hold each module alone; `mem_count.pass` and
# `bus_audit.pass` compose them over MIT's boot PROM with no drive on the
# cable, which is 512 identity memory cycles and no channel at all ---
# `tb/cadr_bus_audit_tb.cpp` asserts outright that the disk channel never took
# the bus.  So the second Xbus master had never crossed the widening, and
# nothing had ever read back through it what it wrote.
#
# This runs the boot PROM from reset WITH A DRIVE ON THE CABLE and a pack
# behind the block store's seam, so the cold boot's own `COLD-DISK-READ`
# happens: a CCW list, blocks into consecutive physical pages, 256 bus cycles
# a page, every word crossing `cadr_axi_master` and `cadr_axi_widen` into a
# 64-bit AXI3 slave.  The pack is synthetic, generated a block at a time, and
# its words are POISON INJECTIVE IN THE DISK ADDRESS AND DECODABLE --- so a
# page of main memory can be read back and decoded without the testbench being
# told where the walk put it.
#
# The strongest of its seven clauses is that one: a page the channel filled
# must decode as one block of the pack, words 0 to 255 in order, whose disk
# address the feeder actually served.  A dropped address bit, a half-select
# that went the wrong way, a duplicated word and a reordered word are all
# visible there and in no other check here.
#
# It stops as soon as three transfers have been made, so nothing in it depends
# on what the machine does with a microcode band that is poison.  About half a
# million microcycles.
AXI_CHANNEL_SRC := $(MACHINE) rtl/plumbing/cadr_axi_master.sv \
                   rtl/plumbing/cadr_axi_widen.sv tb/cadr_band_axi_harness.sv

$(BUILD)/obj_axi_channel/Vcadr_band_axi_harness: $(AXI_CHANNEL_SRC) \
                                                 tb/cadr_axi_channel_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_axi_channel \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_band_axi_harness $(AXI_CHANNEL_SRC) \
	    $(abspath tb/cadr_axi_channel_tb.cpp)

$(BUILD)/axi_channel.pass: $(BUILD)/obj_axi_channel/Vcadr_band_axi_harness \
                           $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_axi_channel/Vcadr_band_axi_harness
	@touch $@

# ------------------- the same run, with the adapter and the widening in it

# `band-axi` is `hash-watch` with the memory model moved one boundary further
# out.  There the word store answers `mem_done`/`mem_rdata` directly, so
# `cadr_axi_master`, `cadr_axi_widen` and everything the 64-bit beat's byte
# strobes decide are OUTSIDE the DUT; here they are inside it and the model is
# `S_AXI_HP0`'s own AXI3 slave.
#
# WHY IT EXISTS.  `hash-watch` established that the board's page-hash-table
# defect is not in `rtl/machine/`: 171,000,000 microcycles, the fingerprint
# zero times, `PGF-RWF` writing the very word correctly.  What that harness
# replaces with a model is the only place left, and **no check in this tree had
# ever run a real program through it** --- `axi_master.pass` and
# `axi_widen.pass` hold each module alone, and `mem_count.pass` and
# `bus_audit.pass` compose them over MIT's boot PROM, which is 512 identity
# cycles with no drive on the cable and no channel at all.
#
# So `tb/cadr_band_axi_harness.sv` is those three modules wired as
# `boards/arty-z7-20/cadr_arty.sv`'s `g_ddr` wires them, WITH THE DISK SEAM
# BROUGHT OUT, and the band boots through it off a real pack.  The watchpoint
# is on the 64-BIT PORT: it reports the beat, its byte strobes, its 64 bits of
# data and the direction, so a half-select that went the wrong way is seen
# rather than inferred.
#
# Not in `make check`: a run to the board's own fault is an hour of Verilator.
# `$(BUILD)/axi_channel.pass` is the check this leaves behind.  `WATCH=<physical
# word in OCTAL>` names a word --- and `WATCH=100` is the calibration: physical
# `0o100` is READ at microcycle 536,687 and WRITTEN at 536,689 by the boot
# PROM's own parity loop, on the beat `0x18000100` that holds words `0o100` and
# `0o101`, with strobes `0f` for the even word and `f0` for the odd one.  The
# write lands two microcycles before the word store put it, and that difference
# is the instrument working rather than a discrepancy: the word store recorded
# a write at muir's own acknowledgment instant, while the AXI address channel
# takes the address as soon as the request rises and only the RESPONSE is held
# to that instant.  `STOP=<microcycles>` bounds the comparison,
# `OBSERVE=<microcycles>` runs that many past it, `FLOOR=0` is needed by any
# run stopped before the band's own 1,062,507-microcycle floor, and
# `PROGRESS=<n>` says where the machine is every n microcycles, `DELAY=<ticks>`
# charges the memory that much past the comparison, and `UNWRITTEN=<word>` is
# what a word of DDR nobody has written reads as there.
#
# **A SHORT RUN EXITS 1 AND THAT IS BY DESIGN**, as it is for `hash-watch`: the
# harness holds itself to the band's own 1,062,507-microcycle floor AND to
# having fetched a block from the pack at a disk address the controller posted.
# `FLOOR=0` waives the first; nothing waives the second, because a run that
# never reached the disk has not used the seam this harness exists to carry.
# The calibration run above is one of those, and its watch lines are the point
# of it rather than its exit code.
BAND_AXI_SRC := $(MACHINE) rtl/plumbing/cadr_axi_master.sv \
                rtl/plumbing/cadr_axi_widen.sv tb/cadr_band_axi_harness.sv

$(BUILD)/obj_band_axi/Vcadr_band_axi_harness: $(BAND_AXI_SRC) \
                                              tb/cadr_band_axi_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_band_axi \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_band_axi_harness $(BAND_AXI_SRC) \
	    $(abspath tb/cadr_band_axi_tb.cpp)

.PHONY: band-axi
band-axi: $(BUILD)/obj_band_axi/Vcadr_band_axi_harness $(BUILD)/rtl_sys.golden \
          $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	@if [ ! -f $(SYS100_GZ) ]; then \
	    echo "band-axi: skipped --- no System 100 release; muir's tools/fetch-system-100.sh fetches it"; \
	else \
	    set -e; \
	    echo "$(SYS100_SHA)  $(SYS100_GZ)" | sha256sum -c --quiet - \
	        || { echo "band-axi: $(SYS100_GZ) is not the release this was measured against"; exit 1; }; \
	    trap 'rm -f $(BUILD)/band-axi-pack.img' EXIT; \
	    gunzip -c $(SYS100_GZ) > $(BUILD)/band-axi-pack.img; \
	    $(BUILD)/obj_band_axi/Vcadr_band_axi_harness $(BUILD)/rtl_sys.golden \
	        --pack $(BUILD)/band-axi-pack.img \
	        $${WATCH:+--watch $$WATCH} $${STOP:+--stop-at $$STOP} \
	        $${OBSERVE:+--observe $$OBSERVE} $${PROGRESS:+--progress $$PROGRESS} \
	        $${UNWRITTEN:+--unwritten $$UNWRITTEN} \
	        $${DELAY:+--mem-delay $$DELAY} \
	        $${FLOOR:+--floor $$FLOOR}; \
	fi

# ----------------- a pack block through the pack side and into main memory

# THE CHECK THE PACK SIDE HAD NEVER HAD.  `axi_channel.pass` runs MIT's boot
# PROM with a drive on the cable and a pack behind the block store's seam, and
# holds that a page the channel filled decodes as a block the feeder served.
# But its feeder IS a testbench, writing 259 words into a slot a word at a
# time.  `rtl/plumbing/cadr_disk_pack.sv` --- the module that does that on the
# board, its `S_AXI_HP2` master and its `M_AXI_GP0` register face --- has never
# been INSTANTIATED in a whole-machine check anywhere in this tree;
# `disk_pack.pass` holds it to properties on a directed stimulus with no
# machine behind it.
#
# This is `axi_channel` with that module in the design.  The record now
# travels testbench -> DDR -> HP2 -> the block store -> the channel -> HP0 ->
# DDR, and the pack is still poison injective in the disk address and
# DECODABLE, so a page is decoded rather than compared against a shadow.  All
# eight of `axi_channel`'s clauses survive word for word, because they state
# properties of the words and not of who moved them; four more are added about
# the module itself, of which the one this was built for is that no beat of
# the pack side lands inside the machine's own main memory.  HP0 and HP2 are
# two doors into ONE array here, as they are into one DRAM on the board, so
# that fault is reachable rather than excluded by construction.
#
# It stops at three transfers for `axi_channel`'s reason: the label is poison
# and the PROM halts at `PC 0o26`, and a machine running poison as
# microinstructions is not a stimulus anybody can reason about.
PACK_CHANNEL_SRC := $(MACHINE) rtl/plumbing/cadr_axi_master.sv \
                    rtl/plumbing/cadr_axi_widen.sv \
                    rtl/plumbing/cadr_disk_pack.sv tb/cadr_pack_axi_harness.sv

$(BUILD)/obj_pack_channel/Vcadr_pack_axi_harness: $(PACK_CHANNEL_SRC) \
                                                  tb/cadr_pack_channel_tb.cpp \
                                                  tb/cadr_pack_linux.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -CFLAGS -I$(abspath tb) -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_pack_channel \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_pack_axi_harness $(PACK_CHANNEL_SRC) \
	    $(abspath tb/cadr_pack_channel_tb.cpp)

$(BUILD)/pack_channel.pass: $(BUILD)/obj_pack_channel/Vcadr_pack_axi_harness \
                            $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_pack_channel/Vcadr_pack_axi_harness
	@touch $@

# ------------------- the same run again, with the pack side as fabric

# THE LAST SIMULATABLE SEAM.  `hash-watch` cleared `rtl/machine/` over
# 171,000,000 microcycles and `band-axi` cleared the adapter and the widening
# over 13,000,000, and both of them PLAY the pack side: the block store's seam
# comes out of the harness and a testbench writes 259 words into a slot.
# `rtl/plumbing/cadr_disk_pack.sv` has never been INSTANTIATED in a
# whole-machine check anywhere in this tree --- `disk_pack.pass` holds it to
# properties on a directed stimulus with no machine behind it --- and
# `S_AXI_HP2` and the `cadr-disk-packs` program are outside all of it.
#
# `tb/cadr_pack_axi_harness.sv` is the band harness with that module between
# the machine and the testbench, wired as `boards/arty-z7-20/cadr_arty.sv`
# wires it, and `tb/cadr_pack_band_tb.cpp` is `tb/cadr_band_axi_tb.cpp` with
# the feeder replaced by Linux on `M_AXI_GP0` and an AXI3 slave on
# `S_AXI_HP2`.  Everything else about the two files is the same, so a
# difference between the two runs is about the pack side and nothing else.
#
# **THE TWO PORTS SHARE ONE MEMORY**, because on the board HP0 and HP2 are two
# doors into one DRAM: a pack-side master that wandered into the machine's own
# region therefore lands where the watchpoint can see it, rather than in a
# second array where the fault would be unreachable by construction.
#
# Not in `make check`, for `band-axi`'s reason: a run to the board's own fault
# is an hour of Verilator.  `$(BUILD)/pack_channel.pass` is the check this
# leaves behind.  The flags are `band-axi`'s, name for name.
PACK_BAND_SRC := $(MACHINE) rtl/plumbing/cadr_axi_master.sv \
                 rtl/plumbing/cadr_axi_widen.sv rtl/plumbing/cadr_disk_pack.sv \
                 tb/cadr_pack_axi_harness.sv

$(BUILD)/obj_pack_band/Vcadr_pack_axi_harness: $(PACK_BAND_SRC) \
                                               tb/cadr_pack_band_tb.cpp \
                                               tb/cadr_pack_linux.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -CFLAGS -I$(abspath tb) -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_pack_band \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_pack_axi_harness $(PACK_BAND_SRC) \
	    $(abspath tb/cadr_pack_band_tb.cpp)

.PHONY: pack-band
pack-band: $(BUILD)/obj_pack_band/Vcadr_pack_axi_harness $(BUILD)/rtl_sys.golden \
           $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	@if [ ! -f $(SYS100_GZ) ]; then \
	    echo "pack-band: skipped --- no System 100 release; muir's tools/fetch-system-100.sh fetches it"; \
	else \
	    set -e; \
	    echo "$(SYS100_SHA)  $(SYS100_GZ)" | sha256sum -c --quiet - \
	        || { echo "pack-band: $(SYS100_GZ) is not the release this was measured against"; exit 1; }; \
	    trap 'rm -f $(BUILD)/pack-band-pack$${TAG:-}.img' EXIT; \
	    gunzip -c $(SYS100_GZ) > $(BUILD)/pack-band-pack$${TAG:-}.img; \
	    $(BUILD)/obj_pack_band/Vcadr_pack_axi_harness $(BUILD)/rtl_sys.golden \
	        --pack $(BUILD)/pack-band-pack$${TAG:-}.img \
	        $${WATCH:+--watch $$WATCH} $${STOP:+--stop-at $$STOP} \
	        $${OBSERVE:+--observe $$OBSERVE} $${PROGRESS:+--progress $$PROGRESS} \
	        $${UNWRITTEN:+--unwritten $$UNWRITTEN} \
	        $${DELAY:+--mem-delay $$DELAY} \
	        $${FLOOR:+--floor $$FLOOR}; \
	fi

# ------------------------------------- the map's two access bits, told apart

# `map_boot.pass` compares a map entry written and then read through, and its
# own output says what it cannot reach: muir refuses the access on 0 of those
# 600,000 microcycles, and every map word MIT's boot PROM writes has bits 23
# and 22 alike, so `-VMAOK` is compared only in its permitted direction and the
# two access bits cannot be told apart.  That is the half the board halts in.
#
# The band cannot close it either, measured: `rtl_sys.golden`'s first refused
# access is at microcycle 2,084,533 and its first asymmetric map word at
# 2,088,933, where a whole-machine comparison has long stopped.
#
# So this check moves ONE field of ONE microinstruction of MIT's own boot PROM.
# At PROM address `0o274` the byte masker's mask IS the map word that
# `SET-UP-FOUR-PAGES` writes, so the mask's right edge is the access code, and
# moving it gives {1,1}, {1,0} and {0,0} with nothing else about the program
# changed.  The patched word and the four map entries are read back out of the
# machine over the console's readout window, so a patch that missed fails
# naming what it found rather than passing.  `tb/cadr_map_access_tb.cpp`'s
# header says what that costs and `docs/map-access.md` argues it.
#
# Four runs, three of 600,000 microcycles and one short, about a minute.
$(BUILD)/obj_map_access/Vcadr_machine: $(MACHINE) tb/cadr_map_access_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_map_access \
	    -GPROM_HEX='"$(abspath $(BUILD))/map_access_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE) $(abspath tb/cadr_map_access_tb.cpp)

$(BUILD)/map_access.pass: $(BUILD)/obj_map_access/Vcadr_machine \
                          $(BUILD)/rtl.golden $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_map_access/Vcadr_machine $(BUILD)/rtl.golden \
	    $(BUILD)/map_access_prom.hex $(BUILD)/boot_prom.hex
	@touch $@

# ------------------------------------------------- the memory port's tally

# `rtl/plumbing/cadr_mem_count.sv` is the board's only positive witness that the
# machine's memory cycles were answered, and an instrument nothing checks is
# worse than no instrument --- it will be read on a board, once, and believed.
# The boot PROM's memory traffic is an identity copy, so page 0 reading back
# unchanged says the same thing whether the port answered or was never brought
# up, and no lamp tells the two apart either.
#
# THE HARNESS AND NOT THE MODULE, because the claim is not that a counter
# counts: it is that the number a debugger reads says what happened, and that
# has the machine, the bridge, the adapter and the widening in it.
# `tb/cadr_mem_count_harness.sv` wires them as `boards/arty-z7-20/cadr_arty.sv`'s `g_ddr`
# does and brings out the 64-bit AXI3 port.
#
# TWO CONFIGURATIONS, and the second is the one the instrument exists for: the
# port held in reset, where the machine asks for exactly as much as it always
# does and NOTHING answers. A counter of the fabric's own intentions reads the
# same in both.
#
# It runs the machine twice, 200 ms of machine time each way.
MEM_COUNT_SRC := $(MACHINE) rtl/plumbing/cadr_axi_master.sv rtl/plumbing/cadr_axi_widen.sv \
                 rtl/plumbing/cadr_mem_count.sv tb/cadr_mem_count_harness.sv

$(BUILD)/obj_mem_count/Vcadr_mem_count_harness: $(MEM_COUNT_SRC) \
                                                tb/cadr_mem_count_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_mem_count \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_mem_count_harness $(MEM_COUNT_SRC) \
	    $(abspath tb/cadr_mem_count_tb.cpp)

$(BUILD)/mem_count.pass: $(BUILD)/obj_mem_count/Vcadr_mem_count_harness \
                         $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_mem_count/Vcadr_mem_count_harness
	@touch $@

# ------------------------------------------- one transaction per bus cycle

# THE CHECK THE BOARD'S OWN BUG HAS BEEN LIVING BEHIND.  The account of it
# establishes that a word in MIT's page hash table is the faulting virtual
# address rather than a page table word, that MD is exonerated by measurement,
# and therefore that main memory already held the wrong word --- so the
# corruption is a WRITE that should not have happened.  And
# `rtl/machine/cadr_microcycle.sv` loads `wdata` from MD at MEMGO regardless of
# direction, so on every read the whole of MD stands on `mem_wdata`: one
# unwanted write replaces a memory word with MD, at the read's own address.
#
# Nothing in this repository counted transactions per bus cycle.
# `axi_master.pass` counts handshakes per transaction, one level down, its
# stimulus being the transactions themselves; `mem_count.pass` counts
# transactions over a whole run and holds them to 256 and 256, which is the
# boot PROM's own arithmetic rather than a property.
#
# THE HARNESS AND NOT THE MODULE, and a harness of its own rather than the
# tally's: `tb/cadr_mem_count_harness.sv` brings `hp0_aresetn` out so that its
# check can make a DEAD port, and a dead port issues no transactions at all,
# which is the one configuration an audit of transactions per cycle has nothing
# to say about.
#
# It runs the machine once, 200 ms of machine time, about seventeen seconds.
BUS_AUDIT_SRC := $(MACHINE) rtl/plumbing/cadr_axi_master.sv \
                 rtl/plumbing/cadr_axi_widen.sv tb/cadr_bus_audit_harness.sv

$(BUILD)/obj_bus_audit/Vcadr_bus_audit_harness: $(BUS_AUDIT_SRC) \
                                                tb/cadr_bus_audit_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_bus_audit \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_bus_audit_harness $(BUS_AUDIT_SRC) \
	    $(abspath tb/cadr_bus_audit_tb.cpp)

$(BUILD)/bus_audit.pass: $(BUILD)/obj_bus_audit/Vcadr_bus_audit_harness \
                         $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_bus_audit/Vcadr_bus_audit_harness
	@touch $@

# ------------------------------------------- the same property, in fabric

# `rtl/plumbing/cadr_bus_audit.sv` is the property above carried onto the
# board: the check next door says it holds for MIT's boot PROM, which is the
# only program `cadr_machine` can run under Verilator and makes 512
# main-memory cycles, and the board's event is one in about a hundred and
# seventy-six million microcycles. So the same clauses are watched in fabric,
# for as long as the board runs, and reported through the console's readout
# window --- which is how anything inside `cadr_machine` is read on a halted
# board, over `M_AXI_GP1`, by `cadr-readout`, with nobody at the board.
#
# AN INSTRUMENT NOTHING CHECKS IS WORSE THAN NO INSTRUMENT: it will be read on
# a board, once, and believed. `mem_count.pass` carries that sentence and this
# is the same argument. The stimulus is DIRECTED and the DUT is the module
# alone, which is the opposite of the check above: a program cannot be made to
# fault on demand, so what each clause catches, which wins when two are true,
# what is captured and what the word reads have no stimulus there at all.
#
# **NOT WIRED INTO `cadr_machine` YET.** The module, its check and its
# mutations are one commit; the instantiation touches `cadr_machine.sv`,
# `cadr_memory_path.sv` and `rtl/plumbing/xilinx7/cadr_machine.xdc` and is
# another. The header of the module says exactly what that second commit has
# to do, the naming of three edge detectors as FAST among it.
BUS_AUDIT_UNIT_SRC := rtl/plumbing/cadr_bus_audit.sv

$(BUILD)/obj_bus_audit_unit/Vcadr_bus_audit: $(BUS_AUDIT_UNIT_SRC) \
                                             tb/cadr_bus_audit_unit_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -Mdir $(BUILD)/obj_bus_audit_unit \
	    --top-module cadr_bus_audit $(BUS_AUDIT_UNIT_SRC) \
	    $(abspath tb/cadr_bus_audit_unit_tb.cpp)

$(BUILD)/bus_audit_unit.pass: $(BUILD)/obj_bus_audit_unit/Vcadr_bus_audit
	$(BUILD)/obj_bus_audit_unit/Vcadr_bus_audit
	@touch $@

# --------------------------------------------- and the audit through the window

# THE JOIN, WHICH NOTHING HELD UNTIL THIS CHECK.  The two above hold the audit
# --- one clause by clause on the module alone, one as a property of the
# composed machine over MIT's boot PROM --- and `readout.pass` holds the
# console's window against the processor's own arrays.  What sits between them
# is `cadr_machine.sv` putting the audit ON that window at a selector of its
# own, and that is where a board reads it: over `M_AXI_GP1`, by `cadr-readout`,
# hours after the machine has stopped, with nobody at the board.
#
# The DUT is `cadr_machine` and the reference is the audit's own registers,
# reached by name --- `--public-flat-rw` for the same reason `readout.pass`
# takes it, that holding the window to itself would hold nothing.  What is
# asserted is the word, field by field; the marker on all sixteen; that the
# eleven selectors below it still come from the processor and the four above
# it still read `RO_NO_MEMORY`; and that a transaction the PORT answered which
# nobody asked for is latched, named and readable.  That last one is injected
# through `port_write_ack`, which is an input of `cadr_machine`: the boot
# PROM's first main-memory cycle is at microcycle 536,303 and a program cannot
# be made to fault on demand.
#
# It runs about 30,000 ticks and takes under a second.
$(BUILD)/obj_audit_window/Vcadr_machine: $(MACHINE) tb/cadr_audit_window_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 --public-flat-rw -Mdir $(BUILD)/obj_audit_window \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE) \
	    $(abspath tb/cadr_audit_window_tb.cpp)

$(BUILD)/audit_window.pass: $(BUILD)/obj_audit_window/Vcadr_machine \
                            $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_audit_window/Vcadr_machine
	@touch $@

# ------------------------------------------------- the machine with no memory

# Not a check: it asserts nothing and cannot fail. `tb/cadr_nomem_tb.cpp` runs
# the exact configuration `boards/arty-z7-20/cadr_arty.sv` puts on the board --- `mem_done`
# tied low, `mem_rdata` zero --- and prints what it measures. Every number in
# `docs/board.md`'s no-memory paragraph comes from it, and it dies with that
# paragraph.
#
# Phony deliberately. A `.pass` file would make `check_makefile` report a check
# that nothing mutates.
.PHONY: nomem
nomem: $(BUILD)/obj_nomem/Vcadr_machine $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_nomem/Vcadr_machine

$(BUILD)/obj_nomem/Vcadr_machine: $(MACHINE) tb/cadr_nomem_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_nomem \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE) $(abspath tb/cadr_nomem_tb.cpp)

# ------------------------------------------------------------- the top level

# `boards/arty-z7-20/cadr_arty.sv` is the only file with no check of any kind. It cannot be
# simulated --- Verilator has no `MMCME2_BASE` --- but it can be linted, and
# lint is what says the port list matches, that nothing is undriven, and that
# the `witness` fold really names every output of `cadr_machine`.
#
# The stubs are in `tb/` and must stay there: both vivado scripts read
# `[glob rtl/*/*.sv rtl/*/*/*.sv boards/arty-z7-20/*.sv]`, so a stub `MMCME2_BASE` in `rtl/` would replace the real
# primitive in synthesis and hand the board a wire where its clock generator
# belongs. `tb/cadr_arty_stubs.sv` says the same at greater length.
#
# THREE TIMES, BECAUSE THERE ARE THREE BOARDS. `PROBE_DEPTH` and `DDR` are
# both zero by default and the generate blocks that instantiate
# `rtl/plumbing/xilinx7/cadr_probe.sv`, `boards/arty-z7-20/cadr_ps7.sv` and `rtl/plumbing/cadr_axi_master.sv` are then
# not elaborated at all --- so a lint of the default says nothing whatever
# about the configurations `boards/arty-z7-20/vivado/probe.tcl` and `DDR=1` build and program.
# A branch only one build reaches is a branch only one build checks.
#
# The `DDR` pass is the only thing anywhere that elaborates `cadr_ps7.sv`
# without Vivado, and what it holds is that all 620 PS7 pins are connected:
# a pin the generator did not write is a PINMISSING against
# `tb/cadr_ps7_stub.sv`, which carries the same 620 off the same parse.  It
# is also the only pass that elaborates `rtl/plumbing/cadr_disk_pack.sv` under the top
# level, on the processing system's `S_AXI_HP2` and `M_AXI_GP0`.
#
# FIVE TIMES NOW, and `$(MACHINE)` COMES FIRST IN EVERY ONE. The top level
# takes the witness's address from `cadr_ddr_map::main_byte_address`, and a
# package has to be parsed before the file that reads it --- so the machine's
# sources, which carry the package, precede `boards/arty-z7-20/cadr_arty.sv` on every
# command line. `mutations/run.py`'s `arty_check` already ordered them that
# way; this is the two descriptions coming back into agreement.
#
# The two new boards are the ones `rtl/plumbing/cadr_prove.sv` builds: the fabric
# writing a word, and the fabric reading one back and writing it out again at
# a second address. They are a branch only those builds reach, and nothing
# else elaborates `cadr_prove.sv` at all.
$(BUILD)/arty.pass: $(MACHINE) boards/arty-z7-20/cadr_arty.sv rtl/plumbing/xilinx7/cadr_probe.sv \
                    boards/arty-z7-20/cadr_ps7.sv rtl/plumbing/cadr_axi_master.sv \
                    rtl/plumbing/cadr_axi_widen.sv rtl/plumbing/cadr_mem_count.sv \
                    rtl/plumbing/cadr_prove.sv rtl/plumbing/cadr_disk_pack.sv \
                    rtl/plumbing/cadr_gp0_default.sv rtl/plumbing/cadr_console.sv \
                    rtl/plumbing/cadr_lamp_errhalt.sv \
                    $(GP0) $(GP1) rtl/plumbing/cadr_debug_window.sv \
                    $(DBGPMOD) $(DISPLAY) \
                    $(BOARD_STUBS) tb/cadr_ps7_stub.sv | $(BUILD)
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_arty $(BOARD_STUBS) $(MACHINE) boards/arty-z7-20/cadr_arty.sv $(DBGPMOD)
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    -GPROBE_DEPTH=1024 \
	    --top-module cadr_arty $(BOARD_STUBS) $(MACHINE) \
	    boards/arty-z7-20/cadr_arty.sv rtl/plumbing/xilinx7/cadr_probe.sv $(DBGPMOD)
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    -GDDR=1 \
	    --top-module cadr_arty $(BOARD_STUBS) tb/cadr_ps7_stub.sv \
	    $(MACHINE) boards/arty-z7-20/cadr_arty.sv boards/arty-z7-20/cadr_ps7.sv rtl/plumbing/cadr_axi_master.sv \
	    rtl/plumbing/cadr_axi_widen.sv rtl/plumbing/cadr_mem_count.sv rtl/plumbing/cadr_disk_pack.sv \
	    rtl/plumbing/cadr_console.sv rtl/plumbing/cadr_gp0_default.sv $(GP0) \
	    $(GP1) rtl/plumbing/cadr_debug_window.sv $(DBGPMOD)
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    -GPROVE=1 \
	    --top-module cadr_arty $(BOARD_STUBS) tb/cadr_ps7_stub.sv \
	    $(MACHINE) boards/arty-z7-20/cadr_arty.sv boards/arty-z7-20/cadr_ps7.sv rtl/plumbing/cadr_axi_master.sv \
	    rtl/plumbing/cadr_axi_widen.sv rtl/plumbing/cadr_mem_count.sv rtl/plumbing/cadr_prove.sv \
	    rtl/plumbing/cadr_gp0_default.sv rtl/plumbing/cadr_console.sv $(GP0) \
	    $(GP1) rtl/plumbing/cadr_debug_window.sv $(DBGPMOD)
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    -GPROVE=2 \
	    --top-module cadr_arty $(BOARD_STUBS) tb/cadr_ps7_stub.sv \
	    $(MACHINE) boards/arty-z7-20/cadr_arty.sv boards/arty-z7-20/cadr_ps7.sv rtl/plumbing/cadr_axi_master.sv \
	    rtl/plumbing/cadr_axi_widen.sv rtl/plumbing/cadr_mem_count.sv rtl/plumbing/cadr_prove.sv \
	    rtl/plumbing/cadr_gp0_default.sv rtl/plumbing/cadr_console.sv $(GP0) \
	    $(GP1) rtl/plumbing/cadr_debug_window.sv $(DBGPMOD)
# A SIXTH BOARD, and it is the one that catches a display pin brought out and
# not connected.  `HDMI=1` turns the port on by itself --- the display needs
# `S_AXI_HP3` and so needs the processing system --- and `DDR=1` beside it is
# the board a bitstream is actually built with, the machine and the display
# together.  Without this pass nothing between `cadr_display_out` and
# `cadr_ps7` would be linted by any tool, which is the drift `make check` was
# green through once already.
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    -GDDR=1 -GHDMI=1 \
	    --top-module cadr_arty $(BOARD_STUBS) tb/cadr_ps7_stub.sv \
	    $(MACHINE) boards/arty-z7-20/cadr_arty.sv boards/arty-z7-20/cadr_ps7.sv rtl/plumbing/cadr_axi_master.sv \
	    rtl/plumbing/cadr_axi_widen.sv rtl/plumbing/cadr_mem_count.sv rtl/plumbing/cadr_disk_pack.sv \
	    rtl/plumbing/cadr_console.sv rtl/plumbing/cadr_gp0_default.sv $(GP0) \
	    $(GP1) rtl/plumbing/cadr_debug_window.sv $(DBGPMOD) $(DISPLAY)
# AND THE DEBUG CABLE'S TWO, AT THEIR OWN DEFAULT PARAMETERS, WHICH IS STILL
# WORTH A PASS OF ITS OWN. Both are composed now --- `cadr_dbgin.sv` is in
# `$(MACHINE)`, so every pass above elaborates it, and
# `cadr_debug_window.sv` is on the three that bring a PS7 out --- but the
# `dbgin` check elaborates them with the harness's own overrides, where
# `WATCHDOG_T` is 4,096 against the module's 100,000,000. That is a
# different `$clog2` and a different set of widths, and BOTH VIVADO SCRIPTS
# READ `[glob rtl/*/*.sv]`, so a file there that does not elaborate at its
# own defaults breaks the bitstream.
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 \
	    --top-module cadr_dbgin rtl/machine/cadr_dbgin.sv
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 \
	    --top-module cadr_debug_window rtl/plumbing/cadr_debug_window.sv
	@touch $@

# ------------------------------------------------ the Cora Z7-07S's top level
#
# `boards/cora-z7-07s/cadr_cora.sv` is the second board, and it is the same
# file one board along: the Arty Z7-20's top level with this board's pins on
# it, `rtl/` unchanged.  Like that one it cannot be simulated --- an MMCM, a
# BUFG and a PS7 are not things Verilator runs --- so lint and the fitter are
# all there is, and this is the lint.
#
# FIVE BOARDS, NOT SIX.  The Arty's rule lints a sixth with `HDMI=1`, and the
# **AND A SIXTH, `LMTV=0`.**  The second display board is the one thing on this
# board whose slot may have to come out: the Cora fits and closes with it, at
# 96.1% of its slices, and the switch is there for the day something else has
# to go in beside it.  A configuration nothing lints is a configuration nobody
# has checked, and `LMTV=0` is a generate arm with five assignments in it.
#
# Cora Z7-07S has no HDMI connector: `cadr_cora.sv` has no `HDMI` parameter to
# set, `cadr_ps7.sv` here does not bring `S_AXI_HP3` out, and there is nothing
# between a display and a PS7 on this board to be left unlinted.
#
# **AND IT USES THE ARTY's STUBS**, `$(BOARD_STUBS)` and
# `tb/cadr_ps7_stub.sv`, because all of them name primitives and pins rather
# than a board: `MMCME2_BASE`, `BUFG`, `OBUFDS`, `BSCANE2`, `USR_ACCESSE2` and
# every one of the PS7's 620 pins are the same on both parts.  A second set of
# stubs would be a second description of one hard block, and `tb/` is not a
# board's directory.
$(BUILD)/cora.pass: $(MACHINE) boards/cora-z7-07s/cadr_cora.sv rtl/plumbing/xilinx7/cadr_probe.sv \
                    boards/cora-z7-07s/cadr_ps7.sv rtl/plumbing/cadr_axi_master.sv \
                    rtl/plumbing/cadr_axi_widen.sv rtl/plumbing/cadr_mem_count.sv \
                    rtl/plumbing/cadr_prove.sv rtl/plumbing/cadr_disk_pack.sv \
                    rtl/plumbing/cadr_gp0_default.sv rtl/plumbing/cadr_console.sv \
                    $(GP0) $(GP1) rtl/plumbing/cadr_debug_window.sv \
                    $(DBGPMOD) rtl/plumbing/cadr_lamp_errhalt.sv \
                    $(BOARD_STUBS) tb/cadr_ps7_stub.sv | $(BUILD)
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/cora-z7-07s \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_cora $(BOARD_STUBS) $(MACHINE) boards/cora-z7-07s/cadr_cora.sv \
	    rtl/plumbing/cadr_lamp_errhalt.sv $(DBGPMOD)
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/cora-z7-07s \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    -GPROBE_DEPTH=1024 \
	    --top-module cadr_cora $(BOARD_STUBS) $(MACHINE) \
	    boards/cora-z7-07s/cadr_cora.sv rtl/plumbing/xilinx7/cadr_probe.sv \
	    rtl/plumbing/cadr_lamp_errhalt.sv $(DBGPMOD)
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/cora-z7-07s \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    -GDDR=1 \
	    --top-module cadr_cora $(BOARD_STUBS) tb/cadr_ps7_stub.sv \
	    $(MACHINE) boards/cora-z7-07s/cadr_cora.sv boards/cora-z7-07s/cadr_ps7.sv \
	    rtl/plumbing/cadr_axi_master.sv \
	    rtl/plumbing/cadr_axi_widen.sv rtl/plumbing/cadr_mem_count.sv rtl/plumbing/cadr_disk_pack.sv \
	    rtl/plumbing/cadr_console.sv rtl/plumbing/cadr_gp0_default.sv $(GP0) \
	    $(GP1) rtl/plumbing/cadr_debug_window.sv $(DBGPMOD) rtl/plumbing/cadr_lamp_errhalt.sv
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/cora-z7-07s \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    -GPROVE=1 \
	    --top-module cadr_cora $(BOARD_STUBS) tb/cadr_ps7_stub.sv \
	    $(MACHINE) boards/cora-z7-07s/cadr_cora.sv boards/cora-z7-07s/cadr_ps7.sv \
	    rtl/plumbing/cadr_axi_master.sv \
	    rtl/plumbing/cadr_axi_widen.sv rtl/plumbing/cadr_mem_count.sv rtl/plumbing/cadr_prove.sv \
	    rtl/plumbing/cadr_gp0_default.sv rtl/plumbing/cadr_console.sv $(GP0) \
	    $(GP1) rtl/plumbing/cadr_debug_window.sv $(DBGPMOD) rtl/plumbing/cadr_lamp_errhalt.sv
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/cora-z7-07s \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    -GDDR=1 -GLMTV=0 \
	    --top-module cadr_cora $(BOARD_STUBS) tb/cadr_ps7_stub.sv \
	    $(MACHINE) boards/cora-z7-07s/cadr_cora.sv boards/cora-z7-07s/cadr_ps7.sv \
	    rtl/plumbing/cadr_axi_master.sv \
	    rtl/plumbing/cadr_axi_widen.sv rtl/plumbing/cadr_mem_count.sv rtl/plumbing/cadr_disk_pack.sv \
	    rtl/plumbing/cadr_console.sv rtl/plumbing/cadr_gp0_default.sv $(GP0) \
	    $(GP1) rtl/plumbing/cadr_debug_window.sv $(DBGPMOD) rtl/plumbing/cadr_lamp_errhalt.sv
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/cora-z7-07s \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    -GPROVE=2 \
	    --top-module cadr_cora $(BOARD_STUBS) tb/cadr_ps7_stub.sv \
	    $(MACHINE) boards/cora-z7-07s/cadr_cora.sv boards/cora-z7-07s/cadr_ps7.sv \
	    rtl/plumbing/cadr_axi_master.sv \
	    rtl/plumbing/cadr_axi_widen.sv rtl/plumbing/cadr_mem_count.sv rtl/plumbing/cadr_prove.sv \
	    rtl/plumbing/cadr_gp0_default.sv rtl/plumbing/cadr_console.sv $(GP0) \
	    $(GP1) rtl/plumbing/cadr_debug_window.sv $(DBGPMOD) rtl/plumbing/cadr_lamp_errhalt.sv
	@touch $@

# ------------------- Ibex and the soft processing system's sources ---------
#
# **THESE LIVE HERE AND NOT IN THE BLOCK AT THE END OF THIS FILE FOR ONE
# REASON: `make` EXPANDS A RULE's PREREQUISITES WHEN IT READS THE LINE.**  The
# Arty A7's lint is the first rule that names them, so a definition after it
# would be an empty list --- which would look exactly like a lint that had
# nothing to read and would pass.  Everything else about the soft processing
# system is in one block at the end of this file.

# --- Ibex, vendored ---------------------------------------------------------
#
# The file list is Ibex's own `rtl/ibex_core.f` plus the six files that list
# does not name and the build needs, plus the include files and the two
# `prim_` modules those pull in.  `third_party/ibex/README.md` says which six
# and why, and carries the upstream commit and every file's digest.
IBEX_DIR := third_party/ibex
IBEX_INC := -I$(IBEX_DIR)/vendor/lowrisc_ip/ip/prim/rtl \
            -I$(IBEX_DIR)/vendor/lowrisc_ip/dv/sv/dv_utils
# **THE PATHS ARE SPELLED OUT AND NOT BUILT FROM `$(IBEX_DIR)`.**
# `mutations/run.py`'s `check_makefile` compares the runner's source list with
# this file as literal text, so that a file added to a check in one and not the
# other is a warning rather than silent under-testing. A variable in the middle
# of a path defeats it, and a guard that cannot see the thing it guards is
# worse than none.
IBEX_SRC := third_party/ibex/rtl/ibex_pkg.sv \
            third_party/ibex/rtl/ibex_cheriot_pkg.sv \
            third_party/ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_cipher_pkg.sv \
            third_party/ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_lfsr.sv \
            third_party/ibex/rtl/ibex_alu.sv \
            third_party/ibex/rtl/ibex_compressed_decoder.sv \
            third_party/ibex/rtl/ibex_controller.sv \
            third_party/ibex/rtl/ibex_counter.sv \
            third_party/ibex/rtl/ibex_cs_registers.sv \
            third_party/ibex/rtl/ibex_csr.sv \
            third_party/ibex/rtl/ibex_decoder.sv \
            third_party/ibex/rtl/ibex_ex_block.sv \
            third_party/ibex/rtl/ibex_id_stage.sv \
            third_party/ibex/rtl/ibex_if_stage.sv \
            third_party/ibex/rtl/ibex_load_store_unit.sv \
            third_party/ibex/rtl/ibex_multdiv_slow.sv \
            third_party/ibex/rtl/ibex_multdiv_fast.sv \
            third_party/ibex/rtl/ibex_prefetch_buffer.sv \
            third_party/ibex/rtl/ibex_fetch_fifo.sv \
            third_party/ibex/rtl/ibex_register_file_ff.sv \
            third_party/ibex/rtl/ibex_register_file_fpga.sv \
            third_party/ibex/rtl/ibex_pmp.sv \
            third_party/ibex/rtl/ibex_dummy_instr.sv \
            third_party/ibex/rtl/ibex_branch_predict.sv \
            third_party/ibex/rtl/ibex_wb_stage.sv \
            third_party/ibex/rtl/ibex_core.sv
# **IBEX's OWN WAIVER IS NOT USED AND THIS ONE IS SCOPED.**  Upstream's first
# line turns a rule off globally, with no file match, which would reach every
# file in this repository.  `ibex_lint.vlt` is written here and waives three
# rules for the vendored directory alone; its header says what each is.
IBEX_VLT := $(IBEX_DIR)/ibex_lint.vlt

SOC_RTL := rtl/plumbing/cadr_soc_ram.sv rtl/plumbing/cadr_soc_uart.sv \
           rtl/plumbing/cadr_soc_timer.sv rtl/plumbing/cadr_soc_axi.sv \
           rtl/plumbing/cadr_soc_cross.sv \
           rtl/plumbing/cadr_soc.sv

# **THE SOFT SYSTEM'S OWN CLOCK, READ OUT OF THE FABRIC THAT DECIDES IT.**  The
# core runs slower than the machine --- Ibex computes a load or a store's
# address in the cycle it uses it and that arc does not fit in a 10 ns tick ---
# and `SOC_CLK_DIVIDE` beside the clock manager in
# `boards/arty-a7-100/cadr_arty_a7.sv` is the one place the number is decided.
# The transmitter's divisor and the timer's microsecond are computed from it
# here so that the check and the board cannot describe two different clocks,
# which is `boards/arty-z7-20/vivado/tick.tcl`'s argument in a second place.
# The voltage controlled oscillator is 1000 MHz, so the divider IS the
# frequency: twenty gives 50 MHz.
#
# **AND THE ARITHMETIC IS THE FABRIC'S OWN, TRUNCATION INCLUDED.**
# `cadr_soc.sv` computes the timer's microsecond as `CLK_HZ / 1_000_000` in
# integers; doing it any other way here would make the check and the board
# disagree about a microsecond at any divider that does not give whole
# megahertz.  So both lines below are integer divisions in the same order.
SOC_CLK_DIVIDE := $(shell sed -n \
    's/^ *localparam int unsigned SOC_CLK_DIVIDE *= *\([0-9][0-9]*\).*/\1/p' \
    boards/arty-a7-100/cadr_arty_a7.sv | head -1)
ifeq ($(strip $(SOC_CLK_DIVIDE)),)
$(error SOC_CLK_DIVIDE could not be read out of \
        boards/arty-a7-100/cadr_arty_a7.sv, so the soft system's clock would \
        be two numbers that can come apart)
endif
SOC_CLK_HZ := $(shell echo $$(( 1000000000 / $(SOC_CLK_DIVIDE) )))
# The faces the soft system masters, unchanged from the boards that have a
# processing system.
#
# **THREE AND NOT FOUR, AND THE FOURTH IS THE DEBUG CABLE'S WINDOW.**
# `rtl/plumbing/cadr_debug_window.sv` is how muir, on a Zynq board's own ARM
# cores, plays the far end of MIT's debug cable in software.  There is no muir
# on an Artix and no processor to run one on: this board's debugger is a SECOND
# BOARD on Pmod JB, which reaches the machine's DBGIN page through the cable's
# own carrier and never through the bridge.  So the window is in no
# configuration of this board, `0x8000_1000` is an address the catch-all
# answers "NONE", and `rtl/plumbing/cadr_soc_axi.sv` has two windows and a
# catch-all where it had three and one.  The file itself stays: both Zynq
# boards read it.
SOC_FACES := rtl/plumbing/cadr_console.sv rtl/plumbing/cadr_disk_pack.sv \
             rtl/plumbing/cadr_gp0_default.sv

# ----------------------------------------------- the Arty A7-100's top level
#
# `boards/arty-a7-100/cadr_arty_a7.sv` is the third board and the first with no
# processing system: an Artix-7, so no PS7, no AXI port, nothing behind the
# machine's memory port, and every seam the other two drive from a program tied
# off instead. Like them it cannot be simulated --- Verilator has no
# `MMCME2_BASE` --- so lint and the fitter are all there is, and this is the
# lint.
#
# **THE FOLD IS WHAT THIS EARNS, AND IT IS NOT A DUPLICATE OF THE OTHER TWO.**
# Three top levels now instantiate `cadr_machine`, and an output added to the
# machine and connected in only some of them is a PINMISSING in the rest. The
# Arty's lint and the Cora's say the port list is complete for a board with a
# processing system; this says it is complete for a board with none, where
# forty-odd seams are tied off rather than driven --- which is a different
# statement about the same list.
#
# SIX TIMES, ONE A CONFIGURATION. The switches are this board's own:
# `PROBE_DEPTH`, `DDR`, `PROVE` and `SOC`. Of the Arty Z7-20's three only
# `HDMI` has no counterpart here; `DDR` and `PROVE` mean the board's own DDR3L
# through the generated controller rather than a port of a Zynq's, and `SOC`
# is the soft processing system the other board has no need of. `PROBE_DEPTH`
# is zero by default and the generate that instantiates
# `rtl/plumbing/xilinx7/cadr_probe.sv` is then not elaborated at all, so a lint
# of the default says nothing about the board
# `boards/arty-a7-100/vivado/probe.tcl` builds and reads. A branch only one
# build reaches is a branch only one build checks.
#
# `$(MACHINE)` COMES FIRST, as it does for the other two: a package has to be
# parsed before the file that reads it.
#
# **THE SOFT PROCESSING SYSTEM IS A SWITCH OF ITS OWN.**  `SOC` puts
# `rtl/plumbing/cadr_soc.sv` and the four faces in the design, and a branch
# only one build reaches is a branch only one build checks.
#
# **AND ONE FILE LIST FOR ALL SIX.**  Verilator resolves the modules named
# in a generate branch it does not elaborate, so the SoC's sources have to be
# on the command line even when `SOC` is clear --- which is the same fact as
# the PINMISSING this repository already records for an un-elaborated cell.
# What changes between the passes is the parameter and nothing else, which is
# also what makes the six comparable.
#
# `A7MEM` IS DEFINED HERE, ABOVE THE RULE THAT NAMES IT, AND NOT IN THE MEMORY
# BLOCK BELOW WHERE IT READS AS BELONGING.  A prerequisite list is expanded
# when the rule is read, so a variable defined further down is empty there:
# measured with `make -pn`, the four files were absent from `arty_a7.pass`'s
# prerequisites and a change to any of them did not re-run the lint that
# reads them. The recipe was unaffected, being expanded when it runs, which
# is why the lint itself was never wrong. The memory block's comment says
# what the three are for.
A7MEM := rtl/plumbing/cadr_mem_cross.sv rtl/plumbing/cadr_mig_ui.sv \
         rtl/plumbing/cadr_jtag_mem.sv rtl/plumbing/cadr_mem_count.sv

ARTY_A7_SRC := $(BOARD_STUBS) $(MACHINE) \
               boards/arty-a7-100/cadr_arty_a7.sv \
               rtl/plumbing/cadr_lamp_errhalt.sv \
               $(IBEX_SRC) $(SOC_RTL) $(SOC_FACES)
ARTY_A7_LINT := $(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing \
                -Irtl/plumbing/xilinx7 -Iboards/arty-a7-100 $(IBEX_INC) \
                -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
                -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
                -GFIRMWARE_HEX='"$(abspath $(BUILD))/soc_firmware.hex"' \
                --top-module cadr_arty_a7 $(IBEX_VLT)

$(BUILD)/arty_a7.pass: $(MACHINE) boards/arty-a7-100/cadr_arty_a7.sv \
                    rtl/plumbing/cadr_lamp_errhalt.sv \
                    rtl/plumbing/xilinx7/cadr_probe.sv \
                    boards/arty-a7-100/cadr_a7_memory.sv $(A7MEM) \
                    tb/cadr_mig_stub.sv \
                    $(IBEX_SRC) $(IBEX_VLT) $(SOC_RTL) $(SOC_FACES) \
                    $(BOARD_STUBS) | $(BUILD)
	$(ARTY_A7_LINT) $(ARTY_A7_SRC)
	$(ARTY_A7_LINT) -GPROBE_DEPTH=1024 $(ARTY_A7_SRC) \
	    rtl/plumbing/xilinx7/cadr_probe.sv
# ...and the three the board's own memory adds: the machine with the DDR3L
# behind it, and the two proving boards with the witness in the machine's
# place.  **FIVE CONFIGURATIONS AND NOT TWO.**  A check that lints one
# configuration says nothing about the others, and this repository has already
# had a whole seam --- everything between the adapter and the processing
# system --- with no check of any kind from any tool while `make check` was
# green, because the runner linted the default board only.
#
# The generated memory controller is not linted with them and cannot be: it is
# 73 files of Verilog with a physical layer of seven-series primitives in it.
# `tb/cadr_mig_stub.sv` stands in for it, with its port list and no behavior,
# and carries the same weakness every stub here carries --- it is written to
# match what we connect.  What it does hold is that the wrapper's
# instantiation matches the generator's own template in name, direction and
# width, which is the fault a hand-copied port list actually makes.
	for g in DDR=1 PROVE=1 PROVE=2; do \
	    $(ARTY_A7_LINT) -G$$g $(ARTY_A7_SRC) tb/cadr_mig_stub.sv \
	        boards/arty-a7-100/cadr_a7_memory.sv $(A7MEM) || exit 1; \
	done
# ...and the soft processing system, which is the sixth.  **SIX
# CONFIGURATIONS AND NOT FIVE.**  `SOC` puts the Ibex, its memory, its UART,
# its timer and the four faces it masters into the design, and the same
# argument the five above rest on rests on this one: a branch only one build
# reaches is a branch only one build checks.
	$(ARTY_A7_LINT) -GSOC=1 $(ARTY_A7_SRC)
# ...and SEVEN, WHICH IS THE ONLY ONE THAT IS THE WHOLE BOARD.  `SOC=1 DDR=1`
# is the machine with its memory behind it AND the soft processing system in
# front of the faces --- the configuration this board is for --- and until
# this line nothing linted it at all.  Six passes over six partial boards is
# exactly the shape this repository has recorded before: a runner that linted
# the default configuration only, while everything between the adapter and the
# processing system had no check of any kind from any tool and `make check` was
# green.  It is also where the design's two crossings meet, the soft system's
# clock and the memory controller's user clock being in one netlist for the
# first time.
	$(ARTY_A7_LINT) -GSOC=1 -GDDR=1 $(ARTY_A7_SRC) tb/cadr_mig_stub.sv \
	    boards/arty-a7-100/cadr_a7_memory.sv $(A7MEM)
	@touch $@

# ============ the Arty A7-100's main memory =============================
#
# The board's own 256 MB of DDR3L behind the machine's memory port, through
# Xilinx's Memory Interface Generator in the fabric.  There is no processing
# system on an Artix, so nothing of the other board's memory path carries over
# below `mem_*`: what is here is three modules of our own and a generated
# controller, and this block is everything in the Makefile that is theirs.
#
# `A7MEM` is the three, named once because two lists of the same files drift:
# the crossing between the machine's tick and the controller's user clock, the
# driver for the controller's native user interface, and the debugger's window
# in front of the port --- which on this board is the ONLY way into memory
# from outside the machine, an Artix having no debug access port onto it.
# (`A7MEM` itself is assigned above the Arty A7-100's lint rule, which names
# it as a prerequisite and so needs it defined first; see the comment there.)
A7MEM_SRC := rtl/plumbing/cadr_ddr_map.sv $(A7MEM) tb/cadr_a7_mem_harness.sv

$(BUILD)/obj_a7_mem/Vcadr_a7_mem_harness: $(A7MEM_SRC) tb/cadr_a7_mem_tb.cpp \
                    | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Itb \
	    -Mdir $(BUILD)/obj_a7_mem \
	    --top-module cadr_a7_mem_harness $(A7MEM_SRC) \
	    $(abspath tb/cadr_a7_mem_tb.cpp)

$(BUILD)/a7_mem.pass: $(BUILD)/obj_a7_mem/Vcadr_a7_mem_harness
	$(BUILD)/obj_a7_mem/Vcadr_a7_mem_harness
	@touch $@

# The controller itself is generated, not written, and it is regenerated by a
# script rather than by a graphical tool:
#
#     vivado -mode batch -source boards/arty-a7-100/vivado/mig.tcl
#
# `make current` asks whether what is committed is what that writes today, and
# whether the project file it reads is Digilent's published one with only the
# three changes the repository states.  There is no Makefile rule that runs the
# generator: it takes half a minute of Vivado and its output is committed, so a
# rule with the generated tree as its target would regenerate it whenever a
# timestamp moved and produce a diff nobody asked for.

# --------------------------------------------------------------- the probe

# `rtl/plumbing/xilinx7/cadr_probe.sv` is what will be read off the board. It is checked the
# way everything else here is checked --- against muir's own trace --- and not
# merely instantiated: `tb/cadr_probe_harness.sv` wires it to `cadr_machine`
# exactly as `boards/arty-z7-20/cadr_arty.sv` does, and the testbench shifts all 1,024
# samples out through the probe's own JTAG shift register and compares every
# column against `build/rtl.golden`. The window needs no stimulus: the boot
# PROM's first memory cycle is at microcycle 535,791.
#
# The harness is in `tb/` for the reason `tb/cadr_arty_stubs.sv` gives: both
# Vivado scripts read `[glob rtl/*/*.sv rtl/*/*/*.sv boards/arty-z7-20/*.sv]`.
PROBE_SRC := $(MACHINE) rtl/plumbing/xilinx7/cadr_probe.sv tb/cadr_probe_harness.sv

$(BUILD)/obj_probe/Vcadr_probe_harness: $(PROBE_SRC) tb/cadr_probe_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_probe \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_probe_harness $(PROBE_SRC) \
	    $(abspath tb/cadr_probe_tb.cpp)

$(BUILD)/probe.pass: $(BUILD)/obj_probe/Vcadr_probe_harness \
                       $(BUILD)/rtl.golden $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_probe/Vcadr_probe_harness $(BUILD)/rtl.golden
	@touch $@

# ------------------------------------------------- the probe's other half
#
# `boards/arty-z7-20/vivado/probe.tcl` is the script that reads the capture off the board over
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
# is a claim `boards/arty-z7-20/vivado/probe.tcl`'s own header makes and an exit code cannot
# tell the two apart.
#
# IN `check`, and it earns the place: it is a check of a script the repository
# ships and will depend on, it needs neither Vivado nor a board nor a
# bitstream, and it costs 80 ms. What it does NOT check is written at length
# in `tb/cadr_jtag_chain.tcl`'s header --- there is no TAP state machine here,
# no DRCK and no silicon, so a green run says the script reads a chain
# correctly and says nothing whatever about the readout being verified.
$(BUILD)/probe_jtag.pass: boards/arty-z7-20/vivado/probe.tcl tb/cadr_jtag_chain.tcl \
                          tb/cadr_probe_jtag_tb.tcl | $(BUILD)
	OUTDIR=$(BUILD)/probe_jtag $(TCLSH) tb/cadr_probe_jtag_tb.tcl
	@touch $@

# --------------------------------------------- what says a download took
#
# The other script that needs a board, held the same way.  Both `program.tcl`s
# used to decide that a download had worked from the DONE bit alone, and DONE
# is already high on a part that was configured before the run --- so the one
# witness read the same whether the configuration took or not.  On the Arty
# A7-100 three downloads in six did not take while the script said they had,
# and what caught it was an identity read out of the design.
#
# The scripts compare the build the part reads back over JTAG with the build
# the bitstream names, which `tools/build_stamp.tcl` writes into
# `BITSTREAM.CONFIG.USERID` at the other end.  This runs both scripts against
# a stubbed hardware manager, ten cases apiece, and asserts, for each, the
# LINE it must print --- because "the part already held this build" and "the
# download took" are two different findings with one exit status.
#
# IN `check`: no Vivado, no cable, no bitstream, and 0.08 s measured.  Three
# records in `mutations/list.txt` aim at it, one at each source, so nothing
# here needs an exemption.
#
# WHAT IT CANNOT SAY is in `tb/cadr_program_tb.tcl`'s header: the USERCODE is
# a stub answering what the case says, and that a part really reads its
# bitstream's USERID back there is read out of the BSDL and Vivado's device
# tables and has not been measured on a board by anything in this repository.
$(BUILD)/program_tcl.pass: boards/arty-z7-20/vivado/program.tcl \
                           boards/arty-a7-100/vivado/program.tcl \
                           tools/build_stamp.tcl tb/cadr_program_tb.tcl | $(BUILD)
	OUTDIR=$(BUILD)/program_tcl $(TCLSH) tb/cadr_program_tb.tcl
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
# hand-written instantiation forgets them. boards/arty-z7-20/vivado/gen_ps7.py has the
# measurement.
ps7:
	python3 boards/arty-z7-20/vivado/gen_ps7.py

# And the Cora Z7-07S's, which is the same parse of the same PS7.v with
# `S_AXI_HP3` left out --- that board has no HDMI connector and so no display
# to master it.  `boards/cora-z7-07s/vivado/gen_ps7.py` is a front end that
# calls the generator above rather than a second copy of it.
ps7-cora:
	python3 boards/cora-z7-07s/vivado/gen_ps7.py

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
# boards/arty-z7-20/vivado/ps7_config.tcl says exactly where it came from, and
# boards/arty-z7-20/vivado/ps7_ops.py what it was measured against.
ps7-init:
	python3 boards/arty-z7-20/vivado/ps7_ops.py

# And the Cora Z7-07S's routine, out of Digilent's own board preset for that
# board.  Two files come of it: the ordered operations, and the C table
# U-Boot's SPL runs, which is derived from them.
ps7-init-cora:
	python3 boards/cora-z7-07s/vivado/ps7_ops.py
	python3 boards/cora-z7-07s/linux/buildroot/board/cora-z7-07s/uboot/gen_ps7_init_gpl.py

$(BUILD)/cables.pass: rtl/machine/cadr_cables.svh rtl/machine/cadr_cables_lint.sv | $(BUILD)
	$(VERILATOR) --lint-only -Wall --top-module cadr_cables_lint -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 \
	    rtl/machine/cadr_cables_lint.sv
	@touch $@

# The generated files have to be the ones the generator writes today. Same
# discipline as cadr4 next door: regenerate, and fail if anything moved.
current:
	@$(GOLDEN) --bin cables
	@git diff --quiet --exit-code HEAD -- rtl/machine/cadr_cables.svh rtl/machine/cadr_cables.map \
	    rtl/machine/cadr_cables_lint.sv \
	    || { echo "generated files are stale: run 'make cables' and commit"; exit 1; }
	@echo "ok: generated files are current"
	@python3 boards/arty-z7-20/vivado/gen_ps7.py --check
	@python3 boards/arty-z7-20/vivado/ps7_ops.py --check
# And the second board's three generated files, on the same argument: a
# generated file that is not what the generator writes today is a claim about
# a design nobody is building.  All three skip without Vivado, as the two
# above do, except the C table --- that one is derived from the committed
# `.ops` by pure Python and runs anywhere.
	@python3 boards/cora-z7-07s/vivado/gen_ps7.py --check
	@python3 boards/cora-z7-07s/vivado/ps7_ops.py --check
	@python3 boards/cora-z7-07s/linux/buildroot/board/cora-z7-07s/uboot/gen_ps7_init_gpl.py --check
# And the third board's memory controller, which is generated rather than
# written --- this project's one generated-IP exception, and the thing that
# keeps it honest.  It skips the regeneration without Vivado and says so; the
# two questions it can always answer, whether the project file is Digilent's
# with the three stated changes and whether the memory-off board's pin file is
# derived from the generated one, are pure Python and run anywhere.
	@python3 boards/arty-a7-100/vivado/mig_check.py --check

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
# THE CHEAP GUARD IN FRONT OF THE EXPENSIVE ONE, and a prerequisite of it
# rather than a thing to remember.  A record whose `@old` matches nothing does
# not weaken the mutation suite, it KILLS it: `parse()` refuses the whole list,
# so one rotted anchor takes every other record with it and the run ends with
# no summary line at all.  That happened once and eleven commits were gated and
# pushed before anybody noticed, because `make check` does not run the suite.
# It uses the runner's own `parse()`, so the two cannot drift about what a
# record is, and it takes seconds with no traces and no Verilator.
.PHONY: mutants-anchors
mutants-anchors:
	python3 mutations/anchors.py

mutants: mutants-anchors $(BUILD)/phase_gen.golden $(BUILD)/busint_xbus.golden \
         $(BUILD)/xbus_decode.golden $(BUILD)/rtl.golden \
         $(BUILD)/disk.golden $(BUILD)/disk_boot.golden $(BUILD)/tv.golden \
         $(BUILD)/tv_lispm.golden $(BUILD)/color_tv.golden \
         $(BUILD)/iob.golden $(BUILD)/busint_regs.golden \
         $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex $(BUILD)/rtl_sys.golden | $(BUILD)
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
                  $(BUILD)/disk.golden $(BUILD)/disk_boot.golden \
                  $(BUILD)/tv.golden $(BUILD)/tv_lispm.golden \
                  $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex $(BUILD)/rtl_sys.golden \
             $(BUILD)/soc_firmware.hex | $(BUILD)
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
# 269 MB free while this runs and keeps the 392 MB trace. `clean` takes
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
                              $(BUILD)/rtl_sys.golden $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_microcycle/Vcadr_microcycle $(BUILD)/rtl_sys.golden
	@touch $@

# ------------------------------------------ MD holds what its instruction put

# A property on the same module and the same two programs, measured every
# tick: from the `cpu_edge` where DESTMDR writes MD until the write phase with
# WMAPD up, MD does not change. The map is indexed by MD<23:8> whenever
# MEMSTART is down, and `wmapd` is registered at the boundary, so an
# instruction that puts a virtual address in MD and then writes the map
# through it needs MD to stand across several microcycles; a held word
# committing inside that span writes the map at a different entry and says
# nothing.
#
# No new reference. MD has two writers and one of them is the instruction, so
# any other change inside the window is the other one. The model is verilated
# `--public-flat-rw` because DESTMDR, WMAPD, the write pulse and `md_pending`
# are internal, and a testbench re-decoding them out of IR would be checking
# its own decode.
#
# THE COVERAGE IS THE FINDING and it is on the check's own output: how many
# windows, how long, how many carried a -LOADMD at all, and how close the
# nearest one came when none did.
$(BUILD)/obj_md_hold/Vcadr_microcycle: $(MICROCYCLE) tb/cadr_md_hold_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 --public-flat-rw -Mdir $(BUILD)/obj_md_hold \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    --top-module cadr_microcycle $(MICROCYCLE) $(abspath tb/cadr_md_hold_tb.cpp)

$(BUILD)/md_hold.pass: $(BUILD)/obj_md_hold/Vcadr_microcycle \
                       $(BUILD)/rtl.golden $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_md_hold/Vcadr_microcycle $(BUILD)/rtl.golden
	@touch $@

$(BUILD)/md_hold_sys.pass: $(BUILD)/obj_md_hold/Vcadr_microcycle \
                           $(BUILD)/rtl_sys.golden $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_md_hold/Vcadr_microcycle $(BUILD)/rtl_sys.golden
	@touch $@

# THE ONE TICK NO TRACE REACHES, AND THIS TARGET IS RED ON PURPOSE.
#
# `md_hold` prints, on both programs, that no -LOADMD ever rose on the tick a
# DESTMDR wrote MD: not once in 600,000 microcycles of the boot PROM nor in
# 2,800,000 of the band. That one tick is the only case in which the MD
# register takes its first branch and the `else if` that clears `md_pending`
# never runs, so it is the only case in which a word strobed before an
# instruction's write can land after it --- and no trace this project has can
# put a check on it.
#
# So the stimulus does: it runs MIT's boot PROM and drives one extra -LOADMD,
# for one tick, on a DESTMDR boundary, against a control run that places none.
# What it asserts is muir's rule, which is that the edge consumes the word and
# the instruction's stands.
#
# IT IS NOT IN `check` AND MUST NOT BE ADDED UNTIL IT PASSES. The defect it
# names is real and unfixed, measured at this commit: md_pending survives the
# edge and the held word commits 44 ticks later, one extra-slow microcycle,
# over the word the instruction put there. The test is written first, as the
# house rule has it, and joins `check` in the commit that makes it pass. It
# runs the boot PROM twice and takes about half a minute.
$(BUILD)/obj_md_inject/Vcadr_microcycle: $(MICROCYCLE) tb/cadr_md_inject_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 --public-flat-rw -Mdir $(BUILD)/obj_md_inject \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    --top-module cadr_microcycle $(MICROCYCLE) $(abspath tb/cadr_md_inject_tb.cpp)

$(BUILD)/md_inject.pass: $(BUILD)/obj_md_inject/Vcadr_microcycle \
                         $(BUILD)/rtl.golden $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_md_inject/Vcadr_microcycle $(BUILD)/rtl.golden
	@touch $@

# --------------------------------------------------- the disk, with a drive

# The reference trace for the disk controller once it has a drive and a pack:
# `golden/src/disk.rs` drives `disk_controller::Controller` register by
# register, as `busint_xbus.rs` drives `busint::Busint`.
#
# It needs no `vendor/`: the pack is blank and the program formats what it
# reads, so this runs in CI where `rtl_sys.golden` skips.  The generator also
# asserts as it runs --- that time never runs backwards and every instant it
# samples at is a multiple of five nanoseconds, that no read of a register
# changed the pack, and that the five status bits `Controller` cannot reach
# are exactly `<4> <12> <19> <21> <23>` --- so a muir that moves under any of
# those says so on the push that moves it.
.PHONY: disk-golden
disk-golden: $(BUILD)/disk.golden

$(BUILD)/disk.golden: golden/src/disk.rs golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin disk > $@

# The controller against that trace, WITH ITS PACK SIDE UNDERNEATH.  The
# block store used to be filled by the testbench through a seam; now
# `rtl/plumbing/cadr_disk_pack.sv` fills it over `S_AXI_HP2` from records the testbench
# puts in a modeled DDR at the addresses the trace names, asked to by register
# writes over `M_AXI_GP0`, and the drive's presence, its read-only switch and
# whether its time is charged are three of those registers.  So the harness is
# the DUT --- `tb/cadr_disk_harness.sv` wires the two as `boards/arty-z7-20/cadr_arty.sv`'s
# `g_ddr` does --- and nothing reaches the store but the master.
#
# **THIS IS THE SLOWEST CHECK HERE AND THE REASON IS A CONSTANT THAT MUST NOT
# BE SHORTENED**: the trace holds one hang run out to `TIMEOUT_NS`, 2.56 s,
# which is 512,000,000 ticks of this fabric's clock, and the fabric has to
# count every one of them.  A check that cannot tell that constant from a
# wrong one is `RD_FINISH_T` again.  With the pre-roll that puts the spindle
# in phase it is about 570 million ticks and takes two minutes or so.
DISK_SRC := rtl/machine/cadr_disk_controller.sv rtl/plumbing/cadr_disk_pack.sv \
            tb/cadr_disk_harness.sv

$(BUILD)/obj_disk/Vcadr_disk_harness: $(DISK_SRC) tb/cadr_disk_tb.cpp \
                                      tb/cadr_pack_side.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Mdir $(BUILD)/obj_disk \
	    --top-module cadr_disk_harness \
	    $(DISK_SRC) $(abspath tb/cadr_disk_tb.cpp)

$(BUILD)/disk.pass: $(BUILD)/obj_disk/Vcadr_disk_harness $(BUILD)/disk.golden
	$(BUILD)/obj_disk/Vcadr_disk_harness $(BUILD)/disk.golden
	@touch $@

# ------------------------------------------------------------- the pack side

# `rtl/plumbing/cadr_disk_pack.sv` held to the property, which is `cadr_axi_master.sv`'s
# situation: no muir reference --- `Unit::read_block` is a memcpy --- so the
# testbench is the stimulus and a counting AXI3 slave is the observer.  A
# block put in the modeled DDR and fetched is READ BACK BY THE CADR, through
# the controller's own transfer into a poisoned page, and a block the CADR
# wrote is written back and compared; the three words after the block are read
# back through the status bits the controller raises when each is wrong.  Same
# harness as `disk`, a few seconds rather than two minutes, and the mutations
# aimed at the pack side run here.
$(BUILD)/obj_disk_pack/Vcadr_disk_harness: $(DISK_SRC) tb/cadr_disk_pack_tb.cpp \
                                           tb/cadr_pack_side.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Mdir $(BUILD)/obj_disk_pack \
	    --top-module cadr_disk_harness \
	    $(DISK_SRC) $(abspath tb/cadr_disk_pack_tb.cpp)

$(BUILD)/disk_pack.pass: $(BUILD)/obj_disk_pack/Vcadr_disk_harness
	$(BUILD)/obj_disk_pack/Vcadr_disk_harness
	@touch $@

# ------------------------------------------- the channel over a real pack

# `golden/src/disk_boot.rs` walks command lists of more than one CCW over a
# real System 100 pack, with the blocks fetched on demand --- the hole the
# other three checks left between them, and the one the board fell through on
# 2026-09-10.  `tb/cadr_disk_boot_tb.cpp` has the whole account.
#
# It needs `vendor/`, so it SKIPS where the release is not here, as
# `rtl_sys.golden` does; the sum is checked before the archive is used and the
# pack is decompressed fresh for the run and removed after.  A drive writes its
# pack, so a generator run against a working image would not be reproducible
# --- and this one is careful besides: `Unit::open` never writes the file, and
# the Makefile still hands it a copy.
.PHONY: disk-boot-golden
disk-boot-golden: $(BUILD)/disk_boot.golden

$(BUILD)/disk_boot.golden: golden/src/disk_boot.rs golden/Cargo.toml | $(BUILD)
	@if [ ! -f $(SYS100_GZ) ]; then \
	    echo "# skipped: the System 100 release is not here" > $@; \
	    echo "disk_boot: skipped --- no System 100 release; muir's tools/fetch-system-100.sh fetches it"; \
	else \
	    set -e; \
	    echo "$(SYS100_SHA)  $(SYS100_GZ)" | sha256sum -c --quiet - \
	        || { echo "disk_boot: $(SYS100_GZ) is not the release this trace was measured against"; exit 1; }; \
	    trap 'rm -f $(BUILD)/disk-boot-pack.img $@.part' EXIT; \
	    gunzip -c $(SYS100_GZ) > $(BUILD)/disk-boot-pack.img; \
	    $(GOLDEN) --release --bin disk_boot -- --pack $(BUILD)/disk-boot-pack.img > $@.part; \
	    mv $@.part $@; \
	fi

$(BUILD)/obj_disk_boot/Vcadr_disk_harness: $(DISK_SRC) tb/cadr_disk_boot_tb.cpp \
                                           tb/cadr_pack_side.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Mdir $(BUILD)/obj_disk_boot \
	    --top-module cadr_disk_harness \
	    $(DISK_SRC) $(abspath tb/cadr_disk_boot_tb.cpp)

# The testbench itself says "skipped" and passes when it is handed the stub,
# so that `mutations/run.py`, which runs the binary and not this rule, does
# the same rather than dying on a trace with no rows.
$(BUILD)/disk_boot.pass: $(BUILD)/obj_disk_boot/Vcadr_disk_harness \
                         $(BUILD)/disk_boot.golden
	$(BUILD)/obj_disk_boot/Vcadr_disk_harness $(BUILD)/disk_boot.golden
	@touch $@

# ------------------------------------------------- the default slave on GP0

# `rtl/plumbing/cadr_gp0_default.sv` answers every address on `M_AXI_GP0` for a board
# that brings the port out without the pack side --- the two proving boards.
# A read nothing answers on GP0 hangs both Arm cores, measured on the board,
# so the property is that every transaction completes: `tb/cadr_gp0_default
# _tb.cpp` drives writes and reads of varying length, ID and spacing at
# addresses across the port's window and counts every handshake.  The arty
# lint holds that the module is wired where GP0 is; this holds that it
# answers.
$(BUILD)/obj_gp0_default/Vcadr_gp0_default: rtl/plumbing/cadr_gp0_default.sv \
                                            tb/cadr_gp0_default_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -Mdir $(BUILD)/obj_gp0_default \
	    --top-module cadr_gp0_default \
	    rtl/plumbing/cadr_gp0_default.sv $(abspath tb/cadr_gp0_default_tb.cpp)

$(BUILD)/gp0_default.pass: $(BUILD)/obj_gp0_default/Vcadr_gp0_default
	$(BUILD)/obj_gp0_default/Vcadr_gp0_default
	@touch $@

# ------------------------------------------------------- the display output

# `rtl/plumbing/cadr_display_out.sv` reads the CADR's bitmap out of the
# display's region of DDR over `S_AXI_HP3` and puts it on a raster. There is
# no muir reference and there could not be: muir's TV is a frame buffer and a
# frame clock with no raster at all, and this drives a monitor. So it is held
# to VESA's figures for the mode and to the bitmap, and `docs/display-output.md`
# is the design.
#
# `tb/cadr_display_out_tb.cpp` runs both clocks at their real and deliberately
# incommensurate periods against a modeled DDR poisoned injectively in the
# address, and reads the result the way a monitor does --- recovering the
# raster position from the syncs rather than from any counter inside the
# module. A whole frame is compared pixel for pixel, the picture against the
# words it comes from and the border black; the mode's figures are counted
# rather than sampled; every read burst is held to AXI, including the split at
# a 4 KB boundary that a 96-byte line forces; and a second configuration slows
# the port until it loses the race, because a stimulus fast enough hides the
# race it exists to show.
$(BUILD)/obj_display_out/Vcadr_display_out: rtl/plumbing/cadr_display_out.sv \
                                            tb/cadr_display_out_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Mdir $(BUILD)/obj_display_out \
	    --top-module cadr_display_out \
	    rtl/plumbing/cadr_display_out.sv $(abspath tb/cadr_display_out_tb.cpp)

$(BUILD)/display_out.pass: $(BUILD)/obj_display_out/Vcadr_display_out
	$(BUILD)/obj_display_out/Vcadr_display_out
	@touch $@

# The DVI transmitter: three TMDS channels and the clock channel.
#
# `tb/cadr_hdmi_tx_tb.cpp` carries a second encoder written from DVI 1.0's own
# pseudocode rather than from the RTL --- with N0 and N1 both present in every
# branch, which is the shape the fabric deliberately does not use --- and
# compares all three channels against it. The sweep is exhaustive over the
# encoder's whole state: every disparity value reachable from a control period
# is found by breadth-first search over the reference model, and all 256 byte
# values are tested in every one of them.
#
# WHAT IT DOES NOT HOLD is the serializer. `OSERDESE2` and `OBUFDS` are
# primitives, their stubs in `tb/cadr_arty_stubs.sv` tie their outputs low, and
# a check built on a stub confirms rather than compares. `build/arty.pass`
# lints `rtl/plumbing/xilinx7/cadr_hdmi_phy.sv` and the fitter is what stands
# behind it; `docs/display-output.md` says so rather than covering it with a
# model that could only agree with itself.
$(BUILD)/obj_hdmi_tx/Vcadr_hdmi_tx: rtl/plumbing/cadr_hdmi_tx.sv \
                                    rtl/plumbing/cadr_tmds_encode.sv \
                                    tb/cadr_hdmi_tx_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -Mdir $(BUILD)/obj_hdmi_tx \
	    --top-module cadr_hdmi_tx \
	    rtl/plumbing/cadr_hdmi_tx.sv rtl/plumbing/cadr_tmds_encode.sv \
	    $(abspath tb/cadr_hdmi_tx_tb.cpp)

$(BUILD)/hdmi_tx.pass: $(BUILD)/obj_hdmi_tx/Vcadr_hdmi_tx
	$(BUILD)/obj_hdmi_tx/Vcadr_hdmi_tx
	@touch $@

# ----------------------------------------------------- `M_AXI_GP0`, split
#
# `rtl/plumbing/cadr_gp0_split.sv` is the decode that lets the pack side, the
# Chaosnet cable, the serial line and the keyboard-and-mouse face share the
# port, and the property the whole arrangement exists for is that EVERY
# address on it is answered in both directions: a read nothing answers there
# hangs both Arm cores at one PC each, measured on the board, and no software
# guard can catch it.
#
# THE HARNESS IS THE ATTACHMENT.  `tb/cadr_gp0_split_harness.sv` wires the
# real five slaves behind the splitter exactly as `boards/arty-z7-20/
# cadr_arty.sv` does, each answering with something only it can answer, and
# puts `rtl/machine/cadr_io_board.sv` on the far side of the three card
# faces' seams --- so the check sweeps the window AND carries a frame, a
# character, a keystroke and a mouse's movement across.  `build/iob.pass` is
# what holds the card itself to muir; this holds the two halves meeting,
# which nothing did before.
GP0_SPLIT_SRC := tb/cadr_gp0_split_harness.sv $(GP0) \
                 rtl/plumbing/cadr_gp0_default.sv rtl/plumbing/cadr_disk_pack.sv \
                 rtl/machine/cadr_io_board.sv

$(BUILD)/obj_gp0_split/Vcadr_gp0_split_harness: $(GP0_SPLIT_SRC) \
                                                tb/cadr_gp0_split_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 \
	    -Mdir $(BUILD)/obj_gp0_split --top-module cadr_gp0_split_harness \
	    $(GP0_SPLIT_SRC) $(abspath tb/cadr_gp0_split_tb.cpp)

$(BUILD)/gp0_split.pass: $(BUILD)/obj_gp0_split/Vcadr_gp0_split_harness
	$(BUILD)/obj_gp0_split/Vcadr_gp0_split_harness
	@touch $@

# ----------------------------------------------------- `M_AXI_GP1`, split
#
# `rtl/plumbing/cadr_gp1_split.sv` is the decode that lets the console and
# the debug cable's carrier share the port, and the property the whole
# arrangement exists for is the one `gp0_split` holds on the other port:
# EVERY address on it is answered in both directions.  A read nothing answers
# there hangs both Arm cores at one PC each, measured on the board, and no
# software guard can catch it.  Until this the console answered the whole
# gigabyte by itself.
#
# THE HARNESS IS THE ATTACHMENT.  `tb/cadr_gp1_split_harness.sv` wires the
# real three slaves behind the splitter exactly as `boards/arty-z7-20/
# cadr_arty.sv` does, and puts MIT's own cable between the window and
# `rtl/machine/cadr_dbgin.sv` --- so the check sweeps the window AND reaches
# the diagnostic register block by both of the two roads the port now has.
# `build/console.pass` and `build/dbgin.pass` hold the two faces separately;
# this holds them meeting, which nothing did before.
GP1_SPLIT_SRC := tb/cadr_gp1_split_harness.sv $(GP1) \
                 rtl/plumbing/cadr_console.sv rtl/plumbing/cadr_debug_window.sv \
                 rtl/plumbing/cadr_gp0_default.sv \
                 rtl/machine/cadr_dbgin.sv rtl/machine/cadr_console_bus.sv \
                 rtl/machine/cadr_spy_registers.sv

$(BUILD)/obj_gp1_split/Vcadr_gp1_split_harness: $(GP1_SPLIT_SRC) \
                                                tb/cadr_gp1_split_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 \
	    -Mdir $(BUILD)/obj_gp1_split --top-module cadr_gp1_split_harness \
	    $(GP1_SPLIT_SRC) $(abspath tb/cadr_gp1_split_tb.cpp)

$(BUILD)/gp1_split.pass: $(BUILD)/obj_gp1_split/Vcadr_gp1_split_harness
	$(BUILD)/obj_gp1_split/Vcadr_gp1_split_harness
	@touch $@

# --------------------------------------------------------------- the console

# `rtl/plumbing/cadr_console.sv` is the sixteen diagnostic registers on `M_AXI_GP1`, so
# that a program in Linux can halt the machine, read its state and start it
# again.  muir's console is CC and its whole vocabulary is `crate::spy`; this
# is `spy_read` and `spy_write` reached from the processing system, with the
# register block `rtl/machine/cadr_spy_registers.sv` untouched between them.
#
# THE HARNESS AND NOT THE MODULE, and the harness is the attachment.  Joining
# a second master to the diagnostic bus means a mux at the register block's
# Unibus port and an arbiter in front of it, both of which belong in
# `rtl/machine/cadr_console_bus.sv`, which `rtl/machine/cadr_memory_path.sv` instantiates ---
# so what this check holds is the module the board carries and not a copy of
# it in a harness.  The
# processor in it is the real one, running MIT's boot PROM out of
# `build/rtl.golden` as `microcycle.pass` runs it --- so the machine the
# console stops is the one the reference describes, and the sixteen registers
# are compared against `Engine::spy_read`'s own answers, microcycle for
# microcycle.  It halts and starts the machine sixteen times and all 600,000
# microcycles still agree.
#
# It takes about seven seconds.
CONSOLE_SRC := rtl/machine/cadr_phase_gen.sv rtl/machine/cadr_microcycle.sv \
               rtl/machine/cadr_spy_registers.sv rtl/machine/cadr_console_bus.sv \
               rtl/machine/cadr_console_state.sv rtl/plumbing/cadr_console.sv \
               tb/cadr_console_harness.sv

$(BUILD)/obj_console/Vcadr_console_harness: $(CONSOLE_SRC) \
                                            tb/cadr_console_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_console \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    --top-module cadr_console_harness $(CONSOLE_SRC) \
	    $(abspath tb/cadr_console_tb.cpp)

$(BUILD)/console.pass: $(BUILD)/obj_console/Vcadr_console_harness \
                       $(BUILD)/rtl.golden $(BUILD)/boot_prom.hex
	$(BUILD)/obj_console/Vcadr_console_harness $(BUILD)/rtl.golden
	@touch $@

# --------------------------------------------------- the debug cable's DBGIN
#
# `rtl/machine/cadr_dbgin.sv` is the debuggee's end of MIT's debug cable --- the
# 74S139 at DBGIN 0A15, the modifier register, the two address latches, the
# error-status driver and the debug master's place on the Unibus --- and
# `rtl/plumbing/cadr_debug_window.sv` is the carrier, sixteen registers on a
# general-purpose AXI port that muir reaches with ordinary loads and stores.
# muir's half is built: `src/fabric.rs` at `e4d8aeb`, to the specification in
# muir issue #95.
#
# THE HARNESS AND NOT THE MODULES, and the harness is the attachment, for the
# reason the console's is: joining a third master to the diagnostic bus means
# the arm `rtl/machine/cadr_console_bus.sv` now carries, and the window's own
# attachment waits on a decision nobody has taken --- which general-purpose
# port it sits on.  `docs/debug-cable.md` poses that question with the
# numbers and carries the wiring as a patch.
#
# The processor in it is the real one, running MIT's boot PROM out of
# `build/rtl.golden`, and the register block is the real one.  So the claim is
# muir's own: a debugger over MIT's own cable halts this machine and reads a
# program counter whose value muir wrote down.
DBGIN_SRC := rtl/machine/cadr_phase_gen.sv rtl/machine/cadr_microcycle.sv \
             rtl/machine/cadr_spy_registers.sv rtl/machine/cadr_console_bus.sv \
             rtl/machine/cadr_dbgin.sv rtl/plumbing/cadr_debug_window.sv \
             tb/cadr_dbgin_harness.sv

$(BUILD)/obj_dbgin/Vcadr_dbgin_harness: $(DBGIN_SRC) \
                                        tb/cadr_dbgin_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_dbgin \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    --top-module cadr_dbgin_harness $(DBGIN_SRC) \
	    $(abspath tb/cadr_dbgin_tb.cpp)

$(BUILD)/dbgin.pass: $(BUILD)/obj_dbgin/Vcadr_dbgin_harness \
                     $(BUILD)/rtl.golden $(BUILD)/boot_prom.hex
	$(BUILD)/obj_dbgin/Vcadr_dbgin_harness $(BUILD)/rtl.golden
	@touch $@

# ------------------------------------------- the debug cable on one Pmod
#
# `rtl/plumbing/cadr_dbg_tx.sv` and `cadr_dbg_rx.sv` are the carrier that puts
# MIT's twenty-one wires on eight Pmod pins, four each way --- a sender and a
# receiver, two modules so that the connector above them can hold a receiver
# quiet while it drives the group that receiver watches.
# `rtl/plumbing/cadr_dbg_join.sv`
# is what lets the connector and the window share one DBGIN page.  Neither has
# a muir reference --- muir has the cable and no wires --- so what holds them
# is a property, which is the footing `cadr_axi_master.sv` is on.
#
# THE TESTBENCH IS THE CABLE.  The harness brings the eight wires of each
# connector out as ports, so the check delays them, skews the strobe against
# the data, shorts a line, crosses two and unplugs the lot.  It runs the two
# ends on two clocks at a twelfth of a tick for the phase where that matters,
# because a strobe sampled on a common clock is a strobe sampled against
# itself.
#
# And the far half of it is the composed path: the real window, the real
# DBGIN page, the real arbiter and the real register block, with the carrier
# between them, so the claim is a debugger halting this machine and reading
# its registers over eight pins rather than bits crossing a wire.
DBG_PMOD_SRC := tb/cadr_dbg_pmod_harness.sv rtl/plumbing/cadr_dbg_tx.sv \
                rtl/plumbing/cadr_dbg_rx.sv rtl/plumbing/cadr_dbg_join.sv \
                rtl/plumbing/cadr_debug_window.sv \
                rtl/machine/cadr_dbgin.sv rtl/machine/cadr_console_bus.sv \
                rtl/machine/cadr_spy_registers.sv

$(BUILD)/obj_dbg_pmod/Vcadr_dbg_pmod_harness: $(DBG_PMOD_SRC) \
                                              tb/cadr_dbg_pmod_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 \
	    -Mdir $(BUILD)/obj_dbg_pmod --top-module cadr_dbg_pmod_harness \
	    $(DBG_PMOD_SRC) $(abspath tb/cadr_dbg_pmod_tb.cpp)

$(BUILD)/dbg_pmod.pass: $(BUILD)/obj_dbg_pmod/Vcadr_dbg_pmod_harness
	$(BUILD)/obj_dbg_pmod/Vcadr_dbg_pmod_harness
	@touch $@

# ------------------------------------------------- the cable, end to end
#
# `rtl/plumbing/cadr_dbg_cable.sv` is the CONNECTOR: one Pmod header carrying
# both directions, and which four of its eight pins this board drives.  The
# carrier under it is held by `build/dbg_pmod.pass` and every module under
# THAT is held to muir; what is held here is the thing neither can see, which
# is that one board's own machine debugs another board's.
#
# The DUT is two boards.  Board A runs the DBGOUT page ---
# `rtl/machine/cadr_busint_regs.sv`, the four registers CC writes --- and
# board B answers them through `rtl/machine/cadr_dbgin.sv` on the arbiter and
# the diagnostic registers, which is CC's whole vocabulary.  All sixteen pads
# are harness ports with their tri-state enables beside them, so the testbench
# is the cable and can delay it, corrupt a beat, unplug it, and count any pad
# driven from both ends --- which is the one thing a connector with two roles
# on it has to make impossible.
DBG_CABLE_SRC := tb/cadr_dbg_cable_harness.sv rtl/plumbing/cadr_dbg_cable.sv \
                 rtl/plumbing/cadr_dbg_tx.sv rtl/plumbing/cadr_dbg_rx.sv \
                 rtl/plumbing/cadr_dbg_join.sv \
                 rtl/machine/cadr_dbgin.sv rtl/machine/cadr_busint_regs.sv \
                 rtl/machine/cadr_console_bus.sv rtl/machine/cadr_spy_registers.sv

$(BUILD)/obj_dbg_cable/Vcadr_dbg_cable_harness: $(DBG_CABLE_SRC) \
                                                tb/cadr_dbg_cable_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing \
	    -Mdir $(BUILD)/obj_dbg_cable --top-module cadr_dbg_cable_harness \
	    $(DBG_CABLE_SRC) $(abspath tb/cadr_dbg_cable_tb.cpp)

$(BUILD)/dbg_cable.pass: $(BUILD)/obj_dbg_cable/Vcadr_dbg_cable_harness
	$(BUILD)/obj_dbg_cable/Vcadr_dbg_cable_harness
	@touch $@

# ------------------------------------------------------------- the readout
#
# The window on the machine's memories, held to every word of every array in
# the processor.  **The same harness as the console's**, built again with a
# different testbench and into a directory of its own: the readout is reached
# through `cadr_console`'s page 0 and the arrays are inside `cadr_microcycle`,
# which is exactly what `tb/cadr_console_harness.sv` already puts together.  A
# harness of its own would be a second description of one attachment, which is
# what that file was extracted to stop.
#
# `--public-flat-rw` because the reference IS the arrays: the readout is the
# suspect and the storage is what it is held to, and a testbench that could
# only see the memories through the readout would be holding the readout to
# itself.  The header of `tb/cadr_readout_tb.cpp` says why that is not the
# shadow-memory mistake.
#
# **NO REFERENCE TRACE.**  What this check holds is a property of the window
# and not of what the machine computes, so the stimulus is MIT's boot PROM
# running out of the machine's own control store and then a poison from
# outside, injective in the memory and the address.  Its own output says how
# much of each memory the program varied, because the boot PROM's pass over
# the control store writes one constant and a check that did not say so would
# be reporting coverage it does not have.
$(BUILD)/obj_readout/Vcadr_console_harness: $(CONSOLE_SRC) \
                                            tb/cadr_readout_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 --public-flat-rw -Mdir $(BUILD)/obj_readout \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    --top-module cadr_console_harness $(CONSOLE_SRC) \
	    $(abspath tb/cadr_readout_tb.cpp)

$(BUILD)/readout.pass: $(BUILD)/obj_readout/Vcadr_console_harness \
                       $(BUILD)/boot_prom.hex
	$(BUILD)/obj_readout/Vcadr_console_harness
	@touch $@

# ------------------------------------------------ the readout's Linux side
#
# `cadr-readout` is the program that prints the machine's memories through the
# console's window, and this is its own host check: the program's core against
# a model of the window, with a poisoned machine behind it.  It needs nothing
# but a C compiler --- no board, no fabric, no Verilator.
#
# **IT IS THE TRANSPORT AND NOT THE FABRIC.**  `build/readout.pass` holds the
# second read ports, the pipeline and the echo against the arrays themselves;
# this holds that the program writes the address where the window takes it,
# reads the three words in the order that latches them together, halts the
# machine first, and REFUSES a word whose echo is not the address it asked
# for.  The numbers the two share --- the selectors, the three word offsets
# and the two values that mean nothing --- are written down in
# `rtl/machine/cadr_microcycle.sv` and repeated in the program's own headers,
# because C cannot read Verilog.
READOUT_SRC := boards/arty-z7-20/linux/buildroot/package/cadr-readout/src

CONSOLE_SRC_DIR := boards/arty-z7-20/linux/buildroot/package/cadr-console/src

# **cadr-common IS DEFINED HERE, ABOVE THE FIRST RULE THAT NAMES IT, AND NOT
# BESIDE THE OTHER PACKAGES FURTHER DOWN.**  A prerequisite list is expanded
# when the rule is READ, so a `$(wildcard $(COMMON_SRC)/*.c)` above the
# assignment expands against an empty variable and the rule quietly has no
# prerequisite at all --- the shape that left `arty_a7.pass` not re-running on
# a change to the memory path, and which the recipe cannot show because a
# recipe is expanded at run time.
COMMON_PKG   := boards/arty-z7-20/linux/buildroot/package/cadr-common
COMMON_SRC   := $(COMMON_PKG)/src

# ---------------------------------------------- the console program's own core
#
# **`cadr-console`'s HOST TEST HAD NEVER BEEN RUN BY `make check`.**  The
# package has carried `src/console_test.c` and a `check` target since the
# console landed --- 194 checks against a model of the slave, the words of
# every message included --- and nothing in this Makefile named it, where
# `cadr-readout`, `cadr-chaosnet`, `cadr-serial` and `cadr-terminal` all have
# theirs here.  So the one test that could have said the console's `step`
# reported a fabric that no longer exists was not being run.  It is now.
#
# **AND cadr-common's SOURCES ARE PREREQUISITES BECAUSE THIS CHECK BUILDS
# THEM.**  The logging every one of these programs says its lines through is
# there --- who a line is for, how many places it goes, and the cap that keeps
# a log off the board's RAM disk --- and this package's mutation list aims at
# it by name, as `serial.pass` and `terminal.pass` already do with the
# endpoint grammar.  Without these a change to `cadr_log.c` would leave this
# check stamped and unrun, which is this project's stale-artifact scar in a
# Makefile.
$(BUILD)/console_face.pass: $(CONSOLE_SRC_DIR)/console_face.c \
                            $(CONSOLE_SRC_DIR)/console_face.h \
                            $(CONSOLE_SRC_DIR)/console_host.c \
                            $(CONSOLE_SRC_DIR)/console_host.h \
                            $(CONSOLE_SRC_DIR)/console_test.c \
                            $(CONSOLE_SRC_DIR)/console_mutations.txt \
                            $(CONSOLE_SRC_DIR)/mutate.py \
                            $(wildcard $(COMMON_SRC)/*.c) \
                            $(wildcard $(COMMON_SRC)/cadr/*.h) \
                            $(CONSOLE_SRC_DIR)/cadr-console.c | $(BUILD)
	$(MAKE) -C $(CONSOLE_SRC_DIR) check
	@echo "console: the program's core agrees with a modeled slave, a reply to a person is"
	@echo "console: bare, and a --log goes to every destination named and is capped at 1 MiB"
	@touch $@

$(BUILD)/readout_face.pass: $(READOUT_SRC)/readout.c $(READOUT_SRC)/readout.h \
                            $(READOUT_SRC)/cadr_image.h \
                            $(READOUT_SRC)/readout_test.c \
                            $(READOUT_SRC)/cadr-readout.c | $(BUILD)
	$(MAKE) -C $(READOUT_SRC) check
	$(MAKE) -C $(READOUT_SRC) all COMMON=host
	$(MAKE) -C $(READOUT_SRC) clean
	@echo "readout: the program builds and its core agrees with a modeled window"
	@touch $@

# ------------------------------------------- the checkpoint, and muir itself

# `cadr-checkpoint` writes the board's machine as a muir checkpoint, and this
# is the only check in the repository whose judge is muir's own reader.
#
# **THE PROOF IS THE ROUND TRIP AND IT HAS THREE LEGS, BECAUSE ONE IS NOT
# ENOUGH.**  Measured, not assumed --- seven mutants of `chk_rtl.c` are built
# and run against each leg, and no leg catches all seven:
#
#   1. muir LOADS the file and SAVES IT BACK BYTE FOR BYTE.  This is muir's
#      own round-trip property (`tests/checkpoint.rs`, "the checkpoint loads
#      and saves as itself") and it holds the framing: every field at the
#      offset muir's reader expects, every array's count, every flag a 0 or a
#      1, every range check passed, and the packing muir's own rather than
#      merely a legal one.  It catches the mutant that drops a byte, and the
#      two that describe a display this machine has not got: muir's own
#      cross-check of the board against `--tv-board`, and the short read that
#      follows a color board claimed on a backplane with none.
#   2. muir's own REPORT of what it resumed names the microcycle count and
#      the nanoseconds the synthetic machine was given.  Two fields the
#      window really does read, asserted in muir's words rather than through
#      an exit code --- `vivado/probe.tcl`'s lesson, one program along.
#   3. the file's SHA-256 against the value recorded here.  **This is the leg
#      that catches a field carrying a WRONG VALUE in a RIGHT-SHAPED SLOT**,
#      which the round trip cannot see by construction: muir re-saves whatever
#      it read, so any valid value survives it.  Four of the seven mutants ---
#      the mouse's quadrature phases written 0 where a fresh mouse has 2,
#      `Machine::opc` taken from the OPC shift register instead of LPC, the
#      color map written all ones, and the sync program's origin written at
#      the machine's clock --- load, re-save identically, and are caught here
#      and nowhere else.
#
# **THE EIGHT ARE STATED TWICE AND BOTH MOVE TOGETHER**: `MUTANTS` in the
# package's own Makefile builds them and the loop below judges them, so one
# added in the first place alone is built and never run, and in the second
# alone is run and never built.
#
# **SO THIS DIGEST IS A GOLDEN VALUE AND MOVES LIKE ONE.**  It is of the file
# the host check writes from its own fixed synthetic machine, which is
# deterministic; it changes when muir's format changes, when `chk_rtl.c`
# changes, or when somebody gets a field wrong.  To move it: run the round
# trip, satisfy yourself that muir still takes the file, write the new value
# here, and say in the commit WHAT MOVED --- the same rule `muir.commit`
# states for a trace, because this is one.
CHECKPOINT_SRC  := boards/arty-z7-20/linux/buildroot/package/cadr-checkpoint/src
CHECKPOINT_WORK := $(HOME)/.cache/muir-fpga-checkpoint
# **MOVED WHEN THE COLOR MAP STOPPED BEING ZEROS.**  The fabric keeps the
# sixteen entries now and offers them on the console face's page 4, so
# `chk_rtl.c` writes the board's own map where it used to write forty-eight
# zeros --- and the host check's synthetic machine poisons the map for the
# reason it poisons main memory and the picture: a check that only ever ran
# it at zero would pass a program that wrote zeros, which is what this one
# used to do.  **The file also grew by 50 bytes, 561,465 to 561,515, and that
# is the packing and not a format change**: `chk.c` collapses a run of zeros
# the way muir's own `pack` does, so forty-eight zero bytes were a short run
# marker and forty-eight poisoned ones are forty-eight bytes behind a literal
# header.  Measured by writing the file both ways from one work directory ---
# the pack binding carries paths, so two directories give two sizes for
# reasons that have nothing to do with this.  muir still takes the file and
# still resumes at the same microcycle.
#
# **AND MOVED AGAIN WHEN THE CHECKPOINT FORMAT WENT 25 TO 26.**  muir's `Tv`
# carries the two sync bits the mode register was holding when the running
# program started, so `Tv::save` writes two more bools and `chk_rtl.c` writes
# them too.  **The file did not grow**, 561,515 bytes both ways: the two bools
# are zeros and `chk.c` collapses a run of zeros, so they joined the eight
# zero bytes `origin` already puts there rather than making a run of their
# own.  What moved is the version byte in the header and the length of that
# one run.  muir loads the file and saves it back byte for byte, and resumes
# at the same microcycle.
CHECKPOINT_SHA  := 25f6f4f5fbbf7f40537a30e2e8f9307f4069227fda80e4880ece7d4e7e2063e5
# What muir prints for the synthetic machine: 0x1234567890 microcycles and
# 0x9876543210 ticks of five nanoseconds each, the two the model sets.
CHECKPOINT_RESUMED := at 78187493520 microcycles, 3274101291600 ns, 1 memory boards
# muir's binary, built into golden's own target directory because muir is
# already golden's path dependency there and the library half is compiled
# once for both.
MUIR_BIN := golden/target/release/muir

$(BUILD)/checkpoint.pass: $(CHECKPOINT_SRC)/cadr-checkpoint.c \
                          $(CHECKPOINT_SRC)/checkpoint_test.c \
                          $(CHECKPOINT_SRC)/chk.c $(CHECKPOINT_SRC)/chk.h \
                          $(CHECKPOINT_SRC)/chk_rtl.c $(CHECKPOINT_SRC)/chk_rtl.h \
                          $(CHECKPOINT_SRC)/pack_bind.c $(CHECKPOINT_SRC)/pack_bind.h \
                          $(CHECKPOINT_SRC)/sha256.c $(CHECKPOINT_SRC)/sha256.h \
                          $(READOUT_SRC)/readout.c $(READOUT_SRC)/readout.h \
                          $(READOUT_SRC)/cadr_image.h | $(BUILD)
	$(MAKE) -C $(CHECKPOINT_SRC) check CHK=$(CHECKPOINT_WORK)/out.chk
	$(MAKE) -C $(CHECKPOINT_SRC) all COMMON=host READOUT=host
	$(MAKE) -C $(CHECKPOINT_SRC) clean
	$(MAKE) -C $(CHECKPOINT_SRC) mutants
	$(CARGO) build --quiet --release --manifest-path $(MUIR)/muir/Cargo.toml \
	    --bin muir --target-dir golden/target
	@set -e; W=$(CHECKPOINT_WORK); M=$(MUIR_BIN); \
	 $$M --rtl --stop-after 0 --resume $$W/out.chk --checkpoint $$W/back.chk \
	     > $$W/muir.log 2>&1 \
	   || { echo "checkpoint: muir REFUSED the file cadr-checkpoint wrote"; \
	        sed -n '$$p' $$W/muir.log; exit 1; }; \
	 cmp $$W/out.chk $$W/back.chk \
	   || { echo "checkpoint: muir loaded the file and saved DIFFERENT bytes"; exit 1; }; \
	 grep -q "$(CHECKPOINT_RESUMED)" $$W/muir.log \
	   || { echo "checkpoint: muir did not resume the machine the model wrote:"; \
	        grep '^resumed' $$W/muir.log; exit 1; }; \
	 echo "$(CHECKPOINT_SHA)  $$W/out.chk" | sha256sum -c --status - \
	   || { echo "checkpoint: the file is not the one this digest was recorded for."; \
	        echo "checkpoint: it is $$(sha256sum $$W/out.chk | cut -d' ' -f1)."; \
	        echo "checkpoint: muir still takes it, so this is a change and not"; \
	        echo "checkpoint: necessarily a fault --- say what moved and record it."; \
	        exit 1; }; \
	 echo "checkpoint: muir loaded $$(stat -c%s $$W/out.chk) bytes and saved them back identically,"; \
	 echo "checkpoint: resumed $$(grep '^resumed' $$W/muir.log | sed 's/^resumed: [^ ]* //'),"; \
	 echo "checkpoint: and the file is the one the digest was recorded for."; \
	 for m in 1 2 3 4 5 6 7 8; do \
	   $$W/checkpoint_test-$$m $$W $$W/mut-$$m.chk > $$W/mut-$$m.out 2>&1 \
	     || { echo "checkpoint: mutant $$m did not build or did not run: BROKEN"; \
	          cat $$W/mut-$$m.out; exit 1; }; \
	   what=$$(sed -n 's/^checkpoint: THIS IS A MUTANT --- //p' $$W/mut-$$m.out); \
	   if ! $$M --rtl --stop-after 0 --resume $$W/mut-$$m.chk \
	            --checkpoint $$W/mut-$$m-back.chk > $$W/mut-$$m.log 2>&1; then \
	     echo "checkpoint: mutant $$m caught, muir refused it --- $$what"; \
	   elif ! cmp -s $$W/mut-$$m.chk $$W/mut-$$m-back.chk; then \
	     echo "checkpoint: mutant $$m caught, muir saved other bytes --- $$what"; \
	   elif ! echo "$(CHECKPOINT_SHA)  $$W/mut-$$m.chk" | sha256sum -c --status -; then \
	     echo "checkpoint: mutant $$m caught by the digest alone --- $$what"; \
	   else \
	     echo "checkpoint: mutant $$m SURVIVED all three legs --- $$what"; exit 1; \
	   fi; \
	 done
	@touch $@

# ------------------------------------ the I/O board's two Linux programs
#
# The Chaosnet and the serial line are one card in the fabric --- the
# interface at `0o764140`-`0o764156` and the 2651 at `0o764160`-`0o764176` on
# `rtl/machine/cadr_io_board.sv` --- and two programs on the processing
# system, because this project's rule is one package per program.  These are
# their host checks: everything about them that is NOT the fabric, on the
# build host, with no board, no Verilator and no network.
#
# **WHAT EACH HOLDS, AND WHAT IT CANNOT.**  `cadr_io_board.sv`'s own checks
# hold the registers against muir.  These hold the other side of the same
# registers: for the Chaosnet, the packet's word layout and its check word,
# the register face's handshake with the fabric, and CHUDP's frame against a
# datagram's literal bytes; for the serial line, the TCP endpoint against a
# real client on the loopback address.  The Chaosnet program answers no
# services --- a CADR has none in it, and muir removed its own at `79c7590`
# --- so there are none to check.  Neither can hold the SEAM between the
# two halves, because only one half exists in each check --- which is why the
# register face is behind one header in each program and why that header says
# what it assumed.
#
# Both run their own mutation lists, so a check that stops biting says so.
#
# The prerequisites are a wildcard where the readout's and the checkpoint's
# are named one by one, and the difference is deliberate: those have four or
# five sources and this has twelve, so an explicit list would be a list
# somebody forgets to add to --- and a source added to the check but not to
# the rule is a check that does not re-run when it changes, which is the
# quiet half of a stale-artifact failure this project has met three times.
#
# **AND `cadr-terminal`'s JOINS THEM, WHICH IS A HOLE THE SCREEN SLICE LEFT.**
# That program has had its own `make -C src check` since it was written --- 420
# checks and fifteen mutations --- and nothing in `make check` ran it, so a
# change to it was gated by whoever remembered.  It has a keyboard and a mouse
# in it now, and the half of them that is a MAPPING has no other reference:
# `input_keymap.h` is generated from muir but the state machine over it is
# written out by hand, and this is what holds it.
DISK_PACKS_PKG := boards/arty-z7-20/linux/buildroot/package/cadr-disk-packs
CHAOSNET_PKG := boards/arty-z7-20/linux/buildroot/package/cadr-chaosnet
CHAOSNET_SRC := $(CHAOSNET_PKG)/src
SERIAL_PKG   := boards/arty-z7-20/linux/buildroot/package/cadr-serial
SERIAL_SRC   := $(SERIAL_PKG)/src
TERMINAL_PKG := boards/arty-z7-20/linux/buildroot/package/cadr-terminal
TERMINAL_SRC := $(TERMINAL_PKG)/src
USB_INPUT_PKG := boards/arty-z7-20/linux/buildroot/package/cadr-usb-input
USB_INPUT_SRC := $(USB_INPUT_PKG)/src

# The init script and the check that runs it are prerequisites too.  The
# package ships three things --- the program, its mutations and the script that
# starts it at boot --- and until the script joined this check a change to it
# was gated by whoever remembered, which is the shape this file already
# records for the terminal's own tests.
$(BUILD)/chaosnet.pass: $(wildcard $(CHAOSNET_SRC)/*.c) \
                        $(wildcard $(CHAOSNET_SRC)/*.h) \
                        $(CHAOSNET_SRC)/chaos_mutations.txt \
                        $(CHAOSNET_SRC)/chaos_test_boot.sh \
                        $(CHAOSNET_PKG)/S87cadr-chaosnet \
                        $(COMMON_SRC)/fpgarc.sh \
                        $(COMMON_SRC)/daemon.sh \
                        $(CHAOSNET_SRC)/mutate.py | $(BUILD)
	$(MAKE) -C $(CHAOSNET_SRC) check
	$(MAKE) -C $(CHAOSNET_SRC) all COMMON=host
	$(MAKE) -C $(CHAOSNET_SRC) clean
	@echo "chaosnet: the program builds, its packet, its register face and CHUDP agree with muir, and its init script waits for the network"
	@touch $@

# **ONE `fpgarc` AND FIVE INIT SCRIPTS.**  The card carries one file of flags
# for the CADR in the fabric and several programs serve that machine, each of
# them refusing a flag it does not know.  So each init script names the flags
# its own program owns and hands the file to cadr-common's reader, which gives
# back those lines and no others.  This check runs all five real scripts
# against one file with a line for each of them, with the tools they call
# stubbed, and holds every program to getting its own and nobody else's.  It
# also holds the boot button's step --- `--no-auto-boot` halting the machine
# before the drive comes present --- and the two ways the card script writes
# that line.
#
# The scripts are prerequisites, not only the reader: the flag lists are in
# them, and a list that goes wrong is exactly what this is for.
#
# **AND THE TWO CARD SCRIPTS ARE PREREQUISITES BECAUSE THIS CHECK RUNS BLOCKS
# OF THEM.**  It lifts the `fpgarc` generator, the card's copy block and the
# stale-loader refusal out of `mksd-buildroot.sh`, and the address guard out of
# `mksd-release.sh`, each on its own anchors, and runs them alone.  Without
# these a change to either would leave the check stamped and unrun --- this
# repository's stale-artifact scar in a Makefile --- and the release guard is
# exactly the thing that sat broken because nobody ran it.
$(BUILD)/fpgarc.pass: $(COMMON_SRC)/fpgarc.sh \
                      $(COMMON_SRC)/daemon.sh \
                      $(COMMON_SRC)/fpgarc_test.sh \
                      $(CHAOSNET_PKG)/S87cadr-chaosnet \
                      $(TERMINAL_PKG)/S85cadr-terminal \
                      $(SERIAL_PKG)/S86cadr-serial \
                      $(USB_INPUT_PKG)/S88cadr-usb-input \
                      $(DISK_PACKS_PKG)/S80cadr-disk-packs \
                      boards/arty-z7-20/linux/mksd-buildroot.sh \
                      boards/arty-z7-20/linux/mksd-release.sh | $(BUILD)
	$(MAKE) -C $(COMMON_SRC) check
	@echo "fpgarc: one file of flags on the card reaches five programs, each gets the flags it"
	@echo "fpgarc: owns and no others, --no-auto-boot holds the machine before the drive, and"
	@echo "fpgarc: the card mirrors the server: the board's four files under the board's folder"
	@touch $@

# **cadr-common's SOURCES ARE PREREQUISITES BECAUSE THIS CHECK COMPILES
# THEM.**  The endpoint grammar `--serial` reads is there, shared with the
# screen so that one grammar cannot become two, and a record in this package's
# list aims at it by name.  Without these a change to it would leave the check
# stamped and unrun, which is this project's stale-artifact scar in a Makefile.
$(BUILD)/serial.pass: $(wildcard $(SERIAL_SRC)/*.c) $(wildcard $(SERIAL_SRC)/*.h) \
                      $(wildcard $(COMMON_SRC)/*.c) $(wildcard $(COMMON_SRC)/cadr/*.h) \
                      $(SERIAL_SRC)/serial_mutations.txt \
                      $(SERIAL_SRC)/mutate.py | $(BUILD)
	$(MAKE) -C $(SERIAL_SRC) check
	$(MAKE) -C $(SERIAL_SRC) all COMMON=host
	$(MAKE) -C $(SERIAL_SRC) clean
	@echo "serial: the program builds, and the cable's far end agrees with muir's endpoint"
	@touch $@

# cadr-common's sources for the same reason the serial line's check has them:
# the endpoint grammar `--terminal` reads is there and a record aims at it.
$(BUILD)/terminal.pass: $(wildcard $(TERMINAL_SRC)/*.c) $(wildcard $(TERMINAL_SRC)/*.h) \
                        $(wildcard $(COMMON_SRC)/*.c) $(wildcard $(COMMON_SRC)/cadr/*.h) \
                        $(TERMINAL_SRC)/screen_mutations.txt \
                        $(TERMINAL_SRC)/mutate.py | $(BUILD)
	$(MAKE) -C $(TERMINAL_SRC) check
	$(MAKE) -C $(TERMINAL_SRC) all COMMON=host
	$(MAKE) -C $(TERMINAL_SRC) clean
	@echo "terminal: the program builds, its pixels agree with muir's own rule, and a viewer's"
	@echo "terminal: keys become MIT's key positions through muir's own mapping"
	@touch $@

# **THE USB PROGRAM'S CHECK BUILDS THE SCREEN'S SOURCES TOO**, so the screen's
# files are prerequisites of it: what it holds is the whole road from a key
# code on the board's own USB port to a word at the machine, and half of that
# road is cadr-terminal's.  A change to either package must re-run it.  The
# program itself links none of the screen's files; the Makefile in its src/
# says which of its two builds is which.
$(BUILD)/usb_input.pass: $(wildcard $(USB_INPUT_SRC)/*.c) $(wildcard $(USB_INPUT_SRC)/*.h) \
                         $(wildcard $(TERMINAL_SRC)/*.c) $(wildcard $(TERMINAL_SRC)/*.h) \
                         $(wildcard $(COMMON_SRC)/*.c) $(wildcard $(COMMON_SRC)/cadr/*.h) \
                         $(USB_INPUT_SRC)/usb_mutations.txt \
                         $(USB_INPUT_PKG)/S88cadr-usb-input \
                         $(COMMON_SRC)/fpgarc.sh $(COMMON_SRC)/daemon.sh \
                         $(USB_INPUT_SRC)/mutate.py | $(BUILD)
	$(MAKE) -C $(USB_INPUT_SRC) check
	$(MAKE) -C $(USB_INPUT_SRC) all COMMON=host
	$(MAKE) -C $(USB_INPUT_SRC) clean
	@echo "usb_input: the program builds, a USB key becomes MIT's own key position with the"
	@echo "usb_input: shift level applied here, and a burst obeys the machine's own pacing"
	@touch $@

$(BUILD):
	@mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD) golden/target

# ------------------------------------------------------------ Linux, Buildroot

# The image the processing system boots: mainline U-Boot with its SPL as the
# first-stage loader, mainline Linux, a BusyBox root filesystem, all from a
# Buildroot pinned by version and sha256 like the BSP and the System 100
# archive.  boards/arty-z7-20/linux/buildroot/ is the BR2_EXTERNAL tree --- the defconfig, the
# board's device tree, the start-up routine generated from boards/arty-z7-20/vivado/ps7_init.ops,
# the kernel config, U-Boot's environment --- and every file in it says why it
# is as it is.  docs/boot.md, "The Buildroot image", is the procedure.
#
# THE BUILD IS NOT UNDER build/ AND NOT UNDER /tmp.  It is several gigabytes
# and takes an hour the first time; /tmp is a RAM disk on the build host.
# BR_WORK puts the Buildroot source and its output directory under ~/.cache
# and can be pointed elsewhere.  The downloads go to vendor/buildroot-dl,
# gitignored with the rest of vendor/, so a second build fetches nothing:
# BR2_DL_DIR in the defconfig says so relative to the external tree.
#
# The Buildroot tarball is fetched by hand, like the BSP, and summed before
# use.  buildroot.org publishes no sha256 file for it (only a GPG .sign); the
# sum below is of the tarball as fetched on 2026-09-10 and is the claim.
#
# MAKEFLAGS is cleared for the inner make: Buildroot runs its own parallel
# builds per package (BR2_JLEVEL, all cores by default) and a top-level -j
# handed down to it is a different, less tested mode.
#
# THE BUILD HOST'S COREUTILS ARE NOT GNU's.  Ubuntu 26.04 ships uutils
# coreutils, with the GNU ones beside them as /usr/bin/gnu*.  Buildroot's
# dependency check refuses the uutils `install` outright
# (support/dependencies/dependencies.sh, uutils issue 12166) and asks for a
# system-wide update-alternatives; and the check is not the end of it ---
# U-Boot's SPL alignment step is `dd conv=block,sync bs=4`
# (scripts/Makefile.xpl), which uutils dd rejects, measured.  Rather than
# change the machine, $(BR_WORK)/bin holds a symlink for every /usr/bin/gnu*
# under its plain name and goes first on the PATH of the inner make only.  On
# a host without gnu* binaries the directory stays empty and nothing changes.
BR_VERSION  := 2026.02.3
BR_TARBALL  := vendor/buildroot-$(BR_VERSION).tar.xz
BR_SHA      := 5a59e7501b0b4ec52c41f4bfa79412320e0b37eae5f719605a258e8d0c6fc7fb
BR_URL      := https://buildroot.org/downloads/buildroot-$(BR_VERSION).tar.xz
BR_WORK     ?= $(HOME)/.cache/muir-fpga-buildroot
BR_SRC      := $(BR_WORK)/buildroot-$(BR_VERSION)
BR_OUT      := $(BR_WORK)/out
BR_EXTERNAL := $(abspath boards/arty-z7-20/linux/buildroot)
# The Cora Z7-07S's image is built from BOTH external trees, because the
# packages live in the Arty Z7-20's and there is one copy of them; the second
# tree holds only the board.  Its output goes in a directory of its own, so
# the two images cannot overwrite each other and a rebuild of one does not
# throw the other away.
BR_EXTERNAL_CORA := $(BR_EXTERNAL):$(abspath boards/cora-z7-07s/linux/buildroot)
BR_OUT_CORA := $(BR_WORK)/out-cora
BR_GEN_PS7_CORA := boards/cora-z7-07s/linux/buildroot/board/cora-z7-07s/uboot/gen_ps7_init_gpl.py
BR_GEN_PS7  := boards/arty-z7-20/linux/buildroot/board/arty-z7-20/uboot/gen_ps7_init_gpl.py
# The packages `buildroot-rebuild` has to force are exactly those Buildroot's
# `local` site method builds out of a src/ directory in this tree, so the list
# is derived from the .mk files rather than typed out.  A package added under
# package/ joins it by existing.  A typed list rots silently, and this one had:
# cadr-checkpoint was missing from it, so the second build after an edit to
# that program built the old sources without saying so.
#
# muir falls out of the derivation and should.  Its version IS the pin in
# muir.commit, so a new pin is a new build directory and Buildroot rebuilds it
# unasked; package/muir/muir.mk's header says the same thing from the other
# side.  uboot and linux are Buildroot's own packages reading our files through
# BR2_EXTERNAL options and external.mk's hooks, so they are named.  cadr-common
# is named ahead of the derived list and filtered out of it, because its
# consumers link the library it puts in the staging tree and a stale one would
# be linked into every program.
#
# `=` rather than `:=`, so the grep runs only when a buildroot target does.
BR_LOCAL_PKGS = $(sort $(notdir $(patsubst %/,%,$(dir $(shell \
    grep -l '_SITE_METHOD = local' $(BR_EXTERNAL)/package/*/*.mk)))))
BR_FORCE_PKGS = uboot linux cadr-common \
    $(filter-out cadr-common,$(BR_LOCAL_PKGS))

# AND A PACKAGE THIS BOARD'S .config DOES NOT SELECT MUST NOT BE FORCED.
# `<pkg>-reconfigure` builds and installs a package whatever the configuration
# says --- Buildroot defines those targets for every package in the tree, not
# for the selected ones --- and Buildroot never removes what it installed.
# Measured on this build host: the Cora Z7-07S's output directory carried
# `usr/bin/cadr-usb-input` and `etc/init.d/S88cadr-usb-input`, installed by a
# forcing run typed by hand, on a board whose defconfig has no USB input.  That
# is the ghost `board/arty-z7-20/post-build.sh` stops the build for, made by
# the rebuild itself --- and it did stop the build, at `target-finalize`, which
# is why the image beside it was never written again and went to the board a
# commit behind its own target tree.
#
# So the list is filtered against the `.config` the defconfig line has just
# written, in the shell, at the moment it is used.  It is ONE list for both
# boards for the reason a second forcing target was refused before it existed:
# two lists rot apart.  The filter is what makes one list safe for a board that
# leaves a package out.
define BR_FORCE
	set -e; force=; \
	for name in $(BR_FORCE_PKGS); do \
	    cfg=$(BR_EXTERNAL)/package/$$name/Config.in; \
	    if [ -f $$cfg ]; then \
	        sym=`sed -n 's/^config \(BR2_PACKAGE_[A-Z0-9_]*\)[[:space:]]*$$/\1/p' $$cfg | head -1`; \
	        [ -n "$$sym" ] || { \
	            echo "$$cfg declares no BR2_PACKAGE_ symbol, so this cannot tell"; \
	            echo "whether the package is in this board's image"; exit 1; }; \
	        grep -qx "$$sym=y" $(1)/.config || { \
	            echo "buildroot: $$name is not in this board's image, so it is not forced"; \
	            continue; }; \
	    fi; \
	    force="$$force $$name-reconfigure"; \
	done; \
	PATH=$(BR_WORK)/bin:$$PATH MAKEFLAGS= $(BR_MAKE) -C $(BR_SRC) O=$(1) $$force
endef

# The image is opened and compared against the target tree it was made from,
# after it is written, on every one of the four targets below.  Its header says
# what went wrong without it; in one line, an image can be older than the
# packages in its own output directory and nothing anywhere says so.  It is
# the counterpart of `post-build.sh`, which runs BEFORE the image and asks a
# question this one cannot: whether the TARGET holds only what the packages
# install.  Neither sees the other's fault.
BR_ROOTFS_CHECK := boards/arty-z7-20/linux/rootfs_check.py
# Not written as $(MAKE) in the recipe: GNU make runs any recipe line that
# names $(MAKE) even under -n, so `make -n buildroot` would start the build.
# The inner make gets a clean MAKEFLAGS anyway (see above), so nothing the
# sub-make convention would have carried is lost.
BR_MAKE     := $(MAKE)

.PHONY: buildroot buildroot-check buildroot-packages-check buildroot-rebuild \
        buildroot-cora buildroot-cora-check buildroot-cora-rebuild

# The generated start-up routine has to be what boards/arty-z7-20/vivado/ps7_init.ops gives
# today, or U-Boot would be built from a stale claim.  Pure Python, no
# Vivado, so it runs anywhere the repository does.
buildroot-check: buildroot-packages-check
	@python3 $(BR_GEN_PS7) --check

# Both ways the derivation above can come out short are failures here rather
# than quiet omissions.  A .mk that declares no site method at all cannot be
# classified, and a grep that matched nothing would leave the list empty and
# force no package of ours --- which is the shape of every silent-omission bug
# this repository has recorded, from an XDC foreach that applied to nothing to
# a package that went on building its old sources.  It is a target of its own
# because the packages are one tree and every board's image is built from
# them, so every board's build asserts it while neither board's build asserts
# the other's start-up routine.
buildroot-packages-check:
	@for mk in $(BR_EXTERNAL)/package/*/*.mk; do \
	    grep -q '_SITE_METHOD = ' $$mk || { \
	        echo "$$mk declares no _SITE_METHOD, so buildroot-rebuild cannot tell"; \
	        echo "whether this package is built from files in this tree"; exit 1; }; \
	done
	@test -n "$(BR_LOCAL_PKGS)" || { \
	    echo "no package under $(BR_EXTERNAL)/package declares _SITE_METHOD = local;"; \
	    echo "buildroot-rebuild would force nothing of ours"; exit 1; }

buildroot: buildroot-check
	@test -f $(BR_TARBALL) || { \
	    echo "no Buildroot at $(BR_TARBALL); fetch it with"; \
	    echo "  curl -o $(BR_TARBALL) $(BR_URL)"; exit 1; }
	@echo "$(BR_SHA)  $(BR_TARBALL)" | sha256sum -c --quiet - \
	    || { echo "$(BR_TARBALL) is not the Buildroot this image was built with"; exit 1; }
	@mkdir -p $(BR_WORK)/bin vendor/buildroot-dl
	@for f in /usr/bin/gnu*; do [ -x "$$f" ] && ln -sf "$$f" "$(BR_WORK)/bin/$${f#/usr/bin/gnu}"; done; true
	@test -d $(BR_SRC) || tar xJf $(BR_TARBALL) -C $(BR_WORK)
	PATH=$(BR_WORK)/bin:$$PATH MAKEFLAGS= $(BR_MAKE) -C $(BR_SRC) O=$(BR_OUT) BR2_EXTERNAL=$(BR_EXTERNAL) arty_z7_20_defconfig
	PATH=$(BR_WORK)/bin:$$PATH MAKEFLAGS= $(BR_MAKE) -C $(BR_SRC) O=$(BR_OUT)
	@python3 $(BR_ROOTFS_CHECK) $(BR_EXTERNAL) $(BR_OUT) $(BR_OUT)/images/rootfs.cpio.uboot
	@echo "buildroot: images in $(BR_OUT)/images:"
	@ls -l $(BR_OUT)/images/ | grep -v '^total'

# Buildroot does not watch our files: a change under boards/arty-z7-20/linux/buildroot/ to
# U-Boot's environment, its fragment, the kernel config, the tree or the
# sources of our own programs is not seen by a plain `make buildroot` once the
# package has a build stamp.  This forces every package that reads them to
# reconfigure and rebuild, then finishes the image as `buildroot` does.  Which
# packages those are is derived at BR_FORCE above rather than named here, so
# that a package cannot be left out of it, and filtered there against this
# board's own .config so that one cannot be forced into an image that does not
# have it.
buildroot-rebuild: buildroot-check
	PATH=$(BR_WORK)/bin:$$PATH MAKEFLAGS= $(BR_MAKE) -C $(BR_SRC) O=$(BR_OUT) BR2_EXTERNAL=$(BR_EXTERNAL) arty_z7_20_defconfig
	$(call BR_FORCE,$(BR_OUT))
	PATH=$(BR_WORK)/bin:$$PATH MAKEFLAGS= $(BR_MAKE) -C $(BR_SRC) O=$(BR_OUT)
	@python3 $(BR_ROOTFS_CHECK) $(BR_EXTERNAL) $(BR_OUT) $(BR_OUT)/images/rootfs.cpio.uboot
	@echo "buildroot: images in $(BR_OUT)/images:"
	@ls -l $(BR_OUT)/images/ | grep -v '^total'

# ------------------------------------------------ the Cora Z7-07S's image
#
# The same Buildroot, the same packages and the same kernel configuration,
# with this board's device tree, start-up routine and U-Boot environment.
# `boards/cora-z7-07s/linux/buildroot/configs/cora_z7_07s_defconfig` says what
# it leaves out and why --- there is no USB input on this board.
#
# The board boots this image from its card and runs the machine on it.  What
# holds the configuration beyond that is that it is the other board's with the
# differences its own header names, and `buildroot-cora-check`, which says the
# start-up routine the SPL would run is what this board's committed `.ops`
# gives.
#
# **AND IT HAS A REBUILD TARGET OF ITS OWN, BECAUSE `buildroot-rebuild` DOES
# NOT REACH IT.**  What stood here said there was no need for one --- that the
# packages are the other tree's, so `buildroot-rebuild` forces them --- and
# that is false: `buildroot-rebuild` acts on `O=$(BR_OUT)` and this board's
# output directory keeps its own build stamps, so it forces nothing here.  The
# image that went to the board carried a `cadr-console` and three init scripts
# from an earlier commit because of it.  The second list the old comment was
# afraid of does not exist: both rebuild targets call `BR_FORCE` above, which
# is one list, derived, and filtered by the board's own `.config`.
buildroot-cora-check: buildroot-packages-check
	@python3 $(BR_GEN_PS7_CORA) --check

buildroot-cora: buildroot-cora-check
	@test -f $(BR_TARBALL) || { \
	    echo "no Buildroot at $(BR_TARBALL); fetch it with"; \
	    echo "  curl -o $(BR_TARBALL) $(BR_URL)"; exit 1; }
	@echo "$(BR_SHA)  $(BR_TARBALL)" | sha256sum -c --quiet - \
	    || { echo "$(BR_TARBALL) is not the Buildroot this image was built with"; exit 1; }
	@mkdir -p $(BR_WORK)/bin vendor/buildroot-dl
	@for f in /usr/bin/gnu*; do [ -x "$$f" ] && ln -sf "$$f" "$(BR_WORK)/bin/$${f#/usr/bin/gnu}"; done; true
	@test -d $(BR_SRC) || tar xJf $(BR_TARBALL) -C $(BR_WORK)
	PATH=$(BR_WORK)/bin:$$PATH MAKEFLAGS= $(BR_MAKE) -C $(BR_SRC) O=$(BR_OUT_CORA) BR2_EXTERNAL=$(BR_EXTERNAL_CORA) cora_z7_07s_defconfig
	PATH=$(BR_WORK)/bin:$$PATH MAKEFLAGS= $(BR_MAKE) -C $(BR_SRC) O=$(BR_OUT_CORA)
	@python3 $(BR_ROOTFS_CHECK) $(BR_EXTERNAL_CORA) $(BR_OUT_CORA) $(BR_OUT_CORA)/images/rootfs.cpio.uboot
	@echo "buildroot-cora: images in $(BR_OUT_CORA)/images:"
	@ls -l $(BR_OUT_CORA)/images/ | grep -v '^total'

# The counterpart of `buildroot-rebuild`, in this board's output directory and
# with both external trees: the same three steps --- apply the defconfig, force
# every package that reads our files and is in this image, finish the image ---
# and the same check of the image afterwards.
buildroot-cora-rebuild: buildroot-cora-check
	PATH=$(BR_WORK)/bin:$$PATH MAKEFLAGS= $(BR_MAKE) -C $(BR_SRC) O=$(BR_OUT_CORA) BR2_EXTERNAL=$(BR_EXTERNAL_CORA) cora_z7_07s_defconfig
	$(call BR_FORCE,$(BR_OUT_CORA))
	PATH=$(BR_WORK)/bin:$$PATH MAKEFLAGS= $(BR_MAKE) -C $(BR_SRC) O=$(BR_OUT_CORA)
	@python3 $(BR_ROOTFS_CHECK) $(BR_EXTERNAL_CORA) $(BR_OUT_CORA) $(BR_OUT_CORA)/images/rootfs.cpio.uboot
	@echo "buildroot-cora: images in $(BR_OUT_CORA)/images:"
	@ls -l $(BR_OUT_CORA)/images/ | grep -v '^total'

# ------------------------------------------------------- MD on the composed
# machine
#
# `md_hold` and `md_inject` ask whether MD can be left holding a stale word,
# of `cadr_microcycle`, where the bus is muir's stimulus.  This asks it of the
# WHOLE machine with only DDR modeled, and walks the acknowledgment across
# the microcycle so the strobe lands at every phase.  It answers the open
# question of whether the DESTMDR/-LOADMD coincidence can be placed at all ---
# and the answer is no, with the reason named: -LOADMD cannot fall before
# -MEMACK on either bus, and MBUSY clears six ticks after it.
#
# It also compares the direction of every DDR transaction against the
# processor's own WRCYC, which nothing else in `make check` does.
$(BUILD)/obj_md_compose/Vcadr_machine: $(MACHINE) tb/cadr_md_compose_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 --public-flat-rw -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_md_compose \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE) $(abspath tb/cadr_md_compose_tb.cpp)

$(BUILD)/md_compose.pass: $(BUILD)/obj_md_compose/Vcadr_machine $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_md_compose/Vcadr_machine
	@touch $@

# ------------------------------------------------------- the halted machine
#
# A halted machine must go on making master clocks, and CC's own entry ---
# `CC-STOP-MACH` and the five microinstructions `CC-FULL-SAVE` forces, the
# last of them a `SRCMD` read of MD --- must not park the ring.  `Rtl::step`
# answers a halted machine before it looks at the bus at all, so muir never
# takes a `-HANG` there; this is that property on the composed machine, where
# the memory path is under the processor and a memory cycle can actually be
# outstanding.  `sstep` scripts the same register against muir row for row
# and its own header says it never reaches a memory cycle.
$(BUILD)/obj_park/Vcadr_machine: $(MACHINE) tb/cadr_park_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 --public-flat-rw -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_park \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE) $(abspath tb/cadr_park_tb.cpp)

$(BUILD)/park.pass: $(BUILD)/obj_park/Vcadr_machine $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_park/Vcadr_machine
	@touch $@

# ================= THE SOFT PROCESSING SYSTEM, Arty A7-100 =================
#
# The Artix has no processing system, so a RISC-V core in fabric masters the
# same register faces the Zynq's ARM cores master on the other two boards, and
# runs firmware built here.  `rtl/plumbing/cadr_soc.sv` is the system,
# `third_party/ibex/` is the core, `boards/arty-a7-100/firmware/` is the
# program, and `tb/cadr_soc_harness.sv` puts the three together with the
# machine and the four faces exactly as `boards/arty-a7-100/cadr_arty_a7.sv`
# does.
#
# **THE TOOLCHAIN IS NAMED AND ITS ABSENCE IS FATAL.**  A firmware is the one
# thing here that needs a compiler this repository does not otherwise want, and
# a rule that skipped quietly would leave a bitstream carrying whatever hex was
# last built --- which is the stale-artifact trap waiting to happen.  So the
# recipe checks, and says what to install.

RISCV_CC      ?= riscv64-unknown-elf-gcc
RISCV_OBJCOPY ?= riscv64-unknown-elf-objcopy
RISCV_SIZE    ?= riscv64-unknown-elf-size

define SOC_NEED_TOOLCHAIN
@command -v $(RISCV_CC) >/dev/null 2>&1 || { \
  echo "$(RISCV_CC) is not installed, and the soft processing system's"; \
  echo "firmware cannot be built without it.  On Debian and Ubuntu:"; \
  echo ""; \
  echo "    sudo apt-get install gcc-riscv64-unknown-elf \\"; \
  echo "                         picolibc-riscv64-unknown-elf"; \
  echo ""; \
  echo "picolibc is not optional: it is the only C library on this"; \
  echo "toolchain that ships headers, and the shared drivers include"; \
  echo "<string.h> and <stdio.h>.  Any other riscv32 toolchain works if"; \
  echo "RISCV_CC names it."; \
  exit 1; }
endef

# --- the firmware -----------------------------------------------------------
#
# **TWO OF THE FIVE SOURCES ARE THE ARTY Z7-20's AND ARE COMPILED WHERE THEY
# LIVE.**  `console_face.c` is the console's register face and `pack_side.c`
# is the disk pack side's, and every line of both is as true of a soft core as
# of an ARM one: the register numbers are the fabric's and the only thing that
# differs is how a word reaches an address.  A copy here would be a second
# description of one register face.
#
# **AND THIS RULE IS THE ONLY THING HOLDING THAT FILE TO BEING A FACE.**  The
# console program has words that are not cycles on the bus --- `trace-keys`
# reads two pid files and signals two daemons --- and the day one of them was
# written into `console_face.c` this link FAILED, nothing in the firmware
# calling it: `fopen` alone drags picolibc's stdio in, wanting `open`,
# `close`, `read`, `write` and `lseek`, and `sbrk` wants a `__heap_end` that
# is not there.  Such words live in `console_host.c`, which only the Linux
# builds compile and which no rule here names.  So `make build/soc.pass` is
# the check on a boundary that is otherwise a matter of opinion.
#
# **THEY BELONG SOMEWHERE NEUTRAL AND THEY ARE NOT THERE YET.**  A file under
# `boards/arty-z7-20/linux/` that a third board compiles is the same shape as
# the three Vivado scripts this repository reads out of that directory from two
# others, and those are owed a move.  This is one more and it is recorded
# rather than done here.
#
# `-Wno-format` on those two and on nothing else: `uint32_t` is `long` on this
# target and `int` on the ARM, both 32 bits, so their `%08x` is right and the
# warning is about the type name.  The firmware's own files use `%08lx` and are
# compiled at the full standard.
SOC_FW_DIR   := boards/arty-a7-100/firmware
SOC_CONS_DIR := boards/arty-z7-20/linux/buildroot/package/cadr-console/src
SOC_PACK_DIR := boards/arty-z7-20/linux/buildroot/package/cadr-disk-packs/src

# 32 KB, eight block RAM tiles.  It must agree with `LENGTH` in
# `$(SOC_FW_DIR)/link.ld`; `tools/bin2hex.py` refuses an image that does not
# fit, which is what catches a disagreement.
SOC_RAM_WORDS := 8192

# `zicsr` is spelled out because GCC 14 no longer implies it from `i`, and the
# trap handler reads `mcause`.  `-Os` because the memory is block RAM and every
# word of it is a tile.
SOC_CFLAGS := -march=rv32imc_zicsr -mabi=ilp32 -Os -g -ffreestanding \
              -nostartfiles --specs=picolibc.specs \
              -DPICOLIBC_INTEGER_PRINTF_SCANF \
              -I$(SOC_FW_DIR) -I$(SOC_FW_DIR)/include \
              -I$(SOC_CONS_DIR) -I$(SOC_PACK_DIR)

SOC_FW_OBJ := $(BUILD)/soc/start.o $(BUILD)/soc/soc_io.o $(BUILD)/soc/main.o \
              $(BUILD)/soc/console_face.o $(BUILD)/soc/pack_side.o

$(BUILD)/soc:
	@mkdir -p $@

$(BUILD)/soc/start.o: $(SOC_FW_DIR)/start.S | $(BUILD)/soc
	$(SOC_NEED_TOOLCHAIN)
	$(RISCV_CC) $(SOC_CFLAGS) -c $< -o $@

$(BUILD)/soc/soc_io.o: $(SOC_FW_DIR)/soc_io.c $(SOC_FW_DIR)/soc.h \
                       $(SOC_FW_DIR)/include/cadr/cadr_log.h | $(BUILD)/soc
	$(SOC_NEED_TOOLCHAIN)
	$(RISCV_CC) $(SOC_CFLAGS) -Wall -Wextra -Werror -c $< -o $@

$(BUILD)/soc/main.o: $(SOC_FW_DIR)/main.c $(SOC_FW_DIR)/soc.h \
                     $(SOC_CONS_DIR)/console_face.h $(SOC_PACK_DIR)/pack_side.h \
                     | $(BUILD)/soc
	$(SOC_NEED_TOOLCHAIN)
	$(RISCV_CC) $(SOC_CFLAGS) -Wall -Wextra -Werror -c $< -o $@

$(BUILD)/soc/console_face.o: $(SOC_CONS_DIR)/console_face.c \
                             $(SOC_CONS_DIR)/console_face.h | $(BUILD)/soc
	$(SOC_NEED_TOOLCHAIN)
	$(RISCV_CC) $(SOC_CFLAGS) -Wall -Wextra -Wno-format -c $< -o $@

$(BUILD)/soc/pack_side.o: $(SOC_PACK_DIR)/pack_side.c \
                          $(SOC_PACK_DIR)/pack_side.h | $(BUILD)/soc
	$(SOC_NEED_TOOLCHAIN)
	$(RISCV_CC) $(SOC_CFLAGS) -Wall -Wextra -Wno-format -c $< -o $@

$(BUILD)/soc/firmware.elf: $(SOC_FW_OBJ) $(SOC_FW_DIR)/link.ld
	$(SOC_NEED_TOOLCHAIN)
	$(RISCV_CC) $(SOC_CFLAGS) -T $(SOC_FW_DIR)/link.ld \
	    -Wl,--no-warn-rwx-segments -Wl,-Map=$(BUILD)/soc/firmware.map \
	    $(SOC_FW_OBJ) -o $@
	@$(RISCV_SIZE) $@

# **A TEMPORARY FILE MOVED INTO PLACE**, because a failed generator that left
# an empty hex would leave `make` calling it up to date and the memory would
# elaborate empty --- which `boards/arty-a7-100/README.md` records as a real
# trap the first board run met with the boot PROM's own hex.
$(BUILD)/soc_firmware.hex: $(BUILD)/soc/firmware.elf tools/bin2hex.py | $(BUILD)
	$(RISCV_OBJCOPY) -O binary $< $(BUILD)/soc/firmware.bin
	python3 tools/bin2hex.py $(BUILD)/soc/firmware.bin $(SOC_RAM_WORDS) $@.tmp
	mv $@.tmp $@

# --- the check --------------------------------------------------------------
#
# The harness is the Arty A7-100's top level below the clock: the soft system,
# the machine with MIT's boot PROM, and the four faces.  The firmware is the
# board's, byte for byte.
#
# **THE RATE IS NOT THE BOARD's AND THE CHECK SAYS WHY.**  At 115,200 baud one
# bit is 434 of the soft system's ticks and a dozen lines are four million of
# them; at a divisor of 32 the same firmware says the same words in a fraction
# of the time, and nothing in it knows the rate.  `tb/cadr_soc_tb.cpp` measures
# the narrowest level on the wire and asserts it IS the divisor, so a rate that
# never reached the fabric is a failure rather than a silent pass.
#
# **AND THE DIVISOR IS IN THE SOFT SYSTEM'S TICKS.**  The transmitter is on
# that side of the crossing, so the rate is computed from that clock and not
# from the machine's tick.  Both numbers below follow `SOC_CLK_HZ`, which is
# read out of the top level; a baud written here as a literal would be a
# second place the soft clock's frequency lived.
SOC_TB_DIVISOR := 32
SOC_TB_BAUD    := $(shell echo $$(( $(SOC_CLK_HZ) / $(SOC_TB_DIVISOR) )))
SOC_TICKS_PER_US := $(shell echo $$(( $(SOC_CLK_HZ) / 1000000 )))

# **WHICH BUILD THE CHECK TELLS THE FABRIC IT IS**, page 2's word 32.  On the
# board a primitive reads the part's AXSS register; there is none under
# Verilator, so this is the number the harness drives and `tb/cadr_soc_tb.cpp`
# asserts the firmware's banner against.
#
# **IT IS DELIBERATELY NOT THIS TREE'S OWN STAMP**: commit `5a1b2c3` with a
# tree that was both modified and carrying an untracked file, which is a
# commit this repository does not have.  A check that took the real stamp and
# then agreed with it would be confirming; this one compares the sentence the
# firmware printed against a number nothing but this line could have supplied.
# Both compound halves of the nibble are exercised by the choice of 3.
# One number in one place: the parameter and the check's own constant are both
# written from it, because two spellings of one value are two chances to
# disagree.
SOC_TB_BUILD_HEX := 5A1B2C33

# **AND THE JOIN, WHICH THE HARNESS INSTANTIATES AND THE FACES DO NOT
# INCLUDE.**  `rtl/plumbing/cadr_dbg_join.sv` is what sits in front of the
# machine's DBGIN page on every board in this repository; on this one it has
# the Pmod connector for its only master and its other arm --- the register
# window's on a Zynq --- is tied idle.  Named here rather than left to
# Verilator's own module search, so that a change to it re-runs this check:
# a prerequisite list is what makes a file part of a check, and finding the
# module is not the same as depending on it.
SOC_HARNESS_SRC := $(MACHINE) tb/cadr_soc_harness.sv $(IBEX_SRC) $(SOC_RTL) \
                   $(SOC_FACES) rtl/plumbing/cadr_dbg_join.sv

$(BUILD)/obj_soc/Vcadr_soc_harness: $(SOC_HARNESS_SRC) $(IBEX_VLT) \
                                    tb/cadr_soc_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing \
	    -Irtl/plumbing/xilinx7 $(IBEX_INC) -Mdir $(BUILD)/obj_soc \
	    -CFLAGS -DUART_DIVISOR=$(SOC_TB_DIVISOR) \
	    -CFLAGS -DSOC_TICKS_PER_US=$(SOC_TICKS_PER_US) \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    -GFIRMWARE_HEX='"$(abspath $(BUILD))/soc_firmware.hex"' \
	    -GSOC_RAM_WORDS=$(SOC_RAM_WORDS) -GSOC_BAUD=$(SOC_TB_BAUD) \
	    -GCLK_HZ=$(SOC_CLK_HZ) -GBUILD_STAMP="32'h$(SOC_TB_BUILD_HEX)" \
	    -CFLAGS -DSOC_TB_BUILD=0x$(SOC_TB_BUILD_HEX)u \
	    --top-module cadr_soc_harness $(IBEX_VLT) $(SOC_HARNESS_SRC) \
	    $(abspath tb/cadr_soc_tb.cpp)

$(BUILD)/soc.pass: $(BUILD)/obj_soc/Vcadr_soc_harness $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex \
                   $(BUILD)/soc_firmware.hex
	$(BUILD)/obj_soc/Vcadr_soc_harness
	@touch $@
