#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The init script's own check: does S87cadr-chaosnet wait for the network
# before it starts the program, and does it stop waiting?
#
# **WHY THERE IS A CHECK HERE AT ALL.**  cadr-chaosnet resolves every peer's
# name once, at the start, and refuses a name that has no address --- which is
# muir's behavior and is right: a name with no address is a refusal at the
# start rather than a peer that is never reached.  The init script runs during
# init, and on this image the DHCP client backgrounds itself when no lease is
# there at once, so `ifup -a` returns OK with the interface still bare and the
# link comes up seconds later.  The program was therefore started before the
# resolver could answer, printed its refusal and exited, while the init script
# printed OK and left a pid file.  Measured on the board on two boots.  The
# fix is a bounded wait in the script; this is what holds it.
#
# **IT RUNS THE REAL SCRIPT, not a copy of its logic.**  Two words in it are
# rewritten --- where the settings file lives, and how long the wait is --- and
# each rewrite is asserted to have matched exactly once, so renaming either
# constant fails this check by name instead of quietly testing nothing.  That
# is `mutations/list.txt`'s anchor discipline borrowed for a shell script.
#
# `ip`, `nslookup` and `start-stop-daemon` are stubs on the PATH that record
# what they were asked and answer what the case wants.  The stub `ip` prints
# nothing and exits 0 when there is no address, which is what the real one
# does --- an exit status would be the easier thing to fake and would not be
# this image's behavior.
#
# **WHAT THIS CANNOT DO: aim a mutation record at the script.**  mutate.py
# copies C sources into a directory of its own and compiles one binary, so its
# `@file` is one of this package's core sources and a record naming a shell
# script would be BROKEN by construction.  Making that possible means a second
# kind of record with its own build and run, which is a change to the runner
# and not to this package.  Until then the evidence that this check can fail
# is that it was written against the unfixed script and did.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../S87cadr-chaosnet"
# The shared reader the script sources.  It is cadr-common's and it is
# installed at /usr/share/cadr/fpgarc.sh on the board; here it is the file in
# the sibling package, and the script's constant for it is rewritten below
# like the other two.  Its own check is that package's fpgarc_test.sh; what
# this file holds is that THIS script gets its own flags out of the one file
# and waits for the network before it passes them on.
STARTER="$HERE/../../cadr-common/src/daemon.sh"
READER="$HERE/../../cadr-common/src/fpgarc.sh"
WORK=${WORK:-$HOME/.cache/muir-fpga-chaosnet-boot-$$}
fails=0
cases=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

fail() {
	echo "FAIL: $*"
	fails=$((fails + 1))
}

ok() {
	echo "  ok: $*"
}

# One case's sandbox: a settings file, a stub PATH, and a copy of the script
# with the two constants rewritten.  $1 is the bound in seconds.
setup() {
	rm -rf "$WORK"
	mkdir -p "$WORK/bin" "$WORK/card" "$WORK/run"
	: > "$WORK/ip.calls"
	: > "$WORK/nslookup.calls"
	: > "$WORK/daemon.calls"

	# The two rewrites, each asserted to have matched exactly once.  A
	# constant that is renamed or moved fails here rather than leaving a
	# check that runs against /mnt/card and waits thirty seconds.
	cp "$SCRIPT" "$WORK/S87"
	chmod +x "$WORK/S87"
	anchor "^CARD=/mnt/card\$" "CARD=$WORK/card" || return 1
	anchor "^WAIT_SECONDS=30\$" "WAIT_SECONDS=$1" || return 1
	anchor "^FPGARC_SH=/usr/share/cadr/fpgarc.sh\$" "FPGARC_SH=$READER" || return 1
	# The daemon starter, cadr-common's other shell file: the script sources
	# it, so without this rewrite the copy dies at that line and every case
	# below reports that the program was never started.
	anchor "^DAEMON_SH=/usr/share/cadr/daemon.sh\$" "DAEMON_SH=$STARTER" || return 1
	# The program and its pid file.  `cadr_daemon` really looks for the
	# process it started, so the stand-in below has to be what is started
	# and /var/run is not this check's to write in.
	anchor "^PROG=/usr/bin/cadr-chaosnet\$" "PROG=$WORK/bin/cadr-chaosnet" || return 1
	anchor "^PIDFILE=/var/run/cadr-chaosnet.pid\$" "PIDFILE=$WORK/run/cadr-chaosnet.pid" \
		|| return 1
	return 0
}

anchor() {
	n=$(grep -c "$1" "$WORK/S87" 2>/dev/null || true)
	if [ "$n" != "1" ]; then
		fail "the anchor $1 matches $n times in S87cadr-chaosnet, not once:" \
		     "this check has rotted against the script it is for"
		return 1
	fi
	sed -i "s|$1|$2|" "$WORK/S87"
	return 0
}

