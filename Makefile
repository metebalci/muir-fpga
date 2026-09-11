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

.PHONY: check cables ps7 ps7-init current mutants mutants-selftest probe-selftest \
        disk-golden disk-boot-golden iob-golden muir-pin clean

check: $(BUILD)/phase_gen.pass $(BUILD)/cables.pass $(BUILD)/busint_xbus.pass \
       $(BUILD)/xbus_decode.pass $(BUILD)/ddr_map.pass \
       $(BUILD)/memory_path.pass $(BUILD)/axi_master.pass \
       $(BUILD)/axi_widen.pass $(BUILD)/prove.pass \
       $(BUILD)/microcycle.pass $(BUILD)/microcycle_sys.pass \
       $(BUILD)/md_hold.pass $(BUILD)/md_hold_sys.pass \
       $(BUILD)/machine.pass $(BUILD)/ddr_boot.pass \
       $(BUILD)/map_boot.pass \
       $(BUILD)/mem_count.pass \
       $(BUILD)/arty.pass $(BUILD)/probe.pass \
       $(BUILD)/probe_jtag.pass $(BUILD)/disk.pass $(BUILD)/disk_pack.pass \
       $(BUILD)/disk_boot.pass \
       $(BUILD)/gp0_default.pass $(BUILD)/tv.pass \
       $(BUILD)/console.pass $(BUILD)/readout.pass \
       $(BUILD)/readout_face.pass $(BUILD)/checkpoint.pass \
       $(BUILD)/iob.pass $(BUILD)/unibus.pass \
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

# The reference trace, out of muir's own clock::Behavioural. It carries the
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
# else, the beat's neighbour is untouched, a wrong word does not read as a
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
MEMPATH := rtl/plumbing/cadr_ddr_map.sv rtl/machine/cadr_xbus_decode.sv rtl/machine/cadr_busint_xbus.sv \
           rtl/plumbing/cadr_xbus_ddr.sv rtl/machine/cadr_tv.sv rtl/machine/cadr_console_bus.sv \
           rtl/machine/cadr_io_board.sv rtl/machine/cadr_memory_path.sv

$(BUILD)/obj_memory_path/Vcadr_memory_path: $(MEMPATH) tb/cadr_memory_path_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_memory_path \
	    --top-module cadr_memory_path $(MEMPATH) $(abspath tb/cadr_memory_path_tb.cpp)

$(BUILD)/memory_path.pass: $(BUILD)/obj_memory_path/Vcadr_memory_path $(BUILD)/busint_xbus.golden
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
# sources as `memory_path`, another trace and another testbench; the modelled
# DDR answers at once so that the timing is comparable with muir, whose TV
# takes no time of its own.
#
# The trace is 77 million ticks --- twenty-five frames, because a write
# landing on the very tick a frame begins first becomes reachable at the
# twenty-fifth --- and takes a minute or so.
$(BUILD)/tv.golden: golden/src/tv.rs golden/Cargo.toml | $(BUILD)
	$(GOLDEN) --release --bin tv > $@

$(BUILD)/obj_tv/Vcadr_memory_path: $(MEMPATH) tb/cadr_tv_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_tv \
	    --top-module cadr_memory_path $(MEMPATH) $(abspath tb/cadr_tv_tb.cpp)

$(BUILD)/tv.pass: $(BUILD)/obj_tv/Vcadr_memory_path $(BUILD)/tv.golden
	$(BUILD)/obj_tv/Vcadr_memory_path $(BUILD)/tv.golden
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
# word and the acknowledgement come apart --- had never carried a word anybody
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
	    --top-module cadr_memory_path $(MEMPATH) $(abspath tb/cadr_unibus_tb.cpp)

