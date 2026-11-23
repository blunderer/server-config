# shellcheck shell=bash disable=SC2015 # `test && ok || warn` reporting is intended
# box hostname subcommand (sourced by box).

cmd_hostname() {
	need_root
	need_env
	local name fqdn
	name=$(gen_hostname)
	fqdn=$name.$(get domain blunderer.org)
	say "hostname: $name ($fqdn), /etc/hosts from the inventory"
	if [[ $(hostname) != "$name" || $(cat /etc/hostname 2>/dev/null) != "$name" ]]; then
		if command -v hostnamectl >/dev/null && hostnamectl set-hostname "$name" 2>/dev/null; then
			:
		else
			echo "$name" >/etc/hostname
			hostname "$name"
		fi
		echo "  hostname set to $name (new logins show it; running shells keep the old prompt)"
	fi
	gen_hosts | install_text /etc/hosts || true
	[[ $(hostname -f 2>/dev/null) == "$fqdn" ]] && ok "hostname -f: $fqdn" ||
		warn "hostname -f gives $(hostname -f 2>/dev/null), expected $fqdn"
	# Cloud images rewrite both at every boot unless told not to.
	if [[ -d /etc/cloud ]]; then
		gen_cloud_cfg | install_text /etc/cloud/cloud.cfg.d/99-srv.cfg || true
	fi
}
