# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The DE25-Nano's Quartus project, written from nothing at every build.
#
# Run by `boards/de25-nano/quartus/build.sh` as
#
#     quartus_sh -t boards/de25-nano/quartus/project.tcl <build dir> <userid> <source>...
#
# from the repository's root.  The sources are the Makefile's
# `$(MACHINE_SRC)` and `$(DE25_TOP)`, in that order, then `$(DE25_PROBE)` when the probe is built
# and `$(DE25_DDR)` when the memory board is, so that the list of what the
# board is built from is written once, beside the lint that reads the same
# list.  `PROBE_DEPTH` in the environment is the probe's depth, and zero or
# none is the plain board; `DDR` is 1 for the memory board.
#
# **NOTHING HERE IS TAKEN FROM A GUI-SAVED PROJECT.**  A `.qsf` saved by the
# tool carries dates, versions and every default it happened to write, and
# none of that is a decision.  Each assignment below is here for a reason
# given beside it.

package require ::quartus::project

set argv $quartus(args)
if {[llength $argv] < 3} {
    puts "project: usage: project.tcl <build dir> <userid> <source>..."
    exit 1
}
set build   [file normalize [lindex $argv 0]]
set probe_depth [expr {[info exists ::env(PROBE_DEPTH)] ? $::env(PROBE_DEPTH) : 0}]
if {![string is integer -strict $probe_depth] || $probe_depth < 0} {
    puts "project: PROBE_DEPTH is '$probe_depth', which is not a depth"
    exit 1
}
set ddr [expr {[info exists ::env(DDR)] ? $::env(DDR) : 0}]
if {$ddr ne "0" && $ddr ne "1"} {
    puts "project: DDR is '$ddr', which is neither 0 nor 1"
    exit 1
}
set hdmi [expr {[info exists ::env(HDMI)] ? $::env(HDMI) : 0}]
if {$hdmi ne "0" && $hdmi ne "1"} {
    puts "project: HDMI is '$hdmi', which is neither 0 nor 1"
    exit 1
}
if {$hdmi && !$ddr} {
    puts "project: HDMI needs DDR: the display reads the machine's memory"
    exit 1
}
# The fault bitstream: `boards/de25-nano/cadr_de25_fault.sv`, the memory
# board's pins and processor system with no machine.  `build.sh` says what
# it is and refuses it without `DDR=1`.
set fault [expr {[info exists ::env(FAULT)] ? $::env(FAULT) : 0}]
if {$fault ne "0" && $fault ne "1"} {
    puts "project: FAULT is '$fault', which is neither 0 nor 1"
    exit 1
}
if {$fault && (!$ddr || $hdmi || $probe_depth > 0)} {
    puts "project: FAULT needs DDR and takes neither HDMI nor a probe"
    exit 1
}
set machine [expr {[info exists ::env(MACHINE)] ? $::env(MACHINE) : "cadr"}]
if {$machine ne "cadr" && $machine ne "quux"} {
    puts "project: MACHINE is '$machine', which is neither cadr nor quux"
    exit 1
}
if {$fault && $machine ne "cadr"} {
    puts "project: FAULT takes no MACHINE=$machine: the fault bitstream carries no machine"
    exit 1
}
set userid  [lindex $argv 1]
set sources [lrange $argv 2 end]
set root    [pwd]

if {![regexp {^[0-9a-f]{8}$} $userid]} {
    puts "project: the build stamp must be eight hex digits, not '$userid'"
    exit 1
}

cd $build
project_new -overwrite cadr_de25

