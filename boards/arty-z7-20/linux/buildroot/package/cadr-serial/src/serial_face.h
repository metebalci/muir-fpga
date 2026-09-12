// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The serial port's register face, as Linux drives it over a general purpose
// AXI port, and the cable vocabulary built on it.
//
// **THIS FILE IS THE ONE PLACE THE TWO HALVES MEET.**  The fabric half --- the
// Signetics 2651 at IOBSER 0A12, its four registers at `0o764160`-`0o764166`
// (and `0o764170`-`0o764176`, `A3` not being decoded), inside
// `rtl/machine/cadr_io_board.sv` --- is another slice's and is held to
// `muir::serial::Pci`.  What is here is the OTHER side of the same chip: the
// RS-232 cable on J9, which is muir's `serial::Endpoint` plugged into
// `serial::Cable`.  Nothing else in this program knows a register number.
//
// ## What the seam IS
//
// A character at a time, both ways, plus the four modem-control lines that
// say whether anything is plugged in.  **The chip is the fabric's and its
// timing stays there**: the 2651 takes its own frame time over each character
// either way --- sixteen 16X clocks of the crystal divisor MODE register 2
// selects --- so a burst read off the socket in one turn is still received one
// frame at a time by the machine.  This program hands over characters and
// takes the ones the port has finished sending; it does not model a baud
// rate, and must not, because two models of one chip is the failure this
// project keeps meeting.
//
// ## The registers
//
// Eight words at `SER_REG_BASE`:
//
//    +0x00  0  IDENT  "SERI", read-only
//    +0x04  1  STAT   read-only, the bits of `enum ser_stat`
//    +0x08  2  RDATA  read: bits 7:0 the next character the machine
//                     transmitted, bit 8 set if there was one.  **The read
//                     consumes it**, which is the one place in this face
//                     where a read has an effect, and is why `STAT`'s
//                     `RX_VALID` is read first and `RDATA` only then
//    +0x0C  3  WDATA  written: bits 7:0 a character into the machine's
//                     receiver.  Refused, and lost, unless `TX_ROOM` is up
//    +0x10  4  CTL    written: `enum ser_ctl`, the modem-control lines this
//                     end asserts.  A device on the cable raises DSR and DCD;
//                     CTS is raised with them, this cable having no flow
//                     control of its own
//    +0x14  5  MODE   read-only: the two mode registers the machine has
//                     programmed, MR1 in bits 7:0 and MR2 in bits 15:8, and
//                     the command register in bits 23:16.  Read for the
//                     status line only --- the rate the machine chose is
//                     worth printing, and `muir::serial::BAUD_TENTHS` names
//                     it.  **Nothing in this program acts on it.**
//    +0x18  6  DROPPED read-only, saturating: characters the machine sent
//                     that nobody was there to take
//    +0x1C  7  IRQ    bit 0 a character is waiting, bit 1 the transmitter has
//                     room.  A 1 written clears the bit
//
// **EVERY ADDRESS IN THE WINDOW MUST BE ANSWERED.**  A read on a GP port that
// nothing answers hangs both Arm cores at one PC each --- measured on this
// board.  So this program runs `cadr_guard()` before it maps anything and
// reads `IDENT` before it believes any other word.
//
// ## Where it is
//
// **ASSUMED**: `M_AXI_GP0`, two 4 KB pages above the pack side, which owns
// `0x40000000` today, and one above the Chaosnet interface.  The two new
// faces are on one port because they are one card --- the I/O board --- and
// because the drawing already puts the Chaosnet buffers on GP0.  Putting a
// second and third slave on GP0 needs a decode in front of
// `cadr_disk_pack.sv`, which is the fabric half's work.  If the port or the
// offset is different, this one constant changes.

#ifndef SERIAL_FACE_H
#define SERIAL_FACE_H

#include <stdint.h>

#define SER_REG_BASE    0x40002000u
#define SER_REG_BYTES   0x1000u
#define SER_IDENT_WORD  0x53455249u	/* "SERI" */

enum ser_reg {
	SER_IDENT = 0, SER_STAT = 1, SER_RDATA = 2, SER_WDATA = 3,
	SER_CTL = 4, SER_MODE = 5, SER_DROPPED = 6, SER_IRQ = 7
};

enum ser_stat {
	// A character the machine transmitted is waiting.
	SER_ST_RX_VALID = 1u << 0,
	// The machine's receiver can take a character now.
	SER_ST_TX_ROOM  = 1u << 1,
	// The machine has its transmitter enabled (`command::TX_ENABLE`).
	SER_ST_TX_ON    = 1u << 2,
	// The machine has its receiver enabled (`command::RX_ENABLE`).
	SER_ST_RX_ON    = 1u << 3
};

// Bit 8 of `RDATA`: there was a character in bits 7:0.
#define SER_RDATA_VALID 0x100u

enum ser_ctl {
	// A device is on the cable: Data Set Ready and Data Carrier Detect,
	// which are what the 2651 reads at `STATUS` bits 7 and 6 and what
	// `sys/io1/serial.lisp` looks at.
	SER_CTL_DSR = 1u << 0,
	SER_CTL_DCD = 1u << 1,
	// Clear To Send, raised with the other two: this cable has no flow
	// control of its own and a device that never raises CTS would stop the
	// machine's transmitter for ever.
	SER_CTL_CTS = 1u << 2
};

// Everything a plugged-in device asserts, so that "a device is on the cable"
// is one constant and not three ORed at each site.
#define SER_CTL_PLUGGED (SER_CTL_DSR | SER_CTL_DCD | SER_CTL_CTS)

enum ser_irq { SER_IRQ_RX = 1u << 0, SER_IRQ_TX = 1u << 1 };

// The face, reached through two function pointers so that the host test can
// put a model of the RTL behind them and the board puts /dev/mem: the seam
// `pack_side.h`, `console_face.h` and `chaos_face.h` all use.
struct serial_face {
	uint32_t (*read)(struct serial_face *f, unsigned word);
	void (*write)(struct serial_face *f, unsigned word, uint32_t v);
	void *ctx;
};

int serial_face_open(struct serial_face *f, int fd, uint32_t base);
void serial_face_close(struct serial_face *f);

// IDENT, read and checked.  0, or -1 having said what was there instead ---
// `CADR_IDENT_NONE` for a bitstream with a default slave where this should
// be, which is the common mistake and is named as such.
int serial_face_ident(struct serial_face *f);

// The next character the machine transmitted: 0..255, or -1 if none is
// waiting.
int serial_face_get(struct serial_face *f);

// A character into the machine's receiver.  1 if it was taken, 0 if the
// receiver had no room and the caller should offer it again.
int serial_face_put(struct serial_face *f, uint8_t c);

// The modem-control lines this end asserts: `SER_CTL_PLUGGED` when a device
// is on the cable and 0 when it is not.  A cable pulled out drops the lines,
// which is what the machine's own software watches.
void serial_face_set_lines(struct serial_face *f, uint32_t lines);

uint32_t serial_face_stat(struct serial_face *f);
uint32_t serial_face_dropped(struct serial_face *f);

// The rate the machine has programmed, as an index into
// `muir::serial::DIVISORS`, out of MODE's MR2; and that rate in tenths of a
// baud, for a status line.  Neither changes anything this program does.
unsigned serial_face_rate(struct serial_face *f);
uint32_t serial_rate_tenths(unsigned rate);

#endif
