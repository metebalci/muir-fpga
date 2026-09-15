// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// cadr-usb-input: a USB keyboard and mouse plugged into the board, carried to
// the CADR's own keyboard and mouse.
//
// WHAT IT IS.  The processing system has a USB host port and Linux drives it,
// so a keyboard plugged into the board appears as `/dev/input/event*`.  The
// CADR's keyboard and mouse are the I/O board's cables, reached through the
// fourth page of `M_AXI_GP0`.  This program is the road between them, and with
// it the machine can be used AT the board rather than only through a viewer on
// another machine.
//
// **IT DOES NOT WRITE THE REGISTERS.**  `cadr-terminal` does, and this sends
// it keysyms and mouse movement over a local socket.  The reason is the whole
// of `cadr/cadr_input_link.h`: the face has one queue, how fast words may be
// handed to it is a rule about the MACHINE, and a rule like that needs one
// pacer.  Two programs each obeying it would give the machine words twice as
// fast as either meant.  It is also muir's own arrangement --- one `Keyboard`,
// one `Mouse`, up to eight viewers pushing into them --- and it keeps the
// mapping in one place, so that one `--keyboard-mapping` file serves a viewer
// and a keyboard at the board alike.  docs/usb-input.md has the decision and
// the two shapes that were not taken.
//
// HOW IT RUNS.  `S88cadr-usb-input` starts it at boot with
// its two logs --- the console and a file --- after the terminal's `S85`.  In order:
//
//   1. THE LINK.  It connects to the socket the terminal listens on and
//      exchanges a greeting, which is what tells the terminal from anything
//      else that might be at that path.  A terminal that has not started yet
//      is not an error: it tries again at every scan and says so ONCE.
//   2. THE DEVICES.  `/dev/input` is looked in for `event*` nodes, each is
//      asked what it reports, and a keyboard or a mouse is opened and
//      DRAINED --- the kernel buffers events for a node nobody has open, and a
//      keystroke from before this program started would otherwise reach a
//      machine that is deciding whether to cold-boot.
//   3. THE LOOP.  Wait on the devices and the link; turn what a device sends
//      into records; send them.  Look for devices that came or went every
//      `--scan-ms`.
//
// **IT REACHES NO GP PORT AND MAPS NO MEMORY.**  Everything it touches is a
// device node and a socket, so it needs no /dev/mem, no guard and no
// bitstream: on a board whose fabric has no input cables the terminal says so
// and refuses the link, and this program says the link is not there.
//
//     cadr-usb-input [--link PATH] [--device PATH]... [--input-dir DIR]
//                    [--scan-ms N] [--grab] [--no-keyboard] [--no-mouse]
//                    [--trace] [--log PATH]... [--once]
//
// **WHAT EACH KEY BECAME, WHILE SOMEBODY IS WATCHING.**  `--usb-trace` writes
// a line for every key event: the device, the key code as the kernel names
// it, the level this program chose, and the keysym that crossed the link ---
// or that the code is not in the table.  It is `evtest` and the mapping in
// one line, and it is the near half of the road whose far half is
// `cadr-terminal --keyboard-mapping-trace`.  OFF by default, and not only a
// flag: `SIGUSR1` turns it on and `SIGUSR2` turns it off while the program
// runs, which is what `cadr-console trace-keys on` sends.  The mouse is not
// traced; `usb_keys.h` says why.
//
// Every flag also has a `--usb-` spelling, so that these can live in the
// card's `fpgarc` beside the Chaosnet's without two files --- `cadr-chaosnet`
// takes `--udp-peer` and `--chaos-udp-peer` for the same reason.
// docs/usb-input.md says what is still open about one file serving several
// programs.

#include <errno.h>
#include <getopt.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <cadr/cadr_input_link.h>
#include <cadr/cadr_log.h>

#include "usb_devices.h"
#include "usb_keys.h"

#define USB_MAX_NAMED 8

static volatile sig_atomic_t stopping;
static void on_stop(int sig)
{
	(void)sig;
	stopping = 1;
}

