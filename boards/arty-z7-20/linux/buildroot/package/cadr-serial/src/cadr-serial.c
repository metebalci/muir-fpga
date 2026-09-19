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
// **HOW OFTEN THE PORT IS LOOKED AT, AND WHY IT NO LONGER HAS TO BEAT A
// FRAME.**  The fabric cannot wake this program: the face has an IRQ register
// but it reaches no Linux interrupt, so nothing but the poll timeout makes the
// port get read.  At MIT's own 300 baud a ten-bit frame is 33.3 ms --- which
// is why muir polls its endpoint every 33 ms and says so at `SERIAL_INTERVAL`
// --- at 9,600 baud it is 1.04 ms and at the 2651's fastest, 19,200, 521 us.
// Those are the machine's milliseconds and this timeout is the wall's, and on
// this board the two are the same: MIT's grid and the board's tick are both
// 10 ns, so the I/O board's baud-rate generator runs at real time.
//
// **THE PORT USED TO HOLD ONE CHARACTER, AND THIS INTERVAL HAD TO BEAT A
// FRAME.**  When the grid moved to 10 ns a frame at 9,600 baud became shorter
// than the 2,000 us this program waits, and the board printed "HELO AD" for
// "HELLO CADR" with DROPPED at 5; looking every 500 us still lost one burst in
// three, because Linux adds its own latency to any interval.  So the port now
// holds a thousand and twenty-four characters behind RDATA
// (`rtl/plumbing/cadr_serial_line.sv`), about a second at 9,600 baud, and
// each look takes everything waiting.  The interval only has to keep a second
// of characters from piling up, which 2,000 us does at every rate the chip has
// with three orders of magnitude to spare.  Do not shorten the frame to buy
// margin instead: its length is what MIT's own interrupt walk depends on, and
// the same file says at length what shortening it cost.  DROPPED, REFUSED and
// the deepest the port's store has been are on the status line, and a line is
// printed whenever either of the port's two losses moves.  A pass that finds
// nothing costs one register read.
//
//     cadr-serial [--serial <endpoint>] [--log PATH]... [--regs ADDR]
//                 [--poll-us N] [--no-guard] [--quiet] [--once]
//
// **WHERE THE FAR END IS OFFERED IS muir'S WORD FOR IT, `--serial`**, and it
// took over from a `--port` and a `--bind` of this program's own.  muir says
// where its serial port is reached with one flag and one word and so does
// this: a port, or address:port (`cadr/cadr_endpoint.h`).  `--port` was a word
// this program and the screen both took, and the card's one file of flags
// cannot carry a word two programs answer to, so neither could say where
// either of them listened.
//
// **THE PORT MUST BE NAMED, WHICH IS muir'S OWN RULE**: a bare address is
// refused rather than bound where nobody was told to attach.  What differs
// from muir is the two defaults, and both differences are this board's.  muir
// leaves J9 empty unless the flag is given, and a daemon has to have a number,
// so the port above stands.  And muir binds the loopback unless told
// otherwise, where this board has no terminal of its own and the line exists
// to be reached from another machine, so the default here is every interface
// --- the decision this file's own paragraph above has always carried.
// `--serial 127.0.0.1:7641` is how the loopback is asked for, and the card
// writes its endpoint out in full so that nothing rests on which default is
// which.

