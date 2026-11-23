# shellcheck shell=bash
# box shell subcommand (sourced by box).

cmd_shell() {
	need_root
	need_env
	say "shell: the same ~/.bashrc and ~/.profile on every host (host/shell)"
	local u home f
	while read -r u home; do
		[[ -d $home ]] || { warn "$u: no home directory $home"; continue; }
		for f in "${SHELL_FILES[@]}"; do
			if install_file "$REPO/host/shell/$f" "$home/.$f"; then
				chown "$u:" "$home/.$f" "$home/.$f.bak" 2>/dev/null || chown "$u:" "$home/.$f"
			fi
		done
		check_shell_user "$u" "$home"
	done < <(shell_users)
	if [[ -d /etc/sudoers.d ]]; then
		local tmp_sudo
		tmp_sudo=$(mktemp)
		install -m 0440 -o 0 -g 0 "$REPO/host/sudo/srv-admin" "$tmp_sudo"
		if visudo -cf "$tmp_sudo" >/dev/null 2>&1; then
			if ! cmp -s "$tmp_sudo" /etc/sudoers.d/srv-admin 2>/dev/null; then
				install -m 0440 -o 0 -g 0 "$tmp_sudo" /etc/sudoers.d/srv-admin
				ok "installed /etc/sudoers.d/srv-admin (session-scoped sudo cache)"
			else
				chown 0:0 /etc/sudoers.d/srv-admin
				chmod 0440 /etc/sudoers.d/srv-admin
				ok "/etc/sudoers.d/srv-admin up to date"
			fi
		else
			warn "visudo rejected $REPO/host/sudo/srv-admin; skipped"
		fi
		rm -f "$tmp_sudo"
	fi
	if ! pkg_missing libpam-ssh-agent-auth && [[ -f /etc/pam.d/sudo ]]; then
		local pam_line="auth sufficient pam_ssh_agent_auth.so file=$SUDO_AUTH_KEYS"
		if ! grep -qE "^[[:space:]]*auth[[:space:]]+sufficient[[:space:]]+pam_ssh_agent_auth\.so[[:space:]]+file=$SUDO_AUTH_KEYS([[:space:]]|\$)" /etc/pam.d/sudo; then
			cp -a /etc/pam.d/sudo /etc/pam.d/sudo.bak
			sed -i "0,/^@include common-auth/s||$pam_line\n@include common-auth|" /etc/pam.d/sudo
			ok "enabled pam_ssh_agent_auth in /etc/pam.d/sudo"
		else
			ok "/etc/pam.d/sudo already has pam_ssh_agent_auth"
		fi
	fi
}
