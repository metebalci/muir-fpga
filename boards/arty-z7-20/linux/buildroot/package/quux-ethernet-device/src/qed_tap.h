// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The tap, the device's host side on a board: `quux0`, which the init
// script makes and gives the address `--ip-gateway` names (the Ethernet
// contract, section 4).
//
// **IT IS OPENED `IFF_TAP | IFF_NO_PI`, NEVER `IFF_VNET_HDR`, AND
// `TUNSETOFFLOAD` IS NEVER CALLED** (section 4).  With no virtio-net header
// the kernel takes every Ethernet frame this program writes as complete, its
// checksums already filled in, and checks every one of them as it would a
// frame off a wire (linux:drivers/net/tun.c, tun_get_user, where only a
// virtio-net header can set CHECKSUM_PARTIAL); and it hands this program
// every frame segmented and summed, with no offload left for a device that
// has none.  So the board's Linux checks every checksum QUUX's device fills
// in, which is one of the witnesses of section 9.

#ifndef QED_TAP_H
#define QED_TAP_H

#include <stddef.h>

// The tap's name on every board.
#define QED_TAP_NAME "quux0"

// The flags the tap is opened with, and the ones it must never have.
#define QED_TAP_FLAGS 0x1002u      // IFF_TAP | IFF_NO_PI
#define QED_TAP_NEVER 0x4000u      // IFF_VNET_HDR

// `name` opened, non-blocking: the descriptor, or -1 with why in `why`.
int qed_tap_open(const char *name, char *why, size_t len);

#ifdef QED_TEST_HOOKS
// Every ioctl the opening makes, in place of the kernel's: the check
// records the requests and the flags.
extern int (*qed_hook_ioctl)(int fd, unsigned long request, void *arg);
extern int (*qed_hook_open)(const char *path, int flags);
#endif

#endif
