// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// cadr-chaosnet: the cable the CADR's Chaosnet interface is plugged into.
//
//     cadr-chaosnet [--chaos-address <octal>] [--chaos-udp [<endpoint>]]
//                   [--chaos-udp-peer <address>@<host>[:<port>]]
//                   [--chaos-udp-default-peer <host>[:<port>]] [--chaos-trace]
//                   [--base <hex>] [--no-guard] [--no-fabric] [--log <file>]...
//
// **WHAT THIS PROGRAM IS: THE ETHER, AND NOTHING ABOVE IT.**  The CADR's
// Chaosnet interface is in fabric --- the registers at `0o764140`-`0o764156`
// on the I/O board, held to `muir::chaos::interface` --- and this is the
// cable it is plugged into.  A frame the machine transmits comes off the
// fabric whole, with its hardware trailer and its check word on it, and goes
// out over CHUDP; a frame that arrives over CHUDP for this machine goes back
// into the fabric the same way.  That is the whole job.
//
// **THERE ARE NO SERVICES IN HERE, BECAUSE THERE ARE NONE IN A CADR.**  A
// Lisp Machine calls its **associated machine** --- MIT's term for the file
// and time server it talks to, the one the boot banner names --- for its
// files and for the date.  That server was another machine on the network and
// was never inside the CADR, so it is not inside this program either.  muir
// carried STATUS, TIME, UPTIME and FILE for a while and removed them at its
// own `79c7590`, for this reason and in these words: "A CADR has no file or
// time server in it, so muir has none either."  This program was ported from
// muir before that commit and carried them across; they are gone now, and so
// are `--chaos-file-root`, `--chaos-file-peers` and `--server-name`, which
// are refused BY NAME rather than ignored, with a line saying where the host
// went.  `metebalci/ozd` is a host that boots a band.
//
// **AND IT IS A LEAF, NOT A ROUTER**, exactly as muir is.  A packet whose
// destination is neither the machine nor a broadcast is handed to CHUDP, and
// a frame that arrived over UDP for a third party is not sent back out.
// AIM-628 chapter 6's routing is a bridge's job, and `cbridge` is the thing
// to put beside this.  **The bridge is reached as the default peer**: a peer
// entry says that one address lives at one endpoint, so naming a bridge as a
// peer does not let this board talk through it, and
// `--chaos-udp-default-peer` is where a frame goes whose destination no peer
// entry names.  A broadcast is not handed to it.  With no default peer such a
// frame is dropped and counted, which is what this program did with every one
// of them before the flag existed.
//
// ## The vocabulary is muir's
//
// **`--chaos-address` IS THE SWITCHES AND `--chaos-udp` IS THE CABLE**, which
// are two things on the board and were one flag here.  On MIT's card the
// sixteen address switches are set whether or not anything is plugged in, and
// a cable can be unplugged; so an address alone sends nothing, and the flags
// that say who is on the cable --- `--chaos-udp-peer` and
// `--chaos-udp-default-peer` --- are refused without it rather than quietly
// bringing a cable of their own.  muir split them at its `0851fa7` and the
// wording of the refusal is muir's.
//
// muir's own flags are `--chaos-address`, `--chaos-udp`, `--chaos-udp-peer`,
// `--chaos-udp-default-peer` and `--chaos-trace`.  This program IS the
// Chaosnet, so the prefix is optional here --- `--address`, `--udp` and the
// rest are accepted as well, and cost three lines --- but muir's spellings
// are the ones the card's `fpgarc` carries and the ones to write down.  The
// console already takes muir's spy names for the same reason and its own
// header says so.
//
// **`--chaos-udp-dynamic` IS GONE, as it is gone from muir.**  It learned
// where a host was from the packets it sent, which is a table nobody wrote
// down and which put the naming in the hands of whoever could reach the port.
// It is not refused by name, unlike the three file-server flags below: those
// configured a SERVICE whose silent absence would look exactly like its
// presence, and this one configured a table that is simply not kept.  An
// unknown flag prints the usage, which is muir's answer to it too.
//
// **Which address a run wants is the BAND's, and the band is asked.**  A band
// holds a host table and calls its file and time host at the address that
// table gives.  System 100's band is `MIT-LISPM-1` at 3050 and calls its file
// and time host `MIT-OZ` at 3060, so a run with that pack is
// `--chaos-address 3050` with `--chaos-udp-peer 3060@<where the host is>`.
// System 304's band is `AMS-LISPM-1` at 4401 calling 4403.  The default here
// is muir's and is deliberately no real host's: 177001, on subnet 376, which
// no host table in either release names.  `muir::chaos`'s own header has the
// whole argument.

