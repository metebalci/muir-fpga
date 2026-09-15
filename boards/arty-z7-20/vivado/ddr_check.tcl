# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Start the processing system and prove, from outside our design, that DDR
# answers.
#
#     ~/Xilinx/2026.1/Vivado/bin/xsdb boards/arty-z7-20/vivado/ddr_check.tcl
#     PS7_INIT=build/ps7/ps7_init.tcl BOARD_URL=<host>:3121 JTAG_SERIAL=<serial> \
#         ~/Xilinx/2026.1/Vivado/bin/xsdb boards/arty-z7-20/vivado/ddr_check.tcl
#
# Run from the repository root.  `connect` with no URL starts a local
# `hw_server` itself; `docs/board.md` has the remote arrangement and the udev
# rules whose absence looks like a network fault.
#
# TWO BOARDS READ THIS FILE, AND THE SECOND ONE SETS SIX FACTS AND SOURCES IT.
# `boards/cora-z7-07s/vivado/ddr_check.tcl` sets that board's name, its
# directory, its part, the device identity its `PSS_IDCODE` must carry, where
# its routine is written and where its DDR ends, and then sources this file.
# That is the shape this project already uses for the same board's `gen_ps7.py`
# and `ps7_ops.py`: one copy of what the check does, and one copy of every
# reason written beside it.  A board that sets nothing gets the Arty Z7-20's
# values, which are the ones written here.
#
# AND THE BOARD IS PICKED BY ITS CABLE SERIAL, BECAUSE `name =~ "APU*"` NAMES
# EVERY ZYNQ ON THE HUB.  That filter was the whole of the selection while one
# board was attached.  Three hang off one hub now and it matches each of their
# APUs, so on its own it can no longer say which board `ps7_init` is about to
# be run against, and this routine writes the memory controller of whichever
# target it is pointed at.
#
#   JTAG_SERIAL in the environment wins, so a run can name a board without
#   editing anything.  Otherwise the serial is read from
#   `<board>/linux/local.conf`, which is gitignored: a cable serial identifies
#   one physical board the way its MAC address does, and this repository is
#   public.
#
#   With no serial at all and exactly one Zynq attached, the filter is the one
#   this file has always used and the run goes ahead.  So a bench with one
#   board behaves as it did, and what is added there is two lines saying which
#   board was chosen and how.
#
#   With no serial and more than one Zynq attached, the run refuses and prints
#   the serials it can see.  Guessing would start the memory controller on
#   whichever board enumerated first, and the numbering moves with enumeration.
#
# NO BITSTREAM, AND NO `ps7_post_config`.  This is the processor side alone.
# `ps7_post_config` writes LVL_SHFTR_EN at 0xF8000900 and clears
# FPGA_RST_CTRL at 0xF8000240, which turns on the PS-PL level shifters and
# brings `S_AXI_HP0` up --- that belongs with the bitstream that uses it, and
# running it here would fold "does the fabric reach memory" back into a step
# whose whole point is that it does not depend on anything we built.  What is
# proved here is that we have the right start-up routine, and nothing else.
#
# WHAT SAYS IT WORKED IS A READ-BACK.  `ps7_init` prints nothing --- its
# version lines are commented out in Xilinx's own output --- so its return
# says only that no Tcl error was raised, and "no error" is not "DDR is up".
# The same shape as the DONE bit in `boards/arty-z7-20/vivado/program.tcl`.
#
# AND `ps_version` DEFAULTS SILENTLY.  It takes bits 31:28 of 0xF8007080 and
# dispatches with **3.0 as the `else` branch**, so a failed or garbage read
# selects the 3.0 tables without saying so.  Two registers are therefore read
# and asserted here, before `ps7_init` is called, because they answer two
# different questions and one of them used to be asked at the wrong address:
#
#   0xF8000530  SLCR PSS_IDCODE.  This is the part's identity, and the low 28
#               bits must be 0x3727093 --- `docs/board.md` quotes the whole
#               word as the JTAG IDCODE 0x23727093, and the two agree on this
#               board.  A read that returned nothing fails here, so the
#               version nibble below is known to have been read from a live
#               PS rather than defaulted into.
#
#   0xF8007080  devcfg MCTRL, whose bits 31:28 are PCAP_PS_VERSION.  It is
#               NOT PSS_IDCODE, whatever a reading of `ps_version` suggests:
#               `ps7_init.c`'s own `ps7GetSiliconVersion` says "Read PS
#               version from MCTRL register [31:28]", and
#               `XDCFG_MCTRL_PCAP_PS_VERSION_MASK` in the devcfg driver is
#               0xF0000000 at that address.  This file asserted the IDCODE
#               against MCTRL on its first run and stopped a good board.
#
# The four values PS_VERSION takes are Xilinx's own, from `zynq_fsbl`'s
# `fsbl.h`: 0 is silicon 1.0, 1 is 2.0, 2 is 3.0 and **3 is 3.1**.  The
# routine has three table sets and 3.1 shares 3.0's, so a 3.1 part reaching
# the `else` branch is the intended path and not the silent default --- which
# is the whole reason to name the branch out loud rather than count on it.
#
# AN EXIT CODE CANNOT TELL TWO FAILURES APART, so every failure below prints
# the address, the word expected and the word read, before exiting 1.
#
# RUN IT UNDER `timeout`.  Xilinx's `mask_poll` waits for DDR-init-complete at
# 0xF8006054 for a hundred million reads before giving up, which over JTAG is
# not a bound anyone will wait for, and the routine is not ours to change.  A
# controller that never comes up therefore hangs rather than failing:
#
#     timeout 600 ~/Xilinx/2026.1/Vivado/bin/xsdb boards/arty-z7-20/vivado/ddr_check.tcl
#
# Exit 124 from that is "the poll never finished", which is its own finding.
#
# WHAT EACH READ IS FOR:
#
#   uninitialized     a block read before anything is written, and read
#                     twice.  Not asserted --- there is nothing to assert ---
#                     but recorded, because all-zeros, all-ones, and a value
#                     that changes between two reads point three different
#                     ways if a later check fails.
#
#                     AND IT IS NOT UNIFORM, WHICH IS THE POINT.  Measured on
#                     this board the first time it was ever brought up: one
#                     word per megabyte across the whole 512 MB comes back in
#                     bands of all-zeros and all-ones, eleven or ten
#                     megabytes wide, repeating with a 64 MB period, with a
#                     handful of lone flipped bits in them.  That is what
#                     never-written DRAM looks like --- true and complement
#                     cells laid out by row --- and it means **an unwritten
#                     word here reads 0x00000000 in some places and
#                     0xFFFFFFFF in others.**  Anything that would take
#                     either as evidence a write happened is testing nothing,
#                     which is the same trap as the control store coming up
#                     zero in CLAUDE.md.  The two blocks sampled below sit on
#                     opposite sides of one of those boundaries on purpose:
#                     0x18000000 lands in a zero band and 0x19000000 in a
#                     ones band.
#
#                     ON A SECOND RUN THEY READ BACK THE FIRST RUN'S WRITES.
#                     Nothing clears DDR between runs, so "uninitialized"
#                     means uninitialized since power-on and only the first
#                     run after one says anything.
#   word and poison   the project's own pair, `0x8A5C36E1` at `0x18A72EE4`
#                     and its complement `0x75A3C91E` written over it.  A
#                     read that returns the value the previous write left is
#                     indistinguishable from a real one until the second
#                     write disagrees with the first.
#   the neighbor      `0x18A72EE0`, the low half of the same 64-bit beat,
#                     asserted unchanged.  `0x18A72EE4` has bit 2 set for
#                     exactly this reason.
#   walking one       one address per address bit, each carrying a value only
#                     it was given, all written before any is read.  A
#                     shorted or dropped address bit lands two writes on one
#                     word and the earlier of them comes back wrong.
#   the top           `0x1FFFFFF0`, sixteen bytes below 512 MB, so that the
#                     whole part is known to have enumerated rather than just
#                     the bottom of it.
#
# The region is `rtl/plumbing/cadr_ddr_map.sv`'s: 0x1800_0000 for 128 MB, which is what
# the machine will own.

