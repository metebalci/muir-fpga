#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# ONE `fpgarc` AND FIVE INIT SCRIPTS: does each program get the flags it owns,
# and only those?
#
# **WHY THERE IS A CHECK HERE AT ALL.**  The card carries one file of flags
# for the CADR in the fabric, and that machine is served by several programs.
# Each of them refuses a flag it does not know, which is muir's behavior and
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
STARTER="$PKG/cadr-common/src/daemon.sh"
CLOCKSH="$PKG/cadr-common/src/clock.sh"
MKSD="$TREE/boards/arty-z7-20/linux/mksd-buildroot.sh"
MKSDREL="$TREE/boards/arty-z7-20/linux/mksd-release.sh"
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
	: > "$WORK/date.calls"
	: > "$WORK/umount.calls"
	: > "$WORK/order.calls"

	# **THE REAL ONE FORKS THE PROGRAM AND CLOSES ITS OUTPUT**, which is
	# what made a refused flag silent, so this does the same: it records
	# what it was asked, runs the program named by --exec in the
	# background with stdout and stderr on /dev/null, and writes the pid
	# where -p says.  A stub that only recorded could not tell a program
	# that started from one that refused its flags and went, which is the
	# whole of what `cadr_daemon` is for.
	cat > "$WORK/bin/start-stop-daemon" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/daemon.calls"
_pidfile=""
_prog=""
while [ \$# -gt 0 ]; do
	case "\$1" in
	-p) _pidfile=\$2; shift ;;
	--exec) _prog=\$2; shift ;;
	--) shift; break ;;
	esac
	shift
done
[ -n "\$_prog" ] || exit 0
"\$_prog" "\$@" > /dev/null 2>&1 &
[ -n "\$_pidfile" ] && echo \$! > "\$_pidfile"
exit 0
EOF
	# The five programs, each a stand-in that refuses the flag \$REFUSE
	# names --- on stderr, which is where every one of them refuses --- and
	# otherwise runs, which is what a daemon does.  The name is its own, so
	# a refusal printed here is attributable the way the real one is.
	for _p in cadr-terminal cadr-serial cadr-usb-input cadr-chaosnet cadr-disk-packs; do
		cat > "$WORK/bin/$_p" <<EOF
#!/bin/sh
for a; do
	if [ -n "\${REFUSE:-}" ] && [ "\$a" = "\${REFUSE}" ]; then
		echo "$_p: unrecognized option '\$a'" >&2
		exit 2
	fi
done
exec sleep 8
EOF
	done
	# The console.  \$CONSOLE_HALTS decides whether `halt` works, so that a
	# console which cannot reach the machine is a case of its own, and
	# \$CONSOLE_SWITCH whether SW0 held the machine at the last reset ---
	# `cadr-console switch` answers that with its exit status, 0 for held,
	# as `mountpoint -q` and `fpgarc_has` answer a question with theirs.
	# The default is NOT held, which is the ordinary board.
	cat > "$WORK/bin/cadr-console" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/console.calls"
# \$CONSOLE_LAMPS decides whether \`blinking-leds off\` got steady lamps,
# which the real console answers with its status.  Its words come after
# \`--log /dev/console\`, so that one is looked for anywhere on the line.
case "\$1" in
halt) [ "\${CONSOLE_HALTS:-yes}" = yes ] ;;
switch) [ "\${CONSOLE_SWITCH:-no}" = yes ] ;;
*)
	case "\$*" in
	*"blinking-leds off"*) [ "\${CONSOLE_LAMPS:-yes}" = yes ] ;;
	*"hdmi-sleep"*) [ "\${CONSOLE_SLEEP:-yes}" = yes ] ;;
	*) : ;;
	esac
	;;
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
	# **THE CLOCK, WHICH THIS CHECK OWNS.**  The board has no real-time
	# clock, so `date` is the only thing the clock step reads and the only
	# thing it writes, and a check that let the real one through would set
	# the build host's clock.  This one keeps the board's clock in a file:
	# a read prints it and a `-s` writes it, so a step that sets the clock
	# and then reads it back sees what it set.  \$DATE_SETS=no is a clock
	# the board will not take, which is a case of its own.
	#
	# The value is kept as the fourteen digits, whatever form the setter
	# used, by dropping everything that is not a digit --- so what is
	# asserted is `date.calls`, which has the words exactly as the step
	# said them.
	echo 19700101000005 > "$WORK/now"
	cat > "$WORK/bin/date" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/date.calls"
_set=""
_fmt=""
while [ \$# -gt 0 ]; do
	case "\$1" in
	-s) _set=\$2; shift ;;
	-u) ;;
	+*) _fmt=\$1 ;;
	esac
	shift
done
if [ -n "\$_set" ]; then
	# **WHERE IN THE BOOT THE CLOCK WAS SET**, which is the half of this the
	# words alone cannot show: the step exists so that the machine, the
	# programs and any file written agree from the first second, and a clock
	# set after the pack program had presented a drive would be a band read
	# with the date still at the epoch.
	_d=after; [ -s "$WORK/daemon.calls" ] || _d=before
	_c=after; [ -s "$WORK/console.calls" ] || _c=before
	echo "the clock was set \$_d the pack program started and \$_c the console was asked anything" \
		>> "$WORK/order.calls"
	if [ "\${DATE_SETS:-yes}" != yes ]; then
		echo "date: invalid date '\$_set'" >&2
		exit 1
	fi
	printf '%s' "\$_set" | tr -cd '0-9' > "$WORK/now"
fi
_now=\$(cat "$WORK/now" 2>/dev/null)
[ -n "\$_now" ] || _now=19700101000000
case "\$_fmt" in
"+%s") echo 0 ;;
*) echo "\$_now" ;;
esac
exit 0
EOF
	# The two the disk script's `stop` uses.  \`umount\` records whether the
	# clock had been saved by the time it ran, which is the only way to see
	# that the save happens while the partition is still the card's: a save
	# after the unmount would write into the root filesystem's RAM disk and
	# be lost at the next boot, with the file there to find either way.
	cat > "$WORK/bin/umount" <<EOF
#!/bin/sh
if [ -f "$WORK/packs/clock" ]; then
	echo "the clock was saved before \$1 was unmounted" >> "$WORK/umount.calls"
else
	echo "\$1 was unmounted before the clock was saved" >> "$WORK/umount.calls"
fi
exit 0
EOF
	cat > "$WORK/bin/sync" <<EOF
#!/bin/sh
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
	anchor "$dst" "^DAEMON_SH=/usr/share/cadr/daemon.sh\$" \
	              "DAEMON_SH=$STARTER" || return 1
	# The program itself, so that the stand-in on the stub PATH is what is
	# started and what is run again for its refusal.  The name is read out
	# of the script rather than written here, so a script that renames its
	# own program fails the anchor by name instead of quietly testing a
	# program that is not there.
	prog=$(sed -n 's|^PROG=/usr/bin/||p' "$dst")
	if [ -z "$prog" ]; then
		fail "$2 has no PROG=/usr/bin/... line for this check to point at the stub"
		return 1
	fi
	anchor "$dst" "^PROG=/usr/bin/$prog\$" "PROG=$WORK/bin/$prog" || return 1
	# And the pid file, which the stub daemon now really writes and
	# `cadr_daemon` really reads: /var/run belongs to the board.
	anchor "$dst" "^PIDFILE=/var/run/$prog.pid\$" "PIDFILE=$WORK/run/$prog.pid" || return 1
	case "$2" in
	S87cadr-chaosnet)
		anchor "$dst" "^WAIT_SECONDS=30\$" "WAIT_SECONDS=1" || return 1
		;;
	S80cadr-disk-packs)
		anchor "$dst" "^BOOT=/mnt/card\$" "BOOT=$WORK/mnt/card" || return 1
		anchor "$dst" "^HELD=/var/run/cadr-held\$" "HELD=$WORK/run/cadr-held" || return 1
		# The clock's own shell, cadr-common's third file on the target,
		# beside the reader and the daemon starter.
		anchor "$dst" "^CLOCK_SH=/usr/share/cadr/clock.sh\$" \
		              "CLOCK_SH=$CLOCKSH" || return 1
		;;
	esac
	return 0
}

