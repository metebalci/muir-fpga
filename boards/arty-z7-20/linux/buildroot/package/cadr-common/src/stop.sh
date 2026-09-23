# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# STOPPING A DAEMON AND WAITING UNTIL IT HAS STOPPED.
#
# **THE FAULT THIS EXISTS FOR.**  `start-stop-daemon -K` sends SIGTERM and
# returns at once; it does not wait for the process to exit (measured with
# BusyBox's: a process that traps TERM and takes two seconds to leave is still
# alive when `-K` has returned 0).  So an init script that did anything after
# `-K` did it beside a program that was still running.  The one where that
# matters most is the disk pack script: cadr-disk-packs writes every dirty
# slot back to its pack when it is told to stop, and the script unmounted the
# card straight after `-K`, racing that write-back, with the unmount's refusal
# sent to /dev/null.  At a reboot the rest of the shutdown then goes on and
# the write-back can be cut off on a filesystem with no journal.  The other
# programs matter for the order too: ozd holds files open on the card, and a
# `restart` that starts a program while the old one still holds its port or
# its pid file starts nothing.
#
# **WHAT THIS DOES ABOUT IT.**  Send SIGTERM as before, then look for the
# process until it is gone or a bound has passed, and print OK only when it is
# gone.  A program still there at the bound is said, by name and PID, and
# FAIL is printed; it is not killed, because the one program here that takes
# its time is taking it to put the machine's writes on its packs, and SIGKILL
# would lose exactly those.  The caller decides what to do next.
#
# **THE LOOK IS EVERY TENTH OF A SECOND WHERE `sleep` TAKES A FRACTION, AND
# EVERY SECOND WHERE IT DOES NOT.**  `daemon.sh` gives the reason fractions are
# not relied on: they are an extension.  So one `sleep 0.1` is tried first and
# a `sleep` that refuses it is a `sleep` of whole seconds; either way the bound
# is counted in the steps actually taken and is the same number of seconds.
#
# THE CONTRACT.
#
#   cadr_stop NAME PIDFILE SECONDS
#       Print `Stopping <NAME>: `, send SIGTERM to the process PIDFILE names,
#       and wait up to SECONDS for it to exit.  Print OK and return 0 when it
#       has; print FAIL and return 1 when there was nothing to stop; print
#       FAIL, then a line naming the process, and return 2 when it is still
#       running at the bound.
#
# It is sourced beside `fpgarc.sh` and `daemon.sh`, and installed with them at
# /usr/share/cadr/.

# How long a program is given when its script names no bound of its own.  The
# programs other than the disk pack one leave at once on SIGTERM; five seconds
# is room for a loaded board, not a measured need.
CADR_STOP_SECONDS=5

cadr_stop() {
	_cadr_name=$1
	_cadr_pidfile=$2
	_cadr_bound=${3:-$CADR_STOP_SECONDS}
	printf "Stopping %s: " "$_cadr_name"
	_cadr_pid=$(cat "$_cadr_pidfile" 2>/dev/null)
	if ! start-stop-daemon -K -q -p "$_cadr_pidfile"; then
		echo "FAIL"
		return 1
	fi
	# A pid file start-stop-daemon acted on but that this shell cannot read
	# back is a process there is no way to watch; say OK as `-K` did.
	if [ -z "$_cadr_pid" ]; then
		echo "OK"
		return 0
	fi
	if sleep 0.1 2>/dev/null; then
		_cadr_step=0.1
		_cadr_steps=$((_cadr_bound * 10))
	else
		_cadr_step=1
		_cadr_steps=$_cadr_bound
	fi
	_cadr_n=0
	while kill -0 "$_cadr_pid" 2>/dev/null; do
		if [ "$_cadr_n" -ge "$_cadr_steps" ]; then
			echo "FAIL"
			echo "$_cadr_name: still running $_cadr_bound s after it was asked to stop" \
			     "(pid $_cadr_pid); it was left running"
			return 2
		fi
		sleep "$_cadr_step"
		_cadr_n=$((_cadr_n + 1))
	done
	echo "OK"
	return 0
}
