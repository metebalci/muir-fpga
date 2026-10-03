# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build a bitstream for the Kria KR260.
#
#     make build/boot_prom.hex build/sync_prom.hex
#     vivado -mode batch -source boards/kria-kr260/vivado/bitstream.tcl
#
# Run from the repository root.  This is `boards/cora-z7-07s/vivado/
# bitstream.tcl` with this board's part, pins, top level and memory map, and
# with the probe and the two proving boards left out: neither has been
# carried to this part yet.  Every check below is that file's and the reason
# for each is that file's (and `boards/arty-z7-20/vivado/bitstream.tcl`'s):
# that the constraints applied, that the machine is still there, that the
# block RAM writes where the RTL says and is enabled only while addressed,
# and that the bitstream is a bitstream.
#
# **THE BOARD IS BUILT WITH THE PROCESSING SYSTEM BY DEFAULT HERE**, `DDR=1`,
# where the Zynq-7000 flows default to the bare machine: a KR260 bitstream is
# loaded by the processing system's own U-Boot and lives beside Linux, and
# the bare machine is K1's out-of-context fit.  `DDR=0` still builds it.
#
# **THE MEMORY MAP IS THE KR260's**, `CADR_DDR_MAP_KR260`, handed to
# synthesis as a define; `cadr_kr260.sv` stops elaboration if the package
# came out with any other base.
#
# **THE THREE CHECKS THAT ASK FOR CELLS BY KIND ACCEPT BOTH FAMILIES**: a
# flip-flop's `PRIMITIVE_GROUP` is `REGISTER` on UltraScale+ where it is
# `FLOP_LATCH` on the 7 series, and block RAM is `BLOCKRAM.BRAM.*` where it is
# `BMEM.*` (`constraints_check.tcl`, `rams_enable_check.tcl`, and the counts
# below).

# **WHICH MACHINE**: `cadr`, the default, or `quux` at revision 13 alone,
# `WORD_BITS=40` (contract G2), as `cadr_kr260.sv` takes them; revision 12 is
# not built for this board.  A QUUX build goes to a directory that says
# `quux13` and writes `quux_kr260.bit`, for the reason the Arty Z7-20's flow
# gives: a build of one machine never replaces the other's.
set machine   [expr {[info exists ::env(MACHINE)]   ? $::env(MACHINE)   : "cadr"}]
set word_bits [expr {[info exists ::env(WORD_BITS)] ? $::env(WORD_BITS) : "32"}]
if {$machine ne "cadr" && $machine ne "quux"} {
    puts "BIT: FAILED --- MACHINE=$machine is not a machine. It is cadr, MIT's"
    puts "BIT: machine, or quux, the evolved CADR."
    exit 1
}
if {$word_bits ne "32" && $word_bits ne "40"} {
    puts "BIT: FAILED --- WORD_BITS=$word_bits is not a word. It is 32, or 40 for"
    puts "BIT: QUUX revision 13."
    exit 1
}
if {$machine eq "quux" && $word_bits ne "40"} {
    puts "BIT: FAILED --- MACHINE=quux at WORD_BITS=$word_bits, and the Kria KR260 builds"
    puts "BIT: the CADR and QUUX revision 13 only: give WORD_BITS=40."
    exit 1
}
if {$machine eq "cadr" && $word_bits eq "40"} {
    puts "BIT: FAILED --- WORD_BITS=40 is QUUX revision 13, and MACHINE=cadr;"
    puts "BIT: the CADR's word is 32 bits."
    exit 1
}
set part   [expr {[info exists ::env(PART)]   ? $::env(PART)   : "xck26-sfvc784-2LV-c"}]
set outdir [expr {[info exists ::env(OUTDIR)] ? $::env(OUTDIR)
                  : ($machine eq "quux" ? "build/bitstream-kr260-quux13" : "build/bitstream-kr260")}]
if {$machine eq "quux" && [string first quux13 [file tail $outdir]] < 0} {
    puts "BIT: FAILED --- MACHINE=quux into OUTDIR=$outdir, whose name does not say"
    puts "BIT: quux13. Name the directory for the machine, as build/bitstream-kr260-quux13."
    exit 1
}
if {$machine eq "quux"} {
    puts "BIT: the machine is quux, revision 13 (WORD_BITS=40)"
} else {
    puts "BIT: the machine is cadr"
}
file mkdir $outdir
if {[info exists ::env(VIVADO_THREADS)]} { set_param general.maxThreads $::env(VIVADO_THREADS) }