run_script() {
	: > "$WORK/daemon.calls"
	: > "$WORK/date.calls"
	: > "$WORK/order.calls"
	# A pid file left by an earlier run in this sandbox would answer for
	# this one: the stand-in programs live for a few seconds, so a stale
	# live pid is exactly the thing that would make a failed start look
	# like a good one.
	rm -f "$WORK"/run/*.pid "$WORK"/run/*.pid.why
	# Where the reader remembers what each script claimed, so that the last
	# one can name the lines nobody took.  /var/run belongs to the board;
	# the reader takes this from the environment for exactly this reason.
	FPGARC_CLAIMED="$WORK/run/claimed" \
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

# How many times a flag stands as a word of the command line the daemon was
# given.  A flag passed twice works --- the program takes the last one --- so
# nothing but a count can see it.
given_count() {
	tr ' ' '\n' < "$WORK/daemon.calls" | grep -cx -- "$1" || true
}

# The flag stands exactly once, and the word after it is $3 when $3 is given.
passes_once() {
	_n=$(given_count "$1")
	if [ "$_n" != 1 ]; then
		fail "$2 was given $1 $_n times and once is right; it was given: $(given)"
		return 1
	fi
	if [ $# -lt 3 ]; then
		ok "$2 was given $1 exactly once"
		return 0
	fi
	if grep -q -- "$1 $3" "$WORK/daemon.calls"; then
		ok "$2 was given $1 $3 exactly once"
	else
		fail "$2 was given $1 once but not with $3; it was given: $(given)"
	fi
}

# ---------------------------------------------------------------------------
# 1.  The reader on its own.
# ---------------------------------------------------------------------------
if [ ! -f "$STARTER" ]; then
	case_head "the daemon starter is where cadr-common installs it from"
	fail "there is no daemon starter at $STARTER: the init scripts source it, so"
	fail "every one of them would die at its own first line"
fi

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

	# **THE CLAIMS FILE IS NOT ALWAYS THERE TO BE WRITTEN, AND THE READER
	# MUST SAY NOTHING ABOUT THAT.**  Where the claims are remembered is
	# /var/run, which belongs to the board, so a call made anywhere else
	# --- this check's own, or somebody's at a prompt --- appends to a path
	# it may not be allowed to create.  A shell prints `cannot create ...:
	# Permission denied` for a redirection it cannot open, and that message
	# went out ahead of the `2>/dev/null` written to catch it: seventeen
	# lines of it in this check's own output.  A reader asked a question
	# must answer it and say nothing else.
	#
	# The path below cannot be created by anybody, root included, because
	# the directory above it is not there.  That is what makes this case
	# say the same thing whoever runs it.
	case_head "a claims file it cannot write is silent, and nothing else changes"
	CLAIMED_WAS=$FPGARC_CLAIMED
	FPGARC_CLAIMED="$WORK/no-such-directory/claimed"
	fpgarc_args "$RC" --chaos-address > "$WORK/claim.out" 2> "$WORK/claim.err"
	if [ -s "$WORK/claim.err" ]; then
		fail "the reader said something about the claims file:"
		sed 's/^/        /' "$WORK/claim.err"
	else
		ok "the reader said nothing"
	fi
	got=$(eval "set -- $(cat "$WORK/claim.out")"; printf '[%s]' "$@")
	if [ "$got" = "[--chaos-address][3050]" ]; then
		ok "and answered the question it was asked"
	else
		fail "and answered [$got]"
	fi
	if fpgarc_has "$RC" --no-auto-boot 2> "$WORK/has.err"; then
		ok "fpgarc_has still finds a flag the file names"
	else
		fail "fpgarc_has does not find --no-auto-boot when the claims file cannot be written"
	fi
	if [ -s "$WORK/has.err" ]; then
		fail "and fpgarc_has said something about the claims file:"
		sed 's/^/        /' "$WORK/has.err"
	else
		ok "and said nothing"
	fi
	# Nothing was recorded, so the report must say nothing rather than
	# name every flag in the file as having gone to nobody.
	got=$(fpgarc_say_unclaimed "$RC" 2>&1)
	if [ -z "$got" ]; then
		ok "and no claim being remembered is a silent report, not a wrong one"
	else
		fail "the report named lines on a boot where no claim was recorded: $got"
	fi

	case_head "and no claims file at all is the same"
	FPGARC_CLAIMED=
	fpgarc_args "$RC" --chaos-address > "$WORK/claim.out" 2> "$WORK/claim.err"
	if [ -s "$WORK/claim.err" ]; then
		fail "the reader said something with no claims file named:"
		sed 's/^/        /' "$WORK/claim.err"
	else
		ok "the reader said nothing"
	fi
	got=$(eval "set -- $(cat "$WORK/claim.out")"; printf '[%s]' "$@")
	if [ "$got" = "[--chaos-address][3050]" ]; then
		ok "and answered the question it was asked"
	else
		fail "and answered [$got]"
	fi
	got=$(fpgarc_say_unclaimed "$RC" 2>&1)
	if [ -z "$got" ]; then
		ok "and the report is silent"
	else
		fail "the report named lines with no claims file: $got"
	fi
	FPGARC_CLAIMED=$CLAIMED_WAS
fi

# ---------------------------------------------------------------------------
# 1b.  THE CLOCK'S OWN ARITHMETIC: what is a date, what is a time, and which of
#      two instants is later.
# ---------------------------------------------------------------------------
#
# **WHY THIS IS TRIED HERE AND NOT ONLY THROUGH THE INIT SCRIPT.**  The two
# flags carry the only numbers on the card that nothing else can check: a
# misspelled endpoint is refused by the program that gets it, but `--date
# 20260931` is eight digits and looks exactly like a date.  What decides is the
# parsing, so the parsing is what this aims at, one process a case, with the
# wrong inputs beside the right ones.  A checker that only tried the good ones
# would pass on a step that took every eight digits it was given.
#
# `clock.sh` is cadr-common's third file on the target, beside the reader and
# the daemon starter, for that reason: the step is a dozen lines of boot and
# the arithmetic under it is what has to be tried by itself.
HAVE_CLOCK=no
if [ ! -f "$CLOCKSH" ]; then
	case_head "the clock's shell is where cadr-common installs it from"
	fail "there is no clock shell at $CLOCKSH: S80cadr-disk-packs sources it, so"
	fail "the disk pack program's whole init script would die at its own first line"
else
	HAVE_CLOCK=yes
	. "$CLOCKSH"

	case_head "a date is eight digits naming a day that exists"
	for d in 20260920 20260101 19700101 19991231 20260930 20240229 20000229 00010101; do
		if cadr_clock_date_ok "$d"; then
			ok "$d is a date"
		else
			fail "$d was refused and it is a date"
		fi
	done

	# **AND EVERY OTHER EIGHT CHARACTERS IS NOT ONE.**  The three that matter
	# most are the last three: a day the month has not, and the two leap
	# years, which are the mutation just outside the bound.  A step that took
	# 20260229 would hand `date` the 29th of a February that has 28 days, and
	# the kernel would silently make it the first of March --- a setting
	# somebody wrote on the card and did not get, which is the failure this
	# whole file exists to prevent.
	case_head "and nothing else is a date"
	for bad in \
		"|nothing at all" \
		"2026092|seven digits" \
		"202609201|nine digits" \
		"2026-09-20|a date with dashes in it" \
		"2026092a|a letter where a digit belongs" \
		"abcdefgh|letters" \
		"20260020|a month of 00" \
		"20261320|a month of 13" \
		"20260900|a day of 00" \
		"20260932|a day of 32" \
		"20260931|the 31st of September, which has thirty days" \
		"20260229|the 29th of February in a year that is not a leap year" \
		"19000229|the 29th of February in 1900, which is not a leap year" \
		" 2026092|a leading space in eight characters" \
		"2026092 |a trailing space in eight characters" \
		"2026 920|a space in the middle" \
		" 20260920|a date with a space in front of it" \
		"20260920 |a date with a space after it" \
	; do
		v=${bad%%|*}
		why=${bad#*|}
		if cadr_clock_date_ok "$v"; then
			fail "[$v] was taken as a date and it is $why"
		else
			ok "[$v] is refused: $why"
		fi
	done

	case_head "a time is four or six digits on a 24-hour clock"
	for t in 0000 1438 2359 000000 143800 143805 235959 0830; do
		if cadr_clock_time_ok "$t"; then
			ok "$t is a time"
		else
			fail "$t was refused and it is a time"
		fi
	done

	case_head "and nothing else is a time"
	for bad in \
		"|nothing at all" \
		"14|two digits" \
		"143|three digits" \
		"14385|five digits" \
		"1438000|seven digits" \
		"14:38|a time with a colon in it" \
		"14a8|a letter where a digit belongs" \
		"abcd|letters" \
		"2400|an hour of 24" \
		"9900|an hour of 99" \
		"1460|a minute of 60" \
		"146000|a minute of 60 with seconds after it" \
		"143860|a second of 60" \
		" 438|a leading space in four characters" \
		"143 |a trailing space in four characters" \
		"14 8|a space in the middle" \
		" 1438|a time with a space in front of it" \
		"1438 |a time with a space after it" \
	; do
		v=${bad%%|*}
		why=${bad#*|}
		if cadr_clock_time_ok "$v"; then
			fail "[$v] was taken as a time and it is $why"
		else
			ok "[$v] is refused: $why"
		fi
	done

	case_head "a flag moves its own field of the clock and leaves the other"
	for triple in \
		"19700101000005 with_date 20260920 20260920000005" \
		"19700101000005 with_time 1438 19700101143800" \
		"19700101000005 with_time 143805 19700101143805" \
		"20260920143805 with_date 20261231 20261231143805" \
		"20260920143805 with_time 0000 20260920000000" \
	; do
		set -- $triple
		got=$(cadr_clock_$2 "$1" "$3")
		if [ "$got" = "$4" ]; then
			ok "$1 with $2 $3 is $4"
		else
			fail "$1 with $2 $3 came out as $got, not $4"
		fi
	done
	got=$(cadr_clock_with_time "$(cadr_clock_with_date 19700101000005 20260920)" 1438)
	if [ "$got" = 20260920143800 ]; then
		ok "and both together are 2026-09-20 14:38:00"
	else
		fail "both together came out as $got, not 20260920143800"
	fi

	# **THE COMPARISON IS WHAT KEEPS THE CLOCK FROM RUNNING BACKWARDS, so both
	# directions of every pair are asserted and so is the pair that is equal.**
	# One direction alone is what a reversed comparison also passes.
	case_head "one instant is later than another, and the reverse is not"
	for pair in \
		"20260920143801 20260920143800" \
		"20260920144000 20260920143959" \
		"20260921000000 20260920235959" \
		"20261001000000 20260930235959" \
		"20270101000000 20261231235959" \
		"20260920143800 19700101000005" \
	; do
		set -- $pair
		if cadr_clock_later "$1" "$2"; then
			ok "$1 is later than $2"
		else
			fail "$1 was not called later than $2"
		fi
		if cadr_clock_later "$2" "$1"; then
			fail "$2 was called later than $1, so the comparison is the wrong way round"
		else
			ok "and $2 is not later than $1"
		fi
	done
	if cadr_clock_later 20260920143800 20260920143800; then
		fail "an instant was called later than itself"
	else
		ok "and an instant is not later than itself"
	fi

	case_head "fourteen digits are a date and a time together"
	for s in 20260920143805 19700101000000 20000229235959; do
		if cadr_clock_stamp_ok "$s"; then
			ok "$s is an instant"
		else
			fail "$s was refused and it is an instant"
		fi
	done
	for bad in \
		"|nothing at all" \
		"2026092014380|thirteen digits" \
		"202609201438050|fifteen digits" \
		"20260920243805|an hour of 24" \
		"20261320143805|a month of 13" \
		"20260931143805|the 31st of September" \
		"2026-09-20 14:38:05|the human form" \
	; do
		v=${bad%%|*}
		why=${bad#*|}
		if cadr_clock_stamp_ok "$v"; then
			fail "[$v] was taken as an instant and it is $why"
		else
			ok "[$v] is refused: $why"
		fi
	done

	case_head "and the human form is what a person reads"
	got=$(cadr_clock_human 20260920143805)
	if [ "$got" = "2026-09-20 14:38:05" ]; then
		ok "20260920143805 reads as 2026-09-20 14:38:05"
	else
		fail "20260920143805 reads as [$got]"
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
	'--serial 0.0.0.0:7641' \
	'--poll-us 250' \
	'--quiet' \
	'--usb-scan-ms 500' \
	'--usb-grab' \
	'--date 20260920' \
	'--time 1438' \
	'--no-auto-boot' > "$RC"

# **AND `--time` IS ON THAT FILE FOR A REASON OF ITS OWN.**  The word was the
# Chaosnet program's once: it named a time host that lived inside it, and the
# program still refuses it by name to say where the host went.  It is not in
# that program's list, so the card's line goes to the clock step and nowhere
# else --- and if it were ever claimed again, the program would be handed it
# and would exit at argument parsing, which is the whole Chaosnet gone on a
# boot that printed OK.  That is what the absence below is for.
case_head "the Chaosnet program gets its own flags and nobody else's"
if prepare cadr-chaosnet S87cadr-chaosnet; then
	run_script S87cadr-chaosnet
	passes "--chaos-address 3050" "cadr-chaosnet"
	passes "--chaos-udp-peer 3060@a-host.invalid:42043" "cadr-chaosnet"
	passes_not "--keyboard-mapping" "cadr-chaosnet"
	passes_not "--usb-grab" "cadr-chaosnet"
	passes_not "--no-auto-boot" "cadr-chaosnet"
	passes_not "--poll-us" "cadr-chaosnet"
	passes_not "--date" "cadr-chaosnet"
	passes_not "--time" "cadr-chaosnet"
fi

case_head "the screen gets its own flags and nobody else's"
if prepare cadr-terminal S85cadr-terminal; then
	run_script S85cadr-terminal
	passes "--keyboard-mapping /mnt/packs/keys.txt" "cadr-terminal"
	passes "--bow" "cadr-terminal"
	passes "--terminal 0.0.0.0:5900" "cadr-terminal"
	passes_not "--port" "cadr-terminal"
	passes_not "--chaos-address" "cadr-terminal"
	passes_not "--usb-scan-ms" "cadr-terminal"
	passes_not "--no-auto-boot" "cadr-terminal"
	passes_not "--quiet" "cadr-terminal"
	passes_not "--date" "cadr-terminal"
	passes_not "--time" "cadr-terminal"
fi

case_head "the serial line gets its own flags and nobody else's"
if prepare cadr-serial S86cadr-serial; then
	run_script S86cadr-serial
	passes "--poll-us 250" "cadr-serial"
	passes "--quiet" "cadr-serial"
	# **muir'S SPELLING, WHICH IS THE WHOLE OF WHY `--port` IS GONE.**  The
	# screen and the serial line both took `--port` and `--bind`, so no
	# list could claim either word and no `fpgarc` line could say where
	# either program listened.  Each has muir's own flag now, and this one
	# comes off the card: a file that says nothing about `--serial` is a
	# serial line that is off, which is the case below, so a file testing
	# the filter has to name it.
	passes "--serial 0.0.0.0:7641" "cadr-serial"
	passes_not "--port" "cadr-serial"
	passes_not "--chaos-udp" "cadr-serial"
	passes_not "--keyboard-mapping" "cadr-serial"
	passes_not "--usb-grab" "cadr-serial"
	passes_not "--date" "cadr-serial"
	passes_not "--time" "cadr-serial"
fi

case_head "the USB input gets its own flags and nobody else's"
if prepare cadr-usb-input S88cadr-usb-input; then
	run_script S88cadr-usb-input
	passes "--usb-scan-ms 500" "cadr-usb-input"
	passes "--usb-grab" "cadr-usb-input"
	passes_not "--chaos-address" "cadr-usb-input"
	passes_not "--keyboard-mapping" "cadr-usb-input"
	passes_not "--bow" "cadr-usb-input"
	passes_not "--date" "cadr-usb-input"
	passes_not "--time" "cadr-usb-input"
fi

# ---------------------------------------------------------------------------
# **WHERE A DAEMON WRITES IS `cadr_daemon`'s, AND IT IS TWO PLACES.**  Every
# one of these programs is started with `--log /dev/console --log
# /var/log/<name>.log`, so what it says is on the serial console, where a boot
# is watched, and in a file, where somebody with nothing but ssh can read it
# and follow it.  It used to be the console alone and each script said so
# itself, which is two ways for five scripts to disagree and one way for the
# key trace to go somewhere the person who asked for it could not see.
#
# The count is asserted as well as the two destinations: `--log` given once is
# the old board, and given three times would mean a script had gone on passing
# one of its own.
# ---------------------------------------------------------------------------
logs_to() {
	_n=$(given_count "--log")
	if [ "$_n" != 2 ]; then
		fail "$1 was given --log $_n times, wanting two --- the console and a" \
		     "file; it was given: $(given)"
	else
		ok "$1 was given --log twice"
	fi
	passes "--log /dev/console" "$1"
	passes "--log /var/log/$1.log" "$1"
}

case_head "every program is given both logs: the console and a file under /var/log"
for _pair in "cadr-chaosnet:S87cadr-chaosnet" "cadr-terminal:S85cadr-terminal" \
             "cadr-serial:S86cadr-serial" "cadr-usb-input:S88cadr-usb-input" \
             "cadr-disk-packs:S80cadr-disk-packs"; do
	_pkg=${_pair%%:*}
	_script=${_pair#*:}
	if prepare "$_pkg" "$_script"; then
		run_script "$_script"
		logs_to "$_pkg"
	fi
done

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

# ---------------------------------------------------------------------------
# 2b.  A DEFAULT IS PASSED ONLY WHERE THE CARD SAYS NOTHING.
# ---------------------------------------------------------------------------
#
# **THE FAULT.**  An init script writes its own endpoint out in full so that
# the script says what it does, and then appends the card's flags so that a
# card naming the same flag wins.  A card that did name it therefore got both,
# and the board ran `cadr-terminal --terminal 0.0.0.0:5900 --terminal
# 0.0.0.0:5900`.  The program takes the last one, so nothing was wrong with
# what ran --- and a `ps` listing on a board somebody is trying to understand
# read as a fault.  Measured on the board, on the screen and the serial line
# both.
#
# **WHAT IS HELD HERE.**  A script asks the reader whether the card names a
# flag before passing its own value for it, so each of these flags stands on
# the command line exactly once, with the card's value where the card has one
# and the script's where it has not.  A count is the only thing that can see
# this: both orderings run correctly, and every assertion in section 2 above
# would pass either way.
case_head "the screen's endpoint is passed once, and it is the card's when the card says one"
sandbox
if prepare cadr-terminal S85cadr-terminal; then
	printf '%s\r\n' '--terminal 0.0.0.0:5999' '--bow' > "$RC"
	run_script S85cadr-terminal
	passes_once "--terminal" "cadr-terminal" "0.0.0.0:5999"
	passes_not "0.0.0.0:5900" "cadr-terminal"
	passes "--bow" "cadr-terminal"
fi

case_head "and once, the script's own, when the card says nothing about it"
sandbox
if prepare cadr-terminal S85cadr-terminal; then
	printf '%s\r\n' '--bow' > "$RC"
	run_script S85cadr-terminal
	passes_once "--terminal" "cadr-terminal" "0.0.0.0:5900"
fi

case_head "and once with no card at all"
sandbox
if prepare cadr-terminal S85cadr-terminal; then
	rm -f "$RC"
	run_script S85cadr-terminal
	passes_once "--terminal" "cadr-terminal" "0.0.0.0:5900"
fi

case_head "the serial line's endpoint is passed once, and it is the card's when the card says one"
sandbox
if prepare cadr-serial S86cadr-serial; then
	printf '%s\r\n' '--serial 0.0.0.0:7999' '--quiet' > "$RC"
	run_script S86cadr-serial
	passes_once "--serial" "cadr-serial" "0.0.0.0:7999"
	passes_not "0.0.0.0:7641" "cadr-serial"
	passes "--quiet" "cadr-serial"
fi

# **AND A CARD THAT SAYS NOTHING ABOUT `--serial` IS A SERIAL LINE THAT IS
# OFF, WHICH IS NOT THE SAME AS THERE BEING NO CARD.**  muir gives `--serial`
# no default and serves no line without it; this program is the same program on
# a board.  A released card ships the line commented out under the sentence
# that says what it does, so a file that is there and does not name it is a
# card that was asked and said no --- and then the program is not started at
# all.  No file is nobody having been asked, and that board runs what it always
# ran.
#
# The two are one line apart in the script and the difference is invisible to
# anything but a case for each, which is why there are two.
case_head "and the serial line is off when the card is there and says nothing about it"
sandbox
if prepare cadr-serial S86cadr-serial; then
	printf '%s\r\n' '--quiet' > "$RC"
	run_script S86cadr-serial
	if [ -s "$WORK/daemon.calls" ]; then
		fail "cadr-serial was started for a card that says nothing about --serial:" \
		     "it was given: $(given)"
	else
		ok "cadr-serial was not started at all"
	fi
	if grep -q 'the serial line is off' "$WORK/out.S86cadr-serial"; then
		ok "and the console says the line is off"
	else
		fail "the console does not say the line is off; it says:"
		sed 's/^/        /' "$WORK/out.S86cadr-serial"
	fi
	if grep -q 'uncomment the --serial line' "$WORK/out.S86cadr-serial"; then
		ok "and says how to turn it on"
	else
		fail "the console does not say how to turn the line on"
	fi
fi

case_head "and once, the script's own, with no card at all"
sandbox
if prepare cadr-serial S86cadr-serial; then
	rm -f "$RC"
	run_script S86cadr-serial
	passes_once "--serial" "cadr-serial" "0.0.0.0:7641"
fi

# **THE CHAOSNET FOLLOWS THE SAME RULE, AND ITS TWO DEFAULTS PART COMPANY
# UNDER IT.**  The script had one branch for a card and one for no card, so a
# card that said nothing about the address got no address at all, where the
# screen and the serial line had long since learned to pass their own where the
# card is silent.
#
# The switches and the cable are not the same kind of thing, which is what
# makes this four cases and not two. An interface HAS an address whether or not
# anything is plugged into it, so the address is passed wherever the card is
# silent. The cable is plugged in or it is not, and a card that is there and
# says nothing about it is a card that was asked and said no --- which is the
# state a released card ships in.
case_head "the Chaosnet's address is passed once, and it is the card's when the card says one"
sandbox
if prepare cadr-chaosnet S87cadr-chaosnet; then
	printf '%s\r\n' '--chaos-address 4401' '--chaos-udp 0.0.0.0:42042' > "$RC"
	run_script S87cadr-chaosnet
	passes_once "--chaos-address" "cadr-chaosnet" "4401"
	passes_not "3050" "cadr-chaosnet"
	passes_once "--chaos-udp" "cadr-chaosnet" "0.0.0.0:42042"
fi

case_head "and once, the script's own, when the card is there and says nothing about it"
sandbox
if prepare cadr-chaosnet S87cadr-chaosnet; then
	printf '%s\r\n' '--chaos-udp 0.0.0.0:42042' > "$RC"
	run_script S87cadr-chaosnet
	passes_once "--chaos-address" "cadr-chaosnet" "3050"
fi

case_head "and the card's short spelling counts as the card saying one"
sandbox
if prepare cadr-chaosnet S87cadr-chaosnet; then
	printf '%s\r\n' '--address 4401' '--udp 0.0.0.0:42042' > "$RC"
	run_script S87cadr-chaosnet
	passes_once "--address" "cadr-chaosnet" "4401"
	passes_not "--chaos-address" "cadr-chaosnet"
fi

# **AND THE CABLE IS NOT PASSED FOR A CARD THAT DID NOT ASK FOR IT.**  This is
# the state a released card ships in: the switches set, the cable commented
# out, and the program saying so.  The program accepts exactly that --- it
# prints that the cable reaches nothing off the board and goes on running ---
# so what is held here is that the script does not plug one in on the card's
# behalf, and that somebody reading the console is told which state the board
# is in and how to change it.
case_head "the cable is not plugged in when the card is there and does not ask for it"
sandbox
if prepare cadr-chaosnet S87cadr-chaosnet; then
	printf '%s\r\n' '--chaos-address 177101' > "$RC"
	run_script S87cadr-chaosnet
	passes_once "--chaos-address" "cadr-chaosnet" "177101"
	passes_not "--chaos-udp" "cadr-chaosnet"
	passes_not "42042" "cadr-chaosnet"
	if grep -q 'the cable is not plugged in' "$WORK/out.S87cadr-chaosnet"; then
		ok "and the console says the cable is not plugged in"
	else
		fail "the console does not say the cable is not plugged in; it says:"
		sed 's/^/        /' "$WORK/out.S87cadr-chaosnet"
	fi
	if grep -q 'uncomment --chaos-udp' "$WORK/out.S87cadr-chaosnet"; then
		ok "and says how to plug one in"
	else
		fail "the console does not say how to plug a cable in"
	fi
	# **AND IT DOES NOT SPEND THE BOUND WAITING FOR A NETWORK IT WILL NOT
	# USE.**  The wait is for the lease and really for the resolver, and
	# with no cable nothing is bound and no name is resolved, so a board
	# with no network would otherwise hold every boot at it.  The stubbed
	# `ip` answers ready here, so what this can see is that the script did
	# not ask at all.
	if [ -s "$WORK/ip.calls" ]; then
		fail "the script waited for a network with no cable to use it"
	else
		ok "and it did not wait for a network it has no cable to reach"
	fi
fi

case_head "and both defaults stand with no card at all"
sandbox
if prepare cadr-chaosnet S87cadr-chaosnet; then
	rm -f "$RC"
	run_script S87cadr-chaosnet
	passes_once "--chaos-address" "cadr-chaosnet" "3050"
	passes_once "--chaos-udp" "cadr-chaosnet" "0.0.0.0:42042"
	if [ -s "$WORK/ip.calls" ]; then
		ok "and a board with no card still waits for its network"
	else
		fail "a board with no card has a cable and did not wait for a network"
	fi
fi

# The keyboard mapping is the same shape one step along: the file beside the
# card's is the screen's other default, and a card that names the flag used to
# get both of those too.
case_head "the card's flag wins over the mapping file found beside it, and is the only one passed"
sandbox
if prepare cadr-terminal S85cadr-terminal; then
	printf 'key 0 0\n' > "$WORK/packs/terminal.keyboard.mapping.txt"
	printf '%s\r\n' '--keyboard-mapping /mnt/packs/from-the-card.txt' > "$RC"
	run_script S85cadr-terminal
	passes_once "--keyboard-mapping" "cadr-terminal" "/mnt/packs/from-the-card.txt"
	passes_not "$WORK/packs/terminal.keyboard.mapping.txt" "cadr-terminal"
fi

case_head "and the mapping file beside it is passed once when the card says nothing"
sandbox
if prepare cadr-terminal S85cadr-terminal; then
	printf 'key 0 0\n' > "$WORK/packs/terminal.keyboard.mapping.txt"
	printf '%s\r\n' '--bow' > "$RC"
	run_script S85cadr-terminal
	passes_once "--keyboard-mapping" "cadr-terminal" \
	            "$WORK/packs/terminal.keyboard.mapping.txt"
fi

case_head "and no mapping flag at all when there is neither"
sandbox
if prepare cadr-terminal S85cadr-terminal; then
	rm -f "$WORK/packs/terminal.keyboard.mapping.txt"
	printf '%s\r\n' '--bow' > "$RC"
	run_script S85cadr-terminal
	passes_not "--keyboard-mapping" "cadr-terminal"
fi

# ---------------------------------------------------------------------------
# 3.  A FLAG THE PROGRAM REFUSES REACHES THE CONSOLE, AND OK DOES NOT.
# ---------------------------------------------------------------------------
#
# **THE FAULT.**  Every one of these programs refuses a flag it does not know,
# which is muir's behavior and the property this whole file of flags rests on.
# But an init script starts its program with `start-stop-daemon -b`, which
# daemonizes it and closes stdout and stderr, so the refusal went to /dev/null
# and the script printed OK.  That is exactly what a carriage return on every
# peer's port once did to the Chaosnet on the board: a boot that looked perfect
# with a program that was not running.
#
# **WHAT IS HELD HERE.**  Each script hands its program to cadr-common's
# `cadr_daemon`, which looks for it a moment after starting it and, when it is
# not there, runs it again and prints what it says.  The stand-in program on
# the stub PATH refuses the flag $REFUSE names, on stderr, the way all five do.
#
# The control matters as much as the case: the same script with nothing to
# refuse must print OK, or a check that always saw FAIL would pass this
# section while saying nothing.
refusal_case() {
	# $1 the package, $2 the script, $3 the flag the file carries and the
	# program refuses, $4 the program's name, and $5 any further line the
	# file must carry for the program to be started at all --- which is the
	# serial line's, since a card that says nothing about `--serial` is a
	# card that says the line is off, and a program that is not started
	# refuses nothing.
	sandbox
	printf '%s\r\n' "$3" ${5:+"$5"} > "$WORK/packs/fpgarc"
	prepare "$1" "$2" || return 1

	case_head "$4: a flag it refuses is printed, and OK is not"
	REFUSE=$3
	export REFUSE
	run_script "$2"
	unset REFUSE
	if grep -q "unrecognized option '$3'" "$WORK/out.$2"; then
		ok "the program's own refusal is on the console"
	else
		fail "the refusal is not on the console; it says:"
		sed 's/^/        /' "$WORK/out.$2"
	fi
	if grep -q "Starting $4: OK" "$WORK/out.$2"; then
		fail "and the script said OK for a program that is not running"
	else
		ok "and the script did not say OK"
	fi
	if grep -q "Starting $4: FAIL" "$WORK/out.$2"; then
		ok "it said FAIL"
	else
		fail "it did not say FAIL either; it says:"
		sed 's/^/        /' "$WORK/out.$2"
	fi

	case_head "$4: and with nothing refused it says OK"
	run_script "$2"
	if grep -q "Starting $4: OK" "$WORK/out.$2"; then
		ok "the same script, the same flag, nothing refused: OK"
	else
		fail "the script says FAIL for a program that started; it says:"
		sed 's/^/        /' "$WORK/out.$2"
	fi
	if grep -q "unrecognized option" "$WORK/out.$2"; then
		fail "and it printed a refusal that did not happen"
	else
		ok "and printed no refusal"
	fi
	return 0
}

# Each program with a flag its own list claims, so that the line really
# reaches it and the refusal is the program's rather than the reader's.
refusal_case cadr-terminal   S85cadr-terminal  --bow          cadr-terminal
refusal_case cadr-serial     S86cadr-serial    --quiet        cadr-serial '--serial 0.0.0.0:7641'
refusal_case cadr-usb-input  S88cadr-usb-input --usb-grab     cadr-usb-input
refusal_case cadr-chaosnet   S87cadr-chaosnet  --chaos-trace  cadr-chaosnet

# The disk pack program takes no flag out of the file --- its init script reads
# one for the boot button and passes the program only its own words --- so the
# refusal it has to survive is of a flag the SCRIPT passes.  `--packs` is that
# flag, and a program that stopped taking it would be a bay that never opens.
case_head "cadr-disk-packs: a flag it refuses is printed, and OK is not"
sandbox
printf '%s\r\n' '--chaos-address 3050' > "$WORK/packs/fpgarc"
if prepare cadr-disk-packs S80cadr-disk-packs; then
	REFUSE=--packs
	export REFUSE
	run_script S80cadr-disk-packs
	unset REFUSE
	if grep -q "unrecognized option '--packs'" "$WORK/out.S80cadr-disk-packs"; then
		ok "the program's own refusal is on the console"
	else
		fail "the refusal is not on the console; it says:"
		sed 's/^/        /' "$WORK/out.S80cadr-disk-packs"
	fi
	if grep -q "Starting cadr-disk-packs: OK" "$WORK/out.S80cadr-disk-packs"; then
		fail "and the script said OK for a program that is not running"
	else
		ok "and the script did not say OK"
	fi
fi

case_head "a program that dies for a reason that is not its flags says so"
sandbox
printf '%s\r\n' '--bow' > "$WORK/packs/fpgarc"
if prepare cadr-terminal S85cadr-terminal; then
	# The stand-in is replaced by one that goes at once and says nothing,
	# which is a program that died at start for a reason of its own.  The
	# script must still not say OK, and must say the one thing it knows.
	cat > "$WORK/bin/cadr-terminal" <<'EOF'
#!/bin/sh
exit 1
EOF
	chmod +x "$WORK/bin/cadr-terminal"
	run_script S85cadr-terminal
	if grep -q "Starting cadr-terminal: OK" "$WORK/out.S85cadr-terminal"; then
		fail "the script said OK for a program that exited at once"
	else
		ok "the script did not say OK"
	fi
	if grep -q "died at start and said nothing" "$WORK/out.S85cadr-terminal"; then
		ok "and said it died at start and said nothing"
	else
		fail "and said nothing useful about it; it says:"
		sed 's/^/        /' "$WORK/out.S85cadr-terminal"
	fi
fi

# ---------------------------------------------------------------------------
# 4.  A LINE NO PROGRAM TAKES IS NAMED AT BOOT.
# ---------------------------------------------------------------------------
#
# Nothing in the reader refuses anything, which is what lets one file serve
# five strict programs --- and it is the one way a setting can still be lost.
# `--bwo` for `--bow` is a card that says something and a board that does
# nothing, with every program starting cleanly and nothing to read.  The last
# script to read the file compares it against what every script claimed and
# names what went to nobody.
case_head "a flag no program's list names is reported by the last script"
sandbox
printf '%s\r\n' \
	'--chaos-address 3050' \
	'--bow' \
	'--usb-grab' \
	'--quiet' \
	'--bwo' \
	'--not-anybodys-flag 7' > "$WORK/packs/fpgarc"
ran=yes
for pair in "cadr-disk-packs S80cadr-disk-packs" "cadr-terminal S85cadr-terminal" \
            "cadr-serial S86cadr-serial" "cadr-chaosnet S87cadr-chaosnet" \
            "cadr-usb-input S88cadr-usb-input"; do
	set -- $pair
	prepare "$1" "$2" || ran=no
done
if [ "$ran" = yes ]; then
	for sc in S80cadr-disk-packs S85cadr-terminal S86cadr-serial \
	          S87cadr-chaosnet S88cadr-usb-input; do
		run_script "$sc"
	done
	last="$WORK/out.S88cadr-usb-input"
	if grep -q -- '--bwo' "$last" && grep -q -- '--not-anybodys-flag' "$last"; then
		ok "both lines nobody takes are named on the console"
	else
		fail "the unclaimed lines are not named; the last script says:"
		sed 's/^/        /' "$last"
	fi
	# And nothing that DID reach a program may be named, or the line would
	# cry wolf on every boot of every card.
	for taken in --chaos-address --bow --usb-grab --quiet; do
		if grep -q "takes.*$taken" "$last"; then
			fail "$taken reached its program and was reported unclaimed anyway"
		else
			ok "$taken reached its program and is not reported"
		fi
	done
fi

# The clock's two lines are on this file as well, because they are claimed by a
# step and not by a program: a claim that was never recorded would have every
# card that sets its clock told at boot that the two lines went to nobody.
case_head "and a file every program's list covers is reported silently"
sandbox
printf '%s\r\n' '--chaos-address 3050' '--bow' '--usb-grab' \
	'--date 20260920' '--time 1438' > "$WORK/packs/fpgarc"
ran=yes
for pair in "cadr-disk-packs S80cadr-disk-packs" "cadr-terminal S85cadr-terminal" \
            "cadr-serial S86cadr-serial" "cadr-chaosnet S87cadr-chaosnet" \
            "cadr-usb-input S88cadr-usb-input"; do
	set -- $pair
	prepare "$1" "$2" || ran=no
done
if [ "$ran" = yes ]; then
	for sc in S80cadr-disk-packs S85cadr-terminal S86cadr-serial \
	          S87cadr-chaosnet S88cadr-usb-input; do
		run_script "$sc"
	done
	if grep -q "no program on this board takes" "$WORK/out.S88cadr-usb-input"; then
		fail "a file whose every line reached a program was reported anyway:"
		sed 's/^/        /' "$WORK/out.S88cadr-usb-input"
	else
		ok "nothing is said about a file with nothing left over"
	fi
fi

# **AND A FLAG THE CHAOSNET PROGRAM REFUSES BY NAME IS ONE OF THOSE LINES.**
# `--chaos-file-root`, `--chaos-file-peers`, `--server-name` and `--time` named
# a file host and a time host that used to live inside that program.  They were
# in its list for a while, so that a card still carrying one got the program's
# own answer about where the host went --- but a claimed line reaches the
# program, and the program exits on it, so the price of that answer was the
# whole Chaosnet.  Unclaimed, the same card gets the line named at boot and a
# Chaosnet that runs, which is the better of the two.
#
# The stand-in program refuses the flag $REFUSE names, as the real one refuses
# these four, so this bites the moment the flag is claimed again: the program
# would then be handed it and would go.
case_head "a flag the Chaosnet program refuses is reported, and the Chaosnet still starts"
sandbox
printf '%s\r\n' \
	'--chaos-address 3050' \
	'--chaos-file-root /mnt/packs/file-root' > "$WORK/packs/fpgarc"
ran=yes
for pair in "cadr-disk-packs S80cadr-disk-packs" "cadr-terminal S85cadr-terminal" \
            "cadr-serial S86cadr-serial" "cadr-chaosnet S87cadr-chaosnet" \
            "cadr-usb-input S88cadr-usb-input"; do
	set -- $pair
	prepare "$1" "$2" || ran=no
done
if [ "$ran" = yes ]; then
	REFUSE=--chaos-file-root
	export REFUSE
	for sc in S80cadr-disk-packs S85cadr-terminal S86cadr-serial \
	          S87cadr-chaosnet S88cadr-usb-input; do
		run_script "$sc"
	done
	unset REFUSE
	if grep -q -- '--chaos-file-root' "$WORK/out.S88cadr-usb-input"; then
		ok "the line nobody takes is named on the console"
	else
		fail "the refused flag is not named as unclaimed; the last script says:"
		sed 's/^/        /' "$WORK/out.S88cadr-usb-input"
	fi
	if grep -q -- '--chaos-file-root' "$WORK/out.S87cadr-chaosnet"; then
		fail "the Chaosnet script was handed a flag its program refuses:"
		sed 's/^/        /' "$WORK/out.S87cadr-chaosnet"
	else
		ok "the Chaosnet program was never handed it"
	fi
	if grep -q "Starting cadr-chaosnet: OK" "$WORK/out.S87cadr-chaosnet"; then
		ok "and the Chaosnet started"
	else
		fail "the Chaosnet did not start; the script says:"
		sed 's/^/        /' "$WORK/out.S87cadr-chaosnet"
	fi
	# And the rest of the file still reached it, so this is a card that
	# works rather than one that says nothing.  The Chaosnet script is run
	# once more for this, because `run_script` keeps only the last script's
	# call and the report above needed S88 to be last.
	run_script S87cadr-chaosnet
	passes "--chaos-address 3050" "cadr-chaosnet"
	passes_not "--chaos-file-root" "cadr-chaosnet"
fi

# ---------------------------------------------------------------------------
# 5.  The boot button: --no-auto-boot holds the machine before the drive comes
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
	# The console IS asked about the switch --- that is how the fabric's own
	# hold is found --- and must be told nothing else.
	if grep -qx "switch" "$WORK/console.calls"; then
		ok "the console was asked about SW0"
	else
		fail "the console was not asked about SW0; it was told: $(cat "$WORK/console.calls")"
	fi
	if grep -qx "halt" "$WORK/console.calls"; then
		fail "the console was told to halt a machine nothing asked to hold"
	else
		ok "and nothing was halted"
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
	if grep -qx "halt" "$WORK/console.calls"; then
		fail "the console was told to halt: $(cat "$WORK/console.calls")"
	else
		ok "nothing was halted"
	fi
	if [ -f "$WORK/run/cadr-held" ]; then
		fail "a hold marker was left by a board with no fpgarc and no switch"
	else
		ok "there is no hold marker"
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

# **SW0 HOLDS THE MACHINE AND NOTHING IS HALTED**, which is the whole
# difference between the two ways of asking.  With the switch on, the fabric
# brought the machine up with RUN clear and it has never run a microcycle, so
# there is nothing for this script to halt --- a halt here would be the script
# taking credit for the switch's work, and it would also be a write to the
# clock control register on a machine nobody has touched.  What the step does
# **AND WHEN THIS SCRIPT LETS THE CONSOLE'S OWN LINES THROUGH, THEY GO INTO
# THE BOOT LOG AND MUST NAME THE PROGRAM.**  `cadr-console` writes a bare reply
# to a person at a terminal and a prefixed line to a log, and `/dev/console` IS
# a terminal --- so the script says which it is with `--log /dev/console`
# rather than leaving six programs' lines in one log with nothing to tell them
# apart.  The two calls that let output through are the debug cable's; `halt`
# and `switch` send theirs to /dev/null and are asserted bare elsewhere.
case_head "the console's lines into the boot log name the program"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	printf '%s\r\n' '--debug-cable-wiring auto' > "$WORK/packs/fpgarc"
	: > "$WORK/daemon.calls"
	FPGARC_CLAIMED="$WORK/run/claimed" PATH="$WORK/bin:$PATH" \
		"$WORK/S80cadr-disk-packs" start > "$WORK/out.cable" 2>&1
	if grep -qx -- "--log /dev/console debug-cable-wiring auto" "$WORK/console.calls"; then
		ok "the wiring is asked for with --log /dev/console, so the reply names its program"
	else
		fail "the console was told: $(cat "$WORK/console.calls")"
	fi
fi

# is leave the marker, so that cadr-console refuses `start` and `step` and says
# why.
case_head "SW0 holds the machine, and nothing is halted"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	printf '%s\r\n' '--chaos-address 3050' > "$WORK/packs/fpgarc"
	: > "$WORK/daemon.calls"
	CONSOLE_SWITCH=yes FPGARC_CLAIMED="$WORK/run/claimed" \
		PATH="$WORK/bin:$PATH" "$WORK/S80cadr-disk-packs" start \
		> "$WORK/out.sw0" 2>&1
	if grep -qx "switch" "$WORK/console.calls"; then
		ok "the console was asked about SW0"
	else
		fail "the console was not asked about SW0; it was told: $(cat "$WORK/console.calls")"
	fi
	if grep -qx "halt" "$WORK/console.calls"; then
		fail "the machine was halted, and the switch had already stopped it"
	else
		ok "and nothing was halted: the machine had never run"
	fi
	if [ -f "$WORK/run/cadr-held" ]; then
		ok "the hold marker stands"
	else
		fail "there is no hold marker"
	fi
	if grep -q "^held at boot by SW0$" "$WORK/run/cadr-held"; then
		ok "and it names SW0 as the cause"
	else
		fail "the marker does not name SW0; it says: $(cat "$WORK/run/cadr-held" 2>/dev/null)"
	fi
	if grep -q "cadr-boot: SW0" "$WORK/out.sw0"; then
		ok "and the console says so"
	else
		fail "the console does not say the switch held it; it says:"
		sed 's/^/        /' "$WORK/out.sw0"
	fi
	if grep -q "cadr-console boot" "$WORK/out.sw0" && grep -q "BTN0" "$WORK/out.sw0"; then
		ok "and names both ways to press the button"
	else
		fail "the line does not name cadr-console boot and BTN0"
	fi
	if [ -s "$WORK/daemon.calls" ]; then
		ok "the pack program was started"
	else
		fail "the pack program was not started"
	fi
fi

# **THE LAMPS: --no-blinking-leds ASKS THE CONSOLE FOR A LEVEL.**  The fabric
# comes up blinking, so a card that says nothing leaves the console alone, and
# a card with the line asks for steady lamps through the console's own word,
# with `--log /dev/console` for the boot log's reason.  A console that could not
# make them steady is said to have failed, and the boot goes on either way,
# since a lamp is nothing to wait on.
case_head "--no-blinking-leds asks the console for steady lamps, and nothing else"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	printf '%s\r\n' '--chaos-address 3050' '--no-blinking-leds' > "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	if grep -qx -- "--log /dev/console blinking-leds off" "$WORK/console.calls"; then
		ok "the console was told blinking-leds off, with the boot log named"
	else
		fail "the console was not asked for steady lamps; it was told: $(cat "$WORK/console.calls")"
	fi
	if grep -qx "halt" "$WORK/console.calls"; then
		fail "asking for steady lamps halted the machine"
	else
		ok "and nothing was halted"
	fi
	if grep -q "cadr-lamps" "$WORK/out.S80cadr-disk-packs"; then
		fail "a console that made the lamps steady was said to have failed:"
		sed 's/^/        /' "$WORK/out.S80cadr-disk-packs"
	else
		ok "and a console that did it is not said to have failed"
	fi
	if [ -s "$WORK/daemon.calls" ]; then
		ok "the pack program was started"
	else
		fail "the pack program was not started"
	fi
fi

case_head "without the line the lamps are left to blink, and a console that fails says so"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	printf '%s\r\n' '--chaos-address 3050' > "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	if grep -q "blinking-leds" "$WORK/console.calls"; then
		fail "the console was asked about the lamps by a card that says nothing: $(cat "$WORK/console.calls")"
	else
		ok "the console was not asked about the lamps"
	fi
	printf '%s\r\n' '--no-blinking-leds' > "$WORK/packs/fpgarc"
	: > "$WORK/daemon.calls"
	CONSOLE_LAMPS=no FPGARC_CLAIMED="$WORK/run/claimed" PATH="$WORK/bin:$PATH" \
		"$WORK/S80cadr-disk-packs" start > "$WORK/out.lamps" 2>&1
	if grep -q "cadr-lamps: --no-blinking-leds: the console did not make the lamps steady" \
	   "$WORK/out.lamps"; then
		ok "a console that did not make them steady is said to have failed"
	else
		fail "a console that did not make the lamps steady is not called out; the script says:"
		sed 's/^/        /' "$WORK/out.lamps"
	fi
	if [ -s "$WORK/daemon.calls" ]; then
		ok "and the boot goes on: the pack program was started anyway"
	else
		fail "the boot stopped: the pack program was never started"
	fi
fi

# **THE DISPLAY OUTPUT'S SLEEP: --hdmi-sleep HANDS THE CONSOLE ITS SECONDS.**
# The fabric comes up with three hundred, so a card that says nothing leaves the
# console alone, and a card with the line has its number carried through the
# console's own word, with `--log /dev/console` for the boot log's reason.  A
# console that did not take it --- a board with no display output, or a number
# the console refuses --- is called out, and the boot goes on either way.
case_head "--hdmi-sleep hands the console the card's seconds, and nothing else"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	printf '%s\r\n' '--chaos-address 3050' '--hdmi-sleep 120' > "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	if grep -qx -- "--log /dev/console hdmi-sleep 120" "$WORK/console.calls"; then
		ok "the console was told hdmi-sleep 120, with the boot log named"
	else
		fail "the console was not given the card's seconds; it was told: $(cat "$WORK/console.calls")"
	fi
	if grep -qx "halt" "$WORK/console.calls"; then
		fail "setting the display's sleep halted the machine"
	else
		ok "and nothing was halted"
	fi
	if grep -q "cadr-display" "$WORK/out.S80cadr-disk-packs"; then
		fail "a console that took the setting was said not to have:"
		sed 's/^/        /' "$WORK/out.S80cadr-disk-packs"
	else
		ok "and a console that took it is not said to have failed"
	fi
	if [ -s "$WORK/daemon.calls" ]; then
		ok "the pack program was started"
	else
		fail "the pack program was not started"
	fi
fi

case_head "without the line the fabric's own sleep stands, and a console that refuses says so"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	printf '%s\r\n' '--chaos-address 3050' '--hdmi-output tv' > "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	if grep -q "hdmi-sleep" "$WORK/console.calls"; then
		fail "the console was asked about sleep by a card that says nothing: $(cat "$WORK/console.calls")"
	else
		ok "the console was not asked about sleep"
	fi
	printf '%s\r\n' '--hdmi-sleep 0' > "$WORK/packs/fpgarc"
	: > "$WORK/daemon.calls"
	: > "$WORK/console.calls"
	CONSOLE_SLEEP=no FPGARC_CLAIMED="$WORK/run/claimed" PATH="$WORK/bin:$PATH" \
		"$WORK/S80cadr-disk-packs" start > "$WORK/out.sleep" 2>&1
	if grep -qx -- "--log /dev/console hdmi-sleep 0" "$WORK/console.calls"; then
		ok "zero is handed over as zero, which is never"
	else
		fail "zero was not handed over; the console was told: $(cat "$WORK/console.calls")"
	fi
	if grep -q "cadr-display: --hdmi-sleep 0: not set" "$WORK/out.sleep"; then
		ok "a console that did not take it is said not to have"
	else
		fail "a console that did not take the setting is not called out; the script says:"
		sed 's/^/        /' "$WORK/out.sleep"
	fi
	if [ -s "$WORK/daemon.calls" ]; then
		ok "and the boot goes on: the pack program was started anyway"
	else
		fail "the boot stopped: the pack program was never started"
	fi
fi

# **THE SWITCH AND THE FLAG TOGETHER, AND THE FLAG CANNOT TURN THE SWITCH
# OFF.**  They are an OR, so a card that says `--no-auto-boot` on a board whose
# switch is on is held once and not twice; the switch is what did it, since the
# machine was already stopped before Linux existed, and the line says the flag
# asked for the same thing so that nobody thinks it was dropped.
case_head "SW0 and --no-auto-boot together: held once, by the switch"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	printf '%s\r\n' '--no-auto-boot' > "$WORK/packs/fpgarc"
	CONSOLE_SWITCH=yes FPGARC_CLAIMED="$WORK/run/claimed" \
		PATH="$WORK/bin:$PATH" "$WORK/S80cadr-disk-packs" start \
		> "$WORK/out.both" 2>&1
	if grep -qx "halt" "$WORK/console.calls"; then
		fail "the machine was halted, and the switch had already stopped it"
	else
		ok "nothing was halted"
	fi
	if grep -q "^held at boot by SW0$" "$WORK/run/cadr-held" 2>/dev/null; then
		ok "the marker names SW0"
	else
		fail "the marker does not name SW0; it says: $(cat "$WORK/run/cadr-held" 2>/dev/null)"
	fi
	if grep -q -- "--no-auto-boot in" "$WORK/out.both"; then
		ok "and the line says the flag asks for the same thing"
	else
		fail "the line does not mention the flag; it says:"
		sed 's/^/        /' "$WORK/out.both"
	fi
fi

# **AND A CONSOLE THAT CANNOT BE REACHED ANSWERS NO**, which is the safe
# direction: a board whose console cannot be read is a board nothing could have
# been held on, and it is the same console that would have had to do the
# halting.  Without cadr-console on the PATH at all, a card with no flag boots
# itself and says nothing.
case_head "no cadr-console at all, and no flag: the board boots itself"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	printf '%s\r\n' '--chaos-address 3050' > "$WORK/packs/fpgarc"
	rm -f "$WORK/bin/cadr-console"
	run_script S80cadr-disk-packs
	if [ -f "$WORK/run/cadr-held" ]; then
		fail "a hold marker was left by a board with no console to ask"
	else
		ok "there is no hold marker"
	fi
	if grep -q "cadr-boot" "$WORK/out.S80cadr-disk-packs"; then
		fail "the console says something about the boot button and should not:"
		sed 's/^/        /' "$WORK/out.S80cadr-disk-packs"
	else
		ok "and nothing is said about the boot button"
	fi
	if [ -s "$WORK/daemon.calls" ]; then
		ok "the pack program was started"
	else
		fail "the pack program was not started"
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
# 5b. THE CLOCK: --date AND --time SET IT BEFORE ANYTHING ELSE STARTS, AND IT
#     NEVER RUNS BACKWARDS.
# ---------------------------------------------------------------------------
#
# **WHAT THE BOARD HAS.**  No board here presents a real-time clock to Linux:
# `date` straight after a boot reads the epoch, /sys/class/rtc is empty and
# there is no /dev/rtc.  So a board that boots from its card alone does not
# know the date or the time until the card tells it, and every file it writes
# and every band it reads is stamped 1970.
#
# **WHAT TELLS IT.**  Two lines on the card, read by the disk pack program's
# init script for the reasons the boot button's step gives: they are on the
# partition that script is the one thing that mounts, and they must land before
# anything else starts.  Either may stand alone and sets only its own field.
#
# **AND THE CLOCK IS SAVED AT A CLEAN SHUTDOWN AND RESTORED AT THE NEXT BOOT,
# so what the card says is a floor and not a setting.**  The later of the two
# wins, which is the one rule here that a check can pass while being exactly
# wrong: a comparison the other way round restores nothing that matters and
# looks like a clock that works.  So every pair below is tried both ways round
# --- a saved clock later than the card's lines and a saved clock earlier ---
# and the two cases assert different outcomes.

# What the step told the clock to be, one line a call.
clock_told() { sed -n 's/^-u -s //p' "$WORK/date.calls"; }
clock_told_count() { clock_told | grep -c . || true; }

# The clock was set to $1 and once.  Setting it twice is not harmless: it means
# the step composed one value, set it, and then thought again.
clock_set_once() {
	_n=$(clock_told_count)
	if [ "$_n" != 1 ]; then
		fail "the clock was set $_n times and once is right; date was told:" \
		     "[$(tr '\n' '|' < "$WORK/date.calls")]"
		return 1
	fi
	if [ "$(clock_told)" = "$1" ]; then
		ok "the clock was set to $1, once"
	else
		fail "the clock was set to [$(clock_told)] and not to [$1]"
	fi
}

clock_set_never() {
	_n=$(clock_told_count)
	if [ "$_n" = 0 ]; then
		ok "$1"
	else
		fail "the clock was set to [$(clock_told)] and nothing asked for it"
	fi
}

# The step ran before the pack program and before the console was touched.
clock_set_first() {
	_want="the clock was set before the pack program started and before the console was asked anything"
	if [ "$(cat "$WORK/order.calls" 2>/dev/null)" = "$_want" ]; then
		ok "and it was set before anything else started"
	else
		fail "the order was [$(cat "$WORK/order.calls" 2>/dev/null)], wanting [$_want]"
	fi
}

# **-F, BECAUSE WHAT IS LOOKED FOR IS A SENTENCE AND NOT A PATTERN.**  A line
# the step prints can hold a bracket --- a value it could not read is printed as
# `[not-a-clock]` --- and grep reads that as a character range, refuses the
# whole pattern and finds nothing, which reads here as "the console does not say
# it".  That is a case failing for a reason that has nothing to do with the
# board, and it was found by a mutation run rather than by the clean one.
said() { grep -qF -- "$1" "$WORK/out.S80cadr-disk-packs"; }
says() {
	if said "$1"; then
		ok "the console says $1"
	else
		fail "the console does not say [$1]; it says:"
		sed 's/^/        /' "$WORK/out.S80cadr-disk-packs"
	fi
}
says_not() {
	if said "$1"; then
		fail "the console says [$1] and should not; it says:"
		sed 's/^/        /' "$WORK/out.S80cadr-disk-packs"
	else
		ok "and the console does not say $1"
	fi
}

case_head "--date and --time set the clock, before anything else starts"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	printf '%s\r\n' '--chaos-address 3050' '--date 20260920' '--time 1438' \
		> "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-20 14:38:00"
	clock_set_first
	says "cadr-clock: the clock is 2026-09-20 14:38:00 UTC"
	says "--date 20260920 and --time 1438"
	# The two lines are the step's and are passed to no program: the pack
	# program refuses a flag it does not know, so a `--date` reaching it
	# would be the drive bay gone on a boot that printed OK.
	passes_not "--date" "cadr-disk-packs"
	passes_not "--time" "cadr-disk-packs"
	if [ -s "$WORK/daemon.calls" ]; then
		ok "the pack program was started"
	else
		fail "the pack program was not started"
	fi
	# Nothing is saved at a start: the save is the shutdown's.
	if [ -f "$WORK/packs/clock" ]; then
		fail "a start wrote the saved clock, and only a clean shutdown may"
	else
		ok "and nothing was saved at start"
	fi
fi

case_head "--date alone sets the date and leaves the time of day"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	printf '%s\r\n' '--date 20260920' > "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-20 00:00:05"
	says "--date 20260920"
	says_not "--time"
fi

case_head "--time alone sets the time of day and leaves the date"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	printf '%s\r\n' '--time 1438' > "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "1970-01-01 14:38:00"
	says "--time 1438"
	says_not "--date"
fi

case_head "--time takes the second when the card gives one"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	printf '%s\r\n' '--date 20260920' '--time 143805' > "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-20 14:38:05"
fi

case_head "a card that says nothing leaves the clock alone and says nothing"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	printf '%s\r\n' '--chaos-address 3050' > "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_never "the clock was not set"
	says_not "cadr-clock"
	if [ -s "$WORK/daemon.calls" ]; then
		ok "and the pack program was started"
	else
		fail "the pack program was not started"
	fi
fi

# **THE CLOCK NEVER RUNS BACKWARDS, and this pair is what says so.**  The same
# card is booted twice: once beside a saved clock LATER than what its lines
# compose, and once beside one EARLIER.  The first must keep the saved clock
# and say that the card's lines were not applied; the second must take the
# card's.  A comparison the wrong way round passes neither, and a step with no
# comparison at all passes only the second.
case_head "a saved clock later than the card's lines wins, and the clock is not moved back"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	echo 20260920140000 > "$WORK/packs/clock"
	printf '%s\r\n' '--date 20260919' '--time 1200' > "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-20 14:00:00"
	says "is not later than the clock restored"
	says "cadr-clock: the clock is 2026-09-20 14:00:00 UTC, restored from"
fi

case_head "and a saved clock earlier than them does not, so the card's lines win"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	echo 20260918000000 > "$WORK/packs/clock"
	printf '%s\r\n' '--date 20260919' '--time 1200' > "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-19 12:00:00"
	says "--date 20260919 and --time 1200"
	says_not "is not later than the clock restored"
fi

# **AND A LINE THAT STANDS ALONE COMPOSES ON THE CLOCK AS IT NOW STANDS, which
# is the restored one.**  `--time 1500` on a board that was halted at two in
# the afternoon is three in the afternoon of the same day, and not three in the
# afternoon of the 1st of January 1970 --- which is what composing on the clock
# the board came up with would give, and which the comparison would then throw
# away, leaving a line on the card that did nothing at all.  That is the whole
# of what "sets only its own field, leaving the other as it is" means, and this
# is the case that says which of the two readings the step has.
case_head "a lone --time moves the restored clock and does not start again from the epoch"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	echo 20260920140000 > "$WORK/packs/clock"
	printf '%s\r\n' '--time 1500' > "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-20 15:00:00"
	says "on the clock restored from"
fi

# **AND ONE SECOND EITHER SIDE OF THE SAVED CLOCK**, which is the mutation just
# outside the bound: a comparison that took `not earlier` for `later`, or that
# compared the date and forgot the time, passes everything above and fails
# here.
case_head "one second later than the saved clock is later, and one second earlier is not"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	echo 20260920143800 > "$WORK/packs/clock"
	printf '%s\r\n' '--date 20260920' '--time 143801' > "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-20 14:38:01"
fi
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	echo 20260920143800 > "$WORK/packs/clock"
	printf '%s\r\n' '--date 20260920' '--time 143759' > "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-20 14:38:00"
	says "is not later than the clock restored"
fi

case_head "a saved clock and no lines at all is restored on its own"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	echo 20260920140000 > "$WORK/packs/clock"
	printf '%s\r\n' '--chaos-address 3050' > "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-20 14:00:00"
	clock_set_first
	says "restored from"
fi

case_head "and a saved clock with no fpgarc beside it is restored too"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	rm -f "$WORK/packs/fpgarc"
	echo 20260920140000 > "$WORK/packs/clock"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-20 14:00:00"
fi

# **THE SAVED CLOCK IS CLEANED THE WAY A LINE OF THE CARD'S FILE IS, AND FOR
# THE SAME REASON.**  The partition is FAT32 and this file can be edited on a
# laptop with a card reader, which leaves a carriage return and can leave a
# space at either end.  A space in the middle is another thing, and is refused:
# `2026 0920140000` is not an instant however it got there.
case_head "a saved clock a card reader left its marks on is still restored"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	printf '  20260920140000  \r\n' > "$WORK/packs/clock"
	rm -f "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-20 14:00:00"
fi
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	printf '2026 0920140000\n' > "$WORK/packs/clock"
	rm -f "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_never "a saved clock with a space in the middle was not used"
	says "cadr-clock: the clock saved in"
fi

case_head "a saved clock that is not fourteen digits is named and not used"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	echo "hello" > "$WORK/packs/clock"
	printf '%s\r\n' '--date 20260920' '--time 1438' > "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-20 14:38:00"
	says "cadr-clock: the clock saved in"
	if [ -s "$WORK/daemon.calls" ]; then
		ok "and the boot goes on: the pack program was started anyway"
	else
		fail "the boot stopped: the pack program was never started"
	fi
fi

# **A LINE THAT IS NOT A DATE IS SAID AND DROPPED, AND THE OTHER LINE STILL
# LANDS.**  That is the shape every other step here has: the console says what
# did not happen and the boot goes on.  What must not happen is the kernel
# being handed 20260231 and quietly making it the 3rd of March.
case_head "a --date that is not a date is named, and --time still lands"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	printf '%s\r\n' '--date 20261301' '--time 1438' > "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "1970-01-01 14:38:00"
	says "cadr-clock: --date 20261301 is not a date"
	says "yyyyMMdd"
fi

case_head "a --time that is not a time is named, and --date still lands"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	printf '%s\r\n' '--date 20260920' '--time 2400' > "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-20 00:00:05"
	says "cadr-clock: --time 2400 is not a time"
	says "HHmm"
fi

case_head "a line with nothing after it is named, and the clock is not set"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	printf '%s\r\n' '--date' > "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_never "the clock was not set from a line with no date on it"
	says "cadr-clock: --date is there with nothing after it"
fi

# **SPACES ROUND THE VALUE ARE THE READER'S TO TAKE OFF, AND A SPACE INSIDE IT
# IS NOT A VALUE.**  The card is edited on a laptop with a card reader, so a
# line with a space at either end is a line somebody really writes; the reader
# trims both ends and reduces the gap after the flag to one space.  A space in
# the middle survives that and is refused here, which is right: `2026 0920` is
# two words and not a date.
case_head "spaces round the value are taken off, and a space inside it is not a date"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	printf '%s\r\n' '   --date   20260920   ' '  --time  1438  ' > "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-20 14:38:00"
fi
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	printf '%s\r\n' '--date 2026 0920' > "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_never "a date with a space in it did not reach the clock"
	says "cadr-clock: --date 2026 0920 is not a date"
fi

case_head "a board whose clock does not read as an instant is said, and nothing is set"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo "not-a-clock" > "$WORK/now"
	printf '%s\r\n' '--date 20260920' '--time 1438' > "$WORK/packs/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_never "nothing was set against a clock that is not an instant"
	says "cadr-clock: the board's clock reads [not-a-clock]"
	if [ -s "$WORK/daemon.calls" ]; then
		ok "and the boot goes on: the pack program was started anyway"
	else
		fail "the boot stopped: the pack program was never started"
	fi
fi

case_head "a clock the board will not take is said, and the boot goes on"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	printf '%s\r\n' '--date 20260920' '--time 1438' > "$WORK/packs/fpgarc"
	: > "$WORK/daemon.calls"
	: > "$WORK/date.calls"
	DATE_SETS=no FPGARC_CLAIMED="$WORK/run/claimed" PATH="$WORK/bin:$PATH" \
		"$WORK/S80cadr-disk-packs" start > "$WORK/out.S80cadr-disk-packs" 2>&1
	says "cadr-clock: the clock could not be set to 2026-09-20 14:38:00"
	if [ -s "$WORK/daemon.calls" ]; then
		ok "and the boot goes on: the pack program was started anyway"
	else
		fail "the boot stopped: the pack program was never started"
	fi
fi

# **THE SAVE IS THE SHUTDOWN'S, AND IT HAPPENS WHILE THE PARTITION IS STILL THE
# CARD'S.**  A save after the unmount writes into the root filesystem, which is
# a RAM disk unpacked at every boot, so the file would be there to find and
# gone at the next boot --- the worst of both.  The stubbed `umount` records
# which side of it the save fell on.
case_head "a clean shutdown saves the clock, before the partition is unmounted"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 20260920143805 > "$WORK/now"
	printf '%s\r\n' '--chaos-address 3050' > "$WORK/packs/fpgarc"
	PATH="$WORK/bin:$PATH" "$WORK/S80cadr-disk-packs" stop > "$WORK/out.stop" 2>&1
	if [ "$(cat "$WORK/packs/clock" 2>/dev/null)" = 20260920143805 ]; then
		ok "the clock was saved as fourteen digits"
	else
		fail "the saved clock is [$(cat "$WORK/packs/clock" 2>/dev/null)], not 20260920143805"
	fi
	if grep -q "cadr-clock: 2026-09-20 14:38:05 UTC saved" "$WORK/out.stop"; then
		ok "and the console says so"
	else
		fail "the console does not say the clock was saved; it says:"
		sed 's/^/        /' "$WORK/out.stop"
	fi
	if grep -q "^the clock was saved before $WORK/packs was unmounted\$" "$WORK/umount.calls"; then
		ok "and it was saved while the partition was still the card's"
	else
		fail "the unmount and the save fell the wrong way round: $(cat "$WORK/umount.calls")"
	fi
fi

# And the round trip, which is the whole of what the save is for: what one
# shutdown wrote is what the next boot reads, with no line on the card at all.
case_head "and the next boot starts where the last shutdown left off"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 20260920143805 > "$WORK/now"
	printf '%s\r\n' '--chaos-address 3050' > "$WORK/packs/fpgarc"
	PATH="$WORK/bin:$PATH" "$WORK/S80cadr-disk-packs" stop > "$WORK/out.stop" 2>&1
	# The board comes up at the epoch, as it really does with no real-time
	# clock in it.
	echo 19700101000005 > "$WORK/now"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-20 14:38:05"
	if [ "$(cat "$WORK/now")" = 20260920143805 ]; then
		ok "and the board's clock reads it afterwards"
	else
		fail "the board's clock reads [$(cat "$WORK/now")] afterwards"
	fi
fi

# ---------------------------------------------------------------------------
# 6.  The card script writes the line, commented out unless asked.
# ---------------------------------------------------------------------------
#
# The generator is lifted out of mksd-buildroot.sh by its own two anchors and
# run on its own, because the rest of that script wants a bitstream, a card
# image and a Buildroot output tree.  The anchors are asserted the same way
# the init scripts' constants are.
#
# **AND THE BOARD'S FACTS BEFORE IT**, lifted the same way: the menu names the
# display's two windows, which are the board's, and the generator reads them
# from the block of the script that sets every board's.  $4 names the board,
# the Arty Z7-20 unless said, which is what the card script itself defaults to.
lift_board_facts() {
	awk '/^case "\$BOARD_NAME" in$/ {on=1}
	     on {print}
	     /^STAGED_FILES=\$BOARD_FILES$/ {if (on) exit}' "$MKSD" > "$1"
	if [ ! -s "$1" ] || [ "$(grep -c '^STAGED_FILES=\$BOARD_FILES$' "$1")" != "1" ]; then
		fail "the board's facts are not where this check looks in mksd-buildroot.sh"
		return 1
	fi
	return 0
}

generate_fpgarc() {
	rm -rf "$WORK/gen"
	mkdir -p "$WORK/gen/packs"
	lift_board_facts "$WORK/gen/board.sh" || return 1
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
	  BOARD_NAME=${4:-arty-z7-20}
	  BOARD_DTB=the-board.dtb
	  . "$WORK/gen/board.sh"
	  NO_AUTO_BOOT=$1
	  # $2 is RELEASE: empty for the development card, 1 for the card a
	  # stranger is given.  The two menus are the same file with a
	  # different set of lines live, so both are generated from this one
	  # block and the cases below say which is which.
	  RELEASE=${2:-}
	  # $3 is NO_BLINKING_LEDS, which local.conf sets on a card for a board
	  # that is left running and which a release never carries live.
	  NO_BLINKING_LEDS=${3:-}
	  CHAOS_PEER=""
	  CHAOS_DEFAULT_PEER=""
	  . "$WORK/gen/gen.sh" ) || return 1
	return 0
}

# The lines of a written menu that are live: a flag at the start of a line.
live_flags() { tr -d '\r' < "$1" | grep -E '^--' || true; }

# **AND THE CARD'S FILE MUST NAME EVERY FLAG THE PROGRAMS TAKE FROM IT.**
#
# The file is a menu: somebody with the card in a reader sees every setting,
# live or commented out, and uncomments what they want.  A menu is only a menu
# while it is complete, and nothing about writing a flag into a program's own
# list makes it appear here --- so this is what keeps the two from drifting.
# A flag added to a program and not to the card fails by name.
#
# **THE REQUIREMENTS ARE READ OUT OF THE SCRIPTS**, never from a list here: a
# second list is a second place to be wrong, which is the argument the Chaosnet
# script already makes about the hosts it resolves.  One LINE of a script's
# FLAGS is one requirement, because the Chaosnet program takes two spellings of
# each of its flags --- muir's `--chaos-address` and its own `--address`, on one
# line --- and a card says a setting once, in one spelling, not twice.
#
# **THE CONVENTION THE COUNT RESTS ON**: a commented-out setting is `#` with
# the flag straight after it, and a flag inside prose is indented away from the
# `#`.  So `#--bow` is a setting and `#     --chaos-udp-peer <address>@...` is a
# sentence about one.  The reader treats both as comments; only this tells them
# apart.
#
# Two flags are repeatable by their own definition --- a peer entry places ONE
# address and a named device is ONE device --- so those may appear more than
# once.  Everything else must appear exactly once, which is what catches a flag
# written into the file twice under two different explanations.
flag_requirements() {
	for _f in cadr-chaosnet/S87cadr-chaosnet cadr-terminal/S85cadr-terminal \
	          cadr-serial/S86cadr-serial cadr-usb-input/S88cadr-usb-input; do
		sed -n '/^FLAGS="/,/"[[:space:]]*$/p' "$PKG/$_f" |
			sed -e 's/^FLAGS="//' -e 's/"[[:space:]]*$//' |
			while IFS= read -r _line; do
				set -- $_line
				[ $# -gt 0 ] && echo "$*"
			done
	done
	# The disk pack script keeps no list: it asks for one flag by name.
	sed -n 's/.*fpgarc_has "\$RC" \(--[a-z0-9-]*\).*/\1/p' \
		"$PKG/cadr-disk-packs/S80cadr-disk-packs"
}