#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <cadr/cadr_log.h>
#include <cadr/cadr_mem.h>

#include "chaos_face.h"
#include "chaos_inject.h"
#include "chaos_packet.h"
#include "chaos_udp.h"

// How long the loop sleeps when nothing happened.  A packet at a time is the
// whole traffic and the transport at the far end acknowledges every one, so
// the round trip this bounds is what a file transfer moves at: muir measures
// "some three milliseconds a packet" at that end's acknowledgment rate, and
// a millisecond of polling under that is not what limits it.  A turn that did
// something does not sleep at all.
//
// **WHAT A BURST DRAINS AT IS THE MACHINE'S PACE AND NOT THE FABRIC'S**, and
// that is `chaos_inject.c`'s doing rather than this constant's.  The frames of
// a burst are taken off the socket as fast as the socket has them, and then
// they wait their turn: the machine's incoming buffer holds one packet, so a
// frame goes when the machine has emptied it.  This sleep is the floor on how
// long a turn can be missed by, and the machine's own copy loop is about the
// same length, so it does not show.
#define IDLE_SLEEP_US 1000u

// How many frames are taken from the fabric, and from the socket, in one turn
// before the other is looked at.  Bounded so that a flood on either side
// cannot starve the other.  It is also how many frames can wait a turn for the
// machine (`CHAOS_INJECT_QUEUE`), so that a burst arriving together is never
// dropped for want of room.
#define DRAIN 64u

// How often the program says how it is getting on, when anything has moved.
#define REPORT_NS 60000000000ull

static volatile sig_atomic_t stopping;

static void on_signal(int sig)
{
	(void)sig;
	stopping = 1;
}

static uint64_t now_ns(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}

// ------------------------------------------------------------- an address
//
// `muir::chaos::parse_address`: the sixteen bits in octal, `3050`, or as
// `subnet:host` with each half in octal, `6:50`.  The two are one number ---
// the subnet is the high byte and the host the low (AIM-628) --- which octal
// digits do not show, three bits to a digit against eight to a byte; that is
// why `3050` reads as "subnet 6, host 50" only once split.
//
// **NEITHER HALF MAY BE ZERO, BECAUSE A ZERO HOST IS NOT A HOST.**  MIT's own
// description of the interface: the destination word is "the cable address of
// the destination of the packet, or 0 to broadcast it", and a receiver stores
// the next packet "addressed to this node, or is broadcast".  So `6:0` names
// every host on subnet 6 rather than one of them, and a machine configured as
// it would take the whole subnet's traffic for its own.  A zero subnet is
// refused for the same reason, which also refuses every bare octal below 400.
static int parse_address(const char *s, uint16_t *out)
{
	unsigned long a;
	char *end;
	const char *colon = strchr(s, ':');
	if (colon) {
		char subnet[16];
		const size_t n = (size_t)(colon - s);
		if (n == 0 || n >= sizeof subnet)
			return -1;
		memcpy(subnet, s, n);
		subnet[n] = '\0';
		unsigned long hi = strtoul(subnet, &end, 8);
		if (*end || hi > 0377)
			return -1;
		unsigned long lo = strtoul(colon + 1, &end, 8);
		if (*end || end == colon + 1 || lo > 0377)
			return -1;
		a = hi << 8 | lo;
	} else {
		a = strtoul(s, &end, 8);
		if (*end || end == s || a > 0177777)
			return -1;
	}
	if ((a >> 8) == 0 || (a & 0377) == 0)
		return -1;
	*out = (uint16_t)a;
	return 0;
}

