#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The DE25-Nano's bitstream, loaded over JTAG.
#
#     make de25-program
#     make de25-program PROBE_DEPTH=1024
#
# The second loads the instrumented build from `build/de25-probe/`, which
# `make de25 PROBE_DEPTH=1024` writes, and the first the plain one.
# `MACHINE=quux` loads the evolved CADR's build from `build/de25-quux/` and
# the same suffixes after it, as `build.sh` names them.
#
# **VOLATILE, AND NOTHING ELSE.**  This loads `build/de25/output_files/
# cadr_de25.sof` into the part's configuration memory, which a power cycle
# clears, and the board then configures from its QSPI flash as it did before.
# Nothing here writes the flash, and the programmer is only ever given an SRAM
# Object File with the `p` operation on a JTAG chain.
#
# **THE BOARD IS NAMED BY ITS SERIAL AND NEVER BY A POSITION.**  Several
# boards share one USB hub on the build host, so a cable is not "the first
# one".  `DE25_SERIAL=` in the gitignored `boards/de25-nano/local.conf`, or in
# the environment, is the serial string the board's USB-Blaster III reports.
# Quartus names a cable by where it is plugged in, `DE25-Nano [9-1-iface0]`,
# and not by its serial, so this finds the USB device carrying that serial
# under Altera's vendor ID, 09fb, and takes the cable Quartus names after that
# device.  A serial that matches no device, or more than one, is refused, and
# so is a chain that is not exactly one Agilex 5 part.
#
# **THE BUILD THE PART READS BACK IS CHECKED, AND IT IS NOT A WITNESS ON ITS
# OWN.**  The programmer must report that configuration succeeded, and that
# report alone is what a Zynq board once lost three downloads in six to.  So
# the build stamp `build.sh` writes into USERCODE is read back by
# `usercode.tcl`, before the download and after it, with the USERCODE
# instruction from Altera's boundary-scan guide for the family, and compared
# with the bitstream's: the part must hold this build afterwards, and the line
# printed says whether it held it before too, in which case a download cannot
# be told from none.
#
# **BECAUSE THAT READ-BACK HAS BEEN CAUGHT GIVING AN ANSWER THAT WAS NOT THE
# PART'S.**  During the flash work it reported one build's stamp before and
# after three downloads of differently stamped images, and reported it again
# while the part was holding the programmer's own helper design.  Other
# readings did follow the part: every one recorded in `docs/board.md` changed
# with its download.  What separates a reading that follows the part from one
# that does not is not established, so a download that has to be certain wants
# a witness of its own, as the flash work took a full read-back of the flash
# against the file written.  `boards/de25-nano/README.md` records both.
#
# **AND THE HUB'S HASH, WHICH TELLS THE TWO BUILDS OF ONE TREE APART.**  The
# plain build and the probe's carry the same stamp when they are built from
# the same tree, so USERCODE cannot say which of the two a part holds.  The
# JTAG server can: it reports a `Design hash` for a design whose SLD hub has a
# node, and it is the hub's own, the `DESIGN_HASH` Quartus writes into the
# build's `.sld` file, not the assembler's design hash, measured.  The probe's
# build shows its hash and the plain build, whose hub has no node, shows
# none.  So a hash shown must be the build's, the probe's build must show
# one, and the line printed says what the hub reported before and after.
#
# It refuses a bitstream whose timing was not met, because a board that
# misses timing is no evidence about its own logic.  `FORCE=1` loads it
# anyway, for a person who wants to see what that looks like.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
cd "$root"

say() { printf 'de25-program: %s\n' "$*"; }
refuse() { printf 'de25-program: REFUSED: %s\n' "$*" >&2; exit 1; }

machine=${MACHINE:-cadr}
case $machine in
    cadr|quux) ;;
    *) refuse "MACHINE is '$machine'; it is cadr, MIT's machine, or quux, the evolved CADR" ;;
esac

conf=boards/de25-nano/local.conf
conf_value() {
    [ -f "$conf" ] || return 0
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$conf" | tail -n 1 | tr -d "\"'"
}

quartus=${QUARTUS_ROOTDIR:-$(conf_value QUARTUS_ROOTDIR)}
[ -n "$quartus" ] || refuse "set QUARTUS_ROOTDIR, or add a QUARTUS_ROOTDIR= line to $conf"
for tool in "$quartus/bin/jtagconfig" "$quartus/bin/quartus_pgm" "$quartus/bin/quartus_stp"; do
    [ -x "$tool" ] || refuse "$tool is not there"
done

serial=${DE25_SERIAL:-$(conf_value DE25_SERIAL)}
[ -n "$serial" ] || refuse "set DE25_SERIAL, or add a DE25_SERIAL= line to $conf"

out=build/de25
if [ "$machine" = quux ]; then
    out=$out-quux
