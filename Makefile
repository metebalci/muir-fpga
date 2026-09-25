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
# Which machine a generator builds, `golden/src/machine_axis.rs`: a
# prerequisite of every trace taken on QUUX.
GOLDEN_AXIS := golden/src/machine_axis.rs

VFLAGS := --cc --exe --build -Wall

# MIT'S GRID, WHICH EVERY TICK COUNT IN THE FABRIC DERIVES FROM.  It goes in
# every source list that builds a module naming an instant, and in exactly
# one list per rule --- a file handed to Verilator twice is a module defined
# twice.  So it is in `$(MACHINE_SRC)` and not in `$(GP0)` or `$(GP1)`, which
# the board passes name beside it.  Vivado needs no such care: both flows read
# `[glob rtl/*/*.sv]`, which already takes it, and order it themselves.
TICKPKG := rtl/machine/cadr_tick_pkg.sv

# **WHICH MACHINE A BOARD'S BITSTREAM IS**: `cadr`, MIT's, or `quux`, the
# evolved CADR.  Every sibling project selects the machine the same way, with
# `cadr` the default.  It reaches `cadr_machine` as its `MACHINE` parameter
# through each board's top level, and the board flows keep the two builds
# apart by directory and by file name.  **QUUX IS A SEPARATE BITSTREAM, ON THE
# ARTY Z7-20 AND THE DE25-NANO ONLY**; the Cora Z7-07S builds the CADR alone,
# and both its top level and its flow refuse anything else.
#
# **`check` AND `mutants` TAKE THE MACHINE TOO.**  `make check` is the
# CADR's: every check against muir's CADR traces, and the CADR's side of each
# of QUUX's differences.  `make check MACHINE=quux` is QUUX's: the checks
# that build `cadr_machine` as QUUX, each against a trace muir took on QUUX
# (`golden/src/machine_axis.rs` says how the generators build it), under
# names of their own, `<check>.quux.golden` and `<check>.quux.pass`, so the
# two machines' traces and results never share a file.  `make mutants
# MACHINE=quux` runs the records aimed at those checks and `make mutants`
# the CADR's; `mutations/run.py` alone runs both.  `machine_param.pass` is
# what holds the parameter's path for both values.
#
# The name was the machine's source list until the QUUX build arrived; that
# list is `$(MACHINE_SRC)` now, so that `make de25 MACHINE=quux` sets this and
# cannot replace the list.
MACHINE ?= cadr
ifneq ($(words $(MACHINE)),1)
$(error MACHINE is '$(MACHINE)'; it is cadr, MIT's machine, or quux, the evolved CADR)
endif
ifeq ($(filter cadr quux,$(MACHINE)),)
$(error MACHINE is '$(MACHINE)'; it is cadr, MIT's machine, or quux, the evolved CADR)
endif

# **QUUX'S MICROCYCLE, IN TICKS**: K, and L more for an `ILONG` instruction
# (`QUUX_TIMED` below says what they are and which checks take them).  The
# CADR's microcycle is its delay line's, so neither means anything there.
SYNC_K ?= 4
SYNC_L ?= 0
qtag = k$(1)$(if $(filter-out 0,$(2)),l$(2))
QK   := $(call qtag,$(SYNC_K),$(SYNC_L))
QKL1 := $(call qtag,$(SYNC_K),1)

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
        mutants-selftest probe-selftest de25 de25-fault de25-program de25-probe \
        disk-golden disk-boot-golden iob-golden busint-regs-golden muir-pin clean

CHECK_CADR = $(BUILD)/phase_gen.pass $(BUILD)/cables.pass $(BUILD)/busint_xbus.pass \
       $(BUILD)/xbus_decode.pass $(BUILD)/ddr_map.pass \
       $(BUILD)/memory_path.pass $(BUILD)/axi_master.pass $(BUILD)/xbus_axi.pass \
       $(BUILD)/axi_widen.pass $(BUILD)/prove.pass \
       $(BUILD)/microcycle.pass $(BUILD)/microcycle_sys.pass \
       $(BUILD)/rdw_poison.pass $(BUILD)/rdw_poison_sys.pass \
       $(BUILD)/rdw_poison_map.pass \
       $(BUILD)/sstep.pass $(BUILD)/dispatch_write_order.pass \
       $(BUILD)/md_hold.pass $(BUILD)/md_hold_sys.pass \
       $(BUILD)/md_inject.pass $(BUILD)/md_compose.pass \
       $(BUILD)/park.pass \
       $(BUILD)/machine.pass $(BUILD)/power_on.pass \
       $(BUILD)/ddr_boot.pass $(BUILD)/kbd_boot.pass \
       $(BUILD)/no_auto_boot.pass $(BUILD)/errhalt_lamp.pass \
       $(BUILD)/blink_lamps.pass $(BUILD)/promenable.pass \
       $(BUILD)/map_boot.pass $(BUILD)/map_access.pass \
       $(BUILD)/mem_count.pass $(BUILD)/f2sdram.pass $(BUILD)/bus_audit.pass \
       $(BUILD)/bus_audit_unit.pass $(BUILD)/axi_channel.pass \
       $(BUILD)/audit_window.pass \
       $(BUILD)/pack_channel.pass $(BUILD)/rdw_poison_disk.pass \
       $(BUILD)/arty.pass $(BUILD)/cora.pass $(BUILD)/machine_param.pass \
       $(BUILD)/work_dirs.pass \
       $(BUILD)/board_reset.pass $(BUILD)/fault.pass \
       $(BUILD)/probe.pass \
       $(BUILD)/probe_jtag.pass $(BUILD)/program_tcl.pass \
       $(BUILD)/disk.pass $(BUILD)/disk_pack.pass \
       $(BUILD)/disk_boot.pass \
       $(BUILD)/gp0_default.pass $(BUILD)/gp0_split.pass $(BUILD)/chaos_cable.pass \
       $(BUILD)/gp1_split.pass $(BUILD)/tv.pass $(BUILD)/color_tv.pass \
       $(BUILD)/display_out.pass $(BUILD)/display_sleep.pass \
       $(BUILD)/display_share.pass \
       $(BUILD)/hdmi_tx.pass $(BUILD)/adv7513.pass \
       $(BUILD)/console.pass $(BUILD)/readout.pass \
       $(BUILD)/dbgin.pass $(BUILD)/dbg_pmod.pass $(BUILD)/dbg_cable.pass \
       $(BUILD)/console_face.pass $(BUILD)/readout_face.pass \
       $(BUILD)/checkpoint.pass \
       $(BUILD)/chaosnet.pass $(BUILD)/serial.pass $(BUILD)/terminal.pass \
       $(BUILD)/usb_input.pass $(BUILD)/fpgarc.pass $(BUILD)/grid.pass \
       $(BUILD)/de25_pins.pass $(BUILD)/de25.pass $(BUILD)/de25_faces.pass \
       $(BUILD)/de25_jtag.pass $(BUILD)/mem_map.pass \
       $(BUILD)/de25_linux.pass \
       $(BUILD)/iob.pass $(BUILD)/busint_regs.pass $(BUILD)/unibus.pass \
       $(QUUX_PROGRAMS:%=$(BUILD)/quux_%.pass) \
       muir-pin current

# QUUX's checks: the whole machine built as QUUX on QUUX's own boot PROM, and
# each of the programs in `golden/src/quux.rs` that reach what that PROM does
# not.  The CADR runs the same programs in `CHECK_CADR` above.
QUUX_PROGRAMS := map tv muldiv tick divmd tickwait clocks
# QUUX's own, at its synchronous microcycle: the same but `tick` and
# `tickwait`, which were revision 4's tick, whose period destination 4 set;
# revision 5 fixes the tick at 60 Hz and gives destination 4 to the interval
# timer (contract Q1), and `clocks` holds both timers and the microsecond
# clock, `tickwin` the window between a flag's rise and the edge `SINTR` is
# taken at (`golden/src/quux.rs`).  The CADR's sides of `tick` and
# `tickwait` are unchanged.  And `pdlsync`, QUUX's alone: a push into the PDL
# buffer and a pop after it; and `imemsync`, words written into the control
# store and run, below QUUX's PROM and over it.
QUUX_SYNC_PROGRAMS := map tv muldiv clocks divmd tickwin pdlsync imemsync page clockwait
# And those taken at an L of one as well: `divmd`, whose `DIV`s are half
# `ILONG`, `divmdsync`, whose one `ILONG` filler at an L of one moves the
# word read a tick against the microcycles, and `tickwin`, whose `ILONG`s put
# a flag's rise strictly inside a microcycle, and `clockwait`, whose `ILONG`s
# put its reads of the clocks between the edges (`golden/src/quux.rs`).
QUUX_L1_PROGRAMS := divmd divmdsync tickwin clockwait
CHECK_QUUX = $(BUILD)/xbus_decode.quux.pass $(BUILD)/machine.quux.$(QK).pass \
       $(BUILD)/dispatch_write_order.quux.$(QK).pass \
       $(BUILD)/display_out.quux.pass $(BUILD)/muldiv.quux.pass $(BUILD)/quux_input.quux.pass \
       $(BUILD)/quux_block_disk.quux.pass \
       $(QUUX_SYNC_PROGRAMS:%=$(BUILD)/quux_%.quux.$(QK).pass) \
       $(QUUX_L1_PROGRAMS:%=$(BUILD)/quux_%.quux.$(QKL1).pass) $(BUILD)/phase_gen.quux.$(QKL1).pass \
       $(BUILD)/machine_param.pass muir-pin

ifeq ($(MACHINE),quux)
check: $(CHECK_QUUX)
else
check: $(CHECK_CADR)
endif

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

$(BUILD)/obj_phase_gen/Vcadr_phase_gen: $(TICKPKG) rtl/machine/cadr_phase_gen.sv tb/cadr_phase_gen_tb.cpp tb/cadr_tick.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) -Mdir $(BUILD)/obj_phase_gen --top-module cadr_phase_gen \
	    $(TICKPKG) rtl/machine/cadr_phase_gen.sv $(abspath tb/cadr_phase_gen_tb.cpp)

# MIT's grid in all its homes: the fabric's package, the testbenches' header,
# every generator's own constant and the board programs' two, the timing model every generator runs
# muir under, and every timing constraint that writes a count of ticks as a
# literal.  They cannot share a literal across four languages, and a grid that
# differs between them still builds, so this is what says they agree.  See
# `tools/grid_check.py` and `docs/timing.md`.  The two files named beside the
# wildcards are the ones `mutations/run.py`'s `grid` records are aimed at.
$(BUILD)/grid.pass: tools/grid_check.py $(TICKPKG) tb/cadr_tick.h $(wildcard golden/src/*.rs) \
                    $(wildcard rtl/*/*.xdc rtl/*/*/*.xdc boards/*/*.xdc boards/*/vivado/*.tcl) \
                    $(wildcard boards/*/quartus/*.sdc boards/*/quartus/*.tcl) \
                    rtl/plumbing/xilinx7/cadr_machine.xdc boards/de25-nano/quartus/cadr_de25.sdc \
                    rtl/plumbing/xilinx7/quux_machine.xdc boards/de25-nano/quartus/quux_de25.sdc \
                    boards/arty-z7-20/cadr_arty.sv boards/de25-nano/cadr_de25.sv \
                    boards/arty-z7-20/linux/buildroot/package/cadr-checkpoint/src/chk.h \
                    boards/arty-z7-20/linux/buildroot/package/cadr-console/src/console_test.c | $(BUILD)
	python3 tools/grid_check.py .
	@touch $@

# The DE25-Nano's pins, transcribed from Terasic's user manual into our own
# Tcl.  Always held to itself: unique ports and pins, each port's name saying
# the manual's signal, and each header's 36 signal pins where the manual's
# figure puts them.  Held as well to the Quartus settings in Terasic's
# resource package, pin and I/O standard for every port, when a package is
# named by TERASIC_DE25_PACKAGE or boards/de25-nano/local.conf.  Without one
# the comparison skips and says so, and the stamp is left alone so that the
# next run asks again.  See `tools/de25_pins_check.py`.
$(BUILD)/de25_pins.pass: tools/de25_pins_check.py boards/de25-nano/de25_nano_pins.tcl \
                         boards/de25-nano/README.md $(wildcard boards/de25-nano/local.conf) | $(BUILD)
	python3 tools/de25_pins_check.py . --stamp $@

# And where the DE25-Nano's register faces sit, which lint cannot see: a face
# is placed by a parameter on its instance, and lint has no opinion about a
# number.  The address is written twice --- as an offset into the bridge's
# window on the instance, and as the processor's address in `cadr_board.h`,
# where every program takes it from --- so the two are required to agree, and
# every instance on either bridge is required to carry the bridges' AXI4
# widths.
#
# AND THE DEBUG CABLE'S SEAM, for the same reason and against a different
# shape of bug: a literal where a signal belongs, and a crossing between two
# signals of the same width.  Lint sees neither.  That takes in which of JP1's
# pins each of the carrier's eight lines is on, which is the one place this
# board chooses a pin rather than transcribing one, so this reads the pin file
# and `rtl/plumbing/cadr_dbg_cable.sv` as well.  It borrows the pin file's
# grammar from `tools/de25_pins_check.py` rather than keeping a second copy.
# See `tools/de25_faces_check.py`.
$(BUILD)/de25_faces.pass: tools/de25_faces_check.py tools/de25_pins_check.py \
                          boards/de25-nano/cadr_de25.sv \
                          boards/de25-nano/de25_nano_pins.tcl \
                          rtl/plumbing/cadr_dbg_cable.sv \
                          boards/arty-z7-20/linux/buildroot/package/cadr-common/src/cadr/cadr_board.h | $(BUILD)
	python3 tools/de25_faces_check.py . --stamp $@

# WHERE EACH BOARD'S MEMORY IS, WRITTEN IN SEVERAL FILES THAT NO ONE BUILD
# READS TOGETHER: the fabric's package, the DE25-Nano's top level, the
# programs' header, each board's reserved-memory node, the card script and,
# on the DE25-Nano, U-Boot's GPO register.  Each build is self-consistent, so a
# number changed in one of them would first be seen on a board.  See
# `tools/mem_map_check.py`.
$(BUILD)/mem_map.pass: tools/mem_map_check.py \
                       rtl/plumbing/cadr_ddr_map.sv \
                       boards/de25-nano/cadr_de25.sv \
                       boards/arty-z7-20/linux/buildroot/package/cadr-common/src/cadr/cadr_board.h \
                       boards/arty-z7-20/linux/cadr-reserved.dtsi \
                       boards/de25-nano/linux/cadr-reserved.dtsi \
                       boards/arty-z7-20/linux/mksd-buildroot.sh \
                       boards/de25-nano/linux/buildroot/board/de25-nano/uboot/cadr_de25.env \
                       boards/arty-z7-20/vivado/ddr_check.tcl \
                       boards/arty-z7-20/vivado/ddr_run.tcl | $(BUILD)
	python3 tools/mem_map_check.py . --stamp $@

$(BUILD)/phase_gen.pass: $(BUILD)/obj_phase_gen/Vcadr_phase_gen $(BUILD)/phase_gen.golden
	$(BUILD)/obj_phase_gen/Vcadr_phase_gen $(BUILD)/phase_gen.golden
	@touch $@

# ------------------------------------------------------------- busint, Xbus

$(BUILD)/busint_xbus.golden: golden/src/busint_xbus.rs golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin busint_xbus > $@

$(BUILD)/obj_busint_xbus/Vcadr_busint_xbus: $(TICKPKG) rtl/machine/cadr_busint_xbus.sv tb/cadr_busint_xbus_tb.cpp tb/cadr_tick.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) -Mdir $(BUILD)/obj_busint_xbus --top-module cadr_busint_xbus \
	    $(TICKPKG) rtl/machine/cadr_busint_xbus.sv $(abspath tb/cadr_busint_xbus_tb.cpp)

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

# The DDR bridge and the adapter together, when the NXM timer ends a cycle the
# memory has not answered: the late answer is drained and thrown away, and the
# next cycle issues a transaction of its own.  The slave is the testbench's,
# with a latency it sets per cycle.
XBUS_AXI_SRC := rtl/plumbing/cadr_ddr_map.sv rtl/plumbing/cadr_xbus_ddr.sv \
                rtl/plumbing/cadr_axi_master.sv tb/cadr_xbus_axi_harness.sv

$(BUILD)/obj_xbus_axi/Vcadr_xbus_axi_harness: $(XBUS_AXI_SRC) tb/cadr_xbus_axi_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -Mdir $(BUILD)/obj_xbus_axi \
	    --top-module cadr_xbus_axi_harness $(XBUS_AXI_SRC) $(abspath tb/cadr_xbus_axi_tb.cpp)

$(BUILD)/xbus_axi.pass: $(BUILD)/obj_xbus_axi/Vcadr_xbus_axi_harness
	$(BUILD)/obj_xbus_axi/Vcadr_xbus_axi_harness
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
PROVE_SRC := $(TICKPKG) rtl/plumbing/cadr_prove.sv rtl/plumbing/cadr_axi_master.sv rtl/plumbing/cadr_axi_widen.sv \
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
MEMPATH := $(TICKPKG) rtl/plumbing/cadr_ddr_map.sv rtl/machine/cadr_xbus_decode.sv rtl/machine/cadr_busint_xbus.sv \
           rtl/plumbing/cadr_xbus_ddr.sv rtl/machine/cadr_tv.sv rtl/machine/cadr_console_bus.sv \
           rtl/machine/cadr_io_board.sv rtl/machine/cadr_busint_regs.sv \
           rtl/machine/cadr_spy_registers.sv rtl/machine/cadr_dbgin.sv \
           rtl/machine/cadr_memory_path.sv

$(BUILD)/obj_memory_path/Vcadr_memory_path: $(MEMPATH) tb/cadr_memory_path_tb.cpp tb/cadr_tick.h | $(BUILD)
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
# The trace is 39 million ticks at the 10 ns grid --- twenty-five frames, because a write
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

$(BUILD)/obj_tv/Vcadr_memory_path: $(MEMPATH) tb/cadr_tv_tb.cpp tb/cadr_tick.h | $(BUILD)
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

$(BUILD)/obj_color_tv/Vcadr_memory_path: $(MEMPATH) tb/cadr_color_tv_tb.cpp tb/cadr_tick.h | $(BUILD)
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
# The trace is 41 million ticks at the 10 ns grid --- 413 ms of the card's
# own time, which is what it takes for the microsecond counter to carry into
# its high half twice and for fourteen boundaries of the sixty-cycle clock to
# be read on alternating sides --- and the generator takes about a second.  It
# asserts as it runs: time never runs backwards, every instant is on the grid,
# every register the decoder names is reached, all hundred phases of
# `-UB MSYN` inside the card's microsecond are used, the mouse's
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
$(BUILD)/obj_iob/Vcadr_io_board: $(TICKPKG) rtl/machine/cadr_io_board.sv tb/cadr_io_board_tb.cpp tb/cadr_tick.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Mdir $(BUILD)/obj_iob \
	    --top-module cadr_io_board $(TICKPKG) rtl/machine/cadr_io_board.sv $(abspath tb/cadr_io_board_tb.cpp)

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

$(BUILD)/obj_busint_regs/Vcadr_busint_regs: $(TICKPKG) rtl/machine/cadr_busint_regs.sv tb/cadr_busint_regs_tb.cpp tb/cadr_tick.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Mdir $(BUILD)/obj_busint_regs \
	    --top-module cadr_busint_regs $(TICKPKG) rtl/machine/cadr_busint_regs.sv $(abspath tb/cadr_busint_regs_tb.cpp)

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
# the 6.6 million ticks the microsecond counter takes to carry into its high
# half.
$(BUILD)/obj_unibus/Vcadr_memory_path: $(MEMPATH) tb/cadr_unibus_tb.cpp tb/cadr_tick.h | $(BUILD)
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

# QUUX's decode, over the same 4,194,304 addresses: the feature page, and
# MONO TV's 40,960-word buffer in place of the CADR boards' 32,768.  The
# golden asks muir the question as its `rtl` engine asks it on QUUX.
$(BUILD)/xbus_decode.quux.golden: golden/src/xbus_decode.rs $(GOLDEN_AXIS) golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin xbus_decode -- --machine quux > $@

$(BUILD)/obj_xbus_decode_quux/Vcadr_xbus_decode: rtl/machine/cadr_xbus_decode.sv tb/cadr_xbus_decode_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Mdir $(BUILD)/obj_xbus_decode_quux -GMACHINE='"quux"' \
	    --top-module cadr_xbus_decode rtl/machine/cadr_xbus_decode.sv $(abspath tb/cadr_xbus_decode_tb.cpp)

$(BUILD)/xbus_decode.quux.pass: $(BUILD)/obj_xbus_decode_quux/Vcadr_xbus_decode $(BUILD)/xbus_decode.quux.golden
	$(BUILD)/obj_xbus_decode_quux/Vcadr_xbus_decode $(BUILD)/xbus_decode.quux.golden
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

MICROCYCLE := $(TICKPKG) rtl/machine/cadr_phase_gen.sv rtl/machine/cadr_microcycle.sv

# The PROM image is named at verilation, absolute, rather than left to the
# module's relative default: $$readmemh resolves against the working directory,
# so a model built with the default runs only from the repository root with the
# default BUILD, and elaborates a control store of x's anywhere else.
$(BUILD)/obj_microcycle/Vcadr_microcycle: $(MICROCYCLE) tb/cadr_microcycle_tb.cpp tb/cadr_tick.h | $(BUILD)
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
# It also holds three of muir's rules no reference program reaches, each
# through the console: a write of both map levels lands in level-2 block 0, a
# prepared cycle goes out at the next master clock with the machine halted,
# and the trap cycle after a boot is long and counted when `IR` asks. The
# boot and the mode register's speed are stimulus columns for the last.
#
# It shares `MICROCYCLE` and the PROM image with `microcycle.pass` and takes
# under a second: the script is a few hundred master clocks after a short
# warm-up.
$(BUILD)/sstep.golden: golden/src/sstep.rs golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin sstep > $@

$(BUILD)/obj_sstep/Vcadr_microcycle: $(MICROCYCLE) tb/cadr_sstep_tb.cpp tb/cadr_tick.h | $(BUILD)
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
MACHINE_SRC := $(TICKPKG) rtl/machine/cadr_phase_gen.sv rtl/machine/quux_phase_gen.sv rtl/machine/cadr_microcycle.sv rtl/plumbing/cadr_ddr_map.sv \
               rtl/machine/cadr_xbus_decode.sv rtl/machine/cadr_busint_xbus.sv rtl/plumbing/cadr_xbus_ddr.sv \
               rtl/machine/cadr_spy_registers.sv rtl/machine/cadr_disk_controller.sv rtl/machine/cadr_tv.sv \
               rtl/machine/cadr_io_board.sv rtl/machine/cadr_busint_regs.sv \
               rtl/machine/cadr_console_bus.sv rtl/machine/cadr_console_state.sv \
               rtl/machine/cadr_dbgin.sv \
               rtl/plumbing/cadr_bus_audit.sv rtl/machine/quux_feature_page.sv rtl/machine/quux_mono_tv.sv \
               rtl/machine/quux_muldiv.sv rtl/machine/quux_clocks.sv rtl/machine/quux_input.sv rtl/machine/quux_block_disk.sv \
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
# top-level output nothing drives is a PINMISSING.  Not in `$(MACHINE_SRC)`:
# `cadr_machine` does not instantiate either of them, and a check that builds
# a module nothing in it reaches is a check with a source it cannot mutate.
DBGPMOD := rtl/plumbing/cadr_dbg_tx.sv rtl/plumbing/cadr_dbg_rx.sv \
           rtl/plumbing/cadr_dbg_join.sv rtl/plumbing/cadr_dbg_cable.sv

# The display output, named here beside the others for the same reason the
# note above gives: `:=` is expanded where it is read and `arty.pass`'s
# prerequisites are read before the rules further down.  The phy is last
# because it is the only one of the three that needs the primitive stubs.
# **AND IT IS `DISPLAY_SRC` AND NOT `DISPLAY`, WHICH IT WAS.**  A make
# variable whose name is also an environment variable's is exported to every
# recipe with the makefile's value, and every Java tool in a flow reads
# `DISPLAY` as an X server to connect to.  Measured: `make de25 DDR=1` handed
# Platform Designer this list as its display, and `save_component` failed with
# "Can't connect to X11 window server using 'rtl/plumbing/...'".  Nothing in
# `check` had ever run a Java tool, so the trap had been harmless until the
# DE25-Nano's processor system arrived.
DISPLAY_SRC := rtl/plumbing/cadr_display_out.sv rtl/plumbing/cadr_tmds_encode.sv \
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

# The DE25-Nano's top level, the three lamp modules it shares with the Zynq
# boards and MIT's debug cable on JP1, named once because two rules read the
# list: the lint in `check` and the Quartus flow outside it.  Named here for
# the reason the lists above are: `:=` is expanded where it is read.
#
# **`$(DBGPMOD)` IS IN THE BASE LIST AND NOT IN `$(DE25_DDR)`**, for the
# reason that list's own note gives and this board needs stating again: a
# board is always a DEBUGGEE, so the connector is on every build of it, memory
# or no memory, and its pins are the top level's.
DE25_TOP := boards/de25-nano/cadr_de25.sv rtl/plumbing/cadr_lamp_clock.sv \
            rtl/plumbing/cadr_lamp_microcycle.sv rtl/plumbing/cadr_lamp_errhalt.sv \
            $(DBGPMOD)

# And the probe on that board: the capture every board shares, and the node
# that puts it behind Altera's Virtual JTAG.  In the lint always, and in the
# Quartus flow only when `PROBE_DEPTH` asks for it.
DE25_PROBE := rtl/plumbing/cadr_probe.sv rtl/plumbing/agilex5/cadr_probe_vjtag.sv

# And the memory board's: the machine's port on the processor's FPGA-to-SDRAM
# bridge, `rtl/plumbing/cadr_f2sdram_port.sv` and the four modules it is made
# of, and the default slave both processor-to-fabric bridges are tied to.  In
# the lint always, and in the Quartus flow only when `DDR` asks for it.
F2SDRAM := rtl/plumbing/cadr_axi_master.sv rtl/plumbing/cadr_axi_widen.sv \
           rtl/plumbing/cadr_mem_count.sv rtl/plumbing/cadr_f2sdram_gate.sv \
           rtl/plumbing/cadr_f2sdram_share.sv rtl/plumbing/cadr_f2sdram_port.sv
# And the faces behind the two processor-to-fabric bridges, which are the
# Zynq boards' own modules at the Agilex 5's AXI4 widths: the two splitters,
# the four register faces of the main bridge, the console and the debug
# cable's window on the lightweight one, and the default slave that answers
# the rest of both windows.
DE25_DDR := $(F2SDRAM) rtl/plumbing/cadr_gp0_default.sv $(GP0) \
            rtl/plumbing/cadr_disk_pack.sv rtl/plumbing/cadr_gp1_split.sv \
            rtl/plumbing/cadr_console.sv rtl/plumbing/cadr_debug_window.sv

# And the display output on that board: the raster every board shares, and
# the HDMI transmitter's own configuration, which is this board's alone.
# **`cadr_tmds_encode.sv`, `cadr_hdmi_tx.sv` AND `xilinx7/cadr_hdmi_phy.sv`
# ARE NOT HERE AND HAVE NO COUNTERPART**: on the DE25-Nano the encoding and
# the serializing are the ADV7513's, and the fabric hands it a parallel
# raster.  In the lint always, and in the Quartus flow only when `HDMI` asks
# for it.
DE25_HDMI := rtl/plumbing/cadr_display_out.sv rtl/plumbing/cadr_adv7513.sv

# **THE DE25-NANO'S MAP OF THE PROCESSOR'S MEMORY**, which every DE25-Nano
# build takes, the lint and the Quartus flow alike: `rtl/plumbing/cadr_ddr_map.sv`
# chooses the board's base by it, and the top level refuses to elaborate
# without it.  No Zynq rule sets it.
DE25_MAP := -DCADR_DDR_MAP_DE25_NANO

$(BUILD)/obj_machine/Vcadr_machine: $(MACHINE_SRC) tb/cadr_machine_tb.cpp tb/cadr_tick.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) +define+CADR_GAP_MONITOR -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_machine \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE_SRC) $(abspath tb/cadr_machine_tb.cpp)

$(BUILD)/machine.pass: $(BUILD)/obj_machine/Vcadr_machine \
                       $(BUILD)/rtl.golden $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_machine/Vcadr_machine $(BUILD)/rtl.golden
	@touch $@

# ------------------------------------------ writes against the reads beside them
#
# A write that lands in the microcycle reading the same memory, and a write
# whose microcycle is held.  `golden/src/dispatch_write_order.rs` builds muir's
# own `tests/dispatch_write_order.rs` programs and runs them on `rtl` under the
# grid; `tb/cadr_dispatch_write_order_tb.cpp` loads each program and the
# memories it starts from into the whole machine and holds every microcycle
# and every word of the end state to it.  Three of muir's rules, which no
# reference program reaches: a `-WAIT` fires no write pulse, a `-HANG`'s write
# pulse runs and takes `MD` as the bus has left it at the boundary, and a read
# in the microcycle that writes the same memory gets the old word.
#
# Built with `--public-flat-rw`, because the programs start from memories
# nothing but a program could otherwise fill, and the end state is read out of
# the arrays themselves.
$(BUILD)/dispatch_write_order.golden: golden/src/dispatch_write_order.rs golden/src/trace.rs \
                                      $(GOLDEN_AXIS) golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin dispatch_write_order > $@

$(BUILD)/obj_dispatch_write_order/Vcadr_machine: $(MACHINE_SRC) tb/cadr_dispatch_write_order_tb.cpp tb/cadr_tick.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) --public-flat-rw -O2 -CFLAGS -O2 +define+CADR_GAP_MONITOR -CFLAGS -DCADR_GAP_MONITOR -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_dispatch_write_order \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE_SRC) $(abspath tb/cadr_dispatch_write_order_tb.cpp)

$(BUILD)/dispatch_write_order.pass: $(BUILD)/obj_dispatch_write_order/Vcadr_machine \
                                    $(BUILD)/dispatch_write_order.golden \
                                    $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_dispatch_write_order/Vcadr_machine $(BUILD)/dispatch_write_order.golden
	@touch $@

# **THE SAME ON QUUX**: every program above run on QUUX, and muir's own of
# QUUX, where a RAM read in its own write cycle gives the old word and a
# microcycle that reads MD with a read in flight waits whole cycles and runs
# once, whole (`golden/src/dispatch_write_order.rs --machine quux`).  Its
# rules are in `QUUX_TIMED` below, one set for each of QUUX's timings.

# ------------------------------------------------ the whole machine, QUUX
#
# **THE SAME CHECK ON THE OTHER MACHINE.**  `cadr_machine` built with
# `MACHINE="quux"` and QUUX's boot PROM, version 1000, against muir's `rtl`
# engine running that PROM on QUUX: `golden/src/rtl.rs --machine quux`,
# which clears the 16K-word PDL buffer and 64 blocks of level 2 before its
# first memory cycle, 131,073 microcycles later than MIT's does, and ends
# 1,536 microcycles after that, short of a timing corner of the fabric's own
# that `golden/src/rtl.rs` describes.  `golden/src/machine_axis.rs` is
# how the generators build QUUX, MONO TV at the bitstreams' 1280 by 1024
# included.  The testbench is the CADR's own; nothing in it knows which
# machine it is holding.
$(BUILD)/boot_prom.quux.hex: golden/src/prom.rs $(GOLDEN_AXIS) golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin prom -- --machine quux > $@

# The trace and the machine built at each of QUUX's timings are in
# `QUUX_TIMED` below.

# ----------------------------------------------- QUUX's multiply and divide
#
# `rtl/machine/quux_muldiv.sv` on its own, against muir's `muldiv::run` over
# every combination of ten edge values and twenty thousand random operands:
# the fabric's closed-form multiply and its 32-step divide against the step
# sequence muir runs, row for row.  The processor's use of it --- the decode,
# the output bus, `Q` and the divider's hold --- is `quux_muldiv.quux.pass`.
$(BUILD)/muldiv.quux.golden: golden/src/muldiv.rs golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin muldiv > $@

$(BUILD)/obj_muldiv/Vquux_muldiv: rtl/machine/quux_muldiv.sv tb/quux_muldiv_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Mdir $(BUILD)/obj_muldiv \
	    --top-module quux_muldiv rtl/machine/quux_muldiv.sv $(abspath tb/quux_muldiv_tb.cpp)

$(BUILD)/muldiv.quux.pass: $(BUILD)/obj_muldiv/Vquux_muldiv $(BUILD)/muldiv.quux.golden
	$(BUILD)/obj_muldiv/Vquux_muldiv $(BUILD)/muldiv.quux.golden
	@touch $@

# ------------------------------------------- QUUX's keyboard and mouse
#
# `rtl/machine/quux_input.sv` on its own, against muir's `QuuxInput` over a
# script of presses, the mouse's counts and buttons, reads and writes and the
# boot word (`golden/src/quux_input.rs`).  The same module on the whole
# machine, through the register page, is `quux_page.quux.*.pass`.
$(BUILD)/quux_input.quux.golden: golden/src/quux_input.rs golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin quux_input > $@

$(BUILD)/obj_quux_input/Vquux_input: $(TICKPKG) rtl/machine/quux_input.sv tb/quux_input_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Mdir $(BUILD)/obj_quux_input \
	    --top-module quux_input $(TICKPKG) rtl/machine/quux_input.sv $(abspath tb/quux_input_tb.cpp)

$(BUILD)/quux_input.quux.pass: $(BUILD)/obj_quux_input/Vquux_input $(BUILD)/quux_input.quux.golden
	$(BUILD)/obj_quux_input/Vquux_input $(BUILD)/quux_input.quux.golden
	@touch $@

# ------------------------------------------------------ QUUX's block-disk
#
# `rtl/machine/quux_block_disk.sv` on its own, against muir's `BlockDisk`
# over a script of register reads and writes at muir's instants, with main
# memory and the pack side answered by the testbench and every page and
# block compared at the end (`golden/src/quux_block_disk.rs`).
$(BUILD)/quux_block_disk.quux.golden: golden/src/quux_block_disk.rs golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin quux_block_disk > $@

$(BUILD)/obj_quux_block_disk/Vquux_block_disk: $(TICKPKG) rtl/machine/quux_block_disk.sv tb/quux_block_disk_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Mdir $(BUILD)/obj_quux_block_disk \
	    --top-module quux_block_disk $(TICKPKG) rtl/machine/quux_block_disk.sv $(abspath tb/quux_block_disk_tb.cpp)

$(BUILD)/quux_block_disk.quux.pass: $(BUILD)/obj_quux_block_disk/Vquux_block_disk $(BUILD)/quux_block_disk.quux.golden
	$(BUILD)/obj_quux_block_disk/Vquux_block_disk $(BUILD)/quux_block_disk.quux.golden
	@touch $@

# ------------------------------------ where QUUX differs, on both machines
#
# **MIT'S BOOT PROM REACHES QUUX'S MAP AND PDL BUFFER AND NOTHING ELSE OF
# IT**, so each of QUUX's differences is a short program of its own in the
# boot PROM: `golden/src/quux.rs --program <name>` assembles it with muir's
# `isa::asm` and traces it on muir's `rtl` engine, and the whole machine is
# built with that program as its PROM image and held to the trace by the
# machine check's own testbench, row for row.  **Each program is traced on
# both machines**: `quux_<name>.golden` on the CADR is the CADR's side of
# the difference and is part of `make check`; `quux_<name>.quux.golden` on
# QUUX is part of `make check MACHINE=quux`.  The generator asserts, at the
# end of each run, the values muir's own `tests/quux.rs` holds, so a program
# that stopped reaching its feature fails there and writes no trace.
QUUX_GOLDEN := golden/src/quux.rs golden/src/trace.rs $(GOLDEN_AXIS) golden/Cargo.toml

# Kept: pattern rules make these intermediate, and make deletes an
# intermediate file after the run, which would rebuild every model each time.
.PRECIOUS: $(BUILD)/quux_%_prom.hex $(BUILD)/quux_%.golden \
           $(BUILD)/obj_quux_%/Vcadr_machine

$(BUILD)/quux_%_prom.hex: $(QUUX_GOLDEN) | $(BUILD)
	$(GOLDEN) --release --bin quux -- --program $* --prom > $@

# **AND QUUX'S IMAGE OF THE SAME PROGRAM, ASSEMBLED AT 36000**, where QUUX's
# PROM sits in the control store (revision 6, contract Q2): every jump is to
# an absolute address, so the two machines run two images of one program.
.PRECIOUS: $(BUILD)/quux_%_prom.quux.hex
$(BUILD)/quux_%_prom.quux.hex: $(QUUX_GOLDEN) | $(BUILD)
	$(GOLDEN) --release --bin quux -- --program $* --machine quux --prom > $@

$(BUILD)/quux_%.golden: $(QUUX_GOLDEN) | $(BUILD)
	$(GOLDEN) --release --bin quux -- --program $* --machine cadr > $@

$(BUILD)/obj_quux_%/Vcadr_machine: $(MACHINE_SRC) tb/cadr_machine_tb.cpp tb/cadr_tick.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) +define+CADR_GAP_MONITOR -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_quux_$* \
	    -GPROM_HEX='"$(abspath $(BUILD))/quux_$*_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE_SRC) $(abspath tb/cadr_machine_tb.cpp)

$(BUILD)/quux_%.pass: $(BUILD)/obj_quux_%/Vcadr_machine $(BUILD)/quux_%.golden \
                      $(BUILD)/quux_%_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_quux_$*/Vcadr_machine $(BUILD)/quux_$*.golden
	@touch $@


# ------------------------------------------------ QUUX's timings, H1a
#
# **QUUX'S MICROCYCLE IS K TICKS, AND AN `ILONG` INSTRUCTION'S K + L**, where
# the CADR's is its delay line's (muir's `TimingModel::Sync`, `--timing-model
# sync --sync-cycle-ticks K`).  K and L are a board's: the fit is what says
# its longest path settles in K ticks, so `SYNC_K` and `SYNC_L` are
# parameters of each board's top level, the Arty's K being 4, and every
# trace QUUX is held to is taken at a K and an L named in its file name,
# `<check>.quux.k4.golden`, or `.k4l1` with an L.  `make check MACHINE=quux`
# runs the checks at `SYNC_K` and `SYNC_L`, 4 and 0 unless the command line
# says otherwise.  **K IS FOUR AT THE LEAST**: at three a `DIV` of MD would
# need the word read in the divider on its strobe's own tick, off a bus whose
# cone is two ticks deep (`rtl/machine/quux_phase_gen.sv` refuses it), so both
# boards run at four and the rules are made for four alone.
# Each K also runs `quux_divmd`, whose program has `ILONG` instructions, at
# an L of one, and the phase generator alone at K and K + 1, since muir's
# command line always gives an L of zero and a nonzero L is reachable only
# through its library, as it is here.
#
# The rules for one timing are `QUUX_TIMED`, instantiated for each of
# `QUUX_TIMINGS` as `K:L`; a timing named nowhere here has no rules, so a
# `SYNC_K` of five stops with no rule to make the target.  A K is added here
# when a board is fitted at it.
QUUX_TIMINGS := 4:0 4:1
# `SYNC_K`, `SYNC_L`, `QK` and `QKL1` are set at the top, beside `MACHINE`,
# because `check`'s prerequisites are expanded where the rule is read.

# $(1) the timing's tag, $(2) K, $(3) L.
define QUUX_TIMED
$$(BUILD)/rtl.quux.$(1).golden: golden/src/rtl.rs golden/src/trace.rs $$(GOLDEN_AXIS) \
                               golden/Cargo.toml | $$(BUILD)
	$$(GOLDEN) --release --bin rtl -- --machine quux --sync-cycle-ticks $(2) --sync-ilong-ticks $(3) > $$@

$$(BUILD)/obj_machine_quux_$(1)/Vcadr_machine: $$(MACHINE_SRC) tb/cadr_machine_tb.cpp tb/cadr_tick.h | $$(BUILD)
	$$(VERILATOR) $$(VFLAGS) +define+CADR_GAP_MONITOR -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $$(BUILD)/obj_machine_quux_$(1) \
	    -GMACHINE='"quux"' -GSYNC_K=$(2) -GSYNC_L=$(3) \
	    -GPROM_HEX='"$$(abspath $$(BUILD))/boot_prom.quux.hex"' \
	    -GSYNC_PROM_HEX='"$$(abspath $$(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $$(MACHINE_SRC) $$(abspath tb/cadr_machine_tb.cpp)

$$(BUILD)/machine.quux.$(1).pass: $$(BUILD)/obj_machine_quux_$(1)/Vcadr_machine \
                                 $$(BUILD)/rtl.quux.$(1).golden $$(BUILD)/boot_prom.quux.hex $$(BUILD)/sync_prom.hex
	$$(BUILD)/obj_machine_quux_$(1)/Vcadr_machine $$(BUILD)/rtl.quux.$(1).golden
	@touch $$@

$$(BUILD)/dispatch_write_order.quux.$(1).golden: golden/src/dispatch_write_order.rs golden/src/trace.rs \
                                                $$(GOLDEN_AXIS) golden/Cargo.toml | $$(BUILD)
	$$(GOLDEN) --release --bin dispatch_write_order -- --machine quux --sync-cycle-ticks $(2) --sync-ilong-ticks $(3) > $$@

$$(BUILD)/obj_dispatch_write_order_quux_$(1)/Vcadr_machine: $$(MACHINE_SRC) tb/cadr_dispatch_write_order_tb.cpp tb/cadr_tick.h | $$(BUILD)
	$$(VERILATOR) $$(VFLAGS) --public-flat-rw -O2 -CFLAGS -O2 +define+CADR_GAP_MONITOR -CFLAGS -DCADR_GAP_MONITOR -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $$(BUILD)/obj_dispatch_write_order_quux_$(1) \
	    -GMACHINE='"quux"' -GSYNC_K=$(2) -GSYNC_L=$(3) \
	    -GPROM_HEX='"$$(abspath $$(BUILD))/boot_prom.quux.hex"' \
	    -GSYNC_PROM_HEX='"$$(abspath $$(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $$(MACHINE_SRC) $$(abspath tb/cadr_dispatch_write_order_tb.cpp)

$$(BUILD)/dispatch_write_order.quux.$(1).pass: $$(BUILD)/obj_dispatch_write_order_quux_$(1)/Vcadr_machine \
                                              $$(BUILD)/dispatch_write_order.quux.$(1).golden \
                                              $$(BUILD)/boot_prom.quux.hex $$(BUILD)/sync_prom.hex
	$$(BUILD)/obj_dispatch_write_order_quux_$(1)/Vcadr_machine $$(BUILD)/dispatch_write_order.quux.$(1).golden
	@touch $$@

.PRECIOUS: $$(BUILD)/quux_%.quux.$(1).golden $$(BUILD)/obj_quux_%_quux_$(1)/Vcadr_machine

$$(BUILD)/quux_%.quux.$(1).golden: $$(QUUX_GOLDEN) | $$(BUILD)
	$$(GOLDEN) --release --bin quux -- --program $$* --machine quux --sync-cycle-ticks $(2) --sync-ilong-ticks $(3) > $$@

$$(BUILD)/obj_quux_%_quux_$(1)/Vcadr_machine: $$(MACHINE_SRC) tb/cadr_machine_tb.cpp tb/cadr_tick.h | $$(BUILD)
	$$(VERILATOR) $$(VFLAGS) +define+CADR_GAP_MONITOR -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $$(BUILD)/obj_quux_$$*_quux_$(1) \
	    -GMACHINE='"quux"' -GSYNC_K=$(2) -GSYNC_L=$(3) \
	    -GPROM_HEX='"$$(abspath $$(BUILD))/quux_$$*_prom.quux.hex"' \
	    -GSYNC_PROM_HEX='"$$(abspath $$(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $$(MACHINE_SRC) $$(abspath tb/cadr_machine_tb.cpp)

$$(BUILD)/quux_%.quux.$(1).pass: $$(BUILD)/obj_quux_%_quux_$(1)/Vcadr_machine $$(BUILD)/quux_%.quux.$(1).golden \
                                $$(BUILD)/quux_%_prom.quux.hex $$(BUILD)/sync_prom.hex
	$$(BUILD)/obj_quux_$$*_quux_$(1)/Vcadr_machine $$(BUILD)/quux_$$*.quux.$(1).golden
	@touch $$@

$$(BUILD)/phase_gen.quux.$(1).golden: golden/src/phase_gen.rs $$(GOLDEN_AXIS) golden/Cargo.toml | $$(BUILD)
	$$(GOLDEN) --release --bin phase_gen -- --machine quux --sync-cycle-ticks $(2) --sync-ilong-ticks $(3) > $$@

$$(BUILD)/obj_phase_gen_quux_$(1)/Vquux_phase_gen: rtl/machine/quux_phase_gen.sv tb/quux_phase_gen_tb.cpp | $$(BUILD)
	$$(VERILATOR) $$(VFLAGS) -Mdir $$(BUILD)/obj_phase_gen_quux_$(1) --top-module quux_phase_gen \
	    -GSYNC_K=$(2) -GSYNC_L=$(3) -CFLAGS '-DSYNC_K_TB=$(2) -DSYNC_L_TB=$(3)' \
	    rtl/machine/quux_phase_gen.sv $$(abspath tb/quux_phase_gen_tb.cpp)

$$(BUILD)/phase_gen.quux.$(1).pass: $$(BUILD)/obj_phase_gen_quux_$(1)/Vquux_phase_gen $$(BUILD)/phase_gen.quux.$(1).golden
	$$(BUILD)/obj_phase_gen_quux_$(1)/Vquux_phase_gen $$(BUILD)/phase_gen.quux.$(1).golden
	@touch $$@
endef
$(foreach t,$(QUUX_TIMINGS),$(eval $(call QUUX_TIMED,$(call qtag,$(word 1,$(subst :, ,$(t))),$(word 2,$(subst :, ,$(t)))),$(word 1,$(subst :, ,$(t))),$(word 2,$(subst :, ,$(t))))))

# EVERY FREE-RUNNING CLOCK OF THE COMPOSED MACHINE AGAINST muir, from the
# processor's origin.  Each clock's own check sets muir's t = 0 from its own
# reset and so cannot see a clock that starts at the wrong edge of the whole
# machine; this takes t = 0 from the first microcycles `machine.pass` holds to
# muir and compares the I/O board's clocks and the display's program from
# power-on against muir's instants under the fabric's timing model.  The model
# is built with `--public-flat-rw`, the clocks reaching no port.
$(BUILD)/power_on.golden: golden/src/power_on.rs golden/src/trace.rs \
                          golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin power_on > $@

$(BUILD)/obj_power_on/Vcadr_machine: $(MACHINE_SRC) tb/cadr_power_on_tb.cpp tb/cadr_tick.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) --public-flat-rw -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_power_on \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE_SRC) $(abspath tb/cadr_power_on_tb.cpp)

