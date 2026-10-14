# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build a bitstream of QUUX revision 15 for the Kria KR260
# (`boards/kria-kr260/quux15_kr260.sv`).
#
#     make build/quux15_transfer_prom.hex
#     PERIOD_NS=13 vivado -mode batch -source boards/kria-kr260/vivado/quux15_bitstream.tcl
#
# Run from the repository root.  `PERIOD_NS` is the machine's period, the
# MMCM's divide (13 by default); `PROM` the boot PROM's image, a 64-bit word
# a line (`golden/src/quux15.rs --prom`); `OUTDIR` where it all goes
# (`build/bitstream-kr260-quux15`).  The memories are placed as
# `quux15_ram.xdc` says; the report says the period the fit met and the
# area, and the bitstream carries the tree's build stamp.
set part    [expr {[info exists ::env(PART)]      ? $::env(PART)      : "xck26-sfvc784-2LV-c"}]
set period  [expr {[info exists ::env(PERIOD_NS)] ? $::env(PERIOD_NS) : 13}]
set prom    [expr {[info exists ::env(PROM)]      ? $::env(PROM)      : "build/quux15_transfer_prom.hex"}]
set outdir  [expr {[info exists ::env(OUTDIR)]    ? $::env(OUTDIR)    : "build/bitstream-kr260-quux15"}]
if {[info exists ::env(VIVADO_THREADS)]} { set_param general.maxThreads $::env(VIVADO_THREADS) }
if {![string is integer -strict $period] || $period < 8 || $period > 40} {
    puts "Q15BIT: FAILED --- PERIOD_NS=$period is not a period in whole nanoseconds from 8 to 40"
    exit 1
}
if {![file exists $prom]} {
    puts "Q15BIT: $prom is missing; run `make $prom` first"
    exit 1
}
file mkdir $outdir
puts "Q15BIT: QUUX revision 15 on the Kria KR260 at $period ns, the PROM $prom"

set sources [list \
    rtl/machine/cadr_tick_pkg.sv rtl/plumbing/cadr_ddr_map.sv \
    rtl/machine/quux15_ram.sv rtl/machine/quux15_tdp.sv rtl/machine/quux15_store.sv \
    rtl/machine/quux15_exec.sv rtl/machine/quux_muldiv.sv rtl/plumbing/quux15_axi_master.sv \
    rtl/machine/quux15_port.sv rtl/machine/quux15_mmu.sv rtl/machine/quux15_devices.sv \
    rtl/machine/quux15_validmap.sv rtl/machine/quux15_recency.sv rtl/machine/quux15_core.sv rtl/machine/quux15_mdmem.sv rtl/machine/quux15_dmem.sv \
    rtl/machine/quux15_block_walk.sv rtl/machine/quux15_input.sv rtl/machine/quux15_chaos.sv \
    rtl/plumbing/cadr_input_cables.sv \
    rtl/plumbing/quux_axi_narrow128.sv rtl/plumbing/cadr_axi_lanes128.sv \
    rtl/plumbing/cadr_gp0_default.sv rtl/plumbing/cadr_gp1_split.sv rtl/plumbing/cadr_gp_regs.sv \
    rtl/plumbing/cadr_gp0_split.sv rtl/plumbing/cadr_disk_pack.sv rtl/plumbing/cadr_axi_burst128.sv \
    rtl/plumbing/quux15_face.sv rtl/plumbing/cadr_mem_count.sv rtl/plumbing/xilinx7/cadr_usr_access.sv \
    rtl/plumbing/quux_fd_face.sv rtl/plumbing/cadr_display_out.sv rtl/plumbing/cadr_axi_rd128.sv \
    boards/kria-kr260/cadr_kr260_pixel_clock.sv rtl/plumbing/cadr_lamp_microcycle.sv \
    boards/kria-kr260/cadr_ps8.sv boards/kria-kr260/quux15_kr260.sv]
read_verilog -sv $sources
read_xdc -unmanaged boards/kria-kr260/vivado/quux15_ram.xdc
set t0 [clock seconds]
synth_design -top quux15_kr260 -part $part -include_dirs rtl/machine \
    -verilog_define CADR_DDR_MAP_KR260=1 \
    -generic PROM_HEX=[file normalize $prom] \
    -generic PERIOD_NS=$period
