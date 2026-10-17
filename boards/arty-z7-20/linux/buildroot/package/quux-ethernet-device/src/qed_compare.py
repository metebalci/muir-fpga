#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# quux-ethernet-device against muir's own Ethernet device.
#
#     qed_compare.py --golden G --test T --vectors V --flags F --work W
#                    [--reference R] [--quiet]
#
# For every script in `qed_scenarios.py`: muir's device (G,
# `golden/src/quux_ethernet_device.rs`) runs it, this program (T, `qed_test`)
# runs it over a model of the fabric's page, and the two transcripts must be
# the same bytes: every trace line, every Ethernet frame sent, registers
# 240-257 and the digest of main memory, after each `run`.  Then muir's and
# this program's answers to the flags' questions (F, `qed_flags.txt`), the
# same way; then the checksum vectors (V, muir-sim's
# `tests/ethernet_vectors.txt` at the pinned muir) through T; then T's own
# unit checks.
#
# **AND THE SCRIPTS MUST STILL REACH WHAT THEY ARE FOR.**  Agreement over
# scripts that produce nothing is agreement about nothing, so muir's
# transcripts are searched for every reason its device gives a transmit's
# refusal and a received frame's drop, every counter moving past its width,
# both index faults and the configuration's refusal; each must be there.
#
# `--reference R` keeps muir's side in R and reuses it when it is there,
# which is what `mutate.py` does: muir's answers do not change with a mutant
# of this program.  The check itself always writes a fresh one.

import argparse
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qed_scenarios  # noqa: E402

# What muir's transcripts must show at least once.
REACHED = [
    "trace sent ",
    "refused: length ",
    "refused: its Ethernet frame at 24001, off a line",
    ", past main memory",
    "refused: type not IPv4 or ARP",
    "refused: TCP payload under 20 bytes",
    ", into entry ",
    "dropped: the device is disabled",
    "dropped: not this device's MAC address",
    "dropped: no buffer given",
    "buffer of 40 bytes is too short",
    "'s buffer at 10001, off a line",
    "'s buffer at 37770, past main memory",
    "dropped: longer than 1514 bytes",
    "dropped: frame under 14 bytes",
    "dropped: type not IPv4 or ARP",
    "dropped: IPv4 header checksum bad",
    "dropped: TCP checksum bad",
    "dropped: UDP checksum bad",
    "dropped: ICMP checksum bad",
    "dropped: IPv4 frame under 34 bytes",
    "dropped: IPv4 version not 4",
    "dropped: IPv4 IHL under 5",
    "dropped: IPv4 total length under the header's",
    "dropped: IPv4 total length past the frame",
    "dropped: UDP length not the payload's",
    "dropped: ICMP payload under 8 bytes",
]


def regs_reached(texts):
    """Status bits and counter values muir's transcripts must show."""
    seen = {"enabled": False, "refused": False, "fault": False, "waiting": False,
            "type-wrapped": False, "ipv4-wrapped": False, "rx-wrapped": False,
            "tx-wrapped": False, "interrupt-enable": False}
    for t in texts:
        for line in t.splitlines():
            if not line.startswith("regs "):
                continue
            w = [int(x, 16) for x in line.split()[1:]]
            control, status = w[0], w[1]
            seen["enabled"] |= bool(status & 1)
            seen["interrupt-enable"] |= bool(control & 0x100)
            seen["refused"] |= bool(status & 4)
            seen["fault"] |= bool(status & 8)
            seen["waiting"] |= bool(status & 0x100)
            # A counter past its width: 17 mod 16, 130 mod 128, 260 mod 256.
            seen["type-wrapped"] |= (status >> 4 & 0xF) == 1
            seen["ipv4-wrapped"] |= (status >> 9 & 0x7F) == 2
            seen["rx-wrapped"] |= (status >> 16 & 0xFF) == 4
            seen["tx-wrapped"] |= (status >> 24 & 0xFF) == 4
    return [k for k, v in seen.items() if not v]


