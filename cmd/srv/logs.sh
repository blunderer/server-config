# shellcheck shell=bash
# srv logs subcommand (sourced by srv).

cmd_logs() {
	local svc=${1:?usage: srv logs <svc> [args]} dir ctr
	local -a ctrs=()
	shift
	need_current "$svc"
	dir="$(svc_state "$svc")/$CUR"
	if [[ $# -ge 1 && $1 != -* ]] && ctr=$(resolve_podman_container "$svc" "$dir" "$1" 2>/dev/null); then
		shift
		[[ $# -gt 0 ]] || set -- -f --tail 100
		pctl logs "$@" "$ctr"
		return 0
	fi
	[[ $# -gt 0 ]] || set -- -f --tail 100
	if [[ -f "$dir/quadlet/srv-$svc.pod" ]]; then
		pctl pod logs "$@" "srv-$svc"
		return 0
	fi
	mapfile -t ctrs < <(podman_containers_of_dir "$dir")
	((${#ctrs[@]} > 0)) || die "no containers defined in $dir/quadlet"
	if ((${#ctrs[@]} == 1)); then
		pctl logs "$@" "${ctrs[0]}"
	else
		if [[ " $* " == *" -f "* || " $* " == *" --follow "* ]]; then
			die "$svc has multiple containers (${ctrs[*]}); specify one: srv logs $svc <container> [args]"
		fi
		for ctr in "${ctrs[@]}"; do
			info "$ctr"
			pctl logs "$@" "$ctr"
		done
	fi
}