static uint64_t monotonic_ms(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (uint64_t)t.tv_sec * 1000u + (uint64_t)t.tv_nsec / 1000000u;
}

// The link, as the devices see it.  A record that will not go is COUNTED and
// not retried: the link is remade instead, because half a record in front of
// the next one is worse than a keystroke lost, and the far end releases what
// this program was holding when the connection goes.
struct sender {
	struct cadr_input_link_client link;
	unsigned long sent, dropped;
	int broken;
};

static void send_event(void *ctx, const struct cadr_input_event *e)
{
	struct sender *s = ctx;
	// **NOTHING GOES BEFORE THE GREETING HAS BEEN ANSWERED.**  The answer
	// is the only thing that tells the machine's terminal from whatever
	// else might be listening at that path.  A record with nowhere to go
	// is counted and dropped; the devices go on being read, so the keys
	// the kernel is holding do not pile up behind a link that is down.
	if (s->link.fd < 0 || !s->link.greeted || s->broken) {
		++s->dropped;
		return;
	}
	if (cadr_input_link_send(&s->link, e) < 0) {
		s->broken = 1;
		++s->dropped;
		say("the link would not take a record (%s); it will be made again",
		    strerror(errno));
		return;
	}
	++s->sent;
}

static void usage(void)
{
	fprintf(stderr,
		"usage: cadr-usb-input [options]\n"
		"  --link PATH       the socket cadr-terminal listens on (default %s)\n"
		"  --device PATH     one device to read, repeatable; with none, --input-dir\n"
		"                    is looked in for what is there\n"
		"  --input-dir DIR   where the evdev nodes are (default /dev/input)\n"
		"  --scan-ms N       how often to look for a device that came or went (default 1000)\n"
		"  --grab            take the devices exclusively, so nothing else on the board\n"
		"                    sees the keys\n"
		"  --no-keyboard     ignore keyboards\n"
		"  --no-mouse        ignore mice\n"
		"  --trace           a line for every key event: the device, the code as the\n"
		"                    kernel names it, the level, and the keysym it became --- or\n"
		"                    that the code is not in the table. The mouse is not traced.\n"
		"                    SIGUSR1 turns it on while the program runs and SIGUSR2 turns\n"
		"                    it off, which is `cadr-console trace-keys on|off`\n"
		"  --log PATH        where to write; may be given more than once, and every\n"
		"                    line then goes to every destination named.  With none,\n"
		"                    stdout.  A destination that is a file is capped at 1 MiB\n"
		"                    and rotated to <name>.1 (the root filesystem is a RAM disk)\n"
		"  --once            find the devices, say what is there, and exit\n"
		"\n"
		"Every flag also has a --usb- spelling, for the card's fpgarc.\n",
		CADR_INPUT_LINK_PATH);
}