# ------------------------------------------------------------------ the part
#
# The part and its family are the resource package's and the user manual's;
# `boards/de25-nano/README.md` says where each is read.
set_global_assignment -name FAMILY "Agilex 5"
set_global_assignment -name DEVICE A5EB013BB23BE4SCS
if {$fault} {
    set_global_assignment -name TOP_LEVEL_ENTITY cadr_de25_fault
} else {
    set_global_assignment -name TOP_LEVEL_ENTITY cadr_de25
}
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files
# Two other build flows can share this machine, and the fitter takes every
# core it is offered. Sixteen is the share a build here is allowed, on a
# machine of twenty-four, so the rest stays usable while a fit runs.
set_global_assignment -name NUM_PARALLEL_PROCESSORS 16
# **THE CONTROL STORE COMES UP ALL ONES**, written by a loop over its 16,384
# words in `rtl/machine/cadr_microcycle.sv`'s `initial` block, and Quartus
# refuses a constant loop longer than 5,000 iterations by default (error
# 13356).  The limit is raised to exactly that loop's length, so a longer one
# is still refused rather than waved through.
set_global_assignment -name VERILOG_CONSTANT_LOOP_LIMIT 16384
# **NO REGISTER IS GIVEN A POWER-UP LEVEL THE DESIGN DID NOT ASK FOR.**  With
# this on, which is Quartus's default, a register that has no power-up level
# may be given either one to save area.  The machine is checked in Verilator,
# and built for the Zynq boards by Vivado, with every register it does not
# reset starting at zero, so the compiler is not allowed to choose here.
set_global_assignment -name ALLOW_POWER_UP_DONT_CARE OFF
# **NO RETIMING.**  Quartus moves registers across logic by default, and the
# first fit here had moved 233 of them, `md[14]~RTM` among them.  The
# machine's timing exceptions in `cadr_de25.sdc` name registers by what they
# are in the design, as `cadr_machine.xdc` does for Vivado, which does not
# retime, and a register moved across the logic between two of them is no
# longer the register the exception's argument is about.  So registers, RAM
# blocks and DSP blocks all stay where the design puts them.
set_global_assignment -name ALLOW_REGISTER_RETIMING OFF
set_global_assignment -name ALLOW_RAM_RETIMING OFF
set_global_assignment -name ALLOW_DSP_RETIMING OFF

# ------------------------------------------------------------- the sources
foreach f $sources {
    set_global_assignment -name SYSTEMVERILOG_FILE [file join $root $f]
}
# The I/O PLL and the Reset Release, deployed into this directory by
# `build.sh`, and generated by `quartus_ipgenerate`.
set_global_assignment -name IP_FILE [file join $build ip cadr_de25_pll.ip]
set_global_assignment -name IP_FILE [file join $build ip cadr_de25_reset_release.ip]
# The fault bitstream has no machine for `cadr_de25.sdc` and `cadr_ddr.sdc`
# to relax; its own file keeps their treatment of the pins and of the
# processor's asynchronous signals.
if {$fault} {
    set_global_assignment -name SDC_FILE [file join $root boards de25-nano quartus cadr_de25_fault.sdc]
} else {
    set_global_assignment -name SDC_FILE [file join $root boards de25-nano quartus cadr_de25.sdc]
    # QUUX's own two clauses, which would reach every path on the CADR.
    if {$machine eq "quux"} {
        set_global_assignment -name SDC_FILE [file join $root boards de25-nano quartus quux_de25.sdc]
    }
}

# **THE BOARD'S MAP OF THE PROCESSOR'S MEMORY, ALWAYS**, and the memory board's
# processor, pins and constraints when it is built.  `rtl/plumbing/cadr_ddr_map.sv`
# chooses the DE25-Nano's base by the first define, and the top level refuses
# to elaborate without it; the second is `boards/de25-nano/cadr_de25.sv`'s own
# switch for the memory board, which changes its port list.  `cadr_ddr.sdc`
# is read only when the memory port is in the design, for the reason the
# probe's file below is.  The processor system itself is added to the
# project by `build.sh`, which builds it after this.
set_global_assignment -name VERILOG_MACRO "CADR_DDR_MAP_DE25_NANO=1"
if {$ddr && !$fault} {
    set_global_assignment -name VERILOG_MACRO "CADR_DE25_DDR=1"
    set_global_assignment -name SDC_FILE [file join $root boards de25-nano quartus cadr_ddr.sdc]
}

# **THE DISPLAY OUTPUT, ITS PIXEL CLOCK AND ITS OWN CONSTRAINTS**, only when
# it is built, for the reason the probe's files below are read only behind
# `PROBE_DEPTH`: a constraint on something that is not in the design is a
# warning that reads like a constraint that applied.  The define is the top
# level's switch for the video pins, which changes its port list, and
# `boards/de25-nano/quartus/build.sh` asks the PLL generator for the video
# mode's own frequency.
if {$hdmi} {
    set_global_assignment -name VERILOG_MACRO "CADR_DE25_HDMI=1"
    set_global_assignment -name IP_FILE [file join $build ip cadr_de25_pixel_pll.ip]
    set_global_assignment -name SDC_FILE [file join $root boards de25-nano quartus cadr_hdmi.sdc]
}

