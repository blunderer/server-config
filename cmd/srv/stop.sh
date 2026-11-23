# shellcheck shell=bash
# srv stop subcommand (sourced by srv).

# srv stop <svc> / srv start <svc>: the current release, without a new
# release (e.g. on a host that should no longer serve the websites).
# Quadlets are removed from user systemd on stop so they stay stopped across reboots.
cmd_stop() {
	need_root
	local svc=${1:?usage: srv stop <svc>}
	need_current "$svc"
	stop_release "$svc" "$CUR"
}
