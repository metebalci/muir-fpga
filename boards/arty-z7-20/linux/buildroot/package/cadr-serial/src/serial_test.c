// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The serial line's far end, held on the build host to a model of the 2651's
// register face and to a real client on a loopback socket: no board, no
// fabric, nothing but a C compiler.
//
//     serial_test
//
// **WHAT DRIVES IT.**  `serial_face.h`'s seam is two function pointers, so
// this file puts a model of what is behind the registers there --- the port's
// queue towards the program, the machine's receiver, the modem-control lines
// and the DROPPED counter --- and drives `serial_endpoint.c` against it with
// a client of this file's own on 127.0.0.1.  Both ends are in this process,
// so the check pumps them by hand: `settle` calls `serial_endpoint_pump` and
// lets the loopback deliver.
//
// **THE MODEL AND THE CODE UNDER TEST SHARE NOTHING THAT COULD BE WRONG
// TOGETHER.**  This is the scar this project keeps re-opening: a shadow
// memory keyed off the thing it is checking moves with the bug, and a check
// written to confirm rather than to compare passes a mirrored screen.  So the
// model below decodes register numbers as LITERAL offsets --- 0 for IDENT, 1
// for STAT, 2 for RDATA, 3 for WDATA, 4 for CTL, 5 for MODE, 6 for DROPPED,
// 7 for IRQ --- written out from `serial_face.h`'s own table and not through
// `enum ser_reg`, and its status and control bits are literal masks written
// out from the same table and not through `enum ser_stat` or `enum ser_ctl`.
// A mutation that renumbers a register or moves a bit is then a disagreement
// and not an agreed change.
//
// **WHERE THE MODEL GOES BEYOND WHAT THE FACE PROMISES, AND WHY THAT IS
// SAFE.**  `serial_face.h` does not say how deep the port's queue is, nor
// which character goes when it overflows.  The model gives it a depth this
// file sets per check and drops the NEWEST, keeping what is already at RDATA
// --- because a fabric that raised RX_VALID and then withdrew the character
// would be lying to a program that had already been told to read it.  Nothing
// in `serial_endpoint.c` depends on either choice: it drains RDATA until it
// reads invalid, which is right for a holding register of one and for a FIFO
// of sixteen.
//
// **WHAT IS CHECKED.**  IDENT, accepted as "SERI" and refused as "NONE" by
// name.  The cable put down at start.  The modem-control lines up when a
// client connects and down when it hangs up, written when the cable changes
// and at no other time.  A character the machine sent arriving at the client,
// and a character typed at the client reaching the machine's receiver, both
// in order and in bursts that wrap the rings.  A second client turned away
// while one is attached.  A client that hangs up and reconnects being served,
// and --- the property muir states --- a device that goes and another that
// comes in the same turn leaving the cable plugged in throughout.  What the
// port sent and the client never took dropped on a hang-up.  Characters
// dropped while nobody is connected counted by the port and not queued here.
// The receiver refusing a character, and the program offering it again rather
// than losing it.  RDATA not read when STAT says there is nothing.  The three
// modem-control lines and nothing else written.  TCP_NODELAY on the accepted
// socket.  And the rate read out of mode register 2.

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cadr/cadr_log.h>

#include "serial_endpoint.h"
#include "serial_face.h"

static int bad;
static unsigned checks;

static void fail(int line, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void fail(int line, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "serial_test.c:%d: FAIL: ", line);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
	++bad;
	if (bad > 30) {
		fprintf(stderr, "FAIL: too many; stopping\n");
		exit(1);
	}
}

#define CHECK(cond, ...)                             \
	do {                                         \
		++checks;                            \
		if (!(cond))                         \
			fail(__LINE__, __VA_ARGS__); \
	} while (0)

// ---- the program's own log ----------------------------------------------
//
// `cadr_log`'s destination is set once, so the program's lines go to a memory
// stream here rather than over the check's output.  Two of them are checked:
// IDENT must name "NONE" when it finds the default slave.  The whole log is
// printed if anything failed, because a failure in a socket check is read off
// what the endpoint said while it happened.

static char *logbuf;
static size_t loglen;
static FILE *logf;

static size_t log_mark(void)
{
	fflush(logf);
	return loglen;
}

static const char *log_since(size_t mark)
{
	fflush(logf);
	return logbuf ? logbuf + mark : "";
}

// ---- the model of what is behind the registers --------------------------
//
// The register numbers and bit masks here are literals out of
// `serial_face.h`'s table, for the reason at the top of this file.

#define MODEL_PORT_MAX 1024	/* the port's queue, machine -> this program */
#define MODEL_RECV_MAX 64	/* the machine's receiver, this program -> machine */
#define MODEL_CTL_LOG  64

