#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# ONE `fpgarc` AND FIVE INIT SCRIPTS: does each program get the flags it owns,
# and only those?
#
# **WHY THERE IS A CHECK HERE AT ALL.**  The card carries one file of flags
# for the CADR in the fabric, and that machine is served by several programs.
# Each of them refuses a flag it does not know, which is muir's behaviour and
# is the property worth keeping, so the file cannot be passed to any of them
# whole.  Each init script names the flags its own program owns and hands the
# file to the shared reader, which gives back those lines and no others.  Two
# ways that can be wrong and neither is visible at a prompt: a program handed
# somebody else's flag exits at once, with the init script printing OK and
# leaving a pid file --- which is exactly what a carriage return did to the
# Chaosnet on the board --- and a line no list claims is dropped in silence,
# so a setting somebody wrote on the card never happens.
#
# **IT RUNS THE REAL SCRIPTS, not a copy of their logic.**  Each is copied and
# a few constants in it are rewritten --- where the pack partition is, where
# the reader is, how long the network wait is --- and every rewrite is
# asserted to have matched exactly once, so renaming a constant fails this
# check by name instead of quietly testing nothing.  That is
# `mutations/list.txt`'s anchor discipline borrowed for a shell script, and it
# is chaos_test_boot.sh's own shape, which holds the Chaosnet script's wait.
#
# `start-stop-daemon`, `cadr-console`, `mount`, `mountpoint`, `ip` and
# `nslookup` are stubs on the PATH that record what they were asked and answer
# what the case wants.
#
# **WHAT THIS CANNOT DO: aim a mutation record at any of it.**  mutate.py
# compiles C, so a record naming a shell script would be BROKEN by
# construction.  The evidence that this check can fail is that it was written
# against the tree before the reader existed and did: run it with TREE set to
# a checkout of that tree.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
# The repository, from this file: src, cadr-common, package, buildroot, linux,
# arty-z7-20, boards.  TREE overrides it, which is how the before-and-after is
# measured against an older checkout.
TREE=${TREE:-$(cd "$HERE/../../../../../../.." && pwd)}
PKG="$TREE/boards/arty-z7-20/linux/buildroot/package"
READER="$PKG/cadr-common/src/fpgarc.sh"
MKSD="$TREE/boards/arty-z7-20/linux/mksd-buildroot.sh"
WORK=${WORK:-$HOME/.cache/muir-fpga-fpgarc-$$}

fails=0
cases=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
ok()   { echo "  ok: $*"; }

case_head() {
	cases=$((cases + 1))
	echo "case $cases: $*"
}

# ---------------------------------------------------------------------------
# The sandbox: a pack partition, a stub PATH, and the init scripts copied with
# their constants rewritten.
# ---------------------------------------------------------------------------

# One anchored rewrite in one file.  $1 the file, $2 the line as it must
# appear, $3 what to put there.
anchor() {
	n=$(grep -c "$2" "$1" 2>/dev/null || true)
	if [ "$n" != "1" ]; then
		fail "the anchor $2 matches $n times in $(basename "$1"), not once:" \
		     "this check has rotted against the script it is for"
		return 1
	fi
	sed -i "s|$2|$3|" "$1"
	return 0
}

sandbox() {
	rm -rf "$WORK"
	mkdir -p "$WORK/bin" "$WORK/packs" "$WORK/run" "$WORK/mnt"
	: > "$WORK/daemon.calls"
	: > "$WORK/console.calls"
	: > "$WORK/ip.calls"
	: > "$WORK/nslookup.calls"

	cat > "$WORK/bin/start-stop-daemon" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/daemon.calls"
exit 0
EOF
	# The console.  \$CONSOLE_HALTS decides whether `halt` works, so that a
	# console which cannot reach the machine is a case of its own.
	cat > "$WORK/bin/cadr-console" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/console.calls"
case "\$1" in
halt) [ "\${CONSOLE_HALTS:-yes}" = yes ] ;;
*) : ;;
esac
EOF
	# The two the disk script uses on the card.  Nothing is mounted here:
	# the pack partition is a directory the rewrite points it at, and the
	# script's own message for a partition it could not mount is part of
	# what is asserted.
	cat > "$WORK/bin/mountpoint" <<EOF
