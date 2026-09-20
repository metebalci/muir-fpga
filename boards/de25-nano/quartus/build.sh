#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The DE25-Nano's bitstream, built by Quartus in batch from nothing.
#
#     make de25
#     make de25 PROBE_DEPTH=1024
#
# which runs this with the Makefile's source list.  Everything it makes is
# under `build/de25/`, which it removes first, so no file from an earlier
# build can be mistaken for this one's.  The SRAM Object File it ends with is
# `build/de25/output_files/cadr_de25.sof`, and `program.sh` beside this loads
# it over JTAG.
#
# **`DDR=1` BUILDS THE MEMORY BOARD**: the machine with the Agilex 5's
# processor, its LPDDR4 and its FPGA-to-SDRAM bridge behind its memory port,
# as `DDR=1` does for the Arty Z7-20.  The processor system is described in
# `hps.tcl` beside this and generated here at every build, as the PLL is.
# `DE25_DDR_MHZ` is the LPDDR4's speed, 1066.667 by default, which runs on
# either revision of the board, or 1333.333 for a rev B board; `hps.tcl` says
# why.  That build goes to `build/de25-ddr/`.
#
# **`HDMI=1` BUILDS THE DISPLAY OUTPUT INTO THE MEMORY BOARD**: the CADR's two
# screens read out of the machine's memory and put on the board's ADV7513, as
# `HDMI=1` does for the Arty Z7-20.  It needs `DDR=1`, because the picture is
# in the machine's memory.  `HDMI_MODE` is which of the four video modes the
# bitstream carries --- 0 is 1280x1024 at 60 Hz, 1 is 1400x1050 reduced
# blanking at 60, 2 is 1920x1080 at 30, 3 is 1920x1080 at 60 --- and the mode
# is a build and not a setting for the reason `docs/display-output.md` gives.
# **MODE 3 IS THIS BOARD'S AND NOT THE ARTY Z7-20'S**, because that board
# serializes the link in fabric where a lane stops near 1.2 Gb/s and this one
# hands a parallel raster to a transmitter part.  That build goes to
# `build/de25-ddr-hdmi/`, and it generates a SECOND I/O PLL for the pixel
# clock, because no counter of the board's 50 MHz gives both the machine's
# tick and a pixel clock.
#
# **`PROBE_DEPTH` BUILDS THE INSTRUMENTED BOARD INSTEAD**, as it does for the
# Zynq boards: the machine with `rtl/plumbing/cadr_probe.sv` holding its first
# `PROBE_DEPTH` microcycles behind Altera's Virtual JTAG, which `probe.tcl`
# beside this reads.  That build goes to `build/de25-probe/`, so that the
# plain bitstream survives it and a board can be given either one without a
# second eight-minute build.  Zero, or no value, is the plain board.  With
# both, the directory is `build/de25-ddr-probe/`.
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
#      the Reset Release, and of the Virtual JTAG when the probe is built.
#   2. The project, by `project.tcl`, with the build stamp in USERCODE, and
#      on the memory board the processor system, by `hps.tcl`.
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
            "$qsys/ip-deploy" "$qsys/qsys-script"; do
    [ -x "$tool" ] || refuse "$tool is not there"
done

for image in build/boot_prom.hex build/sync_prom.hex; do
    [ -s "$image" ] || refuse "$image is missing; \`make de25\` builds it first"
done

# **ONLY THIS FAMILY'S PLUMBING.**  Vendor-specific RTL lives under
# `rtl/plumbing/<family>/`, and a file from another family's directory is a
# primitive this tool does not have: `rtl/plumbing/xilinx7/` is Vivado's.  The
# Zynq flows skip `rtl/plumbing/agilex5/` the same way, by their own rule.
for f in "$@"; do
    case $f in
        rtl/plumbing/agilex5/*) ;;
        rtl/plumbing/*/*) refuse "$f is another family's plumbing; this flow reads rtl/plumbing/agilex5/ only" ;;
    esac
done

# The memory board, or not, and its memory's speed.
ddr=${DDR:-0}
case $ddr in
    0|1) ;;
    *) refuse "DDR is '$ddr'; it is 0, the board without memory, or 1, the memory board" ;;
