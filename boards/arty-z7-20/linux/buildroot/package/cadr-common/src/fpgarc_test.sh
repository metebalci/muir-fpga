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
STOPPER="$PKG/cadr-common/src/stop.sh"
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
	mkdir -p "$WORK/bin" "$WORK/card" "$WORK/run" "$WORK/mnt" "$WORK/dev"
	: > "$WORK/daemon.calls"
	: > "$WORK/console.calls"
	: > "$WORK/ip.calls"
	: > "$WORK/nslookup.calls"
	: > "$WORK/date.calls"
	: > "$WORK/umount.calls"
	: > "$WORK/order.calls"
	: > "$WORK/ozd.check.calls"
	: > "$WORK/ssd.fg.calls"

	# **THE REAL ONE FORKS THE PROGRAM AND CLOSES ITS OUTPUT**, which is
	# what made a refused flag silent, so this does the same: it records
	# what it was asked, runs the program named by --exec in the
	# background with stdout and stderr on /dev/null, and writes the pid
	# where -p says.  A stub that only recorded could not tell a program
	# that started from one that refused its flags and went, which is the
	# whole of what `cadr_daemon` is for.
	#
	# **AND -K IS THE REAL ONE'S TOO**: SIGTERM to the process the pid file
	# names, 1 when there is none, and a return at once without waiting for
	# it to go, which is the whole of why `stop.sh` exists.
	#
	# **AND -c IS THE REAL ONE'S, AS FAR AS A CHECK THAT IS NOT ROOT CAN
	# TAKE IT.**  Nobody here can change user, so the stub hands the user
	# -c names to the program as \$SSD_CHUID, and the ozd stand-in below
	# refuses to run without it, as the real ozd refuses to run as root.
	#
	# **AND WITHOUT -b IT RUNS THE PROGRAM IN THE FOREGROUND**, as the real
	# one does (busybox's start_stop_daemon.c execs it in place, with the
	# caller's stdout and stderr, and its status is the program's).  Such a
	# run is recorded in ssd.fg.calls and not in daemon.calls, which is the
	# record of what was STARTED and which every case counts flags in.
	cat > "$WORK/bin/start-stop-daemon" <<EOF
#!/bin/sh
_all="\$*"
_pidfile=""
_prog=""
_kill=no
_bg=no
_chuid=""
while [ \$# -gt 0 ]; do
	case "\$1" in
	-K) _kill=yes ;;
	-b) _bg=yes ;;
	-c) _chuid=\$2; shift ;;
	-p) _pidfile=\$2; shift ;;
	--exec) _prog=\$2; shift ;;
	--) shift; break ;;
	esac
	shift
done
if [ "\$_kill" = no ] && [ "\$_bg" = no ]; then
	echo "\$_all" >> "$WORK/ssd.fg.calls"
	[ -n "\$_prog" ] || exit 0
	SSD_CHUID=\$_chuid exec "\$_prog" "\$@"
fi
echo "\$_all" >> "$WORK/daemon.calls"
if [ "\$_kill" = yes ]; then
	_pid=\$(cat "\$_pidfile" 2>/dev/null)
	[ -n "\$_pid" ] && kill -0 "\$_pid" 2>/dev/null || exit 1
	kill -TERM "\$_pid"
	exit 0
fi
[ -n "\$_prog" ] || exit 0
SSD_CHUID=\$_chuid "\$_prog" "\$@" > /dev/null 2>&1 &
[ -n "\$_pidfile" ] && echo \$! > "\$_pidfile"
exit 0
EOF
	# The five programs, each a stand-in that refuses the flag \$REFUSE
	# names --- on stderr, which is where every one of them refuses --- and
	# otherwise runs, which is what a daemon does.  The name is its own, so
	# a refusal printed here is attributable the way the real one is.
	# **AND THE SIXTH IS NOT OURS.**  ozd takes no --log and has a dry run
	# of its own, `--check`, which its init script uses instead of this
	# board's start-it-and-run-it-again trick.  \$OZD_CHECK_FAILS makes
	# that dry run refuse, which is the case where a card names a root
	# that is not there.
	#
	# **AND IT REFUSES TO RUN AS ROOT, FOR --check TOO, AS THE REAL ONE
	# DOES.**  An init script runs as root, so a run that did not come
	# through start-stop-daemon's -c with the user S84ozd names is a run as
	# root, and this refuses it in the real one's words before it looks at
	# a single flag.  That is what kept ozd from ever starting on a board:
	# its dry run was run as root and refused.
	cat > "$WORK/bin/ozd" <<EOF
#!/bin/sh
if [ "\${SSD_CHUID:-}" != "$(id -un)" ]; then
	echo "ozd: refusing to run as root: nothing here needs a privilege, and as root a containment bug would reach every file on this host; run it as a user that owns its roots and nothing else (docs/design.md §6)" >&2
	exit 1
fi
for a; do
	case "\$a" in
	--check)
		echo "\$*" >> "$WORK/ozd.check.calls"
		if [ "\${OZD_CHECK_FAILS:-no}" = yes ]; then
			echo "ozd: root /mnt/card/sys: cannot be resolved: No such file or directory (os error 2)" >&2
			exit 1
		fi
		exit 0
		;;
	esac
done
exec sleep 8
EOF
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
	#
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
	# **THE TWO THE DISK SCRIPT USES ON THE CARD.**  Nothing is really
	# mounted here: the card is a directory the rewrite points the script
	# at.  What the stub decides is WHICH DEVICE ANSWERS, which is the whole
	# of how that script tells a card of the new one-partition shape from
	# one of the old two-partition shape.  `$WORK/mountable` names the
	# device that mounts, or is empty, which is a board with no card and is
	# what every case that says nothing about it gets --- so the cases
	# written before the two shapes existed are unchanged.
	:> "$WORK/mountable"
	: > "$WORK/mount.calls"
	# `mountpoint` says the card is mounted when `$WORK/mounted` stands,
	# which only the cases about `stop` make, so every case about `start`
	# sees an unmounted card as it always has.
	cat > "$WORK/bin/mountpoint" <<EOF
#!/bin/sh
[ -f "$WORK/mounted" ]
EOF
	cat > "$WORK/bin/mount" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/mount.calls"