# **THE PROBE, AND ITS OWN CONSTRAINTS, ONLY WHEN IT IS BUILT.**  The Virtual
# JTAG IP deployed by `build.sh`, the depth as the top level's parameter, and
# `cadr_probe.sdc`, which declares the JTAG clock and relaxes one register of
# the probe.  That file is read only here for the reason the Zynq flows read
# theirs only behind `PROBE_DEPTH`: a constraint on something that is not in
# the design is a warning that reads like a constraint that applied.
if {$probe_depth > 0} {
    set_global_assignment -name IP_FILE [file join $build ip cadr_de25_vjtag.ip]
    set_global_assignment -name SDC_FILE [file join $root boards de25-nano quartus cadr_probe.sdc]
    set_parameter -name PROBE_DEPTH $probe_depth
}

# ------------------------------------------- the three asynchronous memories
#
# **THE DISPATCH MEMORY AND BOTH LEVELS OF THE MAP ARE MLABS, AND NOTHING IN
# `rtl/` SAYS SO.**  `rtl/machine/cadr_microcycle.sv` reads the three
# asynchronously, as MIT's board does, and by default Quartus builds an
# asynchronously read array out of registers (info 276007): about 70,000 of
# them and three quarters of the part, measured.  Altera's Agilex 5 embedded
# memory guide (document 813901, the features table) gives the MLAB, and only
# the MLAB, "asynchronous memory ... for flow-through read memory operations",
# with same-port read-during-write "Don't Care".  So synthesis is asked for an
# MLAB with read-during-write checking off, from here and not from the HDL,
# which the Zynq flows and every Verilator check read unchanged.  Asking for
# the MLAB alone is refused (info 276009, the read-during-write behavior).
#
# **WHAT "CHECKING OFF" GIVES AWAY IS ONE TICK, AND A CHECK HOLDS IT.**  The
# word read at an address in the tick after the edge that wrote it is then
# not specified.  `build/rdw_poison.pass`, `build/rdw_poison_sys.pass` and
# `build/rdw_poison_map.pass` return a poisoned word in exactly that tick and
# still agree with muir on every program, and the last section of
# `cadr_microcycle.sv` says why.  `build.sh` refuses a synthesis in which the
# three are anything but MLABs.
foreach memory [expr {$fault ? {} : {dmem l1_map l2_map}}] {
    set_instance_assignment -name RAMSTYLE_ATTRIBUTE MLAB -to "u_machine|processor|$memory"
    set_instance_assignment -name RAMSTYLE_ATTRIBUTE_RDW no_rw_check -to "u_machine|processor|$memory"
}

# ----------------------------------------- the disk controller's block store
#
# **THE STORE IS M20K BLOCKS, AND NOTHING IN `rtl/` SAYS SO EITHER.**  The
# controller's block store is 24 slots of 256 words of 32 bits, and it is a
# TRUE dual-port memory: the seam a program in Linux fills a slot through is
# one port and the channel that walks a block under the heads is the other, so
# a fill and a walk never contend.  Each port is written exactly as a block
# RAM's port is --- `if (we) ram[a] <= d; q <= ram[a];` --- which is read-OLD
# on that port, and Agilex 5's M20K does not offer old data at a port that is
# writing: synthesis says so in as many words (info 276009, "uninferred due to
# unsupported read-during-write behavior") and builds the whole 196,608 bits
# out of logic instead.  **Measured: 332,163 ALUTs of a part that has 93,600,
# and the fitter refuses to place it.**  The store is dead on the Zynq boards'
# default build, where nothing fills it, and it only became real here when the
# pack side arrived.
#
# So synthesis is asked for M20K with read-during-write checking off, from
# here and not from the HDL, exactly as the three asynchronous memories above
# are asked for MLABs.  What that gives away is the word read at an address in
# the tick an edge writes it, on the same port or the other one.
# `build/rdw_poison_disk.pass` is what says nothing reads a word in that
# tick: it returns the complement there, on both ports, and the disk
# controller's own checks --- the drive against `golden/src/disk.rs`, the
# channel and the band --- still agree with the reference.
# `build.sh` refuses a synthesis in which the store is anything but M20K.
if {!$fault} {
    set_instance_assignment -name RAMSTYLE_ATTRIBUTE M20K -to "u_machine|disk|blk_ram"
    set_instance_assignment -name RAMSTYLE_ATTRIBUTE_RDW no_rw_check -to "u_machine|disk|blk_ram"
}