# The stubs.  $1 is how many address probes answer "nothing here yet"; -1 is
# "never ready".  $2 is the nslookup verdict, "yes" or "no".
stubs() {
	cat > "$WORK/bin/ip" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/ip.calls"
case "\$*" in
*addr*)
	n=\$(grep -c addr "$WORK/ip.calls")
	if [ "$1" = "-1" ] || [ "\$n" -le "$1" ]; then exit 0; fi
	echo "2: eth0    inet 192.0.2.17/24 brd 192.0.2.255 scope global eth0"
	;;
*route*)
	echo "default via 192.0.2.1 dev eth0"
	echo "192.0.2.0/24 dev eth0 scope link"
	;;
esac
exit 0
EOF
	cat > "$WORK/bin/nslookup" <<EOF
#!/bin/sh
for a; do
	case "\$a" in
	-*) ;;
	*) echo "\$a" >> "$WORK/nslookup.calls" ;;
	esac
done
[ "$2" = yes ]
EOF
	# **THE REAL ONE FORKS THE PROGRAM AND CLOSES ITS OUTPUT.**  This does
	# the same, because `cadr_daemon` looks for the process a moment after
	# starting it and a stub that only recorded would leave every case here
	# reporting a program that died.  What the refusal is worth is
	# `fpgarc_test.sh`'s to hold; this only has to let the wait be checked.
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
	cat > "$WORK/bin/cadr-chaosnet" <<EOF
#!/bin/sh
exec sleep 8
EOF
	chmod +x "$WORK/bin/ip" "$WORK/bin/nslookup" "$WORK/bin/start-stop-daemon" \
		"$WORK/bin/cadr-chaosnet"
}

