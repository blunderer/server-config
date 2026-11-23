# shellcheck shell=bash
# box resolver subcommand (sourced by box).

cmd_resolver() {
	need_root
	need_env
	say "resolver: port 53 free for the dns service"
	local servers
	# Read the upstream servers while resolved still knows them.
	servers=$(host_resolvers)
	if ! resolv_managed || ! cmp -s /etc/resolv.conf <(gen_resolv_conf "$servers"); then
		[[ -e /etc/resolv.conf && ! -L /etc/resolv.conf ]] && cp -a /etc/resolv.conf /etc/resolv.conf.bak
		rm -f /etc/resolv.conf
		gen_resolv_conf "$servers" >/etc/resolv.conf
		chmod 644 /etc/resolv.conf
		ok "/etc/resolv.conf: $servers"
	else
		ok "/etc/resolv.conf: $servers (unchanged)"
	fi
	if resolved_installed; then
		if resolved_active || ! resolved_masked; then
			systemctl disable --now systemd-resolved 2>/dev/null || true
			systemctl mask systemd-resolved >/dev/null
			ok "systemd-resolved stopped, disabled and masked (it stays off after reboots)"
		else
			ok "systemd-resolved masked"
		fi
	else
		ok "systemd-resolved is not installed"
	fi
	rm -f "$RESOLVED_DROPIN"   # the former stub-only fix, no longer needed
	if getent hosts deb.debian.org >/dev/null; then
		ok "name resolution works"
	else
		fail "name resolution broken: set host_resolvers in $SRV_HOST_ENV, then box resolver"
	fi
	local users l
	users=$(port_53_users)
	if [[ -z $users ]]; then
		ok "port 53 free"
	else
		warn "port 53 still taken (stop that program, or the dns service cannot start):"
		while IFS= read -r l; do printf '         %s\n' "$l"; done <<<"$users"
	fi
}
