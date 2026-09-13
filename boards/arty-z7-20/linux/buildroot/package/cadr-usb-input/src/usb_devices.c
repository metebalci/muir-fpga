// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The devices.  `usb_devices.h` says what the scan does, why a device is
// drained when it is opened, and which one function of this file the check
// cannot reach.

#include "usb_devices.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <sys/ioctl.h>
#include <linux/input.h>

#include <cadr/cadr_log.h>

// evdev's bit arrays come out of `EVIOCGBIT` as a row of longs.
#define BITS_PER_LONG (8 * (int)sizeof(long))
#define NLONGS(n) (((n) + BITS_PER_LONG - 1) / BITS_PER_LONG)
static int bit_set(const unsigned long *b, unsigned n)
{
	return (b[n / BITS_PER_LONG] >> (n % BITS_PER_LONG)) & 1ul;
}

void usb_set_init(struct usb_set *s)
{
	memset(s, 0, sizeof *s);
	s->want_keyboard = 1;
	s->want_mouse = 1;
	for (unsigned k = 0; k < USB_MAX_DEVICES; ++k)
		s->dev[k].fd = -1;
}

int usb_set_add(struct usb_set *s, int fd, unsigned kind, const char *node, const char *label)
{
	if (s->devices >= USB_MAX_DEVICES)
		return -1;
	struct usb_device *d = &s->dev[s->devices];
	memset(d, 0, sizeof *d);
	d->fd = fd;
	d->kind = kind;
	snprintf(d->node, sizeof d->node, "%s", node ? node : "?");
	snprintf(d->label, sizeof d->label, "%s", label ? label : "");
	usb_kbd_init(&d->kbd);
	usb_mouse_init(&d->mouse);
	++s->devices;
	++s->opened;
	return 0;
}

static int is_refused(const struct usb_set *s, const char *node)
{
	for (unsigned k = 0; k < s->refuseds; ++k)
		if (strcmp(s->refused[k], node) == 0)
			return 1;
	return 0;
}

static int is_open(const struct usb_set *s, const char *node)
{
	for (unsigned k = 0; k < s->devices; ++k)
		if (strcmp(s->dev[k].node, node) == 0)
			return 1;
	return 0;
}

static void refuse(struct usb_set *s, const char *node)
{
	if (s->refuseds >= USB_MAX_REFUSED)
		return;
	const size_t n = strlen(node);
	// **A NAME TOO LONG IS NOT REMEMBERED AT ALL.**  Half a name would
	// refuse a node that is not the one examined, and the node examined
	// would be examined again every scan --- which is the harmless half of
	// the pair, so the harmful half is what is refused here.
	// `usb_scan_names` already declines to report such a name; this is the
	// second door on the same room, and it is also what lets the compiler
	// see that the copy fits.
	if (n >= USB_NAME_MAX)
		return;
	memcpy(s->refused[s->refuseds], node, n + 1);
	++s->refuseds;
}

unsigned usb_scan_names(const char *dir, char names[][USB_NAME_MAX], unsigned max)
{
	DIR *d = opendir(dir);
	if (!d)
		return 0;
	unsigned n = 0;
	const struct dirent *e;
	while ((e = readdir(d)) && n < max) {
		if (strncmp(e->d_name, "event", 5) != 0)
			continue;
		const size_t len = strlen(e->d_name);
		// A name too long for a slot is skipped rather than cut short,
		// and the length is used for the copy: a `snprintf` with the
		// guard above it is the same thing to a reader and not to the
		// board's own compiler, which reports `-Wformat-truncation`
		// where the build host's does not.
		if (len >= USB_NAME_MAX)
			continue;
		memcpy(names[n], e->d_name, len + 1);
		++n;
	}
	closedir(d);
	// Sorted, so that a board with several devices opens them in the same
	// order at every boot and a log reads the same twice.  `readdir` gives
	// no order at all.
	//
	// **WRITTEN WITH memcpy AND NOT snprintf, BECAUSE THE CROSS COMPILER
	// SAID SO.**  Both arguments of a `snprintf(names[j], ..., "%s",
	// names[j - 1])` are slots of one array, and the standard declares
	// them `restrict`: gcc 14 for the board reports `-Wrestrict` on it
	// where the build host's gcc is silent.  That is this repository's own
	// lesson about the runner's Verilator being stricter than the local
	// one, met in C for the second time in these packages.  The slots are
	// fixed-size, so a copy of the whole slot is what this wants anyway.
	for (unsigned i = 1; i < n; ++i) {
		char tmp[USB_NAME_MAX];
		memcpy(tmp, names[i], USB_NAME_MAX);
		unsigned j = i;
		while (j && strcmp(names[j - 1], tmp) > 0) {
			memcpy(names[j], names[j - 1], USB_NAME_MAX);
			--j;
		}
		memcpy(names[j], tmp, USB_NAME_MAX);
	}
	return n;
}