esac
mhz=${DE25_DDR_MHZ:-1066.667}
# Which way the processor boots: see `project.tcl`.  The board loaded over
# JTAG with no flash written is the FPGA-first one, and it is the only one
# this flow can turn into a file a programmer takes.
hps_boot=${DE25_HPS_BOOT:-hps-first}
case $hps_boot in
    hps-first|fpga-first) ;;
    *) refuse "DE25_HPS_BOOT is '$hps_boot'; it is hps-first or fpga-first" ;;
esac
# The processor's first-stage loader, as a hex file, when there is one: the
# Linux side builds it.  With it, the flow writes a file the programmer can
# load over JTAG on an FPGA-first board, or the two bitstreams an HPS-first
# board needs in its flash and on its card.
spl=${DE25_SPL_HEX:-}
case $mhz in
    1066.667|1333.333) ;;
    *) refuse "DE25_DDR_MHZ is '$mhz'; the LPDDR4 runs at 1066.667 (either revision) or 1333.333 (rev B)" ;;
esac
out=build/de25
if [ "$ddr" -eq 1 ]; then
    out=$out-ddr
fi

# The display output, or not, and which video mode it carries.  **THE FOUR
# PIXEL CLOCKS ARE THE SPECIFICATIONS' OWN**, and they are written here
# because this is where the PLL is asked for them: VESA DMT's 1280x1024 at
# 60 Hz is 108 MHz, CVT reduced blanking's 1400x1050 at 60 is 101 MHz,
# CEA-861's VIC 34 at 1920x1080 and 30 is 74.25 MHz, and its VIC 16 at
# 1920x1080 and 60 is 148.5.  The same four are the parameter table in
# `rtl/plumbing/cadr_display_out.sv`, which carries the raster's own widths
# beside them, and `tb/cadr_display_out_tb.cpp` carries a third transcription
# and compares against it; what is here is only the frequency the clock
# generator is asked to make.
#
# **AND THE TRANSMITTER'S OWN CEILING IS HELD HERE, AT 165 MHz.**  The
# ADV7513's data sheet in the board's resource package --- Rev. B, page 3 of
# 12, Table 1 under AC SPECIFICATIONS --- gives its Input Video Clock
# Frequency a maximum of 165 MHz and its TMDS Output Clock Frequency 20 to
# 165 MHz, and its first page says 165 MHz supports all video formats up to
# 1080p.  148.5 is inside it.  The bound is written out rather than left
# implied because the next mode somebody adds is the one it is for, and
# `sta_check.tcl` holds the same number against what the PLL actually made
# rather than against what it was asked for.
hdmi=${HDMI:-0}
case $hdmi in
    0|1) ;;
    *) refuse "HDMI is '$hdmi'; it is 0, no display output, or 1, with it" ;;
esac
hdmi_mode=${HDMI_MODE:-0}
case $hdmi_mode in
    0) pixel_mhz=108.0  ; mode_words="1280x1024 at 60 Hz" ;;
    1) pixel_mhz=101.0  ; mode_words="1400x1050 reduced blanking at 60 Hz" ;;
    2) pixel_mhz=74.25  ; mode_words="1920x1080 at 30 Hz" ;;
    3) pixel_mhz=148.5  ; mode_words="1920x1080 at 60 Hz" ;;
    *) refuse "HDMI_MODE is '$hdmi_mode'; it is 0, 1, 2 or 3" ;;
esac
if [ "$(awk -v p="$pixel_mhz" 'BEGIN { print (p > 165.0) ? 1 : 0 }')" = 1 ]; then
    refuse "mode $hdmi_mode asks $pixel_mhz MHz of the pixel clock, and the ADV7513 takes 165 MHz at most (data sheet Rev. B, Table 1, Input Video Clock Frequency)"
fi
if [ "$hdmi" -eq 1 ]; then
    [ "$ddr" -eq 1 ] || refuse "HDMI=1 needs DDR=1: the display reads the machine's memory"
    out=$out-hdmi
fi

# The probe, or not.  A power of two, because its read pointer wraps on it.
depth=${PROBE_DEPTH:-0}
case $depth in
    ''|*[!0-9]*) refuse "PROBE_DEPTH is '$depth', which is not a number" ;;
esac
depth=$((depth + 0))
if [ "$depth" -gt 0 ]; then
    [ $((depth & (depth - 1))) -eq 0 ] || refuse "PROBE_DEPTH is $depth, which is not a power of two"
    out=$out-probe
    say "the probe is in this build: $depth samples, into $out"
fi
if [ "$ddr" -eq 1 ]; then
    say "the processor and its memory are in this build: LPDDR4 at $mhz MHz, into $out"
