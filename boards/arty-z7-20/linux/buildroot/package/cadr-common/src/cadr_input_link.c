// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The local input link, both ends.  `cadr/cadr_input_link.h` says what it is
// for, what crosses it, and why a second source of keys may not write the
// face itself.
//
// **NOTHING HERE BLOCKS.**  The server is inside the terminal's own poll
// loop, which is also serving the screen, so every descriptor is
// non-blocking and a partial record is kept until the rest of it arrives.
// The client's send is non-blocking too: a terminal that has stopped reading
// must not stall the program reading the keyboard, and a record that will not
// go is a record dropped with `EAGAIN`, which the caller counts.

#include "cadr/cadr_input_link.h"

#include "cadr/cadr_log.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

// ---- the record ----------------------------------------------------------

static void put16(uint8_t *b, int16_t v)
{
	const uint16_t u = (uint16_t)v;
	b[0] = (uint8_t)(u & 0xFFu);
	b[1] = (uint8_t)(u >> 8);
}

static int16_t get16(const uint8_t *b)
{
	return (int16_t)((uint16_t)b[0] | ((uint16_t)b[1] << 8));
}

static void put32(uint8_t *b, uint32_t v)
{
	b[0] = (uint8_t)(v & 0xFFu);
	b[1] = (uint8_t)((v >> 8) & 0xFFu);
	b[2] = (uint8_t)((v >> 16) & 0xFFu);
	b[3] = (uint8_t)((v >> 24) & 0xFFu);
}

static uint32_t get32(const uint8_t *b)
{
	return (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16)
	     | ((uint32_t)b[3] << 24);
}

void cadr_input_encode(const struct cadr_input_event *e, uint8_t out[CADR_INPUT_LINK_MSG])
{
	memset(out, 0, CADR_INPUT_LINK_MSG);
	out[0] = e->type;
	out[1] = e->down ? 1u : 0u;
	out[2] = (uint8_t)(e->buttons & 7u);
	// out[3] is the one spare byte, and it is written as zero rather than
	// left alone so that two encodings of one event are the same twelve
	// bytes --- a check comparing records byte for byte is worth more than
	// a byte saved.
	put16(out + 4, e->dx);
	put16(out + 6, e->dy);
	put32(out + 8, e->keysym);
}

int cadr_input_decode(const uint8_t in[CADR_INPUT_LINK_MSG], struct cadr_input_event *e)
{
	memset(e, 0, sizeof *e);
	e->type = in[0];
	e->down = in[1] ? 1u : 0u;
	e->buttons = (uint8_t)(in[2] & 7u);
	e->dx = get16(in + 4);
	e->dy = get16(in + 6);
	e->keysym = get32(in + 8);
	// A type this does not know is a client speaking something else, and
	// the answer is to drop the client rather than to guess at a keystroke.
	if (e->type != CADR_INPUT_KEY && e->type != CADR_INPUT_POINTER)
		return -1;
	return 0;
}

static void hello_bytes(uint8_t out[CADR_INPUT_LINK_HELLO])
{
	put32(out, CADR_INPUT_LINK_MAGIC);
	put32(out + 4, CADR_INPUT_LINK_VERSION);
}

