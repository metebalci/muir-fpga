// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The FILE service: the Chaosnet file protocol as the band's file server
// spoke it.  `muir::chaos::file`, ported.
//
// **THIS IS WHAT THE MACHINE ON THE SCREEN IS ASKING FOR.**  A board that
// boots the Lisp Machine system and paints the window system prints
// `#<ZWEI::ZWEI-FILE-HOST "ED-FILE"> is not a known host` --- a file host
// lookup with nothing to answer it.  Answering it is this file's whole
// purpose.
//
// **THE SPECIFICATION IS IN THE RELEASE AND SO IS MIT'S OWN SERVER.**
// `sys/doc/chfile.text`, 792 lines, "Description of the CHAOS FILE protocol
// designed by HIC"; `sys/file/server.lisp`, 1,253 lines, MIT's server; and
// `sys/network/chaos/qfile.lisp`, the Lisp Machine's client.  muir's
// `src/chaos/file.rs` is read against all three and its header says which
// question each settled.  Nothing here re-derives the protocol: where this
// file and muir differ it is a bug here.
//
// ## The shape
//
// The user end opens a *control connection* to contact `FILE 1` and sends
// commands on it as data packets of text, one command a packet,
// `tid handle COMMAND args`, lines separated by the Lisp Machine's newline
// (`CHAOS_FILE_NEWLINE`).  The server answers each with
// `tid handle COMMAND results`, or `tid handle ERROR code severity message`.
//
// Files move on *data connections* the user end listens for and the server
// calls: a `DATA-CONNECTION` command names an input and an output handle, the
// server opens a connection to the output handle's name as a contact, and
// from then on the input handle is that connection's server-to-user
// direction.  `OPEN READ` on an input handle streams the file down it as data
// packets, then EOF; `CLOSE` is answered on the control connection and
// followed by a *synchronous mark* on the data connection, which is what the
// user end reads until.
//
// ## Containment
//
// The root is the service's `/` and nothing the service does may reach a file
// outside the tree it serves.  A pathname is taken component by component
// under the root with `..` and `.` REFUSED rather than followed; the deepest
// existing part is then resolved on the host, links and all, and must lie
// under the root or under what one of the root's own entries links to --- the
// release trees are put under the root by exactly such a link.  A refusal is
// `ATD`, "Access to directory denied".
//
// **AND REACHABILITY IS NOT AUTHORISATION.**  A peer a packet arrived from
// can be answered; being answerable is not being allowed to read and write a
// real directory.  So `chaos_file_new` is given the addresses it serves and
// refuses every other at the RFC.  TIME, UPTIME and STATUS answer anyone:
// they give nothing away.

#ifndef CHAOS_FILE_H
#define CHAOS_FILE_H

#include <stdint.h>

#include "chaos_ncp.h"

// The contact name.  The band asks for `FILE 1`, the `1` being the protocol
// version, which arrives as the RFC's argument.
#define CHAOS_FILE_CONTACT "FILE"

// The Lisp Machine's newline, `#/NEWLINE`, which separates the lines of a
// command and a reply: `CHNL` in `FILE.c`, `0200|'\r'`.
#define CHAOS_FILE_NEWLINE 0215

// Data packet opcodes on a data connection, `qfile.lisp`: character data is
// plain `DAT`, binary `DAT + 100`, a synchronous mark `DAT + 1`, an
// asynchronous mark --- meaning an error --- `DAT + 2`.
#define CHAOS_FILE_CHARACTER_OP 0200
#define CHAOS_FILE_BINARY_OP    0300
#define CHAOS_FILE_SYNC_MARK_OP 0201
#define CHAOS_FILE_ASYNC_MARK_OP 0202

// The first two 16-bit words of a compiled file, `QFASL` in sixbit: `FILE.c`'s
// `QBIN1` 0143150 and `QBIN2` 071660, each low byte first --- `68 c6 b0 73`,
// which is what `sys/sys/cadrlp.qfasl` in the release begins with.
#define CHAOS_FILE_QFASL_MAGIC "\150\306\260\163"

// The FILE service over `root`, dating by `fixed` (a universal time) or by
// the machine's clock when `fixed` is 0, and answering only the `nhosts`
// Chaosnet addresses in `hosts`.  `nhosts` of 0 answers everyone, which is
// what a cable with one trusted machine on it is; `cadr-chaosnet.c` always
// names the machine and `--file-peers`.
struct chaos_service *chaos_file_new(const char *root, uint32_t fixed,
				     const uint16_t *hosts, unsigned nhosts);

// ------------------------------------------------------ the pieces, exposed
// because `chaos_test.c` holds each of them on its own, and because the
// character translation is the half of this protocol most likely to be got
// wrong quietly.

// The Lisp Machine's character set into Unix's and back, `muir`'s `from_lispm`
// and `to_lispm`: the Lisp Machine's `#/NEWLINE` is 0215 and its own
// carriage return is a real 015, so a file written by the band arrives with
// 0215 where a Unix file has 012.  Returns how many bytes were written, which
// is never more than `len`.
unsigned chaos_file_from_lispm(const uint8_t *in, unsigned len, uint8_t *out);
unsigned chaos_file_to_lispm(const uint8_t *in, unsigned len, uint8_t *out);

// A Unix time in seconds into the civil date, and into the `MM/DD/YY HH:MM:SS`
// a file's properties carry.  `into` must be at least 18 bytes.
void chaos_file_date(uint64_t unix_secs, char *into, unsigned into_len);

// `*` and `#` wildcards as the protocol's `DIRECTORY` matches them:
// `muir::chaos::file::matches`.  1 if `name` matches `pattern`.
int chaos_file_matches(const char *pattern, const char *name);

#endif