struct model {
	// What the machine has transmitted and the program has not read.
	uint8_t port[MODEL_PORT_MAX];
	unsigned port_head, port_len, port_cap;
	// What the program has written into the machine's receiver.
	uint8_t recv[MODEL_RECV_MAX];
	unsigned recv_head, recv_len, recv_cap;

	uint32_t ident, ctl, dropped, mode, irq;
	int tx_on, rx_on;

	// Every write of CTL, in order: the check needs to know WHEN the
	// lines moved and not only where they ended up.
	uint32_t ctl_write[MODEL_CTL_LOG];
	unsigned ctl_writes;

	// Reads of RDATA that found nothing there.  A read of RDATA is the
	// one read in this face with an effect, so a program that issues one
	// without asking STAT first is asking a real fabric to hand over a
	// character it may not have --- counted here so that the rule is
	// checkable rather than merely written down.
	unsigned long rdata_reads_when_empty;
	// Writes of WDATA the receiver had no room for, which `serial_face.h`
	// says are "refused, and lost".
	unsigned long wdata_lost;
};

static void model_init(struct model *m, unsigned port_cap, unsigned recv_cap)
{
	memset(m, 0, sizeof *m);
	m->ident = 0x53455249u;	/* "SERI", serial_face.h's SER_IDENT_WORD */
	m->port_cap = port_cap;
	m->recv_cap = recv_cap;
	// MR1 in bits 7:0, MR2 in bits 15:8, the command register in 23:16.
	// MR2 = 0o45: rate 5 with the receiver and the transmitter both on
	// the internal generator.  Rate 5 is 300 baud, which is what MIT's
	// sys/io1/serial.lisp defaults to.
	m->mode = (0x05u << 16) | (0o45u << 8) | 0o116u;
	m->tx_on = m->rx_on = 1;
}

// The machine transmits a character.  The port holds `port_cap` of them; past
// that the new one is dropped and counted, the one already at RDATA standing.
static void model_machine_sends(struct model *m, uint8_t c)
{
	if (m->port_len == m->port_cap) {
		if (m->dropped != 0xFFFFFFFFu)
			++m->dropped;	/* saturating, as the face says */
		return;
	}
	m->port[(m->port_head + m->port_len) % MODEL_PORT_MAX] = c;
	++m->port_len;
	m->irq |= 1u << 0;	/* IRQ bit 0: a character is waiting */
}

// The machine's receiver takes the next character, or there is none.
static int model_machine_takes(struct model *m)
{
	if (!m->recv_len)
		return -1;
	const uint8_t c = m->recv[m->recv_head];
	m->recv_head = (m->recv_head + 1) % MODEL_RECV_MAX;
	--m->recv_len;
	m->irq |= 1u << 1;	/* IRQ bit 1: the transmitter has room */
	return c;
}

static uint32_t model_read(struct serial_face *f, unsigned word)
{
	struct model *m = f->ctx;
	switch (word) {
	case 0:			/* IDENT */
		return m->ident;
	case 1: {		/* STAT */
		uint32_t s = 0;
		if (m->port_len)
			s |= 1u << 0;	/* RX_VALID */
		if (m->recv_len < m->recv_cap)
			s |= 1u << 1;	/* TX_ROOM */
		if (m->tx_on)
			s |= 1u << 2;	/* TX_ON */
		if (m->rx_on)
			s |= 1u << 3;	/* RX_ON */
		return s;
	}
	case 2:			/* RDATA, and the read CONSUMES */
		if (!m->port_len) {
			++m->rdata_reads_when_empty;
			return 0;
		} else {
			const uint8_t c = m->port[m->port_head];
			m->port_head = (m->port_head + 1) % MODEL_PORT_MAX;
			--m->port_len;
			return 0x100u | c;	/* bit 8: there was one */
		}
	case 3:			/* WDATA is write-only */
	case 4:			/* CTL is write-only */
		return 0;
	case 5:			/* MODE */
		return m->mode;
	case 6:			/* DROPPED */
		return m->dropped;
	case 7:			/* IRQ */
		return m->irq;
	default:
		// Every address in the window must be answered; a fabric that
		// answered nothing here would hang both Arm cores.  The model
		// answers, and the check would see a word the face never asks
		// for as a wrong value rather than as a hang.
		return 0xDEADBEEFu;
	}
}

