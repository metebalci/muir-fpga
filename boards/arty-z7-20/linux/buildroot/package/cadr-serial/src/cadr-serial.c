// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// cadr-serial: the CADR's serial line on a TCP socket.
//
// WHAT IT IS.  The Signetics 2651 at IOBSER 0A12 is in the fabric, its four
// registers at Unibus `0o764160`-`0o764166` (`sys/doc/unaddr.text`), its
// baud-rate crystal at 0A15, and the RS-232 cable out through the MC1488 at
// 0B17 and the MC1489 at 0B16 to J9.  This program is the DEVICE at the other
// end of that cable: a TCP socket, exactly as muir's `--serial <endpoint>`
// offers one.  Attach with `nc <board> 7641` or telnet.  A connection is the
// device plugging in, which raises DSR, DCD and CTS; hanging up drops them.
//
// **THE CHIP IS THE FABRIC'S AND ITS TIMING STAYS THERE.**  Nothing here
// models a baud rate or a character frame.  The machine programs the rate
// into the 2651 --- MIT's `sys/io1/serial.lisp` defaults to 300 baud, seven
// data bits and even parity --- and the fabric takes a frame's time over each
// character either way, so a burst read off the socket in one turn is still
// received one frame at a time by the machine.  This program hands characters
// over and takes the ones the port has finished sending.  Two models of one
// chip is the failure this project keeps meeting, and `serial_face.h` says so
// at the seam.
//
// HOW IT RUNS.  A DAEMON, like cadr-terminal and unlike cadr-console.  What
// it holds while nobody is attached is a listening socket and a poll of one
// register, and it is there the moment somebody wants the line.
// `S86cadr-serial` starts it.
//
// In order, before anything:
//
//   1. THE GUARD.  A read on M_AXI_GP0 that nothing in the fabric answers
//      does not fault the Arm: it hangs both cores at one PC each, measured
//      on the board.  The EMIO tally's marker bits are the one thing that can
//      be read first; `cadr/cadr_mem.h` has the argument.  `--no-guard` is
//      for a board somebody knows.
//   2. IDENT.  Word 0 reads "SERI".  "NONE" is
//      `rtl/plumbing/cadr_gp0_default.sv`'s answer, a board with a GP port
//      and nothing of ours behind it.  Either is a reason to stop and say
//      which.
//   3. THE CABLE DOWN.  The fabric's CTL at power-on is not this program's,
//      and a stale one left by a previous run would tell the machine a device
//      is on a cable that is not.
//
// **THE PORT NUMBER IS THE UNIBUS ADDRESS.**  muir gives `--serial` no
// default on purpose --- "a number here would be muir's own invention and not
// something a viewer or a convention already knows" --- but a daemon started
// by an init script has to have one.  It is taken the way the debug cable's
// 7661 is taken from DBGOUT's Unibus address `0o766100`: the 2651's first
// register is `0o764160`, so the port is 7641.
//
// **HOW OFTEN THE PORT IS LOOKED AT, AND THE ARITHMETIC FOR IT.**  The
// fabric cannot wake this program: the face has an IRQ register but it
// reaches no Linux interrupt, so nothing but the poll timeout makes the port
// get read.  A character's own frame time is what the interval has to beat.
// At MIT's own 300 baud, ten bits is 33.3 ms --- which is why muir polls its
// endpoint every 33 ms and says so at `SERIAL_INTERVAL`.  At 9,600 baud it is
// 1.04 ms and at the 2651's fastest, 19,200, it is 521 us.  The default here
// is 2,000 us, comfortable to 9,600 and not to 19,200; `--poll-us` shortens
// it, and the fabric's own DROPPED counter --- printed on every status line
// --- is what says whether it needed shortening.  A pass that finds nothing
// costs one register read.
//
//     cadr-serial [--port N] [--bind ADDR] [--log PATH] [--regs ADDR]
//                 [--poll-us N] [--no-guard] [--quiet] [--once]

#include <errno.h>
#include <getopt.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <cadr/cadr_log.h>
#include <cadr/cadr_mem.h>

#include "serial_endpoint.h"
#include "serial_face.h"

#define SER_DEFAULT_PORT 7641

static volatile sig_atomic_t stopping;

static void on_stop(int sig)
{
	(void)sig;
	stopping = 1;
}

static void usage(void)
{
	fprintf(stderr,
		"usage: cadr-serial [options]\n"
		"  --port N       the TCP port (default 7641, the 2651's Unibus address 0o764160)\n"
		"  --bind ADDR    the address to listen on (default every interface)\n"
		"  --log PATH     where to write (default stdout)\n"
		"  --regs ADDR    the port's register window (default 0x40002000)\n"
		"  --poll-us N    how often the port is looked at while idle (default 2000)\n"
		"  --no-guard     do not check the EMIO tally first\n"
		"  --quiet        do not say when a device plugs in or hangs up\n"
		"  --once         do the checks, say what the port is set to, and exit\n");
}

// What the machine has programmed, for the status line.  Nothing in this
// program acts on any of it.
static void say_settings(struct serial_face *f)
{
	const unsigned rate = serial_face_rate(f);
	const uint32_t tenths = serial_rate_tenths(rate);
	const uint32_t stat = serial_face_stat(f);
	say("the machine has the port at %u.%u baud (mode register 2 rate %u); its transmitter is "
	    "%s and its receiver is %s",
	    tenths / 10u, tenths % 10u, rate,
	    stat & SER_ST_TX_ON ? "on" : "off", stat & SER_ST_RX_ON ? "on" : "off");
}