$(BUILD)/power_on.pass: $(BUILD)/obj_power_on/Vcadr_machine \
                        $(BUILD)/power_on.golden $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_power_on/Vcadr_machine $(BUILD)/power_on.golden
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
$(BUILD)/obj_ddr_boot/Vcadr_machine: $(MACHINE_SRC) tb/cadr_ddr_boot_tb.cpp tb/cadr_tick.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) +define+CADR_GAP_MONITOR -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_ddr_boot \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE_SRC) $(abspath tb/cadr_ddr_boot_tb.cpp)

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
$(BUILD)/obj_kbd_boot/Vcadr_machine: $(MACHINE_SRC) tb/cadr_kbd_boot_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_kbd_boot \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE_SRC) $(abspath tb/cadr_kbd_boot_tb.cpp)

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
$(BUILD)/obj_no_auto_boot/Vcadr_machine: $(MACHINE_SRC) tb/cadr_no_auto_boot_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_no_auto_boot \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE_SRC) $(abspath tb/cadr_no_auto_boot_tb.cpp)

$(BUILD)/no_auto_boot.pass: $(BUILD)/obj_no_auto_boot/Vcadr_machine $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_no_auto_boot/Vcadr_machine
	@touch $@

# ------------------------------------------------------ LD5, the blue lamp

