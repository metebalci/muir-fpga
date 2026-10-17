// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The tap opened: `qed_tap.h` says how and why.

#include "qed_tap.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/if.h>
#include <linux/if_tun.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

_Static_assert(QED_TAP_FLAGS == (IFF_TAP | IFF_NO_PI), "the tap's flags are IFF_TAP | IFF_NO_PI");
_Static_assert(QED_TAP_NEVER == IFF_VNET_HDR, "the flag the tap never has is IFF_VNET_HDR");

#ifdef QED_TEST_HOOKS
int (*qed_hook_ioctl)(int fd, unsigned long request, void *arg);
int (*qed_hook_open)(const char *path, int flags);
#define IOCTL(fd, req, arg) (qed_hook_ioctl ? qed_hook_ioctl((fd), (req), (arg)) : ioctl((fd), (req), (arg)))
#define OPEN(path, flags) (qed_hook_open ? qed_hook_open((path), (flags)) : open((path), (flags)))
#else
#define IOCTL(fd, req, arg) ioctl((fd), (req), (arg))
#define OPEN(path, flags) open((path), (flags))
#endif

int qed_tap_open(const char *name, char *why, size_t len)
{
	const int fd = OPEN("/dev/net/tun", O_RDWR | O_NONBLOCK | O_CLOEXEC);
	if (fd < 0) {
		snprintf(why, len, "/dev/net/tun: %s%s", strerror(errno),
			 errno == ENOENT ? " (a kernel with no CONFIG_TUN)" : "");
		return -1;
	}
	struct ifreq ifr;
	memset(&ifr, 0, sizeof ifr);
	snprintf(ifr.ifr_name, sizeof ifr.ifr_name, "%s", name);
	ifr.ifr_flags = (short)QED_TAP_FLAGS;
	if (IOCTL(fd, TUNSETIFF, &ifr) < 0) {
		snprintf(why, len, "the tap %s: %s%s", name, strerror(errno),
			 errno == EBUSY ? ": another program holds it" : "");
		close(fd);
		return -1;
	}
	// What the kernel says the tap is now: a tap with no packet
	// information and no virtio-net header, whatever made it.
	memset(&ifr, 0, sizeof ifr);
	if (IOCTL(fd, TUNGETIFF, &ifr) < 0) {
		snprintf(why, len, "the tap %s: TUNGETIFF: %s", name, strerror(errno));
		close(fd);
		return -1;
	}
	const unsigned flags = (unsigned short)ifr.ifr_flags;
	if ((flags & QED_TAP_FLAGS) != QED_TAP_FLAGS || (flags & QED_TAP_NEVER)) {
		snprintf(why, len,
			 "the tap %s has the flags 0x%04x, where this program opens it IFF_TAP | IFF_NO_PI "
			 "and never IFF_VNET_HDR",
			 name, flags);
		close(fd);
		return -1;
	}
	return fd;
}
