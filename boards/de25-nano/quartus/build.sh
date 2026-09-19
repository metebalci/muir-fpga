#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The DE25-Nano's bitstream, built by Quartus in batch from nothing.
#
#     make de25
#
# which runs this with the Makefile's source list.  Everything it makes is
# under `build/de25/`, which it removes first, so no file from an earlier
# build can be mistaken for this one's.  The SRAM Object File it ends with is
# `build/de25/output_files/cadr_de25.sof`, and `program.sh` beside this loads
# it over JTAG.
#
# **WHERE QUARTUS IS** comes from `QUARTUS_ROOTDIR` in the environment, or
# from a `QUARTUS_ROOTDIR=` line in the gitignored
# `boards/de25-nano/local.conf`.  It names the installation's `quartus`
# directory, the one holding `bin/quartus_sh`, which is how Altera's own
# scripts use the name.  The IP tools are taken from the `qsys/bin` beside
# it, so the two always come from one installation.  Nothing is taken from
# the login shell's settings: a non-interactive shell does not read them.
#
# **THE STEPS**, each with its log in `build/de25/`:
#
#   1. The variation files of the I/O PLL, from the parameters below, and of
#      the Reset Release.
#   2. The project, by `project.tcl`, with the build stamp in USERCODE.
#   3. The two cores' HDL, generated from their variations.
#   4. Synthesis, and 5. the fitter.  **A BUILD WITHOUT THE AGILEX 5E LICENSE
#      IS REFUSED**, before synthesis: see "the license" below.
#   6. The timing analyzer, every corner, and `sta_check.tcl`'s checks: the
#      clocks, the board's exceptions, the machine's exceptions and the
#      slack at every corner.
#   7. The fit's size, against what the machine is known to cost.
#   8. The assembler, which writes the `.sof`.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../../.." && pwd)
cd "$root"

say() { printf 'de25: %s\n' "$*"; }
refuse() { printf 'de25: REFUSED: %s\n' "$*" >&2; exit 1; }

[ "$#" -gt 0 ] || refuse "no sources given; run this through \`make de25\`"

conf=boards/de25-nano/local.conf
conf_value() {
    [ -f "$conf" ] || return 0
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$conf" | tail -n 1 | tr -d "\"'"
}

quartus=${QUARTUS_ROOTDIR:-$(conf_value QUARTUS_ROOTDIR)}
[ -n "$quartus" ] || refuse "set QUARTUS_ROOTDIR, or add a QUARTUS_ROOTDIR= line to $conf"
bin=$quartus/bin
qsys=$quartus/../qsys/bin
for tool in "$bin/quartus_sh" "$bin/quartus_ipgenerate" "$bin/quartus_syn" \
            "$bin/quartus_fit" "$bin/quartus_sta" "$bin/quartus_asm" \
            "$qsys/ip-deploy"; do
    [ -x "$tool" ] || refuse "$tool is not there"
done

for image in build/boot_prom.hex build/sync_prom.hex; do
    [ -s "$image" ] || refuse "$image is missing; \`make de25\` builds it first"
done

out=build/de25
rm -rf "$out"
mkdir -p "$out/ip"

# Each step's output goes to its log and nowhere else; the step's exit status
# is the tool's.
step() {
    name=$1; shift
    say "$name"
    if ! "$@" > "$out/$name.log" 2>&1; then
        tail -n 20 "$out/$name.log" >&2
        refuse "$name failed; the whole log is $out/$name.log"
    fi
}

say "$("$bin/quartus_sh" --version | sed -n 's/^Version //p')"

