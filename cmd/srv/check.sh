# shellcheck shell=bash
# srv check subcommand (sourced by srv).

cmd_check() {
	load_host
	local -a svcs=("$@") failed=()
	[[ ${#svcs[@]} -gt 0 ]] || mapfile -t svcs < <(all_services)
	local svc dir tmp valid
	tmp=$(mktemp -d)
	for svc in "${svcs[@]}"; do
		load_meta "$svc"
		dir="$tmp/$svc"
		valid=0
		if (render_service "$svc" "$dir" check) && [[ -d $dir/quadlet ]]; then
			validate_quadlets "$dir" && valid=1
		fi
		if ((valid)); then
			ok "$svc"
		else
			failed+=("$svc")
		fi
	done
	rm -rf "$tmp"
	[[ ${#failed[@]} -eq 0 ]] || die "failed: ${failed[*]}"
}
