# shellcheck shell=bash
# box apply-role-change subcommand (sourced by box).

# Migrate the host's UID 1000 account to the configured unix_role, strip its
# sudo/SSH privileges when separated from admin_role, and ensure admin_role
# exists with sudo and SSH access.
cmd_apply_role_change() {
	need_root
	need_env
	local dry=0 arg
	for arg in "$@"; do
		case $arg in
			-n | --dry-run) dry=1 ;;
			*) die "usage: box apply-role-change [-n|--dry-run]" ;;
		esac
	done

	local new_u adm old_u old_g old_home new_home downer
	new_u=$(unix_role)
	adm=$(admin_role)
	[[ $new_u =~ ^[a-z_][a-z0-9_-]*$ && $new_u != root ]] ||
		die "invalid unix_role '$new_u'"
	[[ $adm =~ ^[a-z_][a-z0-9_-]*$ && $adm != root ]] ||
		die "invalid admin_role '$adm'"

	old_u=$(getent passwd 1000 | cut -d: -f1 || true)
	[[ -n $old_u ]] || die "no account with uid 1000 exists"
	old_g=$(getent group 1000 | cut -d: -f1 || true)
	old_home=$(getent passwd "$old_u" | cut -d: -f6)
	new_home="/home/$new_u"

	if [[ $old_u != "$new_u" ]]; then
		if id "$new_u" >/dev/null 2>&1; then
			die "account '$new_u' already exists (uid $(id -u "$new_u"), not 1000)"
		fi
		if [[ $old_home != "$new_home" && -e $new_home ]]; then
			die "target home directory $new_home already exists: move or remove it first"
		fi
		downer=$(get data_owner "")
		if [[ -n $downer && ($downer == "$old_u" || $downer == "$old_u":* || $downer == *:"$old_u") ]]; then
			die "data_owner=$downer in host env names '$old_u' (which will no longer be uid 1000): set data_owner=1000:1000 or unset it first"
		fi
		if [[ ${SUDO_USER:-} == "$old_u" ]]; then
			cat >&2 <<-EOF
			error: you are logged in as $old_u (uid 1000) and cannot rename your own active session.
			  Bootstrap options:
			    1. Use your provider's out-of-band console as root, OR
			    2. Create a temporary sudo user, add it to ssh_allow_users and run 'box ssh',
			       log in as that user, run 'sudo box apply-role-change', then remove the temp user.
			EOF
			return 1
		fi
	fi

	say "unix_role migration (uid 1000: $old_u -> $new_u; admin_role: $adm)"
	if [[ $old_u != "$new_u" ]]; then
		echo "  - stop enabled services and terminate uid 1000 sessions"
		echo "  - rename uid 1000: $old_u -> $new_u (home $old_home -> $new_home)"
		[[ $old_g == "$old_u" ]] && echo "  - rename gid 1000: $old_g -> $new_u"
		echo "  - update /etc/subuid, /etc/subgid and systemd linger"
	else
		ok "uid 1000 is already '$new_u'"
	fi
	if [[ $new_u != "$adm" ]]; then
		echo "  - lock password, set shell to /usr/sbin/nologin, remove sudo/wheel groups and ~/.ssh from $new_u"
		if id "$adm" >/dev/null 2>&1; then
			echo "  - ensure admin_role '$adm' is in sudo group"
		else
			echo "  - create admin_role '$adm' (in sudo group) and copy existing authorized_keys"
		fi
	fi
	echo "  - refresh podman (incl. secret protection), ssh-keys, ssh and shell configs"

	if ((dry)); then
		ok "dry-run: no changes made"
		return 0
	fi
	confirm "  Apply these account changes on $(get host)?" || die "stopped: nothing changed"

	# Preserve authorized_keys before renaming/cleaning UID 1000's home.
	local saved_auth=""
	if [[ -s $old_home/.ssh/authorized_keys ]]; then
		saved_auth=$(mktemp)
		chmod 0600 "$saved_auth"
		cp "$old_home/.ssh/authorized_keys" "$saved_auth"
	fi
	# shellcheck disable=SC2064 # expand $saved_auth now
	trap "rm -f '$saved_auth'" RETURN

	if [[ $old_u != "$new_u" ]]; then
		local svc
		for svc in $(get services ''); do
			"$SRV" stop "$svc" >/dev/null 2>&1 || true
		done
		loginctl terminate-user "$old_u" 2>/dev/null || true
		systemctl stop user@1000.service 2>/dev/null || true
		sleep 1
		local procs
		procs=$(ps -u 1000 -o pid=,comm= 2>/dev/null || true)
		if [[ -n $procs ]]; then
			echo "$procs" >&2
			die "processes still running as $old_u (uid 1000): stop them and retry"
		fi

		if [[ $old_g == "$old_u" ]] && ! getent group "$new_u" >/dev/null 2>&1; then
			groupmod -n "$new_u" "$old_u"
			ok "renamed group $old_u -> $new_u (gid 1000)"
		fi
		usermod -l "$new_u" "$old_u"
		ok "renamed user $old_u -> $new_u (uid 1000)"

		if [[ $old_home != "$new_home" ]]; then
			usermod -d "$new_home" -m "$new_u"
			ok "moved home $old_home -> $new_home"
		fi

		local f
		for f in /etc/subuid /etc/subgid; do
			if [[ -f $f ]] && grep -q "^${old_u}:" "$f"; then
				sed -i "s/^${old_u}:/${new_u}:/" "$f"
				ok "updated $f ($old_u -> $new_u)"
			fi
		done
		rm -f "/var/lib/systemd/linger/$old_u"
		loginctl enable-linger "$new_u"
		ok "enabled systemd linger for $new_u"
	fi

	new_home=$(getent passwd "$new_u" | cut -d: -f6)
	if [[ $new_u != "$adm" ]]; then
		passwd -l "$new_u" >/dev/null 2>&1 || true
		usermod -s /usr/sbin/nologin "$new_u"
		ok "set login shell of $new_u to /usr/sbin/nologin"
		local grp
		for grp in sudo wheel; do
			if id -nG "$new_u" | grep -qw "$grp"; then
				gpasswd -d "$new_u" "$grp" >/dev/null
				ok "removed $new_u from $grp group"
			fi
		done
		if sudo -l -U "$new_u" 2>/dev/null | grep -q 'may run the following commands'; then
			warn "$new_u still has sudoers privileges (check /etc/sudoers and /etc/sudoers.d/*)"
		fi
		if [[ -e $new_home/.ssh ]]; then
			rm -rf "$new_home/.ssh"
			ok "removed $new_home/.ssh"
		fi

		if ! id "$adm" >/dev/null 2>&1; then
			useradd -m -s /bin/bash -G sudo "$adm"
			ok "created admin_role '$adm' (in sudo group)"
			local adm_home
			adm_home=$(getent passwd "$adm" | cut -d: -f6)
			if [[ -n $saved_auth && -s $saved_auth ]]; then
				install -d -m 0700 -o "$adm" -g "$(id -gn "$adm")" "$adm_home/.ssh"
				install -m 0600 -o "$adm" -g "$(id -gn "$adm")" "$saved_auth" "$adm_home/.ssh/authorized_keys"
				ok "copied authorized_keys to $adm_home/.ssh/authorized_keys"
			fi
			warn "set a sudo password for $adm: passwd $adm"
		elif ! id -nG "$adm" | grep -qw sudo; then
			usermod -aG sudo "$adm"
			ok "added $adm to sudo group"
		else
			ok "admin_role '$adm' already exists with sudo"
		fi
	fi

	run_cmd podman
	run_cmd ssh-keys
	run_cmd ssh
	run_cmd shell

	cat <<-EOF

	  Done. Next steps:
	    1. Verify you can SSH in as $adm from another terminal before closing this session.
	    2. Review and clean any old personal files moved into $new_home.
	    3. Start services: for s in $(get services ''); do sudo srv start "\$s"; done
	    4. Verify host health: sudo box check
	EOF
}
