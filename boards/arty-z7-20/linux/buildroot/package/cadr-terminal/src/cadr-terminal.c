// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// cadr-terminal: the program on Linux that shows the CADR's screen to a VNC
// viewer.
//
// WHAT IT IS.  The CADR's display board --- MIT's TV, `rtl/machine/cadr_tv.sv` ---
// keeps no frame buffer of its own in the fabric: a cycle to the window at
// `0o17000000` is answered by main memory's bridge at the display's own base
// in PS DDR3, `0x1C00_0000` (`rtl/plumbing/cadr_ddr_map.sv`, `rtl/plumbing/cadr_xbus_ddr.sv`).
// So the picture the machine draws is 92,448 bytes of ordinary DDR that
// Linux can map, and **showing it needs no new fabric at all** --- which is
// why this program exists before the display output block does.  It maps
// that region, reads it once a frame, and serves it over RFB, RFC 6143,
// which is what a VNC viewer speaks.
//
// **AND IT CARRIES THE KEYBOARD AND THE MOUSE.**  It did not, for as long as
// there was no I/O board in the fabric to put a keystroke into; the card is
// in the machine now, and `rtl/plumbing/cadr_input_cables.sv` is the far end
// of its keyboard's cable and its mouse's, on the fourth page of
// `M_AXI_GP0`.  A viewer's `KeyEvent` becomes a stream of twenty-four-bit
// words --- muir's own mapping and MIT's own key table, `input_keys.h` --- and
// its `PointerEvent` becomes deltas for the quadrature encoder in fabric and
// a mask for the mouse's three switches.  The screen came first and the input
// later; this is the later.  **`--no-input` is the old behaviour**,
// and so is a bitstream without the input cables: the events are counted and
// dropped and one line says so.
//
// HOW IT RUNS.  `S85cadr-terminal` starts it at boot with `--log /dev/console`.
// In order:
//
//   0. THE FLUSH, before anything can be typed at this program.  **The
//      machine asks whether anybody is typing four instructions into
//      microcode 323** --- `uc-cadr.lisp` at `(LOC 6)` reads the keyboard's
//      status register and cold-boots if it is not ready, warm-boots if it
//      is --- so a word left in the fabric's queue by a previous run would
//      send a restarted machine down a path nobody asked for.  The flush is
//      written after `IDENT` and BEFORE the socket is bound, which is what
//      makes it airtight here: a viewer cannot have sent a key to a socket
//      that does not exist yet.  `input_face.h` has the other three legs.
//   1. THE GUARD.  A read on `M_AXI_GP0` or `M_AXI_GP1` that nothing in the
//      fabric answers hangs both Arm cores, and no software guard can catch
//      it afterwards (CLAUDE.md; measured on the board).  The one thing a
//      program can read first is the EMIO tally at 0xE000A068/6C, which
//      carries marker bits --- `(w & 0x80008000) == 0x00008000` --- only on a
//      bitstream with the processing system in it.  **This program reaches no
//      GP port**: the display's window is DDR, and DDR answers whatever is in
//      the fabric.  The guard runs anyway, and for a reason of its own: a
//      bitstream without the processing system is a bitstream whose CADR
//      never wrote a word of that region, so what this program would serve is
//      whatever the DDR controller last held.  Reading the tally first is how
//      it tells a machine that has not drawn from a board that cannot.
//      `--no-guard` is for a board somebody knows.  **The input face IS on a
//      GP port**, unlike the display's window, so for this program the guard
//      is no longer only a diagnostic: `--no-guard --no-input` is the pair
//      that reaches nothing.
//   2. THE WINDOW: 128 KB at 0x1C00_0000 through /dev/mem, uncached --- a
//      word the fabric writes over `S_AXI_HP0` must not be read out of a
//      cache the port cannot see.
//   3. THE SOCKET: RFB where `--terminal` says, every interface at port 5900
//      by default, which a viewer reaches as display `:0`.
//   4. THE LOOP: the visible 23,112 words copied out of the window once a
//      pass and every viewer answered from that one copy.  Nothing is read
//      while nobody is watching.
//
// **WHAT IT CANNOT READ, AND WHAT IT ASSUMES INSTEAD.**  `MODE BOW` decides
// whether a one bit is white or black, and it is four flops in the fabric
// with no path to the processing system.  The default here is the fabric's
// own power-on state and muir's, zero --- a one bit is white --- which is
// also the mode both reference programs leave the register in.  `--bow`
// swaps it.  `screen_geom.h` and `docs/terminal.md` say what reading it would
// take.
//
// WHAT IT PRINTS, low rate on purpose: one line when it starts, one when a
// viewer connects or leaves, one the first time a viewer sends input, one
// when the screen goes blank or stops being blank, and NOTHING per frame.  A
// summary at most once a minute, and only while the counts move.
//
//     cadr-terminal [--terminal [<endpoint>]] [--log PATH] [--bow]
//                   [--interval-ms N] [--no-rre] [--no-guard] [--no-input]
//                   [--input ADDR] [--keyboard-mapping FILE]
//                   [--keyboard-boot KEYS] [--keyboard-boot-trace] [--once]
//
// **WHERE IT LISTENS IS muir'S WORD FOR IT, `--terminal`**, and it took over
// from a `--port` and a `--bind` of this program's own.  muir says where its
// screen is served with one flag and one word and so does this, in the same
// four forms --- nothing, a port, an address, or address:port
// (`cadr/cadr_endpoint.h`).  Two reasons, and the second is the one that
// forced it.  `--port` was a word this program and the serial line both took,
// and the card's one file of flags cannot carry a word two programs answer to,
// so neither could say where either of them listened.  And a person who knows
// one of the two CADRs on this board should not have to learn a second
// vocabulary for the other.
//
// **THE ONE PLACE IT DIFFERS FROM muir IS THE DEFAULT ADDRESS, and the
// difference is this board's and not the flag's.**  muir binds the loopback
// unless told otherwise, which is where an unauthenticated server belongs on a
// machine somebody is sitting at.  This board has no screen of its own and the
// whole point of this program is to be reached from another machine, so its
// default is every interface --- the decision the paragraph below has always
// carried.  The GRAMMAR is muir's exactly: every spelling muir takes is taken
// here and means the same shape of thing.  `--terminal 127.0.0.1:5900` is how
// the loopback is asked for, and the card writes its endpoint out in full so
// that nothing rests on which default is which.