static void model_write(struct serial_face *f, unsigned word, uint32_t v)
{
	struct model *m = f->ctx;
	switch (word) {
	case 3:			/* WDATA: refused, and lost, unless TX_ROOM */
		if (m->recv_len == m->recv_cap) {
			++m->wdata_lost;
			return;
		}
		m->recv[(m->recv_head + m->recv_len) % MODEL_RECV_MAX] = (uint8_t)(v & 0xFFu);
		++m->recv_len;
		return;
	case 4:			/* CTL */
		m->ctl = v;
		if (m->ctl_writes < MODEL_CTL_LOG)
			m->ctl_write[m->ctl_writes] = v;
		++m->ctl_writes;
		return;
	case 7:			/* IRQ: a 1 clears the bit */
		m->irq &= ~v;
		return;
	default:
		return;
	}
}

// ---- the bench ----------------------------------------------------------

static struct serial_endpoint e;
static struct serial_face face;
static struct model mdl;
static int bound;

static void fresh(unsigned port_cap, unsigned recv_cap)
{
	if (bound) {
		serial_endpoint_close(&e);
		bound = 0;
	}
	model_init(&mdl, port_cap, recv_cap);
	face.read = model_read;
	face.write = model_write;
	face.ctx = &mdl;
	if (serial_endpoint_bind(&e, "127.0.0.1", 0) < 0) {
		fprintf(stderr, "FAIL: serial_test: no socket\n");
		exit(1);
	}
	bound = 1;
	serial_endpoint_start(&e, &face);
}

static void pump(void)
{
	serial_endpoint_pump(&e, &face);
}

// Enough passes for the loopback to have delivered whatever was just done.
// `serial_endpoint_wait` returns as soon as the socket has something, so this
// costs its full timeout only when nothing is happening.
static void settle(void)
{
	for (int k = 0; k < 20; ++k) {
		serial_endpoint_wait(&e, 500);
		pump();
	}
}

static int set_nonblock(int fd)
{
	const int fl = fcntl(fd, F_GETFL, 0);
	return fl < 0 ? -1 : fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

// A client on the loopback.  `rcvbuf`, when not zero, is a deliberately small
// receive buffer so that a far end which has stopped reading fills in a few
// kilobytes rather than a few hundred.
static int client_open(int rcvbuf)
{
	const int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0)
		return -1;
	if (rcvbuf)
		setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof rcvbuf);
	struct sockaddr_in a;
	memset(&a, 0, sizeof a);
	a.sin_family = AF_INET;
	a.sin_port = htons((uint16_t)serial_endpoint_port(&e));
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if (connect(fd, (struct sockaddr *)&a, sizeof a) < 0) {
		close(fd);
		return -1;
	}
	set_nonblock(fd);
	return fd;
}

// Whatever has arrived for the client now.  -1 means the endpoint closed it.
static int client_drain(int fd, uint8_t *buf, size_t cap)
{
	const ssize_t n = read(fd, buf, cap);
	if (n == 0)
		return -1;
	if (n < 0)
		return (errno == EAGAIN || errno == EWOULDBLOCK) ? 0 : -1;
	return (int)n;
}

// Pumps until the client has `want` characters or the patience runs out.
static size_t client_collect(int fd, uint8_t *buf, size_t want, size_t cap)
{
	size_t n = 0;
	for (int k = 0; k < 400 && n < want; ++k) {
		serial_endpoint_wait(&e, 500);
		pump();
		for (;;) {
			const int got = client_drain(fd, buf + n, cap - n);
			if (got <= 0)
				break;
			n += (size_t)got;
			if (n >= cap)
				return n;
		}
	}
	return n;
}

// Pumps until the machine's receiver has given up `want` characters or the
// patience runs out.
static size_t machine_collect(uint8_t *buf, size_t want, size_t cap)
{
	size_t n = 0;
	for (int k = 0; k < 400 && n < want; ++k) {
		serial_endpoint_wait(&e, 500);
		pump();
		for (;;) {
			const int c = model_machine_takes(&mdl);
			if (c < 0)
				break;
			if (n < cap)
				buf[n++] = (uint8_t)c;
		}
	}
	return n;
}

// ---- IDENT --------------------------------------------------------------

static void check_ident(void)
{
	model_init(&mdl, 4, 2);
	face.read = model_read;
	face.write = model_write;
	face.ctx = &mdl;

	size_t mark = log_mark();
	CHECK(serial_face_ident(&face) == 0, "IDENT reading \"SERI\" must be accepted");
	CHECK(strstr(log_since(mark), "SERI") != NULL, "and the line must name what it found");

	// "NONE" is rtl/plumbing/cadr_gp0_default.sv's answer: a board with a
	// GP port and nothing of ours behind it.  It is the common mistake, so
	// it must be named and not merely refused.
	mdl.ident = 0x4E4F4E45u;	/* cadr/cadr_mem.h's CADR_IDENT_NONE */
	mark = log_mark();
	CHECK(serial_face_ident(&face) == -1, "IDENT reading \"NONE\" must be refused");
	CHECK(strstr(log_since(mark), "NONE") != NULL,
	      "and the default slave must be named: the line was \"%s\"", log_since(mark));

	mdl.ident = 0xBADF00D5u;
	mark = log_mark();
	CHECK(serial_face_ident(&face) == -1, "any other word at IDENT must be refused");
	CHECK(strstr(log_since(mark), "NONE") == NULL,
	      "and a word that is not \"NONE\" must not be reported as the default slave");
	CHECK(strstr(log_since(mark), "badf00d5") != NULL || strstr(log_since(mark), "BADF00D5") != NULL,
	      "and the word that was there must be printed");
}

