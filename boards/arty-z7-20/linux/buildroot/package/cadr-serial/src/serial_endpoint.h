// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The far end of the RS-232 cable at J9, as a TCP socket: muir's
// `serial::Endpoint` in C.
//
// This is a port of `../muir/src/serial.rs`, `pub struct Endpoint` and its
// `service` and `poll_cable`, and deliberately so --- two programs offering
// one machine's serial line must not disagree about what plugging in means.
// Every decision below is muir's, with muir's reason:
//
//   **A TCP endpoint and not a pseudo-terminal.**  A pty would look like a
//   serial device, so somebody would attach `screen /dev/ttyUSB0 9600` and
//   that 9600 would mean nothing: the rate is whatever the machine has
//   programmed into the 2651, and the far end of a null-modem cable has no
//   say in it.  Nothing here picks a rate or a frame, and nothing here can
//   report a mismatch either --- a far end at the wrong rate produces
//   garbage, as it does on a real line.
//
//   **One device.**  One thing is on the far end of a null-modem cable, so a
//   second connection is closed as it arrives rather than shouting over the
//   first.
//
//   **Connecting is plugging in.**  The Signetics sheet: the chip "is
//   conditioned to transmit data when the -CTS input is low" and
//   "conditioned to receive data when the -DCD input is low", so carrying
//   bytes alone would leave the port unable to do anything with them.  A
//   connection asserts DSR, DCD and CTS, as a device does with its own DTR
//   and RTS across a null-modem cable, and hanging up drops all three.
//   `SER_CTL_PLUGGED` in `serial_face.h` is those three.
//
//   **The device that is there is served before a new one is accepted**, so
//   that somebody who hangs up and attaches again is not turned away by the
//   connection they have just dropped.  What the cable saw is the two ends of
//   the turn compared: a device that went and another that came in the same
//   turn leaves the port plugged in throughout, which is one device on the
//   cable rather than none.
//
//   **A hang-up drops what the port sent and the device never took**, because
//   a cable pulled out drops whatever was on the wire.
//
//   **TCP_NODELAY**, because a character at a time is the whole traffic here
//   and waiting to coalesce would only add latency.
//
// **THE CHIP IS THE FABRIC'S AND ITS TIMING STAYS THERE.**  `serial_face.h`
// says it and this file obeys it: no baud rate is modelled, no character
// frame is assembled, nothing here counts a bit time.  The port takes its own
// frame time over each character either way, so a burst read off the socket
// in one turn is still received one frame at a time by the machine.  Two
// models of one chip is the failure this project keeps meeting.
//
// **WHAT IS NOT muir's, AND WHY.**  muir's outbox is unbounded and muir's
// `Cable` produces a character only while something is plugged in, because
// the chip it models will not transmit without CTS.  The fabric's face makes
// neither promise, so two rules are added here and both are stated at the
// code that carries them: the outbox is a fixed ring, and the port is drained
// only while a device is on the cable --- reading `RDATA` CONSUMES the
// character, so a read the program cannot deliver loses it where the fabric's
// own `DROPPED` counter would not count it.

#ifndef SERIAL_ENDPOINT_H
#define SERIAL_ENDPOINT_H

#include <stddef.h>
#include <stdint.h>

#include "serial_face.h"

// How many characters the far end will hold for the port before the endpoint
// stops reading the socket.  muir's number and muir's reason: a serial line
// has no buffer at all and the port has one character of one, but this
// program reads the socket in bursts milliseconds apart, so the far end holds
// what arrived between two of them and the receiver takes them a frame at a
// time.  Past this the socket is left unread and TCP's own window holds the
// rest back at whoever is typing --- which is what a far end that cannot keep
// up does.
#define SER_BACKLOG 256

// The two queues are rings of this many characters.  The inbox never passes
// SER_BACKLOG, which is what `room` enforces; the outbox is larger because
// what fills it is the machine and not a person's typing, and because a far
// end that has stopped reading should be given room before the port is stopped
// on its account.
#define SER_QUEUE_CAP 4096

// What one turn at the socket did to the cable.  muir's `enum Change`, with a
// third value for "nothing happened" where Rust has an Option.
enum ser_change { SER_CHANGE_NONE = 0, SER_CHANGE_PLUGGED_IN, SER_CHANGE_HUNG_UP };