#include <getopt.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <cadr/cadr_endpoint.h>
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
		"  --serial <endpoint>   where the far end of the CADR's cable is offered: a\n"
		"                 port, or address:port. muir's own flag and muir's own grammar,\n"
		"                 and the port must be named (default 0.0.0.0:7641, every\n"
		"                 interface at the 2651's Unibus address 0o764160;\n"
		"                 --serial 127.0.0.1:7641 is the loopback alone)\n"
		"  --log PATH     where to write; may be given more than once, and every line\n"
		"                 then goes to every destination named.  With none, stdout.\n"
		"                 A file destination is capped at 1 MiB and rotated to\n"
		"                 <name>.1, the root filesystem being a RAM disk\n"
		"  --regs ADDR    the port's register window (default " CADR_BOARD_SERIAL_BASE_STR ")\n"
		"  --poll-us N    how often the port is looked at while idle (default 2000);\n"
		"                 the port holds 1024 characters, so this need not beat a frame\n"
		"  --no-guard     do not check " CADR_BOARD_TALLY " first\n"
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
	unsigned poll_us = 2000;
	// Where the far end is offered. The default is this board's own --- every
	// interface at the 2651's Unibus address --- and `--serial` reads muir's
	// grammar against it.
	struct cadr_endpoint listen;
	if (cadr_endpoint_parse(NULL, NULL, SER_DEFAULT_PORT, &listen) != 0)
		return 2;
	uint32_t regs_phys = SER_REG_BASE;
	int no_guard = 0, quiet = 0, once = 0;
	static const struct option opts[] = {
		{ "serial", required_argument, NULL, 's' },
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
	while ((c = getopt_long(argc, argv, "s:l:r:u:Gqoh", opts, NULL)) != -1) {
		switch (c) {
		case 's':
			// **THE PORT HAS TO BE NAMED, and that is muir's rule
			// rather than a convenience.**  Every other endpoint flag
			// has a number a person already knows to fall back on ---
			// VNC's display :0, the debug cable's 7661 --- and a serial
			// line has none, so an endpoint that does not say its port
			// is an endpoint nobody was told to attach to.  A bare
			// address parses and names no port, which is exactly the
			// spelling this refuses.
			if (cadr_endpoint_parse(optarg, NULL, SER_DEFAULT_PORT, &listen) != 0 ||
			    !listen.port_named) {
				fprintf(stderr, "cadr-serial: --serial %s: --serial wants a "
					"port or address:port: where the far end of the "
					"CADR's cable is offered\n", optarg);
				return 2;
			}
			break;
		case 'l': cadr_log_dest(optarg); break;
		case 'r':
			if (cadr_parse_u32("--regs", optarg, &regs_phys) != 0)
				return 2;
			break;
		case 'u': poll_us = (unsigned)strtoul(optarg, NULL, 0); break;
		case 'G': no_guard = 1; break;
		case 'q': quiet = 1; break;
		case 'o': once = 1; break;
		default: usage(); return 2;
		}
	}
	// **A WORD THAT IS NOT A FLAG IS REFUSED AND NOT IGNORED.**  Everything
	// this program is given comes from an init script or from the card's
	// `fpgarc`, and a word left over is a line somebody wrote that nothing
	// read --- the same failure as a flag quietly dropped, which is what the
	// reader and every one of these programs is strict to avoid.
	if (optind < argc) {
		fprintf(stderr, "cadr-serial: %s: not a flag this program takes\n", argv[optind]);
		return 2;
	}
	// A zero interval would make the loop a busy wait on both the socket
	// and the register window.
	if (poll_us == 0)
		poll_us = 1;
	if (cadr_log_open("cadr-serial: ") < 0)
		return 2;

	int mem = cadr_open_mem();
	if (mem < 0)
		return 1;
	// 1. The guard, before anything on GP0.
	if (!no_guard && cadr_guard(mem, CADR_BOARD_FACES_PORT) < 0)
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
	if (serial_endpoint_bind(&e, listen.addr[0] ? listen.addr : NULL, listen.port) < 0)
		return 1;
	e.trace = !quiet;
	// 4. The cable starts unplugged.
	serial_endpoint_start(&e, &face);
	say("the CADR's serial line is at %s:%u --- one device at a time, and a second connection "
	    "is closed as it arrives. NO AUTHENTICATION: anybody who can reach this port is the "
	    "device on the null-modem cable. The port is looked at every %u us",
	    listen.addr[0] ? listen.addr : "0.0.0.0", serial_endpoint_port(&e), poll_us);

	// 5. The loop.
	signal(SIGTERM, on_stop);
	signal(SIGINT, on_stop);
	// A device dropped mid-write must not take the program with it:
	// write(2) on a socket the far end has closed raises SIGPIPE, whose
	// default is to end the process.
	signal(SIGPIPE, SIG_IGN);
	time_t last_said = time(NULL);
	struct serial_said said = { 0 };
	(void)serial_endpoint_worth_saying(&e, &face, &said);
	while (!stopping) {
		serial_endpoint_wait(&e, poll_us);
		serial_endpoint_pump(&e, &face);
		const time_t t = time(NULL);
		// **A LINE PRINTED ONLY WHEN SOMETHING MOVED CANNOT REPORT A
		// STALL, AND THAT IS THE ONE THING WORTH REPORTING.**  The three
		// counters this used to watch all stand still when the machine
		// stops taking characters, so the run went quiet exactly when it
		// had something to say: a wedged machine never reads its receive
		// holding register, the card's TX_ROOM stays down behind it, and
		// this program refuses everything typed at it -- with the last
		// line on the console still reading "the receiver had no room 0
		// times", minutes old and looking current.  The refusal count is
		// therefore one of the things that makes a line worth printing, and
		// so are the port's own two losses, which move none of this
		// program's counters: `serial_endpoint_worth_saying` is the rule.
		if (t - last_said >= 60 && serial_endpoint_worth_saying(&e, &face, &said)) {
			say("%s; %llu characters from the machine, %llu to it; %lu attached, "
			    "%lu gone, %lu turned away; the port dropped %u of its own with its "
			    "store full (at most %u waited at once), %llu more went with a cable, "
			    "it refused %u written with no room, the receiver had no room %lu times "
			    "and the far end was too slow to read %lu times",
			    serial_endpoint_connected(&e) ? "a device is on the cable" : "nothing is attached",
			    e.from_machine, e.to_machine, e.connects, e.hangups, e.refused,
			    said.port_dropped, serial_face_deepest(&face), e.dropped_on_hangup,
			    said.port_refused, e.refused_by_receiver, e.stalled_port);
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
	    "it; the port dropped %u of its own and %llu more went with a cable, and refused %u "
	    "written with no room",
	    e.connects, e.hangups, e.from_machine, e.to_machine, serial_face_dropped(&face),
	    e.dropped_on_hangup, serial_face_refused(&face));
	serial_endpoint_close(&e);
	serial_face_close(&face);
	return 0;
}
