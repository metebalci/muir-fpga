# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# THE BOARD'S CLOCK, WHICH NOTHING ON THE BOARD KEEPS.
#
# None of these boards has a real-time clock.  `date` straight after a boot
# reads the epoch, /sys/class/rtc is empty, there is no /dev/rtc and the kernel
# names no such device, so a board that boots from its card alone does not know
# the date or the time.  Everything it then writes is stamped 1970, and the
# machine, the programs and the band all disagree with the world.
#
# Two lines on the card tell it, read by the disk pack program's init script
# before anything else starts:
#
#     --date 20260920      a four-digit year, a two-digit month, a two-digit
#                          day
#     --time 1438          the hour on a 24-hour clock, then the minute, then
#                          the second if it is given; 143800 is the same
#                          instant
#
# **A FLAG NAMES EXACTLY WHAT IT SETS, AND THE BOARD GUESSES NOTHING ELSE.**
# `--date` alone sets the date and leaves the time of day exactly as it stands;
# `--time` alone sets the time of day and leaves the date exactly as it stands.
# A lone `--time` is NOT that time today: this board has no today, and a date it
# invented would mean nothing.  The clock is UTC, as the board's is.
#
# **AND THE CLOCK IS SAVED AT A CLEAN SHUTDOWN AND RESTORED AT THE NEXT BOOT,
# which is what gives the board a date to leave alone.**  The restore happens
# first and the card's lines are set on top of it.  There is no comparison
# between the two and no rule about which is later: a value written on the card
# is one somebody asked for, and dropping it because a saved value happened to
# be later would be a setting written down and not got, which is the failure
# this whole file of flags exists to prevent.
#
# **WHY THIS IS A FILE OF ITS OWN, beside the reader and the daemon starter.**
# The step in the init script is a dozen lines of boot; what is under it is
# arithmetic --- which eight digits are a day that exists, which six are a time
# of day, which field of an instant a flag replaces --- and that is the part a
# check has to aim at directly, with the wrong inputs beside the right ones.
# `--date 20260931` is eight digits and looks exactly like a date, and a step
# that took it would hand the kernel the 31st of September, which it would
# quietly make the 1st of October: a setting somebody wrote on the card and did
# not get, which is the failure the card's whole file of flags exists to
# prevent.
#
# THE CONTRACT.  An INSTANT here is fourteen digits, YYYYMMDDhhmmss, UTC.
#
#   cadr_clock_now
#       Print the board's clock as an instant.
#
#   cadr_clock_date_ok DATE
#       True when DATE is eight digits naming a day that exists: a four-digit
#       year, a month 01 to 12, and a day the month really has, leap years
#       included.
#
#   cadr_clock_time_ok TIME
#       True when TIME is four or six digits naming a time of day: an hour 00
#       to 23, a minute 00 to 59, and a second 00 to 59 when it is there.
#
#   cadr_clock_stamp_ok INSTANT
#       True when INSTANT is fourteen digits whose first eight are a date and
#       whose last six are a time.
#
#   cadr_clock_with_date INSTANT DATE
#       Print INSTANT with its date replaced by DATE.
#
#   cadr_clock_with_time INSTANT TIME
#       Print INSTANT with its time replaced by TIME, seconds 00 when TIME is
#       four digits.
#
#   cadr_clock_human INSTANT
#       Print INSTANT as `YYYY-MM-DD hh:mm:ss`, which is what a person reads
#       and what `date` is given.
#
#   cadr_clock_saved FILE
#       Print what FILE holds, cleaned as the card's own reader cleans a line:
#       a carriage return off, and a space at either end off.  Prints nothing
#       when there is no file, and what it prints is not known to be an
#       instant until cadr_clock_stamp_ok says so.
#
#   cadr_clock_set INSTANT
#       Set the board's clock to INSTANT, UTC.  True when `date` took it.
#
# **THERE IS NO COMPARISON BETWEEN TWO INSTANTS HERE, and that is deliberate.**
# One stood here while the card's lines were a floor that a later saved clock
# could overrule.  They are not a floor now, so nothing compares them, and the
# function went with the rule rather than being left where a check could still
# aim at it: a function nobody calls looks exactly like one that holds
# something.

# The board's clock, UTC, as fourteen digits.
cadr_clock_now() {
	date -u +%Y%m%d%H%M%S
}

