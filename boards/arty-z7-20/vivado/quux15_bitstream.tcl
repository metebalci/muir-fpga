# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build a bitstream of QUUX revision 15 for the Arty Z7-20
# (`boards/arty-z7-20/quux15_arty.sv`).
#
#     make build/boot_prom.quux15.hex
#     PERIOD_NS=48 vivado -mode batch -source boards/arty-z7-20/vivado/quux15_bitstream.tcl
#
# Run from the repository root.  `PERIOD_NS` is the machine's period, the
# MMCM's divide (48 by default, where MP8's trial fit closed); `PROM` the boot
# PROM's image, a 64-bit word a line, PROM 2002 (`build/boot_prom.quux15.hex`)
# by default and a test program (`golden/src/quux15.rs --prom`) only when
# named; `OUTDIR` where it all goes (`build/bitstream-arty-quux15`).  The
# memories are placed as `quux15_ram.xdc` says, and asked after synthesis;
# the report says the period the fit met and the area, and the bitstream
# carries the tree's build stamp.  It is the Kria KR260's flow
# (`boards/kria-kr260/vivado/quux15_bitstream.tcl`) on this part, with the
# board's pins, the display's clocks as `bitstream.tcl` asserts them, a floor
# under the machine's size, and `rams_enable_check.tcl` last.
set part    [expr {[info exists ::env(PART)]      ? $::env(PART)      : "xc7z020clg400-1"}]
set period  [expr {[info exists ::env(PERIOD_NS)] ? $::env(PERIOD_NS) : 48}]
set prom    [expr {[info exists ::env(PROM)]      ? $::env(PROM)      : "build/boot_prom.quux15.hex"}]
set outdir  [expr {[info exists ::env(OUTDIR)]    ? $::env(OUTDIR)    : "build/bitstream-arty-quux15"}]
if {[info exists ::env(VIVADO_THREADS)]} { set_param general.maxThreads $::env(VIVADO_THREADS) }
# The core's `period` is seven bits of 0.5 ns, up to 63.5 ns, and the MMCM
# divides a 1,000 MHz VCO by a whole number here.
if {![string is integer -strict $period] || $period < 8 || $period > 63} {
    puts "Q15ARTY: FAILED --- PERIOD_NS=$period is not a period in whole nanoseconds from 8 to 63"
    exit 1
}
if {![file exists $prom]} {
    puts "Q15ARTY: $prom is missing; run `make $prom` first"
    exit 1
}
file mkdir $outdir
puts "Q15ARTY: QUUX revision 15 on the Arty Z7-20 at $period ns, the PROM $prom"

set sources [list \
    rtl/machine/cadr_tick_pkg.sv rtl/plumbing/cadr_ddr_map.sv \
    rtl/machine/quux15_ram.sv rtl/machine/quux15_tdp.sv rtl/machine/quux15_store.sv \
    rtl/machine/quux15_exec.sv rtl/machine/quux_muldiv.sv rtl/plumbing/quux15_axi_master.sv \
    rtl/machine/quux15_port.sv rtl/machine/quux15_mmu.sv rtl/machine/quux15_devices.sv \
    rtl/machine/quux15_validmap.sv rtl/machine/quux15_recency.sv rtl/machine/quux15_core.sv rtl/machine/quux15_mdmem.sv rtl/machine/quux15_dmem.sv \
    rtl/machine/quux15_block_walk.sv rtl/machine/quux15_input.sv rtl/machine/quux15_chaos.sv \
    rtl/plumbing/cadr_input_cables.sv rtl/plumbing/quux15_axi3.sv \
    rtl/plumbing/cadr_gp0_default.sv rtl/plumbing/cadr_gp1_split.sv rtl/plumbing/cadr_gp_regs.sv \
    rtl/plumbing/cadr_gp0_split.sv rtl/plumbing/cadr_disk_pack.sv \
    rtl/plumbing/quux15_face.sv rtl/plumbing/cadr_mem_count.sv rtl/plumbing/xilinx7/cadr_usr_access.sv \
    rtl/plumbing/quux_fd_face.sv rtl/plumbing/cadr_display_out.sv rtl/plumbing/cadr_tmds_encode.sv \
    rtl/plumbing/cadr_hdmi_tx.sv rtl/plumbing/xilinx7/cadr_hdmi_phy.sv \
    rtl/plumbing/cadr_lamp_clock.sv rtl/plumbing/cadr_lamp_microcycle.sv \
    boards/arty-z7-20/cadr_ps7.sv boards/arty-z7-20/quux15_arty.sv]