// ------------------------------------------------------------- the ether

struct ether {
	struct chaos_face face;
	int have_face;
	struct chudp udp;
	int have_udp;
	// The sending station's end of the machine's buffer: a frame the buffer
	// refused waits here for a turn and is offered again, as an interface's
	// driver retries on Transmit Abort.  It carries the five counts of
	// what became of every frame headed for the machine.
	struct chaos_inject inject;
	uint16_t machine;		// the CADR's own address
	int trace;
	// The turn's own clock, read once at the top of each pass of the loop.
	// The retry wants to know how long a refused frame has been waiting,
	// and `carry` is reached from CHUDP's callback, which carries no time
	// of its own.
	uint64_t now;
	// What has gone by, for the report line and for a person wondering
	// whether anything is happening at all.
	unsigned long from_machine, from_udp, to_udp;
	unsigned long dropped_no_route, dropped_bad_frame;
};

// One frame printed as it goes by: muir's `--chaos-trace`.  This is the only
// place in the program that looks INSIDE a frame --- routing is by the cable
// destination alone, which is the hardware's own addressing --- so a frame
// that will not parse is said to be unparseable and carried anyway, exactly
// as a real cable carries it.
static void trace_frame(struct ether *e, const char *way, const uint16_t *words, unsigned n)
{
	struct chaos_frame f;
	const char *why = NULL;
	char buf[8];
	if (!e->trace)
		return;
	if (chaos_frame_parse(words, n, &f, &why) != 0) {
		say("%s: %u words that are not a packet: %s", way, n,
		    why ? why : "no reason given");
		return;
	}
	say("%s: %s %o -> %o, %u bytes, check %s", way,
	    chaos_op_name(f.packet.opcode, buf, sizeof buf),
	    f.cable_source, f.cable_dest, f.packet.len,
	    f.check_ok ? "good" : "BAD");
}

// A frame onto the machine's incoming buffer, if the fabric is there.
//
// **A REFUSAL IS THE HARDWARE'S ABORT AND THE ANSWER TO IT IS A RETRY.**  The
// machine has not read the last packet out and the interface's own Lost Count
// records the refusal (AIM-628 §7); on the cable the sender's interface would
// have read Transmit Abort and its driver would have sent the packet again
// (§2.5, §2.6).  The station that sent this frame is at the far end of a UDP
// socket and cannot, so `chaos_inject.c` stands in for its interface: the
// frame waits for a turn, goes again when the machine has emptied its buffer,
// and is given up after the three offers the CADR's own driver allows.
// Without it a burst of frames from one host delivered exactly one frame,
// however long the burst was.
//
// **A BROADCAST IS NOT RETRIED, AND THE ROUTING ABOVE DOES NOT DECIDE THAT.**
// AIM-628 §2.5's abort goes out only for a frame "specifically addressed"
// to the receiver, so a broadcast into a full buffer is counted by the
// interface and nobody is told; the rule is `chaos_inject.c`'s, which reads
// the cable destination out of the frame's own words.  `carry` hands a
// broadcast down exactly as it hands down a frame by name, because a
// broadcast does still have to be OFFERED --- what differs is only what
// happens when the buffer refuses it.
//
// **A BAD CHECK WORD IS NOT FILTERED HERE.**  The cable carries what it
// carries and the interface has a CRC Error bit for exactly this; muir's
// ether does not filter either.  A program that dropped such a frame would be
// hiding the one symptom AIM-628 §5.1 meters.
static void to_machine(struct ether *e, const uint16_t *words, unsigned n)
{
	if (!e->have_face)
		return;
	trace_frame(e, "to the machine", words, n);
	chaos_inject_give(&e->inject, &e->face, words, n, e->now);
}

// One frame off the cable, from whichever station put it there, routed by its
// CABLE destination --- which is the last word the software wrote and is the
// hardware's own addressing, not the packet header's.  A broadcast reaches
// everybody but the station it came from.
enum from { FROM_MACHINE, FROM_UDP };