# **`-PROMENABLE` AT PCTL 1C19, WHICH THE BLUE LAMP SHOWS.**  Both Zynq boards
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
$(BUILD)/obj_promenable/Vcadr_machine: $(MACHINE_SRC) tb/cadr_promenable_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_promenable \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE_SRC) $(abspath tb/cadr_promenable_tb.cpp)

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

# ------------------------------------------------ the lamps that blink, or not

# **THE CLOCK LAMP AND THE MICROCYCLE LAMP, BLINKING BY DEFAULT AND STEADY WITH
# `--no-blinking-leds`.**  Two modules, one harness and one check, for the
# errhalt lamp's reason: in the top level these would be reached by lint alone,
# and lint cannot tell a lamp that follows the MMCM's lock from one that samples
# it, or a hold that is re-armed by every microcycle from one that is not.
# What this holds: the clock lamp is the blink when blinking and the lock when
# steady, with no clock edge between a change of the lock and the lamp; the
# microcycle lamp blinks on a count of microcycles and not of ticks and freezes
# when they stop, and steady it is lit on every tick of a running machine and
# for exactly its hold after the last microcycle.  At the modules' own
# defaults, which are the boards'.  Which nets reach them stays the top
# levels' and their lint's.
$(BUILD)/obj_blink_lamps/Vcadr_blink_lamps_harness: rtl/plumbing/cadr_lamp_clock.sv \
                                                    rtl/plumbing/cadr_lamp_microcycle.sv \
                                                    tb/cadr_blink_lamps_harness.sv \
                                                    tb/cadr_blink_lamps_tb.cpp tb/cadr_tick.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Mdir $(BUILD)/obj_blink_lamps \
	    --top-module cadr_blink_lamps_harness \
	    rtl/plumbing/cadr_lamp_clock.sv rtl/plumbing/cadr_lamp_microcycle.sv \
	    tb/cadr_blink_lamps_harness.sv $(abspath tb/cadr_blink_lamps_tb.cpp)

$(BUILD)/blink_lamps.pass: $(BUILD)/obj_blink_lamps/Vcadr_blink_lamps_harness
	$(BUILD)/obj_blink_lamps/Vcadr_blink_lamps_harness
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
$(BUILD)/obj_map_boot/Vcadr_machine: $(MACHINE_SRC) tb/cadr_map_boot_tb.cpp tb/cadr_tick.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_map_boot \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE_SRC) $(abspath tb/cadr_map_boot_tb.cpp)

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
$(BUILD)/obj_band/Vcadr_machine: $(MACHINE_SRC) tb/cadr_band_tb.cpp tb/cadr_tick.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) +define+CADR_GAP_MONITOR -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_band \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE_SRC) $(abspath tb/cadr_band_tb.cpp)

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
$(BUILD)/obj_hash_watch/Vcadr_machine: $(MACHINE_SRC) tb/cadr_hash_watch_tb.cpp tb/cadr_tick.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_hash_watch \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE_SRC) $(abspath tb/cadr_hash_watch_tb.cpp)

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
AXI_CHANNEL_SRC := $(MACHINE_SRC) rtl/plumbing/cadr_axi_master.sv \
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
BAND_AXI_SRC := $(MACHINE_SRC) rtl/plumbing/cadr_axi_master.sv \
                rtl/plumbing/cadr_axi_widen.sv tb/cadr_band_axi_harness.sv

$(BUILD)/obj_band_axi/Vcadr_band_axi_harness: $(BAND_AXI_SRC) \
                                              tb/cadr_band_axi_tb.cpp tb/cadr_tick.h | $(BUILD)
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
PACK_CHANNEL_SRC := $(MACHINE_SRC) rtl/plumbing/cadr_axi_master.sv \
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

# ------------------------- the block store in its undefined tick, poisoned
#
# **THE DE25-NANO'S BLOCK STORE IS AN M20K WITH READ-DURING-WRITE CHECKING
# OFF**, which `boards/de25-nano/quartus/project.tcl` asks for and explains:
# Agilex 5's M20K does not offer old data at a port that is writing, and
# without the relaxation synthesis builds the store's 196,608 bits out of
# logic --- 332,163 ALUTs of a part that has 93,600, so the fitter refuses to
# place it at all.  What the relaxation gives away is the word either port
# reads in the tick after an edge that wrote the array.
#
# This is the same run as `pack_channel` above with `CADR_RDW_POISON_DISK`
# defined,
# which returns the complement of the word in that tick, on both ports and
# after a write to either --- wider than the hardware's own undefined tick, so
# a run that still agrees has shown the narrow thing too.  The check is the
# whole of `pack_channel`'s: every block the channel lays down compared with
# `golden/src/disk.rs`'s own `pack_word`, which is a function of the block AND
# the offset in it, so no wrong word reads like a right one.  The model
# refuses a run in which the store was never written, because a poison that
# never fired measured nothing.
#
# `cadr_microcycle.sv`'s three asynchronous memories have the same treatment
# at `rdw_poison`, `rdw_poison_sys` and `rdw_poison_map`.
$(BUILD)/obj_rdw_poison_disk/Vcadr_pack_axi_harness: $(PACK_CHANNEL_SRC) \
                                                  tb/cadr_pack_channel_tb.cpp \
                                                  tb/cadr_pack_linux.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -CFLAGS -I$(abspath tb) +define+CADR_RDW_POISON_DISK -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_rdw_poison_disk \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_pack_axi_harness $(PACK_CHANNEL_SRC) \
	    $(abspath tb/cadr_pack_channel_tb.cpp)