_dev=""
for _a; do case "\$_a" in $WORK/dev/*) _dev=\$_a ;; esac; done
[ -n "\$_dev" ] || exit 1
grep -qx "\$_dev" "$WORK/mountable" 2>/dev/null || exit 1
exit 0
EOF
	# **WHO THE ozd USER IS, WHICH THE IMAGE DECIDES AND THE CASE SAYS.**
	# Buildroot picks the user's ids when it builds the image, so the disk
	# script asks for its group at boot.  \`$WORK/ozd.gid\` holds the gid
	# the image gave it, and its absence is an image built without ozd.
	# Every case gets one unless it says otherwise, because every image this
	# project builds has the host.  Any other question goes to the real id.
	echo 1042 > "$WORK/ozd.gid"
	_realid=$(command -v id)
	cat > "$WORK/bin/id" <<EOF
#!/bin/sh
case "\$*" in
"-g ozd"|"-G ozd"|"ozd"|"-u ozd")
	if [ -s "$WORK/ozd.gid" ]; then
		case "\$1" in
		-u) echo 1041 ;;
		-g|-G) cat "$WORK/ozd.gid" ;;
		*) echo "uid=1041(ozd) gid=\$(cat "$WORK/ozd.gid")(ozd)" ;;
		esac
		exit 0
	fi
	echo "id: unknown user ozd" >&2
	exit 1
	;;
esac
exec "$_realid" "\$@"
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
	#
	# **AND IT REFUSES WHILE THE PACK PROGRAM IS STILL RUNNING**, as the
	# real one does while the program holds its packs open: EBUSY, said on
	# stderr, which is what a `2>/dev/null` once hid.
	cat > "$WORK/bin/umount" <<EOF
#!/bin/sh
_p=\$(cat "$WORK/run/cadr-disk-packs.pid" 2>/dev/null)
if [ -n "\$_p" ] && kill -0 "\$_p" 2>/dev/null; then
	echo "\$1 was unmounted while cadr-disk-packs was still running" >> "$WORK/umount.calls"
	echo "umount: can't unmount \$1: Device or resource busy" >&2
	exit 1
fi
if [ -f "$WORK/card/clock" ]; then
	echo "the clock was saved before \$1 was unmounted" >> "$WORK/umount.calls"
else
	echo "\$1 was unmounted before the clock was saved" >> "$WORK/umount.calls"
fi
rm -f "$WORK/mounted"
exit 0
EOF
	# **A PROGRAM THAT TAKES ITS TIME TO STOP**, as cadr-disk-packs does
	# while it writes its dirty slots back: SIGTERM, then \$SLOW seconds,
	# then gone.  With \$DEAF=yes it ignores SIGTERM altogether, which is a
	# program that does not stop; exec keeps the signal ignored.
	cat > "$WORK/bin/slow-to-stop" <<EOF
#!/bin/sh
if [ "\${DEAF:-no}" = yes ]; then
	trap '' TERM
	exec sleep 30
fi
trap 'kill \$_w 2>/dev/null; sleep \${SLOW:-1}; exit 0' TERM
sleep 30 &
_w=\$!
wait \$_w
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
	# **WHERE THE CARD IS MOUNTED, WHICH EVERY ONE OF THE SIX NAMES THE SAME
	# WAY.**  The card is one FAT32 partition and `fpgarc` is at its root,
	# so this one rewrite serves all six scripts; a script that spelled it
	# differently would fail the anchor by name rather than quietly reading
	# a file that is not there.
	anchor "$dst" "^CARD=/mnt/card\$" "CARD=$WORK/card" || return 1
	anchor "$dst" "^FPGARC_SH=/usr/share/cadr/fpgarc.sh\$" \
	              "FPGARC_SH=$READER" || return 1
	# **AND THE STOPPER, WHICH EVERY ONE OF THE SIX SOURCES**, ozd
	# included: `start-stop-daemon -K` does not wait, and a script that
	# stops its program without this has gone back to not waiting.
	anchor "$dst" "^STOP_SH=/usr/share/cadr/stop.sh\$" \
	              "STOP_SH=$STOPPER" || return 1
	# **THE DAEMON STARTER IS NOT EVERY SCRIPT'S.**  Five of the six are
	# our own programs and every one of them is started through
	# `cadr_daemon`, which is what makes a refused flag loud.  ozd is not
	# ours: it takes no --log, and it has a dry run of its own that says
	# the same thing earlier.  So the line is required of the five and
	# required to be ABSENT from the sixth, rather than merely allowed to
	# be missing --- a script that grew one would otherwise start using it
	# with nothing here noticing.
	case "$2" in
	S84ozd)
		if grep -q "^DAEMON_SH=" "$dst"; then
			fail "S84ozd has a DAEMON_SH line now; it used ozd's own --check instead," \
			     "and this check has rotted against it"
			return 1
		fi
		anchor "$dst" "^LOG=/var/log/ozd.log\$" "LOG=$WORK/ozd.log" || return 1
		anchor "$dst" "^PEERFILE=/var/run/cadr-ozd.peer\$" \
		              "PEERFILE=$WORK/run/cadr-ozd.peer" || return 1
		anchor "$dst" "^BASE_ROOT=/var/lib/ozd/lispm\$" \
		              "BASE_ROOT=$WORK/ozdroot" || return 1
		# Nobody in this check is root, so the program runs as whoever
		# is running the check.  What the user is for is held by the
		# users table and by the line above, not here.
		anchor "$dst" "^OZD_USER=ozd\$" "OZD_USER=$(id -un)" || return 1
		;;
	*)
		anchor "$dst" "^DAEMON_SH=/usr/share/cadr/daemon.sh\$" \
		              "DAEMON_SH=$STARTER" || return 1
		;;
	esac
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
		# What S84ozd leaves behind when it has started a host on this
		# board.  The two scripts name one path and this rewrite is
		# what keeps the check honest about that: a rename in either
		# fails here by name.
		anchor "$dst" "^OZD_PEERFILE=/var/run/cadr-ozd.peer\$" \
		              "OZD_PEERFILE=$WORK/run/cadr-ozd.peer" || return 1
		;;
	S80cadr-disk-packs)
		# **THE TWO DEVICES, WHICH ONLY THIS SCRIPT KNOWS ABOUT.**  It is
		# the one place on the board that knows a card may be of the old
		# two-partition shape, so it is the one script with devices in
		# it.  They are rewritten to paths the stubbed `mount` can be
		# told about, and a rename in the script fails here by name.
		anchor "$dst" "^CARD_DEV=/dev/mmcblk0p1\$" "CARD_DEV=$WORK/dev/p1" || return 1
		anchor "$dst" "^OLD_CARD_DEV=/dev/mmcblk0p2\$" "OLD_CARD_DEV=$WORK/dev/p2" || return 1
		anchor "$dst" "^HELD=/var/run/cadr-held\$" "HELD=$WORK/run/cadr-held" || return 1
		# The clock's own shell, cadr-common's third file on the target,
		# beside the reader and the daemon starter.
		anchor "$dst" "^CLOCK_SH=/usr/share/cadr/clock.sh\$" \
		              "CLOCK_SH=$CLOCKSH" || return 1
		# Three seconds rather than thirty, so the case of a program that
		# does not stop is three seconds of this check and not thirty.
		anchor "$dst" "^PACKS_STOP_SECONDS=30\$" "PACKS_STOP_SECONDS=3" || return 1
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
	# And where it remembers which repeated flags it has already warned
	# about, so that a script asking about one flag twice warns once.  Each
	# run here is a boot, so it starts empty.
	rm -f "$WORK/run/warned"
	FPGARC_CLAIMED="$WORK/run/claimed" FPGARC_WARNED="$WORK/run/warned" \
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
	RC="$WORK/card/fpgarc"

	# One file with a line for every program on the board, written with
	# carriage returns as a card reader leaves them, a comment, a blank
	# line, leading space, an argument with a space in it and a bare flag.
	printf '%s\r\n' \
		'# the flags for the CADR in the fabric' \
		'' \
		'--chaos-address 3050' \
		'--chaos-udp 0.0.0.0:42042' \
		'  --keyboard-mapping /mnt/card/a name with spaces.txt  ' \
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
	if [ "$got" = "2|/mnt/card/a name with spaces.txt" ]; then
		ok "the mapping file is one argument, trimmed at both ends"
	else
		fail "the mapping file came back as [$got]"
	fi

	case_head "an argument with a quote in it survives"
	printf "%s\r\n" "--keyboard-mapping /mnt/card/it's here.txt" > "$WORK/card/quoted"
	got=$(eval "set -- $(fpgarc_args "$WORK/card/quoted" --keyboard-mapping)"; printf '%s' "$2")
	if [ "$got" = "/mnt/card/it's here.txt" ]; then
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
	if fpgarc_args "$WORK/card/no-such-file" --chaos-address > "$WORK/absent"; then
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
# 1b.  THE CLOCK'S OWN ARITHMETIC: what is a date, what is a time, and which
#      field of an instant a flag replaces.
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

	# **AND A FLAG REPLACES ITS OWN FIELD WHICHEVER WAY IT MOVES IT.**  The
	# last two of these go BACKWARDS --- an earlier date on a later clock and
	# an earlier time of day on the same day --- because nothing here weighs
	# what a flag asks for against what the clock already holds.  A version
	# that dropped a flag pointing at an earlier instant would pass a list of
	# forward moves and nothing else.
	case_head "a flag moves its own field of the clock and leaves the other"
	for triple in \
		"19700101000005 with_date 20260920 20260920000005" \
		"19700101000005 with_time 1438 19700101143800" \
		"19700101000005 with_time 143805 19700101143805" \
		"20260920143805 with_date 20261231 20261231143805" \
		"20260920143805 with_time 0000 20260920000000" \
		"20260920143805 with_date 20260101 20260101143805" \
		"20260920143805 with_time 0900 20260920090000" \
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

	# **AND NOTHING HERE COMPARES TWO INSTANTS.**  A `cadr_clock_later` once
	# stood in this file, with a case of its own aimed at it, while the card's
	# lines were a floor that a later saved clock could overrule.  They are not
	# a floor now: a flag overrides the field it names whatever was restored.
	# The function went with the rule and this case went with the function,
	# because a case aimed at something nobody calls passes for ever and holds
	# nothing.  What replaces it is in section 5b, where a card's line is
	# required to land beside a saved clock that is later than it.
	case_head "the clock's shell keeps no comparison between two instants"
	if grep -q 'cadr_clock_later' "$CLOCKSH"; then
		fail "$CLOCKSH still names cadr_clock_later, and the rule it served is gone"
	else
		ok "cadr_clock_later is gone from $CLOCKSH"
	fi
	if grep -q 'cadr_clock_later' "$PKG/cadr-disk-packs/S80cadr-disk-packs"; then
		fail "S80cadr-disk-packs still calls cadr_clock_later: a flag is being weighed"
		fail "against the saved clock instead of setting the field it names"
	else
		ok "and S80cadr-disk-packs calls no such thing"
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
RC="$WORK/card/fpgarc"
printf '%s\r\n' \
	'# one file for the whole station' \
	'--chaos-address 3050' \
	'--chaos-udp 0.0.0.0:42042' \
	'--chaos-udp-peer 3060@a-host.invalid:42043' \
	'--keyboard-mapping /mnt/card/keys.txt' \
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
# Chaosnet program's once: it named a time host that lived inside it.  It now
# names the time of day on the card, and one name means one thing here, so the
# Chaosnet program no longer knows the word at all --- neither claiming it nor
# refusing it by name.  That makes the absence below matter more, not less: if
# the word were ever added to that program's list, the card's clock line would
# be handed to a program that does not know it, and it would exit at argument
# parsing, which is the whole Chaosnet gone on a boot that printed OK.
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
	passes "--keyboard-mapping /mnt/card/keys.txt" "cadr-terminal"
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
	# **AND IT DOES NOT WAIT, BECAUSE THERE IS NOTHING TO WAIT FOR.**  The
	# defaults are the switches and the cable and no peer at all, so no
	# name is resolved and the wait can buy nothing.  This used to assert
	# the opposite, on a board that then spent the whole bound at every
	# boot on a network it had nobody to reach.
	if [ -s "$WORK/ip.calls" ]; then
		fail "a board with no card and no peer waited for a network"
	else
		ok "and it does not wait: there is no peer, so there is no name"
	fi
fi

# The keyboard mapping is the same shape one step along: the file beside the
# card's is the screen's other default, and a card that names the flag used to
# get both of those too.
case_head "the card's flag wins over the mapping file found beside it, and is the only one passed"
sandbox
if prepare cadr-terminal S85cadr-terminal; then
	printf 'key 0 0\n' > "$WORK/card/terminal.keyboard.mapping.txt"
	printf '%s\r\n' '--keyboard-mapping /mnt/card/from-the-card.txt' > "$RC"
	run_script S85cadr-terminal
	passes_once "--keyboard-mapping" "cadr-terminal" "/mnt/card/from-the-card.txt"
	passes_not "$WORK/card/terminal.keyboard.mapping.txt" "cadr-terminal"
fi

case_head "and the mapping file beside it is passed once when the card says nothing"
sandbox
if prepare cadr-terminal S85cadr-terminal; then
	printf 'key 0 0\n' > "$WORK/card/terminal.keyboard.mapping.txt"
	printf '%s\r\n' '--bow' > "$RC"
	run_script S85cadr-terminal
	passes_once "--keyboard-mapping" "cadr-terminal" \
	            "$WORK/card/terminal.keyboard.mapping.txt"
fi

case_head "and no mapping flag at all when there is neither"
sandbox
if prepare cadr-terminal S85cadr-terminal; then
	rm -f "$WORK/card/terminal.keyboard.mapping.txt"
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
	printf '%s\r\n' "$3" ${5:+"$5"} > "$WORK/card/fpgarc"
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
printf '%s\r\n' '--chaos-address 3050' > "$WORK/card/fpgarc"
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
printf '%s\r\n' '--bow' > "$WORK/card/fpgarc"
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
	'--not-anybodys-flag 7' > "$WORK/card/fpgarc"
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
	'--date 20260920' '--time 1438' > "$WORK/card/fpgarc"
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
	'--chaos-file-root /mnt/card/file-root' > "$WORK/card/fpgarc"
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
	printf '%s\r\n' '--chaos-address 3050' '--no-auto-boot' > "$WORK/card/fpgarc"
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
	printf '%s\r\n' '--chaos-address 3050' > "$WORK/card/fpgarc"
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
	rm -f "$WORK/card/fpgarc"
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
	printf '%s\r\n' '--chaos-address 3050' > "$WORK/card/fpgarc"
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
	printf '%s\r\n' '--no-auto-boot' > "$WORK/card/fpgarc"
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
	printf '%s\r\n' '--debug-cable-wiring auto' > "$WORK/card/fpgarc"
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
	printf '%s\r\n' '--chaos-address 3050' > "$WORK/card/fpgarc"
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
	printf '%s\r\n' '--chaos-address 3050' '--no-blinking-leds' > "$WORK/card/fpgarc"
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
	printf '%s\r\n' '--chaos-address 3050' > "$WORK/card/fpgarc"
	run_script S80cadr-disk-packs
	if grep -q "blinking-leds" "$WORK/console.calls"; then
		fail "the console was asked about the lamps by a card that says nothing: $(cat "$WORK/console.calls")"
	else
		ok "the console was not asked about the lamps"
	fi
	printf '%s\r\n' '--no-blinking-leds' > "$WORK/card/fpgarc"
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
	printf '%s\r\n' '--chaos-address 3050' '--hdmi-sleep 120' > "$WORK/card/fpgarc"
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
	printf '%s\r\n' '--chaos-address 3050' '--hdmi-output tv' > "$WORK/card/fpgarc"
	run_script S80cadr-disk-packs
	if grep -q "hdmi-sleep" "$WORK/console.calls"; then
		fail "the console was asked about sleep by a card that says nothing: $(cat "$WORK/console.calls")"
	else
		ok "the console was not asked about sleep"
	fi
	printf '%s\r\n' '--hdmi-sleep 0' > "$WORK/card/fpgarc"
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
	printf '%s\r\n' '--no-auto-boot' > "$WORK/card/fpgarc"
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
	printf '%s\r\n' '--chaos-address 3050' > "$WORK/card/fpgarc"
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
	printf '%s\r\n' '--no-auto-boot' > "$WORK/card/fpgarc"
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
# 5b. THE CLOCK: --date AND --time SET IT BEFORE ANYTHING ELSE STARTS, AND EACH
#     SETS ONLY THE FIELD IT NAMES.
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
# anything else starts.
#
# **EACH LINE SETS ONLY THE FIELD IT NAMES, AND NOTHING IS INFERRED.**  A lone
# `--time` sets the time of day and leaves the date exactly as it stands.  It
# is not that time today, because this board has no today and a date it
# invented would mean nothing.  A lone `--date` sets the date and leaves the
# time of day.
#
# **AND THE CLOCK IS SAVED AT A CLEAN SHUTDOWN AND RESTORED AT THE NEXT BOOT,
# which is what gives the board a date for a lone `--time` to leave alone.**
# The restore is first and the card's lines are set on top of it.  The two are
# never compared.
#
# **THE COMPARISON THAT WENT IS THE THING THIS SECTION MOST HAS TO CATCH.**
# The step once took the later of the restored clock and what the card's lines
# composed, so a line naming an earlier instant was dropped and the boot log
# said so.  That is a card that says one thing and a board that does another,
# and it is invisible from anywhere but the console.  Every case below that
# names a saved clock therefore names one LATER than the line it is booted
# with, so a step that weighed the two fails it, and the sentence the old step
# printed is asserted absent by name.

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

# **AND THE TWO FIELDS SEPARATELY, because a lone flag is about the field it
# does NOT name.**  `clock_set_once` compares the whole instant and says
# "set to X and not Y" for every way of being wrong at once.  These two say
# which half moved, which is the sentence somebody reading a failure needs when
# the rule under test is that the other half stood still.
clock_date_told() { clock_told | cut -d' ' -f1; }
clock_time_told() { clock_told | cut -d' ' -f2; }

clock_date_unmoved() {
	if [ "$(clock_date_told)" = "$1" ]; then
		ok "and the date is still $1, which no line on the card named"
	else
		fail "the date moved to [$(clock_date_told)] and $1 is where it stood;" \
		     "no line on the card named a date"
	fi
}

clock_time_unmoved() {
	if [ "$(clock_time_told)" = "$1" ]; then
		ok "and the time of day is still $1, which no line on the card named"
	else
		fail "the time of day moved to [$(clock_time_told)] and $1 is where it" \
		     "stood; no line on the card named a time"
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
		> "$WORK/card/fpgarc"
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
	if [ -f "$WORK/card/clock" ]; then
		fail "a start wrote the saved clock, and only a clean shutdown may"
	else
		ok "and nothing was saved at start"
	fi
fi

case_head "--date alone sets the date and leaves the time of day"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	printf '%s\r\n' '--date 20260920' > "$WORK/card/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-20 00:00:05"
	says "--date 20260920"
	says_not "--time"
fi

case_head "--time alone sets the time of day and leaves the date"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	printf '%s\r\n' '--time 1438' > "$WORK/card/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "1970-01-01 14:38:00"
	says "--time 1438"
	says_not "--date"
fi

case_head "--time takes the second when the card gives one"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	printf '%s\r\n' '--date 20260920' '--time 143805' > "$WORK/card/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-20 14:38:05"
fi

case_head "a card that says nothing leaves the clock alone and says nothing"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	printf '%s\r\n' '--chaos-address 3050' > "$WORK/card/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_never "the clock was not set"
	says_not "cadr-clock"
	if [ -s "$WORK/daemon.calls" ]; then
		ok "and the pack program was started"
	else
		fail "the pack program was not started"
	fi
fi

# **A LINE ON THE CARD LANDS WHATEVER THE SAVED CLOCK SAYS, and this pair is
# what says so.**  The same card is booted twice: once beside a saved clock
# LATER than what its lines name and once beside one EARLIER, and the outcome
# is the same both times, which is the whole of the rule.  The step that came
# before took the later of the two, so the first of these two cases is exactly
# the one it fails.  A single case with the saved clock earlier would pass both
# designs and say nothing.
case_head "a saved clock later than the card's lines does not drop them"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	echo 20260920140000 > "$WORK/card/clock"
	printf '%s\r\n' '--date 20260919' '--time 1200' > "$WORK/card/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-19 12:00:00"
	says "cadr-clock: the clock is 2026-09-19 12:00:00 UTC, --date 20260919 and --time 1200"
	says "on the clock restored from"
	# The sentence the old step printed when it dropped a line.  It is asserted
	# absent by name, because a board that silently ignores a setting somebody
	# wrote on the card is the failure this file of flags exists to prevent,
	# and a step that has gone back to weighing the two would print it.
	says_not "is not later than"
fi

case_head "and a saved clock earlier than them lands them the same way"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	echo 20260918000000 > "$WORK/card/clock"
	printf '%s\r\n' '--date 20260919' '--time 1200' > "$WORK/card/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-19 12:00:00"
	says "--date 20260919 and --time 1200"
	says_not "is not later than"
fi

# **AND A LINE THAT STANDS ALONE SETS ITS OWN FIELD ON THE CLOCK AS IT NOW
# STANDS, which is the restored one.**  `--time 1500` on a board that was
# halted at two in the afternoon is three in the afternoon of the same day, and
# not three in the afternoon of the 1st of January 1970 --- which is what
# setting it on the clock the board came up with would give.  That is the whole
# of what "sets only its own field, leaving the other as it is" means, and this
# is the case that says which of the two readings the step has.
case_head "a lone --time moves the restored clock and does not start again from the epoch"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	echo 20260920140000 > "$WORK/card/clock"
	printf '%s\r\n' '--time 1500' > "$WORK/card/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-20 15:00:00"
	clock_date_unmoved "2026-09-20"
	says "on the clock restored from"
fi

# **AND IT LEAVES THE DATE ALONE WHEN THE TIME IT NAMES IS EARLIER THAN THE
# SAVED CLOCK, which is the case the rule is really about.**  The one above
# moves the clock forward, so a step that weighed the line against the saved
# clock would pass it.  This one moves it back by five hours on the same day.
# The line is what the operator asked for and it lands; the date it did not
# name does not move, because this board has no today to put the time on and a
# date it invented would be a day nobody meant.
case_head "a lone --time earlier than the saved clock still lands, and the date does not move"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	echo 20260918140000 > "$WORK/card/clock"
	printf '%s\r\n' '--time 0900' > "$WORK/card/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-18 09:00:00"
	clock_date_unmoved "2026-09-18"
	says "cadr-clock: the clock is 2026-09-18 09:00:00 UTC, --time 0900"
	says "on the clock restored from"
	says_not "is not later than"
	says_not "--date"
fi

# And the same thing the other way up: a lone `--date` earlier than the saved
# clock lands, and the time of day it did not name stays where it stood, down
# to the second.
case_head "a lone --date earlier than the saved clock still lands, and the time of day does not move"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	echo 20260920143805 > "$WORK/card/clock"
	printf '%s\r\n' '--date 20260101' > "$WORK/card/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-01-01 14:38:05"
	clock_time_unmoved "14:38:05"
	says "cadr-clock: the clock is 2026-01-01 14:38:05 UTC, --date 20260101"
	says_not "is not later than"
fi

# **AND ONE SECOND EITHER SIDE OF THE SAVED CLOCK**, which is the mutation just
# outside the bound: a step that took the later of the two, or that took the
# card's lines only when they moved the clock forward, passes the first of
# these and fails the second by one second.
case_head "one second either side of the saved clock is set exactly as the card names it"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	echo 20260920143800 > "$WORK/card/clock"
	printf '%s\r\n' '--date 20260920' '--time 143801' > "$WORK/card/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-20 14:38:01"
fi
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	echo 20260920143800 > "$WORK/card/clock"
	printf '%s\r\n' '--date 20260920' '--time 143759' > "$WORK/card/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-20 14:37:59"
	says_not "is not later than"
fi

case_head "a saved clock and no lines at all is restored on its own"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	echo 20260920140000 > "$WORK/card/clock"
	printf '%s\r\n' '--chaos-address 3050' > "$WORK/card/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-20 14:00:00"
	clock_set_first
	says "restored from"
fi

# **AND THE RESTORE ITSELF IS NOT WEIGHED EITHER.**  A condition on the restore
# would be the same comparison in the other half of the step, so the saved
# clock is put on whatever the board came up with, whichever is later.  On a
# real board the question does not arise --- `date` reads the epoch and the
# saved clock is always later --- and that is exactly why a step that weighed
# them would look like one that works.
case_head "a saved clock earlier than the clock the board came up with is still restored"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 20260921000000 > "$WORK/now"
	echo 20260920140000 > "$WORK/card/clock"
	printf '%s\r\n' '--chaos-address 3050' > "$WORK/card/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-20 14:00:00"
	says "restored from"
fi

case_head "and a saved clock with no fpgarc beside it is restored too"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	rm -f "$WORK/card/fpgarc"
	echo 20260920140000 > "$WORK/card/clock"
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
	printf '  20260920140000  \r\n' > "$WORK/card/clock"
	rm -f "$WORK/card/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-20 14:00:00"
fi
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	printf '2026 0920140000\n' > "$WORK/card/clock"
	rm -f "$WORK/card/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_never "a saved clock with a space in the middle was not used"
	says "cadr-clock: the clock saved in"
fi

case_head "a saved clock that is not fourteen digits is named and not used"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	echo "hello" > "$WORK/card/clock"
	printf '%s\r\n' '--date 20260920' '--time 1438' > "$WORK/card/fpgarc"
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
	printf '%s\r\n' '--date 20261301' '--time 1438' > "$WORK/card/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "1970-01-01 14:38:00"
	says "cadr-clock: --date 20261301 is not a date"
	says "yyyyMMdd"
fi

case_head "a --time that is not a time is named, and --date still lands"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	printf '%s\r\n' '--date 20260920' '--time 2400' > "$WORK/card/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-20 00:00:05"
	says "cadr-clock: --time 2400 is not a time"
	says "HHmm"
fi

case_head "a line with nothing after it is named, and the clock is not set"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	printf '%s\r\n' '--date' > "$WORK/card/fpgarc"
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
	printf '%s\r\n' '   --date   20260920   ' '  --time  1438  ' > "$WORK/card/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_once "2026-09-20 14:38:00"
fi
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	printf '%s\r\n' '--date 2026 0920' > "$WORK/card/fpgarc"
	run_script S80cadr-disk-packs
	clock_set_never "a date with a space in it did not reach the clock"
	says "cadr-clock: --date 2026 0920 is not a date"
fi

case_head "a board whose clock does not read as an instant is said, and nothing is set"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo "not-a-clock" > "$WORK/now"
	printf '%s\r\n' '--date 20260920' '--time 1438' > "$WORK/card/fpgarc"
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
	printf '%s\r\n' '--date 20260920' '--time 1438' > "$WORK/card/fpgarc"
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
	: > "$WORK/mounted"
	printf '%s\r\n' '--chaos-address 3050' > "$WORK/card/fpgarc"
	PATH="$WORK/bin:$PATH" "$WORK/S80cadr-disk-packs" stop > "$WORK/out.stop" 2>&1
	if [ "$(cat "$WORK/card/clock" 2>/dev/null)" = 20260920143805 ]; then
		ok "the clock was saved as fourteen digits"
	else
		fail "the saved clock is [$(cat "$WORK/card/clock" 2>/dev/null)], not 20260920143805"
	fi
	if grep -q "cadr-clock: 2026-09-20 14:38:05 UTC saved" "$WORK/out.stop"; then
		ok "and the console says so"
	else
		fail "the console does not say the clock was saved; it says:"
		sed 's/^/        /' "$WORK/out.stop"
	fi
	if grep -q "^the clock was saved before $WORK/card was unmounted\$" "$WORK/umount.calls"; then
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
	: > "$WORK/mounted"
	printf '%s\r\n' '--chaos-address 3050' > "$WORK/card/fpgarc"
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

# **STOP WAITS FOR THE PROGRAM.**  `start-stop-daemon -K` sends SIGTERM and
# returns at once, and cadr-disk-packs spends the time after SIGTERM writing
# the machine's dirty blocks back to its packs.  The script used to save the
# clock and unmount the card straight after `-K`, racing that write-back, and
# sent the unmount's refusal to /dev/null.  The stand-in here takes a second
# to go after SIGTERM, and the stubbed `umount` refuses, as the real one does,
# while it is still there.
case_head "stop waits for the pack program to finish before it saves the clock and unmounts"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 20260920143805 > "$WORK/now"
	: > "$WORK/mounted"
	SLOW=1 "$WORK/bin/slow-to-stop" &
	_slow=$!
	echo "$_slow" > "$WORK/run/cadr-disk-packs.pid"
	sleep 1
	PATH="$WORK/bin:$PATH" "$WORK/S80cadr-disk-packs" stop > "$WORK/out.stop" 2>&1
	if kill -0 "$_slow" 2>/dev/null; then
		fail "the pack program was still running when stop returned"
		kill -9 "$_slow" 2>/dev/null
	else
		ok "the pack program had exited when stop returned"
	fi
	if grep -q "^the clock was saved before $WORK/card was unmounted\$" "$WORK/umount.calls" \
	   && ! grep -q "still running" "$WORK/umount.calls"; then
		ok "and the card was unmounted after it, with the clock saved first"
	else
		fail "the card was not unmounted after the program had gone: $(cat "$WORK/umount.calls")"
	fi
	if grep -q "Stopping cadr-disk-packs: OK" "$WORK/out.stop" \
	   && ! grep -q "NOT UNMOUNTED" "$WORK/out.stop"; then
		ok "and the console says OK and nothing else went wrong"
	else
		fail "the console does not say a clean stop; it says:"
		sed 's/^/        /' "$WORK/out.stop"
	fi
fi

# And the other side: a program that does not go.  It is said by name and
# left running, because a kill would lose the blocks it is writing; the clock
# is saved anyway; and the unmount that then fails is said, where it was
# once hidden.
says_stop() {
	if grep -qF -- "$1" "$WORK/out.stop"; then
		ok "the console says: $1"
	else
		fail "the console does not say [$1]; it says:"
		sed 's/^/        /' "$WORK/out.stop"
	fi
}
case_head "a pack program that will not stop is said, and so is the unmount that fails"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 20260920143805 > "$WORK/now"
	: > "$WORK/mounted"
	DEAF=yes "$WORK/bin/slow-to-stop" &
	_deaf=$!
	echo "$_deaf" > "$WORK/run/cadr-disk-packs.pid"
	sleep 1
	PATH="$WORK/bin:$PATH" "$WORK/S80cadr-disk-packs" stop > "$WORK/out.stop" 2>&1
	echo "$?" > "$WORK/status.stop"
	kill -9 "$_deaf" 2>/dev/null
	says_stop "Stopping cadr-disk-packs: FAIL"
	says_stop "cadr-disk-packs: still running 3 s after it was asked to stop (pid $_deaf); it was left running"
	says_stop "cadr-clock: 2026-09-20 14:38:05 UTC saved"
	says_stop "cadr-disk-packs: $WORK/card WAS NOT UNMOUNTED"
	says_stop "Device or resource busy"
	if [ "$(cat "$WORK/status.stop")" != 0 ]; then
		ok "and stop says so in its status"
	else
		fail "stop returned 0 with the card still mounted"
	fi
fi

# And a board with no card: nothing is mounted, so nothing is unmounted and
# nothing is said about it.
case_head "a board with no card mounted has nothing to unmount and says nothing about it"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	PATH="$WORK/bin:$PATH" "$WORK/S80cadr-disk-packs" stop > "$WORK/out.stop" 2>&1
	if [ -s "$WORK/umount.calls" ] || grep -q "UNMOUNTED" "$WORK/out.stop"; then
		fail "an unmounted card was unmounted or complained about: $(cat "$WORK/umount.calls")"
		sed 's/^/        /' "$WORK/out.stop"
	else
		ok "nothing was unmounted and nothing was said"
	fi
fi

# **EVERY OTHER SCRIPT WAITS TOO.**  ozd holds files open on the card that
# the disk pack script unmounts after it, and a `restart` that starts a program
# while the old one still holds its port starts nothing.  The shutdown runs
# the scripts in reverse order, so each program must be gone by the time its
# script returns.
for pair in "ozd S84ozd" "cadr-terminal S85cadr-terminal" "cadr-serial S86cadr-serial" \
            "cadr-chaosnet S87cadr-chaosnet" "cadr-usb-input S88cadr-usb-input"; do
	set -- $pair
	case_head "$2 stop waits for $1 to exit"
	sandbox
	if prepare "$1" "$2"; then
		SLOW=1 "$WORK/bin/slow-to-stop" &
		_slow=$!
		echo "$_slow" > "$WORK/run/$1.pid"
		sleep 1
		PATH="$WORK/bin:$PATH" "$WORK/$2" stop > "$WORK/out.stop" 2>&1
		if kill -0 "$_slow" 2>/dev/null; then
			fail "$1 was still running when $2 stop returned"
			kill -9 "$_slow" 2>/dev/null
		else
			ok "$1 had exited when $2 stop returned"
		fi
		if grep -q "Stopping $1: OK" "$WORK/out.stop"; then
			ok "and the console says OK"
		else
			fail "the console does not say Stopping $1: OK; it says:"
			sed 's/^/        /' "$WORK/out.stop"
		fi
	fi
done

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
	mkdir -p "$WORK/gen/card"
	lift_board_facts "$WORK/gen/board.sh" || return 1
	awk '/^CHAOS_ADDR=\$\{CHAOS_ADDR_FPGA/ {on=1}
	     on {print}
	     /^\} > "\$OUT\/card\/fpgarc"$/ {if (on) exit}' "$MKSD" > "$WORK/gen/gen.sh"
	if [ ! -s "$WORK/gen/gen.sh" ]; then
		fail "the fpgarc generator is not where this check looks in mksd-buildroot.sh"
		return 1
	fi
	if [ "$(grep -c '^} > "\$OUT/card/fpgarc"$' "$WORK/gen/gen.sh")" != "1" ]; then
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
	  # $5 is CHAOS_PEER, which local.conf sets on a card whose band has a
	  # file host on a real network.  It is empty everywhere but in the
	  # case that asserts what such a card does about the host on the
	  # board, because those two things are one decision.
	  CHAOS_PEER=${5:-}
	  # $6 is SYS and $7 SITE, the band's two trees staged onto the card.
	  # The menu names each tree exactly when the card carries it, because
	  # a line naming a tree that is not there stops the host, and they are
	  # two flags because a card may carry one and not the other.
	  SYS=${6:-}
	  SITE=${7:-}
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
# Three flags are repeatable by their own definition --- a peer entry places
# ONE address, a named device is ONE device, and a root names ONE tree --- so
# those may appear more than once.  Everything else must appear exactly once,
# which is what catches a flag written into the file twice under two different
# explanations.
flag_requirements() {
	for _f in cadr-chaosnet/S87cadr-chaosnet cadr-terminal/S85cadr-terminal \
	          cadr-serial/S86cadr-serial cadr-usb-input/S88cadr-usb-input \
	          ozd/S84ozd; do
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
	GEN="$WORK/gen/card/fpgarc"
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
		*--chaos-udp-peer*|*--usb-device*|*--ozd-root*)
			# Repeatable: a peer entry places one address, a named
			# device is one device, and a root names one tree ---
			# the card carries two, `sys` and `site`.
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
	if grep -q '^#--no-auto-boot' "$WORK/gen/card/fpgarc"; then
		ok "the line is there and commented out"
	else
		fail "there is no commented --no-auto-boot line in what the card script wrote"
	fi
	if grep -q '^--no-auto-boot' "$WORK/gen/card/fpgarc"; then
		fail "and it is also live, which it must not be"
	else
		ok "and it is not live"
	fi
	if grep -q 'the machine is held at boot' "$WORK/gen/card/fpgarc"; then
		ok "and the sentence explaining it is beside it"
	else
		fail "the line has no sentence explaining it"
	fi
	# The reader must agree with the card script about what a comment is.
	if [ "$HAVE_READER" != yes ]; then
		fail "there is no reader to agree with the card script"
	elif fpgarc_has "$WORK/gen/card/fpgarc" --no-auto-boot; then
		fail "the reader takes the commented line as a flag"
	else
		ok "and the reader does not take it as a flag"
	fi
fi

case_head "NO_AUTO_BOOT=1 makes the same line live"
sandbox
if generate_fpgarc "1"; then
	if grep -q '^--no-auto-boot' "$WORK/gen/card/fpgarc"; then
		ok "the line is live"
	else
		fail "the --no-auto-boot line is not live in what the card script wrote"
	fi
	if grep -q 'the machine is held at boot' "$WORK/gen/card/fpgarc"; then
		ok "and the same sentence is beside it"
	else
		fail "the live line has no sentence explaining it"
	fi
	if [ "$HAVE_READER" != yes ]; then
		fail "there is no reader to find the live line"
	elif fpgarc_has "$WORK/gen/card/fpgarc" --no-auto-boot; then
		ok "and the reader finds it"
	else
		fail "the reader does not find the live line"
	fi
	# Carriage returns: the card is FAT32 and the file is written CRLF, so
	# a reader that did not strip them would hand the shell a flag with a
	# carriage return on it and nothing would match.
	if grep -q "$(printf '\r')$" "$WORK/gen/card/fpgarc"; then
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
	GEN="$WORK/gen/card/fpgarc"
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
	GEN="$WORK/gen/card/fpgarc"
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
	GEN="$WORK/gen/card/fpgarc"
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
		GEN="$WORK/gen/card/fpgarc"
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
case_head "a released card's menu has four live lines and they are the four a board needs"
sandbox
if generate_fpgarc "" 1; then
	GEN="$WORK/gen/card/fpgarc"
	got=$(live_flags "$GEN" | tr '\n' '|')
	want='--chaos-address 177101|--chaos-udp 127.0.0.1:42042|--terminal 0.0.0.0:5900|--keyboard-boot ctrl,meta|'
	if [ "$got" = "$want" ]; then
		ok "the switches, the cable on the loopback, the screen and the boot chord, and nothing else"
	else
		fail "the released menu's live lines are [$got], not [$want]"
	fi
fi

case_head "and the serial line is on it, commented out"
sandbox
if generate_fpgarc "" 1; then
	GEN="$WORK/gen/card/fpgarc"
	for f in --serial; do
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
		for f in --chaos-address --chaos-udp --terminal --keyboard-boot; do
			fpgarc_has "$GEN" "$f" && ok "the reader finds $f" ||
				fail "the reader does not find $f live"
		done
		for f in --serial; do
			fpgarc_has "$GEN" "$f" &&
				fail "the reader takes the commented $f as a flag" ||
				ok "and the reader does not find $f"
		done
	fi
fi

case_head "and it is still the whole menu: every flag every program takes is on it"
sandbox
if generate_fpgarc "" 1; then
	GEN="$WORK/gen/card/fpgarc"
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
	GEN="$WORK/gen/card/fpgarc"
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
case_head "a board given the released menu has its switches set and its cable on the loopback"
sandbox
if generate_fpgarc "" 1 && prepare cadr-chaosnet S87cadr-chaosnet; then
	cp "$WORK/gen/card/fpgarc" "$WORK/card/fpgarc"
	run_script S87cadr-chaosnet
	passes_once "--chaos-address" "cadr-chaosnet" "177101"
	# **THE CABLE IS PLUGGED INTO THE BOARD AND INTO NO NETWORK.**  That is
	# what changed when the board gained a file and time host of its own: a
	# board out of the box is a whole site, and it cannot be one with its
	# cable unplugged.  0.0.0.0 here would be a station on a network the
	# user has not got, which is what kept the line off this menu before.
	passes_once "--chaos-udp" "cadr-chaosnet" "127.0.0.1:42042"
	if grep -q 'the cable is not plugged in' "$WORK/out.S87cadr-chaosnet"; then
		fail "the console says the cable is not plugged in, and the released menu plugs it in"
	else
		ok "and the console does not say the cable is unplugged"
	fi
fi

case_head "and its serial line is off, and its screen is served"
sandbox
if generate_fpgarc "" 1 && prepare cadr-serial S86cadr-serial; then
	cp "$WORK/gen/card/fpgarc" "$WORK/card/fpgarc"
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
	cp "$WORK/gen/card/fpgarc" "$WORK/card/fpgarc"
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
# because the rest of that script wants a bitstream and a Buildroot output
# tree.  The card's LAYOUT has exactly the same shape: small blocks of the
# script that can be run alone against fabricated files, and no board.  What a
# staging run proves on top of this is that the real images and the real
# bitstream went where the block says they go.
#
# **THE PROPERTY.**  The loader's files stay at the root of the card because
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

# **AND THE CARD SAYS WHETHER THE FABRIC WAS CONFIGURED BEFORE U-BOOT RAN.**
# A board configured over JTAG has its fabric in place before the processor's
# loader runs, and the loader may not configure it again; the card's uEnv.txt
# is where it is told so.  The line decides which branch of the loader runs,
# and the branch that loads the fabric is the one that fetches its image, so
# this is also what lets a card with an empty fabric slot boot such a board
# instead of looping on a file it will never use.  Both halves are asserted,
# because a script that wrote the line live always would pass the first.
#
# The block is lifted out of the card script on its own anchors and run
# against each board's REAL template, so a template that stops carrying the
# line fails here by name rather than on a board.
uenv_out() {
	rm -rf "$WORK/uenv/out"; mkdir -p "$WORK/uenv/out/card"
	( set -eu
	  OUT="$WORK/uenv/out"
	  BOARD="$TREE/boards/$1/linux/buildroot/board/$1"
	  BOARD_NAME=$1
	  FABRIC=$2
	  SERVERIP=; ETHADDR=
	  FABRIC_LOADED=$3
	  die() { echo "$*" > "$WORK/uenv/died"; exit 1; }
	  . "$WORK/uenv/uenv.sh" ) > "$WORK/uenv/said" 2>&1
}
case_head "the card says the fabric was configured before U-Boot ran exactly when it is asked to"
sandbox
mkdir -p "$WORK/uenv"
if lift 'sed -e "s/@SERVERIP@/${SERVERIP:-}/"' \
        '# whether the card says the fabric was configured before U-Boot ran' \
        "$WORK/uenv/uenv.sh"; then
	rm -f "$WORK/uenv/died"
	if ! uenv_out de25-nano cadr.core.rbf 1; then
		fail "the DE25-Nano's uEnv.txt was not written with FABRIC_LOADED=1: $(cat "$WORK/uenv/died" "$WORK/uenv/said" 2>/dev/null)"
	elif grep -qx 'cadr_fabric_loaded=1' "$WORK/uenv/out/card/uEnv.txt"; then
		ok "FABRIC_LOADED=1 writes the line live, so the loader opens the bridges and reads no image"
	else
		fail "FABRIC_LOADED=1 left the line commented, so the board would try to configure a fabric it has"
	fi
	# **THE CONTROL.**  Without it the line must still be there and still be
	# commented out: the card is a menu, and a board that boots from its own
	# flash configures its own fabric.
	rm -f "$WORK/uenv/died"
	if ! uenv_out de25-nano cadr.core.rbf ""; then
		fail "the DE25-Nano's uEnv.txt was not written without FABRIC_LOADED: $(cat "$WORK/uenv/died" "$WORK/uenv/said" 2>/dev/null)"
	elif grep -qx '#cadr_fabric_loaded=1' "$WORK/uenv/out/card/uEnv.txt"; then
		ok "and a card that does not ask keeps the line commented, one character from being on"
	else
		fail "a card that did not ask for it does not carry the line commented out"
	fi
	# **AND A BOARD WHOSE LOADER HAS NO SUCH SETTING REFUSES IT BY NAME**,
	# rather than staging a card that says nothing and looks as though it
	# said something.  The Zynq boards' template has no such line.
	rm -f "$WORK/uenv/died"
	if uenv_out arty-z7-20 cadr.bit 1; then
		fail "FABRIC_LOADED=1 was accepted for a board whose loader has no such setting"
	elif grep -q 'cadr_fabric_loaded=1' "$WORK/uenv/died" 2>/dev/null; then
		ok "and a board whose loader has no such setting refuses it by name"
	else
		fail "the refusal does not name the setting: $(cat "$WORK/uenv/died" "$WORK/uenv/said" 2>/dev/null)"
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
	# **AND THE SAME QUESTION OF A LOADER WHOSE cadr_card DOES NOT FETCH THE
	# FABRIC'S IMAGE AT ALL.**  The DE25-Nano's does not: one of its two
	# arrangements may not configure its own fabric and must not so much as
	# ask for the file, so the fetch is `cadr_rbf_card`, run by `cadr_fabric`
	# only on the path that loads.  The staging asked `cadr_card` for all
	# four files and so refused every loader built after that change ---
	# measured, on the real u-boot.itb, which is how this case came to be
	# here.  What is held is the FOLDER, wherever the fetch lives.
	de25_loader() {
		printf 'bootcmd=run cadr_boot\n' > "$1"
		printf 'cadr_card=setenv cadr_rbf_get cadr_rbf_card; run cadr_fabric && load mmc 0:1 ${b} de25-nano/socfpga_agilex5_de25_nano_cadr.dtb && load mmc 0:1 ${c} de25-nano/Image && load mmc 0:1 ${d} de25-nano/rootfs.cpio.uboot && run cadr_booti\n' >> "$1"
		printf 'cadr_rbf_card=load mmc 0:1 ${a} %s\n' "$2" >> "$1"
		printf 'cadr_rbf_net=tftpboot ${a} %s\n' "$2" >> "$1"
		printf 'cadr_net=dhcp && tftpboot ${a} de25-nano/uEnv.net && run netcmd\n' >> "$1"
		printf 'cadr_booti=booti ${c} ${d} ${b}\n' >> "$1"
	}
	run_refusal_de25() {
		cp "$1" "$WORK/ub/card/u-boot.itb"
		( set -eu
		  OUT="$WORK/ub"
		  BOARD_NAME=de25-nano
		  BOARD_DTB=socfpga_agilex5_de25_nano_cadr.dtb
		  . "$WORK/ub/board.sh"
		  die() { echo "mksd-buildroot: $*" >&2; exit 1; }
		  . "$WORK/ub/refuse.sh" ) 2>"$WORK/ub/err"
	}
	de25_loader "$WORK/ub/de25-new.itb" de25-nano/cadr.core.rbf
	de25_loader "$WORK/ub/de25-old.itb" cadr.core.rbf
	if run_refusal_de25 "$WORK/ub/de25-new.itb"; then
		ok "a DE25-Nano loader whose cadr_rbf_card loads de25-nano/cadr.core.rbf is accepted"
	else
		fail "the staging refuses a DE25-Nano loader that IS right: $(cat "$WORK/ub/err")"
	fi
	# **AND THE BLOCK BEFORE IT, WHICH ASKS THE ENVIRONMENT FOR THE CARD
	# PATH BY NAME.**  It is a separate lift because it is a separate block,
	# and it is the one that refused the real u-boot.itb first: it wanted
	# `cadr_card=load mmc 0:1`, which is not how the DE25-Nano's card path
	# begins now that the fabric's image is fetched somewhere else.
	if lift 'for var in "bootcmd=run cadr_boot"' 'done' "$WORK/ub/vars.sh"; then
		run_vars() {
			cp "$2" "$WORK/ub/card/$3"
			( set -eu
			  OUT="$WORK/ub"
			  BOARD_NAME=$1
			  BOARD_DTB=x.dtb
			  . "$WORK/ub/board.sh"
			  die() { echo "mksd-buildroot: $*" >&2; exit 1; }
			  . "$WORK/ub/vars.sh" ) 2>"$WORK/ub/err"
		}
		printf 'bootcmd=run cadr_boot\ncadr_card=load mmc 0:1 ${a} arty-z7-20/cadr.bit\ncadr_net=x\ncadr_bootz=y\n' \
			> "$WORK/ub/vars-arty.img"
		if run_vars arty-z7-20 "$WORK/ub/vars-arty.img" u-boot.img; then
			ok "and the Zynq boards' environment is asked for cadr_card=load mmc 0:1, as it always was"
		else
			fail "the staging refuses a Zynq environment that IS right: $(cat "$WORK/ub/err")"
		fi
		if run_vars de25-nano "$WORK/ub/de25-new.itb" u-boot.itb; then
			ok "and the DE25-Nano's is asked for cadr_rbf_card=load mmc 0:1 instead"
		else
			fail "the staging refuses the DE25-Nano's environment: $(cat "$WORK/ub/err")"
		fi
		# The control: an environment with no card path at all must still
		# be refused, or the two above would pass on a check that asks
		# nothing.
		printf 'bootcmd=run cadr_boot\ncadr_net=x\ncadr_booti=y\n' > "$WORK/ub/vars-none.itb"
		if run_vars de25-nano "$WORK/ub/vars-none.itb" u-boot.itb; then
			fail "an environment with no card path at all is accepted"
		else
			ok "and one with no card path at all is still refused"
		fi
	fi
	if run_refusal_de25 "$WORK/ub/de25-old.itb"; then
		fail "the staging accepts a DE25-Nano loader that fetches the fabric's image from the root of the partition"
	else
		ok "and one that fetches it from the root of the partition is refused"
		if grep -q 'cadr_rbf_card' "$WORK/ub/err"; then
			ok "and the refusal names the variable that fetches it"
		else
			fail "the refusal does not name the variable: $(cat "$WORK/ub/err")"
		fi
	fi
fi

case_head "every board's U-Boot loads its four files from its own folder"
sandbox
# A here-document and not a pipe: a `while` on the far end of a pipe runs in a
# subshell, and the failure count this check exits on would be incremented
# there and lost --- a case that prints FAIL and still leaves the run green.
# **AND THE LAST FIELD SAYS WHICH VARIABLE FETCHES THE FABRIC'S IMAGE**, which
# is not the same one on every board.  The Zynq boards' cadr_card loads all
# four files itself.  The DE25-Nano's does not: one of its two arrangements
# may not configure its own fabric and must not so much as ask for the image,
# so the fetch is a variable of its own that cadr_fabric runs on the path that
# loads.  What this case is about is the FOLDER --- a loader that looked for a
# board's file at the root of the partition would be handed another board's
# --- and that is asked of all four files wherever the fetch lives.
env_block() {
	awk -v v="$1" 'index($0, v "=") == 1 { inside = 1; print; next }
	               inside && (/^$/ || /^[^ \t=][^ =]*=/) { exit }
	               inside { print }' "$2"
}
while IFS= read -r spec; do
	# <environment>=<board>=<its tree>=<its fabric>=<its kernel>=<what fetches the fabric>
	IFS='=' read -r env_rel board dtb fabric kernel rbf_var <<EOF_SPEC
$spec
EOF_SPEC
	env_file="$TREE/$env_rel"
	if [ ! -f "$env_file" ]; then
		fail "no environment at $env_file: this check has rotted"
		continue
	fi
	block=$(env_block cadr_card "$env_file")
	rbf_block=$(env_block "$rbf_var" "$env_file")
	[ -n "$rbf_block" ] || fail "$(basename "$env_file") has no $rbf_var to fetch the fabric's image"
	bad=0
	# The file is at the end of its own line where the fetch is a variable of
	# one line, and is followed by ` &&` inside cadr_card, so either ends it.
	echo "$rbf_block" | grep -q "load mmc 0:1 [^ ]* $board/$fabric\\( \\|\$\\)" \
		|| { fail "$(basename "$env_file")'s $rbf_var does not load $board/$fabric"; bad=1; }
	for f in "$dtb" "$kernel" rootfs.cpio.uboot; do
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
boards/arty-z7-20/linux/buildroot/board/arty-z7-20/uboot/cadr.env=arty-z7-20=zynq-arty-z7-20.dtb=cadr.bit=zImage=cadr_card
boards/cora-z7-07s/linux/buildroot/board/cora-z7-07s/uboot/cadr_cora.env=cora-z7-07s=zynq-cora-z7-07s.dtb=cadr.bit=zImage=cadr_card
boards/de25-nano/linux/buildroot/board/de25-nano/uboot/cadr_de25.env=de25-nano=socfpga_agilex5_de25_nano_cadr.dtb=cadr.core.rbf=Image=cadr_rbf_card
ENVS

case_head "the DE25-Nano's menu is the Zynq boards' with the DE25-Nano's windows"
sandbox
# **ONE MENU FOR EVERY BOARD, AND THE ADDRESSES IN IT ARE THE BOARD'S.**  The
# file of flags is the machine's and not the part's, so the DE25-Nano's card
# must carry the same menu line for line --- and the two lines that name where
# the display's windows are must name the DE25-Nano's, 64 MB into ITS
# reservation, or a person uncommenting them would point the screen at the
# wrong memory.  Generated twice from the one block and compared.
if generate_fpgarc "" "" "" arty-z7-20 && cp "$WORK/gen/card/fpgarc" "$WORK/fpgarc.arty" \
   && generate_fpgarc "" "" "" de25-nano && cp "$WORK/gen/card/fpgarc" "$WORK/fpgarc.de25"; then
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
mkdir -p "$WORK/rel/card/packs" "$WORK/rel/card/sys" "$WORK/rel/card/site"
if lift 'addrs=$(grep -rEoh' '| sort -u || true)' "$WORK/rel/guard.sh" "$MKSDREL" \
   && generate_fpgarc ""; then
	cp "$WORK/gen/card/fpgarc" "$WORK/rel/card/fpgarc"
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
		ok "and a private address at the root of the card still stops the release"
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
	printf -- '--chaos-udp-peer 3060@0.0.0.1:42043\n' > "$WORK/rel/card/packs/near"
	got=$(run_guard)
	if echo "$got" | grep -q '0\.0\.0\.1'; then
		ok "and 0.0.0.1 is not 0.0.0.0"
	else
		fail "the guard exempts more than the exact strings it names"
	fi
	rm -f "$WORK/rel/card/packs/near"
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

# ---------------------------------------------------------------------------
# 8.  THE FILE AND TIME HOST ON THE BOARD.
#
# A CADR has no file or time server in it, so a board with no network had no
# file host and no time host at all: it booted, painted its window system, said
# its file host was not a known host, and did not know the date.  S84ozd starts
# one on the board, on unless the card says --no-ozd.
#
# What these cases hold is the join, which is where the whole thing can go
# wrong quietly.  The host's flags reach ozd in ozd's own spelling; the machine
# is told where the host is; and the ONE address the band calls is not placed
# twice, which the Chaosnet program refuses by name --- a refusal that would
# leave the board with no cable at all, on a boot that started a file host.
# ---------------------------------------------------------------------------

# What start-stop-daemon was given, as one line, for the ozd cases.  The words
# after `--` are the shell's, and ozd's own flags come after the program.
ozd_given() { cat "$WORK/daemon.calls"; }

case_head "the host is on with no card saying anything, and it is given ozd's own words"
sandbox
if prepare ozd S84ozd; then
	: > "$WORK/card/fpgarc"
	run_script S84ozd
	for want in "--address 177200" "--name OZ,system=UNIX" \
	            "--listen 127.0.0.1:42142"; do
		if ozd_given | grep -q -- "$want"; then
			ok "ozd was given $want"
		else
			fail "ozd was not given $want; it was given: $(ozd_given)"
		fi
	done
	# **AND A ROOT, BECAUSE ozd REFUSES TO START WITHOUT ONE.**  It is in
	# the root filesystem and it is empty, which is what makes the host free
	# to have on: a tree there would be about 16 MiB of every board's memory
	# whether anybody ever asked for a file or not.
	if ozd_given | grep -q -- "--root $WORK/ozdroot"; then
		ok "and the base root, which is where a user's own directory goes"
	else
		fail "ozd was given no base root; it was given: $(ozd_given)"
	fi
	if ozd_given | grep -q -- "--root sys="; then
		fail "ozd was given a tree nobody named; the default serves none"
	else
		ok "and no tree, which is the default and costs no memory"
	fi
fi

case_head "--no-ozd stops it, and nothing is left behind for the Chaosnet to find"
sandbox
if prepare ozd S84ozd; then
	printf -- '--no-ozd\r\n' > "$WORK/card/fpgarc"
	run_script S84ozd
	if [ -s "$WORK/daemon.calls" ]; then
		fail "ozd was started with --no-ozd on the card: $(ozd_given)"
	else
		ok "nothing was started"
	fi
	if [ -e "$WORK/run/cadr-ozd.peer" ]; then
		fail "a peer file was left behind by a host that is not running"
	else
		ok "and no peer file, so the Chaosnet adds no peer for it"
	fi
	if grep -q -- '--no-ozd on the card' "$WORK/out.S84ozd"; then
		ok "and the console says so"
	else
		fail "the console does not say the host was turned off"
	fi
fi

# **THE CONTROL FOR THE CASE ABOVE.**  An --ozd- setting beside --no-ozd is
# still CLAIMED, or the last script to read the file would report it at boot as
# a line no program takes --- which would be false: it reached this program,
# which had been told not to run.  An absence is also what a check looking at
# the wrong thing reports, so the same file is run past the reporter both ways.
case_head "a setting left beside --no-ozd is not reported as a line nobody took"
sandbox
if prepare ozd S84ozd && prepare cadr-usb-input S88cadr-usb-input; then
	printf -- '--no-ozd\r\n--ozd-port 42142\r\n' > "$WORK/card/fpgarc"
	: > "$WORK/run/claimed"
	FPGARC_CLAIMED="$WORK/run/claimed" PATH="$WORK/bin:$PATH" \
		"$WORK/S84ozd" start > "$WORK/out.S84ozd" 2>&1
	FPGARC_CLAIMED="$WORK/run/claimed" PATH="$WORK/bin:$PATH" \
		"$WORK/S88cadr-usb-input" start > "$WORK/out.S88cadr-usb-input" 2>&1
	if grep -q 'no program on this board takes' "$WORK/out.S88cadr-usb-input"; then
		fail "a line was reported as taken by nobody: $(grep 'no program' "$WORK/out.S88cadr-usb-input")"
	else
		ok "--ozd-port went to a program, which was told not to run"
	fi
	# The control: a flag no list names really is reported, on the same run
	# of the same reporter.  Without this the case above would pass on a
	# reporter that had stopped reporting anything at all.
	printf -- '--no-ozd\r\n--ozd-prt 42142\r\n' > "$WORK/card/fpgarc"
	: > "$WORK/run/claimed"
	FPGARC_CLAIMED="$WORK/run/claimed" PATH="$WORK/bin:$PATH" \
		"$WORK/S84ozd" start > /dev/null 2>&1
	FPGARC_CLAIMED="$WORK/run/claimed" PATH="$WORK/bin:$PATH" \
		"$WORK/S88cadr-usb-input" start > "$WORK/out.S88cadr-usb-input" 2>&1
	if grep -q -- '--ozd-prt' "$WORK/out.S88cadr-usb-input"; then
		ok "and a misspelling of it still is reported"
	else
		fail "a misspelled --ozd-prt was not reported, so the case above tests nothing"
	fi
fi

case_head "the card's own settings reach ozd, each under ozd's own name"
sandbox
if prepare ozd S84ozd; then
	mkdir -p "$WORK/card/sys"
	{ printf -- '--ozd-chaos-address 3060\r\n'
	  printf -- '--ozd-name MIT-OZ,OZ,system=UNIX\r\n'
	  printf -- '--ozd-port 42242\r\n'
	  printf -- '--ozd-root sys=%s/card/sys,ro\r\n' "$WORK"
	  printf -- '--ozd-host 3050,MIT-LISPM-1,system=LISPM\r\n'
	  printf -- '--ozd-trace\r\n'; } > "$WORK/card/fpgarc"
	run_script S84ozd
	for want in "--address 3060" "--name MIT-OZ,OZ,system=UNIX" \
	            "--listen 127.0.0.1:42242" "--root sys=$WORK/card/sys,ro" \
	            "--host 3050,MIT-LISPM-1,system=LISPM" "--trace"; do
		if ozd_given | grep -q -- "$want"; then
			ok "ozd was given $want"
		else
			fail "ozd was not given $want; it was given: $(ozd_given)"
		fi
	done
	# **AND NOT ONE OF THIS BOARD'S OWN SPELLINGS REACHED IT.**  ozd refuses
	# a flag it does not know, so a rename that did not happen would be a
	# host that never started --- and the case above would still pass,
	# because the defaults it looks for would be there too.
	if ozd_given | grep -q -- '--ozd-'; then
		fail "a --ozd- spelling reached ozd itself: $(ozd_given)"
	else
		ok "and no --ozd- spelling reached it; every one was rewritten"
	fi
fi

# **THE DRY RUN IS ozd TOO, AND ozd WILL NOT RUN AS ROOT.**  The script ran
# `--check` itself, as root, before it dropped to the ozd user for the start,
# and ozd refused it with "refusing to run as root".  So on a board the host
# never started at all, and the console said FAIL with ozd's words under it.
# The stand-in refuses exactly that, so this case holds that the dry run goes
# through the same user as the start.
case_head "the dry run is run as ozd's own user, because ozd refuses root for --check too"
sandbox
if prepare ozd S84ozd; then
	: > "$WORK/card/fpgarc"
	run_script S84ozd
	if grep -q 'refusing to run as root' "$WORK/out.S84ozd"; then
		fail "ozd was run as root and refused: $(cat "$WORK/out.S84ozd")"
	else
		ok "ozd was never run as root"
	fi
	if [ -s "$WORK/ozd.check.calls" ]; then
		ok "the dry run was run, and passed the refusal: $(cat "$WORK/ozd.check.calls")"
	else
		fail "the dry run never reached ozd's --check"
	fi
	if grep -q -- "-c $(id -un) " "$WORK/ssd.fg.calls" &&
	   grep -q -- "--check" "$WORK/ssd.fg.calls"; then
		ok "and it went through start-stop-daemon's -c, as the start does"
	else
		fail "the dry run did not go through start-stop-daemon -c: $(cat "$WORK/ssd.fg.calls")"
	fi
	if grep -q '^Starting ozd: OK$' "$WORK/out.S84ozd"; then
		ok "and the host started"
	else
		fail "the host did not start: $(cat "$WORK/out.S84ozd")"
	fi
fi

case_head "a root the card names and the board has not got stops the host, in ozd's words"
sandbox
if prepare ozd S84ozd; then
	printf -- '--ozd-root sys=/mnt/card/sys,ro\r\n' > "$WORK/card/fpgarc"
	OZD_CHECK_FAILS=yes run_script S84ozd
	if [ -s "$WORK/daemon.calls" ]; then
		fail "the host was started although its own --check refused: $(ozd_given)"
	else
		ok "nothing was started"
	fi
	if grep -q 'cannot be resolved' "$WORK/out.S84ozd"; then
		ok "and what the console says is ozd's own refusal, with the path in it"
	else
		fail "the console does not carry ozd's refusal: $(cat "$WORK/out.S84ozd")"
	fi
	if [ -e "$WORK/run/cadr-ozd.peer" ]; then
		fail "a peer file was left behind by a host that never started"
	else
		ok "and no peer file, so the machine is not sent to a host that is not there"
	fi
fi

case_head "the machine is given the host on its own board, and only when one is running"
sandbox
if prepare ozd S84ozd && prepare cadr-chaosnet S87cadr-chaosnet; then
	printf -- '--chaos-address 177201\r\n--chaos-udp 127.0.0.1:42042\r\n' \
		> "$WORK/card/fpgarc"
	run_script S84ozd
	if [ -s "$WORK/run/cadr-ozd.peer" ]; then
		ok "the host left its endpoint behind: $(cat "$WORK/run/cadr-ozd.peer")"
	else
		fail "the host started and left no endpoint for the Chaosnet to read"
	fi
	run_script S87cadr-chaosnet
	passes_once "--chaos-udp-peer" "cadr-chaosnet" "177200@127.0.0.1:42142"
	if grep -q 'file and time host is on this board' "$WORK/out.S87cadr-chaosnet"; then
		ok "and the console says which host the machine reaches"
	else
		fail "the console does not say where the machine's file host is"
	fi
	# **THE CONTROL.**  With no host running the peer must not appear, or
	# the case above would pass on a script that added that peer whatever
	# happened --- and a machine would be sent to a port nothing answers.
	rm -f "$WORK/run/cadr-ozd.peer"
	run_script S87cadr-chaosnet
	passes_not "--chaos-udp-peer" "cadr-chaosnet"
fi

# **THE COLLISION, WHICH IS THE ONE THAT COSTS THE WHOLE CABLE.**  A band calls
# ONE address for its file host.  If the card places that address on a network
# and the board answers at it on the loopback, cadr-chaosnet is given one Chaos
# address at two endpoints and refuses by name --- `udp: 177200 twice; one
# endpoint an address` --- and the program does not start at all.  So the card
# wins and the console says so.
case_head "a card that places the host's address itself keeps its own host, and keeps its cable"
sandbox
if prepare ozd S84ozd && prepare cadr-chaosnet S87cadr-chaosnet; then
	{ printf -- '--chaos-address 177201\r\n'
	  printf -- '--chaos-udp 0.0.0.0:42042\r\n'
	  printf -- '--chaos-udp-peer 177200@192.0.2.9:42142\r\n'; } > "$WORK/card/fpgarc"
	run_script S84ozd
	run_script S87cadr-chaosnet
	if [ "$(given_count -- '--chaos-udp-peer')" = 1 ]; then
		ok "the address is placed once"
	else
		fail "the address is placed $(given_count -- '--chaos-udp-peer') times; it was given: $(given)"
	fi
	if given | grep -q '177200@192.0.2.9:42142'; then
		ok "and it is the card's endpoint that was placed"
	else
		fail "the card's own endpoint was not placed; it was given: $(given)"
	fi
	if given | grep -q '127.0.0.1:42142'; then
		fail "the host on the board was placed as well, which the program refuses by name"
	else
		ok "and the host on the board was not placed beside it"
	fi
	if grep -q 'places 177200 on the network itself' "$WORK/out.S87cadr-chaosnet"; then
		ok "and the console says which of the two the machine reaches"
	else
		fail "the console does not say the card's own host won: $(cat "$WORK/out.S87cadr-chaosnet")"
	fi
fi

# **AND THE WAIT FOR THE NETWORK IS ONLY FOR A NAME.**  cadr-chaosnet resolves
# every peer's name once at the start and exits if one has none, which is what
# the wait is for.  A card whose peers are all written as addresses has nothing
# for a resolver to answer about --- and a board that is its own file host is
# exactly such a card, at every boot.  This waited the whole bound all the same
# until it was written down: `network_ready` asks for a global address and a
# default route before it looks at a single name.
case_head "a board whose peers are all addresses does not wait for a network"
sandbox
if prepare cadr-chaosnet S87cadr-chaosnet; then
	{ printf -- '--chaos-address 177201\r\n'
	  printf -- '--chaos-udp 127.0.0.1:42042\r\n'
	  printf -- '--chaos-udp-peer 177200@127.0.0.1:42142\r\n'; } > "$WORK/card/fpgarc"
	# No address, no route: a board with nothing plugged in.  The real
	# `network_ready` fails at its first question on such a board.
	cat > "$WORK/bin/ip" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/ip.calls"
exit 0
EOF
	chmod +x "$WORK/bin/ip"
	run_script S87cadr-chaosnet
	if grep -q 'no name to wait for' "$WORK/out.S87cadr-chaosnet"; then
		ok "it says there is no name to wait for"
	else
		fail "the board waited for a network it has no name to resolve on: $(cat "$WORK/out.S87cadr-chaosnet")"
	fi
	if grep -q 'waiting up to' "$WORK/out.S87cadr-chaosnet"; then
		fail "it waited"
	else
		ok "and it did not wait"
	fi
	passes_once "--chaos-udp" "cadr-chaosnet" "127.0.0.1:42042"
fi

# **THE CONTROL FOR THE CASE ABOVE**, and it is the half that makes it a
# measurement rather than a wish: a card with a peer named by NAME must still
# wait, on the same stubbed board with nothing plugged in.  Without this, a
# script that had simply stopped waiting for anything would pass.
case_head "and a board with a peer named by name still waits"
sandbox
if prepare cadr-chaosnet S87cadr-chaosnet; then
	{ printf -- '--chaos-address 177201\r\n'
	  printf -- '--chaos-udp 0.0.0.0:42042\r\n'
	  printf -- '--chaos-udp-peer 177200@a-host.invalid:42142\r\n'; } > "$WORK/card/fpgarc"
	cat > "$WORK/bin/ip" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/ip.calls"
exit 0
EOF
	chmod +x "$WORK/bin/ip"
	run_script S87cadr-chaosnet
	if grep -q 'waiting up to' "$WORK/out.S87cadr-chaosnet"; then
		ok "it waited, and said what it was waiting for"
	else
		fail "a card with a name to resolve did not wait: $(cat "$WORK/out.S87cadr-chaosnet")"
	fi
	if grep -q 'no name to wait for' "$WORK/out.S87cadr-chaosnet"; then
		fail "it said there was no name to wait for, and a-host.invalid is a name"
	else
		ok "and it did not say there was no name"
	fi
fi

# **AND THE CARD TURNS THE HOST OFF EXACTLY WHEN IT NAMES ONE ON A NETWORK.**
# The two are one decision: a card with peer lines has been told where the
# band's file host is, and a second host at the same address would be the
# collision above.  Both halves are asserted, because a card script that wrote
# --no-ozd live always would pass the first alone.
case_head "the card writes --no-ozd live when it names a peer, and commented when it does not"
sandbox
if generate_fpgarc "" "" "" arty-z7-20 "177200@192.0.2.9:42142"; then
	GEN="$WORK/gen/card/fpgarc"
	if tr -d '\r' < "$GEN" | grep -qx -- '--no-ozd'; then
		ok "a card with a file host on its network turns the one on the board off"
	else
		fail "a card with a peer does not write --no-ozd live"
	fi
fi
sandbox
if generate_fpgarc "" ""; then
	GEN="$WORK/gen/card/fpgarc"
	if tr -d '\r' < "$GEN" | grep -qx -- '#--no-ozd'; then
		ok "and a card with no peer leaves it commented, so the board serves itself"
	else
		fail "a card with no peer does not write --no-ozd commented out"
	fi
fi

# ---------------------------------------------------------------------------
# 9.  THE CARD'S LAYOUT, THE ZIP, AND THE TWO CARD SHAPES THE BOARD MAY MEET.
#
# The card is ONE FAT32 partition that the user formats themselves and unpacks
# a zip onto.  Four places on it, so that somebody with the card in a reader can
# see what each part is for without reading anything: the root, which holds only
# what a loader demands by name and the three files a person edits; a folder
# named for the board; `packs/`; and `sys/` and `site/` for the band's Lisp
# files.
#
# **WHAT THIS REPLACED, AND WHAT IT COULD NOT KEEP.**  There used to be an
# image with two partitions, and this section held the arithmetic that sized
# them: a check that ran the card script's own sizing function against measured
# byte counts, with the 272 MiB it once got wrong as the control.  That
# arithmetic had to be right to the megabyte, because `dd` wrote every byte of
# an image and an image larger than the card failed part way through the write.
# It is gone with the image, and it could not be kept: there is no partition to
# size, the user's own formatter makes it, and a number this script imposed
# would be a number about nothing.  What replaced it is a REPORT --- how much a
# card must hold --- and it is still run rather than restated, by the same lift.
#
# What did NOT go is the readback.  The image was read back file by file out of
# each partition with mtools, because a staging that merely copied into a
# directory says nothing about what the board would find.  The zip is read back
# the same way, and the cases below require it to catch a file the zip did not
# carry.
# ---------------------------------------------------------------------------
T300_ON_CARD=269565952
SYS_ON_CARD=17031168
SITE_ON_CARD=24576

# The card's own arithmetic, lifted from the card script.
lift_sizing() {
	sed -n '/^card_needs_mb() {$/,/^}$/p' "$MKSD" > "$1"
	if [ ! -s "$1" ]; then
		fail "the card's sizing is not where this check looks in mksd-buildroot.sh"
		return 1
	fi
	if [ "$(grep -c '^card_needs_mb() {$' "$1")" != 1 ]; then
		fail "card_needs_mb is not where this check looks"
		return 1
	fi
	return 0
}

case_head "the card script says how big a card has to be, and says it of what is on the card"
sandbox
if lift_sizing "$WORK/sizing.sh"; then
	# A card carrying a T-300, both of the band's trees, and the twelve
	# megabytes of loader, kernel, fabric and root filesystem a board needs
	# before it holds anything of the band's at all.
	boot=12500992
	mb=$( . "$WORK/sizing.sh"; card_needs_mb $T300_ON_CARD $SYS_ON_CARD $SITE_ON_CARD $boot )
	need=$(( T300_ON_CARD + SYS_ON_CARD + SITE_ON_CARD + boot ))
	if [ "$(( mb * 1048576 ))" -ge "$need" ]; then
		ok "a card with a T-300 and both trees is told ${mb} MiB, and they come to $(( need / 1048576 + 1 ))"
	else
		fail "a card with a T-300 and both trees is told ${mb} MiB and they come to $(( need / 1048576 + 1 ))"
	fi
	# **THE CONTROL, AND IT IS THE POINT OF THE CASE.**  A function that
	# returned a round number, or the boot files alone, would pass the line
	# above on a small enough input.  So the pack must be IN the answer: the
	# same card without it must be smaller by about the pack.
	nopack=$( . "$WORK/sizing.sh"; card_needs_mb 0 $SYS_ON_CARD $SITE_ON_CARD $boot )
	if [ "$(( mb - nopack ))" -ge "$(( T300_ON_CARD / 1048576 ))" ]; then
		ok "and the same card without the pack is ${nopack} MiB, which is the pack smaller"
	else
		fail "the pack is not in the answer: ${mb} MiB with it and ${nopack} without"
	fi
	# And the megabyte is rounded UP, because a card of exactly the floor is
	# a card with nothing left, and the number is advice a person acts on.
	one=$( . "$WORK/sizing.sh"; card_needs_mb 1 0 0 1048576 )
	if [ "$one" = 2 ]; then
		ok "and a card holding one byte over a megabyte is told 2 MiB, not 1"
	else
		fail "1048577 bytes is told $one MiB: the rounding is down, and a card of the floor has nothing left"
	fi
fi

# **THE ROOT HOLDS WHAT THE LOADER DEMANDS AND THE THREE A PERSON EDITS, AND
# NOTHING ELSE.**  This matters more with one partition than it did with two:
# the root of the card is now where the loader looks AND where a person copies
# things, so it is the place a stray file lands, and a stray file at the root is
# one nothing on the board reads.
#
# The guard is lifted out of the card script on its own anchors and run against
# a fabricated card, once clean and once with one extra file --- and the second
# is the point, because a guard that accepted everything would pass the first.
lift_root_guard() {
	lift 'for e in "$OUT"/card/* "$OUT"/card/.*; do' \
	     'done' "$1" || return 1
	return 0
}
root_guard() {
	( set -eu
	  OUT="$WORK/root"
	  BOARD_NAME=arty-z7-20
	  ROOT_NAMES="BOOT.BIN u-boot.img"
	  die() { echo "mksd-buildroot: $*" >&2; exit 1; }
	  . "$WORK/rootguard.sh" ) 2>"$WORK/root.err"
}
make_root() {
	rm -rf "$WORK/root"
	mkdir -p "$WORK/root/card/arty-z7-20" "$WORK/root/card/packs" \
	         "$WORK/root/card/sys" "$WORK/root/card/site"
	for f in BOOT.BIN u-boot.img uEnv.txt README.TXT fpgarc muirrc; do
		echo x > "$WORK/root/card/$f"
	done
}

case_head "the card's root holds the loader's fixed names, the three a person edits, and the four folders"
sandbox
if lift_root_guard "$WORK/rootguard.sh"; then
	make_root
	if root_guard; then
		ok "a card laid out the way the script lays it out passes"
	else
		fail "a card laid out the way the script lays it out is refused: $(cat "$WORK/root.err")"
	fi
	# THE CONTROL: one file at the root that is none of those names.  A card
	# with a stray zImage at the root is exactly what a hand-copied card
	# looks like, and nothing on the board would read it.
	make_root
	echo x > "$WORK/root/card/zImage"
	if root_guard; then
		fail "a stray zImage at the root was accepted; this guard accepts anything"
	else
		ok "and a stray zImage at the root is refused by name: $(sed 's/^mksd-buildroot: //' "$WORK/root.err")"
	fi
	# AND THE SECOND CONTROL: a folder that is none of the four.  An
	# extra directory on the card is a place a person would put something
	# nothing reads.
	make_root
	mkdir -p "$WORK/root/card/backup"
	if root_guard; then
		fail "a stray folder at the root was accepted"
	else
		ok "and a stray folder at the root is refused by name"
	fi
	# AND THE THIRD: the board's own folder is required to be ALLOWED, which
	# is the case that would fail if the guard were simply refusing every
	# directory.
	make_root
	if root_guard; then
		ok "and the board's own folder, packs/, sys/ and site/ are not what it refuses"
	else
		fail "the four folders are refused: $(cat "$WORK/root.err")"
	fi
fi

# **THE ZIP IS THE CARD, AND IT IS READ BACK OUT RATHER THAN TRUSTED.**  It is
# what a user unpacks onto a card they formatted, so it is the artifact, and an
# artifact nobody read back is a claim.  The block is lifted and run against a
# fabricated card; then it is run again with `zip` stubbed to drop one file,
# and it must die.  Without the second half the first passes on a block that
# unpacked nothing and compared nothing.
lift_zip() {
	# The block's own last line, which is a named `fi` for exactly this
	# reason: `lift` stops at the first line that carries the last anchor,
	# so an anchor inside the block would cut the `fi` off and the lifted
	# copy would not parse.
	lift 'ZIP="$(cd "$OUT" && pwd)/cadr-$BOARD_NAME.zip"' \
	     'fi  # the zip, built and read back' "$1" || return 1
	return 0
}
run_zip() {
	( set -eu
	  OUT="$WORK/root"
	  BOARD_NAME=arty-z7-20
	  die() { echo "mksd-buildroot: $*" >&2; exit 1; }
	  PATH="$1:$PATH"
	  . "$WORK/zip.sh" ) >"$WORK/zip.out" 2>&1
}

case_head "the zip holds the card, read back out of it rather than trusted"
sandbox
if ! command -v zip >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; then
	ok "skipped: no zip or unzip on this host"
elif lift_zip "$WORK/zip.sh"; then
	make_root
	echo band > "$WORK/root/card/packs/disk-pack-0.img"
	echo lisp > "$WORK/root/card/sys/a.lisp"
	if run_zip "$WORK/bin"; then
		ok "the card zips and unzips back to itself: $(sed -n 's/^mksd-buildroot: //p' "$WORK/zip.out" | tail -1)"
	else
		fail "the card did not zip: $(cat "$WORK/zip.out")"
	fi
	# And every folder is really in it, empty ones included, which is what
	# tells somebody where a band goes.
	if [ -f "$WORK/root/cadr-arty-z7-20.zip" ]; then
		z_ok=yes
		for d in arty-z7-20 packs sys site; do
			unzip -l "$WORK/root/cadr-arty-z7-20.zip" | grep -q " $d/" \
				|| { fail "the zip carries no $d/ entry"; z_ok=no; }
		done
		[ "$z_ok" = yes ] && ok "and it carries all four folders, the empty site/ among them"
	fi
	# **THE CONTROL.**  A `zip` that quietly drops a file is what a readback
	# is for, and it is not a fancy failure: a zip built from a directory
	# that was still being written would do the same.
	mkdir -p "$WORK/badbin"
	cat > "$WORK/badbin/zip" <<EOF
#!/bin/sh
# Everything the real one does, minus one file.
_args=
for a; do case "\$a" in README.TXT) ;; *) _args="\$_args \$a" ;; esac; done
exec $(command -v zip) \$_args -x README.TXT
EOF
	chmod +x "$WORK/badbin/zip"
	make_root
	if run_zip "$WORK/badbin"; then
		fail "a zip missing README.TXT was accepted; nothing is being read back"
	else
		ok "and a zip that dropped README.TXT is refused: $(sed -n 's/^mksd-buildroot: //p' "$WORK/zip.out" | tail -1)"
	fi
fi

# **THE TWO CARD SHAPES THE BOARD MAY MEET.**  `mksd-*.sh` makes one shape, and
# S80cadr-disk-packs is the one place on the board that knows there was ever
# another: cards of the old two-partition shape are in boards that are running,
# with `fpgarc`, `muirrc`, `clock` and a flat drive bay on the second partition.
# So it takes the second partition when there is one, and the first when there
# is not, and the drive bay's directory follows.
#
# Both halves are required, and the second is the control: a script that always
# mounted the first partition would pass the new-shape case alone, and a board
# with an old card would come up with no band and nothing saying why.
case_head "a card of the new shape is mounted whole and its bay is packs/"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo "$WORK/dev/p1" > "$WORK/mountable"
	printf -- '--chaos-address 177101\r\n' > "$WORK/card/fpgarc"
	run_script S80cadr-disk-packs
	passes_once "--packs" "cadr-disk-packs" "$WORK/card/packs"
	if grep -q "the card is at $WORK/card, read-write" "$WORK/out.S80cadr-disk-packs"; then
		ok "and the console says the card is mounted read-write"
	else
		fail "the console does not say the card is mounted: $(cat "$WORK/out.S80cadr-disk-packs")"
	fi
	if grep -q "OLD TWO-PARTITION" "$WORK/out.S80cadr-disk-packs"; then
		fail "a card of the new shape was called old"
	else
		ok "and it is not called old"
	fi
fi

case_head "a card of the OLD two-partition shape still works, and is told it is old"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo "$WORK/dev/p2" > "$WORK/mountable"
	printf -- '--chaos-address 177101\r\n' > "$WORK/card/fpgarc"
	run_script S80cadr-disk-packs
	# The bay is the root of that partition and not a folder in it, which is
	# where the packs on those cards really are.  This is the whole of what
	# keeps a running board working, and it is one word of one command line.
	passes_once "--packs" "cadr-disk-packs" "$WORK/card "
	if grep -q "OLD TWO-PARTITION SHAPE" "$WORK/out.S80cadr-disk-packs"; then
		ok "and the console says so, and says to reformat the card and unpack the zip"
	else
		fail "an old card is not told it is old: $(cat "$WORK/out.S80cadr-disk-packs")"
	fi
	# And it still reads the card's file of flags, which on that shape is on
	# the partition that mounted.  A board that came up with no settings is
	# the failure this case exists to catch.
	if grep -q "177101" "$WORK/daemon.calls" || [ -s "$WORK/card/fpgarc" ]; then
		ok "and fpgarc is read from the partition that mounted"
	else
		fail "fpgarc was not read on an old card"
	fi
fi

# **THE CARD'S PERMISSIONS ARE THE MOUNT'S OWN, NOT THE UMASK OF WHOEVER RAN
# IT.**  FAT keeps no owner and no mode, so vfat makes them up at mount time,
# from uid=, gid= and the masks, and from the caller's umask where those are
# not given.  At boot the umask is 022 and ozd, which runs as a user of its own,
# can read `sys/` and `site/`.  A restart from an ssh session with umask 077
# mounted the same card with every file root's alone, so ozd could not read the
# trees and its dry run refused them.  So every vfat mount must name its owner,
# its group and its masks, with root keeping write and everybody keeping read
# and directory search.  The stub cannot see a umask, so what is held is the
# words: each vfat mount the script asked for, on both card shapes.
mount_opts_hold() {
	_n=0
	while IFS= read -r _line; do
		case "$_line" in *"-t vfat"*) ;; *) continue ;; esac
		_n=$((_n + 1))
		_o=$(printf '%s\n' "$_line" | sed -n 's/.*-o \([^ ]*\).*/\1/p')
		_uid=$(printf '%s\n' "$_o" | tr ',' '\n' | sed -n 's/^uid=//p')
		_gid=$(printf '%s\n' "$_o" | tr ',' '\n' | sed -n 's/^gid=//p')
		_um=$(printf '%s\n' "$_o" | tr ',' '\n' | sed -n 's/^umask=//p')
		_dm=$(printf '%s\n' "$_o" | tr ',' '\n' | sed -n 's/^dmask=//p')
		_fm=$(printf '%s\n' "$_o" | tr ',' '\n' | sed -n 's/^fmask=//p')
		[ -n "$_dm" ] || _dm=$_um
		[ -n "$_fm" ] || _fm=$_um
		if [ "$_uid" != 0 ] || [ -z "$_gid" ] || [ -z "$_dm" ] || [ -z "$_fm" ]; then
			fail "a card mount leaves its owner, group or masks to the caller: $_line"
			continue
		fi
		# Root keeps write; every user keeps read, and search on directories.
		if [ $((0$_dm & 0205)) != 0 ] || [ $((0$_fm & 0204)) != 0 ]; then
			fail "a card mount takes away root's write or another user's read: $_line"
			continue
		fi
		ok "the mount states its own permissions: -o $_o"
	done < "$WORK/mount.calls"
	[ "$_n" -gt 0 ] || fail "no vfat mount was asked for, so nothing was held"
}

