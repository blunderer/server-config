# shellcheck shell=bash
# srv start subcommand (sourced by srv).

cmd_start() {
	need_root
	local svc=${1:?usage: srv start <svc>}
	need_current "$svc"
	start_release "$svc" "$CUR"
	wait_healthy "$svc" "$CUR" "${META[HEALTH_TIMEOUT]}" || warn "$svc is not healthy (srv logs $svc)"
}