fi
if [ "$hdmi" -eq 1 ]; then
    say "the display output is in this build: mode $hdmi_mode, $mode_words, a pixel clock of $pixel_mhz MHz, into $out"
fi
rm -rf "$out"
mkdir -p "$out/ip" "$out/tmp"

# **THE TOOLS' TEMPORARY FILES GO WITH THE BUILD**, and not into the system's
# temporary space, which on a build host may be small, shared or a RAM disk.
# Measured here: with it full, Platform Designer failed to write a component
# it had just generated and synthesis failed to open the debug fabric's IP,
# both reported as errors about a file in the tool's own sandbox.
TMPDIR=$(cd "$out/tmp" && pwd)
export TMPDIR

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

# **AND THE PIXEL CLOCK'S PLL, WITH THE DISPLAY.**  The same generator, the
# same reference and the same five decisions, at the mode's frequency instead
# of the tick.  A SECOND PLL AND NOT A SECOND OUTPUT OF THE FIRST, because a
# counter chain that gives 100 MHz gives no whole divisor that is also 108,
# 101, 74.25 or 148.5; the Arty Z7-20's two clock managers exist for the same reason
# and `boards/arty-z7-20/cadr_arty.sv` has the arithmetic.  What the generator
# actually achieves is read back from the timing analyzer by `sta_check.tcl`
# and compared with the mode's, so a PLL that locked at some other frequency
# is a refusal and not a picture nobody can explain.
if [ "$hdmi" -eq 1 ]; then
    step 1-ip-deploy-pixel "$qsys/ip-deploy" --component-name=altera_iopll \
        --output-name=cadr_de25_pixel_pll --output-directory="$out/ip" \
        --family="Agilex 5" --part=A5EB013BB23BE4SCS \
        --component-parameter=gui_reference_clock_frequency=50.0 \
        --component-parameter=gui_number_of_clocks=1 \
        --component-parameter=gui_output_clock_frequency0=$pixel_mhz \
        --component-parameter=gui_use_locked=true \
        --component-parameter=gui_operation_mode=direct
    grep -q 'Able to implement PLL with user settings' "$out/1-ip-deploy-pixel.log" \
        || refuse "the PLL generator did not say it can make $pixel_mhz MHz from 50; see $out/1-ip-deploy-pixel.log"
fi

# **AND THE RESET RELEASE, WITH NO PARAMETER AT ALL.**  Its one option is
# whether `nINIT_DONE` is a conduit or a Platform Designer reset interface,
# and outside a Platform Designer system the two are the same wire; the
# default, a conduit, is taken.  `cadr_de25.sv` says why this is the IP and
# not the primitive the IP is made of.
step 1-ip-deploy-reset "$qsys/ip-deploy" --component-name=altera_s10_user_rst_clkgate \
    --output-name=cadr_de25_reset_release --output-directory="$out/ip" \
    --family="Agilex 5" --part=A5EB013BB23BE4SCS

# **AND THE VIRTUAL JTAG, WITH ONE PARAMETER, WHEN THE PROBE IS BUILT.**  The
# node's instruction is one bit, the sample register or a bypass bit, as
# `rtl/plumbing/agilex5/cadr_probe_vjtag.sv` says.  The instance index is the
# IP's default, assigned by Quartus; with one node in the design it is 0,
# which is the index `probe.tcl` asks for, and a scan of any other finds
# nothing.  The IP's synthesis output is one instance of Quartus's own
# `sld_virtual_jtag` with these parameters, and Quartus builds the SLD hub
# around it.
if [ "$depth" -gt 0 ]; then
    step 1-ip-deploy-vjtag "$qsys/ip-deploy" --component-name=altera_virtual_jtag \
        --output-name=cadr_de25_vjtag --output-directory="$out/ip" \
        --family="Agilex 5" --part=A5EB013BB23BE4SCS \
        --component-parameter=sld_ir_width=1
fi

# ------------------------------------------------------- 2. the project
step 2-project env PROBE_DEPTH="$depth" DDR="$ddr" HDMI="$hdmi" \
    HDMI_MODE="$hdmi_mode" DE25_HPS_BOOT="$hps_boot" \
    "$bin/quartus_sh" -t boards/de25-nano/quartus/project.tcl "$out" "$userid" "$@"

