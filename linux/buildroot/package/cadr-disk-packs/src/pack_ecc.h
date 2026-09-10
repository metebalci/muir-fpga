// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// DCECC's error-correcting code, for the header checkword and the data
// checkword that follow a block in its record.
//
// A second expression of muir's `disk_unit::Ecc`, as `tb/cadr_pack_side.h`
// is a third: thirty-two stages, `ECC.OUT` at bit 0, the feedback taps at
// stages 31, 29, 20, 10 and 8, everything fed low-order bit first and
// low-order byte first.  The checkword is the register shifted out with no
// feedback, which is the register itself --- `Ecc::checkword()` and
// `Ecc::raw()` are the same thirty-two bits.  The host test holds this to
// the checkwords muir wrote into every `BLK` row of `disk.golden`.

#ifndef PACK_ECC_H
#define PACK_ECC_H

#include <stddef.h>
#include <stdint.h>

// One `CLK.SR^` with feedback on: `data` is the bit coming in.
static inline uint32_t ecc_shift(uint32_t r, unsigned data)
{
	const unsigned input = (data ^ (r & 1u)) & 1u;
	r >>= 1;
	if (input)
		r ^= 0xA0100500u;	// stages 31, 29, 20, 10, 8
	return r;
}

// The checkword over bytes, from a clear register: `Ecc::over`.
static inline uint32_t ecc_over_bytes(const uint8_t *b, size_t n)
{
	uint32_t r = 0;
	for (size_t i = 0; i < n; ++i)
		for (int k = 0; k < 8; ++k)
			r = ecc_shift(r, (b[i] >> k) & 1u);
	return r;
}

// The same over 32-bit words laid low byte first, which is how a block lies
// in the pack file and in its record.
static inline uint32_t ecc_over_words(const uint32_t *w, size_t n)
{
	uint32_t r = 0;
	for (size_t i = 0; i < n; ++i)
		for (int k = 0; k < 32; ++k)
			r = ecc_shift(r, (w[i] >> k) & 1u);
	return r;
}

#endif
