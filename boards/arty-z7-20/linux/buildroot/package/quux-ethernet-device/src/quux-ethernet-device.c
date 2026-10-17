// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// quux-ethernet-device: QUUX's Ethernet device, the Linux side.
//
//     quux-ethernet-device [--ethernet-mac XX:XX:XX:XX:XX:XX] [--ip-address A.B.C.D/N]
//                          [--ip-gateway A.B.C.D] [--ethernet-trace]
//                          [--no-guard] [--log <file>]...
//
// QUUX revision 16 moves Ethernet frames through a transmit ring and a
// receive ring in its main memory (the Ethernet contract, section 2).  The
// machine's registers are in the fabric; this program is the device's other
// half.  It sends every Ethernet frame the transmit ring names to the tap
// `quux0` and delivers every one the tap gives into the receive ring's
// buffers, through main memory in /dev/mem and the Ethernet device's page
// (`qed_face_fabric.c`), applying section 2.4 both ways: the checksums
// filled in on transmit and checked on receive, and the type filter.
// `qed_offload.h`, `qed_ring.h` and `qed_face.h` say how each is held to
// muir's own device.
//
// **THE FOUR FLAGS ARE muir's**, with muir's meaning, defaults and refusals
// (`qed_host.h`): `--ethernet-mac` is 253-254 and the address the filter
// takes besides broadcast, `--ip-address` and `--ip-gateway` are 255-257,
// and `--ethernet-trace` prints every Ethernet frame sent and received, and
// why one is refused or dropped, to this program's log.  The board's card
// gives them in `fpgarc`; the init script makes the tap at `--ip-gateway`.
//
// **IT WAITS IN poll() ON THE TAP WITH A 1 ms TIMEOUT** (section 4), which
// also paces its reads of the face: a transmit posted while the tap is quiet
// is sent within a millisecond, and a frame from the tap is taken at once.
// Every frame the tap gives while the device is disabled is read and
// discarded, so the tap never holds a frame from before an enable.
//
// **ITS LOG NAMES THE CAUSE OF EVERY REFUSAL AND DROP** (sections 2.3 and
// 2.4.5), the band's bugs, at most ten lines a second and a count of the
// rest, since the log is a file on a RAM disk.  `--ethernet-trace` says every
// frame, with no limit, and is for a person watching.

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <cadr/cadr_board.h>
#include <cadr/cadr_log.h>
#include <cadr/cadr_mem.h>

#include "qed_face.h"
#include "qed_host.h"
#include "qed_ring.h"
#include "qed_tap.h"

static volatile sig_atomic_t stopping;

static void on_signal(int sig)
{
	(void)sig;
	stopping = 1;
}

static void usage(void)
{
	fprintf(stderr,
"usage: quux-ethernet-device [--ethernet-mac XX:XX:XX:XX:XX:XX] [--ip-address A.B.C.D/N]\n"
"                            [--ip-gateway A.B.C.D] [--ethernet-trace] [--no-guard] [--log <file>]...\n"
"\n"
"  --ethernet-mac XX:XX:XX:XX:XX:XX  the device's MAC address, words 253-254, and the address\n"
"                                    its filter takes besides broadcast; not a group address\n"
"                                    [default: 02:00:00:00:00:01, locally administered]\n"
"  --ip-address A.B.C.D/N            the machine's IPv4 address and prefix length, words 255\n"
"                                    and 256; N is 1 to 30 [default: 169.254.100.2/30]\n"
"  --ip-gateway A.B.C.D              the gateway, word 257: on --ip-address's subnet, and not\n"
"                                    0.0.0.0 or the machine's own address; the tap " QED_TAP_NAME "'s\n"
"                                    address [default: 169.254.100.1]\n"
"  --ethernet-trace                  every Ethernet frame sent and received, and why one is\n"
"                                    refused or dropped, to the log\n"
"  --no-guard                        skip " CADR_BOARD_TALLY " guard.  Only for a board\n"
"                                    somebody knows to have the fabric loaded.\n"
"  --log <file>                      where to write; may be given more than once\n");
}

// The log's limit: ten lines a second, and the rest counted.
struct limited {
	time_t second;
	unsigned said, held;
};

static void say_limited(void *ctx, const char *line)
{
	struct limited *l = ctx;
	const time_t now = time(NULL);
	if (now != l->second) {
		if (l->held)
			say("and %u more refusals and drops in that second", l->held);
		l->second = now;
		l->said = l->held = 0;
	}
	if (l->said < 10) {
		say("%s", line);
		l->said++;
	} else {
		l->held++;
	}
}

static void say_trace(void *ctx, const char *line)
{
	(void)ctx;
	say("ethernet: %s", line);
}

struct tap {
	int fd;
	unsigned long lost;
	time_t said;
};

static void tap_send(void *ctx, const uint8_t *frame, size_t n)
{
	struct tap *t = ctx;
	if (write(t->fd, frame, n) == (ssize_t)n)
		return;
	// A frame the tap does not take is lost, as one on a wire may be; the
	// device has sent it and 245 has passed it.
	t->lost++;
	const time_t now = time(NULL);
	if (now != t->said) {
		say("the tap " QED_TAP_NAME " did not take a frame (%s); %lu lost so far", strerror(errno),
		    t->lost);
		t->said = now;
	}
}

