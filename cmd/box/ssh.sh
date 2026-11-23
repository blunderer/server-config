# shellcheck shell=bash
# box ssh subcommand (sourced by box).

cmd_ssh() {
	need_root
	need_env
	local port ports allow pw u home has_key=0 changed=0 f
	port=$(get ssh_port 222)
	ports=$(ssh_ports)
	allow=$(get ssh_allow_users "$(default_ssh_allow_users)")
	pw=$(ssh_password_auth)
	if [[ $pw == yes ]]; then
		say "sshd: port(s) $ports, password login enabled (ssh_password_auth=yes), root forced-commands-only${allow:+, AllowUsers $allow}"
	else
		say "sshd: port(s) $ports, key login only, root forced-commands-only${allow:+, AllowUsers $allow}"
		# Refuse to disable PasswordAuthentication if no allowed account has a key.
		for u in ${allow:-$(awk -F: '$3 >= 1000 && $7 !~ /(nologin|false|sync)$/ {print $1}' /etc/passwd)}; do
			home=$(getent passwd "$u" | cut -d: -f6)
			if [[ -n $home ]] && grep -qE '^[[:space:]]*(ssh-|ecdsa-|sk-)' "$home/.ssh/authorized_keys" 2>/dev/null; then
				has_key=1
				break
			fi
		done
		if [[ $has_key == 0 && ${SRV_YES:-0} != 1 ]]; then
			die "no SSH public key in authorized_keys for ${allow:-any login user}: install a key (or run box ssh-keys, or set ssh_password_auth=yes) before disabling password login"
		fi
	fi

	# Debian may use socket activation, which ignores Port in sshd_config.
	if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
		systemctl disable --now ssh.socket
		systemctl enable ssh.service
	fi

	# Old hand-written sshd_config files lack the Include of the drop-in
	# directory: without it the drop-in (and the port) would be ignored.
	if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
		cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
		sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
	fi
	# Port is cumulative across files: remove it from the main file so only
	# the drop-in decides.
	if grep -qE '^[[:space:]]*Port[[:space:]]' /etc/ssh/sshd_config; then
		[[ -f /etc/ssh/sshd_config.bak ]] || cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
		sed -i -E 's/^([[:space:]]*Port[[:space:]].*)$/# \1   # moved to sshd_config.d\/srv.conf/' /etc/ssh/sshd_config
	fi
	# First match wins across sshd_config.d/*.conf: comment out
	# PasswordAuthentication in earlier drop-ins (e.g. 50-cloud-init.conf) so
	# srv.conf decides.
	for f in /etc/ssh/sshd_config.d/*.conf; do
		[[ -f $f && $f != /etc/ssh/sshd_config.d/srv.conf ]] || continue
		if grep -qiE '^[[:space:]]*PasswordAuthentication[[:space:]]' "$f"; then
			sed -i -E 's/^([[:space:]]*[Pp]assword[Aa]uthentication[[:space:]].*)$/# \1   # moved to srv.conf/' "$f"
			changed=1
		fi
	done

	gen_sshd_dropin | install_text /etc/ssh/sshd_config.d/srv.conf && changed=1

	if ! sshd -t; then
		[[ -f /etc/ssh/sshd_config.d/srv.conf.bak ]] && mv /etc/ssh/sshd_config.d/srv.conf.bak /etc/ssh/sshd_config.d/srv.conf
		die "sshd rejects the configuration; previous drop-in restored"
	fi
	if [[ $changed == 1 ]]; then
		systemctl restart ssh   # open sessions are not affected
	fi
	ok "sshd listening on: $(ss -Htln | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un | grep -xE "$(echo "$ports" | tr ' ' '|')" | xargs)"

	if [[ $ports == "22 $port" ]]; then
		cat <<-EOF
		  Port $port is open next to 22. From ANOTHER terminal, check that this works:
		    ssh -p $port $(logname 2>/dev/null || echo "<user>")@$(get server_name)
		  (and that your provider's firewall allows $port), then close port 22 with:
		    box ssh-confirm
		EOF
	fi
	if write_fail2ban_ssh && systemctl is-active -q fail2ban; then
		systemctl reload fail2ban
	fi
}
