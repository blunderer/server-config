# shellcheck shell=bash
# box unlink subcommand (sourced by box).

# box unlink [DATA_DIR]: the reverse. Removes only links that point into this
# checkout (commands) or into the data folder's configs (host env).
cmd_unlink() {
	need_root
	local data name
	data=$(link_data_dir "${1:-}")
	say "commands in /usr/local/bin"
	for name in "${LINKS[@]}"; do
		unlink_if_into "/usr/local/bin/$name" "$REPO"
	done
	say "host env in /etc/srv"
	unlink_if_into /etc/srv/hosts.env "$data/configs"
	unlink_if_into "$SRV_HOST_ENV" "$data/configs"
	rmdir /etc/srv 2>/dev/null || true
}