run_start() {
	rm -f "$WORK"/run/*.pid "$WORK"/run/*.pid.why
	# Where the reader remembers what this script claimed.  /var/run
	# belongs to the board; the reader takes this from the environment.
	FPGARC_CLAIMED="$WORK/run/claimed" \
	PATH="$WORK/bin:$PATH" "$WORK/S87" start > "$WORK/out" 2>&1
	echo "$?" > "$WORK/status"
}

says() {
	if grep -q "$1" "$WORK/out"; then
		ok "the console says $1"
	else
		fail "the console does not say $1; it says:"
		sed 's/^/        /' "$WORK/out"
	fi
}

says_not() {
	if grep -q "$1" "$WORK/out"; then
		fail "the console says $1 and should not; it says:"
		sed 's/^/        /' "$WORK/out"
	else
		ok "the console does not say $1"
	fi
}

started() {
	if [ -s "$WORK/daemon.calls" ]; then
		ok "the program was started"
	else
		fail "the program was never started"
	fi
}

passes_flag() {
	if grep -q -- "$1" "$WORK/daemon.calls"; then
		ok "the program was given $1"
	else
		fail "the program was not given $1; it was given:"
		sed 's/^/        /' "$WORK/daemon.calls"
	fi
}

resolved() {
	if grep -qx "$1" "$WORK/nslookup.calls"; then
		ok "$1 was looked up"
	else
		fail "$1 was never looked up; what was: $(tr '\n' ' ' < "$WORK/nslookup.calls")"
	fi
}

no_lookups() {
	if [ -s "$WORK/nslookup.calls" ]; then
		fail "the resolver was asked about $(tr '\n' ' ' < "$WORK/nslookup.calls")" \
		     "and there is no name in these flags"
	else
		ok "the resolver was not asked about anything"
	fi
}

probes() {
	n=$(grep -c addr "$WORK/ip.calls" 2>/dev/null || true)
	[ -n "$n" ] || n=0
	if [ "$n" -ge "$1" ]; then
		ok "it probed the interface $n times, wanting at least $1"
	else
		fail "it probed the interface $n times, wanting at least $1: it did not wait"
	fi
}

case_head() {
	cases=$((cases + 1))
	echo "case $cases: $*"
}

# ---------------------------------------------------------------------------
# 1.  The board's own fault: the address arrives late.  The script must wait
#     for it, say so, and then start the program with the flags unchanged.
# ---------------------------------------------------------------------------
case_head "the address arrives late, so it waits and then starts"
setup 30 && {
	stubs 2 yes
	cat > "$WORK/card/fpgarc" <<'RC'
# a station on the development network
--chaos-address 3050
--chaos-udp 0.0.0.0:42042
--chaos-udp-peer 3060@a-host.invalid:42043
--chaos-udp-default-peer a-bridge.invalid:42042
RC
	run_start
	says "waiting up to .* for the network"
	says "no address"
	says "the network is ready after"
	probes 3
	started
	passes_flag "--chaos-address 3050"
	passes_flag "--chaos-udp-peer 3060@a-host.invalid:42043"
	# **BOTH LOGS, WHICH ARE `cadr_daemon`'s AND NOT THIS SCRIPT'S.**  The
	# console for whoever is watching the boot and a file for whoever has
	# only ssh; this program is the one the silent refusal was measured on,
	# and the file is where its refusal can be read afterwards.
	passes_flag "--log /dev/console"
	passes_flag "--log /var/log/cadr-chaosnet.log"
	resolved "a-host.invalid"
	resolved "a-bridge.invalid"
}

# ---------------------------------------------------------------------------
# 2.  Every peer named by address.  There is nothing for a resolver to answer,
#     so it must not be asked --- and a default peer that is only digits is a
#     port on the loopback, which is the program's own rule and names no host.
# ---------------------------------------------------------------------------
case_head "peers named by address, so the resolver is never asked"
setup 30 && {
	stubs 0 no
	cat > "$WORK/card/fpgarc" <<'RC'
--chaos-address 3050
--chaos-udp 0.0.0.0:42042
--chaos-udp-peer 3060@192.0.2.9:42043
--chaos-udp-default-peer 192.0.2.1
RC
	run_start
	no_lookups
	started
	says_not "still not ready"
}

case_head "a default peer that is a bare port names no host"
setup 30 && {
	stubs 0 no
	cat > "$WORK/card/fpgarc" <<'RC'
--chaos-address 3050
--chaos-udp 0.0.0.0:42042
--chaos-udp-default-peer 42043
RC
	run_start
	no_lookups
	started
}

case_head "a peer line with its endpoint missing is not a name"
setup 2 && {
	stubs 0 no
	cat > "$WORK/card/fpgarc" <<'RC'
--chaos-address 3050
--chaos-udp 0.0.0.0:42042
--chaos-udp-peer
--chaos-trace
RC
	run_start
	no_lookups
	started
	says_not "still not ready"
}

# ---------------------------------------------------------------------------
# 3.  The network never comes.  The wait is bounded: it must give up, say what
#     it was waiting for and how long it waited, and start the program anyway
#     --- so that the program's own refusal is what reaches the console.
# ---------------------------------------------------------------------------
case_head "the network never comes, so the bound expires and it starts anyway"
setup 2 && {
	stubs -1 yes
	cat > "$WORK/card/fpgarc" <<'RC'
--chaos-address 3050
--chaos-udp 0.0.0.0:42042
--chaos-udp-peer 3060@a-host.invalid:42043
RC
	run_start
	says "waiting up to .* for the network"
	says "still not ready after"
	says "starting anyway"
	probes 2
	started
}

# ---------------------------------------------------------------------------
# 4.  The address and the route are there and the resolver is not.  That is
#     the condition the program actually dies of, so it must hold the wait by
#     itself, and the reason must name the host rather than the network.
# ---------------------------------------------------------------------------
case_head "the resolver alone holds the wait, and the reason names the host"
setup 2 && {
	stubs 0 no
	cat > "$WORK/card/fpgarc" <<'RC'
--chaos-address 3050
--chaos-udp 0.0.0.0:42042
--chaos-udp-peer 3060@a-host.invalid:42043
RC
	run_start
	says "waiting up to .* for the network"
	says "a-host.invalid"
	says "still not ready after"
	started
	resolved "a-host.invalid"
}

# ---------------------------------------------------------------------------
# 4b. The settings file serves the whole board, not this program.  The screen,
#     the serial line, the USB input and the boot button take their own flags
#     out of the same file, and this program refuses a flag it does not know,
#     so it must be handed its own lines and nothing else.  It must also not
#     go looking for a resolver on the strength of somebody else's line.
# ---------------------------------------------------------------------------
case_head "the file is the whole board's, and this program gets only its own flags"
setup 2 && {
	stubs 0 yes
	cat > "$WORK/card/fpgarc" <<'RC'
--chaos-address 3050
--chaos-udp 0.0.0.0:42042
--keyboard-mapping /mnt/card/keys.txt
--usb-scan-ms 500
--poll-us 250
--no-auto-boot
RC
	run_start
	started
	passes_flag "--chaos-address 3050"
	no_lookups
	for stray in --keyboard-mapping --usb-scan-ms --poll-us --no-auto-boot; do
		if grep -q -- "$stray" "$WORK/daemon.calls"; then
			fail "cadr-chaosnet was given $stray, which is another program's:" \
			     "$(cat "$WORK/daemon.calls")"
		else
			ok "cadr-chaosnet was not given $stray"
		fi
	done
}

# ---------------------------------------------------------------------------
# 5.  No settings file at all: the defaults, no peers, and nothing to resolve.
#     A board with no card still starts its cable.
# ---------------------------------------------------------------------------
case_head "no settings file, so the defaults and no names"
setup 2 && {
	stubs 0 yes
	rm -f "$WORK/card/fpgarc"
	run_start
	no_lookups
	started
	passes_flag "--chaos-address 3050"
}

echo
if [ "$fails" = 0 ]; then
	echo "chaosnet boot: $cases cases, the init script waits for the network and stops waiting"
	exit 0
fi
echo "chaosnet boot: $fails failures in $cases cases"
exit 1