# ------------------------------------------------------------ the license
#
# **ASKED OF QUARTUS BEFORE ANYTHING IS BUILT, AND READ AS TEXT.**  The no-cost
# license for this part is "Agilex 5E (no-cost)", and `quartus_sh
# --check_license` names the license mode it would use; its exit status is 3
# whether a license is there or not, so the text is what is read.
#
# The fitter's `Info (24849): Successfully acquired license` line is not the
# gate, although it was meant to be.  Measured on the build host: Quartus
# prints it on the fit that fetches the license, and a fetched license is
# kept, so every later fit prints no license line at all.  A gate on that
# line refuses every build but the first.  It is still quoted when it
# appears.
licensing=$("$bin/quartus_sh" --check_license 2>&1 || true)
mode=$(printf '%s\n' "$licensing" | sed -n 's/^License mode: *//p' | head -n 1 | sed 's/ *$//')
case "$mode" in
    "Agilex 5E"*) say "license mode: $mode, $(printf '%s\n' "$licensing" | sed -n 's/^License source: *//p' | head -n 1 | sed 's/ *$//')" ;;
    *) printf '%s\n' "$licensing" >&2
       refuse "quartus_sh --check_license reports the license mode '$mode', not the Agilex 5E one" ;;
esac

# The build stamp, as `tools/build_stamp.tcl` makes it for the Zynq boards.
userid=$("$bin/quartus_sh" --tcl_eval source tools/build_stamp.tcl \; puts [lindex [build_stamp_of_tree] 0] | tail -n 1)
say "build stamp $userid"

# ------------------------------------------------------------ 1. the PLL
#
# **50 MHz IN AND 100 MHz OUT, AND THESE FIVE PARAMETERS ARE THE WHOLE OF
# WHAT IS DECIDED.**  The reference is `CLOCK0_50`, 50 MHz by the manual's
# Table 3-6; one output, at the tick; the lock brought out, because the
# fabric's reset waits for it; and direct mode, since no pin is clocked by
# this clock and there is nothing to compensate for.  Everything else is the
# IP's own default, and the generator chooses the counters and the VCO.  The
# parameter names are the IP's, as `ip-deploy` records them in the variation
# file.  `sta_check.tcl` then reads the period back from the timing analyzer.
step 1-ip-deploy "$qsys/ip-deploy" --component-name=altera_iopll \
    --output-name=cadr_de25_pll --output-directory="$out/ip" \
    --family="Agilex 5" --part=A5EB013BB23BE4SCS \
    --component-parameter=gui_reference_clock_frequency=50.0 \
    --component-parameter=gui_number_of_clocks=1 \
    --component-parameter=gui_output_clock_frequency0=100.0 \
    --component-parameter=gui_use_locked=true \
    --component-parameter=gui_operation_mode=direct
grep -q 'Able to implement PLL with user settings' "$out/1-ip-deploy.log" \
    || refuse "the PLL generator did not say it can make 100 MHz from 50; see $out/1-ip-deploy.log"

# **AND THE RESET RELEASE, WITH NO PARAMETER AT ALL.**  Its one option is
# whether `nINIT_DONE` is a conduit or a Platform Designer reset interface,
# and outside a Platform Designer system the two are the same wire; the
# default, a conduit, is taken.  `cadr_de25.sv` says why this is the IP and
# not the primitive the IP is made of.
step 1-ip-deploy-reset "$qsys/ip-deploy" --component-name=altera_s10_user_rst_clkgate \
    --output-name=cadr_de25_reset_release --output-directory="$out/ip" \
    --family="Agilex 5" --part=A5EB013BB23BE4SCS

# ------------------------------------------------------- 2. the project
step 2-project "$bin/quartus_sh" -t boards/de25-nano/quartus/project.tcl "$out" "$userid" "$@"

# --------------------------------------------- 3. to 6. the compilation
cd "$out"
out=.
step 3-ipgenerate "$bin/quartus_ipgenerate" cadr_de25 --generate_project_ip_files --synthesis=verilog
step 4-syn "$bin/quartus_syn" cadr_de25