$(BUILD)/unibus.pass: $(BUILD)/obj_unibus/Vcadr_memory_path $(BUILD)/iob.golden
	$(BUILD)/obj_unibus/Vcadr_memory_path $(BUILD)/iob.golden
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
#
# `rtl/machine/cadr_disk_controller.sv` is in the list because it is instantiated
# inside `cadr_machine`, which is where the boot PROM's 16,951 device cycles
# now land: they used to be answered from the trace by the testbench, and that
# line is gone. It joins `nomem`, `ddr_boot`, `mem_count`, `arty` and `probe`
# through this variable, all of which build the whole machine.
MACHINE := rtl/machine/cadr_phase_gen.sv rtl/machine/cadr_microcycle.sv rtl/plumbing/cadr_ddr_map.sv \
           rtl/machine/cadr_xbus_decode.sv rtl/machine/cadr_busint_xbus.sv rtl/plumbing/cadr_xbus_ddr.sv \
           rtl/machine/cadr_spy_registers.sv rtl/machine/cadr_disk_controller.sv rtl/machine/cadr_tv.sv \
           rtl/machine/cadr_io_board.sv \
           rtl/machine/cadr_console_bus.sv rtl/machine/cadr_console_state.sv \
           rtl/machine/cadr_memory_path.sv rtl/machine/cadr_machine.sv

$(BUILD)/obj_machine/Vcadr_machine: $(MACHINE) tb/cadr_machine_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_machine \
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
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_ddr_boot \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    --top-module cadr_machine $(MACHINE) $(abspath tb/cadr_ddr_boot_tb.cpp)

$(BUILD)/ddr_boot.pass: $(BUILD)/obj_ddr_boot/Vcadr_machine $(BUILD)/boot_prom.hex
	$(BUILD)/obj_ddr_boot/Vcadr_machine
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
	    --top-module cadr_machine $(MACHINE) $(abspath tb/cadr_map_boot_tb.cpp)

$(BUILD)/map_boot.pass: $(BUILD)/obj_map_boot/Vcadr_machine \
                        $(BUILD)/rtl.golden $(BUILD)/boot_prom.hex
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
# which is the booby trap CLAUDE.md records, a record naming a check the runner
# has no entry for killing the whole run at parse.  Promoting this is those two
# changes together, and `docs/band.md` writes both of them out.
#
# It skips, and says so, when the System 100 release is not here, as its
# neighbours do; the sum is checked before the archive is used and the pack is
# decompressed fresh for the run and removed after.  Twenty-five seconds.
$(BUILD)/obj_band/Vcadr_machine: $(MACHINE) tb/cadr_band_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_band \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    --top-module cadr_machine $(MACHINE) $(abspath tb/cadr_band_tb.cpp)

.PHONY: band
band: $(BUILD)/obj_band/Vcadr_machine $(BUILD)/rtl_sys.golden $(BUILD)/boot_prom.hex
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
	    --top-module cadr_mem_count_harness $(MEM_COUNT_SRC) \
	    $(abspath tb/cadr_mem_count_tb.cpp)

$(BUILD)/mem_count.pass: $(BUILD)/obj_mem_count/Vcadr_mem_count_harness \
                         $(BUILD)/boot_prom.hex
	$(BUILD)/obj_mem_count/Vcadr_mem_count_harness
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
nomem: $(BUILD)/obj_nomem/Vcadr_machine $(BUILD)/boot_prom.hex
	$(BUILD)/obj_nomem/Vcadr_machine