$(BUILD)/rdw_poison_disk.pass: $(BUILD)/obj_rdw_poison_disk/Vcadr_pack_axi_harness \
                               $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_rdw_poison_disk/Vcadr_pack_axi_harness
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
PACK_BAND_SRC := $(MACHINE_SRC) rtl/plumbing/cadr_axi_master.sv \
                 rtl/plumbing/cadr_axi_widen.sv rtl/plumbing/cadr_disk_pack.sv \
                 tb/cadr_pack_axi_harness.sv

$(BUILD)/obj_pack_band/Vcadr_pack_axi_harness: $(PACK_BAND_SRC) \
                                               tb/cadr_pack_band_tb.cpp tb/cadr_tick.h \
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
$(BUILD)/obj_map_access/Vcadr_machine: $(MACHINE_SRC) tb/cadr_map_access_tb.cpp tb/cadr_tick.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_map_access \
	    -GPROM_HEX='"$(abspath $(BUILD))/map_access_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE_SRC) $(abspath tb/cadr_map_access_tb.cpp)

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
MEM_COUNT_SRC := $(MACHINE_SRC) rtl/plumbing/cadr_axi_master.sv rtl/plumbing/cadr_axi_widen.sv \
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

# ------------------------------- the machine on the DE25-Nano's memory port

# THE MACHINE BEHIND THE AGILEX 5'S FPGA-TO-SDRAM BRIDGE, which is what
# `make de25 DDR=1` puts on the part: `rtl/plumbing/cadr_f2sdram_port.sv` with
# `cadr_machine` in front of it and a model of the bridge behind it.  It is
# `ddr_boot`'s question on the other vendor's part, and `memory_path`'s
# configuration B besides --- what another master on the same port costs a
# machine cycle --- because on this board there is one port and three masters.
# `tb/cadr_f2sdram_tb.cpp`'s header has the five configurations and the bound.
#
# **BUILT WITH THE DE25-NANO'S MAP**, `$(DE25_MAP)`, because the addresses the
# machine puts on the bridge are the board's and the model watches those.
#
# It runs the machine five times, a couple of minutes.
F2SDRAM_SRC := $(MACHINE_SRC) $(F2SDRAM) tb/cadr_f2sdram_harness.sv

$(BUILD)/obj_f2sdram/Vcadr_f2sdram_harness: $(F2SDRAM_SRC) \
                                            tb/cadr_f2sdram_tb.cpp tb/cadr_tick.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 $(DE25_MAP) -Irtl/machine -Irtl/plumbing -Mdir $(BUILD)/obj_f2sdram \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_f2sdram_harness $(F2SDRAM_SRC) \
	    $(abspath tb/cadr_f2sdram_tb.cpp)

# AND THE PORT'S TWO RESETS WITH TRANSACTIONS IN FLIGHT, which the machine's
# own traffic cannot reach: its reads are 118 ms into a boot and a reset
# there would land between them.  `tb/cadr_f2sdram_reset_tb.cpp` drives the
# machine's side of `rtl/plumbing/cadr_f2sdram_port.sv` directly, with the
# fabric's reset pulsed under a read, a write and the pack side's burst, and
# the processor's reset raised under a read the bridge then drops.
$(BUILD)/obj_f2sdram_reset/Vcadr_f2sdram_port: $(F2SDRAM) tb/cadr_f2sdram_reset_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/plumbing -Mdir $(BUILD)/obj_f2sdram_reset \
	    --top-module cadr_f2sdram_port $(F2SDRAM) $(abspath tb/cadr_f2sdram_reset_tb.cpp)

$(BUILD)/f2sdram.pass: $(BUILD)/obj_f2sdram/Vcadr_f2sdram_harness \
                       $(BUILD)/obj_f2sdram_reset/Vcadr_f2sdram_port \
                       $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_f2sdram/Vcadr_f2sdram_harness
	$(BUILD)/obj_f2sdram_reset/Vcadr_f2sdram_port
	@touch $@

# ---------------------------------------------- the fabric's reset, per board
#
# THE ONLY CHECK THAT SIMULATES A BOARD'S TOP LEVEL.  Every other check
# drives a module, and a module cannot say which reset its top level gives
# it.  The fabric's reset (BTN1, KEY1, the clock generator losing lock) must
# reset the machine and the faces' registers and never break an AXI
# transaction the processor has started; which reset reaches which module is
# decided in `boards/*/cadr_*.sv` and nowhere else.  So each board's own top
# level is built here with a processing system that drives its ports,
# `tb/cadr_ps7_sim.sv` or `tb/cadr_de25_hps_sim.sv`, and the button is
# pressed under reads and writes on every page of both ports.
# `tb/cadr_board_reset_tb.cpp` has the rule and what is checked, including
# the DE25-Nano's memory port: the machine waiting for it, and the
# processor's reset resetting it and the display but not the machine.
#
# The stubs pass each board's oscillator through as the fabric's clock, and
# the machine runs from its PROM as it does on the board.  A few minutes to
# build the three, seconds to run.
BOARD_RESET_SIM := tb/cadr_sim_axi.sv tb/cadr_board_reset_harness.sv
BOARD_RESET_ZYNQ := $(BOARD_RESET_SIM) $(MACHINE_SRC) $(BOARD_STUBS) tb/cadr_ps7_sim.sv \
                    rtl/plumbing/cadr_axi_master.sv rtl/plumbing/cadr_axi_widen.sv \
                    rtl/plumbing/cadr_mem_count.sv rtl/plumbing/cadr_disk_pack.sv \
                    rtl/plumbing/cadr_console.sv rtl/plumbing/cadr_gp0_default.sv \
                    $(GP0) $(GP1) rtl/plumbing/cadr_debug_window.sv $(DBGPMOD) \
                    rtl/plumbing/cadr_lamp_errhalt.sv rtl/plumbing/cadr_lamp_clock.sv \
                    rtl/plumbing/cadr_lamp_microcycle.sv
BOARD_RESET_VFLAGS := $(VFLAGS) -O2 -CFLAGS -O2 -Wno-PINCONNECTEMPTY \
                      -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
                      -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
                      --top-module cadr_board_reset_harness

$(BUILD)/obj_board_reset_arty/Vcadr_board_reset_harness: $(BOARD_RESET_ZYNQ) \
        $(DISPLAY_SRC) boards/arty-z7-20/cadr_arty.sv tb/cadr_board_reset_tb.cpp | $(BUILD)
	$(VERILATOR) $(BOARD_RESET_VFLAGS) -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 \
	    -DCADR_BOARD_ARTY -CFLAGS -DCADR_BOARD_ARTY -Mdir $(BUILD)/obj_board_reset_arty \
	    $(BOARD_RESET_ZYNQ) $(DISPLAY_SRC) boards/arty-z7-20/cadr_arty.sv \
	    $(abspath tb/cadr_board_reset_tb.cpp)

$(BUILD)/obj_board_reset_cora/Vcadr_board_reset_harness: $(BOARD_RESET_ZYNQ) \
        boards/cora-z7-07s/cadr_cora.sv tb/cadr_board_reset_tb.cpp | $(BUILD)
	$(VERILATOR) $(BOARD_RESET_VFLAGS) -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 \
	    -DCADR_BOARD_CORA -DCADR_PS7_NO_HP3 -CFLAGS -DCADR_BOARD_CORA \
	    -Mdir $(BUILD)/obj_board_reset_cora \
	    $(BOARD_RESET_ZYNQ) boards/cora-z7-07s/cadr_cora.sv \
	    $(abspath tb/cadr_board_reset_tb.cpp)

BOARD_RESET_DE25 := $(BOARD_RESET_SIM) $(MACHINE_SRC) $(DE25_TOP) $(DE25_DDR) $(DE25_HDMI) \
                    tb/cadr_de25_stubs.sv tb/cadr_de25_hps_sim.sv

$(BUILD)/obj_board_reset_de25/Vcadr_board_reset_harness: $(BOARD_RESET_DE25) \
        tb/cadr_board_reset_tb.cpp | $(BUILD)
	$(VERILATOR) $(BOARD_RESET_VFLAGS) -Irtl/machine -Irtl/plumbing $(DE25_MAP) \
	    -DCADR_BOARD_DE25 -DCADR_DE25_DDR -DCADR_DE25_HDMI -DCADR_DE25_HPS_SIM \
	    -CFLAGS -DCADR_BOARD_DE25 -Mdir $(BUILD)/obj_board_reset_de25 \
	    $(BOARD_RESET_DE25) $(abspath tb/cadr_board_reset_tb.cpp)

$(BUILD)/board_reset.pass: $(BUILD)/obj_board_reset_arty/Vcadr_board_reset_harness \
                           $(BUILD)/obj_board_reset_cora/Vcadr_board_reset_harness \
                           $(BUILD)/obj_board_reset_de25/Vcadr_board_reset_harness \
                           $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_board_reset_arty/Vcadr_board_reset_harness
	$(BUILD)/obj_board_reset_cora/Vcadr_board_reset_harness
	$(BUILD)/obj_board_reset_de25/Vcadr_board_reset_harness
	@touch $@

# ------------------------------------------------ the fault bitstream, per board
#
# THE TOP LEVEL U-BOOT LOADS WHEN THE CADR'S CANNOT BE LOADED: no machine,
# every lamp blinking together, every window of both ports answered with
# "FALT", the tally reading "FALT", and nothing mastering memory; on the
# DE25-Nano the warm-reset handshake answered too.  `tb/cadr_fault_tb.cpp` has
# what is held.  Each board's fault top level is simulated with the
# processing system of `board_reset` above, and linted against the real
# `cadr_ps7.sv` wrapper and the DE25-Nano's processor stub, which are what
# the fitters build it with.  Seconds.
FAULT_SIM := tb/cadr_sim_axi.sv rtl/plumbing/cadr_fault_lamp.sv \
             rtl/plumbing/cadr_gp0_default.sv tb/cadr_fault_harness.sv
FAULT_ARTY_SRC := boards/arty-z7-20/cadr_arty_fault.sv
FAULT_CORA_SRC := boards/cora-z7-07s/cadr_cora_fault.sv
FAULT_DE25_SRC := boards/de25-nano/cadr_de25_fault.sv rtl/plumbing/cadr_f2sdram_gate.sv
FAULT_VFLAGS := $(VFLAGS) -O2 -CFLAGS -O2 -Wno-PINCONNECTEMPTY -Irtl/plumbing \
                --top-module cadr_fault_harness

$(BUILD)/obj_fault_arty/Vcadr_fault_harness: $(FAULT_SIM) $(FAULT_ARTY_SRC) tb/cadr_arty_stubs.sv \
        tb/cadr_ps7_sim.sv tb/cadr_fault_tb.cpp | $(BUILD)
	$(VERILATOR) $(FAULT_VFLAGS) -DCADR_BOARD_ARTY -CFLAGS -DCADR_BOARD_ARTY \
	    -Mdir $(BUILD)/obj_fault_arty $(FAULT_SIM) tb/cadr_arty_stubs.sv \
	    tb/cadr_ps7_sim.sv $(FAULT_ARTY_SRC) $(abspath tb/cadr_fault_tb.cpp)

$(BUILD)/obj_fault_cora/Vcadr_fault_harness: $(FAULT_SIM) $(FAULT_CORA_SRC) tb/cadr_arty_stubs.sv \
        tb/cadr_ps7_sim.sv tb/cadr_fault_tb.cpp | $(BUILD)
	$(VERILATOR) $(FAULT_VFLAGS) -DCADR_BOARD_CORA -DCADR_PS7_NO_HP3 -CFLAGS -DCADR_BOARD_CORA \
	    -Mdir $(BUILD)/obj_fault_cora $(FAULT_SIM) tb/cadr_arty_stubs.sv \
	    tb/cadr_ps7_sim.sv $(FAULT_CORA_SRC) $(abspath tb/cadr_fault_tb.cpp)

$(BUILD)/obj_fault_de25/Vcadr_fault_harness: $(FAULT_SIM) $(FAULT_DE25_SRC) tb/cadr_de25_stubs.sv \
        tb/cadr_de25_hps_sim.sv tb/cadr_fault_tb.cpp | $(BUILD)
	$(VERILATOR) $(FAULT_VFLAGS) -DCADR_BOARD_DE25 -DCADR_DE25_HPS_SIM -CFLAGS -DCADR_BOARD_DE25 \
	    -Mdir $(BUILD)/obj_fault_de25 $(FAULT_SIM) tb/cadr_de25_stubs.sv \
	    tb/cadr_de25_hps_sim.sv $(FAULT_DE25_SRC) $(abspath tb/cadr_fault_tb.cpp)

$(BUILD)/fault.pass: $(BUILD)/obj_fault_arty/Vcadr_fault_harness \
                     $(BUILD)/obj_fault_cora/Vcadr_fault_harness \
                     $(BUILD)/obj_fault_de25/Vcadr_fault_harness \
                     boards/arty-z7-20/cadr_ps7.sv boards/cora-z7-07s/cadr_ps7.sv \
                     tb/cadr_ps7_stub.sv
	$(VERILATOR) --lint-only -Wall -Irtl/plumbing --top-module cadr_arty_fault \
	    tb/cadr_arty_stubs.sv tb/cadr_ps7_stub.sv boards/arty-z7-20/cadr_ps7.sv \
	    rtl/plumbing/cadr_gp0_default.sv rtl/plumbing/cadr_fault_lamp.sv $(FAULT_ARTY_SRC)
	$(VERILATOR) --lint-only -Wall -Irtl/plumbing --top-module cadr_cora_fault \
	    tb/cadr_arty_stubs.sv tb/cadr_ps7_stub.sv boards/cora-z7-07s/cadr_ps7.sv \
	    rtl/plumbing/cadr_gp0_default.sv rtl/plumbing/cadr_fault_lamp.sv $(FAULT_CORA_SRC)
	$(VERILATOR) --lint-only -Wall -Irtl/plumbing --top-module cadr_de25_fault \
	    tb/cadr_de25_stubs.sv rtl/plumbing/cadr_gp0_default.sv \
	    rtl/plumbing/cadr_fault_lamp.sv $(FAULT_DE25_SRC)
	$(BUILD)/obj_fault_arty/Vcadr_fault_harness
	$(BUILD)/obj_fault_cora/Vcadr_fault_harness
	$(BUILD)/obj_fault_de25/Vcadr_fault_harness
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
BUS_AUDIT_SRC := $(MACHINE_SRC) rtl/plumbing/cadr_axi_master.sv \
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
$(BUILD)/obj_audit_window/Vcadr_machine: $(MACHINE_SRC) tb/cadr_audit_window_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 --public-flat-rw -Mdir $(BUILD)/obj_audit_window \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE_SRC) \
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

$(BUILD)/obj_nomem/Vcadr_machine: $(MACHINE_SRC) tb/cadr_nomem_tb.cpp tb/cadr_tick.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_nomem \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE_SRC) $(abspath tb/cadr_nomem_tb.cpp)

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
# `rtl/plumbing/cadr_probe.sv`, `boards/arty-z7-20/cadr_ps7.sv` and `rtl/plumbing/cadr_axi_master.sv` are then
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
# FIVE TIMES NOW, and `$(MACHINE_SRC)` COMES FIRST IN EVERY ONE. The top level
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
$(BUILD)/arty.pass: $(MACHINE_SRC) boards/arty-z7-20/cadr_arty.sv rtl/plumbing/cadr_probe.sv \
                    boards/arty-z7-20/cadr_ps7.sv rtl/plumbing/cadr_axi_master.sv \
                    rtl/plumbing/cadr_axi_widen.sv rtl/plumbing/cadr_mem_count.sv \
                    rtl/plumbing/cadr_prove.sv rtl/plumbing/cadr_disk_pack.sv \
                    rtl/plumbing/cadr_gp0_default.sv rtl/plumbing/cadr_console.sv \
                    rtl/plumbing/cadr_lamp_errhalt.sv \
                    rtl/plumbing/cadr_lamp_clock.sv rtl/plumbing/cadr_lamp_microcycle.sv \
                    $(GP0) $(GP1) rtl/plumbing/cadr_debug_window.sv \
                    $(DBGPMOD) $(DISPLAY_SRC) \
                    $(BOARD_STUBS) tb/cadr_ps7_stub.sv | $(BUILD)
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_arty $(BOARD_STUBS) $(MACHINE_SRC) boards/arty-z7-20/cadr_arty.sv $(DBGPMOD)
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    -GPROBE_DEPTH=1024 \
	    --top-module cadr_arty $(BOARD_STUBS) $(MACHINE_SRC) \
	    boards/arty-z7-20/cadr_arty.sv rtl/plumbing/cadr_probe.sv $(DBGPMOD)
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    -GDDR=1 \
	    --top-module cadr_arty $(BOARD_STUBS) tb/cadr_ps7_stub.sv \
	    $(MACHINE_SRC) boards/arty-z7-20/cadr_arty.sv boards/arty-z7-20/cadr_ps7.sv rtl/plumbing/cadr_axi_master.sv \
	    rtl/plumbing/cadr_axi_widen.sv rtl/plumbing/cadr_mem_count.sv rtl/plumbing/cadr_disk_pack.sv \
	    rtl/plumbing/cadr_console.sv rtl/plumbing/cadr_gp0_default.sv $(GP0) \
	    $(GP1) rtl/plumbing/cadr_debug_window.sv $(DBGPMOD)
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    -GPROVE=1 \
	    --top-module cadr_arty $(BOARD_STUBS) tb/cadr_ps7_stub.sv \
	    $(MACHINE_SRC) boards/arty-z7-20/cadr_arty.sv boards/arty-z7-20/cadr_ps7.sv rtl/plumbing/cadr_axi_master.sv \
	    rtl/plumbing/cadr_axi_widen.sv rtl/plumbing/cadr_mem_count.sv rtl/plumbing/cadr_prove.sv \
	    rtl/plumbing/cadr_gp0_default.sv rtl/plumbing/cadr_console.sv $(GP0) \
	    $(GP1) rtl/plumbing/cadr_debug_window.sv $(DBGPMOD)
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    -GPROVE=2 \
	    --top-module cadr_arty $(BOARD_STUBS) tb/cadr_ps7_stub.sv \
	    $(MACHINE_SRC) boards/arty-z7-20/cadr_arty.sv boards/arty-z7-20/cadr_ps7.sv rtl/plumbing/cadr_axi_master.sv \
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
	    $(MACHINE_SRC) boards/arty-z7-20/cadr_arty.sv boards/arty-z7-20/cadr_ps7.sv rtl/plumbing/cadr_axi_master.sv \
	    rtl/plumbing/cadr_axi_widen.sv rtl/plumbing/cadr_mem_count.sv rtl/plumbing/cadr_disk_pack.sv \
	    rtl/plumbing/cadr_console.sv rtl/plumbing/cadr_gp0_default.sv $(GP0) \
	    $(GP1) rtl/plumbing/cadr_debug_window.sv $(DBGPMOD) $(DISPLAY_SRC)
