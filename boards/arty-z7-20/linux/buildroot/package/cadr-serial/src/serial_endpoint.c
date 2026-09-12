// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The far end of the cable at J9 on a TCP socket; `serial_endpoint.h` says
// what it is and which of muir's decisions each part carries.

#define _GNU_SOURCE

#include "serial_endpoint.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cadr/cadr_log.h>

// ---- the rings ----------------------------------------------------------
//
// A ring rather than a memmove, because the outbox is written a character at
// a time by the machine and drained in runs by the socket, and the inbox the
// other way round.  `run` is how many characters stand contiguously at the
// head, which is what write(2) can be handed without copying.

static void q_clear(struct ser_queue *q)
{
	q->head = q->len = 0;
}

static int q_push(struct ser_queue *q, uint8_t c)
{
	if (q->len == SER_QUEUE_CAP)
		return 0;
	q->b[(q->head + q->len) % SER_QUEUE_CAP] = c;
	++q->len;
	return 1;
}

static unsigned q_run(const struct ser_queue *q)
{
	const unsigned to_end = SER_QUEUE_CAP - q->head;
	return q->len < to_end ? q->len : to_end;
}

static void q_drop(struct ser_queue *q, unsigned n)
{
	q->head = (q->head + n) % SER_QUEUE_CAP;
	q->len -= n;
}

// ---- the socket ---------------------------------------------------------

static int set_nonblocking(int fd)
{
	const int fl = fcntl(fd, F_GETFL, 0);
	return fl < 0 ? -1 : fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

int serial_endpoint_bind(struct serial_endpoint *e, const char *bind_addr, unsigned port)
{
	memset(e, 0, sizeof *e);
	e->listener = -1;
	e->device = -1;
	e->trace = 1;
	struct sockaddr_in a;
	memset(&a, 0, sizeof a);
	a.sin_family = AF_INET;
	a.sin_port = htons((uint16_t)port);
	if (!bind_addr || !*bind_addr) {
		a.sin_addr.s_addr = htonl(INADDR_ANY);
	} else if (inet_pton(AF_INET, bind_addr, &a.sin_addr) != 1) {
		say("--bind %s is not a dotted quad", bind_addr);
		return -1;
	}
	const int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) {
		say("socket: %s", strerror(errno));
		return -1;
	}
	const int one = 1;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
	if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0) {
		say("binding %s:%u: %s", bind_addr && *bind_addr ? bind_addr : "0.0.0.0", port,
		    strerror(errno));
		close(fd);
		return -1;
	}
	// A backlog of 2 and not 0: one device is served and the next is
	// turned away, and turning it away means accepting it first so that
	// it is told rather than left ringing.
	if (listen(fd, 2) < 0) {
		say("listen: %s", strerror(errno));
		close(fd);
		return -1;
	}
	set_nonblocking(fd);
	e->listener = fd;
	return 0;
}

unsigned serial_endpoint_port(const struct serial_endpoint *e)
{
	struct sockaddr_in a;
	socklen_t n = sizeof a;
	if (getsockname(e->listener, (struct sockaddr *)&a, &n) < 0)
		return 0;
	return ntohs(a.sin_port);
}

int serial_endpoint_connected(const struct serial_endpoint *e)
{
	return e->device >= 0;
}

void serial_endpoint_close(struct serial_endpoint *e)
{
	if (e->device >= 0)
		close(e->device);
	if (e->listener >= 0)
		close(e->listener);
	e->device = e->listener = -1;
}

// ---- the cable ----------------------------------------------------------

void serial_endpoint_start(struct serial_endpoint *e, struct serial_face *f)
{
	// Down, and said to the fabric rather than assumed of it.  What the
	// CTL register holds before this program runs is whatever the last
	// one left, and a device on the cable is a thing MIT's driver waits
	// for: it must not be told one is there before one is.
	serial_face_set_lines(f, 0);
	e->lines_up = 0;
}