#include <errno.h>
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

#include <cadr/cadr_input_link.h>

#include "input_face.h"
#include "input_keys.h"
#include "input_mapping.h"
#include "screen_frame.h"
#include "screen_geom.h"
#include "screen_server.h"

// The port a screen is served at unless `--terminal` says another: VNC's
// display :0, which is muir's own default and the number every viewer tries
// first.
#define TERMINAL_PORT 5900

static volatile sig_atomic_t stopping;
static void on_stop(int sig)
{
	(void)sig;
	stopping = 1;
}

static uint64_t monotonic_ns(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}

static void usage(void)
{
	fprintf(stderr,
		"usage: cadr-terminal [options]\n"
		"  --terminal [<endpoint>]   where the screen, keyboard and mouse are served\n"
		"                            over RFB: nothing, a port, an address, or\n"
		"                            address:port. muir's own flag and muir's own\n"
		"                            grammar (default 0.0.0.0:5900, every interface at\n"
		"                            VNC's display :0; --terminal 127.0.0.1:5900 is the\n"
		"                            loopback alone)\n"
		"  --log PATH        where to write (default stdout)\n"
		"  --bow             the display's MODE BOW: one bits are black (default: white)\n"
		"  --window ADDR     the display's region (default 0x1C000000)\n"
		"  --interval-ms N   how often the window is read while anybody watches (default 16)\n"
		"  --no-rre          send every rectangle Raw, for measuring what RRE buys\n"
		"  --no-guard        do not check the EMIO tally first\n"
		"  --no-input        do not carry the keyboard and mouse; drop what a viewer sends\n"
		"  --input ADDR      the keyboard and mouse registers (default 0x40003000)\n"
		"  --keyboard-mapping FILE   what a viewer's keysyms mean, over the built-in map\n"
		"                            (muir's own `key` and `prefix` lines; `muir\n"
		"                            --keyboard-mapping-dump` writes a starting file)\n"
		"  --keyboard-boot KEYS      the keys the keyboard's boot sequence needs, held\n"
		"                            with Rubout to cold-boot the machine or with Return\n"
		"                            to warm-boot it. One of\n"
		"    " KEY_BOOT_SPELLINGS "\n"
		"                            the last being the CADR keyboard's own; the default\n"
		"                            `ctrl,meta` is Ctrl-Alt-Del on any keyboard\n"
		"  --keyboard-boot-trace     say when a key-up is held back behind a boot word\n"
		"  --input-link PATH the socket a source that is not a viewer sends keys and\n"
		"                    mouse movement on (default /var/run/cadr-input). That is\n"
		"                    cadr-usb-input, the board's own USB keyboard and mouse\n"
		"  --no-input-link   do not listen for one\n"
		"  --once            do the checks, read one frame, say what is on it, and exit\n");
}