# AND THE DEBUG CABLE'S TWO, AT THEIR OWN DEFAULT PARAMETERS, WHICH IS STILL
# WORTH A PASS OF ITS OWN. Both are composed now --- `cadr_dbgin.sv` is in
# `$(MACHINE_SRC)`, so every pass above elaborates it, and
# `cadr_debug_window.sv` is on the three that bring a PS7 out --- but the
# `dbgin` check elaborates them with the harness's own overrides, where
# `WATCHDOG_T` is 4,096 against the module's 100,000,000. That is a
# different `$clog2` and a different set of widths, and BOTH VIVADO SCRIPTS
# READ `[glob rtl/*/*.sv]`, so a file there that does not elaborate at its
# own defaults breaks the bitstream.
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 \
	    --top-module cadr_dbgin $(TICKPKG) rtl/machine/cadr_dbgin.sv
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 \
	    --top-module cadr_debug_window $(TICKPKG) rtl/plumbing/cadr_debug_window.sv
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
$(BUILD)/cora.pass: $(MACHINE_SRC) boards/cora-z7-07s/cadr_cora.sv rtl/plumbing/cadr_probe.sv \
                    boards/cora-z7-07s/cadr_ps7.sv rtl/plumbing/cadr_axi_master.sv \
                    rtl/plumbing/cadr_axi_widen.sv rtl/plumbing/cadr_mem_count.sv \
                    rtl/plumbing/cadr_prove.sv rtl/plumbing/cadr_disk_pack.sv \
                    rtl/plumbing/cadr_gp0_default.sv rtl/plumbing/cadr_console.sv \
                    $(GP0) $(GP1) rtl/plumbing/cadr_debug_window.sv \
                    $(DBGPMOD) rtl/plumbing/cadr_lamp_errhalt.sv \
                    rtl/plumbing/cadr_lamp_microcycle.sv \
                    $(BOARD_STUBS) tb/cadr_ps7_stub.sv | $(BUILD)
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/cora-z7-07s \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_cora $(BOARD_STUBS) $(MACHINE_SRC) boards/cora-z7-07s/cadr_cora.sv \
	    rtl/plumbing/cadr_lamp_errhalt.sv rtl/plumbing/cadr_lamp_microcycle.sv $(DBGPMOD)
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/cora-z7-07s \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    -GPROBE_DEPTH=1024 \
	    --top-module cadr_cora $(BOARD_STUBS) $(MACHINE_SRC) \
	    boards/cora-z7-07s/cadr_cora.sv rtl/plumbing/cadr_probe.sv \
	    rtl/plumbing/cadr_lamp_errhalt.sv rtl/plumbing/cadr_lamp_microcycle.sv $(DBGPMOD)
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/cora-z7-07s \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    -GDDR=1 \
	    --top-module cadr_cora $(BOARD_STUBS) tb/cadr_ps7_stub.sv \
	    $(MACHINE_SRC) boards/cora-z7-07s/cadr_cora.sv boards/cora-z7-07s/cadr_ps7.sv \
	    rtl/plumbing/cadr_axi_master.sv \
	    rtl/plumbing/cadr_axi_widen.sv rtl/plumbing/cadr_mem_count.sv rtl/plumbing/cadr_disk_pack.sv \
	    rtl/plumbing/cadr_console.sv rtl/plumbing/cadr_gp0_default.sv $(GP0) \
	    $(GP1) rtl/plumbing/cadr_debug_window.sv $(DBGPMOD) rtl/plumbing/cadr_lamp_errhalt.sv \
	    rtl/plumbing/cadr_lamp_microcycle.sv
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/cora-z7-07s \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    -GPROVE=1 \
	    --top-module cadr_cora $(BOARD_STUBS) tb/cadr_ps7_stub.sv \
	    $(MACHINE_SRC) boards/cora-z7-07s/cadr_cora.sv boards/cora-z7-07s/cadr_ps7.sv \
	    rtl/plumbing/cadr_axi_master.sv \
	    rtl/plumbing/cadr_axi_widen.sv rtl/plumbing/cadr_mem_count.sv rtl/plumbing/cadr_prove.sv \
	    rtl/plumbing/cadr_gp0_default.sv rtl/plumbing/cadr_console.sv $(GP0) \
	    $(GP1) rtl/plumbing/cadr_debug_window.sv $(DBGPMOD) rtl/plumbing/cadr_lamp_errhalt.sv \
	    rtl/plumbing/cadr_lamp_microcycle.sv
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/cora-z7-07s \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    -GDDR=1 -GLMTV=0 \
	    --top-module cadr_cora $(BOARD_STUBS) tb/cadr_ps7_stub.sv \
	    $(MACHINE_SRC) boards/cora-z7-07s/cadr_cora.sv boards/cora-z7-07s/cadr_ps7.sv \
	    rtl/plumbing/cadr_axi_master.sv \
	    rtl/plumbing/cadr_axi_widen.sv rtl/plumbing/cadr_mem_count.sv rtl/plumbing/cadr_disk_pack.sv \
	    rtl/plumbing/cadr_console.sv rtl/plumbing/cadr_gp0_default.sv $(GP0) \
	    $(GP1) rtl/plumbing/cadr_debug_window.sv $(DBGPMOD) rtl/plumbing/cadr_lamp_errhalt.sv \
	    rtl/plumbing/cadr_lamp_microcycle.sv
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/cora-z7-07s \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    -GPROVE=2 \
	    --top-module cadr_cora $(BOARD_STUBS) tb/cadr_ps7_stub.sv \
	    $(MACHINE_SRC) boards/cora-z7-07s/cadr_cora.sv boards/cora-z7-07s/cadr_ps7.sv \
	    rtl/plumbing/cadr_axi_master.sv \
	    rtl/plumbing/cadr_axi_widen.sv rtl/plumbing/cadr_mem_count.sv rtl/plumbing/cadr_prove.sv \
	    rtl/plumbing/cadr_gp0_default.sv rtl/plumbing/cadr_console.sv $(GP0) \
	    $(GP1) rtl/plumbing/cadr_debug_window.sv $(DBGPMOD) rtl/plumbing/cadr_lamp_errhalt.sv \
	    rtl/plumbing/cadr_lamp_microcycle.sv
	@touch $@

# ------------------------------------------------- which machine is built
#
# **`MACHINE` REACHES `cadr_machine` ON EVERY BOARD, FOR BOTH VALUES**, and
# nothing else here could say so: the machine's QUUX checks build
# `cadr_machine` with the value directly, so a top level that dropped it would
# build the CADR under QUUX's name and every other check would stay green.  `tools/machine_param_check.py` lints
# each top level with each value and reads the parameter back at `u_machine`
# out of Verilator's elaborated tree; requires a near miss to stop
# elaboration in `u_machine` and QUUX to stop it in the Cora's top level; and
# runs the refusals the Vivado flows and the DE25-Nano's two scripts make
# before any vendor tool is looked for.  Its header says what it cannot see.
#
# Then make's own half, which the script cannot run: `make de25` hands the
# machine to the Quartus flow, and `check MACHINE=quux` holds the machine
# built as QUUX and not the CADR's.  `-n` prints the recipe without running
# it; the check list is read from the variable rather than by a recursive
# `make -n check`, whose own list holds this check and so recurses without
# end.
MACHINE_PARAM_SRC := $(wildcard rtl/*/*.sv rtl/*/*/*.sv boards/*/*.sv) \
                     tb/cadr_arty_stubs.sv tb/cadr_usr_access_stub.sv \
                     tb/cadr_ps7_stub.sv tb/cadr_de25_stubs.sv \
                     boards/arty-z7-20/vivado/bitstream.tcl \
                     boards/cora-z7-07s/vivado/bitstream.tcl \
                     boards/de25-nano/quartus/build.sh \
                     boards/de25-nano/quartus/program.sh

$(BUILD)/machine_param.pass: tools/machine_param_check.py $(MACHINE_PARAM_SRC) Makefile | $(BUILD)
	VERILATOR=$(VERILATOR) TCLSH=$(TCLSH) python3 tools/machine_param_check.py .
	$(MAKE) -s -n de25 MACHINE=quux | tr -d '\\\n' \
	    | grep -q 'MACHINE=quux .*boards/de25-nano/quartus/build.sh' \
	    || { echo "machine: make de25 MACHINE=quux does not hand the machine to build.sh"; exit 1; }
	@echo "machine: ok      make de25 MACHINE=quux hands the machine to build.sh"
	@echo "$(CHECK_QUUX)" | tr ' ' '\n' | grep -qx '$(BUILD)/machine.quux.$(QK).pass' \
	    || { echo "machine: make check MACHINE=quux does not hold the machine built as QUUX"; exit 1; }
	@! echo "$(CHECK_QUUX)" | tr ' ' '\n' | grep -qx '$(BUILD)/machine.pass' \
	    || { echo "machine: make check MACHINE=quux holds the CADR's machine check"; exit 1; }
	@echo "machine: ok      make check MACHINE=quux holds the machine built as QUUX, and not the CADR's"
	@touch $@

# ------------------------------------------------ the DE25-Nano's top level
#
# `boards/de25-nano/cadr_de25.sv` is the first board built by Quartus, and
# like the two Zynq boards it cannot be simulated as it is built: its PLL is
# generated at build time and its reset release is a primitive Quartus
# supplies.  So this is first its lint, and what lint holds is the same as
# `arty.pass` holds there --- that every output of `cadr_machine` reaches the
# instance and the fold, and that nothing in the top level is left undriven or
# unread --- and then the top level simulated around shells of those pieces,
# which is what holds its wiring; the rule below the lint has that.
#
# THREE BOARDS, THE PLAIN ONE, THE PROBE'S AND THE MEMORY BOARD.  `PROBE_DEPTH`
# is a parameter and `CADR_DE25_DDR` a define, because the memory board has
# ports the others do not, and a lint of the default elaborates neither arm.
# So the second pass is the only thing short of Quartus that reads the probe's
# wiring, and the third the only thing that reads the processor's: its
# memory bank, its pins, both bridges' default slaves and the machine's port
# on the third.  All three take the DE25-Nano's map of the processor's memory,
# `$(DE25_MAP)`, and the top level checks that they did.
#
# **ITS STUBS ARE ITS OWN**, `tb/cadr_de25_stubs.sv`, and in `tb/` for the
# reason `tb/cadr_arty_stubs.sv` gives.  The Quartus flow is `make de25`,
# outside `check`, because it needs Quartus and about eight minutes.
$(BUILD)/de25.pass: $(MACHINE_SRC) $(DE25_TOP) $(DE25_PROBE) $(DE25_DDR) $(DE25_HDMI) tb/cadr_de25_stubs.sv \
                   $(BUILD)/obj_de25_top/Vcadr_de25 | $(BUILD)
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing $(DE25_MAP) \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_de25 tb/cadr_de25_stubs.sv $(MACHINE_SRC) $(DE25_TOP)
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing $(DE25_MAP) \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    -GPROBE_DEPTH=1024 \
	    --top-module cadr_de25 tb/cadr_de25_stubs.sv $(MACHINE_SRC) $(DE25_TOP) \
	    $(DE25_PROBE)
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing $(DE25_MAP) \
	    -DCADR_DE25_DDR \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_de25 tb/cadr_de25_stubs.sv $(MACHINE_SRC) $(DE25_TOP) \
	    $(DE25_DDR)
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing $(DE25_MAP) \
	    -DCADR_DE25_DDR -DCADR_DE25_HDMI \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_de25 tb/cadr_de25_stubs.sv $(MACHINE_SRC) $(DE25_TOP) \
	    $(DE25_DDR) $(DE25_HDMI)
	$(BUILD)/obj_de25_top/Vcadr_de25
	@touch $@

# **AND THE TOP LEVEL SIMULATED, WHICH IS WHAT HOLDS ITS WIRING.**  Lint holds
# that every port is connected; it cannot tell a crossed pair of wires of one
# width from a straight one, and measured, eleven such faults of this board
# passed it.  So the whole board --- `CADR_DE25_DDR` and `CADR_DE25_HDMI` --- is
# built around the shells in `tb/cadr_de25_sim_stubs.sv`, with the machine a
# shell too, and `tb/cadr_de25_top_tb.cpp` is the processor, its memory, the
# transmitter's bus, the buttons and a person reading the lamps and the video
# pins.  Its header has what it holds and why each shell is safe.  Part of
# `de25.pass`, so that the mutation runner's `de25` and this rule are one
# check.  About two minutes, most of it the one second the display's sleep
# takes to fall due.
DE25_SIM := tb/cadr_de25_top.vlt tb/cadr_de25_sim_stubs.sv $(TICKPKG) \
            rtl/plumbing/cadr_ddr_map.sv $(DE25_TOP) $(DE25_DDR) $(DE25_HDMI)

$(BUILD)/obj_de25_top/Vcadr_de25: $(DE25_SIM) tb/cadr_de25_top_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) --pins-inout-enables -O2 -CFLAGS -O2 \
	    -Irtl/machine -Irtl/plumbing $(DE25_MAP) -DCADR_DE25_DDR -DCADR_DE25_HDMI \
	    -Mdir $(BUILD)/obj_de25_top --top-module cadr_de25 $(DE25_SIM) \
	    $(abspath tb/cadr_de25_top_tb.cpp)

# THE DE25-NANO'S BITSTREAM, which needs Quartus Prime Pro and is not part of
# `check`.  `boards/de25-nano/quartus/build.sh` says where Quartus is found
# and what each step refuses; everything it writes is under `build/de25/`.
# `PROBE_DEPTH=1024` builds the instrumented board into `build/de25-probe/`,
# and `DDR=1` the memory board, the processor and its LPDDR4 behind the
# machine's memory port, into `build/de25-ddr/`, with `DE25_DDR_MHZ` the
# LPDDR4's speed: 1066.667 by default, or 1333.333 on a rev B board.
# `MACHINE=quux` builds the evolved CADR instead, into `build/de25-quux/` and
# the same suffixes after it, so that neither machine's build replaces the
# other's.
PROBE_DEPTH ?= 0
DDR ?= 0
# **`HDMI=1` BUILDS THE DISPLAY OUTPUT INTO THE MEMORY BOARD**, into
# `build/de25-hdmi/`: the CADR's screens read out of the machine's memory and
# put on the board's ADV7513, as `HDMI=1` does for the Arty Z7-20.  It needs
# `DDR=1`, because the picture is in the machine's memory.
HDMI ?= 0
DE25_DDR_MHZ ?= 1066.667
# How the processor boots, and the first-stage loader to put in the file the
# programmer takes: `boards/de25-nano/quartus/build.sh` says what each makes.
DE25_HPS_BOOT ?= hps-first
DE25_SPL_HEX ?=
de25: $(MACHINE_SRC) $(DE25_TOP) $(DE25_PROBE) $(DE25_DDR) $(DE25_HDMI) $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex \
      $(if $(filter quux,$(MACHINE)),$(BUILD)/boot_prom.quux.hex)
	PROBE_DEPTH=$(PROBE_DEPTH) DDR=$(DDR) DE25_DDR_MHZ=$(DE25_DDR_MHZ) \
	    HDMI=$(HDMI) MACHINE=$(MACHINE) \
	    DE25_HPS_BOOT=$(DE25_HPS_BOOT) DE25_SPL_HEX=$(DE25_SPL_HEX) \
	    boards/de25-nano/quartus/build.sh $(MACHINE_SRC) $(DE25_TOP) \
	    $(if $(filter-out 0,$(PROBE_DEPTH)),$(DE25_PROBE)) \
	    $(if $(filter-out 0,$(DDR)),$(DE25_DDR)) \
	    $(if $(filter-out 0,$(HDMI)),$(DE25_HDMI))

# **AND THE DE25-NANO'S FAULT BITSTREAM**, `boards/de25-nano/cadr_de25_fault.sv`:
# no machine, every lamp blinking, and the memory board's processor system,
# which U-Boot loads when the CADR's core image cannot be loaded.  Into
# `build/de25-fault/`; `DE25_SPL_HEX` makes its core image as for the CADR.
# The Zynq boards' two are `tools/fault_zynq.tcl`'s, under Vivado.
de25-fault: rtl/plumbing/cadr_fault_lamp.sv rtl/plumbing/cadr_gp0_default.sv $(FAULT_DE25_SRC) \
            $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	FAULT=1 DDR=1 HDMI=0 PROBE_DEPTH=0 DE25_DDR_MHZ=$(DE25_DDR_MHZ) \
	    DE25_HPS_BOOT=$(DE25_HPS_BOOT) DE25_SPL_HEX=$(DE25_SPL_HEX) \
	    boards/de25-nano/quartus/build.sh rtl/plumbing/cadr_fault_lamp.sv \
	    rtl/plumbing/cadr_gp0_default.sv $(FAULT_DE25_SRC)

# And that bitstream loaded over JTAG, which is volatile: nothing here writes
# the board's flash.  `boards/de25-nano/quartus/program.sh` finds the board's
# cable by the serial in `boards/de25-nano/local.conf`.
de25-program:
	PROBE_DEPTH=$(PROBE_DEPTH) DDR=$(DDR) HDMI=$(HDMI) MACHINE=$(MACHINE) \
	    boards/de25-nano/quartus/program.sh