// **THE ONE FUNCTION THE CHECK CANNOT REACH.**  `EVIOCGBIT` needs a real
// evdev node and a check cannot make one without being root, so what is here
// is kept to the smallest thing that can be: ask what the device reports,
// decide which of the two it is, drain it, and hand the descriptor to
// `usb_set_add`, which the check drives directly.
static int classify(int fd)
{
	unsigned long types[NLONGS(EV_MAX + 1)];
	unsigned long keys[NLONGS(KEY_MAX + 1)];
	unsigned long rels[NLONGS(REL_MAX + 1)];
	memset(types, 0, sizeof types);
	memset(keys, 0, sizeof keys);
	memset(rels, 0, sizeof rels);
	if (ioctl(fd, EVIOCGBIT(0, sizeof types), types) < 0)
		return USB_KIND_NONE;
	if (!bit_set(types, EV_KEY))
		return USB_KIND_NONE;
	if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof keys), keys) < 0)
		return USB_KIND_NONE;
	if (bit_set(types, EV_REL) && ioctl(fd, EVIOCGBIT(EV_REL, sizeof rels), rels) >= 0) {
		// A mouse reports relative motion in both axes and has at
		// least the left button.  A tablet reports absolute position
		// and is not one; a volume knob reports one axis and is not
		// one either.
		if (bit_set(rels, REL_X) && bit_set(rels, REL_Y) && bit_set(keys, BTN_LEFT))
			return USB_KIND_MOUSE;
	}
	// A keyboard has letters.  Three of them are asked for rather than
	// one, because a device with a single KEY_A is somebody's foot pedal.
	if (bit_set(keys, KEY_A) && bit_set(keys, KEY_Z) && bit_set(keys, KEY_SPACE))
		return USB_KIND_KEYBOARD;
	return USB_KIND_NONE;
}

// Everything the kernel has been holding for a node nobody had open.  See the
// header: this is the leg of the machine's cold-boot test that belongs here.
static void drain(int fd)
{
	uint8_t waste[sizeof(struct input_event) * 32];
	for (;;) {
		const ssize_t got = read(fd, waste, sizeof waste);
		if (got > 0)
			continue;
		if (got < 0 && errno == EINTR)
			continue;
		return;
	}
}