// ---- the cable ----------------------------------------------------------

static void check_start_puts_the_cable_down(void)
{
	fresh(4, 2);
	CHECK(mdl.ctl_writes == 1, "the cable must be put down at start, once: %u writes",
	      mdl.ctl_writes);
	CHECK(mdl.ctl == 0, "and CTL must read 0, not 0x%x", mdl.ctl);
	// The endpoint keeps its own record of what it put on the cable, so
	// that the program can tell whether there is anything to take down
	// when it stops.  The two are compared rather than either taken on
	// trust.
	CHECK(e.lines_up == 0, "and the endpoint's record of the lines agrees with what it wrote");
	CHECK(!serial_endpoint_connected(&e), "and nothing is on the cable yet");
	// Passes with nothing happening cost no writes on the bus.
	for (int k = 0; k < 5; ++k)
		pump();
	CHECK(mdl.ctl_writes == 1, "a pass in which the cable did not change writes no CTL: %u",
	      mdl.ctl_writes);
}

static void check_plug_and_unplug(void)
{
	fresh(4, 2);
	const unsigned before = mdl.ctl_writes;
	const int fd = client_open(0);
	CHECK(fd >= 0, "the client must be able to connect");
	settle();
	CHECK(serial_endpoint_connected(&e), "a connection is a device on the cable");
	CHECK(mdl.ctl_writes == before + 1, "plugging in writes CTL exactly once: %u",
	      mdl.ctl_writes - before);
	// DSR | DCD | CTS, serial_face.h's table read as literals.
	CHECK(mdl.ctl == (1u | 2u | 4u), "and it raises DSR, DCD and CTS: CTL is 0x%x", mdl.ctl);
	CHECK(e.lines_up == 1, "and the endpoint's record of the lines agrees with what it wrote");
	CHECK(e.connects == 1, "one device has attached");

	for (int k = 0; k < 5; ++k)
		pump();
	CHECK(mdl.ctl_writes == before + 1, "and a pass with no change writes no CTL again");

	close(fd);
	settle();
	CHECK(!serial_endpoint_connected(&e), "a hang-up takes the device off the cable");
	CHECK(mdl.ctl_writes == before + 2, "hanging up writes CTL exactly once more: %u",
	      mdl.ctl_writes - before);
	CHECK(mdl.ctl == 0, "and it drops all three lines: CTL is 0x%x", mdl.ctl);
	CHECK(e.lines_up == 0, "and the endpoint's record of the lines agrees again");
	CHECK(e.hangups == 1, "one device has gone");
}

// ---- the two directions -------------------------------------------------

static void check_machine_to_client(void)
{
	fresh(16, 2);
	const int fd = client_open(0);
	CHECK(fd >= 0, "the client must be able to connect");
	settle();

	static const char word[] = "CADR\r\n";
	for (size_t k = 0; k < sizeof word - 1; ++k)
		model_machine_sends(&mdl, (uint8_t)word[k]);

	uint8_t got[64];
	const size_t n = client_collect(fd, got, sizeof word - 1, sizeof got);
	CHECK(n == sizeof word - 1, "the client gets every character the machine sent: %zu of %zu",
	      n, sizeof word - 1);
	CHECK(n == sizeof word - 1 && memcmp(got, word, n) == 0,
	      "and in the order it sent them");
	CHECK(e.from_machine == sizeof word - 1, "and the endpoint counts them: %llu",
	      e.from_machine);
	CHECK(mdl.dropped == 0, "and the port dropped none of them");
	close(fd);
	settle();
}

static void check_client_to_machine(void)
{
	fresh(16, 8);
	const int fd = client_open(0);
	CHECK(fd >= 0, "the client must be able to connect");
	settle();

	static const char typed[] = "hello";
	CHECK(write(fd, typed, sizeof typed - 1) == (ssize_t)(sizeof typed - 1),
	      "the client must be able to type");

	uint8_t got[64];
	const size_t n = machine_collect(got, sizeof typed - 1, sizeof got);
	CHECK(n == sizeof typed - 1, "the machine's receiver gets every character typed: %zu of %zu",
	      n, sizeof typed - 1);
	CHECK(n == sizeof typed - 1 && memcmp(got, typed, n) == 0,
	      "and in the order they were typed");
	CHECK(e.to_machine == sizeof typed - 1, "and the endpoint counts them: %llu", e.to_machine);
	close(fd);
	settle();
}

