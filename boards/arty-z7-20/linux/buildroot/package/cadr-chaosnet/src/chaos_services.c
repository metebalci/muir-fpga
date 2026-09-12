// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// STATUS, TIME and UPTIME: the three services whose whole content is an
// answer.  `muir::chaos::status` and `muir::chaos::time`, ported.
//
// Each is a *simple transaction* --- an RFC evokes an ANS and no connection
// is made, AIM-628 §4.1 --- so each is one `request` filling a
// `struct chaos_response` and nothing else.  They answer anyone: a name, a
// subnet number and the time of day give nothing away, which is why
// `chaos_file.h` has to name the hosts it serves and these do not.
//
// **STATUS IS NOT OPTIONAL.**  AIM-628 §5: "All network nodes, even bridges,
// are required to answer RFC's with contact name STATUS", and §5.1 again,
// "All hosts are required to implement the STATUS protocol since it is used
// for network maintenance".  It is how one machine finds out whether another
// is alive: `HOST-UP-P` in `sys/network/chaos/chsaux.lisp` asks for nothing
// but the ANS coming back, and `HOSTAT` in the same file reads what is in it.
// A host that does not answer STATUS is a host the band believes is down.

#include "chaos_ncp.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <cadr/cadr_log.h>

// ------------------------------------------------------------------ STATUS
//
// **Two sources fix the format and they agree.**  AIM-628 §5.1 specifies it,
// and MIT's own reader --- `HOSTAT-FORMAT-ANS` and `HOSTAT-FORMAT-ANS-1` in
// `sys/network/chaos/chsaux.lisp` --- decodes it:
//
//     bytes 0..32     the node's name, "padded on the right with zero bytes".
//                     `STRING-SEARCH-CHAR 0 (PKT-STRING PKT) 0 32.` is what
//                     finds the end.
//     then, per subnet, an identifier word, a count word, and the meters.
//
// The count is the number of **16-bit words to follow**, not the number of
// meters --- "usually 16" for the eight below, and the reader steps
// `(+ I 2 CT)`.  The identifier is "400 plus a subnet number", and the meters
// after the first two words are 32-bit, low half first, which is what
// `(DPB (AREF PKT (1+ J)) #o2020 (AREF PKT J))` assembles.
//
// An identifier of 0 to 0o377 is the same thing with 16-bit counts, which the
// memo calls obsolete: "This format should no longer be sent by any hosts."
// So this writes the 0o400 form.  0o1000 and up are reserved.

// The 32-byte name field at the front of the answer.
#define STATUS_NAME 32u

// The eight meters AIM-628 §5.1 defines, in its order --- which is also
// `HOSTAT`'s columns, `#-in #-out abort lost crc ram bitc other`:
//
//  1. packets received from this subnet;
//  2. packets transmitted to it;
//  3. transmissions aborted by collisions or a busy receiver;
//  4. incoming packets lost because the host had not read the previous one
//     out of the interface;
//  5. incoming packets with CRC errors;
//  6. incoming packets that were clean on the wire but wrong out of the
//     packet buffer;
//  7. incoming packets rejected for a length that is not a multiple of 16
//     bits;
//  8. incoming packets rejected for anything else.
//
// Sixteen words of them, which is the "usually 16" the memo gives for the
// count field.
//
// **THE METERS HERE ARE ZERO, AND THAT IS NOT A PLACEHOLDER.**  Every one of
// the eight counts something a network interface does.  This program is not
// the interface --- the interface is in fabric, on the other side of
// `chaos_face.h` --- and it keeps none of these counts, so what it can answer
// truthfully is its name and which subnet it is on, and it does.  muir says
// the same of itself and carries the same known omission: a transmission
// aborted on interference does happen and is not carried from the cable to
// this service.
#define STATUS_METERS 8u

// A subnet block's identifier is the subnet plus this; below it is the older
// format, whose meters are 16 bits.
#define STATUS_SUBNET_BLOCK 0400u

struct status {
	struct chaos_service base;
	uint8_t subnet;
	// **LONGER THAN THE FIELD IT GOES IN, ON PURPOSE.**  muir holds a
	// `String` of any length and cuts it where the answer is built, and the
	// cut belongs there because that is where the memo's rule is.  Stored
	// in 32 bytes instead, `snprintf` would do the cutting and the rule in
	// `status_answer` would be unreachable --- a guard that can never fire,
	// which reads exactly like one that works.  Measured: with the name
	// held in 32 bytes, a mutation letting the answer fill all 32 and leave
	// no null survives the check.
	char name[CHAOS_CONTACT_MAX];
};

// The answer's data, as `HOSTAT` reads it.
static unsigned status_answer(const struct status *st, uint8_t *d)
{
	unsigned at = 0;
	// The name, cut rather than overrunning the field, and padded with
	// nulls: MIT looks for a null to end it, so the field always keeps one.
	memset(d, 0, STATUS_NAME);
	unsigned n = (unsigned)strlen(st->name);
	if (n > STATUS_NAME - 1u)
		n = STATUS_NAME - 1u;
	memcpy(d, st->name, n);
	at = STATUS_NAME;
	// One subnet block.  The count is in words, and a meter is two of them.
	const unsigned id = STATUS_SUBNET_BLOCK + st->subnet;
	d[at++] = (uint8_t)id;
	d[at++] = (uint8_t)(id >> 8);
	d[at++] = (uint8_t)(STATUS_METERS * 2u);
	d[at++] = (uint8_t)((STATUS_METERS * 2u) >> 8);
	memset(d + at, 0, STATUS_METERS * 4u);
	at += STATUS_METERS * 4u;
	return at;
}