static int open_node(struct usb_set *s, const char *dir, const char *node, int loud)
{
	char path[256];
	if (dir)
		snprintf(path, sizeof path, "%s/%s", dir, node);
	else
		snprintf(path, sizeof path, "%s", node);
	const int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
	if (fd < 0) {
		if (loud)
			say("%s: %s", path, strerror(errno));
		return -1;
	}
	const int kind = classify(fd);
	if (kind == USB_KIND_NONE
	    || (kind == USB_KIND_KEYBOARD && !s->want_keyboard)
	    || (kind == USB_KIND_MOUSE && !s->want_mouse)) {
		if (loud)
			say("%s is neither a keyboard nor a mouse this program wants", path);
		close(fd);
		return -1;
	}
	char label[USB_LABEL_MAX];
	if (ioctl(fd, EVIOCGNAME(sizeof label), label) < 0)
		snprintf(label, sizeof label, "a device with no name");
	label[sizeof label - 1] = 0;
	drain(fd);
	if (s->grab && ioctl(fd, EVIOCGRAB, 1) < 0)
		// Not fatal: the keys still arrive here, they are simply not
		// kept from anything else on the board that is reading them.
		say("%s: it would not be taken exclusively (%s); the keys still arrive",
		    path, strerror(errno));
	if (usb_set_add(s, fd, (unsigned)kind, node, label) < 0) {
		say("%s: no room for another device", path);
		close(fd);
		return -1;
	}
	say("%s is a %s: %s", path, kind == USB_KIND_MOUSE ? "mouse" : "keyboard", label);
	return 0;
}

int usb_set_open(struct usb_set *s, const char *path)
{
	// A whole path, so there is no directory to join: `open_node` takes
	// NULL for that and uses the name as it stands.  The node it is
	// remembered under is the whole path too, which is what keeps a
	// `--device` and a scan of the same node from opening it twice.
	return open_node(s, NULL, path, 1) < 0 ? -1 : 0;
}

unsigned usb_set_scan(struct usb_set *s, const char *dir)
{
	char names[64][USB_NAME_MAX];
	const unsigned n = usb_scan_names(dir, names, 64);
	unsigned opened = 0;
	for (unsigned k = 0; k < n; ++k) {
		if (is_open(s, names[k]) || is_refused(s, names[k]))
			continue;
		if (open_node(s, dir, names[k], 0) == 0)
			++opened;
		else
			// Examined once.  A board's own buttons must not be
			// opened and closed every second for the life of the
			// program.
			refuse(s, names[k]);
	}
	// A node that has GONE is forgotten as refused, so that a device
	// unplugged and plugged in again --- which may come back at the same
	// name --- is examined afresh rather than refused for ever.
	for (unsigned k = 0; k < s->refuseds;) {
		int there = 0;
		for (unsigned j = 0; j < n; ++j)
			if (strcmp(names[j], s->refused[k]) == 0) {
				there = 1;
				break;
			}
		if (there) {
			++k;
			continue;
		}
		memmove(s->refused[k], s->refused[k + 1],
			(s->refuseds - k - 1) * USB_NAME_MAX);
		--s->refuseds;
	}
	return opened;
}

unsigned usb_set_pollfds(const struct usb_set *s, struct pollfd *fds, unsigned max)
{
	unsigned n = 0;
	for (unsigned k = 0; k < s->devices && n < max; ++k) {
		fds[n].fd = s->dev[k].fd;
		fds[n].events = POLLIN;
		fds[n].revents = 0;
		++n;
	}
	return n;
}

static void emit(const struct usb_out *out, const struct cadr_input_event *e)
{
	if (out && out->event)
		out->event(out->ctx, e);
}

// What a device owes, sent, and then it is closed and forgotten.
static void forget(struct usb_set *s, unsigned k, const struct usb_out *out, const char *why)
{
	struct usb_device *d = &s->dev[k];
	struct cadr_input_event owed[USB_KBD_MAX_DOWN];
	const unsigned n = usb_kbd_release_all(&d->kbd, owed, USB_KBD_MAX_DOWN);
	for (unsigned i = 0; i < n; ++i)
		emit(out, &owed[i]);
	struct cadr_input_event lift;
	if (usb_mouse_release_all(&d->mouse, &lift))
		emit(out, &lift);
	say("%s is gone (%s); %u keys released, %u devices left",
	    d->node, why, n, s->devices - 1);
	if (d->fd >= 0)
		close(d->fd);
	s->dev[k] = s->dev[s->devices - 1];
	memset(&s->dev[s->devices - 1], 0, sizeof s->dev[0]);
	s->dev[s->devices - 1].fd = -1;
	--s->devices;
	++s->gone;
}