# **AND THE PROCESSOR SYSTEM, ON THE MEMORY BOARD.**  `qsys-script` builds it
# in the build directory from `hps.tcl` and adds it to the project, and step
# 3 generates it with the other IP.  `hps.tcl` refuses a system that does not
# validate, and prints the LPDDR4's speed as the IP holds it.
if [ "$ddr" -eq 1 ]; then
    step 2-hps sh -c "cd '$out' && exec '$qsys/qsys-script' --quartus-project=cadr_de25 \
        --cmd='set ddr_mhz $mhz; source $root/boards/de25-nano/quartus/hps.tcl'"
    grep '^hps: ' "$out/2-hps.log" | sed 's/^hps: /de25: hps: /'
    grep -q "^hps: LPDDR4 at $mhz MHz" "$out/2-hps.log" \
        || refuse "the processor system's LPDDR4 is not at $mhz MHz; see $out/2-hps.log"
    grep -q '^set_global_assignment -name QSYS_FILE cadr_de25_hps.qsys' "$out/cadr_de25.qsf" \
        || refuse "qsys-script did not add the processor system to the project; see $out/2-hps.log"
fi

# --------------------------------------------- 3. to 6. the compilation
dir=$out
cd "$out"
out=.
step 3-ipgenerate "$bin/quartus_ipgenerate" cadr_de25 --generate_project_ip_files --synthesis=verilog
step 4-syn "$bin/quartus_syn" cadr_de25

# **THE THREE ASYNCHRONOUS MEMORIES ARE MLABS, OR THE BUILD STOPS HERE.**
# `project.tcl` asks for it, and a request that stopped applying --- a
# renamed instance, a changed array --- would leave them as some 70,000
# registers with nothing but the fit's size to say so.  The synthesis
# report's RAM summary must name each of the three, as MLABs.
#
# **ONE COPY A READER, AND THE MEMORY BOARD HAS TWO READERS.**  An MLAB has one
# asynchronous read port, so a memory two things read at once is built as two
# copies written together.  Without the processor the machine is the only
# reader and there is one copy of each; with it the console's readout window
# reads the same three memories --- `cadr_machine`'s `con_ro_addr`, which is
# tied to the reserved selector on a board with no console and driven by one
# here --- and there are two.  The count is checked rather than left open,
# because a bound with no ceiling would pass a third copy nobody asked for,
# and a copy is 2 KB of the same MLABs the machine is paying for.
rpt=output_files/cadr_de25.syn.rpt
if [ "$ddr" -eq 1 ]; then copies=2; else copies=1; fi
for memory in dmem l1_map l2_map; do
    n=$(grep -c "^; u_machine|processor|${memory}_rtl_[0-9]*|[^;]*; MLAB " "$rpt" || true)
    [ "$n" -eq "$copies" ] || refuse "synthesis made u_machine|processor|$memory into $n MLABs, wanting $copies; see $dir/$rpt"
done
if grep -q 'RAM logic "u_machine|processor|\(dmem\|l1_map\|l2_map\)" is uninferred' 4-syn.log; then
    refuse "synthesis built one of the three asynchronous memories from registers; see $dir/4-syn.log"
fi
say "the dispatch memory and both levels of the map are MLABs, $copies copies each"

# **AND THE DISK CONTROLLER'S BLOCK STORE IS M20K BLOCKS**, for the reason
# `project.tcl` gives: left to itself synthesis builds its 196,608 bits out of
# logic, which is 332,163 ALUTs on a part that has 93,600 and a fitter that
# refuses to place the design.  The store is dead on a build with nothing to
# fill it, so this is asked of the memory board alone.
if [ "$ddr" -eq 1 ]; then
    n=$(grep -c "^; u_machine|disk|blk_ram_rtl_[0-9]*|[^;]*; M20K " "$rpt" || true)
    [ "$n" -eq 1 ] || refuse "synthesis made u_machine|disk|blk_ram into $n M20K memories, wanting 1; see $dir/$rpt"
    if grep -q 'RAM logic "u_machine|disk|blk_ram" is uninferred' 4-syn.log; then
        refuse "synthesis built the disk controller's block store from logic; see $dir/4-syn.log"
    fi
    say "the disk controller's block store is one true dual-port M20K memory"
fi