// muir's `Endpoint::service`, line for line.
enum ser_change serial_endpoint_service(struct serial_endpoint *e, size_t room,
					uint8_t *typed, size_t *ntyped)
{
	const int was = e->device >= 0;
	int gone = 0;

	// The port's characters, as far as the socket will take them now.
	if (e->device >= 0) {
		while (e->outbox.len) {
			const unsigned run = q_run(&e->outbox);
			const ssize_t n = write(e->device, e->outbox.b + e->outbox.head, run);
			if (n == 0) {
				gone = 1;
				break;
			}
			if (n < 0) {
				if (errno == EWOULDBLOCK || errno == EAGAIN)
					break;
				if (errno == EINTR)
					continue;
				say("%s: %s", e->who, strerror(errno));
				gone = 1;
				break;
			}
			q_drop(&e->outbox, (unsigned)n);
		}
	}

	// What was typed at it, up to `room`.
	*ntyped = 0;
	if (!gone && e->device >= 0) {
		uint8_t buf[256];
		while (*ntyped < room) {
			size_t want = sizeof buf;
			if (want > room - *ntyped)
				want = room - *ntyped;
			const ssize_t n = read(e->device, buf, want);
			if (n == 0) {
				gone = 1;
				break;
			}
			if (n < 0) {
				if (errno == EWOULDBLOCK || errno == EAGAIN)
					break;
				if (errno == EINTR)
					continue;
				say("%s: %s", e->who, strerror(errno));
				gone = 1;
				break;
			}
			memcpy(typed + *ntyped, buf, (size_t)n);
			*ntyped += (size_t)n;
		}
	}

	if (gone) {
		if (e->trace)
			say("%s hung up%s", e->who,
			    e->outbox.len ? ", dropping what the port had not sent it" : "");
		close(e->device);
		e->device = -1;
		++e->hangups;
		// What the port sent and the device never took goes with it: a
		// cable pulled out drops whatever was on the wire.
		e->dropped_on_hangup += e->outbox.len;
		q_clear(&e->outbox);
	}

	// **AFTER the device that is there has been served**, so that somebody
	// who hangs up and attaches again in the same turn is not turned away
	// by the connection they have just dropped.  muir's own comment.
	for (;;) {
		struct sockaddr_in from;
		socklen_t n = sizeof from;
		const int fd = accept(e->listener, (struct sockaddr *)&from, &n);
		if (fd < 0) {
			if (errno == EWOULDBLOCK || errno == EAGAIN)
				break;
			if (errno == EINTR)
				continue;
			say("accept: %s", strerror(errno));
			break;
		}
		char host[INET_ADDRSTRLEN] = "?";
		char who[64];
		inet_ntop(AF_INET, &from.sin_addr, host, sizeof host);
		snprintf(who, sizeof who, "%s:%u", host, ntohs(from.sin_port));
		if (e->device >= 0) {
			if (e->trace)
				say("%s turned away: a device is on the cable", who);
			++e->refused;
			close(fd);
			continue;
		}
		if (set_nonblocking(fd) < 0) {
			say("%s: %s", who, strerror(errno));
			close(fd);
			continue;
		}
		// A character at a time is the whole traffic here; waiting to
		// coalesce would only add latency.
		const int one = 1;
		setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
		e->device = fd;
		snprintf(e->who, sizeof e->who, "%s", who);
		++e->connects;
		if (e->trace)
			say("%s connected: the device is on the cable, DSR, DCD and CTS up", e->who);
	}

	const int is = e->device >= 0;
	if (!was && is)
		return SER_CHANGE_PLUGGED_IN;
	if (was && !is)
		return SER_CHANGE_HUNG_UP;
	return SER_CHANGE_NONE;
}