#!/bin/sh
exit 1
EOF
	cat > "$WORK/bin/mount" <<EOF
#!/bin/sh
exit 1
EOF
	# The Chaosnet script's network probes: ready at once, every name
	# resolving, because the wait itself is chaos_test_boot.sh's to hold.
	cat > "$WORK/bin/ip" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/ip.calls"
case "\$*" in
*addr*) echo "2: eth0    inet 192.0.2.17/24 brd 192.0.2.255 scope global eth0" ;;
*route*) echo "default via 192.0.2.1 dev eth0" ;;
esac
exit 0
EOF
	cat > "$WORK/bin/nslookup" <<EOF
#!/bin/sh
for a; do case "\$a" in -*) ;; *) echo "\$a" >> "$WORK/nslookup.calls" ;; esac; done
exit 0
EOF
	chmod +x "$WORK/bin/"*
}

# Copy one init script and rewrite the constants that would otherwise reach
# the real board.  $1 is the package directory's name, $2 the script's.
prepare() {
	src="$PKG/$1/$2"
	dst="$WORK/$2"
	if [ ! -f "$src" ]; then
		fail "$2 is not at $src"
		return 1
	fi
	cp "$src" "$dst" || return 1
	chmod +x "$dst"
	anchor "$dst" "^PACKS=/mnt/packs\$" "PACKS=$WORK/packs" || return 1
	anchor "$dst" "^FPGARC_SH=/usr/share/cadr/fpgarc.sh\$" \
	              "FPGARC_SH=$READER" || return 1
	case "$2" in
	S87cadr-chaosnet)
		anchor "$dst" "^WAIT_SECONDS=30\$" "WAIT_SECONDS=1" || return 1
		;;
	S80cadr-disk-packs)
		anchor "$dst" "^BOOT=/mnt/card\$" "BOOT=$WORK/mnt/card" || return 1
		anchor "$dst" "^HELD=/var/run/cadr-held\$" "HELD=$WORK/run/cadr-held" || return 1
		;;
	esac
	return 0
}

run_script() {
	: > "$WORK/daemon.calls"
	PATH="$WORK/bin:$PATH" "$WORK/$1" start > "$WORK/out.$1" 2>&1
	echo "$?" > "$WORK/status.$1"
}

# What the stubbed daemon was asked to run, for one script's last start.
given() { cat "$WORK/daemon.calls"; }

passes() {
	if grep -q -- "$1" "$WORK/daemon.calls"; then
		ok "$2 was given $1"
	else
		fail "$2 was not given $1; it was given: $(given)"
	fi
}

passes_not() {
	if grep -q -- "$1" "$WORK/daemon.calls"; then
		fail "$2 was given $1 and it is not its flag; it was given: $(given)"
	else
		ok "$2 was not given $1"
	fi
}

# ---------------------------------------------------------------------------
# 1.  The reader on its own.
# ---------------------------------------------------------------------------
HAVE_READER=no
if [ ! -f "$READER" ]; then
	case_head "the reader is where cadr-common installs it from"
	fail "there is no reader at $READER"
