#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The scripts of rings that muir's file device and this program both run,
# and the folders they run against.
#
# **NOTHING HERE SAYS WHAT AN ANSWER SHOULD BE.**  muir's own device is the
# judge: `golden/src/quux_file_device.rs` runs each script and `qfd_test`
# runs the same one, and `qfd_compare.py` holds the two transcripts and the
# two folders after to each other byte for byte.  A script here only has to
# reach things --- every command, every status, every rule of names, mounts,
# rings and handles --- and `qfd_compare.py` counts, in muir's transcripts,
# that every status and every opcode was produced, so that a script that
# stopped reaching something is seen.
#
# A script's handles are predicted here (the lowest free one, as muir gives
# them), which is only a convenience: a prediction that went wrong would
# still be compared, and would show as a status nobody meant.

import os
import stat

OPEN, READ, WRITE, CLOSE, DIRECTORY, COMPLETE, DELETE, RENAME, CREATE_DIRECTORY, LOG = range(1, 11)
MODE_READ, MODE_WRITE, MODE_PROBE = 0, 1, 2
SUPERSEDE, ERROR, APPEND = 0, 1, 2
T0 = 1600000000
MEMORY = 0x40000
CMD_BASE, RESP_BASE = 0x1000, 0x2000
HEAP = 0x4000


def oflags(mode=MODE_READ, if_exists=SUPERSEDE, if_none_error=0):
    return mode | if_exists << 2 | if_none_error << 4