static void status_request(struct chaos_service *sv, uint64_t now, const char *args,
			   uint16_t from_host, uint16_t from_index, struct chaos_response *r)
{
	const struct status *st = (const struct status *)sv;
	(void)now;
	(void)args;
	(void)from_host;
	(void)from_index;
	r->kind = CHAOS_RESP_ANSWER;
	r->len = status_answer(st, r->answer);
}

static void service_destroy(struct chaos_service *sv)
{
	free(sv);
}

struct chaos_service *chaos_status_new(const char *name, uint8_t subnet)
{
	struct status *st = calloc(1, sizeof *st);
	if (!st) {
		say("out of memory making the STATUS service");
		return NULL;
	}
	st->base.contact = "STATUS";
	st->base.request = status_request;
	st->base.destroy = service_destroy;
	// The subnet the host reports a block for.  A Chaosnet address is the
	// subnet in the high byte and the host in the low, so `0o3060` is
	// subnet 6; the caller does that arithmetic because it knows the
	// address and this does not.
	st->subnet = subnet;
	snprintf(st->name, sizeof st->name, "%s", name ? name : "");
	return &st->base;
}

// -------------------------------------------------------------------- TIME
//
// AIM-628 §5.8: "An RFC to contact name TIME evokes an ANS containing the
// number of seconds since midnight Greenwich Mean Time, Jan 1, 1900 as a
// 32-bit number in four 8-bit bytes, least-significant byte first.  Some
// computers --- Lisp machines, for example --- which don't have hardware
// calendar-clocks use this protocol to find out the date and time when they
// first come up."  The Lisp Machine's `HOST-TIME` in
// `sys/network/chaos/chuse.lisp` asks each of its time-server hosts in turn
// and `DECODE-CANONICAL-TIME-PACKET` reads the two words back, low word
// first.
//
// **AND THIS BOARD IS ONE OF THOSE MACHINES.**  The CADR has no calendar
// clock, so the time it shows is the time something on the cable told it.

struct chaos_time {
	struct chaos_service base;
	// A universal time to answer with always, or 0 for the machine's
	// clock.  A fixed one is what the checks use, so that two runs of a
	// boot against this server do the same work and can be compared.
	uint32_t fixed;
};

// The universal time now: seconds since 1900, as the Lisp Machine counts it.
static uint32_t universal(const struct chaos_time *t)
{
	if (t->fixed)
		return t->fixed;
	const time_t unix_secs = time(NULL);
	if (unix_secs < 0)
		return 0;
	// Four bytes on the wire: the count wraps on 7 February 2036, as the
	// band's own universal time does.
	return (uint32_t)((uint64_t)unix_secs + CHAOS_UNIX_EPOCH_UNIVERSAL);
}

// A 32-bit number "in four 8-bit bytes, least-significant byte first", which
// is what both TIME and UPTIME answer with.
static void answer_u32(struct chaos_response *r, uint32_t v)
{
	r->kind = CHAOS_RESP_ANSWER;
	r->len = 4;
	r->answer[0] = (uint8_t)v;
	r->answer[1] = (uint8_t)(v >> 8);
	r->answer[2] = (uint8_t)(v >> 16);
	r->answer[3] = (uint8_t)(v >> 24);
}

static void time_request(struct chaos_service *sv, uint64_t now, const char *args,
			 uint16_t from_host, uint16_t from_index, struct chaos_response *r)
{
	const struct chaos_time *t = (const struct chaos_time *)sv;
	(void)now;
	(void)args;
	(void)from_host;
	(void)from_index;
	answer_u32(r, universal(t));
}

struct chaos_service *chaos_time_new(uint32_t fixed)
{
	struct chaos_time *t = calloc(1, sizeof *t);
	if (!t) {
		say("out of memory making the TIME service");
		return NULL;
	}
	t->base.contact = "TIME";
	t->base.request = time_request;
	t->base.destroy = service_destroy;
	t->fixed = fixed;
	return &t->base;
}

// ------------------------------------------------------------------ UPTIME
//
// AIM-628 §5.8 again: UPTIME "is similar to the TIME protocol, except that
// the contact name is UPTIME, and the time returned is actually an interval
// (in seconds) describing how long the host has been up."  The interval is by
// the transport's own clock --- the `now` every call carries --- and not by
// the wall, so a check can drive it.

struct uptime {
	struct chaos_service base;
	uint64_t since_ns;
};

static void uptime_request(struct chaos_service *sv, uint64_t now, const char *args,
			   uint16_t from_host, uint16_t from_index, struct chaos_response *r)
{
	const struct uptime *u = (const struct uptime *)sv;
	(void)args;
	(void)from_host;
	(void)from_index;
	// muir's `now.saturating_sub(self.since)`: a question asked before the
	// host came up is nought seconds of uptime, not an enormous one.
	const uint64_t ns = now > u->since_ns ? now - u->since_ns : 0;
	answer_u32(r, (uint32_t)(ns / 1000000000ull));
}

struct chaos_service *chaos_uptime_new(uint64_t since_ns)
{
	struct uptime *u = calloc(1, sizeof *u);
	if (!u) {
		say("out of memory making the UPTIME service");
		return NULL;
	}
	u->base.contact = "UPTIME";
	u->base.request = uptime_request;
	u->base.destroy = service_destroy;
	u->since_ns = since_ns;
	return &u->base;
}