# How many SETTING lines a file has for one flag: live, or commented out with
# the flag straight after the `#`.
setting_lines() {
	tr -d '\r' < "$1" | grep -Ec "^#?$2( |$)" || true
}

case_head "the card's file names every flag every program takes from it"
sandbox
if generate_fpgarc ""; then
	GEN="$WORK/gen/packs/fpgarc"
	reqs=0
	missing=0
	twice=0
	flag_requirements > "$WORK/reqs"
	if [ ! -s "$WORK/reqs" ]; then
		fail "no flag lists were found in the init scripts: this check has rotted"
	fi
	while IFS= read -r req; do
		[ -n "$req" ] || continue
		reqs=$((reqs + 1))
		n=0
		for flag in $req; do
			n=$((n + $(setting_lines "$GEN" "$flag")))
		done
		if [ "$n" = 0 ]; then
			fail "the card's file says nothing about $req, which a program takes"
			missing=$((missing + 1))
			continue
		fi
		case "$req" in
		*--chaos-udp-peer*|*--usb-device*)
			# Repeatable: a peer entry places one address and a
			# named device is one device.
			;;
		*)
			if [ "$n" != 1 ]; then
				fail "the card's file says $req $n times; a setting is written once"
				twice=$((twice + 1))
			fi
			;;
		esac
	done < "$WORK/reqs"
	if [ "$missing" = 0 ] && [ "$twice" = 0 ]; then
		ok "all $reqs of them, each once, live or commented out"
	fi

	# And the file the card carries must still read as the reader reads it:
	# a live line is a flag and a commented one is not.
	if [ "$HAVE_READER" != yes ]; then
		fail "there is no reader to agree with the card script"
	else
		if fpgarc_has "$GEN" --terminal && fpgarc_has "$GEN" --serial; then
			ok "the screen's endpoint and the line's are live, and the reader finds both"
		else
			fail "the reader does not find --terminal and --serial live in the card's file"
		fi
		if fpgarc_has "$GEN" --bow || fpgarc_has "$GEN" --usb-grab; then
			fail "the reader takes a commented-out setting as a flag"
		else
			ok "and a commented-out setting is not a flag"
		fi
	fi