case_head "the card's permissions are stated by its mount, on both shapes, whatever the umask"
for dev in p1 p2; do
	sandbox
	if prepare cadr-disk-packs S80cadr-disk-packs; then
		echo "$WORK/dev/$dev" > "$WORK/mountable"
		( umask 077; run_script S80cadr-disk-packs )
		mount_opts_hold
	fi
done

# **AND THE ozd GROUP MAY WRITE THE CARD**, so that the host can serve the
# band's `site` tree read-write and the band can save its host table there.
# FAT has no owner per directory, so the group can write the whole card, which
# is the accepted cost.  The group is looked up when the board boots, because
# Buildroot picks its id when it builds the image: two gids are tried, so a
# script that wrote one image's number in would fail the other.  Each vfat
# mount must name that gid, give the group write and search, and still pass
# `mount_opts_hold` above, which is root's write and everybody's read.
group_may_write() {
	_n=0
	while IFS= read -r _line; do
		case "$_line" in *"-t vfat"*) ;; *) continue ;; esac
		_n=$((_n + 1))
		_o=$(printf '%s\n' "$_line" | sed -n 's/.*-o \([^ ]*\).*/\1/p')
		_gid=$(printf '%s\n' "$_o" | tr ',' '\n' | sed -n 's/^gid=//p')
		_um=$(printf '%s\n' "$_o" | tr ',' '\n' | sed -n 's/^umask=//p')
		_dm=$(printf '%s\n' "$_o" | tr ',' '\n' | sed -n 's/^dmask=//p')
		_fm=$(printf '%s\n' "$_o" | tr ',' '\n' | sed -n 's/^fmask=//p')
		[ -n "$_dm" ] || _dm=$_um
		[ -n "$_fm" ] || _fm=$_um
		if [ "$_gid" != "$1" ]; then
			fail "the card is mounted for gid '$_gid' and the ozd group is $1: $_line"
			continue
		fi
		if [ -z "$_dm" ] || [ -z "$_fm" ] \
		   || [ $((0$_dm & 0070)) != 0 ] || [ $((0$_fm & 0060)) != 0 ]; then
			fail "the card's group cannot write it or search its folders: $_line"
			continue
		fi
		ok "the ozd group, gid $1, may write the card: -o $_o"
	done < "$WORK/mount.calls"
	[ "$_n" -gt 0 ] || fail "no vfat mount was asked for, so nothing was held"
}