static const char *blank_word(int blank)
{
	switch (blank) {
	case SCREEN_BLANK_ZEROS: return "every visible word zero";
	case SCREEN_BLANK_ONES: return "every visible word all ones";
	case SCREEN_BLANK_OTHER: return "one word repeated 23,112 times";
	default: return "content";
	}
}

int main(int argc, char **argv)
{
	const char *log_path = NULL, *keymap_path = NULL;
	unsigned interval_ms = 16;
	// Where the screen is served. The default is this board's own --- every
	// interface at VNC's display :0 --- and `--terminal` reads muir's four
	// forms against it.
	struct cadr_endpoint listen;
	if (cadr_endpoint_parse(NULL, NULL, TERMINAL_PORT, &listen) != 0)
		return 2;
	uint32_t window_phys = SCREEN_BASE;
	uint32_t input_phys = IN_REG_BASE;
	int bow = 0, no_guard = 0, once = 0, no_rre = 0, no_input = 0, no_link = 0;
	int boot_trace = 0;
	const char *link_path = CADR_INPUT_LINK_PATH;
	// `--keyboard-boot`, whose default is muir's: either Control and either
	// Meta.  Read here rather than at the keyboard so that a spelling
	// nobody can type is refused before the socket is bound.
	struct key_boot boot_keys;
	char boot_why[256];
	if (key_boot_parse("ctrl,meta", &boot_keys, boot_why, sizeof boot_why) != 0)
		return 2;
	static const struct option opts[] = {
		{ "terminal", optional_argument, NULL, 't' },
		{ "log", required_argument, NULL, 'l' },
		{ "bow", no_argument, NULL, 'B' },
		{ "window", required_argument, NULL, 'w' },
		{ "interval-ms", required_argument, NULL, 'i' },
		{ "no-rre", no_argument, NULL, 'R' },
		{ "no-guard", no_argument, NULL, 'G' },
		{ "no-input", no_argument, NULL, 'I' },
		{ "input", required_argument, NULL, 'n' },
		{ "keyboard-mapping", required_argument, NULL, 'k' },
		{ "keyboard-boot", required_argument, NULL, 'K' },
		{ "keyboard-boot-trace", no_argument, NULL, 'T' },
		{ "input-link", required_argument, NULL, 'L' },
		{ "no-input-link", no_argument, NULL, 'N' },
		{ "once", no_argument, NULL, 'o' },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};
	int c;
	while ((c = getopt_long(argc, argv, "t::l:Bw:i:RGIn:k:K:TL:Noh", opts, NULL)) != -1) {
		switch (c) {
		case 't': {
			// **THE ENDPOINT IS OPTIONAL, AS muir'S IS, AND getopt
			// HANDS BACK AN OPTIONAL ARGUMENT ONLY WHEN IT IS
			// WRITTEN `--terminal=<endpoint>`.**  The card writes
			// its flags as two words --- that is the rc format's
			// own shape, the flag then a space then the rest of
			// the line --- so a `--terminal 0.0.0.0:5900` line
			// would arrive here as the bare flag with the endpoint
			// left standing as a word nobody looked at, which is
			// the silent setting this whole file of flags exists to
			// prevent.  muir takes the next word unless it is a
			// flag; so does this.
			const char *spec = optarg;
			if (!spec && optind < argc && argv[optind][0] != '-')
				spec = argv[optind++];
			if (cadr_endpoint_parse(spec, NULL, TERMINAL_PORT, &listen) != 0) {
				fprintf(stderr, "cadr-terminal: --terminal %s: "
					"wants nothing, a port, an address or address:port\n",
					spec ? spec : "");
				return 2;
			}
			break;
		}
		case 'l': log_path = optarg; break;
		case 'B': bow = 1; break;
		case 'w': window_phys = (uint32_t)strtoul(optarg, NULL, 0); break;
		case 'i': interval_ms = (unsigned)strtoul(optarg, NULL, 0); break;
		case 'R': no_rre = 1; break;
		case 'G': no_guard = 1; break;
		case 'I': no_input = 1; break;
		case 'n': input_phys = (uint32_t)strtoul(optarg, NULL, 0); break;
		case 'k': keymap_path = optarg; break;
		case 'K':
			// **REFUSED AND NOT FALLEN BACK ON**, which is the
			// other way round from the mapping file above.  A
			// mapping is a file on a card that a typo must not
			// cost the screen for; this is a word on the command
			// line, and a boot sequence quietly set to something
			// else is a machine that reboots when nobody asked or
			// does not when somebody did.
			if (key_boot_parse(optarg, &boot_keys, boot_why, sizeof boot_why) != 0) {
				fprintf(stderr, "cadr-terminal: --keyboard-boot %s\n", boot_why);
				return 2;
			}
			break;
		case 'T': boot_trace = 1; break;
		case 'L': link_path = optarg; break;
		case 'N': no_link = 1; break;
		case 'o': once = 1; break;
		default: usage(); return 2;
		}
	}
	// A zero interval would make the loop a busy wait: poll(2) with no
	// timeout to wait for and a window read every pass.
	if (interval_ms == 0)
		interval_ms = 1;
	// **A WORD THAT IS NOT A FLAG IS REFUSED AND NOT IGNORED.**  Everything
	// this program is given comes from an init script or from the card's
	// `fpgarc`, and a word left over is a line somebody wrote that nothing
	// read --- the same failure as a flag quietly dropped, which is what the
	// reader and every one of these programs is strict to avoid.
	if (optind < argc) {
		fprintf(stderr, "cadr-terminal: %s: not a flag this program takes\n",
			argv[optind]);
		return 2;
	}
	FILE *dest = stdout;
	if (log_path) {
		dest = fopen(log_path, "a");
		if (!dest) {
			fprintf(stderr, "cadr-terminal: %s: %s\n", log_path, strerror(errno));
			return 2;
		}
	}
	cadr_log_init("cadr-terminal: ", dest);

	int mem = cadr_open_mem();
	if (mem < 0)
		return 1;
	// 1. The guard.  This program touches no GP port; the header says why
	// it runs anyway.
	if (!no_guard && cadr_guard(mem, "the display's window") < 0)
		return 1;
	// 2. The window.
	volatile uint32_t *window = cadr_map(mem, window_phys, SCREEN_WINDOW_BYTES,
					     "the display's window");
	if (!window)
		return 1;

	struct screen_frame frame;
	screen_frame_init(&frame, bow);
	screen_frame_read(&frame, window);
	say("the display's window is %u KB at 0x%08x; the screen is %ux%u, %u words a line, "
	    "%u of the window's %u words, one bit a pixel, a one bit %s",
	    SCREEN_WINDOW_BYTES / 1024u, window_phys, SCREEN_WIDTH, SCREEN_HEIGHT,
	    SCREEN_WORDS_PER_LINE, SCREEN_VISIBLE_WORDS, SCREEN_WINDOW_WORDS,
	    bow ? "BLACK (MODE BOW, --bow)" : "WHITE (MODE BOW clear, the fabric's power-on state)");

	int blank = screen_frame_blank(&frame);
	if (blank != SCREEN_BLANK_NO)
		say("the screen is BLANK: %s (0x%08x). Either the machine has not drawn, or this is "
		    "not the region it draws into --- an unwritten word of this board's DDR reads zero "
		    "in some places and all ones in others (docs/board.md)",
		    blank_word(blank), frame.words[0]);
	else
		say("the screen has content: %lu of %u pixels lit",
		    screen_frame_lit(&frame), SCREEN_WIDTH * SCREEN_HEIGHT);
	if (once)
		return 0;

	// 2b. The keyboard and the mouse, and the FLUSH before the socket.
	//
	// **A FACE THAT DOES NOT ANSWER IS NOT A FAILURE**, it is a bitstream
	// without the input cables, and the screen is worth serving either
	// way: the program says which it got and carries on.  `--no-input`
	// says so deliberately.
	struct input_face input;
	int have_input = 0;
	if (!no_input) {
		if (input_face_open(&input, mem, input_phys) == 0) {
			if (input_face_ident(&input) == 0) {
				// The flush, with nothing able to have typed
				// yet: the socket is bound below.
				input_face_flush(&input);
				have_input = 1;
			} else {
				input_face_close(&input);
			}
		}
		if (!have_input)
			say("no keyboard and mouse: the screen is served READ-ONLY, and a viewer's "
			    "keys and pointer are counted and dropped");
	} else {
		say("--no-input: the screen is served READ-ONLY");
	}

	// 3. The socket.
	struct screen_server srv;
	if (screen_server_bind(&srv, listen.addr[0] ? listen.addr : NULL, listen.port) < 0)
		return 1;
	srv.rre_offered = !no_rre;
	if (have_input) {
		srv.input = &input;
		// The mapping, if a file says one.  **A FILE THAT DOES NOT
		// PARSE LEAVES THE BUILT-IN MAPPING STANDING AND DOES NOT STOP
		// THE PROGRAM**, where muir stops the run: this one is started
		// at boot and is the only way to see the machine at all, and
		// the file is optional and lives on a card a laptop edits.  A
		// typo in it must not cost the screen as well as the keyboard.
		// `input_mapping.h` has the argument; the line below is what
		// makes the fall-back visible, on the console, naming the line.
		struct key_map map;
		char err[KEY_MAP_ERR_MAX];
		key_map_built_in(&map);
		if (keymap_path && key_map_read_file(&map, keymap_path, err, sizeof err) != 0) {
			say("the keyboard mapping %s was NOT read and the built-in one stands: %s",
			    keymap_path, err);
			key_map_built_in(&map);
		} else if (keymap_path) {
			say("the keyboard mapping is %s over the built-in one: %u keysyms bound "
			    "and %u behind a prefix",
			    keymap_path, map.bounds, map.afters);
		}
		key_state_init_with(&srv.keys, &map);
		key_boot_set(&srv.keys, boot_keys);
		key_boot_traced(&srv.keys, boot_trace);
		char boot_spelt[32];
		key_boot_spelling(boot_keys, boot_spelt, sizeof boot_spelt);
		say("the keyboard's own boot sequence is %s held with Rubout to cold-boot the "
		    "machine, or with Return to warm-boot it --- the keyboard boots a CADR "
		    "itself and the microcode is not asked. --keyboard-boot moves it",
		    boot_spelt);
		say("the keyboard and mouse are at 0x%08x; a viewer's keys go to the machine "
		    "as MIT's own key positions, muir's mapping, and its pointer as the "
		    "mouse's own counts. The fabric's queue was flushed before this socket "
		    "was bound, so nothing was waiting at the machine's cold-boot test",
		    input_phys);
		// **AND A SOURCE THAT IS NOT A VIEWER.**  `cadr-usb-input`
		// reads the board's own USB keyboard and mouse and sends
		// keysyms here, where they take exactly the path a viewer's
		// keys take: one mapping, one queue, one pacer.  It could not
		// write the registers itself --- the rule about how fast words
		// may be handed over needs ONE pacer, and two programs obeying
		// it separately would give the machine words twice as fast as
		// either meant.  `cadr/cadr_input_link.h` and docs/usb-input.md
		// have the whole of it.  **After the flush**, like the socket
		// above and for the same reason.
		if (!no_link && screen_server_link(&srv, link_path) == 0)
			say("a source that is not a viewer may attach at %s: its keys and "
			    "its mouse go the same way a viewer's do", link_path);
	}
	say("RFB on %s:%u --- display :%u to a viewer. NO AUTHENTICATION: RFC 6143's None is the "
	    "only security type offered, so anyone who can reach this port sees the screen. "
	    "%s. Encodings: Raw%s",
	    listen.addr[0] ? listen.addr : "0.0.0.0", listen.port,
	    listen.port >= TERMINAL_PORT && listen.port < TERMINAL_PORT + 100
	        ? listen.port - TERMINAL_PORT : 0,
	    have_input ? "The keyboard and mouse go to the machine"
	               : "READ-ONLY: keys and pointer events are dropped",
	    no_rre ? " only (--no-rre)" : " and RRE, whichever is smaller for each rectangle");

	// 4. The loop.
	signal(SIGTERM, on_stop);
	signal(SIGINT, on_stop);
	signal(SIGPIPE, SIG_IGN);
	time_t last_said = time(NULL);
	unsigned long said_connects = 0, said_input = 0;
	uint64_t last_read_ns = 0;
	unsigned long long said_bytes = 0;
	while (!stopping) {
		const uint64_t now = monotonic_ns();
		// Nothing is read while nobody is watching: the window is an
		// uncached mapping and 92,448 bytes of it is real traffic on
		// the DDR controller's debug port.  A machine with no viewer
		// costs this program a poll and nothing else.
		if (srv.viewers && now - last_read_ns >= (uint64_t)interval_ms * 1000000u) {
			screen_frame_read(&frame, window);
			last_read_ns = now;
			const int now_blank = screen_frame_blank(&frame);
			if (now_blank != blank) {
				if (now_blank == SCREEN_BLANK_NO)
					say("the screen has content: %lu of %u pixels lit",
					    screen_frame_lit(&frame), SCREEN_WIDTH * SCREEN_HEIGHT);
				else
					say("the screen has gone blank: %s", blank_word(now_blank));
				blank = now_blank;
			}
		}
		// **AND THE LOOP MUST NOT SLEEP PAST A KEY WORD.**  The pacing
		// rule holds a word back until the interval has gone by, and a
		// poll that then slept a whole frame would make a keystroke
		// take a frame a word instead of the interval a word.  So when
		// a word is waiting the sleep is shortened to what is left of
		// its wait, rounded up to a millisecond, which is poll(2)'s own
		// resolution.
		int wait_ms = (int)interval_ms;
		const uint64_t due = screen_server_key_wait_ns(&srv, now);
		if (due) {
			const int due_ms = (int)((due + 999999u) / 1000000u);
			if (due_ms < wait_ms)
				wait_ms = due_ms;
		}
		screen_server_poll(&srv, &frame, wait_ms, monotonic_ns());
		const time_t t = time(NULL);
		if (t - last_said >= 60
		    && (srv.connects != said_connects || srv.input_events != said_input
			|| srv.sent_raw + srv.sent_rre != said_bytes)) {
			say("%u watching (%lu connected, %lu gone, %lu refused); %lu frames read; "
			    "%lu rectangles Raw for %llu bytes (RRE would have been %llu), "
			    "%lu RRE for %llu, saving %llu; %lu input events, %lu key words to "
			    "the machine (%lu held back for pacing or room, %lu lost in the fabric), "
			    "%lu pointer moves, %lu keysyms nothing maps",
			    srv.viewers, srv.connects, srv.drops, srv.refused, frame.reads,
			    srv.rects_raw, srv.sent_raw, srv.declined_rre, srv.rects_rre,
			    srv.sent_rre, srv.saved_by_rre, srv.input_events,
			    srv.keys_sent, srv.keys_stuck,
			    have_input ? (unsigned long)input_face_lost(&input) : 0ul,
			    srv.pointer_moves, srv.keys.unbound);
			if (srv.link_ready && (srv.link.connects || srv.link.events))
				say("the input link: %u attached (%lu came, %lu went, %lu refused, "
				    "%lu dropped for what they said); %lu events",
				    cadr_input_link_clients(&srv.link), srv.link.connects,
				    srv.link.drops, srv.link.refused, srv.link.rejected,
				    srv.link.events);
			said_connects = srv.connects;
			said_input = srv.input_events;
			said_bytes = srv.sent_raw + srv.sent_rre;
			last_said = t;
		}
	}
	say("stopped: %lu viewers came and %lu went; %lu frames read; %llu bytes of pixels sent, "
	    "%llu saved by RRE; %lu input events, %lu key words to the machine, %lu pointer moves",
	    srv.connects, srv.drops, frame.reads, srv.sent_raw + srv.sent_rre, srv.saved_by_rre,
	    srv.input_events, srv.keys_sent, srv.pointer_moves);
	// **THE SOCKET AND THE LINK GO FIRST, AND THE DRAIN IS AFTER THEM.**
	// Closing the link releases every key its clients were holding INTO
	// the queue, so it has to happen before the queue is drained below;
	// closing it after would queue those releases where nothing would ever
	// send them.
	screen_server_close(&srv);
	// Every key anybody had down comes up, and the machine is left with
	// nothing held: a Control still down when this program stops is a
	// Control down for the rest of the machine's run.
	if (have_input) {
		key_all_up(&srv.keys);
		// **PACED LIKE ANY OTHER WORDS.**  A handful of releases handed
		// over at once is the fault this program was fixed for, and a
		// Shift release the machine swallowed is a Shift held for the
		// rest of its run --- which is exactly what this loop exists to
		// prevent.  Bounded, so that a machine which has stopped reading
		// its keyboard cannot hold this program open: twenty releases is
		// the most that can be owed, `KEY_MAX_DOWN`, and the allowance is
		// many times their cost.
		const uint64_t deadline = monotonic_ns()
					+ 64ull * KEY_MAX_DOWN * INPUT_KEY_INTERVAL_NS;
		while (key_pending(&srv.keys) && monotonic_ns() < deadline) {
			if (input_face_key_idle(&input)
			    && input_face_key(&input, key_peek(&srv.keys)))
				key_took(&srv.keys);
			const struct timespec gap = {
				.tv_sec = 0, .tv_nsec = (long)INPUT_KEY_INTERVAL_NS
			};
			nanosleep(&gap, NULL);
		}
		if (key_pending(&srv.keys))
			say("%u key words the machine would not take: it is not reading "
			    "its keyboard", key_pending(&srv.keys));
		input_face_buttons(&input, 0);
	}
	if (have_input)
		input_face_close(&input);
	return 0;
}