// A burst long enough to wrap both rings, each way, so that a queue whose
// wrap is wrong is a wrong order and not a lucky pass.
static void check_bursts_both_ways(void)
{
	enum { BURST = 900 };
	static uint8_t sent[BURST], got[BURST * 2];

	fresh(MODEL_PORT_MAX, 8);
	int fd = client_open(0);
	CHECK(fd >= 0, "the client must be able to connect");
	settle();
	for (int k = 0; k < BURST; ++k) {
		sent[k] = (uint8_t)(k * 7u + 3u);
		model_machine_sends(&mdl, sent[k]);
	}
	size_t n = client_collect(fd, got, BURST, sizeof got);
	CHECK(n == BURST, "a burst of %d from the machine arrives whole: %zu", BURST, n);
	CHECK(n == BURST && memcmp(got, sent, BURST) == 0, "and in order");
	close(fd);
	settle();

	// The other way, with a receiver of two, so that the burst is handed
	// over a couple of characters at a time over many passes.
	fresh(16, 2);
	fd = client_open(0);
	CHECK(fd >= 0, "the client must be able to connect");
	settle();
	for (int k = 0; k < BURST; ++k)
		sent[k] = (uint8_t)(k * 11u + 5u);
	size_t off = 0;
	unsigned biggest_inbox = 0;
	size_t back = 0;
	for (int k = 0; k < 4000 && (off < BURST || back < BURST); ++k) {
		if (off < BURST) {
			const ssize_t w = write(fd, sent + off, (size_t)(BURST - off));
			if (w > 0)
				off += (size_t)w;
		}
		serial_endpoint_wait(&e, 500);
		pump();
		if (serial_endpoint_inbox(&e) > biggest_inbox)
			biggest_inbox = serial_endpoint_inbox(&e);
		for (;;) {
			const int c = model_machine_takes(&mdl);
			if (c < 0)
				break;
			if (back < sizeof got)
				got[back++] = (uint8_t)c;
		}
	}
	CHECK(back == BURST, "a burst of %d typed at the client reaches the machine whole: %zu",
	      BURST, back);
	CHECK(back == BURST && memcmp(got, sent, BURST) == 0, "and in order");
	// muir's own bound: what is already waiting for the receiver counts
	// against what may be read off the socket, so the queue here never
	// passes the backlog and the rest is held back by TCP's window.
	CHECK(biggest_inbox <= SER_BACKLOG,
	      "and what waits here for the receiver never passes the backlog of %u: it reached %u",
	      SER_BACKLOG, biggest_inbox);
	close(fd);
	settle();
}

// ---- one device at a time -----------------------------------------------

static void check_second_client_turned_away(void)
{
	fresh(16, 8);
	const int a = client_open(0);
	CHECK(a >= 0, "the first client must be able to connect");
	settle();
	CHECK(e.connects == 1, "one device is on the cable");

	const int b = client_open(0);
	CHECK(b >= 0, "the second client's connect(2) succeeds --- it is accepted and then told");
	settle();
	CHECK(e.refused == 1, "and it is turned away: %lu refused", e.refused);
	CHECK(e.connects == 1, "the device on the cable is still the first: %lu connects",
	      e.connects);

	uint8_t got[16];
	CHECK(client_drain(b, got, sizeof got) == -1,
	      "the second client's socket is closed under it rather than left ringing");

	// And the first is still served.
	model_machine_sends(&mdl, 'Z');
	const size_t n = client_collect(a, got, 1, sizeof got);
	CHECK(n == 1 && got[0] == 'Z', "and the first client goes on being served");
	close(a);
	close(b);
	settle();
}

static void check_hangup_and_reconnect(void)
{
	fresh(16, 8);
	int fd = client_open(0);
	CHECK(fd >= 0, "the first client must be able to connect");
	settle();
	close(fd);
	settle();
	CHECK(!serial_endpoint_connected(&e), "the cable is empty after the hang-up");

	fd = client_open(0);
	CHECK(fd >= 0, "and somebody may attach again");
	settle();
	CHECK(serial_endpoint_connected(&e), "the new device is on the cable");
	CHECK(e.connects == 2, "two devices have attached: %lu", e.connects);
	CHECK(mdl.ctl == (1u | 2u | 4u), "and the lines are up again: CTL is 0x%x", mdl.ctl);

	model_machine_sends(&mdl, 'K');
	uint8_t got[8];
	const size_t n = client_collect(fd, got, 1, sizeof got);
	CHECK(n == 1 && got[0] == 'K', "and it is served");
	close(fd);
	settle();
}