fi
case ${DDR:-0} in
    ''|0) ;;
    *)    out=$out-ddr ;;
esac
# And the board with the display output, which `make de25 DDR=1 HDMI=1`
# writes: the same naming `build.sh` gives it, so the two agree on where a
# build went.
case ${HDMI:-0} in
    ''|0) ;;
    *)    out=$out-hdmi ;;
esac
case ${PROBE_DEPTH:-0} in
    ''|0) ;;
    *)    out=$out-probe ;;
esac
# **AND THE MEMORY BOARD IS LOADED AS THE FILE THE PROCESSOR NEEDS**, not as
# the bare `.sof`: "SOF files resulted from compiling hardware designs that
# have HPS instantiated cannot be used directly to configure the device", the
# Booting User Guide (document 813762) says in its section 4.5.1, and
# `build.sh` writes `cadr_de25_hps.sof` beside the `.sof` when it is given the
# processor's first-stage loader.
hps_sof=$out/output_files/${machine}_de25_hps.sof
sof=$out/output_files/cadr_de25.sof
if [ -s "$hps_sof" ]; then
    sof=$hps_sof
    say "loading the file with the processor's first stage in it, not the bare bitstream"
fi
asm=$out/output_files/cadr_de25.asm.rpt
[ -s "$sof" ] || refuse "$sof is not there; run \`make de25\` first"
[ -s "$asm" ] || refuse "$asm is not there; the bitstream has no report to check it against"
verdict=$(sed -n 's/^verdict //p' "$out/timing.txt" 2>/dev/null || true)
if [ "$verdict" != "met" ]; then
    [ "${FORCE:-0}" = 1 ] || refuse "the timing verdict is '${verdict:-missing}', not 'met'; see $out/6-sta-check.log"
    say "timing is '$verdict', and FORCE=1 loads it anyway"
fi

# The USB device with this serial under Altera's vendor ID.
devices=""
for d in /sys/bus/usb/devices/*; do
    [ -f "$d/serial" ] && [ -f "$d/idVendor" ] || continue
    [ "$(cat "$d/idVendor")" = 09fb ] || continue
    [ "$(cat "$d/serial")" = "$serial" ] || continue
    devices="$devices $(basename "$d")"
done
set -- $devices
[ "$#" -eq 1 ] || refuse "wanted one Altera USB device with serial $serial, found $#"
cable="DE25-Nano [$1-iface0]"

# What the JTAG server says about that one cable: its line, and every line up
# to the next cable's.
block() {
    "$quartus/bin/jtagconfig" --debug 2>&1 | awk -v c="$cable" '
        /^[0-9]+\) / { mine = (substr($0, index($0, ") ") + 2) == c) }
        mine { print }'
}
# The first query of a session starts the JTAG server, and measured, it can
# answer before the server has found the cable; so it is asked again, for up
# to ten seconds, before the cable is called missing.
chain=$(block)
tries=0
while [ -z "$chain" ] && [ "$tries" -lt 5 ]; do
    sleep 2
    tries=$((tries + 1))
    chain=$(block)
done
[ -n "$chain" ] \
    || refuse "the JTAG server does not list '$cable'; it lists: $("$quartus/bin/jtagconfig" 2>&1 | grep '^ *[0-9])' | tr '\n' ' ')"
# **THIS BOARD'S PART ON THAT CABLE, AND WHAT ELSE MAY BE BESIDE IT.**  The ID
# code Quartus reports for the A5EB013BB23BE4SCS family is 4362C0DD, and it is
# the part this programs.  A design with the processor in it puts a second TAP
# on the chain --- the processor's debug port, which Altera's boundary-scan
# guide for the family says appears only then --- and that is an Arm debug
# port, `?BA06477`, as Quartus's own programmer part table gives every other
# family's (`quartus/linux64/pgm_parts.txt`), and this board's own reports
# `4BA06477 ARM_CORESIGHT_SOC_600 (IR=4)`, measured.  Anything else on the chain is
# refused, and the position of this board's own part is what the programmer is
# given, because a chain of two has two positions.
parts=$(printf '%s\n' "$chain" | grep -c '^  [0-9A-F]\{8\} ' || true)
[ "$parts" -ge 1 ] && [ "$parts" -le 2 ] \
    || refuse "wanted one or two parts on '$cable', found $parts"
ours=$(printf '%s\n' "$chain" | grep -c '^  4362C0DD ' || true)
[ "$ours" -eq 1 ] || refuse "wanted one part with ID code 4362C0DD on '$cable', found $ours"
others=$(printf '%s\n' "$chain" | grep '^  [0-9A-F]\{8\} ' | grep -v '^  4362C0DD ' || true)
if [ -n "$others" ]; then
    printf '%s\n' "$others" | grep -q '^  [0-9A-F]BA06477 ' \
        || refuse "'$cable' carries a part that is neither this board's FPGA nor its processor's debug port: $others"
    say "the processor's debug port is on the chain: $(printf '%s\n' "$others" | sed 's/^  //')"
fi
# Which position this board's part is at, counting the parts in chain order.
device=$(printf '%s\n' "$chain" | grep '^  [0-9A-F]\{8\} ' | grep -n '^  4362C0DD ' | cut -d: -f1)
[ -n "$device" ] || refuse "could not place this board's part on '$cable'"
say "this board's part is device $device of $parts on the chain"

# What the hub reports before the download, for the line after it.
hub_before=$(block | sed -n 's/^ *Design hash *\([0-9A-F]*\).*/\1/p' | head -n 1)

