# shellcheck shell=bash
# srv hook subcommand (sourced by srv).

# hook_summary FILE: the first sentence of the comment under the shebang.
hook_summary() {
	awk 'NR == 1 && /^#!/ {next} /^#/ && !/shellcheck/ {sub(/^# ?/, ""); s = s " " $0; next} {exit}
		END {sub(/^ /, "", s); if (match(s, /\. |\.$/)) s = substr(s, 1, RSTART); print s}' "$1"
}

# hook list [svc|all]: the hooks of each service, when they run, and what
# they do (the comment at the top of each).
cmd_hook_list() {
	local target=${1:-all} svc f name when
	local -a svcs
	if [[ $target == all ]]; then
		load_host
		mapfile -t svcs < <(enabled_services)
	else
		[[ -d $SRV_ROOT/services/$target ]] || die "no service $target"
		svcs=("$target")
	fi
	for svc in "${svcs[@]}"; do
		local found=0
		for f in "$SRV_ROOT/services/$svc/hooks/"*; do
			[[ -f $f && -x $f ]] || continue
			((found++)) || echo "$svc"
			name=${f##*/}
			case $name in
				prepare) when="deploy, before the containers" ;;
				pre-switch) when="deploy, before the switch" ;;
				post-switch) when="deploy, after the switch" ;;
				*) when="srv hook $svc $name" ;;
			esac
			printf '  %-12s %s\n  %-12s %s\n' "$name" "$when" "" "$(hook_summary "$f" | fold -s -w 64 | sed 's/ *$//; 2,$s/^/               /')"
		done
		[[ $target == all ]] || ((found)) || echo "$svc: no hooks"
	done
}

cmd_hook() {
	[[ ${1:-} == list ]] && { shift; cmd_hook_list "$@"; return; }
	need_root
	local usage="usage: srv hook <svc> <name> [arg...] | srv hook list [svc|all]"
	local svc=${1:?$usage} hook=${2:?$usage} cur
	shift 2
	load_host
	load_meta "$svc"
	cur=$(read_link "$svc" current)
	# Hooks get the running release's runtime/project.
	export SRV_CURRENT_RUNTIME='' SRV_CURRENT_PROJECT=''
	if [[ -n $cur ]]; then
		SRV_CURRENT_RUNTIME=podman
		SRV_CURRENT_PROJECT=$(project_name "$svc" "$cur")
	fi
	[[ -x $SRV_ROOT/services/$svc/hooks/$hook ]] || die "no hook services/$svc/hooks/$hook"
	# Arguments after the hook's name are the hook's (srv hook agy sync DIR).
	run_hook "$svc" "$hook" "" "$@"
}