case_head "the ozd group may write the card, on both shapes, whatever gid the image gave it"
for gid in 1042 977; do
	for dev in p1 p2; do
		sandbox
		if prepare cadr-disk-packs S80cadr-disk-packs; then
			echo "$gid" > "$WORK/ozd.gid"
			echo "$WORK/dev/$dev" > "$WORK/mountable"
			( umask 077; run_script S80cadr-disk-packs )
			group_may_write "$gid"
			mount_opts_hold
			# The pack program runs as root and still gets its bay.
			if grep -q -- "--packs" "$WORK/daemon.calls"; then
				ok "and the pack program, which runs as root, is started with its bay"
			else
				fail "the pack program was not started: $(cat "$WORK/out.S80cadr-disk-packs")"
			fi
			if grep -q "no ozd user" "$WORK/out.S80cadr-disk-packs"; then
				fail "an image with ozd is told it has none: $(cat "$WORK/out.S80cadr-disk-packs")"
			else
				ok "and the console does not say the image lacks ozd"
			fi
		fi
	done
done

# **AN IMAGE WITHOUT ozd KEEPS THE CARD ROOT'S, AND SAYS SO.**  There is no
# group to give it to, so the options are the ones every board had before the
# group was given write: root owns the card and every user reads it.
case_head "an image with no ozd user mounts the card as root's, and the console says why"
for dev in p1 p2; do
	sandbox
	if prepare cadr-disk-packs S80cadr-disk-packs; then
		rm -f "$WORK/ozd.gid"
		echo "$WORK/dev/$dev" > "$WORK/mountable"
		run_script S80cadr-disk-packs
		if grep -q -- "-t vfat -o rw,uid=0,gid=0,umask=0022 " "$WORK/mount.calls"; then
			ok "the card is mounted rw,uid=0,gid=0,umask=0022"
		else
			fail "an image without ozd does not mount the card as root's: $(cat "$WORK/mount.calls")"
		fi
		mount_opts_hold
		if grep -q "no ozd user" "$WORK/out.S80cadr-disk-packs"; then
			ok "and the console says there is no ozd user"
		else
			fail "the console does not say why the card is root's: $(cat "$WORK/out.S80cadr-disk-packs")"
		fi
		if grep -q -- "--packs" "$WORK/daemon.calls"; then
			ok "and the pack program is started with its bay"
		else
			fail "the pack program was not started without ozd"
		fi
	fi
