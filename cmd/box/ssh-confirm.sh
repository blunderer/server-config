# shellcheck shell=bash
# box ssh-confirm subcommand (sourced by box).

cmd_ssh_confirm() {
	need_root
	need_env
	local port
	port=$(get ssh_port 222)
	echo "Did 'ssh -p $port' work from another terminal? Port 22 will be closed."
	confirm "Close port 22?" || die "not confirmed"
	echo "$port" >"$SSH_CONFIRMED"
	run_cmd ssh
	run_cmd fail2ban
}
