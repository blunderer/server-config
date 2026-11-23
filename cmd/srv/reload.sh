# shellcheck shell=bash
# srv reload subcommand (sourced by srv).

cmd_reload() {
	need_root
	local svc entry dir ctr rc=0
	local -a entries=()
	load_host
	if has_podman && ((EUID == 0)) && [[ -x $SRV_ROOT/box ]]; then
		"$SRV_ROOT/box" keys sync --restart --quiet >/dev/null || warn "could not sync Podman secrets"
	fi
	for svc in "$@"; do
		load_meta "$svc"
		CUR=$(read_link "$svc" current)
		if [[ -z $CUR ]]; then
			warn "$svc: no srv release running, skipped"
			continue
		fi
		dir="$(svc_state "$svc")/$CUR"
		if [[ -z ${META[RELOAD]} ]]; then
			warn "$svc has no RELOAD in service.env; restarting"
			stop_release "$svc" "$CUR" || true
			start_release "$svc" "$CUR" || { warn "$svc: restart failed"; rc=1; }
			continue
		fi
		# RELOAD="container:command;container:command"
		IFS=';' read -ra entries <<<"${META[RELOAD]}"
		for entry in "${entries[@]}"; do
			ctr=$(resolve_podman_container "$svc" "$dir" "${entry%%:*}" 2>/dev/null || true)
			# shellcheck disable=SC2086
			if [[ -n $ctr ]] && pctl exec "$ctr" ${entry#*:}; then
				ok "$svc: reloaded ${entry%%:*}"
			else
				warn "$svc: reloading ${entry%%:*} failed"
				rc=1
			fi
		done
	done
	return "$rc"
}