done

# **A BOARD WITH NO CARD SAYS NOTHING ABOUT ozd**, because nothing was mounted
# and so nothing about the card's group happened.
case_head "a board with no card and no ozd user says only that there is no card"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	rm -f "$WORK/ozd.gid"
	: > "$WORK/mountable"
	run_script S80cadr-disk-packs
	if grep -q "no ozd user" "$WORK/out.S80cadr-disk-packs"; then
		fail "a board with no card talks about the card's group: $(cat "$WORK/out.S80cadr-disk-packs")"
	else
		ok "the console does not talk about a card that is not there"
	fi
fi

case_head "and a board with no card it can mount says so and leaves the bay empty"
sandbox
if prepare cadr-disk-packs S80cadr-disk-packs; then
	: > "$WORK/mountable"
	run_script S80cadr-disk-packs
	if grep -q "no card at $WORK/dev/p1" "$WORK/out.S80cadr-disk-packs"; then
		ok "the console names the device it could not mount"
	else
		fail "a board with no card does not say so: $(cat "$WORK/out.S80cadr-disk-packs")"
	fi
	# It starts the program anyway, which is what lets a pack copied in later
	# become a drive with no restart.
	if [ -s "$WORK/daemon.calls" ]; then
		ok "and the pack program is started anyway, so a pack copied in later is a drive"
	else
		fail "the pack program was not started on a board with no card"
	fi