# The build the part holds before the download, for the verdict after it.
# A part that cannot be read now is not a reason to stop: the reading after
# the download is the one that decides.
usercode_tcl=boards/de25-nano/quartus/usercode.tcl
before=$(DE25_SERIAL=$serial "$quartus/bin/quartus_stp" -t "$usercode_tcl" 2>&1 \
             | sed -n 's/^de25-program: USERCODE \([0-9a-f]\{8\}\)$/\1/p' | tail -n 1)
say "the part holds build ${before:-that could not be read} before the download"

say "loading $sof over '$cable' (serial $serial), volatile"
"$quartus/bin/quartus_pgm" -c "$cable" -m jtag -o "p;$sof@$device" > "$out/program.log" 2>&1 \
    || { tail -n 20 "$out/program.log" >&2; refuse "the programmer failed; see $out/program.log"; }
grep '^Info (209011)\|^Info (209060)\|Successfully performed' "$out/program.log" | sed 's/^/de25-program: /' || true

# **AND THE INDEX IT SUCCEEDS AT MAY NOT BE THE INDEX IT WAS GIVEN.**  On the
# memory board the processor's debug port joins the chain DURING
# configuration, ahead of the FPGA, and the programmer says so itself:
# "Added ARM_CORESIGHT_SOC_600 at device index 1 after configuration
# succeeded", with the success reported at index 2 for a part that was index
# 1 when the download began.  Measured.  So what is read here is that
# configuration succeeded at some index, and the index is printed; what says
# the part holds this build is the USERCODE read back below, which finds the
# part by its IDCODE whatever the chain has become.
at=$(sed -n 's/^Info (18943): Configuration succeeded at device index \([0-9]*\).*/\1/p' \
     "$out/program.log" | head -n 1)
[ -n "$at" ] \
    || refuse "the programmer did not report that configuration succeeded; see $out/program.log"
if [ "$at" = "$device" ]; then
    say "configuration succeeded on device $at"
else
    say "configuration succeeded on device $at, which was device $device before the download:"
    grep -q 'Added ARM_CORESIGHT_SOC_600' "$out/program.log" \
        && say "the processor's debug port joined the chain ahead of it during configuration" \
        || refuse "the part moved on the chain and nothing says the processor's debug port joined it"
fi

# The hub the part now reports, against the build's: see the header.
sld=$out/output_files/cadr_de25.sld
built=$(sed -n 's/.*DESIGN_HASH \([0-9a-fA-F]*\).*/\1/p' "$sld" 2>/dev/null | head -n 1 | tr a-f A-F)
held=$(block | sed -n 's/^ *Design hash *\([0-9A-F]*\).*/\1/p' | head -n 1)
if [ -n "$held" ]; then
    [ "$held" = "$built" ] || refuse "the part's hub reports design $held, and this build's is ${built:-not in $sld}"
    say "the part's hub reports design $held, this build's"
elif [ "$out" = build/de25-probe ] || [ "$out" = build/de25-quux-probe ]; then
    refuse "the part's hub reports no design, and the probe's build has a node on it"
else
    say "the part's hub reports no design, as the plain build's, with no node, does"
fi
if [ "$hub_before" != "$held" ]; then
    say "the hub reported ${hub_before:-no design} before the download and ${held:-no design} after it"
fi
usercode=$(sed -n 's/^; JTAG usercode *; 0x\([0-9A-Fa-f]*\) *;.*/\1/p' "$asm" | head -n 1)
[ -n "$usercode" ] || refuse "no JTAG usercode in $asm"
say "the bitstream's USERCODE is $usercode"

# And the build the part holds now, against the bitstream's.  Its lines are
# printed whatever they say, and its exit status is the verdict.
if ! DE25_SERIAL=$serial "$quartus/bin/quartus_stp" -t "$usercode_tcl" "$usercode" "$before" \
        > "$out/usercode.log" 2>&1; then
    grep '^de25-program:' "$out/usercode.log" >&2 || tail -n 20 "$out/usercode.log" >&2
    refuse "the part does not hold the build just loaded; see $out/usercode.log"
fi
grep '^de25-program:' "$out/usercode.log"