# Eight digits, and a day the month really has.
cadr_clock_date_ok() {
	case "$1" in
	????????) ;;
	*) return 1 ;;
	esac
	case "$1" in
	*[!0-9]*) return 1 ;;
	esac
	_cadr_clock_y=${1%????}
	_cadr_clock_md=${1#????}
	_cadr_clock_m=${_cadr_clock_md%??}
	_cadr_clock_d=${_cadr_clock_md#??}
	case "$_cadr_clock_m" in
	01|03|05|07|08|10|12) _cadr_clock_last=31 ;;
	04|06|09|11) _cadr_clock_last=30 ;;
	02)
		# The leap year, in full: every fourth year, except every
		# hundredth, except every four hundredth.  1900 is not one and
		# 2000 is, which is the pair a rule that stops at the hundreds
		# gets wrong.
		#
		# The leading zeros come off first, because `$(( ))` reads a
		# number that begins with a zero as octal and 0008 is not an
		# octal number at all.
		_cadr_clock_yy=$_cadr_clock_y
		while :; do
			case "$_cadr_clock_yy" in
			0?*) _cadr_clock_yy=${_cadr_clock_yy#0} ;;
			*) break ;;
			esac
		done
		[ -n "$_cadr_clock_yy" ] || _cadr_clock_yy=0
		if [ $((_cadr_clock_yy % 4)) -ne 0 ]; then
			_cadr_clock_last=28
		elif [ $((_cadr_clock_yy % 100)) -ne 0 ]; then
			_cadr_clock_last=29
		elif [ $((_cadr_clock_yy % 400)) -ne 0 ]; then
			_cadr_clock_last=28
		else
			_cadr_clock_last=29
		fi
		;;
	*) return 1 ;;
	esac
	[ "$_cadr_clock_d" -ge 1 ] || return 1
	[ "$_cadr_clock_d" -le "$_cadr_clock_last" ]
}

# Four or six digits on a 24-hour clock.  There is no am and no pm, and no
# second of 60: a leap second is not an instant the board's clock takes.
#
# Every field is cut out by taking a fixed number of characters off one end or
# the other, which is the one way of cutting a string that every shell has and
# that costs no process on the boot path.
cadr_clock_time_ok() {
	case "$1" in
	*[!0-9]*) return 1 ;;
	????)
		_cadr_clock_h=${1%??}
		_cadr_clock_mi=${1#??}
		_cadr_clock_s=00
		;;
	??????)
		_cadr_clock_h=${1%????}
		_cadr_clock_mi=${1#??}
		_cadr_clock_mi=${_cadr_clock_mi%??}
		_cadr_clock_s=${1#????}
		;;
	*) return 1 ;;
	esac
	[ "$_cadr_clock_h" -le 23 ] || return 1
	[ "$_cadr_clock_mi" -le 59 ] || return 1
	[ "$_cadr_clock_s" -le 59 ]
}

cadr_clock_stamp_ok() {
	case "$1" in
	??????????????) ;;
	*) return 1 ;;
	esac
	cadr_clock_date_ok "${1%??????}" || return 1
	cadr_clock_time_ok "${1#????????}"
}

cadr_clock_with_date() {
	printf '%s%s' "$2" "${1#????????}"
}

cadr_clock_with_time() {
	case "$2" in
	????) printf '%s%s00' "${1%??????}" "$2" ;;
	*) printf '%s%s' "${1%??????}" "$2" ;;
	esac
}

cadr_clock_human() {
	_cadr_clock_mo=${1#????}
	_cadr_clock_mo=${_cadr_clock_mo%????????}
	_cadr_clock_da=${1#??????}
	_cadr_clock_da=${_cadr_clock_da%??????}
	_cadr_clock_ho=${1#????????}
	_cadr_clock_ho=${_cadr_clock_ho%????}
	_cadr_clock_mn=${1#??????????}
	_cadr_clock_mn=${_cadr_clock_mn%??}
	printf '%s-%s-%s %s:%s:%s' \
		"${1%??????????}" "$_cadr_clock_mo" "$_cadr_clock_da" \
		"$_cadr_clock_ho" "$_cadr_clock_mn" "${1#????????????}"
}

# What one clean shutdown wrote, for the boot after it.  The line is cleaned
# exactly as the card's own reader cleans a flag's line and for the same reason:
# the partition is FAT32 and this file can be read and written on a laptop with
# a card reader, which leaves a carriage return and can leave a space at either
# end.  A space in the MIDDLE is left where it is, so that `2026 0920140000` is
# refused rather than quietly read as an instant.
cadr_clock_saved() {
	[ -f "$1" ] || return 0
	head -1 "$1" 2>/dev/null | tr -d '\r\n' |
		sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# **THE CLOCK IS SET ONCE, TO ONE INSTANT.**  Whatever the card and the saved
# clock between them came to is composed first and written here, so that `ps`,
# the boot log and a person reading either see one setting and not a sequence.
cadr_clock_set() {
	date -u -s "$(cadr_clock_human "$1")" > /dev/null 2>&1
}