else
	HAVE_READER=yes
	. "$READER"

	sandbox
	RC="$WORK/packs/fpgarc"

	# One file with a line for every program on the board, written with
	# carriage returns as a card reader leaves them, a comment, a blank
	# line, leading space, an argument with a space in it and a bare flag.
	printf '%s\r\n' \
		'# the flags for the CADR in the fabric' \
		'' \
		'--chaos-address 3050' \
		'--chaos-udp 0.0.0.0:42042' \
		'  --keyboard-mapping /mnt/packs/a name with spaces.txt  ' \
		'--usb-scan-ms 500' \
		'--poll-us 200' \
		'--no-auto-boot' \
		'# --bow' \
		'--nobodys-flag 1' > "$RC"

	case_head "the reader splits a flag from its argument at the first space"
	got=$(eval "set -- $(fpgarc_args "$RC" --chaos-address)"; printf '[%s]' "$@")
	if [ "$got" = "[--chaos-address][3050]" ]; then
		ok "--chaos-address 3050 came back as two words"
	else
		fail "--chaos-address 3050 came back as $got"
	fi

	case_head "a carriage return does not reach the program"
	got=$(eval "set -- $(fpgarc_args "$RC" --chaos-udp)"; printf '%s' "$2")
	if [ "$got" = "0.0.0.0:42042" ]; then
		ok "the endpoint is the endpoint, with no carriage return on it"
	else
		fail "the endpoint came back as [$got]"
	fi

	case_head "an argument with spaces in it stays one word"
	got=$(eval "set -- $(fpgarc_args "$RC" --keyboard-mapping)"; printf '%s|%s' "$#" "$2")
	if [ "$got" = "2|/mnt/packs/a name with spaces.txt" ]; then
		ok "the mapping file is one argument, trimmed at both ends"
	else
		fail "the mapping file came back as [$got]"
	fi

	case_head "an argument with a quote in it survives"
	printf "%s\r\n" "--keyboard-mapping /mnt/packs/it's here.txt" > "$WORK/packs/quoted"
	got=$(eval "set -- $(fpgarc_args "$WORK/packs/quoted" --keyboard-mapping)"; printf '%s' "$2")
	if [ "$got" = "/mnt/packs/it's here.txt" ]; then
		ok "a single quote in an argument comes back as itself"
	else
		fail "the quoted argument came back as [$got]"
	fi

	case_head "a bare flag is one word and is found by name"
	got=$(eval "set -- $(fpgarc_args "$RC" --no-auto-boot)"; printf '%s|%s' "$#" "$1")
	if [ "$got" = "1|--no-auto-boot" ]; then
		ok "--no-auto-boot is one word"
	else
		fail "--no-auto-boot came back as [$got]"
	fi
	if fpgarc_has "$RC" --no-auto-boot; then
		ok "fpgarc_has finds it"
	else
		fail "fpgarc_has does not find --no-auto-boot in a file that names it"
	fi
	if fpgarc_has "$RC" --bow; then
		fail "fpgarc_has found --bow, which is commented out in the file"
	else
		ok "a commented-out flag is not there"
	fi

	case_head "a flag no list names goes to nobody, and nothing is refused"
	got=$(fpgarc_args "$RC" --chaos-address --keyboard-mapping)
	case "$got" in
	*--nobodys-flag*) fail "an unclaimed flag came back: $got" ;;
	*) ok "--nobodys-flag reached neither list" ;;
	esac
	if fpgarc_args "$RC" --nobodys-flag > /dev/null; then
		ok "and a list that DOES name it gets it, the reader refusing nothing"
	else
		fail "the reader failed on a file it should only have read"
	fi

	case_head "a file that is not there is not a file with nothing in it"
	if fpgarc_args "$WORK/packs/no-such-file" --chaos-address > "$WORK/absent"; then
		fail "the reader said it read a file that is not there"
	else
		ok "a missing file returns 1"
	fi
	if [ -s "$WORK/absent" ]; then
		fail "and it printed $(cat "$WORK/absent")"
	else
		ok "and it printed nothing"
	fi
	got=$(fpgarc_args "$RC" --not-in-this-file; echo "rc=$?")
	if [ "$got" = "rc=0" ]; then
		ok "a file with nothing of mine in it returns 0 and prints nothing"
	else
		fail "a file with nothing of mine in it gave [$got]"
	fi
fi

# ---------------------------------------------------------------------------
# 2.  One file, five scripts, and each program gets its own flags.
# ---------------------------------------------------------------------------
sandbox
RC="$WORK/packs/fpgarc"
printf '%s\r\n' \
	'# one file for the whole station' \
	'--chaos-address 3050' \
	'--chaos-udp 0.0.0.0:42042' \
	'--chaos-udp-peer 3060@a-host.invalid:42043' \
	'--keyboard-mapping /mnt/packs/keys.txt' \
	'--bow' \
	'--poll-us 250' \
	'--quiet' \
	'--usb-scan-ms 500' \
	'--usb-grab' \
	'--no-auto-boot' > "$RC"