struct ser_queue {
	uint8_t b[SER_QUEUE_CAP];
	unsigned head, len;
};

struct serial_endpoint {
	// The listening socket.  Public because the host check sets
	// SO_SNDBUF on it --- which an accepted socket inherits --- to make a
	// far end that has stopped reading happen in a few kilobytes rather
	// than a few hundred.
	int listener;
	// The device on the cable, or -1, and where from.
	int device;
	char who[64];
	// What the port has sent and the socket has not taken.  muir's
	// `outbox`.
	struct ser_queue outbox;
	// What was typed at the socket and the machine's receiver has not
	// taken.  muir hands these straight to `Cable::send`, which queues
	// them; the fabric's receiver takes one character when it has room,
	// so the queue is here.
	struct ser_queue inbox;
	// Whether a device coming and going is said as it happens.  muir's
	// `trace`; on here by default, because this program's log is the
	// board's console and a cable being plugged in is the interesting
	// event.
	int trace;
	// What this end last put on the cable.  The lines are written when the
	// cable changes and at no other time, so that a pass in which nothing
	// happened costs no writes on the bus, and this is what says whether
	// there is anything to take down when the program stops.  It is a
	// SECOND record of a fact the fabric's CTL register also holds, which
	// is what lets the check compare the two rather than take either on
	// trust.
	int lines_up;
	unsigned long connects, hangups, refused;
	unsigned long long from_machine, to_machine;
	// What a hang-up threw away, how often the receiver had no room for
	// the character on offer, and on how many passes the port was left
	// undrained because the outbox was full.  All three are ordinary and
	// none is an error; they are counted because a line that misbehaves is
	// read off them.
	unsigned long long dropped_on_hangup;
	unsigned long refused_by_receiver, stalled_port;
};

// Binds and listens, without blocking.  `bind_addr` is a dotted quad or NULL
// for every interface; port 0 asks the host for one, which is what the check
// does so that two runs never collide.  0, or -1 having said why.
int serial_endpoint_bind(struct serial_endpoint *e, const char *bind_addr, unsigned port);

// What port the listener actually took.
unsigned serial_endpoint_port(const struct serial_endpoint *e);

// Whether a device is on the cable.  muir's `connected`.
int serial_endpoint_connected(const struct serial_endpoint *e);

// The cable starts unplugged.  The fabric's CTL at power-on is not this
// program's, and a stale one left by a previous run would tell the machine a
// device is on a cable that is not, which is exactly the reading MIT's
// `sys/io1/serial.lisp` waits on.  Called once, before the loop.
void serial_endpoint_start(struct serial_endpoint *e, struct serial_face *f);

// One turn at the socket: what the port sent as far as the socket will take
// it now, up to `room` characters typed at it, and whoever has arrived.
// Never blocks.  muir's `Endpoint::service`.  `typed` must have room for
// SER_BACKLOG characters.
enum ser_change serial_endpoint_service(struct serial_endpoint *e, size_t room,
					uint8_t *typed, size_t *ntyped);

// One turn for the fabric's far end: what the port has finished sending goes
// to the socket, what was typed at the socket goes into the machine's
// receiver, and the modem-control lines follow whoever is on the cable.
// muir's `Endpoint::poll_cable`, with `serial_face.h` in place of
// `serial::Cable`.
void serial_endpoint_pump(struct serial_endpoint *e, struct serial_face *f);

// Waits until the socket has something to say or `timeout_us` has gone by.
// The fabric has no way to wake this program --- the face's IRQ register
// reaches no Linux interrupt --- so the timeout is what makes the port get
// looked at, and `cadr-serial.c`'s header has the arithmetic for it.
void serial_endpoint_wait(struct serial_endpoint *e, unsigned timeout_us);

// The listener and the device.
void serial_endpoint_close(struct serial_endpoint *e);

static inline unsigned serial_endpoint_outbox(const struct serial_endpoint *e)
{
	return e->outbox.len;
}

static inline unsigned serial_endpoint_inbox(const struct serial_endpoint *e)
{
	return e->inbox.len;
}

#endif