fi

# **THE BAND'S TWO TREES ARE TWO LINES AND TWO DECISIONS.**  A line naming a
# tree that is not there stops the host in its own words, so each is live
# exactly when its own tree was staged --- and they are separate, because a
# card may carry one and not the other.  The sources are read-only and the site
# configuration is not, which is the difference between a tree of sources and a
# thing its owner changes.
case_head "the card names each of the band's trees exactly when it carries that tree"
sandbox
if generate_fpgarc "" "" "" arty-z7-20 "" "/some/sys" "/some/site"; then
	GEN="$WORK/gen/card/fpgarc"
	if tr -d '\r' < "$GEN" | grep -qx -- '--ozd-root sys=/mnt/card/sys,ro'; then
		ok "a card with the sources on it names them, read-only"
	else
		fail "a card carrying the sources does not name them"
	fi
	if tr -d '\r' < "$GEN" | grep -qx -- '--ozd-root site=/mnt/card/site'; then
		ok "and a card with the site configuration names it, and WITHOUT ,ro"
	else
		fail "a card carrying the site configuration does not name it read-write"
	fi
fi
sandbox
if generate_fpgarc "" ""; then
	GEN="$WORK/gen/card/fpgarc"
	if tr -d '\r' < "$GEN" | grep -qx -- '#--ozd-root sys=/mnt/card/sys,ro'; then
		ok "and a card without the sources leaves that line commented, so the host still starts"
	else
		fail "a card with no sources still names them, which stops the host"
	fi
	if tr -d '\r' < "$GEN" | grep -qx -- '#--ozd-root site=/mnt/card/site'; then
		ok "and a card without the site configuration leaves that line commented too"
	else
		fail "a card with no site tree still names it, which stops the host"
	fi
