# shellcheck shell=bash
# box ssh-keys subcommand (sourced by box).

cmd_ssh_keys() {
	need_root
	need_env
	local dir self user home h key a ahome
	dir=$(ssh_dir) self=$(get host) user=$(admin_role)
	say "ssh keys between hosts ($dir/id_ecdsa_<host>)"
	data_owner_init "$(get data_dir /home/data)" "$(get data_owner "")"

	# Missing pairs: created on the leader, for every host of the inventory
	# (used exclusively for root-only forced-command rsync between servers).
	for h in $(get hosts); do
		key=$(host_key "$h")
		[[ -s $key ]] && continue
		if [[ $(get is_leader no) != yes ]]; then
			[[ $h == "$self" ]] && warn "no $key: box ssh-keys on the leader creates it, the next replication brings it"
			continue
		fi
		install -d -m 0700 -o 0 -g 0 "$dir"
		ssh-keygen -q -t ecdsa -b 521 -N '' -C "$h@$(get domain blunderer.org)" -f "$key"
		chown 0:0 "$key" "$key.pub"
		chmod 0600 "$key" "$key.pub"
		ok "created $key (the next replication copies it to $h)"
	done
	# A pair for each ssh client that has none (a machine of ours with box:
	# it installs its pair with box ssh-keys, like a host).
	if [[ $(get is_leader no) == yes ]]; then
		for h in $(get ssh_clients ""); do
			[[ -s $(client_key "$h") ]] && continue
			key=$(host_key "$h")
			install -d -m 0700 -o 0 -g 0 "$dir"
			ssh-keygen -q -t ecdsa -b 521 -N '' -C "$h@$(get domain blunderer.org)" -f "$key"
			chown 0:0 "$key" "$key.pub"
			chmod 0600 "$key" "$key.pub"
			ok "created $key for client $h (box data push; then box ssh-keys on every host, and on $h)"
		done
	fi
	key=$(host_key "$self")
	if [[ $(get in_inventory yes) == no && ! -s $key ]]; then
		warn "no $key: add $self to ssh_clients= in the inventory, box ssh-keys on the leader creates it"
	fi

	# This host's pair in ~/.ssh.
	if [[ -s $key ]]; then
		chmod 600 "$key"
		[[ -s $key.pub ]] || { ssh-keygen -y -f "$key" >"$key.pub"; chown 0:0 "$key.pub"; chmod 0600 "$key.pub"; }
		for a in $(key_accounts); do
			ahome=$(account_home "$a")
			install -d -m 700 -o "$a" -g "$(id -gn "$a")" "$ahome/.ssh"
			install -m 600 -o "$a" -g "$(id -gn "$a")" "$key" "$ahome/.ssh/id_ecdsa_$self"
			install -m 644 -o "$a" -g "$(id -gn "$a")" "$key.pub" "$ahome/.ssh/id_ecdsa_$self.pub"
			ok "$ahome/.ssh/id_ecdsa_$self"
		done
	fi

	# On inventory servers, server host keys are root-sync only: remove any
	# legacy copy from admin_role's ~/.ssh and authorize ONLY ssh_clients for admin_role.
	home=$(account_home "$user")
	if [[ $(get in_inventory yes) == no ]]; then
		:
	else
		if [[ -n $home && $user != root ]]; then
			rm -f "$home/.ssh/id_ecdsa_$self" "$home/.ssh/id_ecdsa_$self.pub"
		fi
		install -d -m 0755 -o 0 -g 0 /usr/local/libexec /etc/srv
		install -m 0755 -o 0 -g 0 "$REPO/host/ssh/srv-sync-endpoint" "$SRV_SYNC_ENDPOINT"
		gen_sync_endpoint_conf | install_text "$SRV_SYNC_CONF" 0600 || true
		chown 0:0 "$SRV_SYNC_CONF"
		install -d -m 700 -o 0 -g 0 /root/.ssh
		gen_root_authorized_keys | install_text /root/.ssh/authorized_keys 0600 || true
		chown 0:0 /root/.ssh/authorized_keys
		gen_sudo_authorized_keys | install_text "$SUDO_AUTH_KEYS" 0644 || true
		chown 0:0 "$SUDO_AUTH_KEYS"
		if [[ -z $home ]]; then
			warn "no account $user here: interactive admin logins cannot be authorized"
		else
			install -d -m 700 -o "$user" -g "$(id -gn "$user")" "$home/.ssh"
			gen_authorized_keys "$home/.ssh/authorized_keys" |
				install_text "$home/.ssh/authorized_keys" 0600 || true
			chown "$user:$(id -gn "$user")" "$home/.ssh/authorized_keys"
		fi
		for h in $(peers); do
			if [[ -s $(host_key "$h").pub ]]; then
				ok "$h authorized for root (forced-command rsync only)"
			else
				warn "no key for $h yet: box ssh-keys on the leader"
			fi
		done
		for h in $(get ssh_clients ""); do
			if [[ -s $(client_key "$h") ]]; then
				ok "client $h authorized for $user"
			else
				warn "client $h has no key: $(client_key "$h")"
			fi
		done
	fi
	local allow
	allow=$(get ssh_allow_users "$(default_ssh_allow_users)")
	[[ -z $allow || " $allow " == *" root "* ]] ||
		warn "ssh_allow_users ($allow) does not include root: peer data/cert sync is refused"
	[[ -z $allow || " $allow " == *" $user "* ]] ||
		warn "ssh_allow_users ($allow) does not include $user: admin logins are refused"

	gen_ssh_client | install_text /etc/ssh/ssh_config.d/srv.conf || true
	if [[ -s $key ]]; then
		ok "ssh client: $(peers | xargs) as $user, with id_ecdsa_$self (ssh <host>: port, address and user set)"
	else
		ok "ssh client: $(peers | xargs) as $user (ssh <host>: port, address and user set)"
	fi
}