case_head "the Chaosnet program gets its own flags and nobody else's"
if prepare cadr-chaosnet S87cadr-chaosnet; then
	run_script S87cadr-chaosnet
	passes "--chaos-address 3050" "cadr-chaosnet"
	passes "--chaos-udp-peer 3060@a-host.invalid:42043" "cadr-chaosnet"
	passes_not "--keyboard-mapping" "cadr-chaosnet"
	passes_not "--usb-grab" "cadr-chaosnet"
	passes_not "--no-auto-boot" "cadr-chaosnet"
	passes_not "--poll-us" "cadr-chaosnet"
fi

case_head "the screen gets its own flags and nobody else's"
if prepare cadr-terminal S85cadr-terminal; then
	run_script S85cadr-terminal
	passes "--keyboard-mapping /mnt/packs/keys.txt" "cadr-terminal"
	passes "--bow" "cadr-terminal"
	passes_not "--chaos-address" "cadr-terminal"
	passes_not "--usb-scan-ms" "cadr-terminal"
	passes_not "--no-auto-boot" "cadr-terminal"
	passes_not "--quiet" "cadr-terminal"
fi

case_head "the serial line gets its own flags and nobody else's"
if prepare cadr-serial S86cadr-serial; then
	run_script S86cadr-serial
	passes "--poll-us 250" "cadr-serial"
	passes "--quiet" "cadr-serial"
	passes "--port 7641" "cadr-serial"
	passes_not "--chaos-udp" "cadr-serial"
	passes_not "--keyboard-mapping" "cadr-serial"
	passes_not "--usb-grab" "cadr-serial"
fi

case_head "the USB input gets its own flags and nobody else's"
if prepare cadr-usb-input S88cadr-usb-input; then
	run_script S88cadr-usb-input
	passes "--usb-scan-ms 500" "cadr-usb-input"
	passes "--usb-grab" "cadr-usb-input"
	passes_not "--chaos-address" "cadr-usb-input"
	passes_not "--keyboard-mapping" "cadr-usb-input"
	passes_not "--bow" "cadr-usb-input"
fi

# **AND THIS CHECK CAN SEE A LIST THAT IS WRONG.**  Everything above is an
# absence --- a program not given somebody else's flag --- and an absence is
# what a check that is looking at the wrong thing also reports.  So one script
# is given a list that claims a flag which is not its, and the flag must then
# reach the program: what the four cases above assert is the list deciding,
# and not the harness failing to look.
case_head "a list that claims another program's flag does get it, so the absences mean something"
sandbox
printf '%s\r\n' '--chaos-address 3050' '--bow' > "$RC"
if prepare cadr-terminal S85cadr-terminal; then
	anchor "$WORK/S85cadr-terminal" '^case "\$1" in$' \
	       'FLAGS="$FLAGS --chaos-address"\ncase "$1" in' && {
		run_script S85cadr-terminal
		passes "--chaos-address 3050" "cadr-terminal with a widened list"
		passes "--bow" "cadr-terminal with a widened list"
	}
fi

case_head "the card's flag wins over the mapping file found beside it"
if prepare cadr-terminal S85cadr-terminal; then
	printf 'key 0 0\n' > "$WORK/packs/terminal.keyboard.mapping.txt"
	printf '%s\r\n' '--keyboard-mapping /mnt/packs/from-the-card.txt' > "$RC"
	run_script S85cadr-terminal
	# The file found beside it is passed first and the card's after, so
	# the program's own rule --- a flag given later wins --- settles it.
	case "$(cat "$WORK/daemon.calls")" in
	*"--keyboard-mapping $WORK/packs/terminal.keyboard.mapping.txt"*"--keyboard-mapping /mnt/packs/from-the-card.txt"*)
		ok "the card's line comes last, so the program takes it" ;;
	*)
		fail "the two mapping flags are not in that order: $(given)" ;;
	esac
fi