fi
# **AND THE TWO ARE INDEPENDENT**, which is the control for both cases above: a
# script that wrote both lines from one variable would pass all four.
sandbox
if generate_fpgarc "" "" "" arty-z7-20 "" "/some/sys" ""; then
	GEN="$WORK/gen/card/fpgarc"
	if tr -d '\r' < "$GEN" | grep -qx -- '--ozd-root sys=/mnt/card/sys,ro' \
	   && tr -d '\r' < "$GEN" | grep -qx -- '#--ozd-root site=/mnt/card/site'; then
		ok "a card with the sources and no site tree names one and comments the other"
	else
		fail "the two trees are written from one decision, so a card can never carry only one"
	fi
fi

# ---------------------------------------------------------------------------
# 9.  A FLAG GIVEN TWICE IS TAKEN FROM ITS LAST LINE, AND THE CONSOLE IS TOLD.
#
# A card edited in a reader can end up saying one thing twice: a line
# uncommented under one that was already live, or a value added at the bottom
# without the old one being deleted.  Somebody editing a file expects the line
# further down to win, and a warning on a board is easy to miss, so the value
# used is the last line's.  Every reader of the card has to agree on that, or
# two programs act on two different lines of one file: the ozd script once
# wrote the Chaosnet peer from the first `--ozd-chaos-address` while ozd itself
# was handed every line.  So each script hands its program ONE line for each
# flag, the last, and never leaves the choice to the program.
#
# A flag that is repeatable by its own definition --- a peer, a device, a root,
# a host --- keeps every line, and says nothing.
# ---------------------------------------------------------------------------

