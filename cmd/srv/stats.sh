# shellcheck shell=bash
# srv stats subcommand (sourced by srv).

# srv stats [--no-stream] [svc...]: live CPU, memory, network, disk for the
# containers of the services' current releases (default: every enabled service).
cmd_stats() {
	load_host
	local -a svcs=() opts=() pids=()
	local a svc cur c fmt='table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}\t{{.PIDs}}'
	for a in "$@"; do
		case $a in
			--no-stream | -a | --all) opts+=("$a") ;;
			-*) die "usage: srv stats [--no-stream] [svc...]" ;;
			*) svcs+=("$a") ;;
		esac
	done
	[[ ${#svcs[@]} -gt 0 ]] || mapfile -t svcs < <(enabled_services)
	for svc in "${svcs[@]}"; do
		load_meta "$svc"
		cur=$(read_link "$svc" current)
		[[ -n $cur ]] || continue
		for c in $(podman_containers_of_dir "$(svc_state "$svc")/$cur"); do pids+=("$c"); done
	done
	((${#pids[@]})) || die "no containers running for: ${svcs[*]:-(no services on this host)}"
	pctl stats "${opts[@]}" --format "$fmt" "${pids[@]}"
}
