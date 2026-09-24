# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Timing constraints for the composed machine.
#
# The master clock exists only to resolve the delay-line taps, which this
# design holds as tick COUNTS of MIT's instants on the fabric's grid --- at the
# 10 ns grid 8, 9, 10, 12, 13, 14 and 16 of them, where the 5 ns grid gave 15,
# 17, 20, 23, 25, 28 and 32.  Netlist logic settles *between* phases, where
# the fast read tap at eight ticks is the real constraint.  (The board clocks
# a tick at 10 ns, so that tap is 80 ns of real time;
# `boards/arty-z7-20/cadr_arty.sv` decides the length of a tick and is the
# only thing that does.  Every exception in this file is written in CYCLES,
# rescales with the tick by itself, and is the grid's count of the instant its
# `# grid:` tag names, which `tools/grid_check.py` holds.)
#
# **EVERY NANOSECOND FIGURE BELOW IS DATED BY THE TICK IT WAS MEASURED AT,
# AND NONE OF THEM HAS BEEN REWRITTEN**: a measurement is worth its provenance
# and not worth being multiplied in a text editor.  A tick was 5 ns until
# 2026-09-11, then 6.25 ns for part of that day, and is 10 ns now.  So where a
# report excerpt below says a path "asks for 5.000 ns" it is one tick and asks
# for 10.000 today, where it says "75.000" it is fifteen ticks and asks for
# 150.000, and the one excerpt quoting 6.250 and 93.750 was taken at the
# 6.25 ns tick and is the same two requirements.  Since the grid moved to
# 10 ns the relaxed set is eight ticks and asks for 80.000.  The RATIOS --- which path is
# relaxed and which is not, and by how much a slack figure moved when
# something changed --- are what those excerpts were quoted for, and they are
# unaffected.  The
# current figures are in `boards/arty-z7-20/vivado/bitstream.tcl`'s header. Hold all 1,821 registers to the tick and the routed report says
# WNS -17.265 ns on the map lookup rippling into the control store's address,
# 21.615 ns over 26 logic levels --- a path that has a phase to happen in.
# (That register count is of the design as it then was. At 712909e the machine
# is 769 registers placed and routed out of context, and the experiment has
# not been repeated at that size.)
# That is the pessimistic version, which is not to be spread, and it distorts
# placement as well as the report: the placer spends itself on 6,637 impossible
# paths.
#
# **But relaxing everything outside the generator is wrong**, and an earlier
# version of this file did exactly that and reported all timing met. It is
# not the module that decides; it is whether a register's input is stable
# across the microcycle and its consumer reads it only at the end.
#
#   - The scratchpad latches qualify. `amem[aadr]` is constant for the whole
#     microcycle because `aadr` comes off IR, so the latch captures the same
#     value every tick and only the last is read. `imem_q` and `prom_q` too.
#   - A free-running counter does not: it is its own input, and the relaxed
#     set's multicycle says its increment may take eight ticks, at which point
#     it does not count. `mfinish_t`, `rdfinish_t`, `elapsed`, `vco_count`, `arb_t`,
#     `phase_t`.
#   - An edge detector does not: it exists to spot a transition and is read
#     the next tick. `n_memack_q`, `n_loadmd_q`, `n_tpwpiram_q`, `n_tpwp_q`,
#     `tpclk_q`. Note these are named, not matched on `_q`, because the
#     scratchpad latches share that suffix and must not be caught.
#   - Nor does a tick's event held for the next: `md_we_q`, MD's move at the
#     end of the tick before, and `mw_early_q`, `mw_early_q2` and
#     `mw_late_q`, which place the maps' and the dispatch memory's write in a
#     hung microcycle (`cadr_microcycle.sv`'s `mw`) and are those memories'
#     write enables a tick on.
#   - Nor does an acknowledgment. `deskewed`, `ub_acked` and `ub_loadmd` are
#     the bus interface's three taps --- the 60 ns tap of the TD100 at REQLM
#     0C09, and the Unibus's 150 and 100 ns instants --- written as registers
#     rather than as comparisons against `elapsed`; the long notes in
#     `rtl/machine/cadr_busint_xbus.sv` say why. They are what -MEMACK and -LOADMD are
#     made of, so they are read every tick and are named here for that reason.
#     They are the only registers in the design that had to be named rather
#     than falling into `slow` on their own, and the reason is worth keeping:
#     a comparison moved into a register is invisible to this file's own test,
#     which asks what a register's consumers do and not what it replaced.
#
# **A REGISTER IN `slow` THAT LOADS EVERY TICK HOLDS GARBAGE FOR THE FIRST
# TICKS AFTER ITS INPUT MOVES, AND A READER THAT DECIDES ON ANY OF THOSE TICKS
# IS WRONG ON SILICON AND RIGHT IN EVERY TRACE.**  `memgo_q` is `MEMSTART AND
# VMAOK`, loaded every tick, with the map between the boundary and its `D`:
# 18.7 to 19.2 ns routed at 9d1cf26, legal under this file's eight ticks.
# `cadr_busint_xbus.sv`'s IDLE state read it every tick and, until the fix
# beside it, granted a bus cycle on one tick of it --- which three placements
# of the board met as a halt in the page-fault code and zero-delay simulation
# never can.  The relaxation is honest only because every reader now decides
# at the master clock edge, a microcycle after the boundary.  So a register
# like it is the same question as an edge detector, asked from the reader's
# side: what does the first reader do with the first tick.
#
# Paths *into* the generator are already tick-rate and must stay so: they are
# slow-to-fast, which `-from $slow -to $slow` does not match. `speed`
# especially --- the synchronizer updates it at phase 12 and the 74S151 samples
# it at phase 13, one tick.

# NO `create_clock` HERE, and that is the point of the file.  This is timing
# *exception* policy --- what may take a microcycle and what may not --- and
# it is read by both the out-of-context fit and the board flow, which do not
# agree about what the clock is.  Out of context `clk` is a port and
# `boards/arty-z7-20/vivado/fit.tcl` declares it; on the board it is an MMCM output and
# `boards/arty-z7-20/cadr_arty.xdc` constrains the 125 MHz pin it is derived from.  A
# `create_clock` on `[get_ports clk]` here is a critical warning in one of
# those two flows, and a critical warning that means nothing is how a
# constraint that means nothing goes unnoticed.