# And the probe's capture read off that board and compared with muir: the
# silicon half of what `build/probe.pass` holds in simulation.  The reader is
# `boards/de25-nano/quartus/probe.tcl` under `quartus_stp`, which refuses a
# part that does not hold the probe build in `build/de25-probe/`; the verdict
# is `tools/probe_check.py`'s.  Quartus is found as `build.sh` finds it.
DE25_QUARTUS = $${QUARTUS_ROOTDIR:-$$(sed -n 's/^[[:space:]]*QUARTUS_ROOTDIR[[:space:]]*=[[:space:]]*//p' \
                   boards/de25-nano/local.conf 2>/dev/null | tail -n 1 | tr -d "\"'")}
de25-probe: $(BUILD)/rtl.golden
	"$(DE25_QUARTUS)/bin/quartus_stp" -t boards/de25-nano/quartus/probe.tcl
	python3 tools/probe_check.py --capture $(BUILD)/de25-probe/capture.csv \
	    --golden $(BUILD)/rtl.golden

# ------------------------------------------ the DE25-Nano's JTAG scripts
#
# `boards/de25-nano/quartus/probe.tcl` reads the probe off the board, and
# `usercode.tcl` reads back the build a part holds for `program.sh`; both
# need a board and Quartus, so nothing would run them otherwise, and the
# Zynq reader shipped with a bug nothing could have caught for that reason.
# `tb/cadr_de25_jtag_tb.tcl` runs both against `tb/cadr_de25_jtag_model.tcl`,
# the ten `quartus_stp` commands they use with the shapes measured on the
# board, and asserts for each case the LINES it must print.  It also holds
# the DE25 reader's field table to the Zynq reader's.  `tclsh`, no board.
# What the model cannot see is in its own header.
$(BUILD)/de25_jtag.pass: boards/de25-nano/quartus/probe.tcl \
                         boards/de25-nano/quartus/usercode.tcl \
                         boards/de25-nano/quartus/jtag.tcl tools/build_stamp.tcl \
                         boards/arty-z7-20/vivado/probe.tcl \
                         tb/cadr_de25_jtag_model.tcl tb/cadr_de25_jtag_tb.tcl | $(BUILD)
	OUTDIR=$(BUILD)/de25_jtag $(TCLSH) tb/cadr_de25_jtag_tb.tcl
	@touch $@

# --------------------------------------------------------------- the probe

# `rtl/plumbing/cadr_probe.sv` is what will be read off the board. It is checked the
# way everything else here is checked --- against muir's own trace --- and not
# merely instantiated: `tb/cadr_probe_harness.sv` wires it to `cadr_machine`
# exactly as `boards/arty-z7-20/cadr_arty.sv` does, and the testbench shifts all 1,024
# samples out through the probe's own JTAG shift register and compares every
# column against `build/rtl.golden`. The window needs no stimulus: the boot
# PROM's first memory cycle is at microcycle 535,791.
#
# The harness is in `tb/` for the reason `tb/cadr_arty_stubs.sv` gives: both
# Vivado scripts read `[glob rtl/*/*.sv rtl/*/*/*.sv boards/arty-z7-20/*.sv]`.
PROBE_SRC := $(MACHINE_SRC) rtl/plumbing/cadr_probe.sv rtl/plumbing/agilex5/cadr_probe_vjtag.sv \
             tb/cadr_probe_harness.sv

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
# presents, and `tb/cadr_probe_jtag_tb.tcl` runs the script against eleven
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
$(BUILD)/probe_jtag.pass: boards/arty-z7-20/vivado/probe.tcl tools/jtag_target.tcl \
                          tb/cadr_jtag_chain.tcl tb/cadr_probe_jtag_tb.tcl | $(BUILD)
	OUTDIR=$(BUILD)/probe_jtag $(TCLSH) tb/cadr_probe_jtag_tb.tcl
	@touch $@

# --------------------------------------------- what says a download took
#
# The other script that needs a board, held the same way.  `program.tcl` used
# to decide that a download had worked from the DONE bit alone, and DONE is
# already high on a part that was configured before the run --- so the one
# witness read the same whether the configuration took or not.  On one board
# three downloads in six did not take while the script said they had, and what
# caught it was an identity read out of the design.
#
# The script compares the build the part reads back over JTAG with the build
# the bitstream names, which `tools/build_stamp.tcl` writes into
# `BITSTREAM.CONFIG.USERID` at the other end, and it picks the JTAG target by
# cable serial through `tools/jtag_target.tcl`.  This runs it against a
# stubbed hardware manager, nineteen cases, and asserts, for each, the LINE
# it must print --- because "the part already held this build" and "the
# download took" are two different findings with one exit status.
#
# IN `check`: no Vivado, no cable, no bitstream, and 0.08 s measured.  Six
# records in `mutations/list.txt` aim at it, at all three of its sources, so
# nothing here needs an exemption.
#
# WHAT IT CANNOT SAY is in `tb/cadr_program_tb.tcl`'s header: the USERCODE is
# a stub answering what the case says, and that a part really reads its
# bitstream's USERID back there is read out of the BSDL and Vivado's device
# tables and has not been measured on a board by anything in this repository.
$(BUILD)/program_tcl.pass: boards/arty-z7-20/vivado/program.tcl \
                           tools/build_stamp.tcl tools/jtag_target.tcl \
                           tb/cadr_program_tb.tcl | $(BUILD)
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

# **HOW MANY MUTATIONS RUN AT ONCE.** The runner's own default is half the
# machine's cores, and its reason is memory rather than courtesy: a job is a
# Verilator build of a large module, and enough of them at once will have the
# kernel kill something. That default does not bound the cores used, because
# one job is several processes, so this machine names a number instead.
# Sixteen is the share a run here is allowed on a twenty-four core host, which
# leaves the rest to the other work that shares it. Lower it on a machine with
# less memory, since the runner's own reason for a limit is memory rather than
# courtesy: a job is a Verilator build of a large module, and enough of them
# at once will have the kernel kill something. The jobs are left free to
# schedule wherever the kernel likes; do not pin them to a subset of cores,
# which only leaves idle cores unused.
MUTJOBS ?= 16

# **WHERE ccache KEEPS THE MUTANTS' OBJECTS.**  Every mutant used to compile
# Verilator's runtime, its testbench and the whole model from nothing, and
# most of that text is the same in every mutant.  Through ccache only what the
# mutation changed is compiled.  A cached object is keyed on the text it was
# compiled from, so it cannot be a stale binary.  The cache outlives the run
# and ccache evicts the oldest objects past the size.  Empty turns it off.
MUTCCACHE ?= $(HOME)/.cache/muir-fpga-ccache
MUTCCACHE_SIZE ?= 10G
MUTCACHEFLAGS := $(if $(MUTCCACHE),--ccache '$(MUTCCACHE)' --ccache-size $(MUTCCACHE_SIZE))

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

# QUUX's traces and PROM images, both machines' programs among them: `make
# mutants` runs the records aimed at the CADR's checks, the CADR's side of
# QUUX's programs included, and `make mutants MACHINE=quux` those aimed at
# QUUX's.  `mutations/run.py` without `--machine` runs both.
MUTANT_QUUX = $(BUILD)/boot_prom.quux.hex $(BUILD)/xbus_decode.quux.golden \
              $(BUILD)/muldiv.quux.golden $(BUILD)/quux_input.quux.golden \
              $(BUILD)/quux_block_disk.quux.golden \
              $(patsubst %,$(BUILD)/quux_%_prom.hex,$(QUUX_PROGRAMS)) \
              $(patsubst %,$(BUILD)/quux_%_prom.quux.hex,$(sort $(QUUX_SYNC_PROGRAMS) $(QUUX_L1_PROGRAMS))) \
              $(QUUX_PROGRAMS:%=$(BUILD)/quux_%.golden) \
              $(foreach q,k4,$(BUILD)/rtl.quux.$(q).golden \
                  $(BUILD)/dispatch_write_order.quux.$(q).golden \
                  $(QUUX_SYNC_PROGRAMS:%=$(BUILD)/quux_%.quux.$(q).golden)) \
              $(foreach q,k4l1,$(QUUX_L1_PROGRAMS:%=$(BUILD)/quux_%.quux.$(q).golden) \
                  $(BUILD)/phase_gen.quux.$(q).golden)

mutants: mutants-anchors $(BUILD)/phase_gen.golden $(BUILD)/busint_xbus.golden \
         $(BUILD)/xbus_decode.golden $(BUILD)/rtl.golden \
         $(BUILD)/disk.golden $(BUILD)/disk_boot.golden $(BUILD)/tv.golden \
         $(BUILD)/tv_lispm.golden $(BUILD)/color_tv.golden \
         $(BUILD)/iob.golden $(BUILD)/busint_regs.golden $(BUILD)/power_on.golden \
         $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex $(BUILD)/rtl_sys.golden \
         $(BUILD)/dispatch_write_order.golden $(MUTANT_QUUX) | $(BUILD)
	python3 mutations/run.py --goldens $(BUILD) --work $(MUTDIR) \
	    --verilator '$(VERILATOR)' --cargo '$(CARGO)' --tclsh '$(TCLSH)' \
	    --jobs $(MUTJOBS) --rev $(MUTREV) --machine $(MACHINE) $(MUTCACHEFLAGS)

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
             | $(BUILD)
	python3 mutations/run.py --goldens $(BUILD) --work $(MUTDIR) \
	    --verilator '$(VERILATOR)' --cargo '$(CARGO)' --tclsh '$(TCLSH)' \
	    --self-test $(MUTCACHEFLAGS)

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

# ---------------------------------------------- the read-during-write window
#
# **THE TICK A BOARD MAY LEAVE UNDEFINED, MADE VISIBLE.**  The dispatch
# memory and both levels of the map are read asynchronously, and on the
# DE25-Nano they are Altera MLABs, which read asynchronously only with
# read-during-write checking off: the word read at an address in the tick
# after the edge that wrote it is not specified there.  This builds the
# processor with `CADR_RDW_POISON`, under which that read returns the
# complement of the word, and runs both programs.  Every row still agreeing
# with muir says no consumer samples one of the three memories in that tick;
# the counts it prints say how many ticks were poisoned, and a memory never
# poisoned fails the run.  `rtl/machine/cadr_microcycle.sv`'s last section
# has the argument and the measurement that keeps the write tick itself out.
#
# The define is set here and nowhere else; no board flow reads it.
$(BUILD)/obj_rdw_poison/Vcadr_microcycle: $(MICROCYCLE) tb/cadr_microcycle_tb.cpp tb/cadr_tick.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 +define+CADR_RDW_POISON -Mdir $(BUILD)/obj_rdw_poison \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    --top-module cadr_microcycle $(MICROCYCLE) $(abspath tb/cadr_microcycle_tb.cpp)

$(BUILD)/rdw_poison.pass: $(BUILD)/obj_rdw_poison/Vcadr_microcycle \
                          $(BUILD)/rtl.golden $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_rdw_poison/Vcadr_microcycle $(BUILD)/rtl.golden
	@touch $@

$(BUILD)/rdw_poison_sys.pass: $(BUILD)/obj_rdw_poison/Vcadr_microcycle \
                              $(BUILD)/rtl_sys.golden $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_rdw_poison/Vcadr_microcycle $(BUILD)/rtl_sys.golden
	@touch $@

# **AND THE ONE PROGRAM THAT WRITES BOTH LEVELS OF THE MAP IN ONE WRITE
# PHASE**, which is where the machine does read a map it is writing: the
# level-2 write's address is the level-1 read of that same tick.  Neither of
# the two programs above does it, and `map_access.pass`'s patched boot PROM
# does, so the same harness runs under the poison too.  Its own patched PROM
# goes to a file of its own, so that the two can run at once.
$(BUILD)/obj_rdw_poison_map/Vcadr_machine: $(MACHINE_SRC) tb/cadr_map_access_tb.cpp tb/cadr_tick.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 +define+CADR_RDW_POISON -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_rdw_poison_map \
	    -GPROM_HEX='"$(abspath $(BUILD))/rdw_poison_map_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE_SRC) $(abspath tb/cadr_map_access_tb.cpp)

$(BUILD)/rdw_poison_map.pass: $(BUILD)/obj_rdw_poison_map/Vcadr_machine \
                              $(BUILD)/rtl.golden $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_rdw_poison_map/Vcadr_machine $(BUILD)/rtl.golden \
	    $(BUILD)/rdw_poison_map_prom.hex $(BUILD)/boot_prom.hex
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
$(BUILD)/obj_md_hold/Vcadr_microcycle: $(MICROCYCLE) tb/cadr_md_hold_tb.cpp tb/cadr_tick.h | $(BUILD)
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

# THE ONE TICK NO TRACE REACHES, AND THIS TARGET WAS WRITTEN RED.
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
# The defect it named was real when it was written: md_pending survived the
# edge and the held word committed 44 ticks later, one extra-slow microcycle
# at the 5 ns grid, over the word the instruction put there. The MD register's
# first branch --- a strobe on the boundary's own tick loads MD and clears the
# flag --- fixed it at 9d1cf26, so the test is in `check` now, and
# `the-destmdr-edge-leaves-a-strobed-word-owed` takes that branch away. It
# runs the boot PROM twice and takes about half a minute.
$(BUILD)/obj_md_inject/Vcadr_microcycle: $(MICROCYCLE) tb/cadr_md_inject_tb.cpp tb/cadr_tick.h | $(BUILD)
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
# which is 256,000,000 ticks at the 10 ns grid, and the fabric has to
# count every one of them.  A check that cannot tell that constant from a
# wrong one is `RD_FINISH_T` again.  With the pre-roll that puts the spindle
# in phase it is about 285 million ticks and takes a minute or so.
DISK_SRC := $(TICKPKG) rtl/machine/cadr_disk_controller.sv rtl/plumbing/cadr_disk_pack.sv \
            tb/cadr_disk_harness.sv

$(BUILD)/obj_disk/Vcadr_disk_harness: $(DISK_SRC) tb/cadr_disk_tb.cpp tb/cadr_tick.h \
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

# AND AT THE AGILEX 5 BRIDGES' SHAPE, which is the same slave with four bits of
# ID and eight of read length, so reads of up to 256 beats: the DE25-Nano ties
# both of its processor-to-fabric bridges to it until the faces arrive.  A
# second model, because the widths are parameters.
$(BUILD)/obj_gp0_default_axi4/Vcadr_gp0_default: rtl/plumbing/cadr_gp0_default.sv \
                                                 tb/cadr_gp0_default_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -Mdir $(BUILD)/obj_gp0_default_axi4 \
	    -GID_W=4 -GLEN_W=8 -CFLAGS -DGP_ID_W=4 -CFLAGS -DGP_LEN_W=8 \
	    --top-module cadr_gp0_default \
	    rtl/plumbing/cadr_gp0_default.sv $(abspath tb/cadr_gp0_default_tb.cpp)

$(BUILD)/gp0_default.pass: $(BUILD)/obj_gp0_default/Vcadr_gp0_default \
                           $(BUILD)/obj_gp0_default_axi4/Vcadr_gp0_default
	$(BUILD)/obj_gp0_default/Vcadr_gp0_default
	$(BUILD)/obj_gp0_default_axi4/Vcadr_gp0_default
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
# **AND WHERE THE TWO PICTURES SIT IS HELD AS FOUR EDGES A SCREEN AND NOT AS
# AN OVERLAP.**  The first display is at the raster's left edge and the color
# board at its right, so they share 64 columns upright and 137 turned. An
# overlap of 64 is small enough that a margin one pixel out is invisible to a
# person and fatal to a comparison, so the check measures the extreme column
# and row each picture reached --- telling the two apart by their colors, since
# the first display draws only black and white and the map has no white or
# black entry --- and holds each of the eight numbers to the figure
# `docs/display-output.md` states.
#
# The testbench carries its own transcription of VESA DMT's figures for
# 1280x1024 at 60 Hz and of the placement rule, so the module's numbers and the
# check's are two descriptions that can disagree.
$(BUILD)/obj_display_out/Vcadr_display_out: rtl/plumbing/cadr_display_out.sv \
                                            tb/cadr_display_out_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Mdir $(BUILD)/obj_display_out \
	    --top-module cadr_display_out \
	    rtl/plumbing/cadr_display_out.sv $(abspath tb/cadr_display_out_tb.cpp)

$(BUILD)/display_out.pass: $(BUILD)/obj_display_out/Vcadr_display_out
	$(BUILD)/obj_display_out/Vcadr_display_out
	@touch $@

# QUUX's picture, MONO TV at the bitstreams' 1280 by 1024: the same module and
# the same testbench, built at the picture the QUUX boards pass it.  It fills
# the raster, so it cannot turn a quarter, and the check holds it upright when
# a turn is asked for; QUUX has no color board.
$(BUILD)/obj_display_out_quux/Vcadr_display_out: rtl/plumbing/cadr_display_out.sv \
                                                 tb/cadr_display_out_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS '-O2 -DCADR_DISPLAY_QUUX' -Mdir $(BUILD)/obj_display_out_quux \
	    -GPIC_W=1280 -GPIC_H=1024 -GWORDS_PER_LINE=40 -GCOLOR_BASE=470024192 \
	    --top-module cadr_display_out \
	    rtl/plumbing/cadr_display_out.sv $(abspath tb/cadr_display_out_tb.cpp)

$(BUILD)/display_out.quux.pass: $(BUILD)/obj_display_out_quux/Vcadr_display_out
	$(BUILD)/obj_display_out_quux/Vcadr_display_out
	@touch $@

# The display output's sleep: the timer, its prescaler and the mute on the four
# lanes, which is how a source puts a monitor to sleep --- a digital link has
# no power management of its own, so the link stops and the monitor sees no
# signal.
#
# `tb/cadr_display_sleep_tb.cpp` holds the timer to the tick from a write, a
# wake while asleep, a wake while awake and a fabric reset; holds the mute to
# the frame boundary, recovered from the syncs as a monitor recovers it; and
# holds that the raster keeps its own shape while the lanes are muted and that
# zero never mutes.
#
# **ITS OWN BUILD, BECAUSE A REAL RASTER AND A REAL SECOND ARE TOO SLOW TO WAIT
# FOR.**  Three hundred seconds of a real second is thirty billion edges.  So
# the raster is 100 by 80 with pictures small enough to sit inside it, and a
# second is 2,000 ticks, which makes the fabric's own default eighty frames.
# The default setting itself is NOT overridden: it is the module's.  The check
# carries these figures a second time and measures the frame from the syncs,
# so a build here with other figures fails rather than measuring itself.
DISPLAY_SLEEP_G := -GH_ACTIVE=80 -GH_FRONT=4 -GH_SYNC=6 -GH_BACK=10 \
                   -GV_ACTIVE=70 -GV_FRONT=2 -GV_SYNC=3 -GV_BACK=5 \
                   -GPIC_W=64 -GPIC_H=6 -GWORDS_PER_LINE=2 \
                   -GCPIC_W=16 -GCPIC_H=4 -GCWORDS_PER_LINE=2 \
                   -GMONO_ENTRIES=16 -GCOLOR_ENTRIES=16 -GSECOND_T=2000