# The two images `cadr_machine` reads at elaboration, by absolute path:
# `$readmemh` resolves a relative one against wherever the tool is running,
# which is this directory and not the repository.  `build.sh` refuses to
# start without them, and the synthesis report's parameter table is where the
# two paths can be read back.
if {!$fault} {
    # QUUX boots from its own PROM, version 1000.
    set_parameter -name PROM_HEX      [file join $root build \
        [expr {$machine eq "quux" ? "boot_prom.quux.hex" : "boot_prom.hex"}]]
    set_parameter -name SYNC_PROM_HEX [file join $root build sync_prom.hex]
}

# **WHICH MACHINE**, set only for QUUX, so that the CADR's project is the one
# it has always been and takes the top level's default.  `build.sh` reads the
# value back out of the synthesis report under `u_machine` for both.
if {!$fault && $machine eq "quux"} {
    set_parameter -name MACHINE quux
}

# ------------------------------------------------------ the configuration
#
# **HOW THE PART IS CONFIGURED IS A FACT OF THE BOARD**, not a choice of this
# design: which of the SDM's pins the board wires to `CONF_DONE` and to the
# processor's cold reset, what the configuration clock is, and how the power
# regulator is told the core voltage.  The user manual gives some of it ---
# the 125 MHz `OSC_CLK1` in section 3.5, and Active Serial from the 128 Mbit
# QSPI flash as the default scheme in section 3.1 --- and not the rest.  So
# the values are read from the one source for this board that grants reuse:
# Altera's `agilex5-demo-hps2fpga-interfaces`, under MIT-0, whose
# `brd_terasic_de25nano_revb/hw_base/create_quartus_project.tcl` at commit
# `064c0cf2f7e749b72add75d3ac3845f20af63dc8` sets exactly these seven.
# Terasic's own `golden_top.qsf` sets the same seven to the same values.
#
# The scheme is the flash's, as the board's DIP switch leaves it by default.
# This flow writes an SRAM Object File, which is loaded over JTAG and lost at
# power-off, and on an HPS-first build with a first-stage loader it writes the
# phase-1 bitstream for the flash as well, which is the image this scheme
# describes.  Writing that image to the flash is still not this flow's
# business and nothing here does it: the board's flash was written by hand
# with the vendor's programmer, and `boards/de25-nano/README.md` says what it
# holds.
set_global_assignment -name STRATIXV_CONFIGURATION_SCHEME "ACTIVE SERIAL X4"
set_global_assignment -name ACTIVE_SERIAL_CLOCK AS_FREQ_125MHZ
set_global_assignment -name DEVICE_INITIALIZATION_CLOCK OSC_CLK_1_125MHZ
set_global_assignment -name USE_CONF_DONE SDM_IO16
set_global_assignment -name USE_HPS_COLD_RESET SDM_IO11
set_global_assignment -name PWRMGT_VOLTAGE_OUTPUT_FORMAT "LINEAR FORMAT"
set_global_assignment -name PWRMGT_LINEAR_FORMAT_N "-12"

# **THE BITSTREAM NAMES THE TREE IT WAS BUILT FROM**, in the JTAG USERCODE
# register, in the format `tools/build_stamp.tcl` gives the Zynq boards: the
# commit's first seven hex digits and a nibble saying how the tree stood.
# Quartus describes this assignment as the value the USERCODE instruction
# reads, and Altera's DE25-Nano project sets it too.
set_global_assignment -name STRATIX_JTAG_USER_CODE $userid
set_global_assignment -name USE_CHECKSUM_AS_USERCODE OFF

