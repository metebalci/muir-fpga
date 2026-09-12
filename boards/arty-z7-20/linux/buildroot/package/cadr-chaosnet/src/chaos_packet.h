// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A Chaosnet packet as the hardware carries it and as the software lays it
// out: `muir::chaos::packet`, ported.
//
// AIM-628 §2.2, "a sequence of up to 4032 data bits, plus 48 bits of header
// information used by the hardware", the hardware header being "three 16-bit
// words, called destination, source, and check".  §3.5: the software header
// is eight 16-bit words --- operation, count, destination address and index,
// source address and index, packet number, acknowledgement --- followed by
// the data, up to 488 bytes.
//
// **THE WORD ORDER AND THE CHECK WORD ARE muir's AND ARE NOT REDERIVED.**
// `muir::chaos::packet::check_word`'s own comment says why it is that
// arrangement and no other: the Fairchild 9401 at LMTBUF C09 dividing by
// CRC-16, `x^16 + x^15 + x^2 + 1`, from a cleared register, each word
// most-significant bit first, and "of the bit orders, seeds and polynomials
// the 9401 offers, only this one gives" the word the netlist board itself
// produced.  It is transcribed here bit for bit and `chaos_test.c` holds it
// to muir's own published figure for a known frame.

#ifndef CHAOS_PACKET_H
#define CHAOS_PACKET_H

#include <stddef.h>
#include <stdint.h>

// The most data a packet carries, AIM-628 §3.5: "the maximum value is 488".
#define CHAOS_PKT_MAX_DATA 488u

// The software header, in 16-bit words.
#define CHAOS_PKT_HEADER_WORDS 8u

// The hardware trailer, AIM-628 §2.2: destination, source, check.
#define CHAOS_PKT_TRAILER_WORDS 3u

// The most words a whole frame can be.
#define CHAOS_PKT_MAX_WORDS \
	(CHAOS_PKT_HEADER_WORDS + (CHAOS_PKT_MAX_DATA / 2u) + CHAOS_PKT_TRAILER_WORDS)

// Packet opcodes, AIM-628 chapter 4, as `sys/network/chaos/chsncp.lisp`
// numbers them.
enum chaos_op {
	CHAOS_RFC = 0001, CHAOS_OPN = 0002, CHAOS_CLS = 0003, CHAOS_FWD = 0004,
	CHAOS_ANS = 0005, CHAOS_SNS = 0006, CHAOS_STS = 0007, CHAOS_RUT = 0010,
	CHAOS_LOS = 0011, CHAOS_LSN = 0012, CHAOS_MNT = 0013, CHAOS_EOF = 0014,
	CHAOS_UNC = 0015, CHAOS_BRD = 0016,
	// "Opcodes 200 through 277 (octal) are controlled packets with user
	// data in 8-bit bytes"; 200 is the default.
	CHAOS_DAT = 0200,
	// "Opcodes 300 through 377 ... 16-bit bytes"; 300 is the default.
	CHAOS_DWD = 0300
};

// Whether an opcode carries user data.
static inline int chaos_op_is_data(unsigned op) { return op >= CHAOS_DAT; }

// Whether packets of this opcode are controlled --- numbered, acknowledged
// and retransmitted, §3.8.
static inline int chaos_op_is_controlled(unsigned op)
{
	return op == CHAOS_RFC || op == CHAOS_OPN || op == CHAOS_EOF ||
	       chaos_op_is_data(op);
}

// The opcode's name, for a trace line.  A static buffer per call is not used:
// unknown opcodes print into `into`, which must be at least 8 bytes.
const char *chaos_op_name(unsigned op, char *into, size_t into_len);

// The software header and the data.  `data` is owned by the packet's holder,
// which is always a caller's buffer here: nothing in this program allocates a
// packet.
struct chaos_packet {
	uint8_t opcode;
	// The forwarding count, the top four bits of the count word.
	uint8_t forward;
	uint16_t dest;
	uint16_t dest_index;
	uint16_t source;
	uint16_t source_index;
	uint16_t number;
	uint16_t ack;
	uint16_t len;			// the byte count
	uint8_t data[CHAOS_PKT_MAX_DATA];
};

// The eight header words and the data words, low byte of each pair first,
// AIM-628 §3.6: "The first 8-bit byte in a 16-bit word is the one in the
// arithmetically least-significant position."  An odd last byte sits in the
// low half with "a garbage padding byte in its high half", §7; the padding
// here is zero.  Returns how many words were written.
unsigned chaos_packet_words(const struct chaos_packet *p, uint16_t *out, unsigned max);

// A whole frame: the words, the cable destination, the cable source, and the
// check word over all of them.  This is what crosses `chaos_face.h`'s seam
// and what goes in a CHUDP datagram.  Returns the word count, or 0 if `max`
// is too small.
unsigned chaos_packet_frame(const struct chaos_packet *p, uint16_t cable_dest,
			    uint16_t cable_source, uint16_t *out, unsigned max);

// A frame taken apart.  `check_ok` is the check word recomputed and compared,
// which is what says the frame arrived whole.
struct chaos_frame {
	struct chaos_packet packet;
	uint16_t cable_dest;
	uint16_t cable_source;
	uint16_t check;
	int check_ok;
};

// A frame's words back into a packet.  0 on success; -1 if the words are not
// a packet at all --- fewer than the header and trailer, or a byte count that
// does not agree with the length, which AIM-628 §5.1's meters count as
// "rejected for a length that is not a multiple of 16 bits" and its
// neighbours.  `why` is filled with a sentence if it is not NULL.
int chaos_frame_parse(const uint16_t *words, unsigned n, struct chaos_frame *out,
		      const char **why);

// The check word the interface puts on a packet: `muir::chaos::packet::check_word`,
// over the words in the order written --- header, data, cable destination,
// then the source the hardware adds --- each word most-significant bit first.
uint16_t chaos_check_word(const uint16_t *words, unsigned n);

#endif