# ---------------------------------------------------------------------------
# 3.  The boot button: --no-auto-boot holds the machine before the drive comes
#     present.
# ---------------------------------------------------------------------------
case_head "--no-auto-boot halts the machine and leaves the marker"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	printf '%s\r\n' '--chaos-address 3050' '--no-auto-boot' > "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	if grep -qx "halt" "$WORK/console.calls"; then
		ok "the console was told to halt"
	else
		fail "the console was not told to halt; it was told: $(cat "$WORK/console.calls")"
	fi
	if [ -f "$WORK/run/cadr-held" ]; then
		ok "the hold marker stands"
	else
		fail "there is no hold marker"
	fi
	if grep -q "cadr-boot: --no-auto-boot: the machine is held" "$WORK/out.S80cadr-disk-packs"; then
		ok "and the console says so"
	else
		fail "the console does not say the machine is held; it says:"
		sed 's/^/        /' "$WORK/out.S80cadr-disk-packs"
	fi
	if grep -q "cadr-console boot" "$WORK/out.S80cadr-disk-packs" &&
	   grep -q "BTN0" "$WORK/out.S80cadr-disk-packs"; then
		ok "and names both ways to press the button"
	else
		fail "the line does not name cadr-console boot and BTN0"
	fi
	# The halt is before the drive: the pack program is what presents it,
	# and a machine held after that has already been let go.
	if [ -s "$WORK/console.calls" ] && [ -s "$WORK/daemon.calls" ]; then
		ok "the pack program was started, after the halt"
	else
		fail "the pack program was not started"
	fi
fi

case_head "without the flag nothing is halted and nothing is said"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	printf '%s\r\n' '--chaos-address 3050' > "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	if [ -s "$WORK/console.calls" ]; then
		fail "the console was told: $(cat "$WORK/console.calls")"
	else
		ok "the console was not told anything"
	fi
	if [ -f "$WORK/run/cadr-held" ]; then
		fail "a hold marker was left by a board that boots itself"
	else
		ok "there is no hold marker"
	fi
	if grep -q "cadr-boot" "$WORK/out.S80cadr-disk-packs"; then
		fail "the console says something about the boot button and should not:"
		sed 's/^/        /' "$WORK/out.S80cadr-disk-packs"
	else
		ok "the console says nothing about the boot button"
	fi
	if [ -s "$WORK/daemon.calls" ]; then
		ok "the pack program was started"
	else
		fail "the pack program was not started"
	fi
fi

case_head "a card with no fpgarc at all boots itself"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	rm -f "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	if [ -s "$WORK/console.calls" ]; then
		fail "the console was told: $(cat "$WORK/console.calls")"
	else
		ok "the console was not told anything"
	fi
	if [ -s "$WORK/daemon.calls" ]; then
		ok "the pack program was started"
	else
		fail "the pack program was not started"
	fi
fi

case_head "a marker left standing from before is removed at start"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	printf '%s\r\n' '--chaos-address 3050' > "$WORK/packs/fpgarc"
	echo "a hold that is over" > "$WORK/run/cadr-held"
	run_script S80cadr-disk-packs
	if [ -f "$WORK/run/cadr-held" ]; then
		fail "the stale marker still stands, so the console would refuse start on a running machine"
	else
		ok "the stale marker is gone"
	fi
fi

case_head "a console that cannot halt says so and does not mark"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	printf '%s\r\n' '--no-auto-boot' > "$WORK/packs/fpgarc"
	: > "$WORK/daemon.calls"
	CONSOLE_HALTS=no PATH="$WORK/bin:$PATH" \
		"$WORK/S80cadr-disk-packs" start > "$WORK/out.held" 2>&1
	if [ -f "$WORK/run/cadr-held" ]; then
		fail "a marker was left for a halt that did not happen"
	else
		ok "no marker for a halt that did not happen"
	fi
	if grep -q "could not halt the machine" "$WORK/out.held"; then
		ok "and the console says so"
	else
		fail "the console does not say the halt failed; it says:"
		sed 's/^/        /' "$WORK/out.held"
	fi
	if [ -s "$WORK/daemon.calls" ]; then
		ok "and the boot goes on: the pack program was started anyway"
	else
		fail "the boot stopped: the pack program was never started"
	fi
fi

case_head "the step never blocks the boot"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	printf '%s\r\n' '--no-auto-boot' > "$WORK/packs/fpgarc"
	started=$(date +%s)
	run_script S80cadr-disk-packs
	took=$(( $(date +%s) - started ))
	if [ "$took" -le 5 ]; then
		ok "it took ${took}s, which is not a wait"
	else
		fail "it took ${took}s: something in the boot button's step waits"
	fi
