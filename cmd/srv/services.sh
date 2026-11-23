# shellcheck shell=bash
# srv services subcommand (sourced by srv).

cmd_services() {
	local s
	load_host
	for s in $(enabled_services); do
		load_meta "$s"
		printf '%-10s %s\n' "$s" "${META[DESCRIPTION]:-}"
	done
}