fi

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

# **THE LAMPS FOLLOW THE BOOT BUTTON'S SHAPE, WITH A RELEASE HELD TO BLINKING.**
# A card that says nothing about the lamps carries the line commented out;
# NO_BLINKING_LEDS=1 on a development card makes the same line live; and a
# released card writes it commented however the variable is set, because the
# menu a stranger is given must not depend on the builder's environment.
case_head "the card is written with blinking lamps by default"
sandbox
if generate_fpgarc "" "" ""; then
	GEN="$WORK/gen/packs/fpgarc"
	if tr -d '\r' < "$GEN" | grep -qx -- '#--no-blinking-leds'; then
		ok "the line is there and commented out"
	else
		fail "there is no commented --no-blinking-leds line in what the card script wrote"
	fi
	if tr -d '\r' < "$GEN" | grep -q -- '^--no-blinking-leds'; then
		fail "and it is also live, which it must not be"
	else
		ok "and it is not live"
	fi
	if grep -q 'the activity lamps hold a level' "$GEN"; then
		ok "and the sentence explaining it is beside it"
	else
		fail "the line has no sentence explaining it"
	fi
	if [ "$HAVE_READER" != yes ]; then
		fail "there is no reader to agree with the card script"
	elif fpgarc_has "$GEN" --no-blinking-leds; then
		fail "the reader takes the commented line as a flag"
	else
		ok "and the reader does not take it as a flag"
	fi
