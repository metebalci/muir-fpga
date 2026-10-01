# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# WHERE THE CARD IS ON THE KRIA KR260, read by S80cadr-disk-packs before it
# mounts the card.
#
# The board's microSD slot is not on an SD controller of the processing
# system: it is a USB mass-storage reader on the USB 2.0 hub of USB0, so the
# card is a SCSI disk, /dev/sdX1, and which X depends on what else is plugged
# in and in what order.  So the card is found by its FAT volume label, CADR,
# which every card of this project carries.  The reader comes up a few
# seconds into the boot, after the carrier's hubs are released from reset and
# enumerate, so this waits for it, up to 20 s, and says how long it took.
#
# A card of the old two-partition shape never existed on this board, so the
# second partition is named as nothing at all.

OLD_CARD_DEV=/dev/null/no-second-partition
cadr_card_label=CADR
_cadr_card_i=0
CARD_DEV=
while [ "$_cadr_card_i" -lt 20 ]; do
	CARD_DEV=$(blkid 2>/dev/null | sed -n "s/^\([^:]*\):.* LABEL=\"$cadr_card_label\".*/\1/p" | head -1)
	[ -n "$CARD_DEV" ] && break
	sleep 1
	_cadr_card_i=$((_cadr_card_i + 1))
done
if [ -n "$CARD_DEV" ]; then
	echo "cadr-disk-packs: the card labelled $cadr_card_label is $CARD_DEV (found after $_cadr_card_i s)"
else
	echo "cadr-disk-packs: no partition labelled $cadr_card_label after 20 s"
	CARD_DEV=/dev/null/no-card-labelled-$cadr_card_label
fi