int main(int argc, char **argv)
{
	const char *link_path = CADR_INPUT_LINK_PATH;
	const char *input_dir = "/dev/input";
	const char *named[USB_MAX_NAMED];
	unsigned names = 0;
	unsigned scan_ms = 1000;
	int grab = 0, no_keyboard = 0, no_mouse = 0, once = 0, trace = 0;
	static const struct option opts[] = {
		{ "link", required_argument, NULL, 'L' },
		{ "usb-link", required_argument, NULL, 'L' },
		{ "device", required_argument, NULL, 'd' },
		{ "usb-device", required_argument, NULL, 'd' },
		{ "input-dir", required_argument, NULL, 'D' },
		{ "usb-input-dir", required_argument, NULL, 'D' },
		{ "scan-ms", required_argument, NULL, 's' },
		{ "usb-scan-ms", required_argument, NULL, 's' },
		{ "grab", no_argument, NULL, 'g' },
		{ "usb-grab", no_argument, NULL, 'g' },
		{ "no-keyboard", no_argument, NULL, 'K' },
		{ "usb-no-keyboard", no_argument, NULL, 'K' },
		{ "no-mouse", no_argument, NULL, 'M' },
		{ "usb-no-mouse", no_argument, NULL, 'M' },
		{ "trace", no_argument, NULL, 'T' },
		{ "usb-trace", no_argument, NULL, 'T' },
		{ "log", required_argument, NULL, 'l' },
		{ "once", no_argument, NULL, 'o' },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};
	int c;
	while ((c = getopt_long(argc, argv, "L:d:D:s:gKMTl:oh", opts, NULL)) != -1) {
		switch (c) {
		case 'L': link_path = optarg; break;
		case 'd':
			if (names >= USB_MAX_NAMED) {
				fprintf(stderr, "cadr-usb-input: more than %u devices named\n",
					USB_MAX_NAMED);
				return 2;
			}
			named[names++] = optarg;
			break;
		case 'D': input_dir = optarg; break;
		case 's': scan_ms = (unsigned)strtoul(optarg, NULL, 0); break;
		case 'g': grab = 1; break;
		case 'K': no_keyboard = 1; break;
		case 'M': no_mouse = 1; break;
		case 'T': trace = 1; break;
		case 'l': cadr_log_dest(optarg); break;
		case 'o': once = 1; break;
		default: usage(); return 2;
		}
	}
	// A zero interval would make the loop a busy wait, and there is
	// nothing to be gained by looking for a keyboard a thousand times a
	// second.
	if (scan_ms == 0)
		scan_ms = 1;
	if (no_keyboard && no_mouse) {
		fprintf(stderr, "cadr-usb-input: --no-keyboard and --no-mouse together "
				"leave nothing to read\n");
		return 2;
	}
	if (cadr_log_open("cadr-usb-input: ") < 0)
		return 2;

	struct usb_set set;
	usb_set_init(&set);
	set.grab = grab;
	set.want_keyboard = !no_keyboard;
	set.want_mouse = !no_mouse;
	usb_set_traced(&set, trace);
	if (trace)
		say("--usb-trace: every key event and what became of it is a line here. "
		    "SIGUSR2 turns it off");

	struct sender out_ctx;
	memset(&out_ctx, 0, sizeof out_ctx);
	out_ctx.link.fd = -1;
	const struct usb_out out = { .event = send_event, .ctx = &out_ctx };

	if (names) {
		for (unsigned k = 0; k < names; ++k)
			usb_set_open(&set, named[k]);
		if (!set.devices) {
			say("none of the %u devices named is a keyboard or a mouse", names);
			return 1;
		}
	} else {
		usb_set_scan(&set, input_dir);
		if (!set.devices)
			say("no keyboard or mouse in %s yet; looking every %u ms",
			    input_dir, scan_ms);
	}
	if (once) {
		say("%u devices", set.devices);
		usb_set_close(&set, NULL);
		return set.devices ? 0 : 1;
	}

	signal(SIGTERM, on_stop);
	signal(SIGINT, on_stop);
	signal(SIGPIPE, SIG_IGN);
	// **AND THE TWO THAT SWITCH THE TRACE WHILE THIS RUNS.**
	// `usb_devices.c` installs them and `usb_trace_apply` below acts on
	// what they asked for, once a pass, where `say` is allowed.
	usb_trace_signals();

	uint64_t next_scan = monotonic_ms() + scan_ms;
	int said_no_link = 0;
	unsigned long said_sent = 0;
	uint64_t last_said = monotonic_ms();

	while (!stopping) {
		const uint64_t now = monotonic_ms();
		// What SIGUSR1 or SIGUSR2 asked for, if either did: acted on
		// here rather than in the handler, and said once when it
		// changes.
		usb_trace_apply(&set);

		// The link, made or made again.  **A TERMINAL THAT IS NOT
		// THERE IS NOT AN ERROR**: this program is started at boot and
		// may be started before, or beside, the one it talks to, and a
		// line a second about it would be the whole console.  So it is
		// said once and again only when something changes.
		if (out_ctx.broken) {
			cadr_input_link_shut(&out_ctx.link);
			// What the devices hold is forgotten and NOT sent: the
			// far end released those keys when the connection went,
			// so sending them again would be a release for a key it
			// does not think is down, and keeping them would make
			// the next press look like a repeat.
			usb_set_release_all(&set, NULL);
			out_ctx.broken = 0;
			said_no_link = 0;
		}
		if (out_ctx.link.fd < 0) {
			const char *why = NULL;
			if (cadr_input_link_open(&out_ctx.link, link_path, &why) < 0
			    && !said_no_link) {
				say("%s is not answering (%s); trying every %u ms. Is "
				    "cadr-terminal running, and does its bitstream have the "
				    "I/O board's input cables?", link_path, why, scan_ms);
				said_no_link = 1;
			}
		} else if (!out_ctx.link.greeted) {
			const char *why = NULL;
			const int got = cadr_input_link_greet(&out_ctx.link, &why);
			if (got > 0) {
				say("attached to %s: keys and mouse movement go to the machine "
				    "through cadr-terminal, which paces them", link_path);
				said_no_link = 0;
			} else if (got < 0) {
				if (!said_no_link) {
					say("%s did not answer as this link (%s); trying again",
					    link_path, why);
					said_no_link = 1;
				}
				out_ctx.broken = 1;
			}
		}

		if (now >= next_scan) {
			if (!names)
				usb_set_scan(&set, input_dir);
			next_scan = now + scan_ms;
		}

		struct pollfd fds[USB_MAX_DEVICES + 1];
		unsigned n = usb_set_pollfds(&set, fds, USB_MAX_DEVICES);
		const unsigned link_at = n;
		if (out_ctx.link.fd >= 0) {
			fds[n].fd = out_ctx.link.fd;
			// Nothing is expected FROM the link.  What this is
			// waiting for is the far end going away, which arrives
			// as a hang-up or as a read of nothing.
			fds[n].events = POLLIN;
			fds[n].revents = 0;
			++n;
		}
		int wait_ms = (int)(next_scan > now ? next_scan - now : 1);
		if (poll(fds, n, wait_ms) < 0 && errno != EINTR)
			break;
		usb_set_poll(&set, fds, link_at, &out);
		if (out_ctx.link.fd >= 0
		    && (fds[link_at].revents & (POLLIN | POLLHUP | POLLERR))) {
			if (!out_ctx.link.greeted) {
				// The answer to the greeting, which is what
				// this program is waiting for at the start.
				const char *why = NULL;
				if (cadr_input_link_greet(&out_ctx.link, &why) < 0) {
					say("%s did not answer as this link (%s); trying again",
					    link_path, why);
					out_ctx.broken = 1;
				}
			} else {
				char waste[16];
				const ssize_t got = read(out_ctx.link.fd, waste, sizeof waste);
				if (got <= 0) {
					say("the link closed; it will be made again");
					out_ctx.broken = 1;
				}
				// Anything the far end DID say is not part of
				// this protocol and is ignored rather than
				// acted on: the link is one way after the
				// greeting.
			}
		}

		if (now - last_said >= 60000u && out_ctx.sent != said_sent) {
			say("%u devices; %lu records sent, %lu dropped for want of a link; "
			    "%lu keys and %lu mouse reports; %lu devices came and %lu went",
			    set.devices, out_ctx.sent, out_ctx.dropped, set.keys, set.moves,
			    set.opened, set.gone);
			said_sent = out_ctx.sent;
			last_said = now;
		}
	}

	// **EVERY KEY THIS PROGRAM PUT DOWN COMES UP**, over the link if it is
	// still there.  A Control held when this stops is a Control held for
	// the rest of the machine's run, there being no modifier bits in a word
	// for the machine to notice with.
	usb_set_close(&set, &out);
	cadr_input_link_shut(&out_ctx.link);
	say("stopped: %lu records sent, %lu dropped; %lu keys, %lu mouse reports; "
	    "%lu devices came and %lu went",
	    out_ctx.sent, out_ctx.dropped, set.keys, set.moves, set.opened, set.gone);
	return 0;
}
