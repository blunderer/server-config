# shellcheck shell=bash
# srv deploy subcommand (sourced by srv).

cmd_deploy() {
	need_root
	local auto_commit=0
	while [[ ${1:-} == -* ]]; do
		case $1 in
			--commit) auto_commit=1 ;;
			-v | --verbose)
				# shellcheck disable=SC2034 # read by _podman_pretty in srv
				SRV_VERBOSE=1
				;;
			*) die "srv deploy: unknown option $1" ;;
		esac
		shift
	done
	local target=${1:?usage: srv deploy [-v] [--commit] <svc|all>}
	load_host
	if [[ $target == all ]]; then
		local s
		for s in $(enabled_services); do
			info "${C_BLD}$s${C_OFF}"
			if ! deploy_one "$s"; then
				warn "$s: deploy did not complete; stopping here (fix it, then: srv deploy all)"
				return 1
			fi
			((auto_commit)) && { load_cmd commit; commit_one "$s"; }
			[[ $SRV_YES == 1 ]] || confirm "Continue with the next service?" || return 0
		done
		return 0
	fi
	deploy_one "$target" || return 1
	((auto_commit)) && { load_cmd commit; commit_one "$target"; }
	return 0
}

deploy_one() {
	local svc=$1 rel dir cur old_prev img
	load_meta "$svc"
	[[ " ${HOST[services]} " == *" $svc "* ]] ||
		confirm "$svc is not in this host's services list; deploy anyway?" || return 1

	rel=$(date +%Y%m%d-%H%M%S)
	dir="$(svc_state "$svc")/$rel"
	cur=$(read_link "$svc" current)
	old_prev=$(read_link "$svc" previous)
	command -v crun >/dev/null 2>&1 || die "crun is not installed: run 'sudo box packages podman'"
	ensure_infra "$svc"

	info "rendering $svc release $rel"
	# Every step checks its status explicitly: `set -e` does not apply inside
	# a function called as `deploy_one ... || ...` (srv deploy all).
	render_service "$svc" "$dir" "$rel" || return 1
	validate_quadlets "$dir" || return 1

	export SRV_RELEASE_DIR=$dir SRV_RUNTIME=podman
	# prepare: create/check host files the containers mount, before they exist.
	run_hook "$svc" prepare "$dir" || { warn "prepare hook failed; nothing was switched"; return 1; }

	local v dst pu puid pgid su0 sg0 o_u o_g
	pu=$(podman_user)
	puid=$(id -u "$pu" 2>/dev/null || echo 1000)
	pgid=$(id -g "$pu" 2>/dev/null || echo 1000)
	su0=$(_subid_start /etc/subuid "$pu" "$puid")
	sg0=$(_subid_start /etc/subgid "$pu" "$puid")
	for v in $(service_volumes "$svc"); do
		dst="${HOST[volumes_dir]}/$v"
		[[ -d $dst ]] && continue
		mkdir -p "$dst"
		if ((EUID == 0)); then
			if is_keepid_native_volume "$v"; then
				o_u=$puid o_g=$pgid
			else
				o_u=$su0 o_g=$sg0
			fi
			chown "$o_u:$o_g" "$dst"
		fi
	done
	if has_podman && ((EUID == 0)) && [[ -x $SRV_ROOT/box ]]; then
		"$SRV_ROOT/box" keys sync --quiet >/dev/null || warn "could not sync Podman secrets"
	fi

	info "pulling and building images"
	podman_sync_images "$dir" "$rel" || { warn "pull/build failed; nothing was switched"; return 1; }
	while read -r img; do
		[[ -n $img ]] || continue
		pctl image inspect -f "$img {{.Id}}" "$img" 2>/dev/null || echo "$img"
	done < <(sed -n 's/^[[:space:]]*Image=//p' "$dir/quadlet"/*.container | sort -u) >>"$dir/release.info" || true

	if [[ -n $cur ]]; then
		if [[ -n $old_prev ]]; then
			warn "$svc was not committed: $old_prev stops being a rollback target and is removed after the switch"
		fi
		if ! confirm "Switch $svc: ${cur} -> ${rel}?"; then
			if [[ $SRV_YES != 1 ]] && confirm "Not switched. Remove release $rel (containers, images, folder)?"; then
				discard_release "$svc" "$rel"
			else
				warn "not switched; release $rel is rendered/built (remove it with: srv discard $svc)"
			fi
			return 1
		fi
	fi

	export SRV_NEW_PROJECT SRV_OLD_PROJECT
	SRV_NEW_PROJECT=$(project_name "$svc" "$rel")
	SRV_OLD_PROJECT=${cur:+$(project_name "$svc" "$cur")}
	run_hook "$svc" pre-switch "$dir" || {
		warn "pre-switch hook failed; nothing was switched ($rel was not started)"
		return 1
	}

	if [[ -n $cur ]]; then
		info "stopping $cur"
		stop_release "$svc" "$cur" || warn "stopping $cur reported an error"
	fi
	if ! migrate_volumes "$svc" "$cur"; then
		warn "volume migration failed; restarting $cur"
		[[ -n $cur ]] && start_release "$svc" "$cur"
		return 1
	fi
	info "starting $rel"
	if ! start_release "$svc" "$rel"; then
		warn "start failed"
	fi
	set_link "$svc" previous "$cur"
	set_link "$svc" current "$rel"
	if [[ -n $old_prev ]]; then drop_release "$svc" "$old_prev"; fi

	info "waiting for health (up to ${META[HEALTH_TIMEOUT]}s)"
	if wait_healthy "$svc" "$rel" "${META[HEALTH_TIMEOUT]}"; then
		run_hook "$svc" post-switch "$dir" || warn "post-switch hook failed"
		ok "$svc is now on $rel"
		if [[ -n $cur ]]; then
			echo "Check it works, then:  srv commit $svc   (or: srv rollback $svc)"
		fi
		return 0
	fi
	warn "$svc release $rel is not healthy. Logs: srv logs $svc"
	if [[ -n $cur ]] && confirm "Roll back to $cur now?"; then
		load_cmd rollback
		cmd_rollback "$svc"
	fi
	return 1
}