# One `filter` call, because an XDC is a restricted Tcl subset: `foreach` and
# `concat` are rejected with a critical warning and the constraint then applies
# to nothing at all. An earlier version of this file built the set with a loop,
# which works when sourced as plain Tcl and silently does nothing when read as
# an XDC --- the report then shows the unconstrained design and looks like a
# real result.
#
# The five edge detectors are named individually rather than matched on `_q`,
# because the scratchpad latches share that suffix --- `amem_q`, `mmem_q`,
# `pdl_q`, `spc_q` --- and they are exactly the registers that should be
# relaxed.
#
# **THE DISK CONTROLLER IS OUT OF THE SET, WHOLE, BUT FOR ITS TWO HELD
# DECODES.**  `all_registers` under `cadr_machine` took every register of
# `rtl/machine/cadr_disk_controller.sv` the day that module landed, and by this
# file's own test nearly none of them qualifies: the spindle adds five
# nanoseconds a tick, the busy counter and the eight attention countdowns
# subtract five a tick, `elapsed` counts the walk, and the channel moves a
# word a tick through a state machine whose every register is its own input.
# The one register the name list happened to catch was `elapsed` --- the bus
# interface's pattern matched the disk's too --- and everything else was
# relaxed to seventy-five nanoseconds.  Asked of the routed DDR=1 board at
# ef9dee9: 3,904 of the disk's 4,000 internal paths carried the exception,
# and the longest of them was 20.1 ns, seventeen logic levels from
# `ch_state_reg[1]` back into `ch_state_reg[2]`.  Every timing figure that
# board reported with the drive in it was of a design a quarter of which was
# not being timed.  This is the too-wide exemption that looks exactly like one
# that is right, found by asking the checkpoint what requirement the paths
# carried rather than reading the summary.
#
# The two that stay are `mine` and `which`: the slave's address match and
# register number, taken once from the far end of the map and constant for
# the microcycle --- `cadr_memory_path.sv`'s held decode one slave along, and
# the same argument.  Paths INTO them from the map need the microcycle and
# get it; paths OUT of them are timed at the tick wherever they land on a
# register that is not in this set, which is every register in the disk.
#
# **THE DISPLAY IS OUT OF THE SET THE SAME WAY, BUT FOR ITS THREE HELD
# DECODES**, `ctl`, `fb` and `which` in `rtl/machine/cadr_tv.sv`, held from `phys`
# for the disk's reason.  Nothing else there qualifies: the frame counter
# adds one a tick and presets the flag as it wraps, `taken` is the cycle's
# latch, and the mode register's clock enable is -XBUS.RQ through the held
# match --- read at the tick, so its D from the cpu's word is timed at the
# tick too, as the disk's registers are.
#
# **AND THE I/O BOARD IS OUT OF THE SET THE SAME WAY, BUT FOR ITS SEVEN HELD
# DECODES**, `sel`, `kbm`, `clkgrp`, `chgrp`, `sergrp`, `wr` and `which` in
# `rtl/machine/cadr_io_board.sv`.  It was five until the Chaosnet interface
# and the serial port landed; `chgrp` and `sergrp` are the same register as
# the other three, one group of the 74LS138 at IOBADR 0E20 each, and they gate
# the same answer machine at the same instant.  The card landed under `cadr_machine` with
# the composition of 2026-09-11 and `all_registers` would have taken every one
# of its registers, which is the trap this file records one module up: a
# relaxed set defined as every register minus a name list swallows every module
# written after it, and the disk controller cost three slices' fit figures that
# way.
#
# The seven that stay are the held match, for the disk's `mine`/`which` reason
# exactly: they are taken from `ub_addr`, which is `phys` with a subtraction on
# it and is constant for the microcycle, and nothing reads them until the
# card's own answer machine decides --- and **the earliest answer this card can
# give is fifty ticks after `-UB MSYN`**, the TD250 at IOBADR 0E09, with the
# keyboard-and-mouse group waiting two edges of the microsecond clock on top of
# that.  A tick of holding cannot reach across fifty.
#
# NOTHING ELSE THERE QUALIFIES, and the list is worth writing out because the
# card is mostly clocks:
#
#   - `usec_t`, `kb_t` and `iv_t` count down one a tick and `mains_acc` adds
#     five nanoseconds a tick with `mains_wrap` comparing it a tick early ---
#     free-running counters, each its own input, which this file's second
#     bullet refuses at any depth;
#   - `t_msyn` and `t_edge` count ticks since the strobe and since the last
#     edge of the microsecond clock, and are what decide when the card
#     answers;
#   - `ub_ssyn` IS the answer.  It is read every tick by `cadr_busint_xbus`,
#     which is watching for its rise to start the two Unibus instants, so it
#     is the same kind of register as `deskewed`, `ub_acked` and `ub_loadmd`
#     above and is refused for the same reason;
#   - `usec` is a counter, and it is read by `usec_latch` at a tick that can be
#     the one after it moved --- `-UB MSYN` falls where it falls --- so even
#     though it advances only once in two hundred ticks, the arc out of it is a
#     one-tick arc;
#   - `busy`, `first` and `edges` are the cycle's own state, one tick deep.
#
# **AND THE THIRD SLAVE IS OUT THE SAME WAY, BUT FOR ITS SIX HELD DECODES.**
# `rtl/machine/cadr_busint_regs.sv` is the bus interface's own interrupt block
# and Unibus map, and it landed under `cadr_machine` after this file was
# written, which is exactly the trap the paragraphs above record: a relaxed set
# defined as every register minus a name list swallows every module written
# after it.  So `memory/busint_regs/*` is excluded whole, and six registers are
# put back.
#
# The six are the held match --- `sel`, `in_int`, `in_map`, `wr`, `which` and
# `mapk` --- and they qualify for the card's reason exactly: they are taken
# from `ub_addr`, which is `phys` with a subtraction on it and is constant for
# the microcycle, and **the earliest answer this block can give is fifty ticks
# after `-UB MSYN`**, `busint::DIAGNOSTIC_NS` through the block select's TD250.
# A tick of holding cannot reach across fifty.
#
# Nothing else there qualifies, and the list is short enough to write out:
#
#   - `t_msyn` counts ticks since the strobe and is what decides when the
#     block answers, which is the card's `t_msyn` one slave along;
#   - `ub_ssyn` IS the answer, read every tick by `cadr_busint_xbus` watching
#     for its rise, so it is the same register as the card's and is refused
#     for the same reason;
#   - `timed_out_q` is one tick deep by construction: it exists to turn a
#     level into an edge, and a held edge detector detects nothing;
#   - `int_status`, `ub_map`, `err_xbus`, `err_unibus` and `write_through`
#     would all pass this file's test read literally --- each is loaded at the
#     register strobe and read at `-LOADMD`, seventy ticks later at the
#     earliest --- and they are left timed at the tick for the reason the
#     card's read side is: naming registers to buy slack nothing has asked for
#     is an exemption written before the question was.
#
# **NO FIT HAS BEEN RUN AT THE COMMIT THAT ADDED THIS CLAUSE.**  The argument
# above is derived and not measured, and this file's own history says what
# that is worth: a correct derivation with a blind check still drifts.  Before
# any timing figure is quoted for this module, ask `report_exceptions` or
# `get_timing_paths -through` which of its paths carry the relaxed set's
# requirement, the way the disk controller's 3,904 of 4,000 were found.
#
# **AND ASKING THE SAME QUESTION OF THE OTHER SLAVE FOUND SOMETHING THIS FILE
# HAS BEEN WRONG ABOUT SINCE THE REGISTER BLOCK LANDED.**  The card's
# `ub_ssyn` is out of the set by the module clause above.  The DIAGNOSTIC
# REGISTER BLOCK's is the same signal on the same wired-OR --- both pull
# `-UB SSYN`, which `cadr_busint_xbus.sv` watches every tick for its rise ---
# and it is named nowhere, so it falls into `slow` by default.  Synthesized at
# this slice with this file read scoped, on the memory-off board, at the
# 6.25 ns tick of that afternoon (one tick and fifteen, as everywhere else):
#
#     memory/spy_registers/ub_ssyn_reg   54 of 54 paths ask for 93.750 ns
#     memory/iob/ub_ssyn_reg            138 of 138 paths ask for  6.250 ns
#     memory/busint/ssyn_seen_reg        21 of 23 paths ask for  93.750 ns
#
# **That is `elapsed -> md/CE` again: one gate, one relaxed input and one
# timed one, and only the source decides.**  The arc that matters is
# `ub_ssyn -> ssyn_seen -> ub_ack_at`, where the interface makes the two
# Unibus instants at the tick it SEES the answer; relaxed, the tool permits
# that rise to take the relaxed set's eight ticks and `-MEMACK` to land eight
# ticks late on a register-block cycle.  Nothing in simulation can see it --- a Verilator
# run is exact whatever this file says --- and until 2026-09-11 nothing ran a
# Unibus READ at all.
#
# **IT IS NOT FIXED HERE AND THE REASON IS THAT THE ONE-LINE FIX IS TOO
# WIDE IN THE OTHER DIRECTION.**  `ub_ssyn` has two consumers and they want
# different deadlines: it is the select of the `rdata` mux into MD, which is
# read at the MD strobe twenty ticks later and genuinely has them, and it is
# the interface's edge, which has one tick.  Excluding the register relaxes
# neither and over-tightens the first, which costs slack for a claim that is
# false.  The remedy the file's own rule prescribes is the one `deskewed`
# took: shorten the control path by registering the decision, so that what
# reaches `ssyn_seen` starts at a named fast register and what reaches MD does
# not.  That is a change to `cadr_busint_xbus.sv` and to the register block,
# not to this file, and it wants its own fit either side.  Measured and
# written down rather than half-done.
#
# **THE READ SIDE WAS CONSIDERED FOR THE SET AND LEFT OUT ON PURPOSE.**
# `usec_latch`, `mains`, `scancode`, the two mouse counters, the status
# register's flip-flops, `interval` and `audio` would all pass this file's test
# read literally: each is loaded at one known instant and read at `-LOADMD`,
# which is seventy ticks later at the earliest.  They are left timed at the
# tick anyway, because naming thirteen registers to buy slack nothing has asked
# for is the too-wide exemption this file exists to warn about, and because the
# measurement says it is not needed: with the whole card at one tick the board
# closes.  If a future fit ever needs them, the argument above is the one to
# make, one register at a time, and `usec` must stay out of the set or the arc
# into `usec_latch` goes with it.
#
# **AND THE CONSOLE'S READ-BACK IS IN THE SET, WHICH IS THE WHOLE REASON IT
# IS INSIDE THIS MACHINE.**  `rtl/plumbing/cadr_console.sv` is an AXI slave on
# `M_AXI_GP1` a level above, beside the PS7, and it reads the sixteen
# diagnostic registers --- which is `Engine::spy_read`, a sixteen-way mux over
# `IR`, `PC`, `OPC`, `OB`, the A and M buses, `ST` and the two flag words.
# With the register that catches that mux's answer up there in the console,
# this file could not name it: it is read `read_xdc -ref cadr_machine` and
# cannot reach a level above, which is the same wall `mem_addr` met and the
# reason `rtl/plumbing/xilinx7/cadr_ddr.xdc` exists.  The board flow then asked the mux to
# settle in one tick and reported
#
#     -12.837 ns  u_machine/processor/md_reg[15]/C
#              -> g_ddr.u_console/eng_rdata_reg[1]/D
#              17.703 ns over 24 logic levels, 70% of it routing
#
# on 5,698 endpoints of 27,144, where the commit before the console read
# -0.148 ns on the same board.  Two and a half ticks, and the worst this
# project has measured.
#
# `rtl/machine/cadr_console_bus.sv` moves that register in here, where it falls into
# the set with no naming --- and it earns the set on this file's own test
# rather than by being in the right module.  Its input is the mux, whose every
# source is a register that moves at the microcycle boundary and stands still
# between; and it is loaded AT THE BOUNDARY AND NOWHERE ELSE, `mclk` being its
# whole clock enable, so it is launched at one boundary and captured at the
# next with twenty-nine ticks to settle in at normal speed and forty-four at
# extra slow. Loaded every tick it would be a register holding whatever a
# relaxed path had reached, which is the too-wide exemption in its purest
# form; `console-read-back-is-not-held-to-the-boundary` is the mutation that
# says so, and `build/console.pass` catches it by MEASURING the lag --- reading
# `PC` with the machine running and asking which row the answer belongs to.
# A halted read cannot resolve it, the machine having stopped moving.
#
# **AND ITS CLOCK ENABLE WAS ASKED ABOUT RATHER THAN REASONED ABOUT**, which
# is the trap this file already records one register along --- `elapsed ->
# md/CE`, where a relaxed register's enable went with it. The prose written
# here first said the enable was not relaxed at all, because `mclk` is made
# from `tpclk` and `tpclk_q` and both are excluded above. `get_property
# REQUIREMENT` says otherwise, and it is the third startpoint that does it.
# Synthesized at this slice with this file read scoped, every path into
# `con_rdata_reg[*]/CE`:
#
#     5.000 ns   u_machine/processor/u_phase_gen/tpclk_reg   x64
#     5.000 ns   u_machine/processor/tpclk_q_reg             x64
#    75.000 ns   u_machine/processor/started_reg             x64
#
# The two that make the edge stay at one tick, which is what matters: a
# boundary that arrived a microcycle late would put the capture anywhere.
# `started` is relaxed, and is the one register in the design for which that
# cannot mean anything --- it goes high at the first boundary out of reset and
# never changes again, so "its input is stable across the microcycle and its
# consumer reads it only at the end" is true of it more completely than of
# anything else in the set.
#
# The reasoning was right about the half that decides and wrong about the
# whole, and only the question told the difference. The same query says every
# one of 400 paths into `con_rdata_reg[*]/D` asks for 75.000, worst
# `vma_reg[14]/C` at 24 logic levels with 57.148 ns of slack --- so the
# naming took, which a slack figure alone could never have said.
#
# **AND THE TRANSACTION AUDIT IS THE FIRST MODULE TO ARRIVE WITH ITS TIMING
# SET ANSWERED BEFORE ITS FIT.**  `rtl/plumbing/cadr_bus_audit.sv` is an
# instrument: it watches one transaction per bus cycle at the memory port and
# reports through the console's readout window, and its 347 registers would
# ALL have landed in `slow` by default --- which is exactly the trap
# `cadr_disk_controller.sv` fell into, where 3,904 of 4,000 paths carried the
# exception and three slices quoted fit figures for a disk nobody was timing.
#
# It is not one set for the whole module and the split is the one its header
# argues for.  THE EDGE DETECTORS AND THE PER-CYCLE STATE ARE READ EVERY TICK:
# `req_q`, `done_q` and `cycle_q` make the three edges the whole instrument is
# built on, and a relaxed edge detector misses an edge or invents one, which is
# an instrument that lies.  `owed_reads` and `owed_writes` are read by the
# fault term on every tick and `port_reads`/`port_writes` are enabled by a
# handshake that can arrive on any tick, so they are in that half too, and so
# are `faults`, `stalled` and `seen`, which are counters.  WHAT IS RELAXED IS
# WHAT A CONSOLE READS FROM A HALTED MACHINE: `first_*`, the record, written
# once and read once; `micro`, incremented at a microcycle boundary, which is
# twenty-nine ticks at normal speed; and `word`, the readout register, whose
# address stands still between one console write and the next.
#
# The `fast -> slow` arc that remains is the fault term into the capture
# registers' clock enable, which this clause times at ONE tick and which is
# what it must be: a capture whose enable is relaxed can fire at a tick where
# its own data has not settled.  That is the arc the module's own
# out-of-context figure names --- `req_q_reg/C -> first_addr_reg[0]/CE` at
# +5.790 ns --- and it is the `elapsed -> md/CE` shape with the right answer
# already applied.
#
# **THE CLAUSE NAMES THE INSTANCE**, so `cadr_machine.sv`'s instantiation must
# stay `cadr_bus_audit audit (...)`: a rename empties it in silence, which is
# the `foreach` trap in a new place and has the same tell --- ask
# `report_exceptions`, or `get_timing_paths -through [get_cells */audit/*]`,
# which of its paths carry the relaxed set's requirement, and expect only the
# record, the microcycle counter and the readout word to.

