# shellcheck shell=bash
# box logout subcommand (sourced by box).

# Clear cached sudo credentials and remove all keys from the current ssh-agent
# (the `box` shell wrapper in host/shell/bashrc also kills the session-scoped
# ssh-agent it started).
cmd_logout() {
	if command -v sudo >/dev/null 2>&1; then
		sudo -k 2>/dev/null || true
	fi
	if [[ -n ${SSH_AUTH_SOCK:-} ]]; then
		ssh-add -D >/dev/null 2>&1 || true
		ok "cleared sudo cache and removed keys from ssh-agent"
	else
		ok "cleared sudo cache"
	fi
}
