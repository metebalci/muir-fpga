// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's Ethernet device: what it does to an Ethernet frame's bytes (the
// Ethernet contract, section 2.4).
//
// **THIS FILE IS muir's `src/ethernet_offload.rs` IN C, AND IS HELD TO IT.**
// The device understands IPv4.  On transmit it fills in the IPv4 header
// checksum and the TCP, UDP and ICMP checksums, whatever QUUX left in their
// fields; on receive it drops an Ethernet frame with a wrong checksum or a
// malformed IPv4 header before the frame takes a buffer.  It takes two
// types, IPv4 (0x0800) and ARP (0x0806), and refuses or drops every other:
// the type filter.  An ARP Ethernet frame passes both ways untouched.  On
// muir the device model does this work; on a board this program does it,
// because it already moves every Ethernet frame's bytes through /dev/mem.
// The checksum vectors (muir-sim's `tests/ethernet_vectors.txt`, read at
// the pinned muir) hold both implementations to the same results.
//
// An Ethernet frame here is the whole frame as the rings hold it, from the
// destination address to the end of the data, 14 to 1514 bytes and no FCS;
// byte k is byte k of the frame.
//
// **Definitions**, for an Ethernet frame of n bytes:
// - the type is bytes 12-13, big-endian;
// - an IPv4 Ethernet frame is well-formed when n >= 34; byte 14 holds
//   version 4 and an IHL of 5 or more, giving H = 4 IHL bytes of header,
//   options included; and the total length TL (bytes 16-17) has H <= TL and
//   14 + TL <= n (RFC 791 section 3.1);
// - bytes from 14 + TL on are Ethernet padding, never summed or changed;
// - the payload is bytes 14 + H to 14 + TL - 1, L = TL - H bytes, of
//   protocol P (byte 23);
// - a fragment has MF (byte 20 <5>) set or a fragment offset (bytes 20-21
//   <12:0>) other than 0;
// - a checked protocol is TCP (6), UDP (17) or ICMP (1) in a datagram that
//   is not a fragment; it is well-formed only if TCP has L >= 20, UDP L >= 8
//   and its length field (payload bytes 4-5) equal to L, and ICMP L >= 8;
// - a checksum is the complement of the ones'-complement sum of big-endian
//   16-bit words, an odd last byte padded with 0 (RFC 1071 section 3); for
//   TCP and UDP the sum also covers the pseudo-header: bytes 26-33, a zero
//   byte, P, and L as 16 bits.
//
// **Transmit** refuses an Ethernet frame under 14 bytes or of another type,
// and an IPv4 Ethernet frame that is not well-formed, and leaves a refused
// frame as it was.  For a well-formed one it fills in bytes 24-25 over the
// H header bytes and, for a checked protocol, the checksum at payload bytes
// 16-17 (TCP), 6-7 (UDP) or 2-3 (ICMP), each field taken as 0.  A UDP
// checksum computed as 0 is sent as 0xFFFF (RFC 768); TCP, ICMP and the
// header keep a computed 0.  A fragment, or another protocol, gets the
// header checksum only.
//
// **Receive** drops, counted by the type filter (241 <7:4>), an Ethernet
// frame under 14 bytes or of another type; and, counted by the IPv4 checks
// (241 <15:9>), an IPv4 Ethernet frame that is not well-formed, whose header
// does not sum to 0xFFFF over its H bytes, or whose checked protocol's
// payload, with the pseudo-header for TCP and UDP, does not.  A UDP checksum
// field of 0 means "no checksum": that payload is not checked (RFC 768; RFC
// 1122 section 4.1.3.4).

#ifndef QED_OFFLOAD_H
#define QED_OFFLOAD_H

#include <stddef.h>
#include <stdint.h>

#define QED_TYPE_IPV4 0x0800u
#define QED_TYPE_ARP  0x0806u

// The counter of status word 241 a dropped received Ethernet frame
// advances, as muir's `RxCounter`.
enum qed_counter {
	QED_COUNT_NONE = 0,     // delivered
	QED_COUNT_TYPE = 1,     // <7:4>, the type filter, mod 16
	QED_COUNT_IPV4 = 2,     // <15:9>, the IPv4 checks, mod 128
};

// The ones'-complement sum of `n` bytes as big-endian 16-bit words, an odd
// last byte padded with 0, folded by end-around carry; not complemented.
uint16_t qed_ones_sum(const uint8_t *data, size_t n);

// Fill the IPv4 header checksum and the TCP, UDP or ICMP checksum of the
// `n`-byte Ethernet frame `f` in place: NULL, or why it is refused (muir's
// `TxRefusal::reason`'s words), the frame then left as it was.
const char *qed_transmit(uint8_t *f, size_t n);

// Whether a received Ethernet frame may take a buffer: QED_COUNT_NONE, or
// the counter its drop advances with the reason (muir's `RxDrop::reason`'s
// words) in `*why`.
enum qed_counter qed_receive(const uint8_t *f, size_t n, const char **why);

#endif
