# shellcheck shell=bash
# srv networks subcommand (sourced by srv).

# cmd_networks: external container networks needed by this host's enabled services.
cmd_networks() {
	load_host
	local svc
	for svc in $(enabled_services); do
		load_meta "$svc"
		if [[ -n ${META[NETWORKS]:-} ]]; then
			# shellcheck disable=SC2086 # space-separated list
			printf '%s\n' ${META[NETWORKS]}
		fi
	done | sort -u
}