// muir's `Endpoint::poll_cable`, with the fabric's register face where muir
// has `serial::Cable`.
void serial_endpoint_pump(struct serial_endpoint *e, struct serial_face *f)
{
	// 1. What the port has finished sending.
	//
	// **ONLY WHILE A DEVICE IS ON THE CABLE**, which is where this parts
	// from muir.  muir's `Cable::take` yields nothing while nothing is
	// plugged in, because the chip it models will not transmit without
	// CTS; the fabric's face promises no such thing, and a read of RDATA
	// CONSUMES the character (`serial_face.h`).  So a program that drained
	// the port with nobody to give the characters to would destroy them
	// where the fabric's own DROPPED counter --- which counts what IT
	// dropped --- could not count them, and the one number that says how
	// much the line lost would understate it.  Left alone, the port fills
	// and the fabric counts the rest.
	//
	// The face does not say how deep the port's queue is and nothing here
	// depends on it: RDATA is drained until it reads invalid, which is
	// right for a holding register of one and for a FIFO of sixteen.
	if (e->device >= 0) {
		while (e->outbox.len < SER_QUEUE_CAP) {
			const int c = serial_face_get(f);
			if (c < 0)
				break;
			q_push(&e->outbox, (uint8_t)c);
			++e->from_machine;
		}
		// Passes on which the far end had stopped reading, TCP's
		// window was shut and the port was therefore left undrained.
		// Counted, not an error: a serial line with no flow control
		// loses characters when the far end cannot keep up, and the
		// ones lost here are lost by the PORT and appear in its own
		// DROPPED.  This is the number that says why.
		if (e->outbox.len == SER_QUEUE_CAP)
			++e->stalled_port;
	}

	// 2. One turn at the socket.  muir's
	// `BACKLOG.saturating_sub(cable.pending())`: what is already waiting
	// for the receiver counts against what may be read off the socket, so
	// that a far end typing faster than the machine reads is held back by
	// TCP's own window and not by a queue growing here.
	const size_t room = e->inbox.len >= SER_BACKLOG ? 0 : SER_BACKLOG - e->inbox.len;
	uint8_t typed[SER_BACKLOG];
	size_t ntyped = 0;
	const enum ser_change change = serial_endpoint_service(e, room, typed, &ntyped);

	// 3. The modem-control lines, written when the cable changes and at no
	// other time.  A device that went and another that came in the same
	// turn leaves the port plugged in throughout, which is one device on
	// the cable rather than none --- so the lines do not flicker and MIT's
	// driver does not see a carrier drop that never happened.
	if (change == SER_CHANGE_PLUGGED_IN) {
		serial_face_set_lines(f, SER_CTL_PLUGGED);
		e->lines_up = 1;
	} else if (change == SER_CHANGE_HUNG_UP) {
		serial_face_set_lines(f, 0);
		e->lines_up = 0;
		// **THE INBOX IS NOT CLEARED, AND THAT IS muir's DECISION
		// RATHER THAN AN OVERSIGHT.**  `serial::Cable`'s doc: characters
		// the far end sends "wait here until the receiver takes them,
		// where a line would lose what was sent while the receiver was
		// off: this far end waits for its prompt".  The outbox goes
		// because it was on the wire; what was typed has not reached
		// the wire yet, and the machine is entitled to it.
	}

	// 4. What was typed goes on the cable...
	for (size_t k = 0; k < ntyped; ++k)
		q_push(&e->inbox, typed[k]);

	// 5. ...and into the machine's receiver, as far as it has room.  A
	// character the receiver refuses stays at the head of the queue and is
	// offered again next pass: `serial_face_put` writes nothing when
	// TX_ROOM is down, so refusing is not losing.
	while (e->inbox.len) {
		if (!serial_face_put(f, e->inbox.b[e->inbox.head])) {
			++e->refused_by_receiver;
			break;
		}
		q_drop(&e->inbox, 1);
		++e->to_machine;
	}
}

void serial_endpoint_wait(struct serial_endpoint *e, unsigned timeout_us)
{
	struct pollfd fds[2];
	nfds_t n = 0;
	fds[n].fd = e->listener;
	fds[n].events = POLLIN;
	fds[n].revents = 0;
	++n;
	if (e->device >= 0) {
		fds[n].fd = e->device;
		fds[n].events = POLLIN;
		// Only while something is waiting to go out: a socket that is
		// always writable would make this a busy loop.
		if (e->outbox.len)
			fds[n].events |= POLLOUT;
		fds[n].revents = 0;
		++n;
	}
	// ppoll and not poll, because the interval that matters here is
	// shorter than a millisecond at the rates the 2651 can be programmed
	// to and poll(2) cannot express it.
	struct timespec t;
	t.tv_sec = timeout_us / 1000000u;
	t.tv_nsec = (long)(timeout_us % 1000000u) * 1000L;
	if (ppoll(fds, n, &t, NULL) < 0 && errno != EINTR)
		say("poll: %s", strerror(errno));
}
