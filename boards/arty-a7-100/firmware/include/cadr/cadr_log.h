// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `say()` with no operating system behind it.
//
// **THIS IS A SHIM AND IT EXISTS SO THAT `console_face.c` AND `pack_side.c`
// COMPILE HERE UNCHANGED.**  Those two files are the drivers of the machine's
// register faces, they are the Arty Z7-20's, and every line of them is as
// true of a soft core as of an ARM one: the register numbers are the fabric's,
// the protocols are the fabric's, and the only thing that differs is how a
// word gets to an address.  So they are compiled into this firmware from where
// they live rather than copied, and the two things they need from their
// surroundings are a `say()` and an access layer.  This is the first.
//
// The name and the path are `cadr-common`'s own, because an `#include
// <cadr/cadr_log.h>` in a shared file must resolve to something whatever is
// compiling it.  The Linux one writes a prefixed, flushed line to a `FILE *`;
// this one writes a prefixed line to the board's UART and there is nothing to
// flush.
//
// **`cadr_log_file` IS NOT HERE.**  Nothing in the two shared files calls it
// --- measured, not assumed --- and a bare-metal `FILE *` for a caller to hand
// somewhere else would be a claim this firmware cannot keep.  A shared file
// that starts calling it will fail to compile here, loudly, which is the right
// way round.

#ifndef CADR_LOG_H
#define CADR_LOG_H

#include <stdio.h>

// The prefix every line carries.  `dest` is ignored: there is one output on
// this board and it is the UART.  The signature is the Linux one so that a
// shared file calling it compiles.
void cadr_log_init(const char *prefix, FILE *dest);

// One line: the prefix, the text, a newline.
void say(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

#endif