fi

case_head "NO_BLINKING_LEDS=1 makes the same line live on a development card"
sandbox
if generate_fpgarc "" "" 1; then
	GEN="$WORK/gen/packs/fpgarc"
	if tr -d '\r' < "$GEN" | grep -qx -- '--no-blinking-leds'; then
		ok "the line is live"
	else
		fail "the --no-blinking-leds line is not live in what the card script wrote"
	fi
	if tr -d '\r' < "$GEN" | grep -q -- '^#--no-blinking-leds'; then
		fail "and a commented copy of it is there as well"
	else
		ok "and it is there once"
	fi
	if [ "$HAVE_READER" != yes ]; then
		fail "there is no reader to find the live line"
	elif fpgarc_has "$GEN" --no-blinking-leds; then
		ok "and the reader finds it"
	else
		fail "the reader does not find the live line"
	fi
	# And nothing else moved: the live lines are the development card's six
	# and this one, which is the control that the variable reaches one line.
	got=$(live_flags "$GEN" | tr '\n' '|')
	want='--chaos-address 177101|--chaos-udp 0.0.0.0:42042|--terminal 0.0.0.0:5900|--keyboard-boot ctrl,meta|--serial 0.0.0.0:7641|--no-blinking-leds|--debug-cable-wiring auto|'
	if [ "$got" = "$want" ]; then
		ok "and it is the only line the variable made live"
	else
		fail "the development menu's live lines with the lamps steady are [$got], not [$want]"
	fi
