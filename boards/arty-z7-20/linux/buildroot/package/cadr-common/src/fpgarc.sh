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
#       True when FILE names FLAG, with an argument or without.  It is how a
#       bare flag like --no-auto-boot is read, and it is also how an init
#       script asks whether to pass its own default: see the note below.
#       False for a file that is not there.  It claims FLAG exactly as
#       fpgarc_args does, which is right --- a script only asks about a flag
#       it owns.
#
#   fpgarc_say_unclaimed FILE
#       Print one line naming the flags in FILE that no program on this board
#       claimed, or nothing at all.  For the LAST init script to read the
#       file, once every other one has had its turn.
#
# **WHY THE UNCLAIMED LINES ARE WORTH A LINE AT BOOT.**  Nothing here refuses
# anything, which is what lets one file serve several strict programs --- and
# it is also the one way a setting can still be lost.  A flag no list names is
# dropped in silence, so `--bwo` for `--bow` is a card that says something and
# a board that does nothing, with every program starting cleanly and nothing
# to read.  That is the same failure the programs' own strictness exists to
# prevent, one level up, and the answer is the same: say it where somebody is
# looking.
#
# **AND THE LISTS ARE NOT GATHERED IN ONE PLACE TO DO IT.**  A union written
# here would be a second copy of five lists and a second place to be wrong.
# Instead each script's claim is recorded as it reads the file, so what the
# last one compares against is what the scripts that actually ran asked for.
# A flag for a program that is not on this board is then reported too, which is
# true and worth knowing.

# WHERE THE CLAIMS ARE REMEMBERED ACROSS A BOOT, and what they are for: one
# line a flag, appended by every script as it reads the file, so that the last
# script to read it can name the lines no program claimed.  It is that list
# and nothing else; no program is ever started from it and nothing is refused
# because of it.  /var/run is a RAM disk unpacked at every boot, so this starts
# empty every time and cannot go stale.  A `restart` of one script only adds to
# it, and claims that only grow can only make the report quieter, never
# wronger.
#
# **AND IT MAY NOT BE THERE TO BE WRITTEN, WHICH MUST BE SILENT.**  /var/run
# belongs to the board, so a call from anywhere else --- a check on the build
# host, somebody at a prompt --- appends to a path it may not be allowed to
# create.  The environment names another for exactly that reason.  What is
# lost when the write cannot happen is the report and nothing else: with no
# claim recorded, `fpgarc_unclaimed` says nothing rather than naming every
# flag in the file, which is the same answer it gives on a boot where it ran
# first rather than last.
FPGARC_CLAIMED=${FPGARC_CLAIMED:-/var/run/cadr-fpgarc.claimed}
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
# **AND A SCRIPT PASSES ITS OWN DEFAULT ONLY WHERE THE CARD SAYS NOTHING.**
# Both flags standing on the command line works, because the program takes the
# last one.  It also puts `--terminal 0.0.0.0:5900 --terminal 0.0.0.0:5900` in
# a `ps` listing on a board somebody is trying to understand, which reads as a
# fault.  So a script asks first:
#
#	fpgarc_has "$RC" --terminal || set -- --terminal "$ENDPOINT"
#
# The card's line is then the only one, and a board with no card line runs
# exactly what it ran before.
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
	# What this caller claims, whether or not the file has any of it and
	# whether or not the file is there at all: a claim is about the
	# program's list and not about the card.
	#
	# **THE `2>/dev/null` COMES FIRST BECAUSE REDIRECTIONS ARE APPLIED IN
	# ORDER.**  Written the other way round the append is opened while
	# stderr is still the console, so a path this cannot create prints
	# `cannot create ...: Permission denied` from the shell itself and the
	# `2>/dev/null` that was meant to catch it never sees it.  Measured in
	# dash, bash and busybox ash alike, and it was seventeen lines in this
	# reader's own check.
	if [ -n "${FPGARC_CLAIMED:-}" ]; then
		for _fpgarc_claim in "$@"; do
			printf '%s\n' "$_fpgarc_claim"
		done 2>/dev/null >> "$FPGARC_CLAIMED" || :
	fi
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

# The flags in FILE that nobody claimed, one a line.  Nothing when the file is
# not there, and nothing when no claim has been recorded --- which is a boot
# where this ran first rather than last, and saying every flag went to nobody
# would be worse than saying nothing.
fpgarc_unclaimed() {
	[ -f "$1" ] || return 0
	[ -s "${FPGARC_CLAIMED:-}" ] || return 0
	fpgarc_lines "$1" | while IFS= read -r _fpgarc_line; do
		_fpgarc_flag=${_fpgarc_line%% *}
		grep -qx -- "$_fpgarc_flag" "$FPGARC_CLAIMED" ||
			printf '%s\n' "$_fpgarc_flag"
	done
}

fpgarc_say_unclaimed() {
	_fpgarc_none=$(fpgarc_unclaimed "$1" | sort -u | tr '\n' ' ')
	# The trailing space from `tr` is why this is not simply -n.
	case "$_fpgarc_none" in
	""|" ") return 0 ;;
	esac
	# The flags last, so that the sentence reads the same for one of them
	# as for six.
	echo "fpgarc: no program on this board takes these lines, so they did nothing" \
	     "(a misspelling, or a flag for a program that is not installed;" \
	     "docs/fpgarc.md has the lists): ${_fpgarc_none% }"
}
