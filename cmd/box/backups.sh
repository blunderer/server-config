# shellcheck shell=bash
# box backups subcommand (sourced by box).

cmd_backups() {
	local action=${1:-status}
	case $action in
		pause)
			need_root
			mkdir -p "$STATE_DIR"
			{ date -Is; echo "by ${SUDO_USER:-$(id -un)}: ${2:-}"; } >"$PAUSE_FLAG"
			ok "paused on $(hostname -s): $PAUSABLE_JOBS (resume: box backups resume)"
			;;
		resume)
			need_root
			rm -f "$PAUSE_FLAG"
			ok "resumed on $(hostname -s): $PAUSABLE_JOBS run at their next scheduled time"
			;;
		status)
			if backups_paused; then
				echo "paused since $(paused_since) on $(hostname -s): $PAUSABLE_JOBS ($(sed -n 2p "$PAUSE_FLAG"))"
			else
				echo "running on $(hostname -s): $PAUSABLE_JOBS"
			fi
			;;
		*) die "usage: box backups pause|resume|status" ;;
	esac
}