# **THE PROBE IS IN THE BUILD THAT ASKED FOR IT AND IN NO OTHER.**  The top
# level's parameter as synthesis records it, in binary; the probe's buffer as
# one memory of `PROBE_DEPTH` words of 454 bits; and the Virtual JTAG IP
# among the design's IP.  A plain build has none of it.
if [ "$depth" -gt 0 ]; then
    pbits=$(sed -n 's/^; PROBE_DEPTH *; \([01]*\) *; Unsigned Binary *;$/\1/p' "$rpt" | head -n 1)
    got=0
    while [ -n "$pbits" ]; do
        got=$((got * 2 + ${pbits%"${pbits#?}"}))
        pbits=${pbits#?}
    done
    [ "$got" -eq "$depth" ] || refuse "synthesis gave the top level PROBE_DEPTH $got, wanting $depth; see $dir/$rpt"
    n=$(grep -c "^; g_probe.u_probe|mem_rtl_0|[^;]*; [A-Z0-9]* *; Simple Dual Port *; $depth *; 454 *;" "$rpt" || true)
    [ "$n" -eq 1 ] || refuse "synthesis made the probe's buffer into $n memories of $depth words of 454 bits, wanting 1; see $dir/$rpt"
    grep -q "; altera_virtual_jtag *;[^;]*;[^;]*;[^;]*; g_probe.u_vjtag *;" "$rpt" \
        || refuse "synthesis lists no Virtual JTAG IP at g_probe.u_vjtag; see $dir/$rpt"
    say "the probe is in: $depth samples of 454 bits, behind the Virtual JTAG"
elif grep -q 'g_probe' "$rpt"; then
    refuse "a build without PROBE_DEPTH has a probe in it; see $dir/$rpt"
fi

# **THE PROCESSOR IS IN THE MEMORY BOARD AND IN NO OTHER**, by the synthesis
# report's list of the design's IP, which names the processor system's two
# components under the instance `u_hps`, and by the machine's memory port
# under `u_memory`.
if [ "$ddr" -eq 1 ]; then
    for ip in intel_agilex_5_soc emif_io96b_hps; do
        grep -q "; $ip *;[^;]*;[^;]*;[^;]*; u_hps|" "$rpt" \
            || refuse "synthesis lists no $ip under u_hps; see $dir/$rpt"
    done
    grep -q 'u_memory|u_share' "$rpt" || refuse "synthesis has no memory port under u_memory; see $dir/$rpt"
    say "the processor system and the machine's memory port are in"
elif grep -q 'u_hps|\|u_memory|' "$rpt"; then
    refuse "a build without DDR has the processor or the memory port in it; see $dir/$rpt"
fi

# **THE DISPLAY IS IN THE BUILD THAT ASKED FOR IT AND IN NO OTHER**, by the
# synthesis report's own list of what it elaborated: the raster and the
# transmitter's configuration, each named by its module AND its instance, so
# a module that had been elaborated somewhere else in the design would not
# answer for one at the top level.  A define that stopped reaching the top
# level would leave a board with video pins and no picture, and the fit's size
# alone would not say so.
disp_line='User Entity cadr_display_out Instance: u_display'
adv_line='User Entity cadr_adv7513 Instance: u_adv7513'
if [ "$hdmi" -eq 1 ]; then
    grep -q "$disp_line" "$rpt" || refuse "synthesis has no display output at u_display; see $dir/$rpt"
    grep -q "$adv_line" "$rpt" \
        || refuse "synthesis has no HDMI transmitter configuration at u_adv7513; see $dir/$rpt"
    # **AND THE DISPLAY'S TWO BAND BUFFERS ARE MEMORIES AND NOT REGISTERS.**
    # Each is written as two halves with their own enables, which is what
    # makes it inferable here at all, and synthesis builds each half as its
    # own memory: two for `mbuf` and two for `cbuf`, four in all.  Written any
    # other way Quartus puts their 98,304 bits in registers without saying so
    # --- 135,576 ALUTs for this module alone, measured, against 1,257 --- and
    # the fit then stops at "Fitter requires 159716 LUTs ... device only has
    # 93600".  `rtl/plumbing/cadr_display_out.sv` has the whole of it.  The
    # RAM summary is where a memory that quietly became registers shows,
    # because nothing else says so.
    for buffer in mbuf cbuf; do
        n=$(grep -c "^; u_display|${buffer}_[a-z0-9_]*|auto_generated" "$rpt" || true)
        [ "$n" -eq 2 ] || refuse "synthesis made u_display|$buffer into $n memories, wanting 2; see $dir/$rpt"
    done
    say "the display's two band buffers are four memories and not 98,304 registers"
    say "the display output and the transmitter's configuration are in"
elif grep -q "$disp_line" "$rpt" || grep -q "$adv_line" "$rpt"; then
    refuse "a build without HDMI has the display output in it; see $dir/$rpt"
fi

step 5-fit "$bin/quartus_fit" cadr_de25
if grep -q '^Info (24849)' 5-fit.log; then
    say "$(grep '^Info (24849)' 5-fit.log | head -n 1)"
fi
step 6-sta "$bin/quartus_sta" cadr_de25
# The checks' own exit status is theirs, and a refusal there stops the flow.
say "6-sta-check"
if ! env CADR_PIXEL_MHZ="$([ "$hdmi" -eq 1 ] && echo "$pixel_mhz" || echo 0)" \
        "$bin/quartus_sta" -t "$here/sta_check.tcl" > 6-sta-check.log 2>&1; then
    grep '^sta:' 6-sta-check.log >&2 || tail -n 20 6-sta-check.log >&2
    refuse "the timing analyzer's checks failed; see $dir/6-sta-check.log"
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
    refuse "the fit is $alms ALMs and $m20k M20K blocks, which is not the machine; see $dir/$summary"
fi
say "fit: $alms ALMs, $m20k M20K blocks"
# And the probe's buffer is block memory, where the fitter was free to put it.
if [ "$depth" -gt 0 ]; then
    grep -q "^; g_probe.u_probe|mem_rtl_0|[^;]*; M20K *; Simple Dual Port *; Single Clock *; $depth *; 454 *;" \
            output_files/cadr_de25.fit.rpt \
        || refuse "the fitter did not put the probe's buffer in M20K blocks; see $dir/output_files/cadr_de25.fit.rpt"
    say "the probe's buffer is in M20K blocks"
fi

# ------------------------------------------------------ 8. the bitstream
step 8-asm "$bin/quartus_asm" cadr_de25
sof=output_files/cadr_de25.sof
[ -s "$sof" ] || refuse "$sof was not written"
say "$(wc -c < "$sof" | tr -d ' ') bytes in $dir/$sof, USERCODE $userid"
say "timing: $(tail -n 1 timing.txt)"

# ------------------------------------------- 9. the processor's own files
#
# **THE `.sof` ALONE DOES NOT CONFIGURE A PART WITH A PROCESSOR IN IT**: the
# Booting User Guide (document 813762, section 4.5.1) says so, and the first
# stage has to be added to it.  With `DE25_SPL_HEX` naming that loader:
#
#   fpga-first   `cadr_de25_hps.sof`, which the programmer loads over JTAG:
#                it configures the fabric and starts the processor's first
#                stage from the same file.  This is the board with no flash
#                written (section 4.5.1).
#   hps-first    `cadr_de25.hps.rbf`, the phase-1 bitstream for the flash,
#                and `cadr_de25.core.rbf`, the fabric the processor loads
#                from the card (section 4.5.2).  Writing the flash is not
#                this flow's business and nothing here does it.
#
# `quartus_pfg -i` then says what the file holds, and its lines are printed:
# the configuration order, whether the processor's debug port is open, and
# the I/O hash, which is what says a phase-1 image and a core bitstream come
# from the same processor configuration.
if [ "$ddr" -eq 1 ] && [ -n "$spl" ]; then
    case $spl in /*) ;; *) spl=$root/$spl ;; esac
    [ -s "$spl" ] || refuse "DE25_SPL_HEX names $spl, which is not there"
    if [ "$hps_boot" = fpga-first ]; then
        step 9-pfg "$bin/quartus_pfg" -c "$sof" output_files/cadr_de25_hps.sof \
            -o hps_path="$spl"
        made=output_files/cadr_de25_hps.sof
    else
        step 9-pfg "$bin/quartus_pfg" -c "$sof" output_files/cadr_de25.rbf \
            -o hps_path="$spl" -o hps=on
        made=output_files/cadr_de25.hps.rbf
    fi
    [ -s "$made" ] || refuse "$made was not written; see $dir/9-pfg.log"
    say "$(wc -c < "$made" | tr -d ' ') bytes in $dir/$made, from $spl"
    "$bin/quartus_pfg" -i "$made" > 9-pfg-info.log 2>&1 || true
    grep -i -E "configuration order|debug access|IO hash|HPS/FPGA" 9-pfg-info.log \
        | sed 's/^[[:space:]]*/de25: /' || true
fi