fi

case_head "and a released card blinks even when NO_BLINKING_LEDS=1 is set"
sandbox
if generate_fpgarc "" 1 1; then
	GEN="$WORK/gen/packs/fpgarc"
	if tr -d '\r' < "$GEN" | grep -qx -- '#--no-blinking-leds'; then
		ok "the line is written commented out"
	else
		fail "the released menu has no commented --no-blinking-leds line"
	fi
	if [ "$HAVE_READER" != yes ]; then
		fail "there is no reader to agree with the card script"
	elif fpgarc_has "$GEN" --no-blinking-leds; then
		fail "a released card carries --no-blinking-leds live"
	else
		ok "and the reader does not find it, so a released board blinks"
	fi
fi

# **THE CLOCK'S TWO LINES ARE ON BOTH MENUS AND LIVE ON NEITHER.**  There is no
# date a card script could write.  The card carries the two lines and the form
# they take, and somebody who wants the board to know the date fills them in
# with a card reader.  The placeholder is the FORM rather than an example date,
# which is the difference between a line somebody uncomments and is told to
# fill in and a line somebody uncomments and gets a wrong date from.  The exact
# live lines of both menus are asserted below, and those two cases are the
# control that neither of these went live.
case_head "the card is written with the clock's two lines commented out"
for _rel in "" 1; do
	sandbox
	if generate_fpgarc "" "$_rel"; then
		GEN="$WORK/gen/packs/fpgarc"
		if [ -n "$_rel" ]; then _which="the released menu"; else _which="the development menu"; fi
		for f in --date --time; do
			if tr -d '\r' < "$GEN" | grep -qE "^#$f "; then
				ok "$_which has $f as a setting to uncomment"
			else
				fail "$_which has no commented $f setting"
			fi
			if tr -d '\r' < "$GEN" | grep -q -- "^$f "; then
				fail "$_which has $f live, and there is no date a card can guess"
			else
				ok "and $_which does not have it live"
			fi
		done
		if grep -q 'no real-time clock' "$GEN"; then
			ok "and the sentence saying why the two lines are there is beside them"
		else
			fail "$_which does not say why the two lines are there"
		fi
		if [ "$HAVE_READER" != yes ]; then
			fail "there is no reader to agree with the card script"
		elif fpgarc_has "$GEN" --date || fpgarc_has "$GEN" --time; then
			fail "the reader takes one of the commented clock lines as a flag"
		else
			ok "and the reader does not take either as a flag"
		fi
	fi
