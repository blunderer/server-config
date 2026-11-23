# shellcheck shell=bash
# box ssh-trusted subcommand (sourced by box).

# box ssh-trusted [ADDR] | --list | --remove ADDR
cmd_ssh_trusted() {
	need_root
	local ip list
	case ${1:-} in
		--list)
			list=$(trusted_ips)
			[[ -n $list ]] && echo "$list" || echo "no trusted address"
			return 0
			;;
		--remove)
			ip=${2:?usage: box ssh-trusted --remove ADDR}
			list=$(trusted_ips | { grep -vxF "$ip" || true; } | xargs)
			# shellcheck disable=SC2086 # list of addresses
			write_trusted $list
			ok "$ip is no longer trusted"
			return 0
			;;
	esac
	ip=${1:-$(client_ip)}
	[[ -n $ip ]] || die "cannot tell your address (not an ssh session?): box ssh-trusted ADDR"
	valid_ip "$ip" || die "not an IP address or network: $ip"
	list=$(trusted_ips | { grep -vxF "$ip" || true; } | xargs)
	# shellcheck disable=SC2086 # list of addresses
	write_trusted $list "$ip"
	if systemctl is-active -q fail2ban 2>/dev/null; then
		fail2ban-client unban "$ip" >/dev/null 2>&1 || true
	fi
	ok "$ip is trusted: fail2ban never bans it (and any current ban is lifted)"
}