static int nonblocking(int fd)
{
	const int fl = fcntl(fd, F_GETFL, 0);
	return fl < 0 ? -1 : fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

static int sun_path_of(struct sockaddr_un *a, const char *path)
{
	memset(a, 0, sizeof *a);
	a->sun_family = AF_UNIX;
	if (strlen(path) >= sizeof a->sun_path)
		return -1;
	// A path longer than the field is refused by name.  Truncating it
	// would bind a DIFFERENT socket and then say nothing, which is the
	// failure this project keeps meeting in other places.
	strncpy(a->sun_path, path, sizeof a->sun_path - 1);
	return 0;
}

// ---- the server ----------------------------------------------------------

int cadr_input_link_listen(struct cadr_input_link *l, const char *path)
{
	memset(l, 0, sizeof *l);
	l->listener = -1;
	if (!path)
		path = CADR_INPUT_LINK_PATH;
	struct sockaddr_un addr;
	if (sun_path_of(&addr, path) < 0) {
		say("the input link's path is too long for a Unix socket: %s", path);
		return -1;
	}
	const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) {
		say("the input link: no socket (%s)", strerror(errno));
		return -1;
	}
	// A path left behind by a run that was killed.  On this image /var/run
	// is a tmpfs and there can be none, which is not a reason to leave the
	// case open: this also runs on a build host.
	unlink(path);
	if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
		say("the input link: cannot bind %s (%s)", path, strerror(errno));
		close(fd);
		return -1;
	}
	if (listen(fd, CADR_INPUT_LINK_MAX_CLIENTS) < 0) {
		say("the input link: cannot listen on %s (%s)", path, strerror(errno));
		close(fd);
		unlink(path);
		return -1;
	}
	if (nonblocking(fd) < 0) {
		say("the input link: cannot make %s non-blocking (%s)", path, strerror(errno));
		close(fd);
		unlink(path);
		return -1;
	}
	l->listener = fd;
	return 0;
}

unsigned cadr_input_link_clients(const struct cadr_input_link *l)
{
	return l->clients;
}

unsigned cadr_input_link_pollfds(const struct cadr_input_link *l, struct pollfd *fds, unsigned max)
{
	unsigned n = 0;
	if (l->listener < 0 || max == 0)
		return 0;
	fds[n].fd = l->listener;
	fds[n].events = POLLIN;
	fds[n].revents = 0;
	++n;
	for (unsigned k = 0; k < l->clients && n < max; ++k) {
		fds[n].fd = l->client[k].fd;
		fds[n].events = POLLIN;
		fds[n].revents = 0;
		++n;
	}
	return n;
}

// The OR of what every client holds: one mouse, three switches, and a switch
// held in one place is not lifted by another letting go.
static unsigned buttons_or(const struct cadr_input_link *l)
{
	unsigned mask = 0;
	for (unsigned k = 0; k < l->clients; ++k)
		mask |= l->client[k].buttons;
	return mask & 7u;
}

static int holds(const struct cadr_input_client *c, uint32_t keysym)
{
	for (unsigned i = 0; i < c->downs; ++i)
		if (c->down[i] == keysym)
			return 1;
	return 0;
}

static void note_down(struct cadr_input_client *c, uint32_t keysym, int down)
{
	if (down) {
		if (!holds(c, keysym) && c->downs < CADR_INPUT_LINK_DOWN_MAX)
			c->down[c->downs++] = keysym;
		return;
	}
	for (unsigned i = 0; i < c->downs; ++i) {
		if (c->down[i] != keysym)
			continue;
		memmove(&c->down[i], &c->down[i + 1],
			(c->downs - i - 1) * sizeof c->down[0]);
		--c->downs;
		return;
	}
}

static void forget(struct cadr_input_link *l, unsigned k, const struct cadr_input_sink *sink,
		   const char *why)
{
	struct cadr_input_client *c = &l->client[k];
	// **EVERY KEY THIS CLIENT HELD COMES UP.**  See the header: a Control
	// held by a program that died is a Control held for the rest of the
	// machine's run.  Oldest first, which is the order the machine saw them
	// go down in.
	if (sink && sink->key)
		for (unsigned i = 0; i < c->downs; ++i)
			sink->key(sink->ctx, c->down[i], 0);
	c->downs = 0;
	c->buttons = 0;
	if (c->fd >= 0)
		close(c->fd);
	l->client[k] = l->client[l->clients - 1];
	memset(&l->client[l->clients - 1], 0, sizeof l->client[0]);
	l->client[l->clients - 1].fd = -1;
	--l->clients;
	++l->drops;
	say("the input link: a source is gone (%s); %u attached", why, l->clients);
	// The switches after it, so that the far end is told the new level
	// rather than left holding the departed client's.
	if (sink && sink->buttons)
		sink->buttons(sink->ctx, buttons_or(l));
}

