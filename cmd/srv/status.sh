# shellcheck shell=bash
# srv status subcommand (sourced by srv).

cmd_status() {
	load_host
	local -a svcs=("$@")
	[[ ${#svcs[@]} -gt 0 ]] || mapfile -t svcs < <(enabled_services)
	((${#svcs[@]} > 0)) || return 0

	local svc cur prev c line
	local -A svc_cur=() svc_prev=() svc_ctrs=() ctr_state=() ctr_restarts=()
	local -a all_podman_ctrs=() all_podman_units=()

	# Pass 1: collect release links and Podman container names across all services
	# so we only spawn ONE podman inspect and ONE systemctl --user show.
	for svc in "${svcs[@]}"; do
		load_meta "$svc"
		cur=$(read_link "$svc" current)
		prev=$(read_link "$svc" previous)
		svc_cur[$svc]=$cur
		svc_prev[$svc]=$prev
		if [[ -n $cur ]]; then
			local clist=''
			for c in $(podman_containers_of_dir "$(svc_state "$svc")/$cur"); do
				clist+="$c "
				all_podman_ctrs+=("$c")
				all_podman_units+=("$c.service")
			done
			svc_ctrs[$svc]=${clist% }
		fi
	done

	if ((${#all_podman_ctrs[@]} > 0)) && has_podman; then
		local cname cstatus chealth
		while read -r cname cstatus chealth; do
			[[ -n $cname ]] || continue
			if [[ -n $chealth && $chealth != none ]]; then
				ctr_state[$cname]="$cstatus/$chealth"
			else
				ctr_state[$cname]=$cstatus
			fi
		done < <(pctl inspect --format '{{.Name}} {{.State.Status}} {{if and .State.Health .State.Health.Status}}{{.State.Health.Status}}{{else}}none{{end}}' "${all_podman_ctrs[@]}" 2>/dev/null || true)

		local key val cur_unit=''
		while IFS='=' read -r key val; do
			case $key in
				Id) cur_unit=${val%.service} ;;
				NRestarts) [[ -n $cur_unit ]] && ctr_restarts[$cur_unit]=$val ;;
			esac
		done < <(uctl show -p Id -p NRestarts "${all_podman_units[@]}" 2>/dev/null || true)
	fi

	printf '%s%-10s %-17s %-17s %s%s\n' "$C_BLD" SERVICE CURRENT PREVIOUS CONTAINERS "$C_OFF"
	for svc in "${svcs[@]}"; do
		load_meta "$svc"
		cur=${svc_cur[$svc]:-}
		prev=${svc_prev[$svc]:-}
		line=''
		if [[ -n $cur ]]; then
			local st nrestarts
			for c in ${svc_ctrs[$svc]:-}; do
				st="${c}:${ctr_state[$c]:-stopped}"
				nrestarts=${ctr_restarts[$c]:-0}
				if [[ $nrestarts =~ ^[1-9][0-9]*$ ]]; then
					st+="(restarts=$nrestarts)"
				fi
				line+="$st "
			done
		fi
		printf '%-10s %-17s %-17s %s\n' "$svc" "${cur:--}" "${prev:--}" "${line:--}"
	done
}