puts "Q15BIT: synthesis took [expr {[clock seconds] - $t0}] s"
report_utilization -file $outdir/util_synth.rpt
read_xdc boards/kria-kr260/quux15_kr260.xdc
# THE DISPLAY OUTPUT'S CLOCKS AND CROSSINGS, `cadr_kr260.sv`'s file for the
# same module, and the assertions that file cannot make for itself, as
# `bitstream.tcl` makes them: that the two clocks exist, that each bound
# named a register, and the PS8's 39 live video pins.  This machine has no
# color board, so the map's bound names nothing and is not asked for.
read_xdc boards/kria-kr260/cadr_kr260_display.xdc
foreach c {clk_raw pixel_raw} {
    if {[llength [get_clocks -quiet $c]] != 1} {
        puts "Q15BIT: FAILED --- no clock `$c`: boards/kria-kr260/cadr_kr260_display.xdc names"
        puts "Q15BIT: the machine's and the pixel MMCM's outputs by their nets"
        exit 1
    }
}
set disp_bound 0
foreach pat {*req_addr_reg* *slp_want_reg* *slp_want_s1_reg* *slp_mute_reg* *slp_mute_s1_reg*} {
    set found [get_cells -quiet -hier -filter "NAME =~ $pat"]
    if {[llength $found] == 0} {
        puts "Q15BIT: FAILED --- no register matching $pat, so a bound in"
        puts "Q15BIT: boards/kria-kr260/cadr_kr260_display.xdc named nothing"
        exit 1
    }
    incr disp_bound [llength $found]
}
set live [get_pins -quiet -hier -filter {NAME =~ *u_ps8/u_ps8/DPLIVEVIDEOIN*}]
if {[llength $live] != 39} {
    puts "Q15BIT: FAILED --- [llength $live] live video pins on the PS8, want 39"
    exit 1
}
puts "Q15BIT: the display's pixel clock grouped apart from the machine's; $disp_bound register(s) of its crossings named; 39 live video pins"

# The memories where `quux15_ram.xdc` puts them: the store and the lines in
# UltraRAM.
set urams [llength [get_cells -hier -quiet -filter {PRIMITIVE_TYPE =~ BLOCKRAM.URAM.*}]]
if {$urams == 0} {
    puts "Q15BIT: FAILED --- no UltraRAM in the netlist: the store and the lines are not placed as quux15_ram.xdc says"
    exit 1
}
puts "Q15BIT: $urams UltraRAM cells"

# **THE MACRO DISPATCH MEMORY READ AT ITS FOUR ADDRESSES** (`quux15_mdmem.sv`;
# `tools/quux15_lutram_ports.tcl`): RD's, EX's, D's and the readout's, each
# its own read port in LUT RAM.  The redirect's fifth feeds nothing with one
# bubble, so four, and a build with fewer reads one address at another's.
source tools/quux15_lutram_ports.tcl
lassign [quux15_lutram_read_ports *u_core/u_mdmem/* [expr {1024 * 18}]] md_cells md_ports
puts "Q15BIT: the macro dispatch memory: $md_cells LUT RAM cell(s), $md_ports read port(s)"
if {$md_ports < 4} {
    puts "Q15BIT: FAILED --- the macro dispatch memory is built with $md_ports read port(s), and its RTL reads it at 4"
    exit 1
}

opt_design
place_design
phys_opt_design
route_design
puts "Q15BIT: implementation took [expr {[clock seconds] - $t0}] s"
write_checkpoint -force $outdir/routed.dcp
report_timing_summary -max_paths 20 -file $outdir/timing.rpt
report_timing -max_paths 50 -nworst 1 -unique_pins -file $outdir/paths.rpt
report_utilization -file $outdir/util.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file $outdir/util_hier.rpt
report_clocks -file $outdir/clocks.rpt
set wns [get_property SLACK [get_timing_paths -setup -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -hold -max_paths 1]]
# The area as the utilization report counts it: LUTs and registers of the
# CLBs, block RAM tiles (36 Kb each, a half for 18 Kb), UltraRAMs.
set util [report_utilization -return_string]
proc util_of {util row} {
    if {[regexp "\\|\\s*$row\\s*\\|\\s*(\[0-9.\]+)" $util -> n]} { return $n }
    return "?"
}
set luts  [util_of $util {CLB LUTs\*?}]
set ffs   [util_of $util {CLB Registers}]
set brams [util_of $util {Block RAM Tile}]
set uramt [util_of $util {URAM}]
puts "Q15BIT: FIT period=$period ns WNS=$wns WHS=$whs LUT=$luts FF=$ffs BRAM=$brams URAM=$uramt"

source tools/build_stamp.tcl
set stamp [build_stamp_of_tree]
puts "Q15BIT: build [lindex $stamp 0] --- commit [lindex $stamp 1], tree [lindex $stamp 2]"
build_stamp_apply [current_design] [lindex $stamp 0]
set bit $outdir/quux15_kr260.bit
if {$wns < 0} {
    puts "Q15BIT: the fit misses $period ns by [expr {-$wns}] ns: no bitstream written"
} else {
    write_bitstream -force $bit
    if {![build_stamp_stamped "Q15BIT:" $bit $stamp]} { exit 1 }
    puts "Q15BIT: wrote $bit"
}
puts "Q15BIT: DONE"