static void accept_one(struct cadr_input_link *l)
{
	const int fd = accept(l->listener, NULL, NULL);
	if (fd < 0)
		return;
	if (l->clients >= CADR_INPUT_LINK_MAX_CLIENTS) {
		++l->refused;
		say("the input link: a source was refused, %u already attached",
		    l->clients);
		close(fd);
		return;
	}
	if (nonblocking(fd) < 0) {
		close(fd);
		return;
	}
	struct cadr_input_client *c = &l->client[l->clients];
	memset(c, 0, sizeof *c);
	c->fd = fd;
	++l->clients;
	++l->connects;
}

// One client's bytes: the greeting if it is still owed, then whole records.
// 0, or -1 with `why` set for a client that must go.
static int step(struct cadr_input_link *l, struct cadr_input_client *c,
		const struct cadr_input_sink *sink, const char **why)
{
	const ssize_t got = read(c->fd, c->in + c->in_len, sizeof c->in - c->in_len);
	if (got == 0) {
		*why = "it closed the connection";
		return -1;
	}
	if (got < 0) {
		if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
			return 0;
		*why = strerror(errno);
		return -1;
	}
	c->in_len += (size_t)got;

	if (!c->greeted) {
		if (c->in_len < CADR_INPUT_LINK_HELLO)
			return 0;
		if (get32(c->in) != CADR_INPUT_LINK_MAGIC
		    || get32(c->in + 4) != CADR_INPUT_LINK_VERSION) {
			// Not a client of ours, or one of another version.
			// Its bytes must never be read as keystrokes.
			++l->rejected;
			*why = "it did not say INLK and this version";
			return -1;
		}
		uint8_t hello[CADR_INPUT_LINK_HELLO];
		hello_bytes(hello);
		// The only thing that ever goes the other way.  A short write
		// on eight bytes into a fresh socket buffer cannot happen; if
		// it somehow did, the client would wait and time out, which is
		// its own affair and not a keystroke lost.
		if (write(c->fd, hello, sizeof hello) != (ssize_t)sizeof hello) {
			*why = "the greeting would not go back";
			return -1;
		}
		c->greeted = 1;
		memmove(c->in, c->in + CADR_INPUT_LINK_HELLO,
			c->in_len - CADR_INPUT_LINK_HELLO);
		c->in_len -= CADR_INPUT_LINK_HELLO;
		say("the input link: a source attached; %u attached", l->clients);
	}

	while (c->in_len >= CADR_INPUT_LINK_MSG) {
		struct cadr_input_event e;
		if (cadr_input_decode(c->in, &e) < 0) {
			++l->rejected;
			*why = "it sent a record of a kind this does not know";
			return -1;
		}
		memmove(c->in, c->in + CADR_INPUT_LINK_MSG,
			c->in_len - CADR_INPUT_LINK_MSG);
		c->in_len -= CADR_INPUT_LINK_MSG;
		++l->events;
		if (e.type == CADR_INPUT_KEY) {
			note_down(c, e.keysym, e.down);
			if (sink && sink->key)
				sink->key(sink->ctx, e.keysym, e.down);
			continue;
		}
		if (e.dx || e.dy) {
			if (sink && sink->move)
				sink->move(sink->ctx, e.dx, e.dy);
		}
		if (e.buttons != c->buttons) {
			c->buttons = e.buttons;
			if (sink && sink->buttons)
				sink->buttons(sink->ctx, buttons_or(l));
		}
	}
	return 0;
}

void cadr_input_link_poll(struct cadr_input_link *l, const struct pollfd *fds, unsigned n,
			  const struct cadr_input_sink *sink)
{
	if (l->listener < 0)
		return;
	for (unsigned j = 0; j < n; ++j)
		if (fds[j].fd == l->listener && (fds[j].revents & POLLIN))
			accept_one(l);

	// A client dropped below moves the last one into its place, so its
	// events are found by descriptor and not by index --- the same care
	// the screen's own poll takes with its viewers, and for the same
	// reason: otherwise the moved client is answered with somebody else's.
	for (unsigned k = 0; k < l->clients;) {
		struct cadr_input_client *c = &l->client[k];
		short ev = 0;
		for (unsigned j = 0; j < n; ++j)
			if (fds[j].fd == c->fd) {
				ev = fds[j].revents;
				break;
			}
		const char *why = NULL;
		if (ev & (POLLHUP | POLLERR))
			why = "the connection went";
		else if ((ev & POLLIN) && step(l, c, sink, &why) < 0 && !why)
			why = "it stopped making sense";
		if (why)
			forget(l, k, sink, why);
		else
			++k;
	}
}

