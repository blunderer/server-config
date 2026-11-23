# shellcheck shell=bash
# box data subcommand (sourced by box).

# box data push|pull [OPTION...] [HOST...] [-- RSYNC_OPTION...]: copy the data
# folder between hosts now (backup/data-sync.sh, which says what each does).
# The output is on the terminal and in the journal: srv-data-push or
# srv-data-pull (the nightly push from cron logs as srv-data-push too).
cmd_data() {
	need_root
	# pull --from is the first thing run on a new host: no host files yet.
	[[ " $* " == *" --from"[=\ ]* ]] || need_env
	local dir=${1:-} rc=0
	[[ $dir == push || $dir == pull ]] || die "usage: box data push|pull [--force] [--login] [-n] [--no-delete] [--exclude-dir DIR]... [HOST...] [-- RSYNC_OPTION...]
       box data pull --from [USER@]ADDRESS[:PORT] [--data-dir DIR]     (a new host's first copy)"
	shift
	say "data $dir"
	# On a terminal: a progress line (data-sync.sh writes it to the terminal,
	# not through the log pipe below).
	local interactive=no
	[[ -t 1 ]] && interactive=yes
	SRV_INTERACTIVE=$interactive SRV=$SRV "$REPO/backup/data-sync.sh" "$dir" "$@" 2>&1 |
		tee >(systemd-cat -t "srv-data-$dir" 2>/dev/null || cat >/dev/null) || rc=$?
	if [[ $rc == 0 ]]; then ok "data $dir done"; else fail "data $dir failed (exit $rc)"; fi
	return "$rc"
}