class Scenario:
    def __init__(self, name):
        self.name = name
        self.lines = []
        self.seed = []          # (kind, rel, arg...)
        self.tag = 1
        self.heap = HEAP
        self.cmd_log2 = 4
        self.handles = set()
        self.index = 0          # the next response's index: commands since the enable

    # --- the folder -------------------------------------------------------
    def file(self, rel, data=b"", mtime=T0, mode=0o644):
        self.seed.append(("file", rel, data if isinstance(data, bytes) else data.encode(), mtime, mode))

    def dir(self, rel):
        self.seed.append(("dir", rel))

    def symlink(self, rel, target):
        self.seed.append(("symlink", rel, target))

    def fifo(self, rel):
        self.seed.append(("fifo", rel))

    def sparse(self, rel, size, mtime=T0):
        self.seed.append(("sparse", rel, size, mtime))

    def build(self, where):
        os.makedirs(where, exist_ok=True)
        for s in self.seed:
            p = os.path.join(where, s[1])
            os.makedirs(os.path.dirname(p), exist_ok=True)
            if s[0] == "file":
                with open(p, "wb") as f:
                    f.write(s[2])
                os.chmod(p, s[4])
                os.utime(p, (s[3], s[3]))
            elif s[0] == "dir":
                os.makedirs(p, exist_ok=True)
            elif s[0] == "symlink":
                os.symlink(s[2], p)
            elif s[0] == "fifo":
                os.mkfifo(p)
            elif s[0] == "sparse":
                with open(p, "wb") as f:
                    f.truncate(s[2])
                os.utime(p, (s[3], s[3]))

    # --- the script -------------------------------------------------------
    def op(self, *words):
        self.lines.append(" ".join(str(w) for w in words))

    def start(self, *roots, cmd_log2=4, resp_log2=4, describe=True):
        self.op("memory", hex(MEMORY))
        for r in roots:
            self.op("root", r)
        if describe:
            self.op("describe")
        self.rings(cmd_log2, resp_log2)
        self.enable()

    def enable(self, ie=0):
        self.op("enable", ie)
        self.index = 0

    def disable(self):
        self.op("disable")
        self.index = 0
        self.handles.clear()

    def reset(self):
        self.op("reset")
        self.index = 0
        self.handles.clear()

    def rings(self, cmd_log2, resp_log2, cmd_base=CMD_BASE, resp_base=RESP_BASE):
        self.cmd_log2 = cmd_log2
        self.op("rings", hex(cmd_base), cmd_log2, hex(resp_base), resp_log2)

    def alloc(self, nbytes):
        words = max(1, (nbytes + 3) // 4)
        words = (words + 3) & ~3
        if self.heap + words > MEMORY - 0x100:
            self.heap = HEAP
        at = self.heap
        self.heap += words
        return at

    def cmd(self, op, flags=0, handle=0, a=None, b=0, off=0, date=0,
            a_addr=None, a_len=None, b_addr=None, b_len=None):
        """One command entry.  `a` is buffer A's bytes; `b` is buffer B's
        length, or its bytes (RENAME's second name).  An address or a length
        given outright is used as it is, which is how a bad buffer is made."""
        if isinstance(a, str):
            a = a.encode("latin-1")
        if isinstance(b, str):
            b = b.encode("latin-1")
        if a is not None:
            at = self.alloc(len(a)) if a_addr is None else a_addr
            if a and (at & 0xFFFFFF) + (len(a) + 3) // 4 <= MEMORY:
                self.op("bytes", hex(at & 0xFFFFFF), a.hex())
            a_addr = at
            a_len = len(a) if a_len is None else a_len
        if isinstance(b, bytes):
            at = self.alloc(len(b)) if b_addr is None else b_addr
            if b:
                self.op("bytes", hex(at), b.hex())
            b_addr = at
            b_len = len(b) if b_len is None else b_len
        elif b or b_len:
            n = b if b_len is None else b_len
            at = self.alloc(min(n, 65536)) if b_addr is None else b_addr
            if at + (min(n, 65536) + 3) // 4 <= MEMORY and not at & 3:
                self.op("fill", hex(at), (min(n, 65536) + 3) // 4, hex(0xA5000000 | self.tag))
            b_addr, b_len = at, n
        self.index += 1
        tag = self.tag
        self.tag = (self.tag + 1) & 0xFFFF
        w0 = tag | (op & 0xFF) << 16 | (flags & 0xFF) << 24
        self.op("cmd", hex(w0), handle, hex(a_addr or 0), a_len or 0, hex(b_addr or 0), b_len or 0,
                off, date)

    def go(self, n=1):
        """Post the last n commands, let the device run, and consume what it answered."""
        self.op("post")
        self.op("run")
        self.op("consume", n)

    def one(self, *args, **kw):
        self.cmd(*args, **kw)
        self.go()

    # Helpers whose handles are predicted.
    def open_read(self, name):
        h = min(set(range(1, 65)) - self.handles)
        self.handles.add(h)
        self.one(OPEN, oflags(MODE_READ), a=name)
        return h

    def open_write(self, name, if_exists=SUPERSEDE, if_none_error=0):
        h = min(set(range(1, 65)) - self.handles)
        self.handles.add(h)
        self.one(OPEN, oflags(MODE_WRITE, if_exists, if_none_error), a=name)
        return h

    def close(self, h, flags=0, date=0):
        self.handles.discard(h)
        self.one(CLOSE, flags, handle=h, date=date)

    def probe(self, name):
        self.one(OPEN, oflags(MODE_PROBE), a=name)

    def text(self):
        return "\n".join(self.lines) + "\n"


def basic():
    s = Scenario("basic")
    s.file("root/hello.txt", "Hello, world!\n")
    s.file("root/big.bin", bytes((i * 7 + 3) & 0xFF for i in range(100000)), mtime=T0 + 5)
    s.file("root/empty.txt", b"")
    s.file("root/sub/inner.txt", "inner text\n", mtime=T0 + 9)
    s.file("root/mode640.txt", "private\n", mode=0o640)
    s.file("root/doomed.txt", "going, going\n")
    s.dir("root/d")
    s.start("@/root")
    for n in ("/hello.txt", "/sub", "/sub/", "/", "/nope", "/nope/x", "/hello.txt/x", "/empty.txt"):
        s.probe(n)
    h = s.open_read("/hello.txt")
    for off, want in ((0, 5), (7, 100), (14, 10), (15, 1), (3, 0), (1, 3), (0, 65536)):
        s.one(READ, handle=h, b=want, off=off)
    s.close(h)
    s.one(READ, handle=h, b=8)
    # Several READs of one file in flight at once.
    h = s.open_read("/big.bin")
    for off in (0, 1024, 99000, 50001):
        s.cmd(READ, handle=h, b=1024, off=off)
    s.go(4)
    s.close(h)
    # A write lands whole at CLOSE.
    h = s.open_write("/new.txt")
    s.one(WRITE, handle=h, a="abc", off=0)
    s.one(WRITE, handle=h, a="defg", off=3)
    s.one(WRITE, handle=h, a="XY", off=1)
    s.one(WRITE, handle=h, a="hole", off=10)
    s.probe("/new.txt")
    s.close(h, flags=2, date=1234567890)
    h = s.open_read("/new.txt")
    s.one(READ, handle=h, b=64)
    s.close(h)
    # Supersede an existing file, with its permissions kept.
    for name in ("/hello.txt", "/mode640.txt"):
        h = s.open_write(name)
        s.one(WRITE, handle=h, a="short", off=0)
        s.close(h, flags=2, date=T0 + 100)
    # Append: the reply's length is the old file's.
    h = s.open_write("/sub/inner.txt", if_exists=APPEND)
    s.one(WRITE, handle=h, a=" and more", off=11)
    s.one(WRITE, handle=h, a="x", off=0)
    s.close(h, flags=2, date=T0 + 200)
    # If it exists, error: at OPEN, and at CLOSE for one that appeared.
    s.one(OPEN, oflags(MODE_WRITE, ERROR), a="/sub/inner.txt")
    h = s.open_write("/appear.txt", if_exists=ERROR)
    s.op("hostwrite", "root/appear.txt", b"theirs".hex())
    s.one(WRITE, handle=h, a="mine", off=0)
    s.close(h, flags=2, date=T0)
    s.op("utime", "root/appear.txt", T0 + 300)
    # If it does not exist, error; and an abort leaves the old file.
    s.one(OPEN, oflags(MODE_WRITE, SUPERSEDE, 1), a="/missing.txt")
    h = s.open_write("/sub/inner.txt", if_none_error=1)
    s.one(WRITE, handle=h, a="lost", off=0)
    s.close(h, flags=1)
    s.probe("/sub/inner.txt")
    # What OPEN refuses.
    for name, flags in (("/nodir/x.txt", oflags(MODE_WRITE)), ("/sub", oflags(MODE_WRITE)),
                        ("/sub", oflags(MODE_READ)), ("/", oflags(MODE_WRITE)),
                        ("/", oflags(MODE_READ)), ("/missing.txt", oflags(MODE_READ))):
        s.one(OPEN, flags, a=name)
    # A CLOSE without a date: the host's clock.
    h = s.open_write("/nodate.txt")
    s.one(WRITE, handle=h, a="when?", off=0)
    s.op("nowat", s.index)
    s.close(h)
    s.op("utime", "root/nodate.txt", T0 + 400)
    s.probe("/nodate.txt")
    # The wrong kind of handle, and none.
    hr = s.open_read("/empty.txt")
    hw = s.open_write("/w.txt")
    s.one(READ, handle=hw, b=4)
    s.one(WRITE, handle=hr, a="no", off=0)
    s.one(READ, handle=0, b=4)
    s.one(READ, handle=65, b=4)
    s.one(CLOSE, handle=0)
    s.one(CLOSE, handle=0xFFFFFFFF)
    s.one(READ, handle=hr, b=4, off=0)
    s.close(hr, flags=1)
    s.close(hw, flags=2, date=T0 + 500)
    # A read handle outlives the host's delete.
    h = s.open_read("/doomed.txt")
    s.op("hostrm", "root/doomed.txt")
    s.one(READ, handle=h, b=64)
    s.close(h, flags=2, date=5)
    # An empty write, and a WRITE past what the file holds.
    h = s.open_write("/empty2.txt")
    s.one(WRITE, handle=h, a=b"", off=0)
    s.one(WRITE, handle=h, a="late", off=1)
    s.close(h, flags=2, date=T0)
    return s


def directory():
    s = Scenario("directory")
    for n in ("b.txt", "a.txt", ".hidden", "C.txt", "sp ace.txt", "~tilde"):
        s.file("root/" + n, n * 3)
    s.file("root/.quux-write-99-1", "stale")
    s.file("root/bad\x7fname", "unlisted")
    s.file("root/tab\tname", "unlisted")
    s.file("root/" + "L" * 200, "long")
    s.dir("root/dir1")
    s.symlink("root/link-in", "a.txt")
    s.symlink("root/link-out", "../outside")
    s.symlink("root/link-dangling", "nowhere")
    s.symlink("root/linkdir", "dir1")
    s.fifo("root/fifo")
    s.file("outside/secret", "no")
    for k in range(60):
        s.file("root/many/f%02d" % k, "x" * k, mtime=T0 + k)
    s.sparse("root/huge.bin", 1 << 32)
    s.start("@/root")
    s.one(DIRECTORY, a="/", b=4096)
    s.one(DIRECTORY, a="/dir1", b=272)
    s.one(DIRECTORY, a="/dir1/", b=272)
    s.one(DIRECTORY, a="/linkdir", b=272)
    for cookie in (0, 17, 34, 51, 60, 100):
        s.one(DIRECTORY, a="/many", b=272, off=cookie)
    s.one(DIRECTORY, a="/many", b=4096, off=3)
    s.one(DIRECTORY, a="/many", b=271)
    for n in ("/a.txt", "/nope", "/nope/x", "rel", "/link-out", "/fifo"):
        s.one(DIRECTORY, a=n, b=512)
    s.probe("/huge.bin")
    s.one(OPEN, oflags(MODE_WRITE, APPEND), a="/huge.bin")
    s.probe("/fifo")
    s.one(OPEN, oflags(MODE_READ), a="/fifo")
    s.one(OPEN, oflags(MODE_WRITE), a="/fifo")
    return s


def complete():
    s = Scenario("complete")
    for n in ("apple", "apricot", "app", "banana", ".dot"):
        s.file("root/c/" + n, n)
    s.dir("root/c/apex")
    s.file("root/c/.quux-write-1-1", "stale")
    s.start("@/root")
    for t in ("/c/ap", "/c/app", "/c/ape", "/c/apex", "/c/z", "/c/", "/c/.", "/c/.q", "/", "/c",
              "/nope/x", "/c/apple/x", "c/x", "nosl", "/c/\x01", "/c/" + "p" * 256, "/c//a"):
        s.one(COMPLETE, a=t, b=256)
    s.one(COMPLETE, a="/c/b", b=2)
    s.one(COMPLETE, a="/c/b", b=6)
    return s


def ops():
    s = Scenario("ops")
    s.file("root/f.txt", "f")
    s.file("root/a.txt", "a")
    s.file("root/exists.txt", "e")
    s.dir("root/emptydir")
    s.dir("root/dir2")
    s.file("root/full/x", "x")
    s.file("root/sub/s.txt", "s")
    s.file("rofolder/r.txt", "r")
    s.file("otherfolder/o.txt", "o")
    s.start("@/root", "ro=@/rofolder,ro", "other=@/otherfolder")
    for n in ("/f.txt", "/f.txt", "/emptydir", "/full", "/nope/x", "/ro/r.txt", "/ro", "/other", "/",
              "/other/o.txt", "rel"):
        s.one(DELETE, a=n)
    for f, t in (("/a.txt", "/b.txt"), ("/b.txt", "/exists.txt"), ("/b.txt", "/dir2"),
                 ("/b.txt", "/other/b.txt"), ("/b.txt", "/nope/b.txt"), ("/missing", "/x"),
                 ("/sub", "/sub2"), ("/ro/r.txt", "/y"), ("/other", "/o2"), ("/y", "/other"),
                 ("/b.txt", "/"), ("/b.txt", "rel"), ("rel", "/b.txt"), ("/dir2", "/dir2/inside")):
        s.one(RENAME, a=f, b=t)
    for n in ("/newdir", "/newdir", "/exists.txt", "/nope/deep", "/ro/n", "/other/n", "/", "/ro",
              "/newdir/inner"):
        s.one(CREATE_DIRECTORY, a=n)
    s.one(OPEN, oflags(MODE_WRITE), a="/ro/x")
    s.one(OPEN, oflags(MODE_WRITE), a="/ro/r.txt")
    s.one(DIRECTORY, a="/", b=1024)
    s.probe("/ro")
    s.probe("/ro/r.txt")
    s.probe("/other/")
    return s


def names():
    s = Scenario("names")
    s.file("root/hello.txt", "hi")
    s.file("root/sp ace", "space")
    s.file("root/sub/x", "x")
    s.start("@/root")
    for n in (b"", b"rel", b"/a//b", b"/./a", b"/a/..", b"/..", b"/.", b"/\x1f", b"/\x7f", b"/\x80",
              b"/" + b"x" * 255, b"/" + b"x" * 256, b"/" + b"y/" * 511 + b"z", b"/" + b"y/" * 512,
              b"/sub/", b"/sub//", b"//", b"/HELLO.TXT", b"/Hello.txt", b"/hello.txt", b"/sp ace",
              b"/sub/x/"):
        s.one(OPEN, oflags(MODE_PROBE), a=n)
    return s


def mounts_override():
    s = Scenario("mounts_override")
    s.file("base/sys/base-only", "hidden by the named sys")
    s.file("base/site/site.lisp", "site")
    s.file("base/home/lispm/init.lisp", "init")
    s.file("base/x/y", "y")
    s.file("othersys/sysfile", "sys")
    s.file("scratch/s", "s")
    s.start("@/base", "sys=@/othersys", "scratch=@/scratch,ro")
    s.one(DIRECTORY, a="/", b=1024)
    for n in ("/sys/", "/sys/sysfile", "/sys/base-only", "/home/lispm/init.lisp", "/scratch", "/nope",
              "/nope/x", "/x/y"):
        s.probe(n)
    s.one(OPEN, oflags(MODE_WRITE), a="/scratch/new")
    s.one(OPEN, oflags(MODE_WRITE), a="/home/lispm/new.lisp")
    s.one(CREATE_DIRECTORY, a="/newtop")
    s.one(RENAME, a="/x/y", b="/sys/y")
    s.one(RENAME, a="/sys/sysfile", b="/sys/sysfile2")
    return s


def mounts_named_only():
    s = Scenario("mounts_named_only")
    s.file("s/a", "a")
    s.file("t/b", "b")
    s.start("sys=@/s,ro", "site=@/t")
    s.one(DIRECTORY, a="/", b=1024)
    s.probe("/")
    s.one(OPEN, oflags(MODE_READ), a="/")
    for n in ("/x", "/zzz", "/zzz/x"):
        s.probe(n)
    s.one(OPEN, oflags(MODE_WRITE), a="/x")
    s.one(OPEN, oflags(MODE_WRITE), a="/zzz/x")
    s.one(CREATE_DIRECTORY, a="/x")
    s.one(CREATE_DIRECTORY, a="/")
    s.one(DELETE, a="/sys")
    s.one(DELETE, a="/site")
    s.one(DELETE, a="/zzz/q")
    s.one(RENAME, a="/site/b", b="/site/c")
    s.one(RENAME, a="/site", b="/q")
    s.one(RENAME, a="/zzz/a", b="/site/q")
    s.one(DIRECTORY, a="/zzz", b=512)
    s.one(COMPLETE, a="/s", b=64)
    return s


def mounts_none():
    s = Scenario("mounts_none")
    s.start()
    s.one(DIRECTORY, a="/", b=512)
    s.probe("/")
    for n in ("/x", "/x/y"):
        s.probe(n)
        s.one(OPEN, oflags(MODE_READ), a=n)
    s.one(COMPLETE, a="/", b=64)
    return s


def mounts_bad():
    s = Scenario("mounts_bad")
    s.file("afile", "not a folder")
    for d in ("a", "b", "c", "d", "x"):
        s.dir(d)
    s.op("memory", hex(MEMORY))
    for r in ("@/nonexistent", "@/afile", "sys=@/a", "sys=@/b", "@/c", "@/d", "a/b=@/c", "n=@/x,ro",
              "m=@/afile", "=@/a", "p=@/a,ro,ro", "q=@/nonexistent,ro"):
        s.op("root", r)
    s.op("describe")
    s.rings(4, 4)
    s.enable()
    s.one(DIRECTORY, a="/", b=1024)
    return s


def handles():
    s = Scenario("handles")
    s.file("root/h.txt", "handle")
    s.start("@/root")
    hs = [s.open_read("/h.txt") for _ in range(64)]
    s.one(OPEN, oflags(MODE_READ), a="/h.txt")
    s.one(OPEN, oflags(MODE_WRITE), a="/w.txt")
    s.probe("/h.txt")
    for h in hs:
        s.close(h)
    # Commands queued behind a full response ring, with one handle open.
    s.disable()
    s.rings(3, 0)
    s.enable()
    h = s.open_read("/h.txt")
    for _ in range(3):
        s.cmd(READ, handle=h, b=4)
    s.op("post")
    s.op("run")
    s.op("consume", 1)
    s.op("run")
    s.op("consume", 1)
    s.op("run")
    s.op("consume", 1)
    s.one(CLOSE, handle=h)
    for _ in range(2):
        s.cmd(OPEN, oflags(MODE_PROBE), a="/h.txt")
    s.op("post")
    s.op("run")
    s.op("consume", 1)
    s.op("run")
    s.op("consume", 1)
    return s


def rings():
    s = Scenario("rings")
    s.file("root/r.txt", "ring")
    s.start("@/root", cmd_log2=0, resp_log2=0)
    for _ in range(5):
        s.probe("/r.txt")
    s.disable()
    s.rings(1, 1)
    s.enable(1)
    for _ in range(5):
        s.cmd(OPEN, oflags(MODE_PROBE), a="/r.txt")
        s.cmd(0)
        s.go(2)
    # A disable drops what is queued, closes every handle and discards
    # every write; the rings may move before the next enable.
    s.disable()
    s.rings(3, 0, cmd_base=0x3000, resp_base=0x3800)
    s.enable()
    s.cmd(OPEN, oflags(MODE_WRITE), a="/dropped.txt")
    s.cmd(WRITE, handle=1, a="dropped", off=0)
    s.cmd(CLOSE, flags=2, handle=1, date=T0)
    s.op("post")
    s.op("run")
    s.disable()
    s.op("run")
    s.rings(4, 4)
    s.enable()
    s.one(WRITE, handle=1, a="gone", off=0)
    s.probe("/dropped.txt")
    # And a machine reset does the same.
    s.cmd(OPEN, oflags(MODE_WRITE), a="/reset.txt")
    s.op("post")
    s.op("run")
    s.reset()
    s.enable()
    s.one(CLOSE, handle=1, flags=2, date=T0)
    s.probe("/reset.txt")
    # 256 entries a ring, and the indexes across 2^16.
    s.disable()
    s.rings(8, 8)
    s.enable()
    probe = s.alloc(8)
    s.op("bytes", hex(probe), b"/r.txt".hex())
    for batch in range(257):
        for k in range(256):
            if k % 64 == 0:
                s.cmd(OPEN, oflags(MODE_PROBE), a=b"/r.txt", a_addr=probe)
            else:
                s.cmd(0)
        s.go(256)
    return s


def buffers():
    s = Scenario("buffers")
    s.file("root/f.txt", "0123456789")
    s.start("@/root")
    good = s.alloc(8)
    s.op("bytes", hex(good), b"/f.txt".hex())
    s.one(OPEN, oflags(MODE_PROBE), a=b"/f.txt", a_addr=good + 1)
    s.one(OPEN, oflags(MODE_PROBE), a=b"/f.txt", a_addr=good + 2, a_len=6)
    s.one(OPEN, oflags(MODE_PROBE), a=b"/f.txt", a_addr=good, a_len=65537)
    s.one(OPEN, oflags(MODE_PROBE), a=b"/f.txt", a_addr=MEMORY - 4, a_len=17)
    s.one(OPEN, oflags(MODE_PROBE), a=b"/f.txt", a_addr=MEMORY - 4, a_len=16)
    s.one(OPEN, oflags(MODE_PROBE), a=b"/f.txt", a_addr=0xFF000000 | good)
    s.one(OPEN, oflags(MODE_PROBE), a=b"/f.txt", a_addr=MEMORY + 4)
    h = s.open_read("/f.txt")
    s.one(READ, handle=h, b=4, b_addr=good + 2)
    s.one(READ, handle=h, b=4, b_addr=MEMORY - 4, b_len=20)
    s.one(READ, handle=h, b=65537)
    for n in (1, 2, 3, 4, 5, 9, 10):
        s.one(READ, handle=h, b=n)
    s.one(READ, 1, handle=h, b=4)
    s.close(h)
    for flags in (3, 3 << 2 | MODE_WRITE, 0x20, 0x80):
        s.one(OPEN, flags, a="/f.txt")
    s.one(CLOSE, 4, handle=1)
    for op in (0, 11, 63, 128, 255):
        s.one(op, a="/f.txt", b=16)
    for op in (DIRECTORY, COMPLETE, DELETE, RENAME, CREATE_DIRECTORY, LOG, WRITE, READ):
        s.one(op, 0x40, a="/f.txt", b=16)
    return s


def logs():
    s = Scenario("logs")
    s.start("@/root")
    s.file("root/keep", "k")
    s.one(LOG, a="report: script-ends")
    for k in range(4):
        s.one(LOG, a=bytes(range(64 * k, 64 * k + 64)))
    s.one(LOG, a=b"")
    s.one(LOG, a=b"x" * 1024)
    s.one(LOG, a=b"y" * 1025)
    s.one(LOG, a=b"\\ backslash and \"quote\"")
    return s


def symlinks():
    s = Scenario("symlinks")
    s.file("root/real/file.txt", "real file")
    s.file("root/real/f2.txt", "second")
    s.symlink("root/inlink", "real")
    s.symlink("root/filelink", "real/file.txt")
    s.symlink("root/filelink2", "real/f2.txt")
    s.symlink("root/out", "../outside")
    s.symlink("root/outfile", "../outside/secret.txt")
    s.symlink("root/loop1", "loop2")
    s.symlink("root/loop2", "loop1")
    s.symlink("root/dangle", "nowhere")
    s.symlink("root/abs-out", "/")
    s.file("outside/secret.txt", "secret")
    # A folder whose name begins with the mount's: outside it all the same.
    s.file("rootx/f", "beside")
    s.symlink("root/sneaky", "../rootx/f")
    s.start("@/root")
    for n in ("/sneaky", "/inlink/file.txt", "/filelink", "/out/secret.txt", "/outfile", "/loop1", "/dangle",
              "/abs-out", "/loop1/x", "/out", "/inlink"):
        s.one(OPEN, oflags(MODE_READ), a=n)
        s.probe(n)
    s.one(DIRECTORY, a="/", b=2048)
    s.one(DIRECTORY, a="/inlink", b=512)
    s.one(DIRECTORY, a="/out", b=512)
    s.one(COMPLETE, a="/o", b=64)
    h = s.open_write("/filelink2")
    s.one(WRITE, handle=h, a="through the link", off=0)
    s.close(h, flags=2, date=T0 + 1)
    s.one(DELETE, a="/filelink")
    s.one(DELETE, a="/outfile")
    s.one(DELETE, a="/dangle")
    s.one(RENAME, a="/loop1", b="/loop3")
    s.one(RENAME, a="/inlink", b="/inlink2")
    s.one(CREATE_DIRECTORY, a="/dangle")
    s.one(CREATE_DIRECTORY, a="/out/x")
    s.one(OPEN, oflags(MODE_WRITE), a="/out/new")
    s.one(OPEN, oflags(MODE_WRITE), a="/dangle")
    return s


def perms():
    s = Scenario("perms")
    s.file("root/secret.txt", "secret")
    s.file("root/locked/x.txt", "x")
    s.file("root/readonly/y.txt", "y")
    s.start("@/root")
    s.op("chmod", "root/secret.txt", "000")
    s.op("chmod", "root/locked", "000")
    s.op("chmod", "root/readonly", "555")
    s.one(OPEN, oflags(MODE_READ), a="/secret.txt")
    s.probe("/secret.txt")
    s.probe("/locked/x.txt")
    s.one(DIRECTORY, a="/locked", b=512)
    s.one(OPEN, oflags(MODE_WRITE), a="/locked/new")
    s.one(OPEN, oflags(MODE_WRITE), a="/readonly/new")
    s.one(CREATE_DIRECTORY, a="/readonly/d")
    s.one(DELETE, a="/readonly/y.txt")
    s.one(RENAME, a="/readonly/y.txt", b="/y.txt")
    h = s.open_write("/secret.txt")
    s.one(WRITE, handle=h, a="new secret", off=0)
    s.close(h, flags=2, date=T0 + 7)
    s.one(OPEN, oflags(MODE_WRITE, APPEND), a="/secret.txt")
    s.op("chmod", "root/secret.txt", "644")
    s.op("chmod", "root/locked", "755")
    s.op("chmod", "root/readonly", "755")
    s.one(DIRECTORY, a="/", b=512)
    return s


ALL = [basic, directory, complete, ops, names, mounts_override, mounts_named_only, mounts_none,
       mounts_bad, handles, rings, buffers, logs, symlinks, perms]