set slow [filter [all_registers] {NAME !~ *u_phase_gen*      && \
                                  NAME !~ *mfinish_t_reg*    && \
                                  NAME !~ *rdfinish_t_reg*   && \
                                  NAME !~ *elapsed_reg*      && \
                                  NAME !~ *vco_count_reg*    && \
                                  NAME !~ *arb_t_reg*        && \
                                  NAME !~ *phase_t_reg*      && \
                                  NAME !~ *n_memack_q_reg*   && \
                                  NAME !~ *n_loadmd_q_reg*   && \
                                  NAME !~ *n_tpwpiram_q_reg* && \
                                  NAME !~ *n_tpwp_q_reg*     && \
                                  NAME !~ *deskewed_reg*     && \
                                  NAME !~ *ub_acked_reg*     && \
                                  NAME !~ *ub_loadmd_reg*    && \
                                  NAME !~ *tpclk_q_reg*      && \
                                  NAME !~ *processor/md_we_q_reg*   && \
                                  NAME !~ *processor/mw_early_q*    && \
                                  NAME !~ *processor/mw_late_q_reg* && \
                                  (NAME !~ *disk/* || NAME =~ *disk/mine_reg* || \
                                                      NAME =~ *disk/which_reg*) && \
                                  (NAME !~ *audit/* || NAME =~ *audit/first_* || \
                                                       NAME =~ *audit/micro_reg* || \
                                                       NAME =~ *audit/word_reg*) && \
                                  (NAME !~ *memory/tv/* || NAME =~ *memory/tv/ctl_reg* || \
                                                           NAME =~ *memory/tv/fb_reg* || \
                                                           NAME =~ *memory/tv/which_reg*) && \
                                  (NAME !~ *memory/iob/* || NAME =~ *memory/iob/sel_reg* || \
                                                            NAME =~ *memory/iob/kbm_reg* || \
                                                            NAME =~ *memory/iob/clkgrp_reg* || \
                                                            NAME =~ *memory/iob/chgrp_reg* || \
                                                            NAME =~ *memory/iob/sergrp_reg* || \
                                                            NAME =~ *memory/iob/wr_reg* || \
                                                            NAME =~ *memory/iob/which_reg*) && \
                                  (NAME !~ *memory/busint_regs/* || \
                                       NAME =~ *memory/busint_regs/sel_reg*    || \
                                       NAME =~ *memory/busint_regs/in_int_reg* || \
                                       NAME =~ *memory/busint_regs/in_map_reg* || \
                                       NAME =~ *memory/busint_regs/wr_reg*     || \
                                       NAME =~ *memory/busint_regs/which_reg*  || \
                                       NAME =~ *memory/busint_regs/mapk_reg*)}]

# The fast read tap, not the whole microcycle: the tightest instant a datapath
# register is read at.  `cadr_tick_pkg::ticks(75)`, eight at a 10 ns grid.
# grid: 75 ns
set_multicycle_path -setup 8 -from $slow -to $slow
set_multicycle_path -hold  7 -from $slow -to $slow

# ------------------------------------------------ THE SPLIT PATHS
#
# **THE CLAUSE ABOVE GIVES EVERY HOP EIGHT TICKS, AND SOME PATHS ARE TWO HOPS
# OR START LATE.**  Eight ticks is right for a register loaded at the boundary
# and read at the next one, which is the whole microcycle away.  It is too
# wide for the paths below, and each has a clause with the time the machine
# really gives it.  Counted from the edge the source moves on to the edge the
# destination takes it, with the processor's registers moving on the edge
# that ends the generator's boundary tick (`cadr_microcycle.sv`'s
# `boundary`), the scratchpad latches following while TPCLK is high, so that
# their last load is at the read tap itself, and **every write the write
# pulse makes taken as the pulse ends** (`cadr_microcycle.sv`'s `wp`).
# Measured tick by tick on a verilated `cadr_microcycle` at all four speeds:
# the latch's last load is the read tap less one tick after IR moves, seven
# at fast speed, and seven ticks before the next boundary at every speed; the
# write pulse ends on the boundary's own edge; a `WRITE-I-MEM` writes the
# control store one tick after the read tap.
#
# **A MICROCYCLE -HANG HOLDS IS THE EXCEPTION, AND IT SETS THE WRITES'
# COUNTS.**  There the pulse still ends at the cycle's length, which is the
# park's first tick, and the boundary that ends the hang can be the very next
# edge; and while -HANG is up the bus's strobe is MD at once, so MD can move
# on the tick before the pulse ends.  Taken there literally the maps' and the
# dispatch memory's write had one tick on both sides.  `cadr_microcycle.sv`'s
# `mw` places it instead, with the same address and word, two ticks before
# the pulse would end when the read has been acknowledged, a tick after it
# when MD moved on the cycle's last edge, and at it otherwise; its note says
# why nothing but the boundary can see the difference and why the choice is
# made from registers.  Measured on the whole machine by `CADR_GAP_MONITOR`
# over `build/dispatch_write_order.pass`'s programs, which the check requires
# to reach both bounds, and over 739 programs moving the acknowledgment
# through every tick of the hung cycle: a write is never less than two ticks
# after MD moved, and a boundary is never less than three after a write.  At
# `f016b65`, where the writes were taken three ticks before the boundary, the
# first was already one tick, measured the same way.
#
#   - THE SCRATCHPAD LATCHES are a register loaded every tick of the read
#     phase between IR and the boundary, so a path through them is two hops.
#     Into them: IR moves at the boundary and the latch closes at the read
#     tap, so the window is the tap less a tick, SEVEN at fast speed, where
#     the clause above allowed eight.  Out of them: the latch's last load is
#     at the read tap and the next boundary's registers take it `ticks(60)`
#     and one tick later, SEVEN at every speed.  Seven and seven is fourteen,
#     the fast microcycle, where eight and eight would have allowed sixteen.
#     **The dispatch memory's write is FIVE ticks after the latch's last
#     load**: a hung cycle whose read has been acknowledged writes it on the
#     tick before its last, `ticks(60)` less one after the read tap.
#   - THE CONTROL STORE'S WORD is a register loaded every tick, and after a
#     `WRITE-I-MEM` it moves mid-cycle: the write is one tick after the read
#     tap, the word is out a tick after that, and IR takes it at the
#     boundary, `ticks(60)` less one later: FIVE.  The PROM shares the I bus
#     with it and is held to the same five, which with the address's eight
#     keeps the two hops inside the fast microcycle.
#   - THE MAPS AND THE DISPATCH MEMORY ARE READ WITHOUT A CLOCK, so the word
#     written is at the memory's output at once, and what reads it at the
#     next boundary --- the dispatch address and the PC, the M bus, MD, the
#     console's read-back --- takes the new word THREE ticks after the write
#     or more.  `-from` the memories' cells names only the paths their write
#     clock launches; a read through them starts at MD or VMA, which move at
#     the boundary and keep the whole microcycle.  The readout's copies are
#     loaded every tick and take the new word ONE tick after.  The registers
#     loaded every tick from the map, `memgo_q` and the memory path's held
#     decode, read it only while MEMSTART is up, and under MEMSTART a map
#     write writes nothing (`mw`'s note), so no path from a write reaches them
#     that the three ticks do not cover.
#   - MD INTO THOSE WRITES is TWO ticks at the least: the map's address is MD
#     and the dispatch memory's comes off it through the M bus.  MD_HELD into
#     MD is one tick, the hang taking the held word on the tick after the
#     strobe held it, and the stack's write into the stack's latch is one
#     tick too: the pulse ends on the boundary edge and the latch follows on
#     the next.
#   - EVERY OTHER REGISTER LOADED EVERY TICK FROM THE BOUNDARY'S REGISTERS
#     AND READ AT THE NEXT BOUNDARY is two hops the same way: `memgo_q`, the
#     three held halves of -WAIT, and the memory path's held decode.  The
#     first hop keeps the relaxed set's `ticks(75)`; the second gets
#     `ticks(60)`, SIX, so that the two sum to the fast microcycle.
#
# A COUNT OF THE FABRIC'S OWN TICKS IS WRITTEN `grid: 0 ns + 3 ticks`: the
# instant is the write, and the ticks are the fabric's.
#
# MEASURED BEFORE THE CLAUSES EXISTED, on the routed DDR=1 HDMI=1 Arty at
# f016b65 and the 10 ns tick, as requirement less slack: into the latches
# 5.8 ns, out of them 27.4 ns, latch to the dispatch memory's write 20.2 ns;
# the control store's address 6.7 ns and its word 8.2 ns; `memgo_q` 15.4 ns in
# and 6.7 out, the -WAIT halves 7.8 and 8.3, the held decode 19.0 and 11.6.
# **AND THE LEVEL-1 MAP'S WRITE TO THE CONTROL STORE'S ADDRESS 33.5 ns**,
# through level 2, the M bus and the dispatch memory; level 2's is 27.5 ns.
# With the writes taken literally at the pulse's end and every clause at one
# tick, at the merge of muir's `bc6af67`: the level-1 map's write to the PC
# 19.0 ns, level 2's 15.5 ns, MD into the dispatch memory's write address
# 15.2 ns and into the maps' write 12.1 ns, all against 10.
#
# Each clause is written `-from X -to $slow`, the priority of the clause
# above, and after it, and the flows assert that every path out of X asks for
# the new count and none for more: a clause the tool ranked below the relaxed
# set would leave every figure exactly as it was.
set split_latch_addr [filter [all_registers] {NAME =~ *processor/ir_reg*      || \
                                              NAME =~ *processor/pdl_ptr_reg* || \
                                              NAME =~ *processor/pdl_idx_reg* || \
                                              NAME =~ *processor/spcptr_reg*}]
set split_latch [filter [all_registers] {NAME =~ *processor/amem_reg*   || \
                                         NAME =~ *processor/mmem_reg*   || \
                                         NAME =~ *processor/pdl_reg*    || \
                                         NAME =~ *processor/amem_q_reg* || \
                                         NAME =~ *processor/mmem_q_reg* || \
                                         NAME =~ *processor/pdl_q_reg*  || \
                                         NAME =~ *processor/spc_q_reg*}]
set split_dmem [filter [all_registers] {NAME =~ *processor/dmem_reg*}]
set split_cstore [filter [all_registers] {(REF_NAME =~ RAMB* && NAME =~ *processor/* && \
                                           NAME !~ *processor/amem_reg* && \
                                           NAME !~ *processor/mmem_reg* && \
                                           NAME !~ *processor/pdl_reg*) || \
                                          NAME =~ *processor/imem_q_reg* || \
                                          NAME =~ *processor/prom_q_reg*}]
set split_maps [filter [all_registers] {NAME =~ *processor/l1_map_reg* || \
                                        NAME =~ *processor/l2_map_reg*}]
set split_md [filter [all_registers] {NAME =~ *processor/md_reg*}]
set split_md_writes [filter [all_registers] {NAME =~ *processor/l1_map_reg* || \
                                              NAME =~ *processor/l2_map_reg* || \
                                              NAME =~ *processor/dmem_reg*}]
set split_md_held [filter [all_registers] {NAME =~ *processor/md_held_reg*}]
set split_readout [filter [all_registers] {NAME =~ *processor/ro_dmem_q_reg* || \
                                           NAME =~ *processor/ro_map1_q_reg* || \
                                           NAME =~ *processor/ro_map2_q_reg*}]
set split_spcm [filter [all_registers] {NAME =~ *processor/spcm_reg*}]
set split_spc_q [filter [all_registers] {NAME =~ *processor/spc_q_reg*}]
set split_every_tick [filter [all_registers] {NAME =~ *processor/memgo_q_reg*   || \
                                              NAME =~ *processor/destmem_q_reg* || \
                                              NAME =~ *processor/use_md_q_reg*  || \
                                              NAME =~ *processor/ifetch_q_reg*  || \
                                              NAME =~ *memory/is_memory_reg*    || \
                                              NAME =~ *memory/device_reg*       || \
                                              NAME =~ *memory/nxm_reg*          || \
                                              NAME =~ *memory/unibus_reg*       || \
                                              NAME =~ *memory/ub_addr_reg*}]

# Into the latches: the fast read tap less the tick IR moves after it.
# grid: 75 ns - 1 tick
set_multicycle_path -setup 7 -from $split_latch_addr -to $split_latch
set_multicycle_path -hold  6 -from $split_latch_addr -to $split_latch

# Out of the latches: the restart after the read tap, and the tick the
# boundary's registers take.
# grid: 60 ns + 1 tick
set_multicycle_path -setup 7 -from $split_latch -to $slow
set_multicycle_path -hold  6 -from $split_latch -to $slow

# Out of the latches into the dispatch memory's write, which in a hung
# microcycle whose read has been acknowledged lands on the tick before the
# cycle's last: the restart after the read tap, less one.
# grid: 60 ns - 1 tick
set_multicycle_path -setup 5 -from $split_latch -to $split_dmem
set_multicycle_path -hold  4 -from $split_latch -to $split_dmem

# The control store's word, from the write a tick after the read tap.
# grid: 60 ns - 1 tick
set_multicycle_path -setup 5 -from $split_cstore -to $slow
set_multicycle_path -hold  4 -from $split_cstore -to $slow

# The maps' write, to the first boundary that can read it: three ticks on,
# the hang of a microcycle whose read has been acknowledged ending on the
# edge after its pulse.
# grid: 0 ns + 3 ticks
set_multicycle_path -setup 3 -from $split_maps -to $slow
set_multicycle_path -hold  2 -from $split_maps -to $slow

# The dispatch memory's write, the same.
# grid: 0 ns + 3 ticks
set_multicycle_path -setup 3 -from $split_dmem -to $slow
set_multicycle_path -hold  2 -from $split_dmem -to $slow

# The three memories' writes into the readout's copies, which are loaded
# every tick.  After the two clauses above, which name them too.
# grid: 0 ns + 1 tick
set_multicycle_path -setup 1 -from $split_md_writes -to $split_readout
set_multicycle_path -hold  0 -from $split_md_writes -to $split_readout

# MD into the address of the maps' and the dispatch memory's write: two
# ticks at the least, `mw`'s placement in a hung microcycle.  After the latch
# clause above, which names the dispatch memory too.
# grid: 0 ns + 2 ticks
set_multicycle_path -setup 2 -from $split_md -to $split_md_writes
set_multicycle_path -hold  1 -from $split_md -to $split_md_writes

# MD_HELD into MD, which the hang takes on the tick after the strobe held it.
# grid: 0 ns + 1 tick
set_multicycle_path -setup 1 -from $split_md_held -to $split_md
set_multicycle_path -hold  0 -from $split_md_held -to $split_md

# The stack's write, on the boundary's edge, into the stack's latch, which
# follows it on the next.
# grid: 0 ns + 1 tick
set_multicycle_path -setup 1 -from $split_spcm -to $split_spc_q
set_multicycle_path -hold  0 -from $split_spcm -to $split_spc_q

# The second hop of every other every-tick register.
# grid: 60 ns
set_multicycle_path -setup 6 -from $split_every_tick -to $slow
set_multicycle_path -hold  5 -from $split_every_tick -to $slow

# THE BUS'S OWN EIGHTY NANOSECONDS, FOR THE SLAVES THAT ARE INSIDE THIS FILE.
#
# `rtl/plumbing/cadr_xbus_ddr.sv` quotes the bus rule that a master must
# "assert good address, write, and data lines 80 ns prior to asserting
# -XBUS.RQ", and `rtl/plumbing/xilinx7/cadr_ddr.xdc` relaxes the memory
# port's address and data registers to `ticks(80)` --- eight at the 10 ns
# grid, sixteen at 5 --- ON THE STRENGTH OF IT.
# The machine's OWN slaves take the same lines from the same master under the
# same rule, and until now nothing said so: they were timed at one tick, and
# at a 5 ns tick the routed board fails 207 paths into the display board's
# color map because of it.
#
# THE DERIVATION, and every step of it is a line rather than an argument.
# `cadr_busint_xbus.sv:128` sets `SETUP_T = cadr_tick_pkg::ticks(80)` and
# `:283` makes `dev_rq = (state == GRANTED && elapsed >= SETUP_T)`, so
# -XBUS.RQ stands `SETUP_T` ticks after the grant and `elapsed` counts from
# the grant.
# `cadr_memory_path.sv` loads `wdata` at MEMGO, which is at or before the
# grant. `cadr_tv.sv:427` takes the word at
# `store_now = asked && dev_write && !taken` --- the FIRST tick -XBUS.RQ
# stands, `taken` refusing every tick after it. So the word has been settled
# for `SETUP_T` ticks when the board captures it, and it is the same count
# the memory port already claims one module along.
#
# WHAT MAKES THIS A BOUND AND NOT A CONVENIENCE, which is the whole of the
# discipline this file is made of:
#
#   - **The `/D` pins and not the cells.** `color_map`'s clock enable is
#     `store_now` with `which`, `wdata[7:6]` and `wdata[3:0]` on it --- an
#     address decode and a one-tick window. `cadr_debug.xdc` and
#     `cadr_ddr.xdc` both split a register's data from its enable for this
#     reason, and `elapsed -> md/CE` is the lesson under all three. The
#     enable keeps its tick, so the capture happens at the tick it always
#     did; what is relaxed is only the word it captures, which the bus
#     already owed `SETUP_T` ticks of settling.
#
#   - **Only registers whose `D` IS the bus word.** `color_map` and
#     `pointer` have exactly two writers each --- `cadr_tv.sv:529` and `:502`
#     clear them at reset, `:557` and `:546` load them from `wdata` --- and a
#     synchronous clear arrives on `R`, not on `D`. So every setup path into
#     these `/D` pins is the line the 80 ns rule names, and the exception
#     needs no `-from` to say so.
#
#   - **`flag` is refused although the same gate writes it.**
#     `cadr_tv.sv:537` gives it a third writer, `tvma_clr`, the sync
#     generator's own one-tick event. Relaxing `flag/D` would relax that
#     preset, and an exemption that reaches a one-tick event is the one this
#     file exists to warn about. `mode` and `sync_on` pass the test and are
#     left timed at the tick anyway, because nothing has asked: naming
#     registers to buy slack nobody wanted is the same fault seen from the
#     other side, and it is the reason the I/O board's read side is out.
#
#   - **And the sync generator is not in it.** `seq_a`, `seq_left` and
#     `seq_ended` fail at 5 ns too and are NOT relaxed: they are the display's
#     own program counter, which steps every tick, and they are the reason
#     this clause names four pin patterns rather than an instance.
#
# HOLD: `-hold 7` beside `-setup 8` --- `cadr_tick_pkg::ticks(80)`, eight at a
# 10 ns grid --- which puts the hold check back on the launch edge where it
# was. Without it the tool would ask the word to be held for seven ticks after
# its launch and report hold violations no slower clock could cure.
# grid: 80 ns
set bus_word [get_pins -quiet {memory/tv/color_map_reg[*][*][*]/D
                               memory/tv/pointer_reg[*]/D
                               memory/g_color_tv.tv_color/color_map_reg[*][*][*]/D
                               memory/g_color_tv.tv_color/pointer_reg[*]/D}]
set_multicycle_path -setup 8 -to $bus_word
set_multicycle_path -hold  7 -to $bus_word

# THE UNIBUS MAP AND ITS WRITE BUFFER, AT THE INSTANT MIT's OWN STROBE PUTS
# THEM.
#
# `cadr_busint_regs.sv:765` and `:769`:
#
#     assign land      = ub_msyn && sel    && wr             && (t_msyn == STROBE_T);
#     assign land_wbuf = ub_msyn && in_win && wr && !mp_high && (t_msyn == STROBE_T);
#
# with `STROBE_T = cadr_tick_pkg::ticks(150)` at `:477` --- FIFTEEN TICKS at a
# 10 ns grid after `-UB MSYN` rises. That is `busint::REGISTER_STROBE_NS`, the instant muir's `Busint`
# calls a write of this block answered, and `t_msyn` counts from the strobe,
# so neither capture can happen before its `STROBE_T`th tick.
#
# And a Unibus master has its data lines good BEFORE it raises `-UB MSYN`.
# The word arrives on `ub_wdata`, which `cadr_console_bus.sv:228` mixes from
# the three masters --- `sr_wdata = dbg_own ? dbg_wdata : con_own ?
# con_wdata_q : cpu_wdata` --- and which of them owns the bus is settled
# before the cycle starts, the bus idling one tick at every change of owner.
# So every setup path into these two registers' `D` was launched at or before
# the tick `-UB MSYN` rose and is captured `STROBE_T` ticks later.
#
# THE TWO REGISTERS ARE THE ONLY ONES IN THE BLOCK THIS IS TRUE OF, and the
# neighbours are worth naming because each is refused for a different reason:
#
#   - `wr_buf` (`:954`) and `ub_map` (`:959`) have exactly two writers each,
#     the reset at `:820`-`:822` and the master's word at the strobe. A
#     synchronous clear arrives on `R`, so every setup path into `/D` is
#     `ub_wdata`.
#   - `rd_buf` is NOT in it. `:919` loads it with `map_rdata[31:16]`, the
#     HIGH half of an Xbus READ, inside the mapped cycle's state machine and
#     nowhere near the strobe. Same array, same reset, different instant.
#   - `map_wdata` (`:906`) and `map_md_wdata` (`:939`) are not in it either:
#     they are loaded when the mapped cycle is LAUNCHED, at `xbus_ok`, which
#     is the state machine's tick and not the strobe's.
#   - `int_status`, `err_*` and `write_through` are loaded at `land` like
#     `ub_map` and would pass the same test. They are left timed at the tick
#     because nothing has asked --- one failing path between them at 5 ns
#     against 270 for the two named here --- and this file's rule is that
#     naming registers to buy slack nobody wanted is an exemption written
#     before the question was.
#
# THE ENABLE IS NOT RELAXED AND MUST NOT BE. `land` and `land_wbuf` are an
# EQUALITY on a counter, true for exactly one tick, and `mp_page` and `mapk`
# are the addresses they write at. A capture whose enable is relaxed can fire
# at a tick where its own data has not settled, and here it would also fire
# at a tick where the entry it writes has moved. That is `elapsed -> md/CE`
# and it is why this names `/D` pins and not cells. 729 of the failing paths
# at 5 ns are the clock enables of these very registers and NOT ONE of them
# is relaxed here.
#
# HOLD: `-hold 14` beside `-setup 15`, putting the hold check back on the
# launch edge. `the-register-strobe-is-a-tick-early` is the mutation that
# holds the count, one tick outside the bound in the design.
# grid: 150 ns
set ub_strobe [get_pins -quiet {memory/busint_regs/wr_buf_reg[*][*]/D
                                memory/busint_regs/ub_map_reg[*][*]/D}]
set_multicycle_path -setup 15 -to $ub_strobe
set_multicycle_path -hold  14 -to $ub_strobe

# THE MEMORY PORT'S OWN DEADLINE IS NOT HERE, AND IT CANNOT BE.
#
# `mem_addr`, `mem_wdata` and `mem_write` leave this module for whatever is
# behind the memory port, and the bus specification --- quoted in
# `rtl/plumbing/cadr_xbus_ddr.sv` --- makes the master responsible for asserting them
# 80 ns before the request.  That is `ticks(80)`, and it is a timing
# exception waiting to be written.  It is written in `rtl/plumbing/xilinx7/cadr_ddr.xdc`
# instead, for a reason worth recording rather than rediscovering:
#
# **THIS FILE IS READ SCOPED, `read_xdc -ref cadr_machine`, and the registers
# that receive those three signals are outside the module.**  A scoped file
# cannot name them.  Nor can it name the ports they leave by: `set_multicycle
# _path -through [get_ports {mem_addr[*] ...}]` was tried and Vivado 2026.1
# answered
#
#     CRITICAL WARNING: [Vivado 12-4739] set_multicycle_path:No valid
#     object(s) found for '-through [get_ports -quiet {...}]'
#
# twice, and `report_exceptions` then counted two exceptions where there
# should have been four.  Measured on the board flow at 1d3a9bc plus this
# work.  It is the `foreach` failure again in a new costume --- a constraint
# that reads cleanly and reaches nothing --- and the only thing that caught it
# was the critical warning being read.
#
# Nor do the hierarchical pins survive to be named from outside: on the board
# netlist `get_pins u_machine/mem_addr[*]` and `u_machine/mem_wdata[*]` are
# both empty, the buses having been dissolved by synthesis --- 32 bits of
# address arrive as 23 registers, the rest of the byte address being constant.
# `u_machine/mem_write` does survive, alone.  So the exception has to name the
# far side, which is the top level's business and not this file's.

# WHAT THIS REPORTED BEFORE THE TWO HOLDINGS BELOW, placed and routed on an
# xc7z020clg400-1: timing NOT met, five paths violating, and they were one
# path fanned across the counter's bits:
#
#     -3.957 ns   processor/memstart_reg_replica_1/C
#              -> processor/rdfinish_t_reg[1]/R
#              8.349 ns (logic 2.349, route 6.001)
#
# `memstart` reaching the synchronous reset of the -RDFINISH counter, 72% of
# it routing. Everything else met. Utilization was not the problem then and is
# not now: 2,795 LUTs of 53,200 and 28 block RAM tiles of 140 at 712909e.
#
# A later report named a second endpoint of the same family:
#
#     -6.542 ns   processor/vma_reg[13]_replica/C
#              -> processor/n_loadmd_q_reg/D
#
# THE FAMILY, AND WHY IT IS NOT ANSWERED HERE. Both are the map arriving at a
# register this file deliberately refuses to relax --- a counter in the first,
# an edge detector in the second. That refusal is right: `rdfinish_t` really
# does count every tick and `n_loadmd_q` really does have to see -LOADMD move
# within one. What is wrong is the path, not the exception. `VMAOK` and the
# address decode are the far end of two asynchronous RAMs and are constant
# for the microcycle they belong to, so the fix is to hold that decision in a
# register of its own and let the tick-rate logic start from there.
#
# Two holdings do it, and neither is a constraint:
#
#   - `cadr_memory_path.sv` registers the decode, so `is_memory` no longer
#     carries the map into `cadr_xbus_ddr`'s `sel` and out through -MEMACK
#     and -LOADMD. `ub_addr` is held with it, for the register block's
#     `elapsed`.
#   - `cadr_microcycle.sv` holds `MEMSTART AND VMAOK` as `memgo_q` for the
#     two countdowns, so the map no longer reaches `mfinish_t/R` or
#     `rdfinish_t/R`.
#
# Each new register is stable across the microcycle and read at the end of
# one, so each is in `slow` by this file's own test and needs no naming.
#
# THE RULE THAT TELLS THE TWO REMEDIES APART, because there are two and they
# are not interchangeable. A fifth destination in the same family --- the
# Unibus SSYN time reaching `mfinish_t` and `rdfinish_t`, 198 ps on the board
# flow --- did NOT take the holding above. It took the other one: the sums
# were moved off the comparator's path, `ssyn_at + UB_ACK_T` becoming a held
# `ub_ack_at`, which is what `cadr_phase_gen.sv` does for its taps.
#
# The deciding question is **when the signal is read**, not what it is:
#
#   - Read once, at a known instant, with the value settled long before?
#     Hold the decision in a register. The map's decode is read at the grant
#     and `MEMSTART AND VMAOK` at the microcycle boundary, so a tick of
#     holding cannot reach across the twenty-odd ticks they have been stable.
#   - Read every tick, because it exists to catch something moving? Then
#     holding it is wrong at any depth, and the only remedy is to make the
#     path shorter --- move an adder to where it has a whole tick, leave the
#     comparator alone with a register.
#
# `MEMRQ` and `MBUSY` are the two halves of one expression and fall on
# opposite sides of that line, which is why `cadr_microcycle.sv` holds one and
# not the other. Pattern-matching the family would have got the fifth one
# wrong.
#
# THE RULE APPLIED AGAIN, WITH THE MEMORY SWITCHED ON, and it sent the two
# arcs different ways for the third and fourth time. `DDR=1` puts the
# processing system behind the memory port, which is the first build that
# times `mem_addr` and `mem_wdata` at all --- `rtl/plumbing/xilinx7/cadr_ddr.xdc` has that
# story. At a840c85 that board reported WNS -0.446 ns on 86 endpoints, where
# the same commit with the memory off reported -0.054 on one. Every one of the
# 86 was inside the machine and none in the new logic, and they were two arcs
# rather than eighty-six:
#
#     61  md_reg/CE, md_held_reg/CE, md_pending_reg/D  <- busint/elapsed_reg/C
#     13  mfinish_t_reg/CE and /D, rdfinish_t_reg/D    <- busint/answered_at_reg/C
#     12  mfinish_t_reg/R, rdfinish_t_reg/R            <- processor/ir_reg/C
#      1  u_phase_gen/tpclk_reg/D                      <- processor/ir_reg/C
#
# The first two rows are one thing seen from both ends: the read deskew
# written as `elapsed >= answered_at + DESKEW_T`, a ten-bit magnitude compare
# standing between the interface's counter and -MEMACK/-LOADMD, which cross to
# the processor and land on MD's clock enables and on the two countdowns. The
# last two are the -WAIT decode: `ir` through DESTM, DESTLC and NEEDFETCH into
# MACHRUN, and MACHRUN into a countdown's reset.
#
#   - The deskew is read every tick. It *is* the acknowledgment, so holding
#     it is wrong at any depth and the path is shortened instead: the
#     comparison is made one tick early and registered, which is the move
#     `cadr_phase_gen.sv` makes for its own taps. `elapsed >= X` at tick t is
#     `elapsed >= X - 1` at t-1, so the value arrives on the same tick with
#     the carry chain off the acknowledgment's path. The Unibus's two
#     instants took the same treatment once the deskew stopped being worst,
#     which is the rest of the move begun when `ssyn_at` became `ub_ack_at`.
#   - MACHRUN is read at one instant and one only --- `cpu_edge` is
#     `mclk_edge && machrun`, one tick a microcycle --- and the IR-derived
#     half of each -WAIT term has been settled since the boundary before. So
#     `DESTMEM`, `USE.MD` and `LCINC AND NEEDFETCH` are held, as `destmem_q`,
#     `use_md_q` and `ifetch_q`. The other half of each term is `MBUSY.SYNC`,
#     `MBUSY` and `-MEMGRANT`, which move within the microcycle and are left
#     alone: -MFINISHD clearing MBUSY in the very tick MCLK1A samples it is
#     where a 220 ns wait cycle turns on, and a tick of holding there would
#     lose a boundary and cost a microcycle.
#
# Same rule, same file, opposite answers, and the three taps are the reason
# this file now names registers that are not edge detectors.
#
# AND THAT WAS ASKED OF THE DESIGN RATHER THAN ASSUMED, synthesized out of
# context with this file read: every path out of `deskewed`, `ub_acked` and
# `ub_loadmd` asks for 5.000 ns, so the naming took; 181 of the first 200 out
# of `destmem_q`, `use_md_q` and `ifetch_q` ask for 75.000 and the other 19 for
# 5.000, which is those three landing in `slow` and their arcs into the
# countdowns and the edge detectors staying at one tick. A register named here
# by mistake and one that should have been and was not look identical in a
# slack figure; they do not look identical to `get_property REQUIREMENT`.
#
# MEASURED AT a840c85 PLUS THIS WORK, board flow, both configurations:
#
#                            DDR=1                    DDR=0
#     worst negative slack   -0.446 -> -0.012 ns      -0.054 -> +0.077 ns
#     failing endpoints      86 of 14787 -> 6         1 of 14058 -> 0
#     total negative slack   -12.534 -> -0.074 ns     -0.054 -> 0
#     hold                   +0.040 -> +0.041 ns      +0.084 -> +0.097 ns
#     LUTs                   2136 -> 2177             2072 -> 2005
#     registers              954 -> 957               748 -> 752
#     block RAM tiles        29, unchanged            29, unchanged
#
# **THE BOARD WITH THE MEMORY OFF NOW MEETS TIMING**, and its worst path has
# moved to the phase generator's TPCLK into the control store's write address,
# a family this file has never had to argue about. The board with the memory
# on does not, by twelve picoseconds on six endpoints --- which is inside the
# quarter of a nanosecond that counts as placement noise, so it is reported as
# a number and not as closure.
#
# AND WHAT IS LEFT CANNOT TAKE EITHER REMEDY, which is worth writing down
# before somebody tries. All six are
#
#     -0.012 ns   busint/elapsed_reg[6]/C -> processor/md_reg[*]/CE
#              4.128 ns over five LUTs, no carry chain
#
# and the arc is `elapsed >= SETUP_T` making -XBUS.RQ, the bridge answering it
# combinationally, and `write && answering` making -MEMACK on a write. That
# last gate is the 74S64 at REQLM 0C11 and it is a gate on purpose:
# `cadr_busint_xbus.sv` says so and `memack-registered-on-a-write` is the
# mutation that holds it, because registering it puts the acknowledgment a
# tick late on every write. Holding is refused by the rule and registering is
# refused by the machine.
#
# MEASURED AT 712909e, and the holdings did what they were for. Placed and
# routed out of context by `boards/arty-z7-20/vivado/fit.tcl`: WNS -0.484 ns, 94 failing
# endpoints of 13,444, hold met at +0.061 ns. On the board through
# `boards/arty-z7-20/vivado/bitstream.tcl`, where this file is read scoped: WNS -0.129 ns, 16
# failing endpoints of 14,135, hold met at +0.079 ns.
#
# NEITHER ENDPOINT NAMED ABOVE IS ANYWHERE NEAR THE TOP NOW. `n_loadmd_q_reg`
# and `memstart` between them appear not once in the ten worst paths of either
# flow --- the reports are `report_timing_summary -max_paths 10`, so that is
# what "no longer near the top" is measured against and not more. What is
# worst out of context is a third member of the same family, and it is the one
# this file's policy predicts:
#
#     -0.484 ns   processor/ir_reg[26]/C
#              -> processor/mfinish_t_reg[1]/R
#              4.971 ns (logic 1.076, route 3.895), 5 logic levels
#
# A datapath register into a tick-rate counter's reset: slow-to-fast, so the
# `-from $slow -to $slow` multicycle does not match it and must not, and it
# has one tick to arrive in. It is within half a nanosecond of doing so, and
# on the board the same family is worst at -0.384 ns from `ir_reg[25]` at
# b1bcc34 --- where at 712909e the board's worst was somewhere else entirely,
# the phase generator's write pulse into the dispatch memory's LUTRAM write
# enables, 3 logic levels and 80% route delay. Two revisions, two worst nets:
# the family is stable and the net is placement, so a net quoted from a timing
# report belongs with the commit it was measured at.
#
# MEASURED AT THIS SLICE, the I/O board's composition, both boards through
# `boards/arty-z7-20/vivado/bitstream.tcl` and against the same two fits run
# from a worktree at 74fa921 on the same machine and the same tool:
#
#                            memory-off               DDR=1
#     worst negative slack   +0.375 -> +0.393 ns      +0.362 -> +0.153 ns
#     failing endpoints      0 of 16,316 -> 0/16,843  0 of 27,578 -> 0/28,166
#     hold                   +0.036 -> +0.048 ns      +0.025 -> +0.043 ns
#     Slice LUTs             3,685 -> 3,895           7,352 -> 7,518
#     Slice Registers        1,662 -> 1,863           5,195 -> 5,412
#     block RAM tiles        37, unchanged            37, unchanged
#
# Both still meet.  **The memory-on board's 209 ps is placement and not the
# card**: its worst path moved from the pack side's `store_wdata` into the
# disk's tag to `disk/rst_q_reg/C -> disk/ch_i_reg[0]/R`, zero logic levels
# and 92% routing, and no path of the card appears anywhere in that report.
# The card's own worst, on the memory-off board where it is not folded away,
# is `memory/iob/t_edge_reg[0]/C -> memory/iob/iv_t_reg[0]/R` at +0.646 ns.
# Quote these with the commit, as this file's own note says.
#
# The 10,972 paths this file relaxes to 75.000 ns out of context, and the
# 10,929 it relaxes on the board --- 10,956 there once routed --- are what
# `boards/arty-z7-20/vivado/constraints_check.tcl` asserts on: a count of zero at that
# requirement is the `foreach` bug back again, and both flows now stop on it
# before they place anything.