// muir's rule, and the reason the device that is there is served before a new
// one is accepted: "someone who hangs up and attaches again is not turned away
// by the connection they have just dropped", and "a device that went and
// another that came in the same turn leaves the port plugged in throughout,
// which is one device on the cable rather than none".
//
// Both events are made to be waiting before a SINGLE pass runs, so the
// ordering inside that pass is what decides the outcome and the check is not
// a race.
static void check_one_device_replaces_another_in_one_turn(void)
{
	fresh(16, 8);
	const int a = client_open(0);
	CHECK(a >= 0, "the first client must be able to connect");
	settle();
	const unsigned ctl_writes_before = mdl.ctl_writes;
	CHECK(serial_endpoint_connected(&e), "the first device is on the cable");

	close(a);
	const int b = client_open(0);
	CHECK(b >= 0, "the second client must be able to connect");
	// The FIN and the new connection are both in the kernel before the one
	// pass that has to see them together.
	usleep(50000);
	pump();

	CHECK(e.refused == 0,
	      "a device that arrives as another goes must not be turned away by the connection "
	      "just dropped: %lu refused", e.refused);
	CHECK(serial_endpoint_connected(&e), "the new device is on the cable");
	CHECK(mdl.ctl_writes == ctl_writes_before,
	      "and the cable did not flicker: one device throughout, so no line moved (%u writes)",
	      mdl.ctl_writes - ctl_writes_before);
	CHECK(mdl.ctl == (1u | 2u | 4u), "the lines are still up: CTL is 0x%x", mdl.ctl);

	model_machine_sends(&mdl, 'Q');
	uint8_t got[8];
	const size_t n = client_collect(b, got, 1, sizeof got);
	CHECK(n == 1 && got[0] == 'Q', "and the new device is served");
	close(b);
	settle();
}

// ---- what a hang-up throws away -----------------------------------------

static void check_outbox_dropped_on_hangup(void)
{
	fresh(MODEL_PORT_MAX, 8);
	// A small send buffer on the listener, which the accepted socket
	// inherits, and a small receive buffer on the client: a far end that
	// has stopped reading then fills in a few kilobytes.
	const int small = 2048;
	setsockopt(e.listener, SOL_SOCKET, SO_SNDBUF, &small, sizeof small);
	const int fd = client_open(512);
	CHECK(fd >= 0, "the client must be able to connect");
	settle();

	// The client never reads.  The machine goes on transmitting until
	// characters are standing here that the socket has not taken.
	unsigned held = 0;
	for (int round = 0; round < 200 && !held; ++round) {
		for (int k = 0; k < 256; ++k)
			model_machine_sends(&mdl, (uint8_t)('a' + (k & 15)));
		pump();
		held = serial_endpoint_outbox(&e);
	}
	CHECK(held > 0, "a client that does not read leaves characters standing here");

	close(fd);
	settle();
	CHECK(!serial_endpoint_connected(&e), "and then hangs up");
	CHECK(serial_endpoint_outbox(&e) == 0,
	      "a cable pulled out drops whatever was on the wire: %u characters still held",
	      serial_endpoint_outbox(&e));
	CHECK(e.dropped_on_hangup > 0, "and what went is counted: %llu", e.dropped_on_hangup);

	// And the next device is not handed the last one's characters.
	const int next = client_open(0);
	CHECK(next >= 0, "somebody attaches again");
	settle();
	model_machine_sends(&mdl, '!');
	uint8_t got[64];
	const size_t n = client_collect(next, got, 1, sizeof got);
	CHECK(n >= 1 && got[0] == '!',
	      "and the first character it sees is the first the machine sent it, not the last "
	      "device's leavings");
	close(next);
	settle();
}

// ---- with nobody on the cable -------------------------------------------

static void check_dropped_with_nobody_connected(void)
{
	fresh(4, 8);
	for (int k = 0; k < 20; ++k)
		model_machine_sends(&mdl, (uint8_t)('A' + k));
	settle();
	// Four fitted in the port and sixteen did not.  The arithmetic is the
	// model's own and is written out rather than taken from the code under
	// test.
	CHECK(mdl.dropped == 16, "with nobody on the cable the PORT drops what will not fit: %u",
	      mdl.dropped);
	CHECK(serial_endpoint_outbox(&e) == 0,
	      "and nothing is queued here for a device that is not there: %u",
	      serial_endpoint_outbox(&e));
	CHECK(e.from_machine == 0, "and nothing was taken off the port: %llu", e.from_machine);
	// Reading RDATA CONSUMES, so a program that drained the port with
	// nobody to give the characters to would lose them where the port's
	// own counter could not count them.
	CHECK(mdl.port_len == 4,
	      "the characters the port did hold are still there, not consumed and thrown away: %u",
	      mdl.port_len);
}