$(BUILD)/obj_display_sleep/Vcadr_display_out: rtl/plumbing/cadr_display_out.sv \
                                              tb/cadr_display_sleep_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Mdir $(BUILD)/obj_display_sleep \
	    $(DISPLAY_SLEEP_G) --top-module cadr_display_out \
	    rtl/plumbing/cadr_display_out.sv $(abspath tb/cadr_display_sleep_tb.cpp)

$(BUILD)/display_sleep.pass: $(BUILD)/obj_display_sleep/Vcadr_display_out
	$(BUILD)/obj_display_sleep/Vcadr_display_out
	@touch $@

# THE DISPLAY OUTPUT BEHIND THE DE25-NANO'S SHARE OF ONE PORT: the same
# testbench as `display_out.pass`, built with `CADR_DISPLAY_SHARE` around
# `tb/cadr_display_share_harness.sv`, which puts the display on the third port
# of `rtl/plumbing/cadr_f2sdram_share.sv` as the board does.  Against a memory
# whose round trip is pipelined, every picture upright and rotated must keep
# up and, rotated, reach the memory with more than one read in flight.  Its
# header in the testbench has the figure and what was measured either side of
# it.  About fifteen seconds.
DISPLAY_SHARE_SRC := rtl/plumbing/cadr_display_out.sv rtl/plumbing/cadr_f2sdram_share.sv \
                     tb/cadr_display_share_harness.sv

$(BUILD)/obj_display_share/Vcadr_display_share_harness: $(DISPLAY_SHARE_SRC) \
                                                      tb/cadr_display_out_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -CFLAGS -DCADR_DISPLAY_SHARE \
	    -Mdir $(BUILD)/obj_display_share --top-module cadr_display_share_harness \
	    $(DISPLAY_SHARE_SRC) $(abspath tb/cadr_display_out_tb.cpp)

$(BUILD)/display_share.pass: $(BUILD)/obj_display_share/Vcadr_display_share_harness
	$(BUILD)/obj_display_share/Vcadr_display_share_harness
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

# The HDMI transmitter on the DE25-Nano, and the two wires its registers are
# written over.  On the Arty Z7-20 the fabric makes the link itself and there
# is nothing to configure; here the part does nothing at all until it is
# written, so this is the piece the second vendor's board needs and the first
# does not.
#
# `tb/cadr_adv7513_tb.cpp` reads the two lines as a bus analyzer reads them:
# it recovers the starts, the stops, every bit and every acknowledge from
# their edges, never from a signal inside the module and never by predicting
# where an edge will be, and compares the byte stream with ITS OWN
# transcription of the program --- so the two transcriptions are two
# descriptions of one thing and can disagree.  It also measures the six
# intervals the part's data sheet bounds and prints the worst of each, drives
# a stretched clock and a refused byte, and holds that the bus is left alone
# once the program is through.
#
# WHAT IT DOES NOT HOLD is that these registers and these values make an
# ADV7513 transmit.  The register map is in a programming guide that is not
# here, the program is the board vendor's own for this board, and this
# board's connector has never been wired to a monitor.
$(BUILD)/obj_adv7513/Vcadr_adv7513: rtl/plumbing/cadr_adv7513.sv \
                                    tb/cadr_adv7513_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Mdir $(BUILD)/obj_adv7513 \
	    --top-module cadr_adv7513 \
	    rtl/plumbing/cadr_adv7513.sv $(abspath tb/cadr_adv7513_tb.cpp)

$(BUILD)/adv7513.pass: $(BUILD)/obj_adv7513/Vcadr_adv7513
	$(BUILD)/obj_adv7513/Vcadr_adv7513
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
GP0_SPLIT_SRC := $(TICKPKG) tb/cadr_gp0_split_harness.sv $(GP0) \
                 rtl/plumbing/cadr_gp0_default.sv rtl/plumbing/cadr_disk_pack.sv \
                 rtl/machine/cadr_io_board.sv

$(BUILD)/obj_gp0_split/Vcadr_gp0_split_harness: $(GP0_SPLIT_SRC) \
                                                tb/cadr_gp0_split_tb.cpp tb/cadr_tick.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 \
	    -Mdir $(BUILD)/obj_gp0_split --top-module cadr_gp0_split_harness \
	    $(GP0_SPLIT_SRC) $(abspath tb/cadr_gp0_split_tb.cpp)

# AND THE SAME ARRANGEMENT AT THE DE25-NANO'S SHAPE AND MAP, which is the
# same five slaves behind the same splitter on the HPS-to-FPGA bridge: AXI4,
# four bits of ID and eight of burst length, and the faces at offsets 0 to
# 0x3000 into the bridge's own window rather than at the processor's
# `0x4000_0000`.  A second model, because those are parameters; the sweep is
# the whole of both windows, twice.
$(BUILD)/obj_gp0_split_axi4/Vcadr_gp0_split_harness: $(GP0_SPLIT_SRC) \
                                                tb/cadr_gp0_split_tb.cpp tb/cadr_tick.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 \
	    -GID_W=4 -GLEN_W=8 \
	    -GPACK_BASE=32\'h0000_0000 -GCHAOS_BASE=32\'h0000_1000 \
	    -GSER_BASE=32\'h0000_2000 -GINPUT_BASE=32\'h0000_3000 \
	    -CFLAGS -DGP_ID_W=4 -CFLAGS -DGP_LEN_W=8 \
	    -CFLAGS -DGP_PORT_BASE=0x00000000u \
	    -Mdir $(BUILD)/obj_gp0_split_axi4 --top-module cadr_gp0_split_harness \
	    $(GP0_SPLIT_SRC) $(abspath tb/cadr_gp0_split_tb.cpp)

$(BUILD)/gp0_split.pass: $(BUILD)/obj_gp0_split/Vcadr_gp0_split_harness \
                         $(BUILD)/obj_gp0_split_axi4/Vcadr_gp0_split_harness
	$(BUILD)/obj_gp0_split/Vcadr_gp0_split_harness
	$(BUILD)/obj_gp0_split_axi4/Vcadr_gp0_split_harness
	@touch $@

# The Chaosnet cable's face alone, against the program's calls overlapping
# the cable's own work: a give landing while the last frame still streams, a
# commit whose length is not a frame, and a take racing the machine's Clear
# Transmitter.  `gp0_split` carries a frame at a time across the whole seam;
# this is what happens between two of them.
CHAOS_CABLE_SRC := rtl/plumbing/cadr_gp_regs.sv rtl/plumbing/cadr_chaos_cable.sv

$(BUILD)/obj_chaos_cable/Vcadr_chaos_cable: $(CHAOS_CABLE_SRC) tb/cadr_chaos_cable_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -Mdir $(BUILD)/obj_chaos_cable \
	    --top-module cadr_chaos_cable $(CHAOS_CABLE_SRC) $(abspath tb/cadr_chaos_cable_tb.cpp)

$(BUILD)/chaos_cable.pass: $(BUILD)/obj_chaos_cable/Vcadr_chaos_cable
	$(BUILD)/obj_chaos_cable/Vcadr_chaos_cable
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
GP1_SPLIT_SRC := $(TICKPKG) tb/cadr_gp1_split_harness.sv $(GP1) \
                 rtl/plumbing/cadr_console.sv rtl/plumbing/cadr_debug_window.sv \
                 rtl/plumbing/cadr_gp0_default.sv \
                 rtl/machine/cadr_dbgin.sv rtl/machine/cadr_console_bus.sv \
                 rtl/machine/cadr_spy_registers.sv

$(BUILD)/obj_gp1_split/Vcadr_gp1_split_harness: $(GP1_SPLIT_SRC) \
                                                tb/cadr_gp1_split_tb.cpp tb/cadr_tick.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 \
	    -Mdir $(BUILD)/obj_gp1_split --top-module cadr_gp1_split_harness \
	    $(GP1_SPLIT_SRC) $(abspath tb/cadr_gp1_split_tb.cpp)

# AND THE SAME THREE AT THE DE25-NANO'S SHAPE AND MAP, on the lightweight
# bridge: AXI4 with four bits of ID and eight of burst length, the console at
# offset 0 and the cable's window at 0x1000, and a window of 512 MB rather
# than the Zynq port's gigabyte --- 131,072 pages, every one of them read.
$(BUILD)/obj_gp1_split_axi4/Vcadr_gp1_split_harness: $(GP1_SPLIT_SRC) \
                                                tb/cadr_gp1_split_tb.cpp tb/cadr_tick.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 \
	    -GID_W=4 -GLEN_W=8 \
	    -GCON_BASE=32\'h0000_0000 -GDBG_BASE=32\'h0000_1000 \
	    -CFLAGS -DGP_ID_W=4 -CFLAGS -DGP_LEN_W=8 \
	    -CFLAGS -DGP_PORT_BASE=0x00000000u -CFLAGS -DGP_PORT_PAGES=131072u \
	    -Mdir $(BUILD)/obj_gp1_split_axi4 --top-module cadr_gp1_split_harness \
	    $(GP1_SPLIT_SRC) $(abspath tb/cadr_gp1_split_tb.cpp)

$(BUILD)/gp1_split.pass: $(BUILD)/obj_gp1_split/Vcadr_gp1_split_harness \
                         $(BUILD)/obj_gp1_split_axi4/Vcadr_gp1_split_harness
	$(BUILD)/obj_gp1_split/Vcadr_gp1_split_harness
	$(BUILD)/obj_gp1_split_axi4/Vcadr_gp1_split_harness
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
CONSOLE_SRC := $(TICKPKG) rtl/machine/cadr_phase_gen.sv rtl/machine/cadr_microcycle.sv \
               rtl/machine/cadr_spy_registers.sv rtl/machine/cadr_console_bus.sv \
               rtl/machine/cadr_console_state.sv rtl/plumbing/cadr_console.sv \
               tb/cadr_console_harness.sv

$(BUILD)/obj_console/Vcadr_console_harness: $(CONSOLE_SRC) \
                                            tb/cadr_console_tb.cpp tb/cadr_tick.h | $(BUILD)
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
DBGIN_SRC := $(TICKPKG) rtl/machine/cadr_phase_gen.sv rtl/machine/cadr_microcycle.sv \
             rtl/machine/cadr_spy_registers.sv rtl/machine/cadr_console_bus.sv \
             rtl/machine/cadr_dbgin.sv rtl/plumbing/cadr_debug_window.sv \
             tb/cadr_dbgin_harness.sv

$(BUILD)/obj_dbgin/Vcadr_dbgin_harness: $(DBGIN_SRC) \
                                        tb/cadr_dbgin_tb.cpp tb/cadr_tick.h | $(BUILD)
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
DBG_PMOD_SRC := $(TICKPKG) tb/cadr_dbg_pmod_harness.sv rtl/plumbing/cadr_dbg_tx.sv \
                rtl/plumbing/cadr_dbg_rx.sv rtl/plumbing/cadr_dbg_join.sv \
                rtl/plumbing/cadr_debug_window.sv \
                rtl/machine/cadr_dbgin.sv rtl/machine/cadr_console_bus.sv \
                rtl/machine/cadr_spy_registers.sv

$(BUILD)/obj_dbg_pmod/Vcadr_dbg_pmod_harness: $(DBG_PMOD_SRC) \
                                              tb/cadr_dbg_pmod_tb.cpp tb/cadr_tick.h | $(BUILD)
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
DBG_CABLE_SRC := $(TICKPKG) tb/cadr_dbg_cable_harness.sv rtl/plumbing/cadr_dbg_cable.sv \
                 rtl/plumbing/cadr_dbg_tx.sv rtl/plumbing/cadr_dbg_rx.sv \
                 rtl/plumbing/cadr_dbg_join.sv \
                 rtl/machine/cadr_dbgin.sv rtl/machine/cadr_busint_regs.sv \
                 rtl/machine/cadr_console_bus.sv rtl/machine/cadr_spy_registers.sv

$(BUILD)/obj_dbg_cable/Vcadr_dbg_cable_harness: $(DBG_CABLE_SRC) \
                                                tb/cadr_dbg_cable_tb.cpp tb/cadr_tick.h | $(BUILD)
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
# prerequisite at all --- the shape that once left a board's lint not
# re-running on a change to the memory path, and which the recipe cannot show
# because a recipe is expanded at run time.
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
                            $(wildcard $(COMMON_SRC)/cadr/*.h) \
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
# **THE WORK DIRECTORY IS THIS TREE'S OWN, UNDER ITS `build/`.**  It was one
# fixed path under `~/.cache` for every tree on the host, and the package's
# Makefile rebuilds its test binaries there only when they are older than its
# sources: a second worktree whose sources were older than the last build in
# the first ran the FIRST tree's binaries and failed its own gate on a format
# it did not have.  Every call into the package passes it as `WORK`, so the
# package's own default --- its path hashed, for a run outside this Makefile
# --- is never the one used here.  `tools/work_dir_check.py`, run by
# `build/work_dirs.pass`, holds both halves.
CHECKPOINT_WORK := $(abspath $(BUILD))/checkpoint-work

$(BUILD)/work_dirs.pass: tools/work_dir_check.py Makefile \
                         $(wildcard boards/arty-z7-20/linux/buildroot/package/*/src/Makefile) | $(BUILD)
	python3 tools/work_dir_check.py .
	@touch $@
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
#
# **AND AGAIN WHEN IT WENT 26 TO 27.**  muir's `Rtl` records whose time it
# keeps, `TimingModel`, as one byte after `speed_a`, so `chk_rtl.c` declares
# it too.  The file grew by that one byte, 561,515 to 561,516.  muir loads it
# and saves it back byte for byte, and resumes at the same microcycle.
#
# **AND WHEN THE GRID MOVED TO 10 NS.**  A tick is ten of muir's nanoseconds
# now, so the elapsed time doubled; the timing byte declares `TimingModel::
# Fpga`; and the memory boards' power-on instants are `with_timing_model(Fpga)`'s,
# 1,420, 960, 13,000 and 13,001 where the board's own are 1,416, 958, 12,991 and
# 12,992.  The file is still 561,516 bytes.  muir under `--timing-model fpga` loads it
# and saves it back byte for byte and resumes at the same microcycle; without
# the flag it refuses the file by name.
#
# **AND WHEN IT WENT 27 TO 33.**  muir's `Machine` now holds either of two
# machines, the CADR and QUUX, so its PDL buffer and level-2 map are the
# larger machine's, 16,384 and 2,048 words, and `Machine::save` writes the
# machine's `Geometry` after the level-1 map: the level-1 entry's bits, the
# PDL pointer's, and whether ALU functions 42 and 43 are QUUX's multiply and
# divide, and whether it has QUUX's tick.  `chk_rtl.c` writes the fabric's
# 1,024 words of each and zeros after them, and declares `Geometry::CADR`:
# five, ten, no and no.  The machine's tick follows, as `Tick::new` leaves
# it --- off, 16,667 us, no deadline --- and the display writes the size
# QUUX's MONO TV would have after its board's tag, 1,920 by 1,080, the
# default a CADR's display keeps.  `Rtl` keeps one more instant, when `IR`
# was loaded, which only QUUX's divider reads, and the file declares it zero
# as a fresh `Rtl` has it.  The zeros pack into runs, so the file grew by 30
# bytes, 561,516 to 561,546.  muir loads it and saves it back byte for byte,
# and resumes at the same microcycle.
#
# **AND WHEN IT WENT 33 TO 35.**  Version 34 gives the timing byte the
# microcycle length of QUUX's `sync` model, which `Fpga` does not carry, so
# the byte is unchanged.  Version 35 adds `Rtl::pulsed`, one flag after the
# instant `IR` was loaded, which the file declares false: it is set only
# inside a microcycle `-HANG` holds, and a halted machine is never in one.
# And MONO TV's default size, which a CADR's display keeps, is 1,280 by 1,024
# where it was 1,920 by 1,080.  The one byte added and the new size's packing
# leave the file one byte SHORTER, 561,546 to 561,545.  muir loads it and
# saves it back byte for byte, and resumes at the same microcycle.
#
# **AND WHEN IT WENT 35 TO 37.**  Version 36 adds QUUX's memory cache: the
# bus interface's cache and QUUX's memory timing, both options written
# absent, and the four fields beside them, and the machine's flag that the
# disk controller wrote memory, written false.  Version 37 adds QUUX's
# block-disk after the disk controller, an option written absent.  The
# twenty-five bytes added pack to one, 561,545 to 561,546, and muir loads the
# file, saves it back byte for byte and resumes at the same microcycle.
#
# **AND WHEN IT WENT 37 TO 39.**  Version 38 is QUUX's clocks: the tick's
# period goes, fixed at 60 Hz, and the interval timer's enable, period and
# deadline follow the tick's, all written as a CADR's machine holds them, off
# with no deadline.  Version 39 adds QUUX's keyboard and mouse after the I/O
# board, written empty.  The twenty-two bytes added pack to six, 561,546 to
# 561,552, and muir loads the file, saves it back byte for byte and resumes
# at the same microcycle.
CHECKPOINT_SHA  := 25c0abae27266187ba807ba615429390f43b4bba2a9c10699adcb36dde743c92
# What muir prints for the synthetic machine: 0x1234567890 microcycles and
# 0x9876543210 ticks of MIT's grid, ten nanoseconds each, the two the model
# sets.  The checkpoint declares muir's `fpga` timing model, so it is resumed
# under `--timing-model fpga` and muir refuses it under any other.
CHECKPOINT_RESUMED := at 78187493520 microcycles, 6548202583200 ns, 1 memory boards
# muir's binary, built into golden's own target directory because muir is
# already golden's path dependency there and the library half is compiled
# once for both.
MUIR_BIN := golden/target/release/muir
# **AND RUN WITH NO FILE OF FLAGS.**  muir reads `.muirrc` in the directory it
# runs from or in the home directory, and a home file that says `--machine
# quux` makes it refuse the CADR's checkpoint by its geometry.  `MUIR_RC`
# names the file in place of the two looked for, and one that is empty gives
# the run no flags but the ones written here, so the recipe exports it.