static void carry(struct ether *e, enum from who, const uint16_t *words, unsigned n,
		  uint16_t cable_dest)
{
	const int broadcast = cable_dest == 0;
	const int mine = cable_dest == e->machine;

	// The one station that is on this cable.  A station never hears its
	// own frame, which is what `who` is for: the interface's receiver does
	// not store what its own transmitter put on the wire.
	if ((broadcast || mine) && who != FROM_MACHINE)
		to_machine(e, words, n);

	// And everything else, which is off the board.  **A LEAF, NOT A
	// ROUTER**: an address no peer claims is dropped and counted rather
	// than forwarded, and a frame that arrived over UDP for a third party
	// is not sent back out.
	if (!broadcast && mine)
		return;
	if (who == FROM_UDP) {
		if (!broadcast)
			++e->dropped_no_route;
		return;
	}
	trace_frame(e, "onto the network", words, n);
	const int sent = e->have_udp ? chudp_send(&e->udp, words, n, cable_dest) : 0;
	if (sent > 0)
		e->to_udp += (unsigned long)sent;
	else if (!broadcast)
		++e->dropped_no_route;
}

// What CHUDP hands up.  A datagram is already a whole frame in the seam's own
// layout, so nothing is rebuilt: this is why the hardware trailer is carried
// across `chaos_face.h` rather than stripped and remade.
static void from_udp(void *ctx, const uint16_t *words, unsigned n)
{
	struct ether *e = ctx;
	++e->from_udp;
	if (n < CHAOS_PKT_HEADER_WORDS + CHAOS_PKT_TRAILER_WORDS) {
		++e->dropped_bad_frame;
		return;
	}
	carry(e, FROM_UDP, words, n, words[n - CHAOS_PKT_TRAILER_WORDS]);
}

// ------------------------------------------------------------- the program

static void usage(void)
{
	fprintf(stderr,
"usage: cadr-chaosnet [--chaos-address <octal>] [--chaos-udp [<endpoint>]]\n"
"                     [--chaos-udp-peer <address>@<host>[:<port>]]\n"
"                     [--chaos-udp-default-peer <host>[:<port>]] [--chaos-trace]\n"
"                     [--base <hex>] [--no-guard] [--no-fabric] [--log <file>]...\n"
"\n"
"  --chaos-address <octal>      this machine's Chaosnet address, in octal or\n"
"                               subnet:host.  System 100's band wants 3050 and\n"
"                               System 304's 4401.  The default, 177001, is\n"
"                               deliberately no real host's\n"
"  --chaos-udp [<endpoint>]     the cable, plugged in: Chaosnet over UDP at\n"
"                               [<address>:]<port>, 42042 by default.  WITHOUT\n"
"                               THIS NOTHING IS SENT, whatever the address\n"
"                               switches read, as a machine with no cable\n"
"                               talks to nobody\n"
"  --chaos-udp-peer <a>@<h>[:<p>]  a station on the cable that is not on this\n"
"                               board.  The band's file and time host is one:\n"
"                               System 100 calls 3060, System 304 calls 4403.\n"
"                               It needs the cable, --chaos-udp\n"
"  --chaos-udp-default-peer <h>[:<p>]  where a frame goes whose destination no\n"
"                               --chaos-udp-peer named: the route of last\n"
"                               resort, which is what lets a cbridge beside\n"
"                               this board carry the traffic on.  An endpoint\n"
"                               and NO Chaosnet address, the frame carrying\n"
"                               the destination in its trailer for the bridge\n"
"                               to route on.  A broadcast is not sent here.\n"
"                               It needs the cable, --chaos-udp\n"
"  --chaos-trace                every frame, as it goes by, and every datagram\n"
"                               refused.  SIGUSR1 turns it on while the program\n"
"                               runs and SIGUSR2 turns it off, which is what\n"
"                               `cadr-console trace-chaos on|off` sends\n"
"  --base <hex>                 the register face's address; 0x%08x by default\n"
"  --no-guard                   skip the EMIO tally guard.  Only for a board\n"
"                               somebody knows: see <cadr/cadr_mem.h>\n"
"  --no-fabric                  no board at all --- CHUDP alone, which is how\n"
"                               this is exercised off the board\n"
"  --log <file>                 where lines go; may be given more than once, and\n"
"                               every line then goes to every destination named.\n"
"                               The init script gives it the console and a file\n"
"                               under /var/log, which is capped at 1 MiB and\n"
"                               rotated (the root filesystem is a RAM disk)\n"
"\n"
"The prefix is optional: --address, --udp, --udp-peer, --udp-default-peer and\n"
"--trace are the same flags.\n",
		CHAOS_REG_BASE);
}