void cadr_input_link_close(struct cadr_input_link *l, const struct cadr_input_sink *sink)
{
	while (l->clients)
		forget(l, l->clients - 1, sink, "this program is stopping");
	if (l->listener >= 0)
		close(l->listener);
	l->listener = -1;
}

// ---- the client ----------------------------------------------------------

void cadr_input_link_shut(struct cadr_input_link_client *c)
{
	if (c->fd >= 0)
		close(c->fd);
	memset(c, 0, sizeof *c);
	c->fd = -1;
}

int cadr_input_link_open(struct cadr_input_link_client *c, const char *path, const char **why)
{
	static const char *no_reason = "";
	memset(c, 0, sizeof *c);
	c->fd = -1;
	if (why)
		*why = no_reason;
	if (!path)
		path = CADR_INPUT_LINK_PATH;
	struct sockaddr_un addr;
	if (sun_path_of(&addr, path) < 0) {
		if (why)
			*why = "the path is too long for a Unix socket";
		return -1;
	}
	const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) {
		if (why)
			*why = strerror(errno);
		return -1;
	}
	// A Unix socket with somebody listening connects at once; there is no
	// route to wait for and no handshake below this one.  A refusal here
	// is a server that is not there, which is the ordinary case at boot.
	if (connect(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
		if (why)
			*why = strerror(errno);
		close(fd);
		return -1;
	}
	if (nonblocking(fd) < 0) {
		if (why)
			*why = strerror(errno);
		close(fd);
		return -1;
	}
	uint8_t hello[CADR_INPUT_LINK_HELLO];
	hello_bytes(hello);
	if (write(fd, hello, sizeof hello) != (ssize_t)sizeof hello) {
		if (why)
			*why = "the greeting would not go";
		close(fd);
		return -1;
	}
	c->fd = fd;
	return 0;
}

int cadr_input_link_greet(struct cadr_input_link_client *c, const char **why)
{
	static const char *no_reason = "";
	if (why)
		*why = no_reason;
	if (c->greeted)
		return 1;
	if (c->fd < 0) {
		if (why)
			*why = "there is no connection";
		return -1;
	}
	while (c->at < CADR_INPUT_LINK_HELLO) {
		const ssize_t got = read(c->fd, c->back + c->at, CADR_INPUT_LINK_HELLO - c->at);
		if (got > 0) {
			c->at += (unsigned)got;
			continue;
		}
		if (got < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
			return 0;
		if (got < 0 && errno == EINTR)
			continue;
		if (why)
			*why = got == 0 ? "it closed the connection" : strerror(errno);
		return -1;
	}
	if (get32(c->back) != CADR_INPUT_LINK_MAGIC
	    || get32(c->back + 4) != CADR_INPUT_LINK_VERSION) {
		// Something answered and it is not this link.  A client must
		// never pour keystrokes into it.
		if (why)
			*why = "what answered is not this link";
		return -1;
	}
	c->greeted = 1;
	return 1;
}

int cadr_input_link_send(const struct cadr_input_link_client *c, const struct cadr_input_event *e)
{
	if (c->fd < 0 || !c->greeted) {
		errno = ENOTCONN;
		return -1;
	}
	uint8_t b[CADR_INPUT_LINK_MSG];
	cadr_input_encode(e, b);
	size_t at = 0;
	while (at < sizeof b) {
		const ssize_t put = write(c->fd, b + at, sizeof b - at);
		if (put > 0) {
			at += (size_t)put;
			continue;
		}
		if (put < 0 && errno == EINTR)
			continue;
		// **A PARTIAL RECORD IS A BROKEN LINK, NOT A RETRY.**  Twelve
		// bytes into a socket with room go whole; a short write means
		// the buffer filled, which on this link means the far end has
		// stopped reading, and going on would put half a record in
		// front of the next one.  The caller connects again.
		return -1;
	}
	return 0;
}
