# shellcheck shell=bash
# srv uctl subcommand (sourced by srv).

cmd_uctl() {
	load_host
	uctl "$@"
}
