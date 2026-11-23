# shellcheck shell=bash
# srv requirements subcommand (sourced by srv).

# cmd_requirements: "service path" for every file or directory (trailing /)
# the enabled services expect on this host, from REQUIRES in service.env.
# Relative paths are under data_dir; @var@ placeholders are rendered.
cmd_requirements() {
	load_host
	local svc tmp p
	tmp=$(mktemp)
	for svc in $(enabled_services); do
		load_meta "$svc"
		# Its files cannot be named without them; srv check reports it.
		[[ -z $(missing_needs) ]] || continue
		if [[ -n ${META[REQUIRES]:-} ]]; then
			# shellcheck disable=SC2086 # space-separated list
			printf '%s\n' ${META[REQUIRES]} >"$tmp"
			render_file "$tmp"
			while read -r p; do
				[[ $p == /* ]] || p="${HOST[data_dir]}/$p"
				printf '%s %s\n' "$svc" "$p"
			done <"$tmp"
		fi
		if [[ -f $SRV_ROOT/services/$svc/hooks/requirements.sh ]]; then
			while read -r p; do
				[[ -n $p ]] || continue
				[[ $p == /* ]] || p="${HOST[data_dir]}/$p"
				printf '%s %s\n' "$svc" "$p"
			done < <(
				# shellcheck disable=SC1090
				. "$SRV_ROOT/services/$svc/hooks/requirements.sh"
				service_requirements
			)
		fi
	done
	rm -f "$tmp"
}