$(BUILD)/checkpoint.pass: $(CHECKPOINT_SRC)/cadr-checkpoint.c \
                          $(CHECKPOINT_SRC)/checkpoint_test.c \
                          $(CHECKPOINT_SRC)/chk.c $(CHECKPOINT_SRC)/chk.h \
                          $(CHECKPOINT_SRC)/chk_rtl.c $(CHECKPOINT_SRC)/chk_rtl.h \
                          $(CHECKPOINT_SRC)/pack_bind.c $(CHECKPOINT_SRC)/pack_bind.h \
                          $(CHECKPOINT_SRC)/sha256.c $(CHECKPOINT_SRC)/sha256.h \
                          $(READOUT_SRC)/readout.c $(READOUT_SRC)/readout.h \
                          $(READOUT_SRC)/cadr_image.h \
                          $(wildcard $(COMMON_SRC)/cadr/*.h) | $(BUILD)
	$(MAKE) -C $(CHECKPOINT_SRC) check WORK=$(CHECKPOINT_WORK) CHK=$(CHECKPOINT_WORK)/out.chk
	$(MAKE) -C $(CHECKPOINT_SRC) all WORK=$(CHECKPOINT_WORK) COMMON=host READOUT=host
	$(MAKE) -C $(CHECKPOINT_SRC) clean WORK=$(CHECKPOINT_WORK)
	$(MAKE) -C $(CHECKPOINT_SRC) mutants WORK=$(CHECKPOINT_WORK)
	$(CARGO) build --quiet --release --manifest-path $(MUIR)/muir/Cargo.toml \
	    --bin muir --target-dir golden/target
	@set -e; export MUIR_RC=/dev/null; W=$(CHECKPOINT_WORK); M=$(MUIR_BIN); \
	 $$M --rtl --timing-model fpga --stop-after 0 --resume $$W/out.chk --checkpoint $$W/back.chk \
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
	   if ! $$M --rtl --timing-model fpga --stop-after 0 --resume $$W/mut-$$m.chk \
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
# ozd's package: the band's file and time host, on the board itself.  It is the
# sixth init script the card's one file of flags reaches, and the only one of
# the six whose program is not ours.
OZD_PKG      := boards/arty-z7-20/linux/buildroot/package/ozd
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
                        $(wildcard $(COMMON_SRC)/cadr/*.h) \
                        $(CHAOSNET_SRC)/chaos_mutations.txt \
                        $(CHAOSNET_SRC)/chaos_test_boot.sh \
                        $(CHAOSNET_PKG)/S87cadr-chaosnet \
                        $(COMMON_SRC)/fpgarc.sh \
                        $(COMMON_SRC)/daemon.sh $(COMMON_SRC)/stop.sh \
                        $(COMMON_SRC)/fault.sh \
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
                      $(COMMON_SRC)/daemon.sh $(COMMON_SRC)/stop.sh \
                      $(COMMON_SRC)/clock.sh $(COMMON_SRC)/fault.sh \
                      $(COMMON_SRC)/fpgarc_test.sh \
                      $(CHAOSNET_PKG)/S87cadr-chaosnet \
                      $(OZD_PKG)/S84ozd \
                      $(TERMINAL_PKG)/S85cadr-terminal \
                      $(SERIAL_PKG)/S86cadr-serial \
                      $(USB_INPUT_PKG)/S88cadr-usb-input \
                      $(DISK_PACKS_PKG)/S80cadr-disk-packs \
                      boards/arty-z7-20/linux/mksd-buildroot.sh \
                      boards/arty-z7-20/linux/mksd-release.sh | $(BUILD)
	$(MAKE) -C $(COMMON_SRC) check
	@echo "fpgarc: one file of flags on the card reaches six programs, each gets the flags it"
	@echo "fpgarc: owns and no others, --no-auto-boot holds the machine before the drive,"
	@echo "fpgarc: --date and --time each set one field of a clock the board does not keep,"
	@echo "fpgarc: the board's own file and time host is on unless --no-ozd and its address"
	@echo "fpgarc: is never placed twice, with nothing inferred, the card mirrors the server,"
	@echo "fpgarc: the card's root holds what a loader demands and nothing else, the zip is"
	@echo "fpgarc: read back out of itself, and a card of the old two-partition shape still"
	@echo "fpgarc: mounts and is told it is old"
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
                         $(COMMON_SRC)/fpgarc.sh $(COMMON_SRC)/daemon.sh $(COMMON_SRC)/stop.sh \
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
# is as it is.  docs/boot.md, "The image", is the procedure.
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
# be linked into every program.  cadr-readout is the second library package
# and is hoisted for the same reason: cadr-checkpoint compiles against the
# headers it stages, and the derived list is alphabetical, so left in place it
# would be reconfigured after its consumer and the consumer would build
# against the headers of the previous build.
#
# `=` rather than `:=`, so the grep runs only when a buildroot target does.
BR_LOCAL_PKGS = $(sort $(notdir $(patsubst %/,%,$(dir $(shell \
    grep -l '_SITE_METHOD = local' $(BR_EXTERNAL)/package/*/*.mk)))))
BR_FORCE_PKGS = uboot linux cadr-common cadr-readout \
    $(filter-out cadr-common cadr-readout,$(BR_LOCAL_PKGS))

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

# ------------------------------------------------ the DE25-Nano's image
#
# The same Buildroot and the same packages, for aarch64, with Altera's TF-A,
# U-Boot and kernel, each pinned to a commit.  `boards/de25-nano/linux/
# buildroot/configs/de25_nano_defconfig` says what it is and why; like the
# Cora Z7-07S's it is built from both external trees and into an output
# directory of its own.
#
# **TWO CHECKS OF ITS OWN, BEFORE AND AFTER.**  Before: the three pinned
# sources each have a hash file naming the pinned commit, because Buildroot
# lets a download with no hash file through with a warning, even with
# BR2_DOWNLOAD_FORCE_CHECK_HASHES set (support/download/check-hash).  After:
# every line of the defconfig and of this board's kernel and U-Boot fragments
# holds in the .config each was built with, because Kconfig drops a line it
# cannot satisfy without a word, and the programs in the image say this
# board's addresses.  Then the image against its target tree, as on every
# board.
#
# **AND A REBUILD TARGET FROM THE START**, for the Cora Z7-07S's reason: the
# other boards' rebuild targets act on their own output directories.  It forces
# the same one list, filtered by this board's .config.
BR_EXTERNAL_DE25 := $(BR_EXTERNAL):$(abspath boards/de25-nano/linux/buildroot)
BR_OUT_DE25 := $(BR_WORK)/out-de25
BR_DE25_CHECK := boards/de25-nano/linux/buildroot_check.py

.PHONY: buildroot-de25 buildroot-de25-check buildroot-de25-rebuild

# **AND WHAT OF IT `make check` CAN HOLD WITH NO BUILDROOT AT ALL.**  The pins,
# the boot's own arrangement of the fabric's image, and every program compiled
# on the build host with the DE25-Nano's address map, warnings as errors, and
# asked for that board's addresses and ports in its own words.  The boot check
# holds the fabric's image to being fetched only on the path that loads it into
# the fabric, so that a card with an empty fabric slot cannot stop a board that
# was configured before U-Boot ran; `buildroot_check.py` says what it holds and
# what it cannot.  Every other check here compiles the Zynq boards' map, which
# is what their models were written against, so this is the only place the
# other half of `cadr/cadr_board.h` is compiled before a board build --- a map
# that does not compile, or a program that still says a Zynq board's address,
# fails the gate and not the board.  The packages are compiled in a copy, so
# that this never shares a source directory with the checks that build there.
DE25_LINUX_PROGRAMS := cadr-console cadr-readout cadr-checkpoint cadr-disk-packs \
                       cadr-serial cadr-chaosnet cadr-terminal cadr-usb-input
DE25_LINUX_WORK := $(HOME)/.cache/muir-fpga-de25-linux-$(shell printf '%s' '$(CURDIR)' | sha256sum | cut -c1-12)
$(BUILD)/de25_linux.pass: $(BR_DE25_CHECK) \
                          boards/de25-nano/linux/buildroot/configs/de25_nano_defconfig \
                          boards/de25-nano/linux/buildroot/board/de25-nano/uboot/cadr_de25.env \
                          boards/de25-nano/linux/buildroot/board/de25-nano/uEnv.net \
                          $(wildcard boards/de25-nano/linux/buildroot/board/de25-nano/patches/*/*/*.hash) \
                          $(wildcard $(BR_EXTERNAL)/package/*/src/*.c) \
                          $(wildcard $(BR_EXTERNAL)/package/*/src/*.h) \
                          $(wildcard $(BR_EXTERNAL)/package/*/src/Makefile) \
                          $(wildcard $(BR_EXTERNAL)/package/*/src/cadr/*.h) | $(BUILD)
	@python3 $(BR_DE25_CHECK) pins boards/de25-nano/linux/buildroot
	@python3 $(BR_DE25_CHECK) boot boards/de25-nano/linux/buildroot
	@rm -rf $(DE25_LINUX_WORK) && mkdir -p $(DE25_LINUX_WORK)/bin
	@cp -a $(BR_EXTERNAL)/package $(DE25_LINUX_WORK)/package
	@set -e; for p in $(DE25_LINUX_PROGRAMS); do \
	    MAKEFLAGS= $(BR_MAKE) -s -C $(DE25_LINUX_WORK)/package/$$p/src all COMMON=host READOUT=host \
	        CFLAGS="-O2 -Wall -Wextra -Werror -std=gnu11 -DCADR_BOARD_DE25_NANO"; \
	    cp $(DE25_LINUX_WORK)/package/$$p/src/$$p $(DE25_LINUX_WORK)/bin/; \
	done
	@python3 $(BR_DE25_CHECK) programs boards/de25-nano/linux/buildroot $(DE25_LINUX_WORK)/bin
	@rm -rf $(DE25_LINUX_WORK)
	@touch $@

buildroot-de25-check: buildroot-packages-check
	@python3 $(BR_DE25_CHECK) pins boards/de25-nano/linux/buildroot
	@python3 $(BR_DE25_CHECK) boot boards/de25-nano/linux/buildroot

buildroot-de25: buildroot-de25-check
	@test -f $(BR_TARBALL) || { \
	    echo "no Buildroot at $(BR_TARBALL); fetch it with"; \
	    echo "  curl -o $(BR_TARBALL) $(BR_URL)"; exit 1; }
	@echo "$(BR_SHA)  $(BR_TARBALL)" | sha256sum -c --quiet - \
	    || { echo "$(BR_TARBALL) is not the Buildroot this image was built with"; exit 1; }
	@mkdir -p $(BR_WORK)/bin vendor/buildroot-dl
	@for f in /usr/bin/gnu*; do [ -x "$$f" ] && ln -sf "$$f" "$(BR_WORK)/bin/$${f#/usr/bin/gnu}"; done; true
	@test -d $(BR_SRC) || tar xJf $(BR_TARBALL) -C $(BR_WORK)
	PATH=$(BR_WORK)/bin:$$PATH MAKEFLAGS= $(BR_MAKE) -C $(BR_SRC) O=$(BR_OUT_DE25) BR2_EXTERNAL=$(BR_EXTERNAL_DE25) de25_nano_defconfig
	PATH=$(BR_WORK)/bin:$$PATH MAKEFLAGS= $(BR_MAKE) -C $(BR_SRC) O=$(BR_OUT_DE25)
	@python3 $(BR_DE25_CHECK) configs boards/de25-nano/linux/buildroot $(BR_OUT_DE25)
	@python3 $(BR_ROOTFS_CHECK) $(BR_EXTERNAL_DE25) $(BR_OUT_DE25) $(BR_OUT_DE25)/images/rootfs.cpio.uboot
	@echo "buildroot-de25: images in $(BR_OUT_DE25)/images:"
	@ls -l $(BR_OUT_DE25)/images/ | grep -v '^total'

buildroot-de25-rebuild: buildroot-de25-check
	PATH=$(BR_WORK)/bin:$$PATH MAKEFLAGS= $(BR_MAKE) -C $(BR_SRC) O=$(BR_OUT_DE25) BR2_EXTERNAL=$(BR_EXTERNAL_DE25) de25_nano_defconfig
	$(call BR_FORCE,$(BR_OUT_DE25))
	PATH=$(BR_WORK)/bin:$$PATH MAKEFLAGS= $(BR_MAKE) -C $(BR_SRC) O=$(BR_OUT_DE25)
	@python3 $(BR_DE25_CHECK) configs boards/de25-nano/linux/buildroot $(BR_OUT_DE25)
	@python3 $(BR_ROOTFS_CHECK) $(BR_EXTERNAL_DE25) $(BR_OUT_DE25) $(BR_OUT_DE25)/images/rootfs.cpio.uboot
	@echo "buildroot-de25: images in $(BR_OUT_DE25)/images:"
	@ls -l $(BR_OUT_DE25)/images/ | grep -v '^total'

# ------------------------------------------------------------ the release
#
# **A RELEASE IS THREE ZIPS, ONE A BOARD, AND THIS IS THE ONE COMMAND THAT
# MAKES THEM.**  There is no card image any more: a user formats a microSD
# card themselves, as one FAT32 partition in an MBR, and unpacks their board's
# zip onto it.  Each zip is self-sufficient, names its board in its own file
# name and inside it, and is what is published for that board.
#
#     make release BIT_ARTY=<a .bit> BIT_CORA=<a .bit> BIT_DE25=<a .rbf> \
#                  FAULT_ARTY=<a .bit> FAULT_CORA=<a .bit> FAULT_DE25=<a .rbf>
#
# **AND EACH ZIP CARRIES ITS BOARD'S FAULT BITSTREAM**, the one the loader
# takes when the CADR's will not load (`docs/board.md`), named the same way.
#
# **THREE ZIPS ARE THREE CHANCES FOR ONE TO BE STALE**, which is why this is
# one target and not three: a release in which two boards were rebuilt and the
# third was not is exactly the sort of thing that ships.  So every bitstream is
# required by name, the target refuses to build a partial release, and it
# prints the three zips together at the end with their digests, where a missing
# one is visible.
#
# The bitstreams are not in this repository --- they are built by Vivado and by
# Quartus, which `make check` does not run --- so they are named on the command
# line.  Each board's Buildroot output must exist: `make buildroot`,
# `make buildroot-cora` and `make buildroot-de25` build them.
.PHONY: release
RELEASE_DIR := build/sd/release
release:
	@for v in BIT_ARTY BIT_CORA BIT_DE25 FAULT_ARTY FAULT_CORA FAULT_DE25; do \
	    eval "b=\$$$$v"; \
	    [ -n "$$b" ] || { \
	        echo "release: $$v is not set.  A release is three zips and this target makes"; \
	        echo "release: all three, so that one board cannot be left at an older build:"; \
	        echo "release:   make release BIT_ARTY=<a .bit> BIT_CORA=<a .bit> BIT_DE25=<a .rbf>"; \
	        echo "release:                FAULT_ARTY=<a .bit> FAULT_CORA=<a .bit> FAULT_DE25=<a .rbf>"; \
	        exit 1; }; \
	    [ -f "$$b" ] || { echo "release: $$v=$$b is not a file"; exit 1; }; \
	done
	BIT=$(BIT_ARTY) FAULT_BIT=$(FAULT_ARTY) \
	    boards/arty-z7-20/linux/mksd-release.sh
	IMAGES=$(BR_OUT_CORA)/images \
	    BOARD_DIR=boards/cora-z7-07s BOARD_DTB=zynq-cora-z7-07s.dtb \
	    BIT=$(BIT_CORA) FAULT_BIT=$(FAULT_CORA) boards/arty-z7-20/linux/mksd-release.sh
	IMAGES=$(BR_OUT_DE25)/images \
	    BOARD_DIR=boards/de25-nano BOARD_DTB=socfpga_agilex5_de25_nano_cadr.dtb \
	    BIT=$(BIT_DE25) FAULT_BIT=$(FAULT_DE25) boards/arty-z7-20/linux/mksd-release.sh
	@echo
	@echo "release: three zips, one a board:"
	@for b in arty-z7-20 cora-z7-07s de25-nano; do \
	    z=$(RELEASE_DIR)/$$b/cadr-$$b.zip; \
	    [ -f "$$z" ] || { echo "release: $$z was not built"; exit 1; }; \
	    printf '  %-44s %10d  %s\n' "$$z" "$$(stat -c %s $$z)" "$$(sha256sum $$z | cut -c1-16)"; \
	done
	@echo "release: each is unpacked onto a microSD card formatted as ONE FAT32"
	@echo "release: partition in an MBR.  docs/boot.md says how."

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
$(BUILD)/obj_md_compose/Vcadr_machine: $(MACHINE_SRC) tb/cadr_md_compose_tb.cpp tb/cadr_tick.h | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 --public-flat-rw -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_md_compose \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE_SRC) $(abspath tb/cadr_md_compose_tb.cpp)

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
$(BUILD)/obj_park/Vcadr_machine: $(MACHINE_SRC) tb/cadr_park_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) +define+CADR_GAP_MONITOR -O2 -CFLAGS -O2 --public-flat-rw -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_park \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GSYNC_PROM_HEX='"$(abspath $(BUILD))/sync_prom.hex"' \
	    --top-module cadr_machine $(MACHINE_SRC) $(abspath tb/cadr_park_tb.cpp)

$(BUILD)/park.pass: $(BUILD)/obj_park/Vcadr_machine $(BUILD)/boot_prom.hex $(BUILD)/sync_prom.hex
	$(BUILD)/obj_park/Vcadr_machine
	@touch $@
