# shellcheck shell=bash
# srv rollback subcommand (sourced by srv).

cmd_rollback() {
	need_root
	local svc=${1:?usage: srv rollback <svc>} cur prev
	load_host
	load_meta "$svc"
	cur=$(read_link "$svc" current)
	prev=$(read_link "$svc" previous)
	[[ -n $prev ]] || die "$svc has no previous release to roll back to"
	info "rolling back $svc: $cur -> $prev"
	[[ -n $cur ]] && stop_release "$svc" "$cur"
	start_release "$svc" "$prev"
	set_link "$svc" current "$prev"
	set_link "$svc" previous "$cur"
	wait_healthy "$svc" "$prev" "${META[HEALTH_TIMEOUT]}" || warn "$prev is not healthy either"
	ok "$svc is on $prev. 'srv commit $svc' removes $cur; 'srv rollback $svc' goes back to it."
}
