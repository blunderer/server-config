# shellcheck shell=bash
# srv podman subcommand (sourced by srv).

cmd_podman() {
	load_host
	pctl "$@"
}
