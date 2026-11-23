# shellcheck shell=bash
# box setup subcommand (sourced by box).

cmd_setup() {
	need_root
	run_cmd link ""   # first: may create the host env links need_env wants
	need_env
	run_cmd hostname
	run_cmd ipv6
	run_cmd resolver
	run_cmd packages
	run_cmd shell
	run_cmd man
	run_cmd podman
	run_cmd ssh-keys
	run_cmd ssh
	run_cmd fail2ban
	run_cmd alerts
	run_cmd cron
	echo
	run_cmd check || true
	echo
	echo "Next: srv deploy <service> (docs/transition.md for the order)"
}