done

# ---------------------------------------------------------------------------
# 6b. THE RELEASED CARD'S MENU: THREE LIVE LINES, AND THE REST OF THE MENU
#     STILL THERE.
# ---------------------------------------------------------------------------
#
# **THE DECISION.**  A card a stranger is given carries the same whole menu the
# development card does --- every flag every program takes, each under the
# sentence that says what it does --- with three of them live: the address
# switches, the screen, and the chord that cold-boots the machine.  Those are
# what a board out of the box needs and nothing else is.
#
# **THE TWO THAT COME OUT ARE THINGS A USER PLUGS IN.**  A release with
# `--chaos-udp` live would put a station on a network the user has not got,
# listening on a port nobody named, with no peer it could reach; a release with
# `--serial` live would offer an unauthenticated port on every interface for a
# cable hardly anybody wants. muir's own rule for both is that they are off
# unless asked for.
#
# **WHAT MAKES THIS CHECKABLE RATHER THAN A CLAIM**: the released card's file
# and the development card's come out of one block of one script with one
# variable between them, so both can be written here and compared. The
# development menu is asserted as the control, because a release menu with
# three live lines could otherwise be bought by turning the development card's
# off as well, and every case above would still pass.
case_head "a released card's menu has three live lines and they are the three a board needs"
sandbox
if generate_fpgarc "" 1; then
	GEN="$WORK/gen/packs/fpgarc"
	got=$(live_flags "$GEN" | tr '\n' '|')
	want='--chaos-address 177101|--terminal 0.0.0.0:5900|--keyboard-boot ctrl,meta|'
	if [ "$got" = "$want" ]; then
		ok "the address switches, the screen and the boot chord, and nothing else"
	else
		fail "the released menu's live lines are [$got], not [$want]"
	fi
fi

case_head "and the cable and the serial line are on it, commented out"
sandbox
if generate_fpgarc "" 1; then
	GEN="$WORK/gen/packs/fpgarc"
	for f in --chaos-udp --serial; do
		if tr -d '\r' < "$GEN" | grep -qE "^#$f "; then
			ok "$f is there as a setting to uncomment"
		else
			fail "$f is not on the released menu as a commented setting"
		fi
	done
	# And the reader agrees, which is what the init scripts will do with it.
	if [ "$HAVE_READER" != yes ]; then
		fail "there is no reader to agree with the card script"
	else
		for f in --chaos-address --terminal --keyboard-boot; do
			fpgarc_has "$GEN" "$f" && ok "the reader finds $f" ||
				fail "the reader does not find $f live"
		done
		for f in --chaos-udp --serial; do
			fpgarc_has "$GEN" "$f" &&
				fail "the reader takes the commented $f as a flag" ||
				ok "and the reader does not find $f"
		done
	fi
fi

case_head "and it is still the whole menu: every flag every program takes is on it"
sandbox
if generate_fpgarc "" 1; then
	GEN="$WORK/gen/packs/fpgarc"
	reqs=0
	missing=0
	flag_requirements > "$WORK/reqs"
	if [ ! -s "$WORK/reqs" ]; then
		fail "no flag lists were found in the init scripts: this check has rotted"
	fi
	while IFS= read -r req; do
		[ -n "$req" ] || continue
		reqs=$((reqs + 1))
		n=0
		for flag in $req; do
			n=$((n + $(setting_lines "$GEN" "$flag")))
		done
		if [ "$n" = 0 ]; then
			fail "the released menu says nothing about $req, which a program takes"
			missing=$((missing + 1))
		fi
	done < "$WORK/reqs"
	[ "$missing" = 0 ] && ok "all $reqs of them, live or commented out"
fi

# **THE CONTROL.**  A release menu with three live lines is only a decision if
# the development card still has its six; otherwise the same result would come
# of turning everything off everywhere, and nothing above could tell.
case_head "and the development card's menu is unchanged: six live lines, the cable and the line among them"
sandbox
if generate_fpgarc "" ""; then
	GEN="$WORK/gen/packs/fpgarc"
	got=$(live_flags "$GEN" | tr '\n' '|')
	# The sixth is the JA ribbon's wiring, which is `auto` --- the fabric's
	# own reset value, so the line changes nothing.  It is live on a card
	# that is being worked on so that the boot log says which wiring the
	# board is on, and commented on a release, which keeps its three.
	want='--chaos-address 177101|--chaos-udp 0.0.0.0:42042|--terminal 0.0.0.0:5900|--keyboard-boot ctrl,meta|--serial 0.0.0.0:7641|--debug-cable-wiring auto|'
	if [ "$got" = "$want" ]; then
		ok "the cable is plugged in and the serial line is offered, as they always were"
	else
		fail "the development menu's live lines are [$got], not [$want]"
	fi
fi

# **AND THE INIT SCRIPTS READ THE RELEASED MENU THE WAY IT IS MEANT.**  The two
# cases above are about what is written; these two are about what a board then
# does with it, on the real file the real script writes rather than on one
# fabricated here.  That is the join the decision actually rests on: a menu
# whose commented lines the scripts ignored, or whose live ones they missed,
# would be a card that says one thing and a board that does another.
case_head "a board given the released menu has its switches set and no cable"
sandbox
if generate_fpgarc "" 1 && prepare cadr-chaosnet S87cadr-chaosnet; then
	cp "$WORK/gen/packs/fpgarc" "$WORK/packs/fpgarc"
	run_script S87cadr-chaosnet
	passes_once "--chaos-address" "cadr-chaosnet" "177101"
	passes_not "--chaos-udp" "cadr-chaosnet"
	if grep -q 'the cable is not plugged in' "$WORK/out.S87cadr-chaosnet"; then
		ok "and the console says the cable is not plugged in"
	else
		fail "the console does not say the cable is not plugged in"
	fi
fi

case_head "and its serial line is off, and its screen is served"
sandbox
if generate_fpgarc "" 1 && prepare cadr-serial S86cadr-serial; then
	cp "$WORK/gen/packs/fpgarc" "$WORK/packs/fpgarc"
	run_script S86cadr-serial
	if [ -s "$WORK/daemon.calls" ]; then
		fail "cadr-serial was started off the released menu: $(given)"
	else
		ok "cadr-serial was not started"
	fi
	if grep -q 'the serial line is off' "$WORK/out.S86cadr-serial"; then
		ok "and the console says the line is off"
	else
		fail "the console does not say the line is off"
	fi
fi
sandbox
if generate_fpgarc "" 1 && prepare cadr-terminal S85cadr-terminal; then
	cp "$WORK/gen/packs/fpgarc" "$WORK/packs/fpgarc"
	run_script S85cadr-terminal
	passes_once "--terminal" "cadr-terminal" "0.0.0.0:5900"
	passes_once "--keyboard-boot" "cadr-terminal" "ctrl,meta"
fi

# ---------------------------------------------------------------------------
# 7.  The card mirrors the server: the board's four files in the board's
#     folder, the three fixed names at the root, and a U-Boot that predates
#     the change refused.
# ---------------------------------------------------------------------------
#
# **WHY THIS IS HERE AND NOT IN A CHECK OF ITS OWN.**  This check already runs
# the real card script's fpgarc generator by lifting it out on its own anchors,
# because the rest of that script wants a bitstream, a Buildroot output tree
# and genimage.  The card's LAYOUT has exactly the same shape: two small blocks
# of the script that can be run alone against fabricated files, and no board.
# What a staging run proves on top of this is that genimage carried the folder
# into the image, which is read back there and cannot be read back here.
#
# **THE PROPERTY.**  Three files stay at the root of the boot partition because
# their names are not ours to move --- BOOT.BIN, which the boot ROM reads from
# the root of the first FAT partition; u-boot.img, which the SPL asks for by
# that name at the root; and uEnv.txt, which U-Boot imports before any board
# name is known.  The board's own four go in a folder named as the board's
# directory under `boards/` is, which is the name the TFTP server's directory
# for that board already has.  A card staged the old way and a U-Boot built the
# new way is a board that loops saying it cannot find a file, so the staging
# refuses that pair by name.

# A block of a card script, lifted on its own anchors and run alone, the
# anchors asserted so that a rename fails this check by name instead of
# quietly testing nothing --- which is `mutations/list.txt`'s discipline
# borrowed for a shell script, and the same thing `anchor` above does to the
# init scripts.  $1 is a line of the first line, $2 of the last, $3 where to
# put it, $4 the script (mksd-buildroot.sh unless said).
lift() {
	_first=$1; _last=$2; _out=$3; _src=${4:-$MKSD}
	_n=$(grep -Fc -- "$_first" "$_src" 2>/dev/null || true)
	if [ "$_n" != "1" ]; then
		fail "the anchor '$_first' matches $_n times in $(basename "$_src")," \
		     "not once: this check has rotted against the script it is for"
		return 1
	fi
	awk -v first="$_first" -v last="$_last" '
		!on && index($0, first) { on = 1; start = NR }
		on { print }
		on && NR > start && index($0, last) { exit }
	' "$_src" > "$_out"
	if [ ! -s "$_out" ]; then
		fail "$(basename "$_src") has no block starting '$_first': this check has rotted"
		return 1
	fi
	if ! grep -Fq -- "$_last" "$_out"; then
		fail "the block starting '$_first' does not reach '$_last': this check has rotted"
		return 1
	fi
	return 0
}

case_head "the card script puts the board's four files in the board's own folder"
sandbox
mkdir -p "$WORK/lay/images" "$WORK/lay/out"
for f in boot.bin u-boot.img zImage rootfs.cpio.uboot zynq-arty-z7-20.dtb \
         u-boot.itb Image socfpga_agilex5_de25_nano_cadr.dtb; do
	echo "$f" > "$WORK/lay/images/$f"
done
echo bitstream > "$WORK/lay/the.bit"
# One board's copy, run the way the script runs it: the board's facts, then the
# copy block, each lifted on its own anchors.  $1 the board, $2 its tree.
lay_out() {
	rm -rf "$WORK/lay/out"; mkdir -p "$WORK/lay/out"
	( set -eu
	  OUT="$WORK/lay/out"
	  IMAGES="$WORK/lay/images"
	  BIT="$WORK/lay/the.bit"
	  NO_FABRIC=
	  BOARD_NAME=$1
	  BOARD_DTB=$2
	  . "$WORK/lay/board.sh"
	  mkdir -p "$OUT/card/$BOARD_NAME"
	  . "$WORK/lay/copy.sh" ) 2>"$WORK/lay/err"
}
if lift_board_facts "$WORK/lay/board.sh" \
   && lift 'for spec in $ROOT_FILES; do' \
        'cp "$IMAGES/$BOARD_DTB" "$IMAGES/$KERNEL" "$IMAGES/rootfs.cpio.uboot"' \
        "$WORK/lay/copy.sh"; then
	if ! lay_out arty-z7-20 zynq-arty-z7-20.dtb; then
		fail "the card script's copy block did not run: $(cat "$WORK/lay/err")"
	else
		root_ok=yes
		for f in BOOT.BIN u-boot.img; do
			[ -f "$WORK/lay/out/card/$f" ] || { fail "card/$f is not at the root"; root_ok=no; }
		done
		[ "$root_ok" = yes ] && ok "BOOT.BIN and u-boot.img are at the root, where their names are fixed"
		folder_ok=yes
		for f in cadr.bit zynq-arty-z7-20.dtb zImage rootfs.cpio.uboot; do
			[ -f "$WORK/lay/out/card/arty-z7-20/$f" ] \
				|| { fail "card/arty-z7-20/$f is not in the board's folder"; folder_ok=no; }
			if [ -f "$WORK/lay/out/card/$f" ]; then
				fail "card/$f is also at the root, where nothing reads it"
				folder_ok=no
			fi
		done
		[ "$folder_ok" = yes ] \
			&& ok "and cadr.bit, the tree, zImage and the root filesystem are in arty-z7-20/ and nowhere else"
	fi
	# **THE DE25-Nano FROM THE SAME BLOCK**, which is the point of the
	# block: one layout, the board's own names.  Its first-stage loader is in
	# its flash, so the root holds u-boot.itb and no BOOT.BIN, and the fabric
	# is a core.rbf.
	if ! lay_out de25-nano socfpga_agilex5_de25_nano_cadr.dtb; then
		fail "the card script's copy block did not run for the DE25-Nano: $(cat "$WORK/lay/err")"
	else
		de25_ok=yes
		[ -f "$WORK/lay/out/card/u-boot.itb" ] || { fail "card/u-boot.itb is not at the root"; de25_ok=no; }
		for f in BOOT.BIN u-boot.img; do
			[ -e "$WORK/lay/out/card/$f" ] && { fail "the DE25-Nano's card has a $f, which nothing on it reads"; de25_ok=no; }
		done
		for f in cadr.core.rbf socfpga_agilex5_de25_nano_cadr.dtb Image rootfs.cpio.uboot; do
			[ -f "$WORK/lay/out/card/de25-nano/$f" ] \
				|| { fail "card/de25-nano/$f is not in the board's folder"; de25_ok=no; }
		done
		n=$(ls "$WORK/lay/out/card" | wc -l)
		[ "$n" = 2 ] || { fail "the DE25-Nano's card root holds $n entries, wanting u-boot.itb and de25-nano/"; de25_ok=no; }
		[ "$de25_ok" = yes ] \
			&& ok "and the DE25-Nano's: u-boot.itb alone at the root, cadr.core.rbf, its tree, Image and the root filesystem in de25-nano/"
	fi
