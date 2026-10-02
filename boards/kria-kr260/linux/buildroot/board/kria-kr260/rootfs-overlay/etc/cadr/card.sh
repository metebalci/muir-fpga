# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# WHERE THE CARD IS ON THE KRIA KR260, read by S80cadr-disk-packs before it
# mounts the card.
#
# The board's microSD slot is not on an SD controller of the processing
# system: it is a USB mass-storage reader on the USB 2.0 hub of USB0, so the
# card is a SCSI disk, /dev/sdX, and which X depends on what else is plugged
# in and in what order.  **SO THE CARD IS FOUND BY ITS READER**, the carrier's
# own: the USB device 0424:2240, Microchip's USB2240 ("Ultra Fast Media",
# SCSI "Ultra HS-COMBO"), which every boot of this board has enumerated at
# port 1-1.1, behind the carrier's USB2734 hub at 1-1.  The disk whose USB
# ancestor is that reader is the card, whatever its volume label, and its
# first partition is what is mounted; a card formatted with no partition table
# is mounted whole.  The board's USB ports are for the keyboard and the mouse,
# and another USB disk plugged in is never taken for the card.
#
# **A SECOND READER OF THE SAME CHIP IS THE ONE THING THAT COULD BE MISTAKEN
# FOR IT**, so when there are two, the one at the carrier's own port, 1-1.1, is
# the card, and the console says there were two.
#
# The reader comes up a few seconds into the boot, after the carrier's hubs are
# released from reset and enumerate, so this waits for it, up to
# CADR_CARD_SECONDS, and says how long it took.
#
# A card of the old two-partition shape never existed on this board, so the
# second partition is named as nothing at all.
#
# `cadr_card_find` is the whole of the identification and reads only
# CADR_SYSFS, so a check can hand it a made-up /sys.

OLD_CARD_DEV=/dev/null/no-second-partition
CADR_SYSFS=${CADR_SYSFS:-/sys}
CADR_CARD_READER=0424:2240
CADR_CARD_PORT=1-1.1
CADR_CARD_SECONDS=${CADR_CARD_SECONDS:-20}

# The USB device a block device hangs from, as its sysfs directory: the
# nearest ancestor of the disk's own directory that has an idVendor.
cadr_card_usb_of() {
	_cadr_card_d=$(readlink -f "$1/device" 2>/dev/null) || return 1
	while [ -n "$_cadr_card_d" ] && [ "$_cadr_card_d" != / ]; do
		if [ -f "$_cadr_card_d/idVendor" ] && [ -f "$_cadr_card_d/idProduct" ]; then
			printf '%s' "$_cadr_card_d"
			return 0
		fi
		_cadr_card_d=${_cadr_card_d%/*}
	done
	return 1
}

# The card's device, /dev/sdXN or /dev/sdX, printed; nothing when no disk
# hangs from the reader.  A line for two readers goes to stderr.
cadr_card_find() {
	_cadr_card_found=
	_cadr_card_count=0
	for _cadr_card_b in "$CADR_SYSFS"/block/sd*; do
		[ -d "$_cadr_card_b" ] || continue
		_cadr_card_u=$(cadr_card_usb_of "$_cadr_card_b") || continue
		_cadr_card_id="$(cat "$_cadr_card_u/idVendor" 2>/dev/null):$(cat "$_cadr_card_u/idProduct" 2>/dev/null)"
		[ "$_cadr_card_id" = "$CADR_CARD_READER" ] || continue
		_cadr_card_count=$((_cadr_card_count + 1))
		_cadr_card_disk=${_cadr_card_b##*/}
		# The first partition, or the disk itself when it has none.
		_cadr_card_dev=/dev/$_cadr_card_disk
		for _cadr_card_p in "$_cadr_card_b/${_cadr_card_disk}1" "$_cadr_card_b/${_cadr_card_disk}p1"; do
			if [ -d "$_cadr_card_p" ]; then
				_cadr_card_dev=/dev/${_cadr_card_p##*/}
				break
			fi
		done
		if [ -z "$_cadr_card_found" ] || [ "${_cadr_card_u##*/}" = "$CADR_CARD_PORT" ]; then
			_cadr_card_found=$_cadr_card_dev
		fi
	done
	if [ "$_cadr_card_count" -gt 1 ]; then
		echo "cadr-disk-packs: $_cadr_card_count readers $CADR_CARD_READER are plugged in;" \
		     "the card is the one at port $CADR_CARD_PORT, $_cadr_card_found" >&2
	fi
	printf '%s' "$_cadr_card_found"
}

_cadr_card_i=0
CARD_DEV=
while :; do
	CARD_DEV=$(cadr_card_find)
	[ -n "$CARD_DEV" ] && break
	[ "$_cadr_card_i" -lt "$CADR_CARD_SECONDS" ] || break
	sleep 1
	_cadr_card_i=$((_cadr_card_i + 1))
done
if [ -n "$CARD_DEV" ]; then
	echo "cadr-disk-packs: the card is $CARD_DEV, in the board's own reader $CADR_CARD_READER (found after $_cadr_card_i s)"
else
	echo "cadr-disk-packs: no card in the board's own reader $CADR_CARD_READER after $CADR_CARD_SECONDS s"
	CARD_DEV=/dev/null/no-card-in-the-reader
fi
