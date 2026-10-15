#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""A QUUX card set: the disk's current microcode against the served tree's.

    python3 tools/quux_card_check.py --card ROOT
    python3 tools/quux_card_check.py --pack DISK --tree ROOT
    python3 tools/quux_card_check.py --tree ROOT

WHY THIS EXISTS.  A QUUX band boots on the microcode its disk's PROM finds,
and then reads that microcode's error table from the served tree,
`sys/ubin/ucadr.tbl`.  When the tree has no such file the band keeps the
table saved inside it, which belongs to whatever microcode the band was saved
under; the version number alone does not tell two builds of one microcode
apart, so a band whose MCR1 was replaced after its save looks every trap up at
the wrong address.  A card set is therefore refused unless the tree carries
`sys/ubin/ucadr.tbl` and `sys/ubin/ucadr.mcr`, and the `.mcr` is the
microcode the PROM loads.

ROOT is the root of the served tree, the directory holding `sys/` and `site/`
(on a card, the card's root, whose `sys/` the file device serves as `sys`).
`--card ROOT` takes the disk from `ROOT/packs/disk-pack-0.img`, QUUX's one
disk.  `--tree` alone checks the two files and compares nothing.

HOW THE PROM FINDS THE MICROCODE (muir-sys `sys/ucadr/promh.text`,
READ-LABEL and SEARCH-GPT), done here the same way:

  - The disk is a raw image, a fixed VHD or a dynamic VHD, told apart by the
    VHD footer in its last 512 bytes (cookie `conectix`; differencing disks
    are refused).  The VHD fields are Microsoft's Virtual Hard Disk Image
    Format Specification's, big-endian.
  - Sector 1 is the GPT header: `EFI PART` at 0, the entry array's first
    sector at 72 (even, its high 32 bits zero), the number of entries at 80,
    an entry's size at 84 (128).  Anything else is no GPT, where the PROM
    halts at ERROR-NO-GPT.  The header's CRC is not read, as the PROM does
    not read it.
  - The first entry, in array order, whose type GUID's first 32-bit word is
    the microcode type's, 9e318cf5 (`9e318cf5-a95b-4b3b-b2ad-9ae306b0e2da`),
    and whose attribute bit 48 is set is the microcode partition; none is
    ERROR-NO-CURRENT-MICR, and one starting on an odd sector is
    ERROR-ODD-MICR-START.  The PROM reads it from its first sector on.

WHAT IS COMPARED.  The `.mcr` is written over the partition from its first
byte (muir-sys's builder zeroes the partition and copies the file in; by hand,
`dd ... seek=<first block> conv=notrunc`), and the PROM reads the partition
from its first byte for as many words as the file's own sections say.  So
the file's L bytes are compared with the partition's first L bytes, byte for
byte; a file longer than the partition is refused.  When the file is the
self-describing format of revision 15 (format word 0x51550001), the number
of bytes the PROM reads, N, is worked out from its section headers, and a
file shorter than N is refused as truncated: its bytes would match a
partition whose microcode goes on.  The partition's bytes after L, which the
PROM does not read, are reported and not compared.

It prints what it read and compared, with SHA-256s, and exits 1 with every
reason when it refuses.
"""

import argparse
import hashlib
import os
import struct
import sys

SECTOR = 512
MCR_TYPE_WORD0 = 0x9E318CF5          # the microcode type GUID's first word
CURRENT_BIT = 48                     # the GPT attribute bit the PROM looks for
MCR15_FORMAT = 0x51550001            # revision 15's self-describing .mcr


class Refused(Exception):
    """A card set this check refuses, with the reason."""


class Disk:
    """A QUUX disk file read as its raw sectors: raw, fixed VHD or dynamic VHD."""

    def __init__(self, f, size):
        self.f = f
        self.size = size
        self.kind = "raw"
        self.length = size
        self.bat = None
        if size >= SECTOR:
            footer = self._pread(size - SECTOR, SECTOR)
            if footer[:8] == b"conectix":
                self._vhd(footer)

    def _pread(self, offset, n):
        self.f.seek(offset)
        b = self.f.read(n)
        if len(b) != n:
            raise Refused("the disk file ends at byte %d, reading %d bytes at %d"
                          % (self.size, n, offset))
        return b

    def _vhd(self, footer):
        want = struct.unpack(">I", footer[64:68])[0]
        got = (~sum(footer[:64] + b"\0\0\0\0" + footer[68:])) & 0xFFFFFFFF
        if want != got:
            raise Refused("the VHD footer's checksum is %08x where its bytes sum to %08x"
                          % (want, got))
        data_offset = struct.unpack(">Q", footer[16:24])[0]
        self.length = struct.unpack(">Q", footer[48:56])[0]
        dtype = struct.unpack(">I", footer[60:64])[0]
        if dtype == 2:
            self.kind = "fixed VHD"
            if self.length > self.size - SECTOR:
                raise Refused("the fixed VHD says %d bytes and holds %d"
                              % (self.length, self.size - SECTOR))
            return
        if dtype != 3:
            raise Refused("the VHD's disk type is %d, neither fixed (2) nor dynamic (3)" % dtype)
        self.kind = "dynamic VHD"
        head = self._pread(data_offset, 1024)
        if head[:8] != b"cxsparse":
            raise Refused("the dynamic VHD's header at %d has no cxsparse cookie" % data_offset)
        table = struct.unpack(">Q", head[16:24])[0]
        entries = struct.unpack(">I", head[28:32])[0]
        self.block = struct.unpack(">I", head[32:36])[0]
        if self.block == 0 or self.block % SECTOR:
            raise Refused("the dynamic VHD's block size is %d" % self.block)
        bitmap = -(-self.block // SECTOR // 8)
        self.bitmap = -(-bitmap // SECTOR) * SECTOR
        self.bat = struct.unpack(">%dI" % entries, self._pread(table, 4 * entries))

    def read(self, offset, n):
        """N bytes of the disk from byte OFFSET; past its end is refused."""
        if offset < 0 or offset + n > self.length:
            raise Refused("bytes %d to %d are past the disk's end, %d"
                          % (offset, offset + n, self.length))
        if self.bat is None:
            return self._pread(offset, n)
        out = bytearray()
        while n:
            k, within = divmod(offset, self.block)
            take = min(n, self.block - within)
            sector = self.bat[k] if k < len(self.bat) else 0xFFFFFFFF
            if sector == 0xFFFFFFFF:
                out += bytes(take)
            else:
                out += self._pread(sector * SECTOR + self.bitmap + within, take)
            offset += take
            n -= take
        return bytes(out)


def current_microcode(disk):
    """(entry index, name, first sector, last sector) as the PROM finds it."""
    head = disk.read(SECTOR, SECTOR)
    if head[:8] != b"EFI PART":
        raise Refused("no GPT: sector 1 does not start with EFI PART (the PROM halts at "
                      "ERROR-NO-GPT)")
    array, count, size = struct.unpack("<QII", head[72:88])
    if array & 1 or array >> 32:
        raise Refused("no GPT the PROM reads: the entry array's sector, %d, is odd or past "
                      "32 bits (ERROR-NO-GPT)" % array)
    if size != 128:
        raise Refused("no GPT the PROM reads: an entry is %d bytes, not 128 (ERROR-NO-GPT)"
                      % size)
    for i in range(count):
        e = disk.read(array * SECTOR + 128 * i, 128)
        if struct.unpack("<I", e[0:4])[0] != MCR_TYPE_WORD0:
            continue
        if not (struct.unpack("<Q", e[48:56])[0] >> CURRENT_BIT) & 1:
            continue
        first, last = struct.unpack("<QQ", e[32:48])
        name = e[56:128].decode("utf-16-le", "replace").split("\0")[0]
        if first & 1:
            raise Refused("the current microcode partition, entry %d, %s, starts on odd "
                          "sector %d (the PROM halts at ERROR-ODD-MICR-START)"
                          % (i + 1, name, first))
        if last < first:
            raise Refused("the current microcode partition, entry %d, %s, ends at sector %d "
                          "before its start, %d" % (i + 1, name, last, first))
        return i + 1, name, first, last
    raise Refused("no current microcode partition: none of the GPT's %d entries has the "
                  "microcode type 9e318cf5-... and attribute bit 48 (the PROM halts at "
                  "ERROR-NO-CURRENT-MICR)" % count)


def prom_length(mcr):
    """The bytes the PROM reads of a revision 15 .mcr, or None for another format.

    The file: the format word and the number of sections, then each section an
    8-word header (word 1 the number of items, word 3 the storage width in
    bits) and its items, each storage width / 32 words (promh.text, revision
    15's reader).  A header past the file's end counts as the file being short.
    """
    if len(mcr) < 8 or struct.unpack("<I", mcr[0:4])[0] != MCR15_FORMAT:
        return None
    sections = struct.unpack("<I", mcr[4:8])[0]
    words = 2
    for _ in range(sections):
        if 4 * (words + 8) > len(mcr):
            return 4 * (words + 8)
        h = struct.unpack("<8I", mcr[4 * words:4 * words + 32])
        words += 8 + h[1] * (h[3] // 32)
    return 4 * words


def sha(b):
    return hashlib.sha256(b).hexdigest()


def partition_label(name, index):
    """A partition's four-character Lisp name, MCR1, or its entry number."""
    return name.split()[0] if name.split() else "GPT entry %d" % index


def tree_files(tree, say):
    """The served tree's sys/ubin/ucadr.tbl and .mcr ({name: bytes}), and the problems."""
    problems, files = [], {}
    ubin = os.path.join(tree, "sys", "ubin")
    if not os.path.isdir(ubin):
        problems.append("the served tree %s has no sys/ubin/: the band would fall back to "
                        "the error table saved inside it" % tree)
        return files, problems
    for name in ("ucadr.tbl", "ucadr.mcr"):
        p = os.path.join(ubin, name)
        if not os.path.isfile(p):
            problems.append("the served tree has no sys/ubin/%s" % name)
            continue
        with open(p, "rb") as f:
            files[name] = f.read()
        say("sys/ubin/%s: %d bytes, sha256 %s" % (name, len(files[name]), sha(files[name])))
    return files, problems


def compare(disk, mcr, say):
    """The disk's current microcode against MCR, the served .mcr's bytes (None: absent)."""
    problems = []
    try:
        say("the disk is a %s of %d bytes" % (disk.kind, disk.length))
        index, name, first, last = current_microcode(disk)
        label = partition_label(name, index)
        part = (last - first + 1) * SECTOR
        say("the PROM's microcode partition: GPT entry %d, %s (\"%s\"), sectors %d to %d, "
            "%d bytes" % (index, label, name, first, last, part))
        if mcr is None:
            return problems
        n = prom_length(mcr)
        if n is None:
            say("sys/ubin/ucadr.mcr is not revision 15's self-describing format: its "
                "%d bytes are compared" % len(mcr))
        else:
            say("sys/ubin/ucadr.mcr is revision 15's format: the PROM reads its first "
                "%d bytes of %d, and all %d are compared" % (n, len(mcr), len(mcr)))
            if n > len(mcr):
                problems.append("sys/ubin/ucadr.mcr is %d bytes and its sections say %d: "
                                "it is truncated" % (len(mcr), n))
        if len(mcr) > part:
            problems.append("sys/ubin/ucadr.mcr is %d bytes, more than %s holds, %d"
                            % (len(mcr), label, part))
            return problems
        held = disk.read(first * SECTOR, len(mcr))
        say("%s's first %d bytes: sha256 %s" % (label, len(mcr), sha(held)))
        if held != mcr:
            at = next(i for i in range(len(mcr)) if held[i] != mcr[i])
            problems.append("sys/ubin/ucadr.mcr (sha256 %s) is not the microcode the PROM "
                            "loads: %s's first %d bytes differ from it, first at byte %d"
                            % (sha(mcr)[:16], label, len(mcr), at))
        else:
            say("sys/ubin/ucadr.mcr is %s's first %d bytes, byte for byte" % (label, len(mcr)))
        tail = disk.read(first * SECTOR + len(mcr), min(part - len(mcr), 1 << 20))
        say("%s after those bytes, which the PROM does not read: %s"
            % (label, "zero" if not any(tail) else "not zero"))
    except Refused as e:
        problems.append("the disk: %s" % e)
    return problems


def check(disk_file, tree, say):
    """Every reason to refuse the set (DISK_FILE None: the tree alone), saying what it read."""
    files, problems = tree_files(tree, say)
    if disk_file is None:
        say("no disk given: the microcode is not compared")
        return problems
    try:
        with open(disk_file, "rb") as f:
            h = hashlib.sha256()
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
            size = f.tell()
            say("disk %s: %d bytes, sha256 %s" % (disk_file, size, h.hexdigest()))
            problems += compare(Disk(f, size), files.get("ucadr.mcr"), say)
    except Refused as e:
        problems.append("the disk: %s" % e)
    except OSError as e:
        problems.append("the disk: %s" % e)
    return problems


def card_paths(root):
    """A card's disk and tree, or None for the disk when it carries none."""
    disk = os.path.join(root, "packs", "disk-pack-0.img")
    return (disk if os.path.isfile(disk) else None), root


# ------------------------------------------------------------- self test ---
#
# Small disks made here, not a real band: a raw GPT image, and the same disk
# as a fixed and as a dynamic VHD written by this test's own encoder, whose
# blocks lie in the file in reverse order.  The array holds decoys before the
# current microcode: a band partition with bit 48, and a microcode partition
# with bits 0, 47 and 49 but not 48, each holding other bytes; after it a
# second current microcode partition, which the PROM's first-in-order rule
# passes over.  With `--q8-disks`, muir's Q8 fixtures (made by sgdisk and
# qemu, not by this file) are read as raw, fixed and dynamic VHDs and must
# agree with their raw twins: the outside witness for the VHD reader.

LOD_TYPE_WORD0 = 0xA3B30470


def _mcr15(items):
    """A revision 15 .mcr: section 6 (15), a control store of ITEMS 64-bit
    items and an A memory of 3, padded with zeros to 1024 bytes."""
    w = [MCR15_FORMAT, 3, 6, 1, 32, 32, 0, 0, 0, 0, 15]
    w += [1, len(items), 64, 64, 0, 0, 0, 0]
    for x in items:
        w += [x & 0xFFFFFFFF, x >> 32]
    w += [4, 3, 40, 64, 0, 0, 0, 0, 0x11111111, 0x22, 0x33333333, 0x44, 0x55555555, 0x66]
    b = struct.pack("<%dI" % len(w), *w)
    return b + bytes(1024 - len(b))


GOOD = _mcr15([0x0123456789ABCDEF, 0xFEDCBA9876543210])
OTHER = _mcr15([0x0123456789ABCDEF, 0xFEDCBA9876543211])


def _disk(mcr1, current=True, mcr1_first=54, header=True, entry_size=128, array=2):
    """A raw GPT disk of 256 sectors with MCR1 holding MCR1 (sectors 54-57)."""
    d = bytearray(256 * SECTOR)
    if header:
        d[SECTOR:SECTOR + 8] = b"EFI PART"
        struct.pack_into("<QII", d, SECTOR + 72, array, 128, entry_size)
    parts = [(LOD_TYPE_WORD0, 1 << 48, 34, 49, "LOD1 decoy", b"L" * 8192),
             (MCR_TYPE_WORD0, 1 << 49 | 1 << 47 | 1, 50, 53, "MCR2 decoy", OTHER),
             (MCR_TYPE_WORD0, (1 << 48) if current else 0, mcr1_first, mcr1_first + 3,
              "MCR1 UCADR 2002", mcr1),
             (MCR_TYPE_WORD0, (1 << 48) if current else 0, 58, 61, "MCR3 decoy", OTHER)]
    for i, (t, attrs, first, last, name, data) in enumerate(parts):
        e = array * SECTOR + entry_size * i
        struct.pack_into("<I", d, e, t)
        d[e + 4:e + 16] = bytes.fromhex("5ba93b4bb2ad9ae306b0e2da")
        struct.pack_into("<QQQ", d, e + 32, first, last, attrs)
        nm = name.encode("utf-16-le")
        d[e + 56:e + 56 + len(nm)] = nm
        d[first * SECTOR:first * SECTOR + len(data)] = data
    return bytes(d)


def _footer(size, dtype, data_offset):
    f = bytearray(SECTOR)
    f[0:8] = b"conectix"
    struct.pack_into(">IIQ", f, 8, 2, 0x10000, data_offset)
    struct.pack_into(">QQ", f, 40, size, size)
    struct.pack_into(">I", f, 60, dtype)
    struct.pack_into(">I", f, 64, (~sum(f)) & 0xFFFFFFFF)
    return bytes(f)


def _fixed(raw):
    return raw + _footer(len(raw), 2, 0xFFFFFFFFFFFFFFFF)


def _dynamic(raw, block=16384, drop=None, bad_sum=False):
    """RAW as a dynamic VHD: blocks of zeros left unallocated, the others in
    the file in reverse order; DROP, a byte offset, leaves its block out."""
    n = -(-len(raw) // block)
    foot = _footer(len(raw), 3, SECTOR)
    head = bytearray(1024)
    head[0:8] = b"cxsparse"
    struct.pack_into(">QQIII", head, 8, 0xFFFFFFFFFFFFFFFF, 1536, 0x10000, n, block)
    struct.pack_into(">I", head, 36, (~sum(head)) & 0xFFFFFFFF)
    table = -(-4 * n // SECTOR) * SECTOR
    bat = [0xFFFFFFFF] * n
    body = bytearray()
    at = SECTOR + 1024 + table
    for k in reversed(range(n)):
        data = raw[k * block:(k + 1) * block]
        if not any(data) or (drop is not None and k == drop // block):
            continue
        bat[k] = (at + len(body)) // SECTOR
        body += b"\xff" * SECTOR + data
    if bad_sum:
        foot = foot[:64] + struct.pack(">I", struct.unpack(">I", foot[64:68])[0] ^ 1) + foot[68:]
    bats = struct.pack(">%dI" % n, *bat)
    return foot + bytes(head) + bats + b"\xff" * (table - len(bats)) + bytes(body) + foot


def self_test(q8_disks, out):
    import tempfile
    good = _disk(GOOD)
    tbl = b"(error table)\n"
    ubin = {"ucadr.tbl": tbl, "ucadr.mcr": GOOD}
    cases = [
        # name, disk bytes, sys/ubin files (None: no sys/ubin/), refused?, reason
        ("a good set, raw", good, ubin, False, ""),
        ("a good set, fixed VHD", _fixed(good), ubin, False, ""),
        ("a good set, dynamic VHD", _dynamic(good), ubin, False, ""),
        ("a good set, MCR1 not revision 15's format",
         _disk(b"\x07" * 1500), dict(ubin, **{"ucadr.mcr": b"\x07" * 1500}), False, ""),
        ("a .mcr exactly as long as MCR1", good,
         dict(ubin, **{"ucadr.mcr": GOOD + bytes(1024)}), False, ""),
        ("a .mcr exactly as long as the PROM reads", good,
         dict(ubin, **{"ucadr.mcr": GOOD[:prom_length(GOOD)]}), False, ""),
        ("no sys/ubin/", good, None, True, "has no sys/ubin/:"),
        ("no ucadr.tbl", good, {"ucadr.mcr": GOOD}, True, "no sys/ubin/ucadr.tbl"),
        ("no ucadr.mcr", good, {"ucadr.tbl": tbl}, True, "no sys/ubin/ucadr.mcr"),
        ("ucadr.mcr one byte off inside what the PROM reads", good,
         dict(ubin, **{"ucadr.mcr": GOOD[:140] + bytes([GOOD[140] ^ 1]) + GOOD[141:]}),
         True, "differ from it, first at byte 140"),
        ("ucadr.mcr the non-current MCR2's", good, dict(ubin, **{"ucadr.mcr": OTHER}),
         True, "is not the microcode the PROM loads"),
        ("ucadr.mcr truncated inside what the PROM reads", good,
         dict(ubin, **{"ucadr.mcr": GOOD[:100]}), True, "it is truncated"),
        ("ucadr.mcr one byte longer than MCR1", good,
         dict(ubin, **{"ucadr.mcr": GOOD + bytes(1025)}), True, "more than MCR1 holds"),
        ("a dynamic VHD with MCR1's block not allocated", _dynamic(good, drop=54 * SECTOR),
         ubin, True, "differ from it, first at byte 0"),
        ("a dynamic VHD whose footer's checksum is wrong", _dynamic(good, bad_sum=True),
         ubin, True, "footer's checksum"),
        ("no GPT", _disk(GOOD, header=False), ubin, True, "no GPT: sector 1"),
        ("a GPT of 256-byte entries", _disk(GOOD, entry_size=256), ubin, True,
         "not 128 (ERROR-NO-GPT)"),
        ("a GPT whose entries start on an odd sector", _disk(GOOD, array=3), ubin, True,
         "is odd or past 32 bits"),
        ("no current microcode", _disk(GOOD, current=False), ubin, True,
         "ERROR-NO-CURRENT-MICR"),
        ("the current microcode on an odd sector", _disk(GOOD, mcr1_first=63), ubin, True,
         "ERROR-ODD-MICR-START"),
    ]
    wrong = 0
    with tempfile.TemporaryDirectory(prefix="quux-card-check-") as tmp:
        for k, (name, disk, files, refused, reason) in enumerate(cases):
            root = os.path.join(tmp, "c%d" % k)
            os.makedirs(os.path.join(root, "packs"))
            os.makedirs(os.path.join(root, "site"))
            if files is not None:
                os.makedirs(os.path.join(root, "sys", "ubin"))
                for fn, b in files.items():
                    with open(os.path.join(root, "sys", "ubin", fn), "wb") as f:
                        f.write(b)
            with open(os.path.join(root, "packs", "disk-pack-0.img"), "wb") as f:
                f.write(disk)
            said = []
            disk_file, tree = card_paths(root)
            problems = check(disk_file, tree, said.append)
            ok = (bool(problems) == refused
                  and (not refused or any(reason in p for p in problems)))
            wrong += not ok
            out.write("self test: %-58s %s%s\n" % (name, "refused" if problems else "passed",
                                                   "" if ok else "   WRONG"))
            for p in problems if not ok else []:
                out.write("self test:     %s\n" % p)
        # A card without its disk.
        if card_paths(os.path.join(tmp, "c%d" % (len(cases) + 1)))[0] is not None:
            wrong += 1
            out.write("self test: a card without packs/disk-pack-0.img found a disk   WRONG\n")
    if q8_disks is not None:
        wrong += q8_witness(q8_disks, out)
    if wrong:
        out.write("self test: %d WRONG\n" % wrong)
        return 1
    out.write("self test: %d cases, all as expected\n" % len(cases))
    return 0


def q8_witness(directory, out):
    """muir's Q8 fixtures, read as each format, against their raw twins."""
    wrong = 0
    pairs = [("quux-disk-fixed.vhd", "quux-disk.img"), ("quux-disk-dynamic.vhd", "quux-disk.img"),
             ("quux-disk-dynamic-grown.vhd", "quux-disk-grown.img")]
    for vhd, img in pairs:
        try:
            with open(os.path.join(directory, img), "rb") as r, \
                    open(os.path.join(directory, vhd), "rb") as v:
                raw = r.read()
                d = Disk(v, os.fstat(v.fileno()).st_size)
                index, name, first, last = current_microcode(d)
                mcr = raw[first * SECTOR:(last + 1) * SECTOR]
                same = (d.length == len(raw)
                        and d.read(first * SECTOR, len(mcr)) == mcr
                        and d.read(0, len(raw)) == raw)
                ok = (d.kind != "raw" and same and (index, name, first, last)
                      == (1, "MCR1 UCADR 2000", 2048, 2559) and any(mcr))
        except (OSError, Refused) as e:
            ok, name, first, last, d = False, str(e), 0, 0, None
        wrong += not ok
        out.write("self test: %s as a %s: %s, sectors %d to %d, its raw twin's bytes%s\n"
                  % (vhd, d.kind if d else "?", name, first, last, "" if ok else "   WRONG"))
    return wrong


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--card", help="a card's root: its packs/disk-pack-0.img and its tree")
    ap.add_argument("--pack", help="the QUUX disk: raw, a fixed VHD or a dynamic VHD")
    ap.add_argument("--tree", help="the served tree's root, holding sys/ and site/")
    ap.add_argument("--self-test", action="store_true",
                    help="run this check over small disks made here")
    ap.add_argument("--q8-disks", help="with --self-test: muir's data/ directory, whose Q8 "
                    "disks the VHD reader is held to")
    args = ap.parse_args()
    if args.self_test:
        sys.exit(self_test(args.q8_disks, sys.stdout))
    if args.card:
        if args.pack or args.tree:
            ap.error("--card names both the disk and the tree; give it alone")
        disk, tree = card_paths(args.card)
        if disk is None:
            print("quux_card_check: REFUSED: the card %s has no packs/disk-pack-0.img"
                  % args.card)
            sys.exit(1)
    elif args.tree:
        disk, tree = args.pack, args.tree
    else:
        ap.error("give --card ROOT, or --tree ROOT with or without --pack DISK")
    if not os.path.isdir(tree):
        print("quux_card_check: REFUSED: no served tree at %s" % tree)
        sys.exit(1)
    problems = check(disk, tree, lambda s: print("quux_card_check: " + s))
    for p in problems:
        print("quux_card_check: REFUSED: " + p)
    if problems:
        sys.exit(1)
    print("quux_card_check: OK")


if __name__ == "__main__":
    main()