# The console's lines about a repeated flag, from one script's last start.
repeat_lines() { grep -F -- "fpgarc: $2 " "$WORK/out.$1" | grep -F 'is on lines' || true; }

# The script warned about $2 exactly once, naming the lines $3 and the line
# used $4.
warns_once() {
	_w=$(repeat_lines "$1" "$2")
	_n=$(printf '%s' "$_w" | grep -c . || true)
	if [ "$_n" != 1 ]; then
		fail "$1 warned about $2 $_n times and once is right; the console says:"
		sed 's/^/        /' "$WORK/out.$1"
		return 1
	fi
	case "$_w" in
	*"is on lines $3 "*"line $4 is used"*)
		ok "$1 warned once that $2 is on lines $3 and line $4 is used" ;;
	*)
		fail "$1 warned about $2 without naming lines $3 and line $4: $_w" ;;
	esac
}

warns_not() {
	if [ -n "$(repeat_lines "$1" "$2")" ]; then
		fail "$1 warned about $2, which may be given more than once: $(repeat_lines "$1" "$2")"
	else
		ok "$1 did not warn about $2, which may be given more than once"
	fi
}

if [ "$HAVE_READER" = yes ]; then
	sandbox
	RC="$WORK/card/fpgarc"
	FPGARC_WARNED="$WORK/run/warned"

	case_head "the reader takes a repeated flag from its last line, counting lines as the file does"
	printf '%s\r\n' \
		'# a comment is a line' \
		'--chaos-udp 0.0.0.0:1' \
		'' \
		'--chaos-udp 0.0.0.0:2' > "$RC"
	rm -f "$FPGARC_WARNED"
	got=$(eval "set -- $(fpgarc_args "$RC" --chaos-udp 2> "$WORK/err")"; printf '[%s]' "$@")
	if [ "$got" = "[--chaos-udp][0.0.0.0:2]" ]; then
		ok "only the last line came back: $got"
	else
		fail "a flag on two lines came back as $got, wanting the last line alone"
	fi
	if grep -qF -- "fpgarc: --chaos-udp is on lines 2 and 4 of $RC; line 4 is used" "$WORK/err"; then
		ok "and the warning names the flag, both lines and the one used"
	else
		fail "the warning does not name --chaos-udp on lines 2 and 4: [$(cat "$WORK/err")]"
	fi

	case_head "three lines are all named, and the last is the one used"
	printf '%s\r\n' '--date 20260101' '--bow' '--date 20260202' '#--date 1' \
		'--date 20260303' > "$RC"
	rm -f "$FPGARC_WARNED"
	got=$(eval "set -- $(fpgarc_args "$RC" --date --bow 2> "$WORK/err")"; printf '[%s]' "$@")
	if [ "$got" = "[--bow][--date][20260303]" ]; then
		ok "the file's order stands and the last --date is the only one: $got"
	else
		fail "three --date lines came back as $got"
	fi
	if grep -qF -- "fpgarc: --date is on lines 1, 3 and 5 of $RC; line 5 is used" "$WORK/err"; then
		ok "and all three lines are named"
	else
		fail "the warning does not name lines 1, 3 and 5: [$(cat "$WORK/err")]"
	fi

	case_head "a bare flag given twice is one word, and is warned about too"
	printf '%s\r\n' '--no-auto-boot' '--no-auto-boot' > "$RC"
	rm -f "$FPGARC_WARNED"
	got=$(eval "set -- $(fpgarc_args "$RC" --no-auto-boot 2> "$WORK/err")"; printf '[%s]' "$@")
	if [ "$got" = "[--no-auto-boot]" ]; then
		ok "--no-auto-boot came back once"
	else
		fail "--no-auto-boot on two lines came back as $got"
	fi
	if grep -qF -- "fpgarc: --no-auto-boot is on lines 1 and 2" "$WORK/err"; then
		ok "and it is warned about"
	else
		fail "a bare flag on two lines is not warned about: [$(cat "$WORK/err")]"
	fi

	case_head "a last line with no newline after it is still the last line"
	printf -- '--date 20260101\r\n--date 20260202' > "$RC"
	rm -f "$FPGARC_WARNED"
	got=$(eval "set -- $(fpgarc_args "$RC" --date 2> "$WORK/err")"; printf '[%s]' "$@")
	if [ "$got" = "[--date][20260202]" ]; then
		ok "the unterminated last line is the one used"
	else
		fail "a file ending without a newline came back as $got"
	fi

	case_head "asking about one repeated flag twice warns once"
	printf '%s\r\n' '--date 20260101' '--date 20260202' > "$RC"
	rm -f "$FPGARC_WARNED"
	{ fpgarc_has "$RC" --date && fpgarc_args "$RC" --date > /dev/null; } 2> "$WORK/err"
	n=$(grep -c 'is on lines' "$WORK/err" || true)
	if [ "$n" = 1 ]; then
		ok "fpgarc_has and then fpgarc_args said it once"
	else
		fail "one repeated flag was warned about $n times: [$(cat "$WORK/err")]"
	fi

	case_head "a flag the caller calls repeatable keeps every line and says nothing"
	printf '%s\r\n' '--usb-device /dev/input/event1' '--usb-scan-ms 1' \
		'--usb-device /dev/input/event2' > "$RC"
	rm -f "$FPGARC_WARNED"
	got=$(FPGARC_REPEATABLE=--usb-device; eval "set -- $(fpgarc_args "$RC" --usb-device --usb-scan-ms 2> "$WORK/err")"; printf '[%s]' "$@")
	if [ "$got" = "[--usb-device][/dev/input/event1][--usb-scan-ms][1][--usb-device][/dev/input/event2]" ]; then
		ok "both devices came back, in the file's order"
	else
		fail "a repeatable flag came back as $got"
	fi
	if [ -s "$WORK/err" ]; then
		fail "a repeatable flag was warned about: [$(cat "$WORK/err")]"
	else
		ok "and nothing was said"
	fi

	case_head "two spellings of one flag are one flag"
	printf '%s\r\n' '--chaos-address 3050' '--address 3060' > "$RC"
	rm -f "$FPGARC_WARNED"
	got=$(FPGARC_SPELLINGS='--address --chaos-address
--udp --chaos-udp'; eval "set -- $(fpgarc_args "$RC" --address --chaos-address 2> "$WORK/err")"; printf '[%s]' "$@")
	if [ "$got" = "[--address][3060]" ]; then
		ok "the last line's spelling and value alone: $got"
	else
		fail "one flag in two spellings came back as $got"
	fi
	if grep -qF -- "is on lines 1 and 2 of $RC; line 2 is used" "$WORK/err"; then
		ok "and it is warned about as one flag"
	else
		fail "two spellings of one flag are not warned about: [$(cat "$WORK/err")]"
	fi
	unset FPGARC_WARNED
fi

sandbox
RC="$WORK/card/fpgarc"

case_head "cadr-chaosnet: each flag once from its last line, either spelling, and every peer"
if prepare cadr-chaosnet S87cadr-chaosnet; then
	printf '%s\r\n' '--chaos-address 3050' '--address 3060' \
		'--chaos-udp 0.0.0.0:1' '--chaos-udp 0.0.0.0:42042' \
		'--chaos-udp-peer 3070@192.0.2.1:1' '--udp-peer 3071@192.0.2.2:2' > "$RC"
	run_script S87cadr-chaosnet
	n=$(( $(given_count --chaos-address) + $(given_count --address) ))
	if [ "$n" = 1 ] && grep -q -- "--address 3060" "$WORK/daemon.calls"; then
		ok "the address was given once, and it is the last line's"
	else
		fail "the address was given $n times, wanting --address 3060 once: $(given)"
	fi
	passes_once --chaos-udp cadr-chaosnet 0.0.0.0:42042
	passes "--chaos-udp-peer 3070@192.0.2.1:1" cadr-chaosnet
	passes "--udp-peer 3071@192.0.2.2:2" cadr-chaosnet
	if grep -qF 'is on lines 1 and 2' "$WORK/out.S87cadr-chaosnet"; then
		ok "the address's two lines were warned about"
	else
		fail "the address's two lines were not warned about"
	fi
	warns_once S87cadr-chaosnet --chaos-udp "3 and 4" 4
	warns_not S87cadr-chaosnet --chaos-udp-peer
	warns_not S87cadr-chaosnet --udp-peer
fi

case_head "cadr-terminal: each flag once, from its last line"
if prepare cadr-terminal S85cadr-terminal; then
	printf '%s\r\n' '--terminal 5901' '--bow' '--terminal 5902' '--bow' > "$RC"
	run_script S85cadr-terminal
	passes_once --terminal cadr-terminal 5902
	passes_once --bow cadr-terminal
	warns_once S85cadr-terminal --terminal "1 and 3" 3
	warns_once S85cadr-terminal --bow "2 and 4" 4
fi

case_head "cadr-serial: each flag once, from its last line"
if prepare cadr-serial S86cadr-serial; then
	printf '%s\r\n' '--serial 0.0.0.0:7641' '--serial 0.0.0.0:7642' > "$RC"
	run_script S86cadr-serial
	passes_once --serial cadr-serial 0.0.0.0:7642
	warns_once S86cadr-serial --serial "1 and 2" 2
fi

case_head "cadr-usb-input: each flag once from its last line, and every device"
if prepare cadr-usb-input S88cadr-usb-input; then
	printf '%s\r\n' '--usb-scan-ms 500' '--usb-device /dev/input/event1' \
		'--usb-scan-ms 600' '--usb-device /dev/input/event2' > "$RC"
	run_script S88cadr-usb-input
	passes_once --usb-scan-ms cadr-usb-input 600
	passes "--usb-device /dev/input/event1" cadr-usb-input
	passes "--usb-device /dev/input/event2" cadr-usb-input
	warns_once S88cadr-usb-input --usb-scan-ms "1 and 3" 3
	warns_not S88cadr-usb-input --usb-device
fi

case_head "cadr-disk-packs: the clock, the display and the boot button take the last line"
if prepare cadr-disk-packs S80cadr-disk-packs; then
	echo 19700101000005 > "$WORK/now"
	printf '%s\r\n' '--date 20260101' '--hdmi-sleep 120' '--no-auto-boot' \
		'--date 20270202' '--hdmi-sleep 240' '--no-auto-boot' > "$RC"
	run_script S80cadr-disk-packs
	clock_set_once "2027-02-02 00:00:05"
	if grep -qx -- "--log /dev/console hdmi-sleep 240" "$WORK/console.calls" &&
	   ! grep -q -- "hdmi-sleep 120" "$WORK/console.calls"; then
		ok "the console was told hdmi-sleep 240 and not 120"
	else
		fail "the console was not told the last --hdmi-sleep alone: $(cat "$WORK/console.calls")"
	fi
	warns_once S80cadr-disk-packs --date "1 and 4" 4
	warns_once S80cadr-disk-packs --hdmi-sleep "2 and 5" 5
	warns_once S80cadr-disk-packs --no-auto-boot "3 and 6" 6
fi

# **THE ONE THIS SECTION WAS WRITTEN FOR.**  The peer file is what the Chaosnet
# program reads to reach the host on this board, and ozd's own --address is the
# address the host answers at.  Two lines on the card must not make those two
# different addresses.
case_head "ozd: the peer file and ozd's own address are the card's last line, and agree"
if prepare ozd S84ozd; then
	mkdir -p "$WORK/card/sys" "$WORK/card/site"
	printf '%s\r\n' '--ozd-chaos-address 177300' '--ozd-name A,system=UNIX' \
		"--ozd-root sys=$WORK/card/sys,ro" '--ozd-chaos-address 177301' \
		'--ozd-name B,system=UNIX' "--ozd-root site=$WORK/card/site" \
		'--ozd-host 3050,X,system=LISPM' '--ozd-host 3051,Y,system=LISPM' > "$RC"
	run_script S84ozd
	peer=$(cat "$WORK/run/cadr-ozd.peer" 2>/dev/null)
	if [ "$peer" = "177301@127.0.0.1:42142" ]; then
		ok "the peer file names the last line's address: $peer"
	else
		fail "the peer file says [$peer], wanting 177301@127.0.0.1:42142"
	fi
	passes_once --address ozd 177301
	# The address ozd was given, read out of its own arguments and compared
	# with the peer file's, so that the two are held to each other and not
	# only each to a constant here.
	given_addr=$(tr ' ' '\n' < "$WORK/daemon.calls" | sed -n '/^--address$/{n;p;}' | tail -n 1)
	if [ -n "$given_addr" ] && [ "$given_addr" = "${peer%%@*}" ]; then
		ok "and ozd answers at the address the peer file names"
	else
		fail "ozd was given --address [$given_addr] and the peer file names [${peer%%@*}]"
	fi
	passes_once --name ozd B,system=UNIX
	passes "--root sys=$WORK/card/sys,ro" ozd
	passes "--root site=$WORK/card/site" ozd
	passes "--host 3050,X,system=LISPM" ozd
	passes "--host 3051,Y,system=LISPM" ozd
	warns_once S84ozd --ozd-chaos-address "1 and 4" 4
	warns_once S84ozd --ozd-name "2 and 5" 5
	warns_not S84ozd --ozd-root
	warns_not S84ozd --ozd-host
fi

echo
if [ "$fails" = 0 ]; then
	echo "fpgarc: $cases cases, one file of flags reaches six programs and each gets its own"
	exit 0
fi
echo "fpgarc: $fails failures in $cases cases"
exit 1
