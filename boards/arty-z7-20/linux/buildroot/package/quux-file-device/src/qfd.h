// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's file device, the Linux side: the protocol core.
//
// QUUX reads and writes files on its host through a file device (muir's
// contract Q9, revision 9, `docs/quux.md` "The file device"): folders of the
// host served under one pathname host, HOST, with commands and responses in
// two rings in the machine's main memory and the bytes moved by DMA.  On a
// board the fabric holds the registers and Linux is the device: this program
// reads each command entry and its buffers out of DDR, does the host's
// operation, and writes buffer B and the response back.
//
// **THIS FILE IS muir's `src/file_device.rs` IN C, AND IS HELD TO IT.**  The
// statuses, their order of precedence, the directory records, the names'
// rules, the mounts and the temporary files are muir's, decision for
// decision, because the Lisp side is one program that must meet the same
// device on muir and on a board.  `qfd_test.c` runs scripts of rings through
// this and `golden/src/quux_file_device.rs` runs the same scripts through
// muir's own device, and the two transcripts and the two folders after must
// agree byte for byte.
//
// What is NOT here: the rings' indexes, the enable and the registers, which
// are the fabric's and reach this program through the face (`qfd_face.h`);
// the service loop over them (`qfd_ring.c`); and the program's start
// (`quux-file-device.c`).

#ifndef QFD_H
#define QFD_H

#include <stddef.h>
#include <stdint.h>

// The opcodes, a command's word 0 <23:16>.
enum {
	QFD_OPEN = 1, QFD_READ = 2, QFD_WRITE = 3, QFD_CLOSE = 4, QFD_DIRECTORY = 5,
	QFD_COMPLETE = 6, QFD_DELETE = 7, QFD_RENAME = 8, QFD_CREATE_DIRECTORY = 9,
	QFD_LOG = 10,
};

// The statuses, a response's word 0 <23:16>: the Lisp system's file errors
// by their three letters, and three driver faults.
enum {
	QFD_OK = 0, QFD_FNF = 1, QFD_DNF = 2, QFD_FAE = 3, QFD_REF = 4, QFD_ACC = 5,
	QFD_ATF = 6, QFD_DAE = 7, QFD_DNE = 8, QFD_NMR = 9, QFD_IOD = 10, QFD_WKF = 11,
	QFD_IPS = 12, QFD_NER = 13, QFD_UOP = 14, QFD_DAT = 15, QFD_FOR = 16,
	QFD_RAD = 17,
	QFD_BAD_HANDLE = 64, QFD_BAD_BUFFER = 65, QFD_BAD_ARGUMENT = 66,
};

#define QFD_MAX_HANDLES      64
#define QFD_MAX_BUFFER       65536u
#define QFD_MIN_DIRECTORY    272u
#define QFD_MAX_NAME         1024u
#define QFD_MAX_COMPONENT    255u
#define QFD_MAX_LOG          1024u
#define QFD_MAX_MOUNTS       32
// How a write's temporary file's name begins.  DIRECTORY and COMPLETE never
// show such a name, and the start sweeps any left behind.
#define QFD_TEMP_PREFIX      ".quux-write-"

// Main memory, as the device sees it: `words` words from `w`, word k at
// `w[k]`.  On a board `w` is an uncached mapping of DDR (`cadr_mem.h` says
// why every access is one aligned 32-bit word); in the check it is an array.
// `touch`, when set, is called before every access, which is how the check
// holds that no word is touched outside the claim.
struct qfd_mem {
	volatile uint32_t *w;
	size_t words;
	void (*touch)(void *ctx);
	void *ctx;
};

// A host folder served to the machine.
struct qfd_mount {
	char *name;   // NULL for the default folder, HOST's `/`
	char *given;  // the folder as given
	char *path;   // the folder with its symlinks resolved
	int ro;
};

struct qfd_mounts {
	int has_default;
	struct qfd_mount def;
	// The named mounts, sorted bytewise by name, as muir's BTreeMap is.
	int n;
	struct qfd_mount named[QFD_MAX_MOUNTS];
};

struct qfd_handle {
	int kind;         // 0 none, 1 read, 2 write
	int fd;
	char *temp;       // write: the temporary file
	char *target;     // write: where CLOSE puts it
	int noreplace;    // write: if-exists error, so CLOSE refuses a name that appeared
	uint64_t held;    // write: the bytes the temporary file holds
};

struct qfd {
	struct qfd_mounts mounts;
	struct qfd_handle h[QFD_MAX_HANDLES];
	uint64_t temps;   // the next temporary file's number
	// Where LOG's line goes, the text as `qfd_log_line` makes it.  The
	// program says it; the check records it.
	void (*log)(void *ctx, const char *line);
	void *log_ctx;
};

void qfd_init(struct qfd *d);

// One `--file-root` value, muir's grammar: `<name>=<folder>[,ro]` when the
// text before the first `=` is a valid component, else `<folder>[,ro]`, the
// default folder.  0, or -1 with `why` filled: not a folder, a name given
// twice, a second default folder, too many.
int qfd_mount_add(struct qfd_mounts *m, const char *spec, char *why, size_t whylen);

// What the start says, a line a mount, muir's words: `emit` once a line.
void qfd_mounts_describe(const struct qfd_mounts *m, void (*emit)(void *ctx, const char *line),
			 void *ctx);

// One command: the entry at word `cmd_at` read, the host's operation done,
// buffer B and the response entry at word `resp_at` written.  The caller
// holds the claim and moves the indexes.
void qfd_execute(struct qfd *d, struct qfd_mem *mem, size_t cmd_at, size_t resp_at);

// The disable, which is the reset: every handle closed, every write
// discarded and its temporary file removed.
void qfd_reset(struct qfd *d);

unsigned qfd_handles_open(const struct qfd *d);

// A host errno's status: muir's `host_status`, EINVAL a name the host
// refuses (a FAT folder refuses `:` and `*`, among others).
uint32_t qfd_errno_status(int e);

// LOG's text: `log: ` and the line, a byte outside 040-176 as a backslash
// and three octal digits.  `out` holds at least 5 + 4 * n + 1 bytes.
void qfd_log_line(const uint8_t *bytes, size_t n, char *out);

// Why a checkpoint cannot be taken, muir's own sentence, or NULL when it
// can: a handle's host file and a command's host effect are outside the
// machine.  The inputs are the ones `cadr-checkpoint` reads off the face:
// the handles open and the commands the machine has posted and not had
// answered.  `buf` holds at least 200 bytes.
const char *qfd_checkpoint_refusal(unsigned handles, unsigned queued, char *buf, size_t len);

// The start's sweep: every regular file whose name begins with
// QFD_TEMP_PREFIX under a writable mount's folder, removed, symlinks not
// followed.  A read-only mount is left as it is.  `emit` is told each one.
// Returns how many were removed.
unsigned qfd_sweep(const struct qfd_mounts *m, void (*emit)(void *ctx, const char *path),
		   void *ctx);

#ifdef QFD_TEST_HOOKS
// The check's hooks into the host calls, which a Linux folder cannot produce
// on its own: an errno every host call that makes or moves a name gives
// while it is set (a FAT folder refuses such a name at every one), and a
// folder that finds a name whatever its case, as FAT does.
extern int qfd_hook_errno;
extern const char *qfd_hook_folding;
#endif

#endif
