# shellcheck shell=bash
# srv restart subcommand (sourced by srv).

cmd_restart() {
	need_root
	local svc=${1:?usage: srv restart <svc>}
	need_current "$svc"
	stop_release "$svc" "$CUR" || true
	start_release "$svc" "$CUR"
	wait_healthy "$svc" "$CUR" "${META[HEALTH_TIMEOUT]}" || warn "$svc is not healthy (srv logs $svc)"
}