// A flag that was here when this program had services in it.  Refused by name
// rather than ignored, because a boot that silently dropped `--file-root`
// would look exactly like a boot that served it.
static int gone(const char *flag)
{
	fprintf(stderr,
"cadr-chaosnet: %s is gone, and so is the service it configured.\n"
"cadr-chaosnet: A CADR has no file or time server in it, so this program has\n"
"cadr-chaosnet: none either --- muir removed its own at 79c7590 for the same\n"
"cadr-chaosnet: reason.  The host is ON THE NETWORK: give it its own Chaosnet\n"
"cadr-chaosnet: address and reach it with --chaos-udp-peer <address>@<host>.\n"
"cadr-chaosnet: A band calls the address its own host table names --- 3060 for\n"
"cadr-chaosnet: System 100, 4403 for System 304.  metebalci/ozd is a host that\n"
"cadr-chaosnet: boots a band.\n", flag);
	return 2;
}

int main(int argc, char **argv)
{
	struct ether e;
	memset(&e, 0, sizeof e);
	e.machine = 0177001;

	const char *udp_endpoint = NULL;
	uint32_t base = CHAOS_REG_BASE;
	int guard = 1, fabric = 1, want_udp = 0;
	const char *udp_peers[CHUDP_MAX_PEERS];
	unsigned nudp_peers = 0;
	const char *udp_default_peer = NULL;

	// muir's spellings are taken as well as the short ones.  `same` folds
	// the two so that the table below reads once.
	#define SAME(short_name, muir_name) \
		(!strcmp(a, short_name) || !strcmp(a, muir_name))

	for (int i = 1; i < argc; ++i) {
		const char *a = argv[i];
		const char *v = i + 1 < argc ? argv[i + 1] : NULL;
		if (SAME("--address", "--chaos-address") && v) {
			// ONE address.  It used to take `<this>,<server>`,
			// and the second half was the server inside this
			// program; there is no such thing now, so a comma is
			// an error and says why rather than being ignored.
			if (strchr(argv[++i], ',')) {
				fprintf(stderr, "cadr-chaosnet: --chaos-address takes ONE "
					"address, this machine's.\n");
				return gone("the server address after the comma");
			}
			if (parse_address(argv[i], &e.machine) != 0) {
				fprintf(stderr, "cadr-chaosnet: %s is not a Chaosnet address\n",
					argv[i]);
				return 2;
			}
		} else if (SAME("--udp", "--chaos-udp")) {
			want_udp = 1;
			// The endpoint is optional, so a following word is
			// only taken when it is not itself a flag.
			if (v && v[0] != '-')
				udp_endpoint = argv[++i];
		} else if (SAME("--udp-peer", "--chaos-udp-peer") && v) {
			if (nudp_peers == CHUDP_MAX_PEERS) {
				fprintf(stderr, "cadr-chaosnet: too many peers\n");
				return 2;
			}
			udp_peers[nudp_peers++] = argv[++i];
		} else if (SAME("--udp-default-peer", "--chaos-udp-default-peer") && v) {
			udp_default_peer = argv[++i];
		} else if (SAME("--trace", "--chaos-trace")) {
			e.trace = 1;
		} else if (SAME("--file-root", "--chaos-file-root")) {
			return gone(a);
		} else if (SAME("--file-peers", "--chaos-file-peers")) {
			return gone(a);
		} else if (!strcmp(a, "--server-name")) {
			return gone(a);
		} else if (!strcmp(a, "--time")) {
			return gone(a);
		} else if (!strcmp(a, "--base") && v) {
			base = (uint32_t)strtoul(argv[++i], NULL, 0);
		} else if (!strcmp(a, "--no-guard")) {
			guard = 0;
		} else if (!strcmp(a, "--no-fabric")) {
			fabric = 0;
		} else if (!strcmp(a, "--log") && v) {
			cadr_log_dest(argv[++i]);
		} else {
			usage();
			return 2;
		}
	}
	#undef SAME

	// **THE FLAGS THAT DESCRIBE WHAT IS ON THE CABLE DESCRIBE ONE THAT HAS
	// TO BE THERE.**  They used to ask for the cable themselves, so a run
	// that said who its file host was found itself on a network it had not
	// asked for, listening on a port nobody had named.  muir separated the
	// two at `0851fa7` and this follows: the switches are one flag and the
	// cable is another.  `chudp_flag_without_cable` is the rule and the
	// check holds it; this is where it is said out loud.
	{
		const char *stray = chudp_flag_without_cable(want_udp, nudp_peers,
							     udp_default_peer != NULL);
		if (stray) {
			fprintf(stderr, "cadr-chaosnet: %s is part of the CHUDP link: "
				"it needs --chaos-udp, which is the cable\n", stray);
			return 2;
		}
	}

	if (cadr_log_open("cadr-chaosnet: ") < 0)
		return 1;

	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);
	// A peer that has gone away makes a UDP socket give EPIPE on some
	// paths; the program says so rather than dying of it.
	signal(SIGPIPE, SIG_IGN);
	// **AND THE TWO THAT SWITCH THE TRACE**, SIGUSR1 on and SIGUSR2 off,
	// so that a link quietly refusing datagrams can be watched without
	// stopping the program --- which on this board means booting the
	// machine's world off the disk again.  `cadr-console trace-chaos
	// on|off` is what sends them.  Installed here, beside the other three,
	// rather than at the start: a signal that arrived before the log was
	// open would have nowhere to say so.
	chaos_trace_signals();

	say("this machine is %o", e.machine);

	// ---- the fabric ----
	//
	// THE GUARD FIRST, AND IT IS NOT OPTIONAL.  A read on a general
	// purpose AXI port that nothing in the fabric answers does not fault
	// the Arm: it hangs both cores at one PC each, measured on this board.
	// <cadr/cadr_mem.h> has the whole argument and the EMIO tally is the
	// one place the processing system can always reach.
	int fd = -1;
	if (fabric) {
		fd = cadr_open_mem();
		if (fd < 0)
			return 1;
		if (guard && cadr_guard(fd, "the Chaosnet interface") != 0)
			return 1;
		if (chaos_face_open(&e.face, fd, base) != 0)
			return 1;
		if (chaos_face_ident(&e.face) != 0)
			return 1;
		e.have_face = 1;
		// The sixteen address switches.  On MIT's board these are DIP
		// switches at LMMYNM D10 and D12; on this one there is nothing
		// to set, so the program sets them --- which is why the band's
		// own address has to be given here and cannot be read off the
		// card.
		chaos_face_set_address(&e.face, e.machine);
		const uint16_t back = chaos_face_address(&e.face);
		if (back != e.machine)
			say("the address switches read %o where %o was written; "
			    "the interface is not holding this machine's address",
			    back, e.machine);
		else
			say("the interface is at 0x%08x and holds address %o", base, e.machine);
	} else {
		say("no fabric: CHUDP alone, and the machine is not on this cable");
	}

	// ---- the cable's other stations ----
	if (want_udp) {
		char host[128] = "";
		uint16_t port = CHUDP_PORT;
		if (udp_endpoint) {
			const char *colon = strrchr(udp_endpoint, ':');
			if (colon) {
				const size_t n = (size_t)(colon - udp_endpoint);
				if (n < sizeof host) {
					memcpy(host, udp_endpoint, n);
					host[n] = '\0';
				}
				port = (uint16_t)strtoul(colon + 1, NULL, 10);
			} else {
				port = (uint16_t)strtoul(udp_endpoint, NULL, 10);
			}
		}
		if (chudp_bind(&e.udp, host[0] ? host : NULL, port) != 0)
			return 1;
		e.udp.trace = e.trace;
		// The one station this cable carries in this process, so that
		// a datagram claiming to come FROM it is refused rather than
		// put on the cable for the interface to take as its own.
		e.udp.local = e.machine;
		for (unsigned k = 0; k < nudp_peers; ++k) {
			if (chudp_add_peer(&e.udp, udp_peers[k]) != 0)
				return 1;
		}
		if (udp_default_peer && chudp_set_default_peer(&e.udp, udp_default_peer) != 0)
			return 1;
		e.have_udp = 1;
	} else {
		// Not an error: a board on a bench with no network is a
		// machine whose band will say its file host is not answering,
		// which is true and is better than a guess.
		say("no --chaos-udp, so this cable reaches nothing off the board");
	}

	// ---- the ether ----
	uint64_t last_report = now_ns();
	unsigned long reported = 0;
	// The retry at the machine's end, and the trace it starts with: a run
	// started with `--chaos-trace` should say what the queue is doing from
	// its first frame and not from its first signal.
	chaos_inject_init(&e.inject);
	e.inject.trace = e.trace;
	while (!stopping) {
		int did = 0;
		const uint64_t now = now_ns();
		// The turn's own clock, where `carry` can reach it: CHUDP hands
		// a frame up through a callback that carries no time.
		e.now = now;

		// What SIGUSR1 or SIGUSR2 asked for, if either did: acted on
		// here, in the program's own loop, where `say` is allowed.
		// **BOTH FLAGS MOVE TOGETHER**, the ether's line for a frame
		// going by and the link's for a datagram refused, because they
		// are one trace to the person who asked for it.
		{
			const int want = chaos_trace_apply(e.trace);
			if (want >= 0) {
				e.trace = want;
				e.inject.trace = want;
				if (e.have_udp)
					e.udp.trace = want;
			}
		}

		// What the machine transmitted.  The fabric holds one frame at
		// a time --- the interface's outgoing buffer is one packet ---
		// so this drains until it says there is none.
		if (e.have_face) {
			uint16_t words[CHAOS_MAX_WORDS];
			for (unsigned k = 0; k < DRAIN; ++k) {
				const int n = chaos_face_take(&e.face, words, CHAOS_MAX_WORDS);
				if (n <= 0)
					break;
				++e.from_machine;
				did = 1;
				// The cable destination is the third word from
				// the end: the hardware trailer is destination,
				// source, check.
				carry(&e, FROM_MACHINE, words, (unsigned)n,
				      words[(unsigned)n - CHAOS_PKT_TRAILER_WORDS]);
			}
		}

		// What came in off the network.
		if (e.have_udp) {
			const int n = chudp_poll(&e.udp, DRAIN, from_udp, &e);
			if (n > 0)
				did = 1;
		}

		// **AND THE FRAME WHOSE TURN IT IS.**  A frame the machine's
		// buffer refused waits here and goes again when the machine has
		// emptied it, which is what the sending station's own driver
		// would have done with an aborted packet.  One frame a turn, as
		// muir's node puts one on the cable at each of its turns.  A
		// turn in which nothing moved answers nought, so a queue waiting
		// on the machine still lets the loop sleep.
		if (e.have_face && chaos_inject_pump(&e.inject, &e.face, now))
			did = 1;

		if (now - last_report >= REPORT_NS) {
			// **WHAT COUNTS AS SOMETHING HAVING HAPPENED INCLUDES A
			// DATAGRAM THAT WAS REFUSED**, which is the whole
			// point of counting the refusals.  This was the
			// delivered count, so a link hearing datagrams and
			// throwing every one of them away printed nothing at
			// all and looked exactly like a link hearing nothing:
			// the report line was silent about the one case
			// somebody would be reading it for.  The link's
			// `received` covers its delivered frames as well, so
			// it takes their place here rather than being added
			// to them.
			const unsigned long moved = e.from_machine + e.inject.stored + e.to_udp
						  + (e.have_udp ? e.udp.received : 0ul);
			if (moved != reported) {
				// **THE LINK'S OWN FOUR COUNTS, AND THEY ADD
				// UP.**  A datagram refused at the UDP edge
				// never reaches the counters here, so the edge
				// keeps its own and this line prints them:
				// what arrived, and the three ways a datagram
				// can fail to come in.  The arithmetic closes,
				// which is what it is for --- `%lu datagrams
				// arrived` is the `%lu in` above plus the
				// three that follow it, so a line where they
				// do not add up says a road is uncounted, and
				// a line where they do says that a link
				// reporting nothing in really did hear
				// nothing.
				// **AND THE MACHINE'S SIDE CLOSES TOO**, which is
				// the same rule one seam along: every frame this
				// cable carried for the machine was stored, given
				// up after its three offers, dropped for want of
				// room to wait, or is still waiting, and
				// `chaos_inject.h` names the identity.  The
				// refusals stand beside them rather than in the
				// sum, being OFFERS and not frames: they are the
				// twin of the interface's own Lost Count, which
				// counts a commit and not a packet.
				// **AND A BROADCAST HAS A ROAD OF ITS OWN**,
				// because a busy receiver counts one and does
				// not abort it, so nothing on the cable was
				// ever told to send it again.  It is not folded
				// into the frames given up, which mean a
				// machine that has stopped listening: a count
				// that can mean two things is one nobody reads.
				say("%lu from the machine, %lu to it, %lu in and %lu out over UDP; "
				    "%lu datagrams arrived, %lu refused for their shape, "
				    "%lu with a bad checksum, %lu not for this cable; "
				    "%lu with nowhere to go, %lu malformed; "
				    "%lu offers refused because the machine had not emptied "
				    "its buffer and %lu in the interface's own Lost Count, "
				    "%lu frames given up after three, "
				    "%lu broadcasts lost to a full buffer, "
				    "%lu with no room to wait, %lu waiting",
				    e.from_machine, e.inject.stored, e.from_udp, e.to_udp,
				    e.have_udp ? e.udp.received : 0ul,
				    e.have_udp ? e.udp.bad_shape : 0ul,
				    e.have_udp ? e.udp.bad_checksum : 0ul,
				    e.have_udp ? e.udp.not_this_cable : 0ul,
				    e.dropped_no_route, e.dropped_bad_frame,
				    e.inject.refused,
				    // **THE INTERFACE'S OWN COUNT, BESIDE THIS
				    // PROGRAM'S.**  They are the same event
				    // counted at the two ends of the seam and
				    // they should move together; a board where
				    // they do not is a board where somebody
				    // else is committing frames, or where the
				    // fabric is refusing for a reason this
				    // program cannot see.  It is the one number
				    // in this line that is read out of the
				    // fabric rather than kept here.
				    e.have_face ? (unsigned long)chaos_face_lost(&e.face) : 0ul,
				    e.inject.given_up, e.inject.broadcasts_lost,
				    e.inject.no_room, (unsigned long)e.inject.waiting);
				reported = moved;
			}
			last_report = now;
		}

		if (!did)
			usleep(IDLE_SLEEP_US);
	}

	say("stopping: %lu packets from the machine, %lu to it, %lu still waiting for a turn",
	    e.from_machine, e.inject.stored, (unsigned long)e.inject.waiting);
	if (e.have_udp)
		chudp_close(&e.udp);
	if (e.have_face)
		chaos_face_close(&e.face);
	if (fd >= 0)
		close(fd);
	// The log's files are not closed here: there is more than one of them
	// now and they belong to `cadr_log_open`.  Every line is flushed as it
	// is said, so there is nothing standing in a buffer to lose.
	return 0;
}