$(BUILD)/obj_nomem/Vcadr_machine: $(MACHINE) tb/cadr_nomem_tb.cpp | $(BUILD)
	$(VERILATOR) $(VFLAGS) -O2 -CFLAGS -O2 -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 -Mdir $(BUILD)/obj_nomem \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
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
                    tb/cadr_arty_stubs.sv tb/cadr_ps7_stub.sv | $(BUILD)
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    --top-module cadr_arty tb/cadr_arty_stubs.sv $(MACHINE) boards/arty-z7-20/cadr_arty.sv
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GPROBE_DEPTH=1024 \
	    --top-module cadr_arty tb/cadr_arty_stubs.sv $(MACHINE) \
	    boards/arty-z7-20/cadr_arty.sv rtl/plumbing/xilinx7/cadr_probe.sv
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GDDR=1 \
	    --top-module cadr_arty tb/cadr_arty_stubs.sv tb/cadr_ps7_stub.sv \
	    $(MACHINE) boards/arty-z7-20/cadr_arty.sv boards/arty-z7-20/cadr_ps7.sv rtl/plumbing/cadr_axi_master.sv \
	    rtl/plumbing/cadr_axi_widen.sv rtl/plumbing/cadr_mem_count.sv rtl/plumbing/cadr_disk_pack.sv \
	    rtl/plumbing/cadr_console.sv
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GPROVE=1 \
	    --top-module cadr_arty tb/cadr_arty_stubs.sv tb/cadr_ps7_stub.sv \
	    $(MACHINE) boards/arty-z7-20/cadr_arty.sv boards/arty-z7-20/cadr_ps7.sv rtl/plumbing/cadr_axi_master.sv \
	    rtl/plumbing/cadr_axi_widen.sv rtl/plumbing/cadr_mem_count.sv rtl/plumbing/cadr_prove.sv \
	    rtl/plumbing/cadr_gp0_default.sv rtl/plumbing/cadr_console.sv
	$(VERILATOR) --lint-only -Wall -Irtl/machine -Irtl/plumbing -Irtl/plumbing/xilinx7 -Iboards/arty-z7-20 \
	    -GPROM_HEX='"$(abspath $(BUILD))/boot_prom.hex"' \
	    -GPROVE=2 \
	    --top-module cadr_arty tb/cadr_arty_stubs.sv tb/cadr_ps7_stub.sv \
	    $(MACHINE) boards/arty-z7-20/cadr_arty.sv boards/arty-z7-20/cadr_ps7.sv rtl/plumbing/cadr_axi_master.sv \
	    rtl/plumbing/cadr_axi_widen.sv rtl/plumbing/cadr_mem_count.sv rtl/plumbing/cadr_prove.sv \
	    rtl/plumbing/cadr_gp0_default.sv rtl/plumbing/cadr_console.sv
	@touch $@

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
	    --top-module cadr_probe_harness $(PROBE_SRC) \
	    $(abspath tb/cadr_probe_tb.cpp)

$(BUILD)/probe.pass: $(BUILD)/obj_probe/Vcadr_probe_harness \
                       $(BUILD)/rtl.golden $(BUILD)/boot_prom.hex
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
         $(BUILD)/disk.golden $(BUILD)/disk_boot.golden $(BUILD)/tv.golden \
         $(BUILD)/iob.golden \
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
                  $(BUILD)/disk.golden $(BUILD)/disk_boot.golden \
                  $(BUILD)/tv.golden \
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
                              $(BUILD)/rtl_sys.golden $(BUILD)/boot_prom.hex
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
                       $(BUILD)/rtl.golden $(BUILD)/boot_prom.hex
	$(BUILD)/obj_md_hold/Vcadr_microcycle $(BUILD)/rtl.golden
	@touch $@

$(BUILD)/md_hold_sys.pass: $(BUILD)/obj_md_hold/Vcadr_microcycle \
                           $(BUILD)/rtl_sys.golden $(BUILD)/boot_prom.hex
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
                         $(BUILD)/rtl.golden $(BUILD)/boot_prom.hex
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
# puts in a modelled DDR at the addresses the trace names, asked to by register
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
# block put in the modelled DDR and fetched is READ BACK BY THE CADR, through
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

$(BUILD)/readout_face.pass: $(READOUT_SRC)/readout.c $(READOUT_SRC)/readout.h \
                            $(READOUT_SRC)/cadr_image.h \
                            $(READOUT_SRC)/readout_test.c \
                            $(READOUT_SRC)/cadr-readout.c | $(BUILD)
	$(MAKE) -C $(READOUT_SRC) check
	$(MAKE) -C $(READOUT_SRC) all COMMON=host
	$(MAKE) -C $(READOUT_SRC) clean
	@echo "readout: the program builds and its core agrees with a modelled window"
	@touch $@

# ------------------------------------------- the checkpoint, and muir itself