# **THE THREE ASYNCHRONOUS MEMORIES ARE MLABS, OR THE BUILD STOPS HERE.**
# `project.tcl` asks for it, and a request that stopped applying --- a
# renamed instance, a changed array --- would leave them as some 70,000
# registers with nothing but the fit's size to say so.  The synthesis
# report's RAM summary must name each of the three once, as an MLAB.
rpt=output_files/cadr_de25.syn.rpt
for memory in dmem l1_map l2_map; do
    n=$(grep -c "^; u_machine|processor|${memory}_rtl_[0-9]*|[^;]*; MLAB " "$rpt" || true)
    [ "$n" -eq 1 ] || refuse "synthesis made u_machine|processor|$memory into $n MLABs, wanting 1; see build/de25/$rpt"
done
if grep -q 'RAM logic "u_machine|processor|\(dmem\|l1_map\|l2_map\)" is uninferred' 4-syn.log; then
    refuse "synthesis built one of the three asynchronous memories from registers; see build/de25/4-syn.log"
fi
say "the dispatch memory and both levels of the map are MLABs"
step 5-fit "$bin/quartus_fit" cadr_de25
if grep -q '^Info (24849)' 5-fit.log; then
    say "$(grep '^Info (24849)' 5-fit.log | head -n 1)"
fi
step 6-sta "$bin/quartus_sta" cadr_de25
# The checks' own exit status is theirs, and a refusal there stops the flow.
say "6-sta-check"
if ! "$bin/quartus_sta" -t "$here/sta_check.tcl" > 6-sta-check.log 2>&1; then
    grep '^sta:' 6-sta-check.log >&2 || tail -n 20 6-sta-check.log >&2
    refuse "the timing analyzer's checks failed; see build/de25/6-sta-check.log"
fi
grep '^sta:' 6-sta-check.log | sed 's/^sta: /de25: /'

# ------------------------------------------------------- 7. the size
#
# **A FIT MUCH SMALLER THAN THE MACHINE IS A FIT OF SOMETHING ELSE.**  If the
# fold in `cadr_de25.sv` stopped holding the machine, synthesis would delete
# it and every figure above would be a figure for an empty part.
summary=output_files/cadr_de25.fit.summary
[ -f "$summary" ] || refuse "$summary is missing"
sed 's/^/de25: /' "$summary"
# **ALMs AND M20K BLOCKS ARE THE TWO FIGURES**, as slices and block RAM are the
# Zynq boards'.  An MLAB is a LAB used as memory, so the ALMs holding the
# three asynchronous memories are inside the ALM figure, as distributed RAM is
# inside a Zynq's slices; the fitter's own breakdown line is printed beside it
# so that the figure can be read.
alms=$(sed -n 's/^Logic utilization (in ALMs) : \([0-9,]*\) .*/\1/p' "$summary" | tr -d ,)
m20k=$(sed -n 's/^Total RAM Blocks : \([0-9,]*\) .*/\1/p' "$summary" | tr -d ,)
[ -n "$alms" ] && [ -n "$m20k" ] || refuse "no ALM or RAM block count in $summary"
grep '^; *\[d\] ALMs used for memory' output_files/cadr_de25.fit.rpt | head -n 1 \
    | sed 's/^; *\([^;]*[^ ;]\) *; *\([0-9,]*\) .*/de25: \1: \2, inside the ALM figure/'
# The floors are the size of an empty part's worth of nothing, not a budget:
# the control store alone is 16,384 words of 48 bits, forty M20K blocks.
if [ "$alms" -lt 1000 ] || [ "$m20k" -lt 40 ]; then
    refuse "the fit is $alms ALMs and $m20k M20K blocks, which is not the machine; see build/de25/$summary"
fi
say "fit: $alms ALMs, $m20k M20K blocks"

# ------------------------------------------------------ 8. the bitstream
step 8-asm "$bin/quartus_asm" cadr_de25
sof=output_files/cadr_de25.sof
[ -s "$sof" ] || refuse "$sof was not written"
say "$(wc -c < "$sof" | tr -d ' ') bytes in build/de25/$sof, USERCODE $userid"
say "timing: $(tail -n 1 timing.txt)"