// ---- the receiver having no room ----------------------------------------

static void check_receiver_refuses_and_is_offered_again(void)
{
	fresh(16, 2);
	const int fd = client_open(0);
	CHECK(fd >= 0, "the client must be able to connect");
	settle();

	static const char typed[] = "abcde";
	CHECK(write(fd, typed, 5) == 5, "five characters typed at a receiver that holds two");
	settle();
	CHECK(e.refused_by_receiver > 0,
	      "the receiver has no room for all five and says so: %lu refusals",
	      e.refused_by_receiver);
	CHECK(mdl.recv_len == 2, "it took the two it had room for: %u", mdl.recv_len);
	CHECK(serial_endpoint_inbox(&e) == 3, "and three wait here: %u", serial_endpoint_inbox(&e));
	CHECK(mdl.wdata_lost == 0,
	      "and nothing was written into a receiver with no room: %lu lost", mdl.wdata_lost);

	uint8_t got[16];
	const size_t n = machine_collect(got, 5, sizeof got);
	CHECK(n == 5, "offered again, every one of the five arrives: %zu", n);
	CHECK(n == 5 && memcmp(got, typed, 5) == 0, "and in order, none lost to a refusal");
	CHECK(mdl.wdata_lost == 0, "and still nothing was written where there was no room");
	close(fd);
	settle();
}

// ---- the face's own rules -----------------------------------------------

static void check_rdata_is_not_read_blind(void)
{
	fresh(4, 8);
	const int fd = client_open(0);
	CHECK(fd >= 0, "the client must be able to connect");
	settle();
	const unsigned long before = mdl.rdata_reads_when_empty;
	for (int k = 0; k < 10; ++k)
		pump();
	CHECK(mdl.rdata_reads_when_empty == before,
	      "reading RDATA is the one read in this face with an effect, so STAT is asked first "
	      "and an empty port is never read: %lu blind reads",
	      mdl.rdata_reads_when_empty - before);

	// And the character that IS there is taken, so the rule has not been
	// obeyed by never reading at all.
	model_machine_sends(&mdl, 'y');
	uint8_t got[8];
	const size_t n = client_collect(fd, got, 1, sizeof got);
	CHECK(n == 1 && got[0] == 'y', "and a character that is there is still taken");
	close(fd);
	settle();
}

static void check_put_asks_for_room(void)
{
	model_init(&mdl, 4, 2);
	face.read = model_read;
	face.write = model_write;
	face.ctx = &mdl;

	CHECK(serial_face_put(&face, 'p') == 1, "the receiver has room and takes the character");
	CHECK(serial_face_put(&face, 'q') == 1, "and room for a second");
	CHECK(mdl.recv_len == 2, "both are in it: %u", mdl.recv_len);
	CHECK(serial_face_put(&face, 'r') == 0, "with no room the write is not made and 0 is said");
	CHECK(mdl.wdata_lost == 0,
	      "and WDATA was not written into a full receiver, which the face says loses it: %lu",
	      mdl.wdata_lost);
	CHECK(model_machine_takes(&mdl) == 'p', "the first character out is the first in");
	CHECK(serial_face_put(&face, 'r') == 1, "and with room again the same character is taken");
	CHECK(model_machine_takes(&mdl) == 'q', "in order");
	CHECK(model_machine_takes(&mdl) == 'r', "in order");
	CHECK(model_machine_takes(&mdl) == -1, "and nothing more");
}

static void check_get_takes_one_in_order(void)
{
	model_init(&mdl, 4, 2);
	face.read = model_read;
	face.write = model_write;
	face.ctx = &mdl;

	CHECK(serial_face_get(&face) == -1, "an empty port says there is nothing");
	model_machine_sends(&mdl, 'A');
	model_machine_sends(&mdl, 'B');
	CHECK(serial_face_get(&face) == 'A', "the first character out is the first in");
	CHECK(serial_face_get(&face) == 'B', "then the second");
	CHECK(serial_face_get(&face) == -1, "then nothing");
	// A character with the top bit set must come back as 0..255 and not as
	// a negative number, which is what "-1 if none is waiting" would
	// otherwise collide with.
	model_machine_sends(&mdl, 0xFF);
	CHECK(serial_face_get(&face) == 0xFF, "and 0xFF is a character, not an empty port");
}

