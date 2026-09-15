# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Generate the DDR3L controller for this board, in batch, from a project file.
#
# THIS IS THE PROJECT'S ONE GENERATED-IP EXCEPTION AND IT IS A DECIDED ONE.
# Everything else Xilinx offers as a directory of generated XML has been
# declined here and hand-built instead: the clock generator is an
# `MMCME2_BASE`, the capture instrument is a `BSCANE2` and a shift register,
# the processing system is a `PS7`.  Each of those is one primitive in a file
# somebody can read.  A DDR3 controller is not: it is a calibration state
# machine, a PHY with per-bit deskew, a refresh and bank manager and a write
# leveling sequence, and nothing in this repository could hold a hand-written
# one to anything.  So the Memory Interface Generator is taken.
#
# WHAT KEEPS IT HONEST.  The input is a text file in the repository, the run
# is a script with no project saved and no graphical tool anywhere, and the
# output is committed.  `python3 boards/arty-a7-100/vivado/mig_check.py` --- which
# `make current` runs --- regenerates into a scratch directory and compares,
# so a generated file that is not what the generator writes today is a
# failure and not a surprise.  That is the same shape as `gen_ps7.py`.
#
# WHERE THE PROJECT FILE CAME FROM, and it is not written here from memory.
# `boards/arty-a7-100/mig/mig-digilent-E.0-1.1.prj` is Digilent's own published
# file for this board, byte for byte, and its provenance is in
# `boards/arty-a7-100/mig/README.md`.  `mig.prj` is that file with three
# changes and nothing else, which `mig_check.py` also asserts:
#
#   * the system clock is "No Buffer" rather than "Single-Ended", and the pad
#     element that named E3 is gone.  The board has ONE oscillator and this
#     design's top level already owns it: `cadr_arty_a7.sv`'s single
#     `MMCME2_BASE` takes E3 and makes the machine's 10 ns tick from it.  Two
#     input buffers on one pad is an error, and `boards/arty-z7-20/vivado/tick.tcl`
#     --- which every board's flow hands its top level to --- allows exactly
#     one MMCM in that file.  So the controller is fed a clock this design
#     makes rather than taking the pin for itself.
#   * the port interface is the native user interface rather than the AXI4
#     slave, and the AXI parameter block is gone.
#     `rtl/plumbing/cadr_mig_ui.sv`'s header has the argument.
#
# Run:  vivado -mode batch -source boards/arty-a7-100/vivado/mig.tcl
# Or with an output directory of its own, which is what the check does:
#       OUTDIR=... vivado -mode batch -source boards/arty-a7-100/vivado/mig.tcl

set part      xc7a100tcsg324-1
set ip_name   cadr_mig_a7
set prj_file  [file normalize boards/arty-a7-100/mig/mig.prj]
set outdir    [expr {[info exists ::env(OUTDIR)] ? $::env(OUTDIR)
                                                 : "boards/arty-a7-100/mig/gen"}]

if {![file exists $prj_file]} {
    puts "MIG: no project file at $prj_file"
    exit 1
}

# No project on disk.  An in-memory project is a part and a set of properties
# and nothing else, so nothing here can be opened in a graphical tool later and
# quietly diverge from what this script says.
create_project -in_memory -part $part

# The generator writes a great deal more than a design needs, and some of it
# cannot be reproduced: a date stamp in two constraint files, a directory
# listing in another, absolute paths in the tool's own scratch, and a hash in
# the packaging XML.  **A generated file that cannot be regenerated identically
# cannot be checked**, so it is not kept: what is copied out below is the
# design's own Verilog and constraints, the instantiation template a reader
# checks the wrapper against, the datasheet that says what was configured, and
# the project file the generator actually consumed.  Everything else --- the
# example design and its traffic generator, the simulation scripts, the
# packaging XML --- belongs to a design nobody here builds.
set work $outdir/_work
file delete -force $work
file mkdir $work
create_ip -name mig_7series -vendor xilinx.com -library ip \
    -module_name $ip_name -dir $work

set ip [get_ips $ip_name]
set_property -dict [list CONFIG.XML_INPUT_FILE $prj_file] $ip
generate_target all $ip

set src $work/$ip_name/$ip_name
foreach d {rtl constraints} {
    file delete -force $outdir/$d
    file copy -force $src/user_design/$d $outdir/$d
}
foreach f [list [list $work/$ip_name/$ip_name.veo $outdir/$ip_name.veo] \
                [list $src/datasheet.txt          $outdir/datasheet.txt] \
                [list $src/mig.prj                $outdir/mig-as-read.prj]] {
    file delete -force [lindex $f 1]
    file copy -force [lindex $f 0] [lindex $f 1]
}
file delete -force $work

puts "MIG: generated into $outdir"
exit 0
