#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Which packages a Buildroot rebuild forces, held against a board's defconfig.

    br_force_check.py <defconfig> <package dir> <forced>

`<forced>` is what the Makefile's `BR_FORCE_NAMES` printed for that defconfig
standing as the `.config`: its last line is the `-reconfigure` targets.  This
computes the list apart from the macro --- U-Boot when `BR2_TARGET_UBOOT=y`,
the kernel when `BR2_LINUX_KERNEL=y`, and each package of ours built from this
tree (`_SITE_METHOD = local`) whose own `config BR2_PACKAGE_...` is `y` --- and
the two must name the same set.  A target forced for something the board does
not select is the fault this exists for: the Kria KR260 selects no U-Boot, and
`uboot-reconfigure` has no rule there.
"""
import os
import re
import sys


def selected(defconfig):
    on = set()
    for line in open(defconfig):
        m = re.match(r'^(BR2_[A-Z0-9_]+)=y\s*$', line)
        if m:
            on.add(m.group(1))
    return on


def ours(pkgdir):
    """The packages built from this tree, and the symbol each selects by."""
    out = {}
    for name in sorted(os.listdir(pkgdir)):
        d = os.path.join(pkgdir, name)
        mk = os.path.join(d, name + '.mk')
        cfg = os.path.join(d, 'Config.in')
        if not os.path.isfile(mk) or '_SITE_METHOD = local' not in open(mk).read():
            continue
        m = re.search(r'^config (BR2_PACKAGE_[A-Z0-9_]+)\s*$', open(cfg).read(), re.M)
        if not m:
            sys.exit(f'br_force_check: {cfg} declares no BR2_PACKAGE_ symbol')
        out[name] = m.group(1)
    return out


def main():
    defconfig, pkgdir, forced = sys.argv[1:4]
    on = selected(defconfig)
    want = {n + '-reconfigure' for n, sym in ours(pkgdir).items() if sym in on}
    if 'BR2_TARGET_UBOOT' in on:
        want.add('uboot-reconfigure')
    if 'BR2_LINUX_KERNEL' in on:
        want.add('linux-reconfigure')
    lines = open(forced).read().splitlines()
    got = set(lines[-1].split()) if lines else set()
    board = os.path.basename(defconfig)
    if got != want:
        for t in sorted(got - want):
            print(f'br_force_check: {board}: the rebuild forces {t}, which this board does not select')
        for t in sorted(want - got):
            print(f'br_force_check: {board}: the rebuild does not force {t}, which this board selects')
        sys.exit(1)
    print(f'br_force_check: {board}: forces {len(got)} targets, each one the board selects'
          + ('' if 'uboot-reconfigure' in got else '; no U-Boot'))


if __name__ == '__main__':
    main()