read_verilog -sv $sources
read_xdc -unmanaged boards/arty-z7-20/vivado/quux15_ram.xdc
set t0 [clock seconds]
synth_design -top quux15_arty -part $part -include_dirs rtl/machine \
    -generic PROM_HEX=[file normalize $prom] \
    -generic PERIOD_NS=$period
puts "Q15ARTY: synthesis took [expr {[clock seconds] - $t0}] s"
report_utilization -file $outdir/util_synth.rpt

# THE BOARD'S PINS, `cadr_arty.sv`'s file, which this top's port list
# matches; and THE DISPLAY OUTPUT'S CLOCKS AND CROSSINGS, the same module's
# file as an `HDMI=1` board reads it, with the assertions that file cannot
# make for itself, as `bitstream.tcl` makes them: that the three clocks
# exist, and that each bound named a register.  This machine has no color
# board, so the map's bound names nothing and is not asked for.
read_xdc boards/arty-z7-20/cadr_arty.xdc
read_xdc rtl/plumbing/xilinx7/cadr_hdmi.xdc
foreach c {clk_raw pixel_raw serial_raw} {
    if {[llength [get_clocks -quiet $c]] != 1} {
        puts "Q15ARTY: FAILED --- no clock `$c`: rtl/plumbing/xilinx7/cadr_hdmi.xdc names"
        puts "Q15ARTY: the machine's and the display MMCM's outputs by their nets"
        exit 1
    }
}
set disp_bound 0
foreach pat {*req_addr_reg* *slp_want_reg* *slp_want_s1_reg* *slp_mute_reg* *slp_mute_s1_reg*} {
    set found [get_cells -quiet -hier -filter "NAME =~ $pat"]
    if {[llength $found] == 0} {
        puts "Q15ARTY: FAILED --- no register matching $pat, so a bound in"
        puts "Q15ARTY: rtl/plumbing/xilinx7/cadr_hdmi.xdc named nothing"
        exit 1
    }
    incr disp_bound [llength $found]
}
puts "Q15ARTY: the display's clocks grouped apart from the machine's; $disp_bound register(s) of its crossings named"

