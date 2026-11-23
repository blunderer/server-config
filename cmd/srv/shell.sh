# shellcheck shell=bash
# srv shell subcommand (sourced by srv).

cmd_shell() {
	local svc=${1:?usage: srv shell <svc> [container]} ctr=${2:-} dir
	need_current "$svc"
	dir="$(svc_state "$svc")/$CUR"
	ctr=$(resolve_podman_container "$svc" "$dir" "$ctr") || die "no container '${ctr:-}' in $svc/$CUR"
	pctl exec -it "$ctr" sh -c 'command -v bash >/dev/null && exec bash || exec sh'
}