fi

# ---------------------------------------------------------------------------
# 4.  The card script writes the line, commented out unless asked.
# ---------------------------------------------------------------------------
#
# The generator is lifted out of mksd-buildroot.sh by its own two anchors and
# run on its own, because the rest of that script wants a bitstream, a card
# image and a Buildroot output tree.  The anchors are asserted the same way
# the init scripts' constants are.
generate_fpgarc() {
	rm -rf "$WORK/gen"
	mkdir -p "$WORK/gen/packs"
	awk '/^CHAOS_ADDR=\$\{CHAOS_ADDR_FPGA/ {on=1}
	     on {print}
	     /^\} > "\$OUT\/packs\/fpgarc"$/ {if (on) exit}' "$MKSD" > "$WORK/gen/gen.sh"
	if [ ! -s "$WORK/gen/gen.sh" ]; then
		fail "the fpgarc generator is not where this check looks in mksd-buildroot.sh"
		return 1
	fi
	if [ "$(grep -c '^} > "\$OUT/packs/fpgarc"$' "$WORK/gen/gen.sh")" != "1" ]; then
		fail "the fpgarc generator's end is not where this check looks"
		return 1
	fi
	( set -u
	  OUT="$WORK/gen"
	  NO_AUTO_BOOT=$1
	  CHAOS_PEER=""
	  CHAOS_DEFAULT_PEER=""
	  . "$WORK/gen/gen.sh" ) || return 1
	return 0
}

case_head "the card is written with the boot button pressed by default"
sandbox
if generate_fpgarc ""; then
	if grep -q '^#--no-auto-boot' "$WORK/gen/packs/fpgarc"; then
		ok "the line is there and commented out"
	else
		fail "there is no commented --no-auto-boot line in what the card script wrote"
	fi
	if grep -q '^--no-auto-boot' "$WORK/gen/packs/fpgarc"; then
		fail "and it is also live, which it must not be"
	else
		ok "and it is not live"
	fi
	if grep -q 'the machine is held at boot' "$WORK/gen/packs/fpgarc"; then
		ok "and the sentence explaining it is beside it"
	else
		fail "the line has no sentence explaining it"
	fi
	# The reader must agree with the card script about what a comment is.
	if [ "$HAVE_READER" != yes ]; then
		fail "there is no reader to agree with the card script"
	elif fpgarc_has "$WORK/gen/packs/fpgarc" --no-auto-boot; then
		fail "the reader takes the commented line as a flag"
	else
		ok "and the reader does not take it as a flag"
	fi
fi

case_head "NO_AUTO_BOOT=1 makes the same line live"
sandbox
if generate_fpgarc "1"; then
	if grep -q '^--no-auto-boot' "$WORK/gen/packs/fpgarc"; then
		ok "the line is live"
	else
		fail "the --no-auto-boot line is not live in what the card script wrote"
	fi
	if grep -q 'the machine is held at boot' "$WORK/gen/packs/fpgarc"; then
		ok "and the same sentence is beside it"
	else
		fail "the live line has no sentence explaining it"
	fi
	if [ "$HAVE_READER" != yes ]; then
		fail "there is no reader to find the live line"
	elif fpgarc_has "$WORK/gen/packs/fpgarc" --no-auto-boot; then
		ok "and the reader finds it"
	else
		fail "the reader does not find the live line"
	fi
	# Carriage returns: the card is FAT32 and the file is written CRLF, so
	# a reader that did not strip them would hand the shell a flag with a
	# carriage return on it and nothing would match.
	if grep -q "$(printf '\r')$" "$WORK/gen/packs/fpgarc"; then
		ok "and the card's file is written with carriage returns, as it must be"
	else
		fail "the card's file has no carriage returns"
	fi
fi

echo
if [ "$fails" = 0 ]; then
	echo "fpgarc: $cases cases, one file of flags reaches five programs and each gets its own"
	exit 0
fi
echo "fpgarc: $fails failures in $cases cases"
exit 1