# **THE MEMORY BOARD'S PROCESSOR BOOTS FIRST**, and these four are how, each
# as Altera's MIT-0 demo sets it for this board (its
# `create_quartus_project.tcl`, the same commit as above).  Only the memory
# board has a processor to boot, so the board without it sets none of them.
#
#   HPS_INITIALIZATION "HPS FIRST"  the processor is configured and boots
#       before the fabric, which is what lets U-Boot load the fabric from the
#       card; the HPS Booting User Guide, document 813762, chapter 6: "only
#       when using the HPS Boot First mode".
#   HPS_DAP_SPLIT_MODE "SDM PINS"   the processor's debug access port on the
#       SDM's JTAG pins, the board's one JTAG connection, so that a debugger
#       can reach the processor over the cable this project already uses.
#   HPS_DAP_NO_CERTIFICATE ON       that port open without an authentication
#       certificate, which is what a development board wants.
#   QSPI_OWNERSHIP HPS              the configuration flash the processor's
#       after it boots, as the processor's first stage expects when it boots
#       first.
#
# **AND ONE BOARD BOOTS THE OTHER WAY ROUND, FOR A BOARD WITH NO FLASH
# WRITTEN.**  `DE25_HPS_BOOT` is `hps-first` by default and `fpga-first` for
# the development board that is loaded over JTAG: the processor cannot be
# configured over JTAG in HPS-first mode --- the Booting User Guide's section
# 4.5.2 puts its phase-1 bitstream in the flash --- while an FPGA-first board
# takes one file over JTAG that configures the fabric AND starts the
# processor's first stage from the same file (its section 4.5.1).  That board
# may not configure the fabric from the processor afterwards (Technical
# Reference Manual A.4.2.1), which the card's `uEnv.txt` says with
# `cadr_fabric_loaded=1`.
set hps_boot [expr {[info exists ::env(DE25_HPS_BOOT)] ? $::env(DE25_HPS_BOOT) : "hps-first"}]
if {$hps_boot ne "hps-first" && $hps_boot ne "fpga-first"} {
    puts "project: DE25_HPS_BOOT is '$hps_boot', which is neither hps-first nor fpga-first"
    exit 1
}
if {$ddr} {
    # Quartus's own two values, from `linux64/assignment_defaults.qdf`:
    # "HPS FIRST", and "After INIT_DONE" for the fabric first, which is what
    # `quartus_pfg -i` calls `HPS_AFTER_INIT_DONE` and the default for this
    # family.
    if {$hps_boot eq "hps-first"} {
        set_global_assignment -name HPS_INITIALIZATION "HPS FIRST"
    } else {
        set_global_assignment -name HPS_INITIALIZATION "After INIT_DONE"
    }
    set_global_assignment -name HPS_DAP_SPLIT_MODE "SDM PINS"
    set_global_assignment -name HPS_DAP_NO_CERTIFICATE ON
    set_global_assignment -name QSPI_OWNERSHIP HPS
}

# ----------------------------------------------------------------- the pins
#
# **FROM `boards/de25-nano/de25_nano_pins.tcl`, AND ONLY FOR THE PORTS THE TOP
# LEVEL HAS.**  That file assigns every pin it knows, and Quartus warns about
# each assignment to a port the design does not have: well over a hundred
# warnings on this board, among which a real one would be lost.  So the file
# is sourced in a child interpreter whose two assignment commands are
# recorded rather than applied, and only the top level's ports are applied
# here.  The pin file stays the one place a pin is written.
# **AND MIT'S DEBUG CABLE ON JP1 PINS 31 TO 38, IN THE BASE PATTERN AND NOT
# BEHIND `$ddr`.**  A board is always a DEBUGGEE, so the connector is in every
# build of this design and its eight pads are placed on every one of them.
# They are named by a range rather than one by one because the eight are
# consecutive, which is the whole of the map;
# `boards/de25-nano/cadr_de25.sv`'s connector section has the table and
# `tools/de25_pins_check.py` holds it.  The header's four supply pins have no
# fabric pin at all and so cannot be swept in by any pattern.
set wanted {^(clock50_0|btn\[[01]\]|sw\[[0-3]\]|led\[[0-7]\]|jp1_pin3[1-8])$}
set wanted_ports [expr {15 + 8}]
# And the memory board's: the processor's LPDDR4 bank, 57 pins, and its 40
# peripheral pins, every one the pin file has.
if {$ddr} {
    set wanted {^(clock50_0|btn\[[01]\]|sw\[[0-3]\]|led\[[0-7]\]|jp1_pin3[1-8]|lpddr4a_.*|hps_.*)$}
    set wanted_ports [expr {15 + 8 + 57 + 40}]
}
# **AND THE DISPLAY'S THIRTY: THE VIDEO BUS AND THE TRANSMITTER'S TWO WIRES,
# AND NOT THE OTHER FIVE THE PIN FILE HAS.**  The twenty-four data lines, the
# pixel clock, the data enable and the two syncs are what the fabric drives;
# `hdmi_scl` and `hdmi_sda` are how its registers are written.  `hdmi_int` and
# the four audio lines are deliberately not in the top level's port list ---
# `boards/de25-nano/cadr_de25.sv` says why for each --- so they are named out
# here rather than swept in by a pattern, and the count below is what says
# the two files still agree.
if {$hdmi} {
    set wanted {^(clock50_0|btn\[[01]\]|sw\[[0-3]\]|led\[[0-7]\]|jp1_pin3[1-8]|lpddr4a_.*|hps_.*|hdmi_d\[([0-9]|1[0-9]|2[0-3])\]|hdmi_pclk|hdmi_de|hdmi_hsync|hdmi_vsync|hdmi_scl|hdmi_sda)$}
    set wanted_ports [expr {15 + 8 + 57 + 40 + 30}]
}
set locations {}
set standards {}
proc record_location {pin -to port} {
    lappend ::locations $port $pin
}
proc record_standard {-name name standard -to port} {
    if {$name ne "IO_STANDARD"} {
        puts "project: the pin file makes a $name assignment, which this flow does not know"
        exit 1
    }
    lappend ::standards $port $standard
}
set pins [interp create]
interp alias $pins set_location_assignment {} record_location
interp alias $pins set_instance_assignment {} record_standard
$pins eval [list source [file join $root boards de25-nano de25_nano_pins.tcl]]
interp delete $pins