# `cadr-checkpoint` writes the board's machine as a muir checkpoint, and this
# is the only check in the repository whose judge is muir's own reader.
#
# **THE PROOF IS THE ROUND TRIP AND IT HAS THREE LEGS, BECAUSE ONE IS NOT
# ENOUGH.**  Measured, not assumed --- three mutants of `chk_rtl.c` were built
# and run against each leg, and no leg catches all three:
#
#   1. muir LOADS the file and SAVES IT BACK BYTE FOR BYTE.  This is muir's
#      own round-trip property (`tests/checkpoint.rs`, "the checkpoint loads
#      and saves as itself") and it holds the framing: every field at the
#      offset muir's reader expects, every array's count, every flag a 0 or a
#      1, every range check passed, and the packing muir's own rather than
#      merely a legal one.  It catches the mutant that drops a byte.
#   2. muir's own REPORT of what it resumed names the microcycle count and
#      the nanoseconds the synthetic machine was given.  Two fields the
#      window really does read, asserted in muir's words rather than through
#      an exit code --- `vivado/probe.tcl`'s lesson, one program along.
#   3. the file's SHA-256 against the value recorded here.  **This is the leg
#      that catches a field carrying a WRONG VALUE in a RIGHT-SHAPED SLOT**,
#      which the round trip cannot see by construction: muir re-saves whatever
#      it read, so any valid value survives it.  Two of the three mutants ---
#      the mouse's quadrature phases written 0 where a fresh mouse has 2, and
#      `Machine::opc` taken from the OPC shift register instead of LPC ---
#      load, re-save identically, and are caught here and nowhere else.
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
CHECKPOINT_SHA  := 9bc79063064d6f2336d69b384b7e73a8e76631998f167e108779678f3bb1b6db
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
	 for m in 1 2 3; do \
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
BR_GEN_PS7  := boards/arty-z7-20/linux/buildroot/board/arty-z7-20/uboot/gen_ps7_init_gpl.py
# Not written as $(MAKE) in the recipe: GNU make runs any recipe line that
# names $(MAKE) even under -n, so `make -n buildroot` would start the build.
# The inner make gets a clean MAKEFLAGS anyway (see above), so nothing the
# sub-make convention would have carried is lost.
BR_MAKE     := $(MAKE)

.PHONY: buildroot buildroot-check buildroot-rebuild

# The generated start-up routine has to be what boards/arty-z7-20/vivado/ps7_init.ops gives
# today, or U-Boot would be built from a stale claim.  Pure Python, no
# Vivado, so it runs anywhere the repository does.
buildroot-check:
	@python3 $(BR_GEN_PS7) --check

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
	@echo "buildroot: images in $(BR_OUT)/images:"
	@ls -l $(BR_OUT)/images/ | grep -v '^total'

# Buildroot does not watch our files: a change under boards/arty-z7-20/linux/buildroot/ to
# U-Boot's environment, its fragment, the kernel config, the tree or the
# sources of our own programs is not seen by a plain `make buildroot` once the
# package has a build stamp.  This forces every package that reads them to
# reconfigure and rebuild, then finishes the image as `buildroot` does.
# cadr-common is named before its consumers: they link the library it puts in
# the staging tree, so a stale one would be linked into both programs.
buildroot-rebuild: buildroot-check
	PATH=$(BR_WORK)/bin:$$PATH MAKEFLAGS= $(BR_MAKE) -C $(BR_SRC) O=$(BR_OUT) BR2_EXTERNAL=$(BR_EXTERNAL) arty_z7_20_defconfig
	PATH=$(BR_WORK)/bin:$$PATH MAKEFLAGS= $(BR_MAKE) -C $(BR_SRC) O=$(BR_OUT) \
	    uboot-reconfigure linux-reconfigure cadr-common-reconfigure \
	    cadr-console-reconfigure cadr-readout-reconfigure \
	    cadr-disk-packs-reconfigure cadr-terminal-reconfigure
	PATH=$(BR_WORK)/bin:$$PATH MAKEFLAGS= $(BR_MAKE) -C $(BR_SRC) O=$(BR_OUT)
	@echo "buildroot: images in $(BR_OUT)/images:"
	@ls -l $(BR_OUT)/images/ | grep -v '^total'