int main(int argc, char **argv)
{
	int guard = 1, trace = 0;
	const char *mac = NULL, *address = NULL, *gateway = NULL;
	for (int i = 1; i < argc; ++i) {
		const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
		if (!strcmp(a, "--ethernet-mac") && v) {
			mac = argv[++i];
		} else if (!strcmp(a, "--ip-address") && v) {
			address = argv[++i];
		} else if (!strcmp(a, "--ip-gateway") && v) {
			gateway = argv[++i];
		} else if (!strcmp(a, "--ethernet-trace")) {
			trace = 1;
		} else if (!strcmp(a, "--no-guard")) {
			guard = 0;
		} else if (!strcmp(a, "--log") && v) {
			cadr_log_dest(argv[++i]);
		} else if (!strcmp(a, "--help") || !strcmp(a, "-h")) {
			usage();
			return 0;
		} else {
			usage();
			return 2;
		}
	}
	if (cadr_log_open("quux-ethernet-device: ") < 0)
		return 1;
	// 253-257: the flags', or muir's defaults, with the gateway, given or
	// not, held to the address's subnet.
	struct qed_host host;
	qed_host_default(&host);
	char why[512];
	if ((mac && qed_parse_mac(mac, host.mac, why, sizeof why))
	    || (address && qed_parse_ip_address(address, &host.address, &host.netmask, why, sizeof why))
	    || (gateway && qed_parse_ip_gateway(gateway, &host.gateway, why, sizeof why))
	    || qed_check_gateway(host.address, host.netmask, host.gateway, !gateway, why, sizeof why)) {
		say("%s", why);
		return 2;
	}

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);
	signal(SIGPIPE, SIG_IGN);

	const int fd = cadr_open_mem();
	if (fd < 0)
		return 1;
	if (guard && cadr_guard(fd, "the Ethernet device's page") != 0)
		return 1;
	struct qed_fabric fb = { 0 };
	fb.page = cadr_map(fd, CADR_BOARD_PACK_BASE + QED_FACE_OFFSET, 4096, "the Ethernet device's page");
	if (!fb.page)
		return 1;
	if (qed_fabric_attach(&fb, why, sizeof why) != 0) {
		say("%s; not started", why);
		return 1;
	}
	// Main memory: packed storage, 5 bytes a word, at QUUX's base below the
	// display (`cadr_board.h`), in a room the board keeps for so many words.
	const uint32_t base = CADR_BOARD_QUUX13_MAIN_BASE;
	if (fb.mem_words > CADR_BOARD_QUUX13_MAIN_WORDS_MAX) {
		say("the Ethernet device's page says main memory is %u words, and this board keeps room "
		    "for %u; not started", fb.mem_words, CADR_BOARD_QUUX13_MAIN_WORDS_MAX);
		return 1;
	}
	volatile void *main_mem = cadr_map(fd, base, (size_t)fb.mem_words * 5u, "the machine's main memory");
	if (!main_mem)
		return 1;
	struct tap tap = { -1, 0, 0 };
	tap.fd = qed_tap_open(QED_TAP_NAME, why, sizeof why);
	if (tap.fd < 0) {
		say("%s; not started", why);
		return 1;
	}
	struct qed_face face;
	qed_fabric_face(&fb, main_mem, &face);
	static struct limited limit;
	struct qed_ring g;
	memset(&g, 0, sizeof g);
	g.send = tap_send;
	g.send_ctx = &tap;
	g.trace = trace ? say_trace : NULL;
	g.log = say_limited;
	g.say_ctx = &limit;
	qed_ring_init(&g, &face, &host);
	char m[18], a[16], gw[16];
	qed_mac_text(host.mac, m);
	qed_ipv4_text(host.address, a);
	qed_ipv4_text(host.gateway, gw);
	say("serving the Ethernet device: revision 16, main memory %u words at 0x%08x, packed storage; "
	    "the tap %s; %s, %s/%u by %s", fb.mem_words, base, QED_TAP_NAME, m, a,
	    qed_prefix_length(host.netmask), gw);

	static uint8_t frame[65536];
	while (!stopping) {
		struct pollfd p = { tap.fd, POLLIN, 0 };
		const int ready = poll(&p, 1, 1);
		if (ready < 0 && errno != EINTR) {
			say("poll on the tap: %s; stopping", strerror(errno));
			break;
		}
		if (ready > 0 && (p.revents & (POLLERR | POLLHUP | POLLNVAL))) {
			say("the tap " QED_TAP_NAME " failed (revents 0x%x); stopping", p.revents);
			break;
		}
		// The frames the tap holds, a bounded batch, so that the
		// transmit ring is looked at between batches.
		for (int k = 0; k < 64; ++k) {
			const ssize_t n = read(tap.fd, frame, sizeof frame);
			if (n < 0) {
				if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
					say("a read of the tap: %s", strerror(errno));
				break;
			}
			qed_ring_receive(&g, &face, frame, (size_t)n);
		}
		qed_ring_transmit(&g, &face, 64);
	}
	face.release(face.ctx);
	say("stopped");
	return 0;
}
