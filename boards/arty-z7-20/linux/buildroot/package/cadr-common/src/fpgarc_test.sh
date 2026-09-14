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
STARTER="$PKG/cadr-common/src/daemon.sh"
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
case "\$1" in
halt) [ "\${CONSOLE_HALTS:-yes}" = yes ] ;;
switch) [ "\${CONSOLE_SWITCH:-no}" = yes ] ;;
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
		;;
	esac
	return 0
}

run_script() {
	: > "$WORK/daemon.calls"
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
	passes "--terminal 0.0.0.0:5900" "cadr-terminal"
	passes_not "--port" "cadr-terminal"
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
	# **muir'S SPELLING, WHICH IS THE WHOLE OF WHY `--port` IS GONE.**  The
	# screen and the serial line both took `--port` and `--bind`, so no
	# list could claim either word and no `fpgarc` line could say where
	# either program listened.  Each has muir's own flag now and the init
	# script passes it written out in full.
	passes "--serial 0.0.0.0:7641" "cadr-serial"
	passes_not "--port" "cadr-serial"
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

case_head "and once, the script's own, when the card says nothing about it"
sandbox
if prepare cadr-serial S86cadr-serial; then
	printf '%s\r\n' '--quiet' > "$RC"
	run_script S86cadr-serial
	passes_once "--serial" "cadr-serial" "0.0.0.0:7641"
fi

case_head "and once with no card at all"
sandbox
if prepare cadr-serial S86cadr-serial; then
	rm -f "$RC"
	run_script S86cadr-serial
	passes_once "--serial" "cadr-serial" "0.0.0.0:7641"
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
# which is muir's behaviour and the property this whole file of flags rests on.
# But an init script starts its program with `start-stop-daemon -b`, which
# daemonises it and closes stdout and stderr, so the refusal went to /dev/null
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
	# program refuses, $4 the program's name.
	sandbox
	printf '%s\r\n' "$3" > "$WORK/packs/fpgarc"
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
refusal_case cadr-serial     S86cadr-serial    --quiet        cadr-serial
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

case_head "and a file every program's list covers is reported silently"
sandbox
printf '%s\r\n' '--chaos-address 3050' '--bow' '--usb-grab' > "$WORK/packs/fpgarc"
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
# 6.  The card script writes the line, commented out unless asked.
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

echo
if [ "$fails" = 0 ]; then
	echo "fpgarc: $cases cases, one file of flags reaches five programs and each gets its own"
	exit 0
fi
echo "fpgarc: $fails failures in $cases cases"
exit 1