// One device's bytes into records.  0, or -1 for a device that has gone.
static int step(struct usb_set *s, struct usb_device *d, const struct usb_out *out,
		const char **why)
{
	const ssize_t got = read(d->fd, d->in + d->in_len, sizeof d->in - d->in_len);
	if (got == 0) {
		*why = "it closed";
		return -1;
	}
	if (got < 0) {
		if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
			return 0;
		// ENODEV is what an unplugged device gives.  Anything else is
		// reported in its own words rather than guessed at.
		*why = strerror(errno);
		return -1;
	}
	d->in_len += (size_t)got;
	const size_t one = sizeof(struct input_event);
	size_t at = 0;
	while (d->in_len - at >= one) {
		struct input_event ev;
		memcpy(&ev, d->in + at, one);
		at += one;
		++d->events;
		if (d->kind == USB_KIND_KEYBOARD) {
			if (ev.type != EV_KEY)
				continue;
			struct cadr_input_event e;
			if (usb_kbd_key(&d->kbd, ev.code, ev.value, &e)) {
				++s->keys;
				emit(out, &e);
			}
			continue;
		}
		if (ev.type == EV_SYN && ev.code == SYN_REPORT) {
			struct cadr_input_event e;
			if (usb_mouse_report(&d->mouse, &e)) {
				++s->moves;
				emit(out, &e);
			}
			continue;
		}
		usb_mouse_event(&d->mouse, ev.type, ev.code, ev.value);
	}
	if (at) {
		memmove(d->in, d->in + at, d->in_len - at);
		d->in_len -= at;
	}
	return 0;
}

int usb_set_read(struct usb_set *s, unsigned k, const struct usb_out *out)
{
	if (k >= s->devices)
		return -1;
	const char *why = NULL;
	if (step(s, &s->dev[k], out, &why) == 0)
		return 0;
	forget(s, k, out, why ? why : "it stopped answering");
	return -1;
}

void usb_set_poll(struct usb_set *s, const struct pollfd *fds, unsigned n,
		  const struct usb_out *out)
{
	// A device forgotten below moves the last one into its place, so its
	// events are found by descriptor and not by index --- the same care
	// the screen's poll takes with its viewers.
	for (unsigned k = 0; k < s->devices;) {
		short ev = 0;
		for (unsigned j = 0; j < n; ++j)
			if (fds[j].fd == s->dev[k].fd) {
				ev = fds[j].revents;
				break;
			}
		if (ev & (POLLHUP | POLLERR)) {
			forget(s, k, out, "the descriptor went");
			continue;
		}
		if (!(ev & POLLIN)) {
			++k;
			continue;
		}
		if (usb_set_read(s, k, out) == 0)
			++k;
	}
}

void usb_set_release_all(struct usb_set *s, const struct usb_out *out)
{
	// What every device holds, released, with the devices left open.
	// **`out` MAY BE NULL, AND THAT IS THE INTERESTING CASE**: when the
	// link goes, the far end has already released what this program had
	// sent down, so what is wanted here is to forget it without sending
	// anything --- otherwise a key still held would be one this program
	// thinks is down and the far end thinks is up, and the next press of
	// it would be dropped as a repeat.
	for (unsigned k = 0; k < s->devices; ++k) {
		struct cadr_input_event owed[USB_KBD_MAX_DOWN];
		const unsigned n = usb_kbd_release_all(&s->dev[k].kbd, owed, USB_KBD_MAX_DOWN);
		for (unsigned i = 0; i < n; ++i)
			emit(out, &owed[i]);
		struct cadr_input_event lift;
		if (usb_mouse_release_all(&s->dev[k].mouse, &lift))
			emit(out, &lift);
	}
}

void usb_set_close(struct usb_set *s, const struct usb_out *out)
{
	while (s->devices)
		forget(s, s->devices - 1, out, "this program is stopping");
	s->refuseds = 0;
}