# ---------------------------------------------------------------- the board
#
# The six facts that differ between boards.  A board that sources this file
# sets the ones it needs first, and `board_fact` leaves those alone; what it
# does not set is the Arty Z7-20's, which is what these values are.
proc board_fact {name value} {
    if {![info exists ::$name]} {
        set ::$name $value
    }
}

# The name that goes in the messages.
board_fact BOARD_NAME "Arty Z7-20"
# Where the board's gitignored `local.conf` is, which is where a cable serial
# comes from when the environment does not carry one.
board_fact BOARD_DIR "boards/arty-z7-20"
# The part, named in the failure the identity check prints.
board_fact PART_NAME "XC7Z020"
# The low 28 bits `PSS_IDCODE` must carry.  This is Xilinx's own number, out
# of the device table Vivado ships at
# `data/xicom/cable_data/digilent/lnx64/jtscdvclist.txt`: under `XC7Z` it
# gives every Zynq device its IDCODE and the mask `0x0FFFFFFF` that drops the
# revision nibble, and device `020` there is `0x03727093`.  The chain's own
# JTAG IDCODE for this part is that word with a revision on top, which
# `docs/board.md` quotes as `0x23727093`.
board_fact DEVICE_ID 0x03727093
# Where `make ps7-init` writes the routine this check runs.
board_fact PS7_INIT_DEFAULT "build/ps7/ps7_init.tcl"
# One past the top of the board's DDR.  Both boards carry 512 MB, the same
# MT41K256M16 at the same width, so this is the same number twice and is a
# fact about a board rather than about the machine.
board_fact DDR_TOP 0x20000000