fi

case_head "a U-Boot that loads from the root of the partition is refused by name"
sandbox
mkdir -p "$WORK/ub/card"
if lift '# AND IT MUST LOAD THE BOARD' 'done' "$WORK/ub/refuse.sh"; then
	# Two fabricated loaders, differing in the one thing the refusal reads.
	# `strings` takes them as they are, being text.
	printf 'bootcmd=run cadr_boot\ncadr_card=load mmc 0:1 ${a} arty-z7-20/cadr.bit && load mmc 0:1 ${b} arty-z7-20/zynq-arty-z7-20.dtb && load mmc 0:1 ${c} arty-z7-20/zImage && load mmc 0:1 ${d} arty-z7-20/rootfs.cpio.uboot && run cadr_bootz\n' \
		> "$WORK/ub/new.img"
	printf 'bootcmd=run cadr_boot\ncadr_card=load mmc 0:1 ${a} cadr.bit && load mmc 0:1 ${b} zynq-arty-z7-20.dtb && load mmc 0:1 ${c} zImage && load mmc 0:1 ${d} rootfs.cpio.uboot && run cadr_bootz\n' \
		> "$WORK/ub/old.img"
	lift_board_facts "$WORK/ub/board.sh" || true
	run_refusal() {
		cp "$1" "$WORK/ub/card/u-boot.img"
		( set -eu
		  OUT="$WORK/ub"
		  BOARD_NAME=arty-z7-20
		  BOARD_DTB=zynq-arty-z7-20.dtb
		  . "$WORK/ub/board.sh"
		  die() { echo "mksd-buildroot: $*" >&2; exit 1; }
		  . "$WORK/ub/refuse.sh" ) 2>"$WORK/ub/err"
	}
	if run_refusal "$WORK/ub/new.img"; then
		ok "a U-Boot that loads arty-z7-20/cadr.bit and the rest is accepted"
	else
		fail "the staging refuses a U-Boot that IS right: $(cat "$WORK/ub/err")"
	fi
	if run_refusal "$WORK/ub/old.img"; then
		fail "the staging accepts a U-Boot that loads cadr.bit from the root of the partition"
	else
		ok "and one that loads cadr.bit from the root is refused"
		# **AN EXIT CODE CANNOT TELL TWO FAILURES APART**, so the
		# message is asserted and not the status: this refusal has to
		# say which file and what to do, because a plain stop here
		# reads as a broken staging tool rather than a stale U-Boot.
		if grep -q 'arty-z7-20/cadr.bit' "$WORK/ub/err"; then
			ok "and it names the file it wanted"
		else
			fail "the refusal does not name the file: $(cat "$WORK/ub/err")"
		fi
		if grep -q 'buildroot-rebuild' "$WORK/ub/err"; then
			ok "and it names the command that rewrites the loader"
		else
			fail "the refusal does not say how to fix it: $(cat "$WORK/ub/err")"
		fi
	fi
fi

case_head "every board's U-Boot loads its four files from its own folder"
sandbox
# A here-document and not a pipe: a `while` on the far end of a pipe runs in a
# subshell, and the failure count this check exits on would be incremented
# there and lost --- a case that prints FAIL and still leaves the run green.
while IFS= read -r spec; do
	# <environment>=<board>=<its tree>=<its fabric>=<its kernel>
	IFS='=' read -r env_rel board dtb fabric kernel <<EOF_SPEC
$spec
EOF_SPEC
	env_file="$TREE/$env_rel"
	if [ ! -f "$env_file" ]; then
		fail "no environment at $env_file: this check has rotted"
		continue
	fi
	block=$(sed -n '/^cadr_card=/,/^$/p' "$env_file")
	bad=0
	for f in "$fabric" "$dtb" "$kernel" rootfs.cpio.uboot; do
		echo "$block" | grep -q "load mmc 0:1 [^ ]* $board/$f " \
			|| { fail "$(basename "$env_file")'s cadr_card does not load $board/$f"; bad=1; }
	done
	# uEnv.txt is imported before any board name is known, so it must NOT
	# be under the folder: a card whose loader looked for it there would
	# never read the file that decides which path it takes.
	grep -q "load mmc 0:1 \${cadr_uenv_addr} uEnv.txt" "$env_file" \
		|| { fail "$(basename "$env_file") does not import uEnv.txt from the root of the partition"; bad=1; }
	[ "$bad" = 0 ] && ok "$(basename "$env_file"): all four out of $board/, and uEnv.txt from the root"
done <<'ENVS'
boards/arty-z7-20/linux/buildroot/board/arty-z7-20/uboot/cadr.env=arty-z7-20=zynq-arty-z7-20.dtb=cadr.bit=zImage
boards/cora-z7-07s/linux/buildroot/board/cora-z7-07s/uboot/cadr_cora.env=cora-z7-07s=zynq-cora-z7-07s.dtb=cadr.bit=zImage
boards/de25-nano/linux/buildroot/board/de25-nano/uboot/cadr_de25.env=de25-nano=socfpga_agilex5_de25_nano_cadr.dtb=cadr.core.rbf=Image
ENVS

case_head "the DE25-Nano's menu is the Zynq boards' with the DE25-Nano's windows"
sandbox
# **ONE MENU FOR EVERY BOARD, AND THE ADDRESSES IN IT ARE THE BOARD'S.**  The
# file of flags is the machine's and not the part's, so the DE25-Nano's card
# must carry the same menu line for line --- and the two lines that name where
# the display's windows are must name the DE25-Nano's, 64 MB into ITS
# reservation, or a person uncommenting them would point the screen at the
# wrong memory.  Generated twice from the one block and compared.
if generate_fpgarc "" "" "" arty-z7-20 && cp "$WORK/gen/packs/fpgarc" "$WORK/fpgarc.arty" \
   && generate_fpgarc "" "" "" de25-nano && cp "$WORK/gen/packs/fpgarc" "$WORK/fpgarc.de25"; then
	if tr -d '\r' < "$WORK/fpgarc.arty" | grep -qx -- '#--window 0x1C000000' \
	   && tr -d '\r' < "$WORK/fpgarc.arty" | grep -qx -- '#--color-window 0x1C020000'; then
		ok "the Arty Z7-20's names its display at 0x1C000000 and the color display at 0x1C020000"
	else
		fail "the Arty Z7-20's menu does not name its display's windows"
	fi
	if tr -d '\r' < "$WORK/fpgarc.de25" | grep -qx -- '#--window 0xB4000000' \
	   && tr -d '\r' < "$WORK/fpgarc.de25" | grep -qx -- '#--color-window 0xB4020000'; then
		ok "the DE25-Nano's names its display at 0xB4000000 and the color display at 0xB4020000"
	else
		fail "the DE25-Nano's menu does not name ITS display's windows"
	fi
	n=$(diff "$WORK/fpgarc.arty" "$WORK/fpgarc.de25" | grep -c '^[<>]' || true)
	if [ "$n" = 4 ]; then
		ok "and the two menus differ in those two lines and in nothing else"
	else
		fail "the two boards' menus differ in $n lines, wanting the two windows' 4:" \
		     "$(diff "$WORK/fpgarc.arty" "$WORK/fpgarc.de25" | head -20)"
	fi
fi

# ---------------------------------------------------------------------------
# 8.  The release guard: it lets the card's own file through, and it still
#     catches an address.
# ---------------------------------------------------------------------------
#
# **A GUARD NOBODY RUNS IS A GUARD NOBODY KNOWS IS WRONG, AND THIS ONE WAS.**
# mksd-release.sh greps the staged card for anything address-shaped, because
# the flag that says a release carries nothing of ours is a flag and a flag can
# be wrong.  When the card's file of flags became a full menu it gained the
# loopback in its prose and RFC 5737's TEST-NET-1 in its two commented
# examples, and the guard exempted 0.0.0.0 alone --- so a release stopped on
# every board, naming four lines that were not private at all.  Nothing had run
# it, so nothing said so.
#
# So the guard is run here, on the file the card script really writes, both
# ways: it must pass what a release carries, and it must still catch a private
# address and a MAC.  The second half is what keeps the first from being
# bought by widening the exemption until nothing is caught.
case_head "the release guard passes the card's own file of flags and still catches an address"
sandbox
mkdir -p "$WORK/rel/card" "$WORK/rel/packs"
if lift 'addrs=$(grep -rEoh' '| sort -u || true)' "$WORK/rel/guard.sh" "$MKSDREL" \
   && generate_fpgarc ""; then
	cp "$WORK/gen/packs/fpgarc" "$WORK/rel/packs/fpgarc"
	run_guard() {
		( set -u
		  OUT="$WORK/rel"
		  . "$WORK/rel/guard.sh"
		  printf '%s' "$addrs" )
	}
	got=$(run_guard)
	if [ -z "$got" ]; then
		ok "the file the card script writes carries nothing the guard calls an address"
	else
		fail "the guard stops a release on the card's own file: $(echo "$got" | tr '\n' ' ')"
	fi
	# The bite.  A private address and a MAC, which are the two things the
	# guard exists for and the two shapes a card has really carried.
	# The two values below are invented for this case and are on no network
	# and no board: 10.0.0.7 is a private address this project does not use,
	# and 02:00:00:00:00:01 is a locally-administered MAC nobody can have
	# been given.  A guard that catches a MAC cannot be tested without a
	# MAC-shaped string, and this is the least real one there is.
	printf 'serverip=10.0.0.7\nethaddr=02:00:00:00:00:01\n' > "$WORK/rel/card/uEnv.txt"
	got=$(run_guard)
	if echo "$got" | grep -q '10\.0\.0\.7'; then
		ok "and a private address on the boot partition still stops the release"
	else
		fail "the guard no longer catches a private address: the exemptions have eaten it"
	fi
	if echo "$got" | grep -qi '02:00:00:00:00:01'; then
		ok "and so does a MAC"
	else
		fail "the guard no longer catches a MAC"
	fi
	rm -f "$WORK/rel/card/uEnv.txt"
	# And the exemptions are only the addresses that cannot name a host: an
	# address one away from an exempt one is not exempt.
	printf -- '--chaos-udp-peer 3060@0.0.0.1:42043\n' > "$WORK/rel/packs/near"
	got=$(run_guard)
	if echo "$got" | grep -q '0\.0\.0\.1'; then
		ok "and 0.0.0.1 is not 0.0.0.0"
	else
		fail "the guard exempts more than the exact strings it names"
	fi
	rm -f "$WORK/rel/packs/near"
fi

# ---------------------------------------------------------------------------
# 9.  A release carries nothing from local.conf, because it does not read it.
# ---------------------------------------------------------------------------
#
# **THIS IS A CHECK ON THE SOURCE AND NOT ON A RUN, AND THE REASON IS THE
# PROPERTY'S OWN SHAPE.**  The card script used to read local.conf always and
# then clear six values by name when STANDALONE was set.  Every card setting is
# read as `${VAR:-<default>}`, so local.conf could set any of them, and only
# six were ever in that list --- measured on this project's own build host, a
# release image carried this board's Chaosnet station number, which no address
# guard can see because it is an octal number on a private subnet.  A list of
# names is a place to be short.  Not reading the file is not.
#
# So what is asserted is the structure: there is exactly one place local.conf
# is read, and it is guarded by STANDALONE.  A run cannot show this without a
# Buildroot output tree and a bitstream, and a run that showed it for the six
# names in the list would have passed before the fault as well.
case_head "a release does not read local.conf at all"
sandbox
n=$(grep -c '^[[:space:]]*\. "\$BOARD_DIR/linux/local.conf"' "$MKSD" 2>/dev/null || true)
if [ "$n" != "1" ]; then
	fail "mksd-buildroot.sh reads local.conf $n times, not once: this check has rotted"
else
	ok "local.conf is read in exactly one place"
	if grep -B2 '^[[:space:]]*\. "\$BOARD_DIR/linux/local.conf"' "$MKSD" \
	   | grep -q '\[ -z "\$STANDALONE" \]'; then
		ok "and that place is guarded by STANDALONE, so a release cannot carry anything from it"
	else
		fail "local.conf is read with no STANDALONE guard: a release would carry whatever is in it"
	fi
fi
# And the environment, which a file cannot be asked about: the flag still
# clears by name the settings an exported variable could otherwise carry into
# a release.  This is the list that can go short, so it is named here and the
# case says which two kinds of value it is for.
cleared=yes
for v in SERVERIP ETHADDR CHAOS_PEER CHAOS_DEFAULT_PEER CC_PACK NO_AUTO_BOOT \
         NO_BLINKING_LEDS CHAOS_ADDR_FPGA CHAOS_ADDR_MUIR; do
	if sed -n '/^if \[ -n "\$STANDALONE" \]; then$/,/^fi$/p' "$MKSD" | grep -q "$v="; then
		:
	else
		fail "STANDALONE does not clear $v, so an exported one would reach a release"
		cleared=no
	fi
done
[ "$cleared" = yes ] \
	&& ok "and STANDALONE clears the private values and the board's station numbers out of the environment"

echo
if [ "$fails" = 0 ]; then
	echo "fpgarc: $cases cases, one file of flags reaches five programs and each gets its own"
	exit 0
fi
echo "fpgarc: $fails failures in $cases cases"
exit 1
