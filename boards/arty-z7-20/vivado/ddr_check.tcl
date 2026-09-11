# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Start the processing system and prove, from outside our design, that DDR
# answers.
#
#     ~/Xilinx/2026.1/Vivado/bin/xsdb boards/arty-z7-20/vivado/ddr_check.tcl
#     PS7_INIT=build/ps7/ps7_init.tcl BOARD_URL=<host>:3121 \
#         ~/Xilinx/2026.1/Vivado/bin/xsdb boards/arty-z7-20/vivado/ddr_check.tcl
#
# Run from the repository root.  `connect` with no URL starts a local
# `hw_server` itself; `docs/board.md` has the remote arrangement and the udev
# rules whose absence looks like a network fault.
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
#   uninitialised     a block read before anything is written, and read
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
#                     Nothing clears DDR between runs, so "uninitialised"
#                     means uninitialised since power-on and only the first
#                     run after one says anything.
#   word and poison   the project's own pair, `0x8A5C36E1` at `0x18A72EE4`
#                     and its complement `0x75A3C91E` written over it.  A
#                     read that returns the value the previous write left is
#                     indistinguishable from a real one until the second
#                     write disagrees with the first.
#   the neighbour     `0x18A72EE0`, the low half of the same 64-bit beat,
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

set url  [expr {[info exists ::env(BOARD_URL)] ? $::env(BOARD_URL) : ""}]
set init [expr {[info exists ::env(PS7_INIT)] ? $::env(PS7_INIT) \
                                              : "build/ps7/ps7_init.tcl"}]

# ------------------------------------------------------------------ the map
# rtl/plumbing/cadr_ddr_map.sv: RESERVED_BASE, and MAIN_BASE on top of it.
set MAIN_BASE   0x18000000
set DDR_TOP     0x20000000
set RESERVED_MB 128

# The proving address and word, the same pair `boards/arty-z7-20/cadr_arty.sv` gives the
# witness: main_byte_address(22'o12345671), a word of four distinct bytes
# whose halves are not rotations of each other, and its complement as poison.
set PROVE_ADDR  0x18A72EE4
set PROVE_NEIGH 0x18A72EE0
set PROVE_WORD  0x8A5C36E1
set PROVE_POISON 0x75A3C91E

set TOP_ADDR    0x1FFFFFF0

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

if {[catch {targets -set -filter {name =~ "APU*"}} err]} {
    stop "no APU target: $err"
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
say "  device identity              [hex $device]  wanted 0x03727093 (XC7Z020)"
if {$device != 0x03727093} {
    say "FAILED at 0xF8000530 --- PSS_IDCODE is not an XC7Z020's."
    say "FAILED   read [hex $idcode], device identity [hex $device],"
    say "FAILED   wanted 0x03727093.  docs/board.md quotes the whole word as"
    say "FAILED   the JTAG IDCODE 0x23727093.  Nothing below is initialised"
    say "FAILED   against a part this routine was not written for."
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

# ------------------------------------------------- uninitialised, before any write

say "uninitialised DDR, read before anything is written:"
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
    say "  (recorded, not asserted: uninitialised DDR is allowed to be"
    say "   anything, but an unstable read is worth knowing about)"
}

# ------------------------------------------------------- the word and its poison

set neigh_before [rd32 $PROVE_NEIGH]
say "the proving word at [hex $PROVE_ADDR]:"
wr32 $PROVE_ADDR $PROVE_WORD
expect "wrote the word"           $PROVE_ADDR $PROVE_WORD
wr32 $PROVE_ADDR $PROVE_POISON
expect "wrote its complement"     $PROVE_ADDR $PROVE_POISON
expect "the neighbour, untouched" $PROVE_NEIGH $neigh_before

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
expect "its neighbour"       [expr {$TOP_ADDR + 4}] 0x5AA51248
wr32 $TOP_ADDR              0xE0123456
expect "top word, complement" $TOP_ADDR             0xE0123456
expect "its neighbour, still" [expr {$TOP_ADDR + 4}] 0x5AA51248

# ----------------------------------------------------------------------- done

configparams force-mem-accesses $saved_mode
say "PASSED --- the memory controller is up and DDR answers at [hex $MAIN_BASE]"
say "  through [hex [expr {$DDR_TOP - 1}]], with no bitstream and no"
say "  ps7_post_config."
bye 0