set url  [expr {[info exists ::env(BOARD_URL)] ? $::env(BOARD_URL) : ""}]
set init [expr {[info exists ::env(PS7_INIT)] ? $::env(PS7_INIT) \
                                              : $PS7_INIT_DEFAULT}]

# ------------------------------------------------------------------ the map
# rtl/plumbing/cadr_ddr_map.sv: RESERVED_BASE, and MAIN_BASE on top of it.
set MAIN_BASE   0x18000000
set RESERVED_MB 128

# The proving address and word, the same pair `boards/arty-z7-20/cadr_arty.sv` gives the
# witness: main_byte_address(22'o12345671), a word of four distinct bytes
# whose halves are not rotations of each other, and its complement as poison.
set PROVE_ADDR  0x18A72EE4
set PROVE_NEIGH 0x18A72EE0
set PROVE_WORD  0x8A5C36E1
set PROVE_POISON 0x75A3C91E

# Sixteen bytes below the top of DDR.
set TOP_ADDR    [expr {$DDR_TOP - 16}]

# ------------------------------------------------------------------ helpers

set connected 0

proc say {msg} {
    puts "DDR: $msg"
    flush stdout
}

proc hex {v} {
    return [format 0x%08X [expr {$v & 0xFFFFFFFF}]]
}

proc bye {code} {
    global connected
    if {$connected} {
        catch {disconnect}
        set connected 0
    }
    exit $code
}

proc stop {msg} {
    say "FAILED --- $msg"
    bye 1
}

# Named so that the message can never be a bare "mismatch": the address is
# always in it.
proc fail {what addr want got} {
    say "FAILED at [hex $addr] --- $what"
    say "FAILED   wanted [hex $want], read [hex $got]"
    bye 1
}

