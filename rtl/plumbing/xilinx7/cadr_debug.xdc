# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The debug cable's deadline: the word the debuggee drives is not a one-tick
# signal, and where the carrier latches it is outside the machine.
#
# READ ONLY BY A BOARD THAT BRINGS A GENERAL-PURPOSE PORT OUT, on
# `rtl/plumbing/xilinx7/cadr_ddr.xdc`'s precedent and for its reason. Every
# object below is inside `g_ddr`, which exists only when
# `boards/arty-z7-20/cadr_arty.sv` has a `PS7` in it; read against the default
# board it would be critical warnings about objects that are not there, and a
# critical warning that means nothing is how a constraint that means nothing
# goes unnoticed.
#
# WHY THERE IS A DEADLINE HERE AT ALL, MEASURED RATHER THAN FORESEEN. The
# first board with the cable composed came out at **-8.772 ns on the memory-on
# flow**, against +0.914 ns for the same board one commit earlier, and the
# worst path was
#
#     u_machine/processor/vma_reg[15]/C
#       -> g_ddr.u_debug_window/sts_dbd_reg[1]/D
#     23 logic levels, 18.679 ns, requirement 10.000 ns
#
# with ten of the twenty worst endpoints in that one sixteen-bit register.
# That is `VMA` through both levels of the map to `-VMAOK`, into FLAG-2, into
# the processor's sixteen-way diagnostic mux, through the register block, the
# arbiter and MIT's DBGIN page, out of `cadr_machine` on `DBD<15:0>` and into
# the carrier's latch.
#
# **IT IS THIS PROJECT'S OWN RECORDED TRAP, ONE SIGNAL ALONG.** A module a
# level above `cadr_machine` gets none of `cadr_machine.xdc`, so an arc into
# it is timed at one tick however slow both its ends are. The console read
# the machine's `MD` into a register in the top level and the board read
# -12.837 ns. **The deadline was wrong, not the depth**: every register on
# this arc inside the machine is in `cadr_machine.xdc`'s relaxed set, and
# the one that ends it is not, because it is in the carrier.
#
# THE CARRIER'S LATCH CANNOT SIMPLY MOVE INSIDE, and that is decided rather
# than assumed. `docs/debug-cable.md`: a read cycle's word is driven LIVE by
# `cadr_dbgin.sv`, as the Am8304s drive it from `UDI` while the cycle runs,
# and "whoever is watching is the one that has to latch" --- which is what
# `cable::DebugIn::observe` does on muir's side. Two latches in one path would
# be two places a mutation could be made and neither caught. So the latch
# stays where the watcher is, and the arc gets a deadline instead.
#
# AND THE DEADLINE IS THE CABLE'S OWN, WRITTEN DOWN, NOT CHOSEN. A debug cycle
# is answered by the diagnostic register block `busint::DIAGNOSTIC_NS` = 250 ns
# after `-UB MSYN`, which is twenty-five ticks, and the address that selects
# the word --- `dbg_addr`, hence `spy_eadr` --- is a LATCHED register that has
# not moved since the previous request's lift. So by the tick `DEBUG IN ACK`
# rises and this register captures, the word has had twenty-five ticks to
# settle and not one. **Six ticks is a floor with four times margin**, and it
# is stated as a floor: the measured need is 18.679 ns, which is two.
#
# IT WAS FOUR UNTIL THE TICK WAS ASKED TO BE 5 ns AGAIN, AND FOUR IS NOT A
# BOUND. At a 10 ns tick 18.679 ns is under two ticks and any small number
# does; at 5 ns the same arc is four ticks and a half, and the routed board
# reports 22.867 ns into `sts_dbd_reg[*]`, so four is below the arc it was
# written for. Six is taken from the other register this project relaxes by
# the same argument --- the Pmod carrier's frame register, whose shift
# reloads it every `BEAT_T` = 6 ticks and which therefore cannot honestly be
# given more --- so ONE number covers both latches and neither is written to
# its own convenience. Twenty-five is what this latch alone could claim, and
# it is not claimed.
#
# WHAT THE RELAXATION DOES NOT EXCUSE, and it is worth saying because MIT
# said it first. The 74LS244s drive `SPY<15:0>` asynchronously, so a RUNNING
# machine moves the lines under a standing acknowledgment and read and write
# at one address are uncorrelated. A word a tick or two stale on a running
# machine is therefore already the semantics of this bus, stated in
# `cadr_console_bus.sv` for the console's own read-back --- "exact on a halted
# machine and muir's own read-phase semantics on a running one" --- and CC
# halts the debuggee before it does anything else. This exception does not
# make that worse; a two-tick arrival inside a twenty-five-tick window is
# invisible to it.
#
# HOW THIS IS KEPT FROM BEING TOO WIDE, because an exemption that is too wide
# tests nothing and looks exactly like one that is right.
#
#   - **The `/D` pins and not the cells.** `-to [get_cells ...]` is every
#     input pin of the register, `CE` among them, and this register's `CE` is
#     `dbg_in_req && dbg_in_ack && !sts_ack` --- the acknowledgment, which is
#     the signal that says the word is good and the one thing that must NOT be
#     relaxed. That is `cadr_ddr.xdc`'s split between the address and
#     `-XBUS.RQ`, made for the same reason, and the `elapsed -> md/CE` lesson
#     underneath both.
#
#   - **`sts_dbd` alone and nothing else in the carrier.** `sts_ack` is a
#     constant, `sts_drv` is `|dbd_oe` and two levels deep, and the watchdog
#     and the lead are counters that must keep their tick.
#     `boards/arty-z7-20/vivado/bitstream.tcl` asserts exactly that with
#     `assert_instance_timing`: no path into any OTHER register of the window
#     may ask for 40 ns, and at least one path into this one must.
#
#   - **And the count is asserted**, the way the machine's relaxed set and
#     the memory port's contract are, so an exception that reached no path is a
#     failure and not a plausible number.
#
# **THE INSTANCE IS MATCHED BY A WILDCARD AND NOT BY ITS FULL PATH.**  On both
# boards the window is `g_ddr.u_debug_window`, behind the processing system's
# port, and the module, the cone and the reason are identical --- the machine's
# diagnostic multiplexer reaching this latch, twenty-three logic levels of it.
# Naming the generate hierarchy here would make this file a second thing to
# keep in step with a top level, and a scoped path that stops matching applies
# to nothing while saying nothing, which is the failure this repository records
# more often than any other.  The pattern is anchored on the instance name and
# not open at the other end, and `assert_instance_timing` in each board's flow
# is what says it reached the registers it was meant to.
set cable [get_pins -quiet {*u_debug_window/sts_dbd_reg[*]/D}]
# board ticks
set_multicycle_path -setup 6 -to $cable
set_multicycle_path -hold  5 -to $cable
