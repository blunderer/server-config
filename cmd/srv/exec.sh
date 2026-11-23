# shellcheck shell=bash
# srv exec subcommand (sourced by srv).

cmd_exec() {
	local svc=${1:?usage: srv exec <svc> [container|--] <cmd...>} ctr='' dir
	shift
	[[ $# -gt 0 ]] || die "usage: srv exec <svc> [container|--] <cmd...>"
	need_current "$svc"
	dir="$(svc_state "$svc")/$CUR"
	if [[ $1 == -- ]]; then
		shift
		ctr=$(resolve_podman_container "$svc" "$dir" "") || die "no container in $svc/$CUR"
	else
		ctr=$1
		shift
		ctr=$(resolve_podman_container "$svc" "$dir" "$ctr") || die "no container '$ctr' in $svc/$CUR"
	fi
	[[ $# -gt 0 ]] || die "usage: srv exec <svc> [container|--] <cmd...>"
	if [[ -t 0 && -t 1 ]]; then
		pctl exec -it "$ctr" "$@"
	else
		pctl exec -i "$ctr" "$@"
	fi
}
