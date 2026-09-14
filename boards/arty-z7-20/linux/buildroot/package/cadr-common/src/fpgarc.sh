# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# ONE `fpgarc` FOR SEVERAL PROGRAMS: THE FILTER EVERY INIT SCRIPT READS IT
# THROUGH.
#
# The pack partition carries one file of flags for each of the two CADRs this
# board runs.  `fpgarc` configures the machine in the fabric and `muirrc` the
# machine inside muir, both in muir's own rc format, so somebody who has read
# one can read the other.
#
# muir is one program, so its file goes to it whole.  The fabric CADR is
# served by several programs --- the screen, the serial line, the network, the
# USB input and the boot button --- and each of them refuses a flag it does
# not know, which is muir's behaviour and is right: a flag that is quietly
# ignored is a setting somebody wrote down and did not get.  So the file
# cannot go to any of them whole.
#
# **THE ANSWER IS A FILTER AND NOT A LOOSENING.**  Each init script names the
# flags its own program owns and is handed those lines and no others.  Nothing
# here refuses anything, and a flag no list names goes to nobody.  The
# programs stay exactly as strict as they are, which is the property this is
# for.
#
# **A FLAG IN `fpgarc` THEREFORE NAMES ONE PROGRAM.**  That is a rule about
# the flags and not about this code: `--port` is taken by the screen and by
# the serial line both, so no list may claim it and no `fpgarc` line can say
# it.  What a program shares with another it takes on its own command line in
# its init script; what is its alone it can take from this file.
# docs/fpgarc.md has the lists and says which flags cannot be written here.
#
# THE FORMAT, which is muir's.  One flag a line.  The flag comes first, then a
# space, then the rest of the line as its argument, so an argument with a
# space in it needs no quoting.  A line that is blank or starts with `#` is a
# comment.  Carriage returns are stripped, because the partition is FAT32 and
# the point of putting the file there is that a laptop with a card reader can
# edit it --- and a carriage return reaching a program once cost this board
# its whole Chaosnet, with the init script printing OK.
#
# THE CONTRACT.
#
#   fpgarc_args FILE FLAG...
#       Prints the lines of FILE whose flag is one of FLAG..., as shell-quoted
#       words on one line, for `eval set --`.  A flag with an argument is two
#       words and a bare flag is one.  Order is the file's.  Prints nothing
#       and returns 1 when FILE does not exist, so a caller can tell "no file"
#       from "a file with nothing of mine in it"; returns 0 otherwise.
#
#   fpgarc_has FILE FLAG
#       True when FILE names FLAG.  For a bare flag like --no-auto-boot.
#
# HOW A CALLER USES IT.  The words are quoted, so they go back through `eval`
# and an argument with a space in it survives:
#
#	FPGARC_SH=/usr/share/cadr/fpgarc.sh
#	. "$FPGARC_SH"
#	set -- --port "$PORT"
#	eval "set -- \"\$@\" $(fpgarc_args "$RC" --window --bow)"
#
# The file's flags come after the script's own, so a card that names a flag
# the script also passes wins --- which is the way round somebody editing the
# card expects, and it is muir's own rule that a flag given later wins.
#
# **WHY ONE LINE AND NOT ONE WORD A LINE.**  A newline inside `set -- ...`
# ends the command, so an `eval` of several lines would run the second word as
# a program.  Everything is printed with a trailing space instead.

# One word, quoted so that `eval` gives it back unchanged.  A single quote
# inside it becomes '\'' , which is the only character that needs the care.
fpgarc_quote() {
	printf "'%s' " "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# The file, cleaned the way muir reads its own: carriage returns gone,
# comments and blank lines dropped, each line trimmed, and the gap between a
# flag and its argument reduced to one space so the two can be split apart
# with no word-splitting of the argument itself.
fpgarc_lines() {
	tr -d '\r' < "$1" | sed \
		-e '/^[[:space:]]*#/d' \
		-e 's/^[[:space:]]*//' \
		-e 's/[[:space:]]*$//' \
		-e '/^$/d' \
		-e 's/^\([^[:space:]][^[:space:]]*\)[[:space:]][[:space:]]*/\1 /'
}

fpgarc_args() {
	_fpgarc_file=$1
	shift
	[ -f "$_fpgarc_file" ] || return 1
	fpgarc_lines "$_fpgarc_file" | while IFS= read -r _fpgarc_line; do
		case "$_fpgarc_line" in
		*' '*)
			_fpgarc_flag=${_fpgarc_line%% *}
			_fpgarc_value=${_fpgarc_line#* }
			_fpgarc_valued=1
			;;
		*)
			_fpgarc_flag=$_fpgarc_line
			_fpgarc_value=
			_fpgarc_valued=0
			;;
		esac
		for _fpgarc_want in "$@"; do
			[ "$_fpgarc_flag" = "$_fpgarc_want" ] || continue
			fpgarc_quote "$_fpgarc_flag"
			[ "$_fpgarc_valued" = 1 ] && fpgarc_quote "$_fpgarc_value"
			break
		done
	done
	return 0
}

fpgarc_has() {
	[ -n "$(fpgarc_args "$1" "$2")" ]
}