# The memories where `quux15_ram.xdc` puts them: the control store, each way
# of the cache's lines and each TLB in block RAM, none of them left in LUTs.
set rams_ok 1
foreach {what pat} {
    "the control store"  *u_core/store/ram/*
    "the lines, way 0"   *u_core/port/lines0/*
    "the lines, way 1"   *u_core/port/lines1/*
    "the TLB, port A"    *u_core/mmu/tlb_a/*
    "the TLB, port B"    *u_core/mmu/tlb_b/*} {
    set bmem [llength [get_cells -hier -quiet -filter "PRIMITIVE_TYPE =~ BMEM.*.* && NAME =~ $pat"]]
    set dmem [llength [get_cells -hier -quiet -filter "PRIMITIVE_GROUP == DMEM && NAME =~ $pat"]]
    puts "Q15ARTY: $what: $bmem block RAM cell(s), $dmem LUT RAM cell(s)"
    if {$bmem == 0 || $dmem != 0} { set rams_ok 0 }
}
if {!$rams_ok} {
    puts "Q15ARTY: FAILED --- a memory is not in block RAM as quux15_ram.xdc says"
    exit 1
}

# **THE MACRO DISPATCH MEMORY READ AT ITS FOUR ADDRESSES** (`quux15_mdmem.sv`;
# `tools/quux15_lutram_ports.tcl`): RD's, EX's, D's and the readout's, each
# its own read port in LUT RAM.  The redirect's fifth feeds nothing with one
# bubble, so four, and a build with fewer reads one address at another's.
source tools/quux15_lutram_ports.tcl
lassign [quux15_lutram_read_ports *u_core/u_mdmem/* [expr {1024 * 18}]] md_cells md_ports
puts "Q15ARTY: the macro dispatch memory: $md_cells LUT RAM cell(s), $md_ports read port(s)"
if {$md_ports < 4} {
    puts "Q15ARTY: FAILED --- the macro dispatch memory is built with $md_ports read port(s), and its RTL reads it at 4"
    exit 1
}

# opt_design's phases without its BRAM power optimization: with PROM 2002 as
# the boot PROM, Vivado 2026.1 segfaults in that step (libxv_pwropt, in the
# cleanup after an HACOOException).
opt_design -retarget -propconst -sweep -bufg_opt -shift_register_opt
place_design
phys_opt_design
route_design
puts "Q15ARTY: implementation took [expr {[clock seconds] - $t0}] s"
write_checkpoint -force $outdir/routed.dcp
report_timing_summary -max_paths 20 -file $outdir/timing.rpt
report_timing -max_paths 50 -nworst 1 -unique_pins -file $outdir/paths.rpt
report_utilization -file $outdir/util.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file $outdir/util_hier.rpt
report_ram_utilization -file $outdir/ram.rpt
report_clocks -file $outdir/clocks.rpt
set wns [get_property SLACK [get_timing_paths -setup -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -hold -max_paths 1]]
# The area as the utilization report counts it: LUTs and registers of the
# slices, block RAM tiles (36 Kb each, a half for 18 Kb), DSPs.
set util [report_utilization -return_string]
proc util_of {util row} {
    if {[regexp "\\|\\s*$row\\s*\\|\\s*(\[0-9.\]+)" $util -> n]} { return $n }
    return "?"
}
set luts  [util_of $util {Slice LUTs\*?}]
set ffs   [util_of $util {Slice Registers}]
set brams [util_of $util {Block RAM Tile}]
set dsps  [util_of $util {DSPs}]
puts "Q15ARTY: FIT period=$period ns WNS=$wns WHS=$whs LUT=$luts FF=$ffs BRAM=$brams DSP=$dsps"

# **IS THE MACHINE STILL THERE?**  A floor an order under the trial fit's
# figures (MP8 step 0: about 29,000 LUTs and 93.5 tiles at 48 ns), so that a
# datapath optimized away is refused and the next revision is not.
if {$luts eq "?" || $brams eq "?" || $luts < 15000 || $brams < 50} {
    puts "Q15ARTY: FAILED --- $luts LUTs and $brams block RAM tiles is not the whole machine"
    exit 1
}

source tools/build_stamp.tcl
set stamp [build_stamp_of_tree]
puts "Q15ARTY: build [lindex $stamp 0] --- commit [lindex $stamp 1], tree [lindex $stamp 2]"
build_stamp_apply [current_design] [lindex $stamp 0]
set bit $outdir/quux15_arty.bit
if {$wns < 0} {
    puts "Q15ARTY: the fit misses $period ns by [expr {-$wns}] ns: no bitstream written"
} else {
    write_bitstream -force $bit
    if {![build_stamp_stamped "Q15ARTY:" $bit $stamp]} { exit 1 }
    puts "Q15ARTY: wrote $bit"
    # **IS EVERY BLOCK RAM'S ADDRESS STILL WHENEVER THE RAM IS ENABLED?**
    # Asked last, because it drops the design's timing constraints to ask
    # (`rams_enable_check.tcl`): revision 15 is timed at one clock with no
    # exception into a RAM, so every port is asked at the period.  A build
    # that fails it loses the bitstream written above.
    source boards/arty-z7-20/vivado/rams_enable_check.tcl
    assert_rams_enabled_only_while_addressed $period $bit
}
puts "Q15ARTY: DONE"
