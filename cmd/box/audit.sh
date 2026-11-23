# shellcheck shell=bash
# box audit subcommand (sourced by box).

cmd_audit() {
	need_root
	need_env
	local drift
	say "configuration drift (what to re-run)"
	drift=$(audit_drift)
	if [[ -n $drift ]]; then echo "$drift"; else ok "this host matches the repository"; fi

	local -a wanted=("${PKG_BASE[@]}" "${PKG_PODMAN[@]}")
	say "listening sockets (anything unexpected here is attack surface)"
	ss -Htulpn | awk '{printf "  %-4s %-28s %s\n", $1, $5, $7}' | sort -u
	say "enabled services"
	systemctl list-unit-files --type=service --state=enabled --no-legend | awk '{print "  " $1}'
	say "manually installed packages srv does not need (review; nothing is removed)"
	apt-mark showmanual | grep -vxF -f <(printf '%s\n' "${wanted[@]}") | sed 's/^/  /' || true
	say "accounts with a login shell"
	awk -F: '$7 !~ /(nologin|false|sync)$/ {print "  " $1 " (" $7 ")"}' /etc/passwd
	say "members of sudo group"
	{ getent group sudo 2>/dev/null || true; } | sed 's/^/  /'
}
