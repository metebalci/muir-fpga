#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The DE25-Nano's bitstream, loaded over JTAG.
#
#     make de25-program
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
# **WHAT IT READS BACK, AND WHAT IT CANNOT YET.**  The programmer must report
# that configuration succeeded on device 1.  The JTAG server reports a hash of
# the design a part holds only when that design carries a debug hub: the
# board's factory image showed one, with three debug nodes, and this design,
# with no hub, shows none, measured.  Where a hash is shown it must be the
# start of the assembler's, or the part is not running what was built.  The
# build stamp is in the USERCODE register, and reading it back needs the
# Agilex 5 USERCODE instruction from Altera's boundary-scan guide, which this
# script does not guess.
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

conf=boards/de25-nano/local.conf
conf_value() {
    [ -f "$conf" ] || return 0
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$conf" | tail -n 1 | tr -d "\"'"
}

quartus=${QUARTUS_ROOTDIR:-$(conf_value QUARTUS_ROOTDIR)}
[ -n "$quartus" ] || refuse "set QUARTUS_ROOTDIR, or add a QUARTUS_ROOTDIR= line to $conf"
for tool in "$quartus/bin/jtagconfig" "$quartus/bin/quartus_pgm"; do
    [ -x "$tool" ] || refuse "$tool is not there"
done

serial=${DE25_SERIAL:-$(conf_value DE25_SERIAL)}
[ -n "$serial" ] || refuse "set DE25_SERIAL, or add a DE25_SERIAL= line to $conf"

out=build/de25
sof=$out/output_files/cadr_de25.sof
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
# One part on that cable, and it is this board's: the ID code Quartus reports
# for the A5EB013BB23BE4SCS family, 4362C0DD.
parts=$(printf '%s\n' "$chain" | grep -c '^  [0-9A-F]\{8\} ' || true)
[ "$parts" -eq 1 ] || refuse "wanted one part on '$cable', found $parts"
printf '%s\n' "$chain" | grep -q '^  4362C0DD ' || refuse "the part on '$cable' is not ID code 4362C0DD"

say "loading $sof over '$cable' (serial $serial), volatile"
"$quartus/bin/quartus_pgm" -c "$cable" -m jtag -o "p;$sof@1" > "$out/program.log" 2>&1 \
    || { tail -n 20 "$out/program.log" >&2; refuse "the programmer failed; see $out/program.log"; }
grep '^Info (209011)\|^Info (209060)\|Successfully performed' "$out/program.log" | sed 's/^/de25-program: /' || true

grep -q '^Info (18943): Configuration succeeded at device index 1' "$out/program.log" \
    || refuse "the programmer did not report that configuration succeeded; see $out/program.log"
say "configuration succeeded on device 1"

# The design the part now holds, against the design in the file, where the
# JTAG server shows one: see the header.
built=$(sed -n 's/^; Design hash *; \([0-9A-F]*\) *;.*/\1/p' "$asm" | head -n 1)
[ -n "$built" ] || refuse "no design hash in $asm"
held=$(block | sed -n 's/^ *Design hash *\([0-9A-F]*\).*/\1/p' | head -n 1)
if [ -n "$held" ]; then
    case "$built" in
        "$held"*) say "the part holds design $held, the start of the file's $built" ;;
        *) refuse "the part holds design $held, and the file's is $built" ;;
    esac
else
    say "the part shows no design hash, as a design with no debug hub does; the file's is $built"
fi
usercode=$(sed -n 's/^; JTAG usercode *; 0x\([0-9A-Fa-f]*\) *;.*/\1/p' "$asm" | head -n 1)
say "the bitstream's USERCODE is $usercode"
