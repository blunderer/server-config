# shellcheck shell=bash
# box run subcommand (sourced by box).

cmd_run() {
	local name=${1:?usage: box run <name> <command...>} out rc=0
	shift
	[[ ${1:-} == -- ]] && shift
	[[ $# -gt 0 ]] || die "usage: box run <name> <command...>"
	if backups_paused && [[ " $PAUSABLE_JOBS " == *" $name "* ]]; then
		echo "$name skipped: backups paused since $(paused_since) (box backups resume)" |
			systemd-cat -t "srv-$name" 2>/dev/null || true
		return 0
	fi
	out=$(mktemp)
	"$@" >"$out" 2>&1 || rc=$?
	systemd-cat -t "srv-$name" <"$out" 2>/dev/null || cat "$out"
	if [[ $rc != 0 ]]; then
		{
			echo "Job:     $name"
			echo "Command: $*"
			echo "Exit:    $rc"
			echo "Full log: journalctl -t srv-$name --since today"
			echo
			echo "Last 100 lines:"
			tail -n 100 "$out"
		} | send_alert "$name failed (exit $rc)"
	fi
	rm -f "$out"
	return "$rc"
}