# `local.conf` is a shell file of KEY=VALUE lines --- `mksd-buildroot.sh`
# sources it --- and this reads one key out of it without running it.  A file
# that is not there is not an error: it means no serial, which is allowed when
# one board is attached.
proc local_conf_serial {path} {
    if {![file readable $path]} {
        return ""
    }
    set fh [open $path]
    set text [read $fh]
    close $fh
    foreach line [split $text "\n"] {
        if {[regexp {^[ \t]*JTAG_SERIAL[ \t]*=[ \t]*\"?([A-Za-z0-9]+)} $line -> s]} {
            return $s
        }
    }
    return ""
}

proc rd32 {addr} {
    return [expr {[lindex [mrd -force -value $addr 1] 0] & 0xFFFFFFFF}]
}

proc rdn {addr n} {
    return [mrd -force -value $addr $n]
}

proc wr32 {addr val} {
    mwr -force $addr [expr {$val & 0xFFFFFFFF}]
}

# Read back and compare, printing both either way.
proc expect {what addr want} {
    set got [rd32 $addr]
    say [format "  %-28s %s  wanted %s" $what [hex $got] [hex $want]]
    if {$got != ($want & 0xFFFFFFFF)} {
        fail $what $addr $want $got
    }
}

# ------------------------------------------------------------------ connect

if {![file exists $init]} {
    say "FAILED --- $init is missing."
    say "FAILED   `make current` regenerates it; it needs Vivado."
    exit 1
}

say "the $BOARD_NAME"

# The environment first, so that a run can name a board without editing
# anything, then the board's own gitignored file.
set serial [expr {[info exists ::env(JTAG_SERIAL)] ? $::env(JTAG_SERIAL) : ""}]
set serial_from "JTAG_SERIAL in the environment"
if {$serial eq ""} {
    set serial [local_conf_serial $BOARD_DIR/linux/local.conf]
    set serial_from "$BOARD_DIR/linux/local.conf"
}

if {$url eq ""} {
    say "connecting to a local hw_server"
    if {[catch {connect} err]} {
        say "FAILED --- connect: $err"
        exit 1
    }
} else {
    say "connecting to $url"
    if {[catch {connect -url $url} err]} {
        say "FAILED --- connect $url: $err"
        exit 1
    }
}
set connected 1

# ------------------------------------------------------- which board this is
#
# Every Zynq on the hub has an APU, so the count is asked before anything is
# selected and a run with nothing to tell them apart refuses rather than
# initializing the first one.
set apus [targets -target-properties -filter {name =~ "APU*"}]
set seen {}
foreach t $apus {
    if {[dict exists $t jtag_cable_serial]} {
        lappend seen [dict get $t jtag_cable_serial]
    }
}

if {$serial eq ""} {
    if {[llength $apus] > 1} {
        say "FAILED --- [llength $apus] Zynq targets are attached and nothing"
        say "FAILED   says which of them this run is for.  Their cable serials:"
        foreach one $seen {
            say "FAILED     $one"
        }
        say "FAILED   Set JTAG_SERIAL, or put a JTAG_SERIAL line in"
        say "FAILED   $BOARD_DIR/linux/local.conf, which is gitignored."
        say "FAILED   Guessing would run ps7_init against whichever board"
        say "FAILED   enumerated first, and that order is not ours to choose."
        bye 1
    }
    say "no cable serial was given and one Zynq is attached, so it is that one"
    set filter {name =~ "APU*"}
} else {
    say "selecting by cable serial, from $serial_from"
    # The serial the debugger reports carries a letter after the one on the
    # board, so this matches a prefix rather than the whole string.
    set filter [format {jtag_cable_serial =~ "%s*" && name =~ "APU*"} $serial]
}

set chosen [targets -target-properties -filter $filter]
if {[llength $chosen] != 1} {
    say "FAILED --- [llength $chosen] targets match, and exactly one is wanted."
    say "FAILED   The filter was: $filter"
    say "FAILED   The APU cable serials attached are: [join $seen {, }]"
    bye 1
}
if {[dict exists [lindex $chosen 0] jtag_cable_name]} {
    say "the cable is [dict get [lindex $chosen 0] jtag_cable_name]"
}
if {[catch {targets -set -filter $filter} err]} {
    stop "no APU target for the $BOARD_NAME: $err"
}
say "targets seen:"
foreach line [split [string trimright [targets]] "\n"] {
    say "  $line"
}

# `ps7_init` writes SLCR while the APU is wherever the BootROM left it, and
# Xilinx's own routine uses `mwr -force` throughout for that reason.  Every
# access here does the same.
set saved_mode [configparams force-mem-accesses]
configparams force-mem-accesses 1

# ------------------------------------------------- the silicon version, first

# The part's identity, at the register that carries it.  This also says the
# reads below came off a live PS: a version nibble is four bits and every
# value of it means something, so nothing in it alone can say "no answer".
set idcode [rd32 0xF8000530]
set device [expr {$idcode & 0x0FFFFFFF}]
say "SLCR PSS_IDCODE at 0xF8000530 reads [hex $idcode]"
say "  device identity              [hex $device]  wanted [hex $DEVICE_ID] ($PART_NAME)"
if {$device != ($DEVICE_ID & 0xFFFFFFFF)} {
    say "FAILED at 0xF8000530 --- PSS_IDCODE is not a $PART_NAME's."
    say "FAILED   read [hex $idcode], device identity [hex $device],"
    say "FAILED   wanted [hex $DEVICE_ID], which is Xilinx's own device code"
    say "FAILED   for this part with the revision nibble masked off.  The"
    say "FAILED   chain's JTAG IDCODE is the same word with a revision on it."
    say "FAILED   Nothing below is initialized against a part this routine was"
    say "FAILED   not written for."
    bye 1
}

# devcfg MCTRL, bits 31:28.  This is the register ps_version reads.
set mctrl   [rd32 0xF8007080]
set version [expr {($mctrl >> 28) & 0xF}]
say "devcfg MCTRL at 0xF8007080 reads [hex $mctrl]"
say "  PCAP_PS_VERSION 31:28        $version"

# zynq_fsbl/src/fsbl.h: SILICON_VERSION_1 0, _2 1, _3 2, _3_1 3.
switch -- $version {
    0 { set silicon "1.0"; set branch "the 1.0 tables" }
    1 { set silicon "2.0"; set branch "the 2.0 tables" }
    2 { set silicon "3.0"; set branch "the 3.0 tables" }
    3 { set silicon "3.1"; set branch "the 3.0 tables, by the else branch" }
    default {
        say "FAILED at 0xF8007080 --- PCAP_PS_VERSION $version is not one of"
        say "FAILED   the four Xilinx's own fsbl.h names (0 = 1.0, 1 = 2.0,"
        say "FAILED   2 = 3.0, 3 = 3.1).  ps_version would return"
        say "FAILED   [format 0x%X $version] and ps7_init's else branch would run"
        say "FAILED   the 3.0 tables against it without saying so."
        bye 1
    }
}
say "silicon $silicon --- ps_version returns [format 0x%X $version], and ps7_init will"
say "  run $branch."
if {$version == 3} {
    say "  3.1 shares 3.0's tables: the routine has three sets and this is the"
    say "  one Xilinx's own FSBL uses for a 3.1 part, so the else branch here"
    say "  is the intended path and not a default taken on a failed read."
}

# --------------------------------------------------------------- ps7_init

say "sourcing $init"
if {[catch {source $init} err]} {
    stop "sourcing $init: $err"
}
if {[info procs ps7_init] eq ""} {
    stop "$init defined no ps7_init"
}
say "running ps7_init --- it prints nothing on success, so this says only that"
say "  it returned; the read-backs below are what say the controller is up."
if {[catch {ps7_init} err]} {
    stop "ps7_init raised: $err"
}
say "ps7_init returned without error"
say "ps7_post_config is deliberately NOT run: the level shifters and"
say "  S_AXI_HP0 belong with the bitstream that uses them."

# ------------------------------------------------- uninitialized, before any write

say "uninitialized DDR, read before anything is written:"
foreach a [list $MAIN_BASE $PROVE_NEIGH 0x19000000 0x1FFFFFE0] {
    set words [rdn $a 8]
    set out {}
    foreach w $words { lappend out [hex $w] }
    say "  [hex $a]  [join $out { }]"
}

# Read one of them twice.  Two disagreeing reads of memory nothing has
# touched is a different fault from a stable pattern, and only a second read
# can tell them apart.
set first  [rdn 0x19000000 8]
set second [rdn 0x19000000 8]
if {$first eq $second} {
    say "  0x19000000 re-read: identical, so what it holds is stable"
} else {
    set out {}
    foreach w $second { lappend out [hex $w] }
    say "  0x19000000 re-read: DIFFERENT --- [join $out { }]"
    say "  (recorded, not asserted: uninitialized DDR is allowed to be"
    say "   anything, but an unstable read is worth knowing about)"
}

# ------------------------------------------------------- the word and its poison

set neigh_before [rd32 $PROVE_NEIGH]
say "the proving word at [hex $PROVE_ADDR]:"
wr32 $PROVE_ADDR $PROVE_WORD
expect "wrote the word"           $PROVE_ADDR $PROVE_WORD
wr32 $PROVE_ADDR $PROVE_POISON
expect "wrote its complement"     $PROVE_ADDR $PROVE_POISON
expect "the neighbor, untouched"  $PROVE_NEIGH $neigh_before

# ------------------------------------------------------------ the walking one

# One address per address bit inside the reserved region: base + 1<<k for
# every k a word address can carry, plus the base itself.  Everything is
# written before anything is read, so an address bit that does not reach the
# part shows as two writes landing on one word.
set walk {}
lappend walk [list $MAIN_BASE 0xE1000000]
for {set k 2} {$k <= 26} {incr k} {
    set a [expr {$MAIN_BASE + (1 << $k)}]
    if {$a >= $MAIN_BASE + ($RESERVED_MB * 1024 * 1024)} { continue }
    # Distinct per bit, never zero, never all ones, and not the address.
    lappend walk [list $a [expr {0xC0DE0000 | ($k << 8) | (255 - $k)}]]
}

say "walking one across [llength $walk] addresses, all written before any is read:"
foreach pair $walk {
    wr32 [lindex $pair 0] [lindex $pair 1]
}
foreach pair $walk {
    set a [lindex $pair 0]
    set w [lindex $pair 1]
    set g [rd32 $a]
    say [format "  %s  %s  wanted %s" [hex $a] [hex $g] [hex $w]]
    if {$g != $w} {
        fail "walking one --- an address bit does not reach the part" $a $w $g
    }
}

# ------------------------------------------------------------------ the top

say "the top of the 512 MB, so the whole part is known to have enumerated:"
wr32 $TOP_ADDR              0x1FEDCBA9
wr32 [expr {$TOP_ADDR + 4}] 0x5AA51248
expect "top word"            $TOP_ADDR              0x1FEDCBA9
expect "its neighbor"        [expr {$TOP_ADDR + 4}] 0x5AA51248
wr32 $TOP_ADDR              0xE0123456
expect "top word, complement" $TOP_ADDR             0xE0123456
expect "its neighbor, still"  [expr {$TOP_ADDR + 4}] 0x5AA51248

# ----------------------------------------------------------------------- done

configparams force-mem-accesses $saved_mode
say "PASSED --- the $BOARD_NAME's memory controller is up and DDR answers at [hex $MAIN_BASE]"
say "  through [hex [expr {$DDR_TOP - 1}]], with no bitstream and no"
say "  ps7_post_config."
bye 0
