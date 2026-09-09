# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Write the Zynq start-up routine, out of Digilent's own board configuration.
#
#     vivado -mode batch -source vivado/gen_ps7_init.tcl
#     # writes $OUTDIR/ps7_init.tcl, default build/ps7/ps7_init.tcl
#
# Run from the repository root. This is what makes DDR answer: programming a
# `.bit` over JTAG does not start the PS, so the memory controller, the three
# PLLs and the pin multiplexing stay unconfigured until this routine has been
# run over XSDB. The ordering is `ps7_init` -> program the `.bit` ->
# `ps7_post_config`, which is what post-config is named for --- it writes
# LVL_SHFTR_EN at 0xF8000900 and clears FPGA_RST_CTRL at 0xF8000240, and until
# then the PS-PL level shifters are off and `S_AXI_HP0` is dead.
#
# THE IP ROUTE IS AVAILABLE AT THE BASIC LICENCE: DECLINED FOR THE FABRIC,
# TAKEN FOR THIS. `rtl/cadr_ps7.sv` instantiates the PS7 primitive rather than
# the IP, because the IP adds nothing a hard block needs. But `create_ip` and
# `generate_target` check out no licence feature at all, and `ps7_init` is the
# one thing the IP produces that cannot be had any other way --- no XSA, no
# Vitis, no PetaLinux. Say which it is: declined there, taken here.
#
# WHAT IT GENERATES IS NOT CHECKED BY EYE. vivado/ps7_ops.py extracts the
# ordered register operations from the routine and compares them against the
# committed vivado/ps7_init.ops, so a change in Digilent's configuration or in
# Vivado's DDR part database fails `make current` instead of arriving silently
# in a bring-up.
#
# The IP instance may not be called `ps7`: `create_ip -module_name ps7` is
# refused with `[Common 17-69] IP instance name 'ps7' should not be a unisim
# module name`, PS7 being the primitive. Hence `cadr_ps7_ip`, which is also
# not `cadr_ps7` --- that name is the fabric wrapper `vivado/gen_ps7.py`
# writes, and two different things must not share one name.

set part   [expr {[info exists ::env(PART)]   ? $::env(PART)   : "xc7z020clg400-1"}]
set outdir [expr {[info exists ::env(OUTDIR)] ? $::env(OUTDIR) : "build/ps7"}]

set ipdir $outdir/ip
file delete -force $ipdir
file mkdir $ipdir

source vivado/ps7_config.tcl
if {![info exists ps7_config]} {
    puts "gen_ps7_init: vivado/ps7_config.tcl set no ps7_config"
    exit 1
}

create_project -in_memory -part $part
create_ip -name processing_system7 -vendor xilinx.com -library ip \
    -module_name cadr_ps7_ip -dir $ipdir
set_property -dict $ps7_config [get_ips cadr_ps7_ip]
generate_target all [get_files $ipdir/cadr_ps7_ip/cadr_ps7_ip.xci]

# The routine, and the two C forms of the same table beside it: `ps7_init.c`
# is Xilinx's under MIT, `ps7_init_gpl.c` the same data under GPL-2.0-or-later,
# and an FSBL of our own would take one of them. The .tcl carries no licence
# header of any kind; it is the one XSDB sources.
set src $ipdir/cadr_ps7_ip
foreach f {ps7_init.tcl ps7_init.c ps7_init.h ps7_init_gpl.c ps7_init_gpl.h} {
    if {![file exists $src/$f]} {
        puts "gen_ps7_init: the IP wrote no $f"
        exit 1
    }
    file copy -force $src/$f $outdir/$f
}

# A generated routine that says nothing is indistinguishable from one that did
# nothing, and `ps7_init` itself prints nothing --- Xilinx comments out its own
# `puts "PCW Silicon Version : ..."`. So this says what it wrote and how big.
set n [llength [split [read [set fh [open $outdir/ps7_init.tcl]]] "\n"]]
close $fh
puts "gen_ps7_init: wrote $outdir/ps7_init.tcl, $n lines"
puts "gen_ps7_init: ok"