# The tick, read out of the MMCME4_BASE in the top level by the same parser
# every board's flow uses: its four parameters have the MMCME2's names.
source boards/arty-z7-20/vivado/tick.tcl
set tick [cadr_tick_ns boards/kria-kr260/cadr_kr260.sv]

set ddr  [expr {[info exists ::env(DDR)]  ? $::env(DDR)  : 1}]
set lmtv [expr {[info exists ::env(LMTV)] ? $::env(LMTV) : 1}]

# QUUX revision 13 boots from its own PROM, version 2001
# (`make build/boot_prom.quux13.hex`), as on the other boards.
set prom [expr {$machine eq "quux" ? "build/boot_prom.quux13.hex" : "build/boot_prom.hex"}]
puts "BIT: the boot PROM is $prom"
if {![file exists $prom]} {
    puts "BIT: $prom is missing; run `make $prom` first"
    exit 1
}
set sync_prom build/sync_prom.hex
if {![file exists $sync_prom]} {
    puts "BIT: $sync_prom is missing; run `make $sync_prom` first"
    exit 1
}

# The sources: every vendor-neutral file, this board's directory, and of the
# family directories only `xilinx7/cadr_usr_access.sv`, whose `USR_ACCESSE2`
# is the same primitive on UltraScale+.  The rest of `xilinx7/` is the HDMI
# transmitter's 7-series serializers, which this board does not build.
set sources {}
foreach f [glob rtl/*/*.sv rtl/*/*/*.sv boards/kria-kr260/*.sv] {
    if {[regexp {^rtl/plumbing/([^/]+)/} $f -> family] &&
        $f ne "rtl/plumbing/xilinx7/cadr_usr_access.sv"} {
        continue
    }
    lappend sources $f
}

source boards/arty-z7-20/vivado/rams_check.tcl
rams_canary $part

read_verilog -sv $sources

set t0 [clock seconds]
synth_design -top cadr_kr260 -part $part \
    -verilog_define CADR_DDR_MAP_KR260=1 \
    -generic PROM_HEX=[file normalize $prom] \
    -generic SYNC_PROM_HEX=[file normalize $sync_prom] \
    -generic DDR=$ddr \
    -generic LMTV=$lmtv \
    {*}[expr {$machine eq "quux" ? [list -generic MACHINE=quux -generic WORD_BITS=40] : {}}]
puts "BIT: synthesis took [expr {[clock seconds] - $t0}] s"

assert_rams_write_where_the_rtl_says $machine

read_xdc boards/kria-kr260/cadr_kr260.xdc
read_xdc -ref cadr_machine rtl/plumbing/xilinx7/cadr_machine.xdc
# QUUX's own clauses, each count of K written from `sync_k`: this board's
# `SYNC_K13`, read out of its top level by `tick.tcl`'s `cadr_sync_k`.
if {$machine eq "quux"} {
    set sync_k [cadr_sync_k 40 boards/kria-kr260/cadr_kr260.sv]
    read_xdc -ref cadr_machine rtl/plumbing/xilinx7/quux_machine.xdc
    puts "BIT: QUUX's microcycle is $sync_k ticks"
}
if {$ddr > 0} { read_xdc rtl/plumbing/xilinx7/cadr_ddr.xdc }
# THE DISPLAY OUTPUT'S CLOCKS AND CROSSINGS, on a board with its processing
# system, where the display is built.  And the assertions that file cannot
# make for itself, the Arty Z7-20's flow's for the same module: that the two
# clocks exist, and that each bound named a register.
if {$ddr > 0} {
    read_xdc boards/kria-kr260/cadr_kr260_display.xdc
    foreach c {clk_raw pixel_raw} {
        if {[llength [get_clocks -quiet $c]] != 1} {
            puts "BIT: FAILED --- no clock `$c`. boards/kria-kr260/cadr_kr260_display.xdc"
            puts "BIT: names the machine's and the pixel MMCM's outputs by their nets; a"
            puts "BIT: renamed net is a clock group that reached nothing."
            exit 1
        }
    }
    set disp_bound 0
    set disp_pats {*req_addr_reg* *slp_want_reg* *slp_want_s1_reg* *slp_mute_reg* *slp_mute_s1_reg*}
    if {$machine ne "quux"} { lappend disp_pats *map_idx_reg* *cmap_reg* }
    foreach pat $disp_pats {
        set found [get_cells -quiet -hier -filter "NAME =~ $pat"]
        if {[llength $found] == 0} {
            puts "BIT: FAILED --- no register matching $pat, so a bound in"
            puts "BIT: boards/kria-kr260/cadr_kr260_display.xdc named nothing."
            exit 1
        }
        incr disp_bound [llength $found]
    }
    set live [get_pins -quiet -hier -filter {NAME =~ *u_ps8/u_ps8/DPLIVEVIDEOIN*}]
    if {[llength $live] != 39} {
        puts "BIT: FAILED --- [llength $live] live video pins on the PS8, want 39"
        puts "BIT: (DE, the two syncs and the 36-bit pixel)."
        exit 1
    }
    puts "BIT: the display's pixel clock is grouped apart from the machine's;"
    puts "BIT: $disp_bound register(s) of its crossings named; 39 live video pins"
}
# The debug cable is the CADR's alone (contract Q5).
if {$ddr > 0 && $machine eq "cadr"} { read_xdc rtl/plumbing/xilinx7/cadr_debug.xdc }
if {$machine eq "cadr"} { read_xdc rtl/plumbing/xilinx7/cadr_debug_pmod.xdc }

source boards/arty-z7-20/vivado/constraints_check.tcl

set inside u_machine
if {$ddr > 0} { lappend inside g_ddr.u_axi }
if {$ddr > 0 && $machine eq "cadr"} { lappend inside g_ddr.g_dbg_window.u_debug_window }
if {$ddr > 0 && $machine eq "quux"} { lappend inside g_ddr.g_qaxi.u_qaxi }
if {$machine eq "cadr"} { lappend inside g_dbg_cable.u_dbg_cable }
assert_constraints_scoped $inside $tick

report_exceptions -file $outdir/exceptions.rpt
set fh [open $outdir/exceptions.rpt r]
set exception_text [read $fh]
close $fh
set exceptions [regexp -all {cycles=} $exception_text]
set clocks     [llength [get_clocks -quiet]]
puts "BIT: $exceptions multicycle exceptions, $clocks clocks"
if {$exceptions < 2} {
    puts "BIT: FAILED --- no timing exceptions were created."
    exit 1
}
if {$clocks < 2} {
    puts "BIT: FAILED --- $clocks clock(s); expected the carrier's 25 MHz and"
    puts "BIT: the MMCM's 100 MHz derived from it."
    exit 1
}

if {$machine eq "cadr"} {
    # The same assertions as the Cora's, in the same order: see that flow.
    # grid: 75 ns (shared with 80 ns)
    assert_multicycle_applied $tick 8
    # grid: 75 ns
    if {$ddr > 0} {
        assert_instance_timing $tick 8 *u_machine/audit/* \
            {*audit/first_* *audit/micro_reg* *audit/word_reg*}
    } else {
        puts "XDC: the audit has no registers on a board with no console to read\
              it, so its split is not asked about here"
    }
    if {$ddr > 0} {
        # grid: 80 ns
        assert_instance_timing $tick 8 *g_ddr.u_axi/* {} \
            {*m_axi_awaddr_reg* *m_axi_araddr_reg* *m_axi_wdata_reg*}
        set a_addr {*g_ddr.u_axi/m_axi_awaddr_reg* *g_ddr.u_axi/m_axi_araddr_reg* *g_ddr.u_axi/m_axi_wdata_reg*}
        # grid: 80 ns
        assert_clause_timing $tick 8 "the processor's cycle into the adapter" \
            {*u_machine/processor/*} $a_addr
        # grid: 0 ns + 1 tick
        assert_clause_timing $tick 1 "the disk's channel into the adapter" \
            {*g_cadr_disk.disk/*} $a_addr
        # grid: 0 ns + 1 tick
        assert_clause_timing $tick 1 "the Unibus map's window into the adapter" \
            {*memory/busint_regs/*} $a_addr
        # grid: 0 ns + 1 tick
        assert_clause_timing $tick 1 "the Xbus arbiter into the adapter" \
            {*memory/ch_own_reg* *memory/mp_own_reg* *memory/owner_d_reg*} $a_addr
        # grid: 0 ns + 1 tick
        assert_clause_timing $tick 1 "the bus interface's state into the adapter" \
            {*g_cadr_busint.busint/*} $a_addr
    }
    # board ticks
    if {$ddr > 0} {
        assert_instance_timing $tick 6 *g_ddr.g_dbg_window.u_debug_window/* {*sts_dbd_reg*}
    }
    # board ticks
    assert_instance_timing $tick 6 *g_dbg_cable.u_dbg_cable/* {*tx_frame_reg* *tx_d_reg*}
    assert_cable_beat rtl/plumbing/cadr_dbg_tx.sv rtl/plumbing/xilinx7/cadr_debug_pmod.xdc
    # board ticks
    assert_multicycle_applied $tick 6
    # grid: 80 ns
    assert_instance_timing $tick 8 *u_machine/memory/tv/* {*color_map_reg* *pointer_reg*} \
        {*memory/tv/ctl_reg* *memory/tv/fb_reg* *memory/tv/which_reg*}
    # grid: 80 ns
    if {$lmtv} {
        assert_instance_timing $tick 8 *u_machine/memory/g_color_tv.tv_color/* \
            {*color_map_reg* *pointer_reg*} \
            {*g_color_tv.tv_color/ctl_reg* *g_color_tv.tv_color/fb_reg* *g_color_tv.tv_color/which_reg*}
    }
    # grid: 150 ns
    assert_instance_timing $tick 15 *u_machine/memory/busint_regs/* \
        {*wr_buf_reg* *ub_map_reg*}
    # grid: 75 ns - 1 tick
    assert_clause_timing $tick 7 "IR into the scratchpad latches" \
        {*processor/ir_reg* *processor/pdl_ptr_reg* *processor/pdl_idx_reg* *processor/spcptr_reg*} \
        {*processor/amem_reg* *processor/mmem_reg* *processor/pdl_reg* *processor/amem_q_reg*
         *processor/mmem_q_reg* *processor/pdl_q_reg* *processor/spc_q_reg*}
    # grid: 60 ns + 1 tick
    assert_clause_timing $tick 7 "out of the scratchpad latches" \
        {*processor/amem_reg* *processor/mmem_reg* *processor/pdl_reg* *processor/amem_q_reg*
         *processor/mmem_q_reg* *processor/pdl_q_reg* *processor/spc_q_reg*}
    # grid: 60 ns - 1 tick
    assert_clause_timing $tick 5 "the latches into the dispatch memory's write" \
        {*processor/amem_reg* *processor/mmem_reg* *processor/pdl_reg* *processor/amem_q_reg*
         *processor/mmem_q_reg* *processor/pdl_q_reg* *processor/spc_q_reg*} {*processor/dmem_reg*}
    # grid: 60 ns - 1 tick
    assert_clause_timing $tick 5 "the control store's word" \
        {*processor/imem_reg* *processor/imem_q_reg* *processor/prom_q_reg*}
    # grid: 0 ns + 3 ticks
    assert_clause_timing $tick 3 "the maps' write" {*processor/l1_map_reg* *processor/l2_map_reg*}
    # grid: 0 ns + 3 ticks
    assert_clause_timing $tick 3 "the dispatch memory's write" {*processor/dmem_reg*}
    # grid: 0 ns + 1 tick
    assert_clause_timing $tick 1 "the three memories' writes into the readout" \
        {*processor/l1_map_reg* *processor/l2_map_reg* *processor/dmem_reg*} \
        {*processor/ro_dmem_q_reg* *processor/ro_map1_q_reg* *processor/ro_map2_q_reg*}
    # grid: 0 ns + 2 ticks
    assert_clause_timing $tick 2 "MD into the writes' address" {*processor/md_reg*} \
        {*processor/l1_map_reg* *processor/l2_map_reg* *processor/dmem_reg*}
    # grid: 0 ns + 1 tick
    assert_clause_timing $tick 1 "the placement of the maps' and dispatch memory's write" \
        {*processor/md_we_q_reg* *processor/mw_early_q* *processor/mw_k1_q_reg*
         *processor/mw_late2_q_reg*}
    # grid: 0 ns + 1 tick
    assert_clause_timing $tick 1 "MD_HELD into MD" {*processor/md_held_reg*} {*processor/md_reg*}
    # grid: 0 ns + 1 tick
    assert_clause_timing $tick 1 "the stack's write into its latch" {*processor/spcm_reg*} \
        {*processor/spc_q_reg*}
    # grid: 0 ns + 1 tick
    assert_clause_timing $tick 1 "REQTIM's oscillator" {*g_cadr_busint.busint/vco_acc_reg*}
    # grid: 60 ns
    assert_clause_timing $tick 6 "the second hop of the every-tick registers" \
        {*processor/memgo_q_reg* *processor/destmem_q_reg* *processor/use_md_q_reg*
         *processor/ifetch_q_reg* *memory/is_memory_reg* *memory/device_reg* *memory/nxm_reg*
         *memory/unibus_reg* *memory/ub_addr_reg*}
}

# **QUUX REVISION 13'S ASSERTIONS ARE THE ARTY Z7-20'S**, taken from its
# flow at this board's K, with the reasons there: the relaxed set at K; the
# audit's split at K; QUUX's adapter, which has no clause of the bus's, a tick
# from each of its two writers; no cell of the debug cable (contract Q5); and
# every clause of `quux_machine.xdc` asked what it reached.
if {$machine eq "quux"} {
    # sync: K
    assert_multicycle_applied $tick $sync_k
    if {$ddr > 0} {
        # sync: K
        assert_instance_timing $tick $sync_k *u_machine/audit/* \
            {*audit/first_* *audit/micro_reg* *audit/word_reg*}
        # The request the adapter holds, which its transaction is worked out
        # from (`quux_axi_master.sv`).
        set q_addr {*g_ddr.g_qaxi.u_qaxi/a_q_reg* *g_ddr.g_qaxi.u_qaxi/wd_q_reg* *g_ddr.g_qaxi.u_qaxi/beats_q_reg*
                    *g_ddr.g_qaxi.u_qaxi/wide_q_reg* *g_ddr.g_qaxi.u_qaxi/line_reg*}
        # grid: 80 ns
        assert_instance_timing $tick 8 *g_ddr.g_qaxi.u_qaxi/* {}
        # grid: 0 ns + 1 tick
        assert_clause_timing $tick 1 "QUUX's port's operations into its adapter" \
            {*memory/g_quux_port.port/*} $q_addr
        # And the block-disk's transfer words, which pass through the bridge
        # three ticks after the channel loads them, and the arbiter's registers,
        # which hand it the bus one and two ticks before: one tick each.
        # grid: 0 ns + 1 tick
        assert_clause_timing $tick 1 "block-disk's words into QUUX's adapter" \
            {*g_quux_disk.disk/*} $q_addr
        # grid: 0 ns + 1 tick
        assert_clause_timing $tick 1 "the Xbus arbiter into QUUX's adapter" \
            {*memory/ch_own_reg* *memory/owner_d_reg*} $q_addr
    } else {
        puts "XDC: the audit has no registers on a board with no console to read\
              it, so its split is not asked about here"
    }
    assert_no_debug_cable
    set quux_tick_cells [get_cells -quiet -hier -filter {NAME =~ *processor/g_quux_tick.clocks/us_reg* && IS_SEQUENTIAL}]
    if {[llength $quux_tick_cells] == 0} {
        puts "BIT: FAILED --- QUUX's clocks' countdown is not in the design, so the"
        puts "BIT: clause taking it out of the relaxed set is on nothing."
        exit 1
    }
    set q_latch {*processor/amem_reg* *processor/mmem_reg* *processor/pdl_reg* *processor/amem_q_reg*
                 *processor/mmem_q_reg* *processor/spc_q_reg*}
    # grid: 0 ns + 1 tick
    assert_clause_timing $tick 1 "IR into the scratchpad latches" \
        {*processor/ir_reg* *processor/pdl_ptr_reg* *processor/pdl_idx_reg* *processor/spcptr_reg*} \
        $q_latch
    # sync: K - 1
    assert_clause_timing $tick [expr {$sync_k - 1}] "out of the scratchpad latches" $q_latch
    # sync: K - 1
    assert_clause_timing $tick [expr {$sync_k - 1}] "the latches into the dispatch memory's write" $q_latch \
        {*processor/dmem_reg*}
    # sync: K
    assert_clause_timing $tick $sync_k "the control store's word" \
        {*processor/imem_reg* *processor/imem_q_reg* *processor/prom_q_reg*}
    # sync: K
    assert_clause_timing $tick $sync_k "the maps' write" {*processor/l1_map_reg* *processor/l2_map_reg*}
    # sync: K
    assert_clause_timing $tick $sync_k "the dispatch memory's write" {*processor/dmem_reg*}
    # grid: 0 ns + 1 tick
    assert_clause_timing $tick 1 "the three memories' writes into the readout" \
        {*processor/l1_map_reg* *processor/l2_map_reg* *processor/dmem_reg*} \
        {*processor/ro_dmem_q_reg* *processor/ro_map1_q_reg* *processor/ro_map2_q_reg*}
    # sync: K
    assert_clause_timing $tick $sync_k "MD into the writes' address" {*processor/md_reg*} \
        {*processor/l1_map_reg* *processor/l2_map_reg* *processor/dmem_reg*}
    # grid: 0 ns + 1 tick
    assert_clause_timing $tick 1 "MD_HELD into MD" {*processor/md_held_reg*} {*processor/md_reg*}
    # grid: 0 ns + 1 tick
    assert_clause_timing $tick 1 "the stack's write into its latch" {*processor/spcm_reg*} \
        {*processor/spc_q_reg*}
    # sync: K - 2
    assert_clause_timing $tick [expr {$sync_k - 2}] "into the every-tick registers" \
        {*processor/ir_reg* *processor/vma_reg* *processor/memstart_reg* *processor/md_reg*} \
        {*processor/memgo_q_reg* *processor/destmem_q_reg* *processor/use_md_q_reg*
         *processor/ifetch_q_reg* *memory/is_memory_reg* *memory/device_reg* *memory/nxm_reg*
         *memory/unibus_reg* *memory/ub_addr_reg*}
    # grid: 0 ns + 2 ticks
    assert_clause_timing $tick 2 "the second hop of the every-tick registers" \
        {*processor/memgo_q_reg* *processor/destmem_q_reg* *processor/use_md_q_reg*
         *processor/ifetch_q_reg* *memory/is_memory_reg* *memory/device_reg* *memory/nxm_reg*
         *memory/unibus_reg* *memory/ub_addr_reg*}
    # sync: K
    assert_clause_timing $tick $sync_k "the edge's registers into QUUX's divider" \
        {*processor/q_reg* *processor/ir_reg*} {*processor/g_quux_muldiv.muldiv/dv_*}
    # sync: K - 1
    assert_clause_timing $tick [expr {$sync_k - 1}] "the latches into QUUX's divider" $q_latch \
        {*processor/g_quux_muldiv.muldiv/dv_*}
    # grid: 0 ns + 1 tick
    assert_clause_timing $tick 1 "MD_HELD into QUUX's divider" {*processor/md_held_reg*} \
        {*processor/g_quux_muldiv.muldiv/dv_*}
    # And what a microcycle reads of QUUX's clocks: the microsecond clock
    # the whole microcycle.  Source 17's status, which had a tick less, is
    # gone at revision 10 (contract Q11), and so is `L` into the flags a
    # page read takes: destination 3 writes only M, and nothing of `OB`
    # reaches the timers.
    # sync: K
    assert_clause_timing $tick $sync_k "the microsecond clock a microcycle reads" \
        {*processor/g_quux_tick.clocks/usec_s_reg*}
    # QUUX's memory port: none of its tick registers relaxed, and the address
    # the cache holds at the microcycle.
    # sync: K
    assert_instance_timing $tick $sync_k *memory/g_quux_port.port/* \
        {*cache/idx_q_reg* *cache/tag_q_reg* *cache/off_q_reg*}
    # And nothing out of the cache relaxed at all: its word reaches MD in the
    # tick after the lookup's.
    # grid: 0 ns + 1 tick
    assert_clause_timing $tick 1 "the cache's word into MD" \
        {*memory/g_quux_port.port/cache/*} {*processor/md_reg* *processor/md_held_reg*}
    puts "BIT: QUUX: [llength $quux_tick_cells] tick countdown cells"
}

opt_design
place_design
phys_opt_design
route_design
puts "BIT: implementation done [expr {[clock seconds] - $t0}] s after synthesis began"
write_checkpoint -force $outdir/routed.dcp

# THE MACHINE IS STILL THERE: logic, registers and block RAM by kind, the
# kinds named for both families.  A LUT is asked for by its cell name: on
# UltraScale+ its `PRIMITIVE_GROUP` is `CLB` and not `LUT`, and the first fit
# of this flow counted none that way.
set luts  [llength [get_cells -quiet -hier -filter {REF_NAME =~ LUT*}]]
set brams [llength [get_cells -quiet -hier -filter {PRIMITIVE_TYPE =~ BMEM.*.* || PRIMITIVE_TYPE =~ BLOCKRAM.BRAM.*}]]
set urams [llength [get_cells -quiet -hier -filter {PRIMITIVE_TYPE =~ BLOCKRAM.URAM.*}]]
set ffs   [llength [get_cells -quiet -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH || PRIMITIVE_GROUP == REGISTER}]]
puts "BIT: $luts LUTs, $ffs registers, $brams block RAMs, $urams UltraRAMs"
if {$luts < 1500 || $brams < 20 || $ffs < 1000} {
    puts "BIT: FAILED --- that is not the whole machine.  K1's out-of-context"
    puts "BIT: CADR on this part is 10,833 LUTs and 36.5 block RAM tiles."
    exit 1
}

report_utilization                     -file $outdir/utilisation.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file $outdir/utilisation_hier.rpt
report_timing_summary -max_paths 10    -file $outdir/timing.rpt
report_clocks                          -file $outdir/clocks.rpt
report_clock_interaction               -file $outdir/clock_interaction.rpt
report_timing -delay_type max -max_paths 20 -nworst 1 -unique_pins -file $outdir/worst_setup.rpt
report_timing -delay_type min -max_paths 10 -nworst 1 -file $outdir/worst_hold.rpt

set paths [get_timing_paths -quiet -max_paths 1 -delay_type max]
set holds [get_timing_paths -quiet -max_paths 1 -delay_type min]
if {[llength $holds]} {
    puts "BIT: worst hold slack [format %.3f [get_property SLACK [lindex $holds 0]]] ns"
}
if {[llength $paths]} {
    set wns [get_property SLACK [lindex $paths 0]]
    puts "BIT: worst slack [format %.3f $wns] ns"
    if {$wns < 0} {
        puts "BIT: TIMING IS NOT MET --- the bitstream below is of a design that"
        puts "BIT: does not close. It proves the flow, not the machine."
    } else {
        puts "BIT: timing is met"
    }
} else {
    puts "BIT: no timing path reported --- timing is met"
}

source [file join [file dirname [file normalize [info script]]] .. .. .. tools build_stamp.tcl]
set stamp [build_stamp_of_tree]
puts "BIT: build [lindex $stamp 0] --- commit [lindex $stamp 1], tree [lindex $stamp 2]"
build_stamp_apply [current_design] [lindex $stamp 0]

set bit $outdir/[expr {$machine eq "quux" ? "quux_kr260.bit" : "cadr_kr260.bit"}]
write_bitstream -force $bit
if {![file exists $bit]} {
    puts "BIT: FAILED --- write_bitstream left no file at $bit"
    exit 1
}
set size [file size $bit]
# The xck26's configuration is some 7.5 MB uncompressed.
if {$size < 5000000} {
    puts "BIT: FAILED --- $bit is $size bytes, too small to configure an xck26"
    exit 1
}
if {![build_stamp_stamped "BIT:" $bit $stamp]} { exit 1 }
puts "BIT: wrote $bit, $size bytes"
puts "BIT: part $part, reports in $outdir"

source boards/arty-z7-20/vivado/rams_enable_check.tcl
assert_rams_enabled_only_while_addressed $tick $bit
puts "BIT: DONE"