set placed 0
foreach {port pin} $locations {
    if {[regexp $wanted $port]} {
        set_location_assignment $pin -to $port
        incr placed
    }
}
set standardized 0
foreach {port standard} $standards {
    if {[regexp $wanted $port]} {
        set_instance_assignment -name IO_STANDARD $standard -to $port
        incr standardized
    }
}
# One clock, two buttons, four switches, eight LEDs and the debug cable's
# eight pads, and on the memory board the processor's 97.  A count that is not
# the one wanted is a pin file or a port list that has moved under this flow.
if {$placed != $wanted_ports || $standardized != $wanted_ports} {
    puts "project: placed $placed ports and gave $standardized a standard, wanting $wanted_ports and $wanted_ports"
    exit 1
}
puts "project: $wanted_ports of the pin file's [expr {[llength $locations] / 2}] ports are this top level's"

# **AND THE DEBUG CABLE'S PADS ARE PULLED DOWN, EVERY ONE OF THEM.**  An
# unplugged connector must read ZERO and not float, because zero is the idle
# cable this transport is built on: `-DEBUG IN REQ` up and `DEBUG IN ACK`
# down.  A floating pad that toggles is worse than a wrong level --- every pad
# enable in `rtl/plumbing/cadr_dbg_cable.sv` is gated on that group's receiver
# saying nothing is on it, so a board that hears noise on a group never drives
# it, and a debuggee with nothing plugged in would refuse to answer for ever.
# Either group can be the one this board is listening to, so all eight are
# pulled and not four.  `boards/arty-z7-20/cadr_arty.xdc` does the same with
# Vivado's `PULLTYPE PULLDOWN`.
#
# **AND THE COUNT IS ASSERTED**, because an assignment that reaches nothing
# looks exactly like one that works, and this one reaches nothing at all if a
# pad is ever renamed.
#
# **WHAT IS MEASURED ABOUT IT AND WHAT IS NOT.**  `WEAK_PULL_DOWN_RESISTOR` is
# an assignment this Quartus knows, and on a scratch project for this exact
# part --- A5EB013BB23BE4SCS --- it is accepted on `PIN_H19` at 3.3-V LVCMOS
# and written into the `.qsf`, with no warning.  That is the tool agreeing that
# the assignment exists; it is NOT the fitter agreeing that the pin's buffer
# offers a pull-down, which only a fit can say.  Altera's device metadata for
# the E-series lists a pull direction select for its high-voltage I/O, which is
# the kind of bank these header pins are in, so there is a reason to expect it
# and no measurement of it.  The Zynq boards get the same thing from Vivado's
# `PULLTYPE PULLDOWN`, which has been fitted and run.
set pulled 0
foreach {port pin} $locations {
    if {[regexp {^jp1_pin3[1-8]$} $port]} {
        set_instance_assignment -name WEAK_PULL_DOWN_RESISTOR ON -to $port
        incr pulled
    }
}
if {$pulled != 8} {
    puts "project: pulled $pulled of the debug cable's pads down, wanting 8"
    exit 1
}
puts "project: the debug cable's 8 pads on JP1 are pulled down, so an unplugged connector reads zero"

project_close
if {$fault} {
    puts "project: written to $build/cadr_de25.qsf with USERCODE $userid, $hps_boot, THE FAULT BITSTREAM"
} elseif {$probe_depth > 0} {
    puts "project: written to $build/cadr_de25.qsf with USERCODE $userid and a probe of $probe_depth samples"
} elseif {$hdmi} {
    puts "project: written to $build/cadr_de25.qsf with USERCODE $userid, $hps_boot, with the display output"
} else {
    puts "project: written to $build/cadr_de25.qsf with USERCODE $userid, $hps_boot"
}