int main(int argc, char **argv)
{
	const char *log_path = NULL, *bind_addr = NULL;
	unsigned port = SER_DEFAULT_PORT, poll_us = 2000;
	uint32_t regs_phys = SER_REG_BASE;
	int no_guard = 0, quiet = 0, once = 0;
	static const struct option opts[] = {
		{ "port", required_argument, NULL, 'p' },
		{ "bind", required_argument, NULL, 'b' },
		{ "log", required_argument, NULL, 'l' },
		{ "regs", required_argument, NULL, 'r' },
		{ "poll-us", required_argument, NULL, 'u' },
		{ "no-guard", no_argument, NULL, 'G' },
		{ "quiet", no_argument, NULL, 'q' },
		{ "once", no_argument, NULL, 'o' },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};
	int c;
	while ((c = getopt_long(argc, argv, "p:b:l:r:u:Gqoh", opts, NULL)) != -1) {
		switch (c) {
		case 'p': port = (unsigned)strtoul(optarg, NULL, 0); break;
		case 'b': bind_addr = optarg; break;
		case 'l': log_path = optarg; break;
		case 'r': regs_phys = (uint32_t)strtoul(optarg, NULL, 0); break;
		case 'u': poll_us = (unsigned)strtoul(optarg, NULL, 0); break;
		case 'G': no_guard = 1; break;
		case 'q': quiet = 1; break;
		case 'o': once = 1; break;
		default: usage(); return 2;
		}
	}
	if (port > 65535) {
		fprintf(stderr, "cadr-serial: --port %u: a port is 0 to 65535\n", port);
		return 2;
	}
	// A zero interval would make the loop a busy wait on both the socket
	// and the register window.
	if (poll_us == 0)
		poll_us = 1;
	FILE *dest = stdout;
	if (log_path) {
		dest = fopen(log_path, "a");
		if (!dest) {
			fprintf(stderr, "cadr-serial: %s: %s\n", log_path, strerror(errno));
			return 2;
		}
	}
	cadr_log_init("cadr-serial: ", dest);

	int mem = cadr_open_mem();
	if (mem < 0)
		return 1;
	// 1. The guard, before anything on GP0.
	if (!no_guard && cadr_guard(mem, "M_AXI_GP0") < 0)
		return 1;

	struct serial_face face;
	if (serial_face_open(&face, mem, regs_phys) < 0)
		return 1;
	// 2. The face is there, or nothing is.
	if (serial_face_ident(&face) < 0)
		return 1;
	say_settings(&face);
	// `--once` is a probe and writes NOTHING: it does not put the cable
	// down, because a program that only looked must not be able to change
	// what the machine sees.
	if (once)
		return 0;

	// 3. The socket.
	struct serial_endpoint e;
	if (serial_endpoint_bind(&e, bind_addr, port) < 0)
		return 1;
	e.trace = !quiet;
	// 4. The cable starts unplugged.
	serial_endpoint_start(&e, &face);
	say("the CADR's serial line is at %s:%u --- one device at a time, and a second connection "
	    "is closed as it arrives. NO AUTHENTICATION: anybody who can reach this port is the "
	    "device on the null-modem cable. The port is looked at every %u us",
	    bind_addr && *bind_addr ? bind_addr : "0.0.0.0", serial_endpoint_port(&e), poll_us);

	// 5. The loop.
	signal(SIGTERM, on_stop);
	signal(SIGINT, on_stop);
	// A device dropped mid-write must not take the program with it:
	// write(2) on a socket the far end has closed raises SIGPIPE, whose
	// default is to end the process.
	signal(SIGPIPE, SIG_IGN);
	time_t last_said = time(NULL);
	unsigned long long said_from = 0, said_to = 0;
	unsigned long said_connects = 0;
	while (!stopping) {
		serial_endpoint_wait(&e, poll_us);
		serial_endpoint_pump(&e, &face);
		const time_t t = time(NULL);
		if (t - last_said >= 60
		    && (e.from_machine != said_from || e.to_machine != said_to
			|| e.connects != said_connects)) {
			say("%s; %llu characters from the machine, %llu to it; %lu attached, "
			    "%lu gone, %lu turned away; the port dropped %u of its own, %llu more "
			    "went with a cable, the receiver had no room %lu times and the far end "
			    "was too slow to read %lu times",
			    serial_endpoint_connected(&e) ? "a device is on the cable" : "nothing is attached",
			    e.from_machine, e.to_machine, e.connects, e.hangups, e.refused,
			    serial_face_dropped(&face), e.dropped_on_hangup, e.refused_by_receiver,
			    e.stalled_port);
			said_from = e.from_machine;
			said_to = e.to_machine;
			said_connects = e.connects;
			last_said = t;
		}
	}
	// The cable goes down with the program: a machine left believing a
	// device is there would wait on a carrier that has gone.  Only if it
	// was up, so that stopping a program nobody ever attached to leaves
	// the register exactly as `serial_endpoint_start` set it.
	if (e.lines_up)
		serial_face_set_lines(&face, 0);
	say("stopped: %lu devices attached and %lu went; %llu characters from the machine, %llu to "
	    "it; the port dropped %u of its own and %llu more went with a cable",
	    e.connects, e.hangups, e.from_machine, e.to_machine, serial_face_dropped(&face),
	    e.dropped_on_hangup);
	serial_endpoint_close(&e);
	serial_face_close(&face);
	return 0;
}
