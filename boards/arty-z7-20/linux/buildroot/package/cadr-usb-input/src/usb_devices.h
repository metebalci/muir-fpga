// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The devices: which of `/dev/input/event*` are a keyboard and a mouse, what
// they send, and what they owe when they are unplugged.
//
// ## Coming and going
//
// **THERE IS NO udev IN THIS IMAGE.**  `/dev` is devtmpfs, so a node appears
// and disappears by itself and nothing tells a program about it.  So this
// looks at the directory every so often --- `--scan-ms`, a second by default
// --- and a device that has gone gives `ENODEV` on the next read.  A netlink
// socket would be the other way and is not worth a dependency for a keyboard
// somebody plugs in twice a year.
//
// A node that is neither a keyboard nor a mouse is REMEMBERED as such, so
// that the board's own buttons and switches are examined once and not once a
// second for as long as the program runs.
//
// **A DEVICE IS DRAINED WHEN IT IS OPENED.**  The kernel buffers events for a
// node nobody has open, so the first read could otherwise deliver a keystroke
// from before this program started.  `input_face.h` names this as the leg of
// the machine's cold-boot test that belongs to a program taking keys from a
// device: the machine asks whether anybody is typing four instructions into
// microcode 323, the buffering is on the far side of the fabric's seam, and no
// register there can see it.
//
// **WHAT A DEVICE HELD WHEN IT WENT IS RELEASED.**  Every key this program
// sent down for it comes up and its switches are lifted.  A keyboard unplugged
// with Control held must not leave the machine holding Control, there being no
// modifier bits in a word for the machine to notice with.
//
// ## What is testable and what is not
//
// A device is a descriptor and an `input_event` stream, so everything above
// the open --- the reads, the partial ones, the dispatch, the releases owed,
// a device going away --- runs in the check over a socket pair.  What cannot
// run there is the open itself: `EVIOCGBIT` on anything but a real evdev node
// answers with an error, and a check cannot make one of those without being
// root.  So the open is one function, it is the only thing in this file the
// check does not reach, and it says so at itself.

#ifndef USB_DEVICES_H
#define USB_DEVICES_H

#include <stddef.h>
#include <stdint.h>

#include <poll.h>

#include <cadr/cadr_input_link.h>

#include "usb_keys.h"

// How many devices at once.  A keyboard and a mouse is the whole of it; eight
// is room for a keyboard with a second interface, a trackball and somebody's
// habit of plugging in two of everything.
#define USB_MAX_DEVICES 8
// How many nodes are remembered as being neither.  A board with more than
// this many other input devices examines the rest once a scan, which costs an
// open and an ioctl and is not worth another array.
#define USB_MAX_REFUSED 32
#define USB_NAME_MAX 32
// The longest a device's own name is kept, for the line that says what was
// plugged in.
#define USB_LABEL_MAX 80

enum usb_kind { USB_KIND_NONE = 0, USB_KIND_KEYBOARD = 1, USB_KIND_MOUSE = 2 };

// Where a record goes.  A function pointer so that the program sends it down
// the link and the check collects it in an array, which is the same seam
// `input_face.h` uses for the fabric.
struct usb_out {
	void (*event)(void *ctx, const struct cadr_input_event *e);
	void *ctx;
};

struct usb_device {
	int fd;
	unsigned kind;
	char node[USB_NAME_MAX];
	char label[USB_LABEL_MAX];
	struct usb_kbd_state kbd;
	struct usb_mouse_state mouse;
	// A read gives whole `input_event`s and may give a part of one, so
	// what is left over is kept.  Eight of them is a mouse's longest
	// report with room to spare.
	uint8_t in[8 * 32];
	size_t in_len;
	unsigned long events;
};

struct usb_set {
	struct usb_device dev[USB_MAX_DEVICES];
	unsigned devices;
	char refused[USB_MAX_REFUSED][USB_NAME_MAX];
	unsigned refuseds;
	// Whether to take the devices exclusively, and which kinds are wanted.
	int grab, want_keyboard, want_mouse;
	unsigned long opened, gone, keys, moves;
};

void usb_set_init(struct usb_set *s);

// A descriptor this program did not open: the scan's own way in, and the
// check's.  The set takes the descriptor and closes it in its own time.
// 0, or -1 if there is no room.
int usb_set_add(struct usb_set *s, int fd, unsigned kind, const char *node, const char *label);

// Look in `dir` for `event*` nodes that are not open and not already refused,
// and open the ones that are a keyboard or a mouse.  How many were opened.
//
// **THE ONLY PART OF THIS FILE THE CHECK CANNOT REACH.**  See the header.
unsigned usb_set_scan(struct usb_set *s, const char *dir);

// One named device, opened, classified, drained and added.  0, or -1 having
// said why --- which is what `--device` uses, where a name that is not a
// device is a mistake worth reporting rather than a node to skip.
int usb_set_open(struct usb_set *s, const char *path);

// The `event*` names in a directory, sorted.  Separate from the scan so that
// the check can drive it over a directory of its own making.
unsigned usb_scan_names(const char *dir, char names[][USB_NAME_MAX], unsigned max);

// The descriptors to wait on.  How many were written.
unsigned usb_set_pollfds(const struct usb_set *s, struct pollfd *fds, unsigned max);

// Read what is waiting on every device the `fds` say has something, decode it,
// and hand each record to `out`.  A device that has gone is closed and what it
// held is released through `out` first.
void usb_set_poll(struct usb_set *s, const struct pollfd *fds, unsigned n,
		  const struct usb_out *out);

// Read one device, whatever poll(2) said.  0, or -1 for a device that has
// gone --- which this then forgets, having released what it held.
int usb_set_read(struct usb_set *s, unsigned k, const struct usb_out *out);

// What every device holds, released through `out`, with the devices left
// open.  `out` may be NULL, which forgets what they hold and sends nothing:
// that is what a link going away wants, the far end having released those
// keys itself.
void usb_set_release_all(struct usb_set *s, const struct usb_out *out);

// Everything released and every device closed: what this program owes the
// machine when it stops.
void usb_set_close(struct usb_set *s, const struct usb_out *out);

#endif
