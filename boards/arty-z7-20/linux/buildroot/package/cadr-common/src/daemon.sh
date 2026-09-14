# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# STARTING A DAEMON SO THAT A FLAG IT REFUSES IS NOT SILENT.
#
# **THE FAULT THIS EXISTS FOR.**  Every one of these programs refuses a flag it
# does not know --- muir's behaviour, and the property the card's one file of
# flags is built on, because a flag quietly ignored is a setting somebody wrote
# down and did not get.  But a refusal is a line on stderr, and an init script
# starts its program with `start-stop-daemon -b`, which daemonises it and sends
# stdout and stderr to /dev/null.  So the program printed its refusal into
# nothing, start-stop-daemon reported that it had forked successfully, and the
# script printed OK.  That is the exact shape of the carriage return that once
# cost this board its whole Chaosnet: a boot that looks perfect with a program
# that is not running.
#
# **WHAT THIS DOES ABOUT IT.**  Start the program, wait a moment, and look for
# it.  If it is not there, run it once more with the same words and print what
# it says, which is the refusal --- and print FAIL rather than OK.
#
# **WHY RUNNING IT AGAIN IS SAFE, and it is worth being exact.**  This runs
# only when the daemon is already gone, and a program is gone for one of three
# reasons.  It refused a flag, which happens at argument parsing before it has
# opened /dev/mem, bound a socket or touched the fabric, so a second run
# refuses identically and does nothing else.  Or it failed a start-up check ---
# the EMIO tally, an IDENT that is not its own --- which is deterministic too
# and is just as worth printing.  Or it ran and then died, which is the only
# case where a second run would really run, and it is bounded here: the second
# run is put in the background and killed by its own PID a moment later.  By
# PID and never by pattern, which is this project's standing rule.
#
# **WHAT IT COSTS: ONE SECOND A PROGRAM, AND THE BOARD HAS FIVE.**  There is no
# shorter honest moment.  A refusal is immediate but `start-stop-daemon`
# returns as soon as it has forked, before the child has read a single flag, so
# looking at once would find every program alive including the ones about to
# die.  A whole second is also the only interval a POSIX `sleep` is sure to
# take --- fractions are an extension, and one that works on the build host and
# not on the board would be a check that holds nothing where it matters.  Five
# seconds on a board that reaches a login in fifteen, against a class of
# failure that has already cost this project a night: the Chaosnet script
# alone already waits up to thirty for the network.
#
# THE CONTRACT.
#
#   cadr_daemon PROG PIDFILE ARG...
#       Print `Starting <name>: `, start PROG as a daemon with ARG..., and
#       print OK when it is still running a moment later.  Otherwise print
#       FAIL and then, on lines of their own, what the program says when it is
#       run again --- or that it died at start and said nothing.  Returns 0
#       when it is running and 1 when it is not, so a caller may do more.
#
# `cadr_daemon_alive` and `cadr_daemon_why` are its two halves and are not for
# calling from anywhere else.
#
# It is sourced beside `fpgarc.sh`, which is what hands each program the flags
# it owns out of the card's one file.  The two go together: that file decides
# what a program is given and this one makes sure a program that will not take
# it says so where somebody is looking.

# A moment, then the process the pid file names.  The pid file is
# start-stop-daemon's own, written by -m, so an empty or absent one is itself
# an answer: nothing was started.
cadr_daemon_alive() {
	sleep 1
	_cadr_p=$(cat "$1" 2>/dev/null) || return 1
	[ -n "$_cadr_p" ] || return 1
	kill -0 "$_cadr_p" 2>/dev/null
}

# What the program says, run once more with the same words.  Its own lines
# already carry its own name in front of them, so they are printed as they
# come; a program that says nothing at all gets a line from here instead,
# because "it is not running" with no reason is still worth more than OK.
cadr_daemon_why() {
	_cadr_prog=$1
	_cadr_name=$(basename "$_cadr_prog")
	# Beside the pid file, because that directory is writable by definition
	# --- start-stop-daemon has just written a pid file into it --- and
	# because a fixed /tmp would be one more place a board and a check
	# could differ.
	_cadr_said=$2.why
	shift 2
	rm -f "$_cadr_said"
	"$_cadr_prog" "$@" > "$_cadr_said" 2>&1 &
	_cadr_again=$!
	sleep 1
	if kill -0 "$_cadr_again" 2>/dev/null; then
		# It did not refuse anything this time: whatever took the first
		# one is not in the words.  Take this one back down --- by PID,
		# which is the only pattern-free way --- and say so.
		# Killed and not waited for.  A program that ignored the signal
		# would hold a `wait` for ever, and an init step that can hang
		# the boot is worse than the silence this whole file is about.
		kill "$_cadr_again" 2>/dev/null
		echo "$_cadr_name: it died at start, and started when it was run again:" \
		     "the flags are not what stopped it"
	elif [ -s "$_cadr_said" ]; then
		cat "$_cadr_said"
	else
		echo "$_cadr_name: died at start and said nothing"
	fi
	rm -f "$_cadr_said"
}

cadr_daemon() {
	_cadr_prog=$1
	_cadr_pidfile=$2
	shift 2
	printf "Starting %s: " "$(basename "$_cadr_prog")"
	if ! start-stop-daemon -S -q -b -m -p "$_cadr_pidfile" \
	     --exec "$_cadr_prog" -- "$@"; then
		echo "FAIL"
		cadr_daemon_why "$_cadr_prog" "$_cadr_pidfile" "$@"
		return 1
	fi
	if cadr_daemon_alive "$_cadr_pidfile"; then
		echo "OK"
		return 0
	fi
	echo "FAIL"
	cadr_daemon_why "$_cadr_prog" "$_cadr_pidfile" "$@"
	return 1
}