def first_difference(a, b):
    al, bl = a.splitlines(), b.splitlines()
    for i, (x, y) in enumerate(zip(al, bl)):
        if x != y:
            return f"line {i + 1}: muir {x[:110]!r}, the program {y[:110]!r}"
    return f"muir has {len(al)} lines, the program {len(bl)}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--golden", required=True)
    ap.add_argument("--test", required=True)
    ap.add_argument("--vectors", required=True)
    ap.add_argument("--flags", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--reference")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    fails = []
    shutil.rmtree(args.work, ignore_errors=True)
    os.makedirs(args.work)
    ref = args.reference
    reuse = bool(ref) and os.path.exists(os.path.join(ref, ".whole"))
    if ref and not reuse:
        shutil.rmtree(ref, ignore_errors=True)
        os.makedirs(ref)
    muir_dir = ref if ref else args.work

    scripts = qed_scenarios.scenarios(args.vectors)
    texts = []
    for name, text in scripts:
        script = os.path.join(args.work, name + ".script")
        open(script, "w").write(text)
        theirs = os.path.join(muir_dir, name + ".muir")
        if not reuse:
            r = subprocess.run([args.golden, "--script", script, "--out", theirs],
                               capture_output=True, text=True)
            if r.returncode != 0:
                fails.append(f"{name}: muir's side failed: {r.stderr.strip()[-300:]}")
                continue
        ours = os.path.join(args.work, name + ".qed")
        r = subprocess.run([args.test, "--script", script, "--out", ours], capture_output=True,
                           text=True, timeout=120)
        bad = [l for l in r.stdout.splitlines() if l.startswith("FAIL")]
        if r.returncode != 0 or bad:
            fails.append(f"{name}: the program's side: {(bad or [r.stderr.strip()[-200:]])[0]}")
            continue
        a, b = open(theirs).read(), open(ours).read()
        texts.append(a)
        if a != b:
            fails.append(f"{name}: the transcripts differ, {first_difference(a, b)}")
        elif not args.quiet:
            print(f"  same      {name}: {len(a.splitlines())} lines")

    if not reuse:
        joined = "\n".join(texts)
        for want in REACHED:
            if want not in joined:
                fails.append(f"the scripts reach nothing muir says as {want!r}")
        for missed in regs_reached(texts):
            fails.append(f"the scripts never show {missed} in registers 240 and 241")

    theirs = os.path.join(muir_dir, "flags.muir")
    if not reuse:
        subprocess.run([args.golden, "--flags", args.flags, "--out", theirs], check=True)
    ours = os.path.join(args.work, "flags.qed")
    r = subprocess.run([args.test, "--flags", args.flags, "--out", ours], capture_output=True,
                       text=True)
    if r.returncode != 0:
        fails.append(f"the flags: the program's side failed: {r.stdout.strip()[-200:]}")
    elif open(theirs).read() != open(ours).read():
        fails.append(f"the flags differ, {first_difference(open(theirs).read(), open(ours).read())}")
    elif not args.quiet:
        print(f"  same      the flags: {len(open(ours).read().splitlines())} answers")

    r = subprocess.run([args.test, "--vectors", args.vectors], capture_output=True, text=True)
    if r.returncode != 0:
        fails.append("the checksum vectors: " + next(
            (l for l in r.stdout.splitlines() if l.startswith("FAIL")), r.stdout[-200:]))
    elif not args.quiet:
        print("  " + r.stdout.strip().splitlines()[-1])

    r = subprocess.run([args.test, "--unit"], capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        fails.append("the unit checks: " + next(
            (l for l in r.stdout.splitlines() if l.startswith("FAIL")), r.stdout[-200:]))
    elif not args.quiet:
        print("  " + r.stdout.strip().splitlines()[-1])

    if ref and not reuse and not fails:
        open(os.path.join(ref, ".whole"), "w").write("")
    for f in fails:
        print("FAIL: " + f)
    if not fails:
        print(f"quux-ethernet-device: {len(scripts)} scripts the same as muir's device, the flags "
              f"the same as muir's, the vectors and the unit checks pass")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