static void check_set_lines_writes_only_the_three(void)
{
	model_init(&mdl, 4, 2);
	face.read = model_read;
	face.write = model_write;
	face.ctx = &mdl;

	serial_face_set_lines(&face, 0xFFFFFFFFu);
	CHECK(mdl.ctl == (1u | 2u | 4u),
	      "only DSR, DCD and CTS are this end's to assert: CTL is 0x%x", mdl.ctl);
	serial_face_set_lines(&face, 0);
	CHECK(mdl.ctl == 0, "and nothing is on the cable when they are dropped: CTL is 0x%x",
	      mdl.ctl);
}

static void check_nodelay(void)
{
	fresh(4, 8);
	const int fd = client_open(0);
	CHECK(fd >= 0, "the client must be able to connect");
	settle();
	CHECK(serial_endpoint_connected(&e), "the device is on the cable");
	int on = 0;
	socklen_t n = sizeof on;
	CHECK(getsockopt(e.device, IPPROTO_TCP, TCP_NODELAY, &on, &n) == 0,
	      "the accepted socket can be asked about Nagle");
	CHECK(on != 0,
	      "a character at a time is the whole traffic here, so TCP_NODELAY is on: %d", on);
	close(fd);
	settle();
}

static void check_the_rate_is_read_out_of_mode_register_2(void)
{
	model_init(&mdl, 4, 2);
	face.read = model_read;
	face.write = model_write;
	face.ctx = &mdl;

	// MR1 in bits 7:0, MR2 in bits 15:8; the rate is MR2's low four bits.
	// model_init puts MR2 at 0o45, so rate 5.
	CHECK(serial_face_rate(&face) == 5, "the rate is MR2's low four bits: %u",
	      serial_face_rate(&face));
	mdl.mode = (0x05u << 16) | (0o56u << 8) | 0o116u;
	CHECK(serial_face_rate(&face) == 14, "and moves with them: %u", serial_face_rate(&face));

	// muir src/serial.rs, BAUD_TENTHS, which is the Signetics sheet's
	// Table 6 and MIT's own :BAUD list.  Written out as literals here.
	CHECK(serial_rate_tenths(0) == 500, "rate 0 is 50 baud");
	CHECK(serial_rate_tenths(3) == 1345, "rate 3 is 134.5 baud, which is why it is in tenths");
	CHECK(serial_rate_tenths(5) == 3000, "rate 5 is 300 baud, MIT's own default");
	CHECK(serial_rate_tenths(14) == 96000, "rate 14 is 9600 baud");
	CHECK(serial_rate_tenths(15) == 192000, "rate 15 is 19200 baud, the fastest the chip has");
	CHECK(serial_rate_tenths(16) == 500, "and the index is four bits, so 16 is 0 again");
}

// ---- the run ------------------------------------------------------------

int main(void)
{
	// A client dropped mid-write must not take the check with it: write(2)
	// on a socket the far end has closed raises SIGPIPE, whose default is
	// to end the process.
	signal(SIGPIPE, SIG_IGN);

	logf = open_memstream(&logbuf, &loglen);
	if (!logf) {
		fprintf(stderr, "FAIL: serial_test: no memory stream for the log\n");
		return 1;
	}
	cadr_log_init("  serial: ", logf);

	printf("serial_test: the cable's far end against a model of the 2651's register face, "
	       "on 127.0.0.1\n");

	printf("--- IDENT\n");
	check_ident();

	printf("--- the cable at start, and plugging in and out\n");
	check_start_puts_the_cable_down();
	check_plug_and_unplug();

	printf("--- the two directions\n");
	check_machine_to_client();
	check_client_to_machine();
	check_bursts_both_ways();

	printf("--- one device at a time\n");
	check_second_client_turned_away();
	check_hangup_and_reconnect();
	check_one_device_replaces_another_in_one_turn();

	printf("--- what a hang-up throws away, and what nobody is there to take\n");
	check_outbox_dropped_on_hangup();
	check_dropped_with_nobody_connected();

	printf("--- the receiver having no room\n");
	check_receiver_refuses_and_is_offered_again();

	printf("--- the face's own rules\n");
	check_rdata_is_not_read_blind();
	check_put_asks_for_room();
	check_get_takes_one_in_order();
	check_set_lines_writes_only_the_three();
	check_nodelay();
	check_the_rate_is_read_out_of_mode_register_2();

	if (bound)
		serial_endpoint_close(&e);

	fflush(logf);
	if (bad) {
		fprintf(stderr, "--- what the endpoint said while that happened ---\n%s",
			logbuf ? logbuf : "");
		fprintf(stderr, "FAIL: serial_test: %u checks, %d failed\n", checks, bad);
		return 1;
	}
	printf("serial_test: %u checks, all passed\n", checks);
	return 0;
}
