# shellcheck shell=bash disable=SC2015 # `test && ok || fail` reporting is intended
# box ipv6 subcommand (sourced by box).

cmd_ipv6() {
	need_root
	need_env
	say "ipv6: the inventory's address on this host"
	local addr gw intf
	addr=$(get "$(get host)_ip6" "")
	gw=$(get ip6_gw "")
	if [[ -z $addr ]]; then
		ok "no $(get host)_ip6 in the inventory: IPv4 only"
		[[ ! -e $IPV6_UNIT ]] || { systemctl disable --now srv-ipv6 >/dev/null 2>&1 || true; rm -f "$IPV6_UNIT"; systemctl daemon-reload; ok "removed $IPV6_UNIT"; }
		return 0
	fi
	if [[ -z $gw ]]; then
		ok "no ip6_gw in the host file: the address comes from the provider's network setup"
	else
		intf=$(ip6_intf)
		[[ -n $intf ]] && ip link show "$intf" >/dev/null 2>&1 ||
			die "no interface '${intf:-?}': set ip6_intf in $SRV_HOST_ENV (ip -br link)"
		if [[ $(sysctl -n "net.ipv6.conf.$intf.disable_ipv6" 2>/dev/null) == 1 ]]; then
			warn "IPv6 is disabled on $intf (sysctl net.ipv6.conf.$intf.disable_ipv6=1): find what sets it (/etc/sysctl.d)"
		fi
		if gen_ipv6_unit | install_text "$IPV6_UNIT"; then
			systemctl daemon-reload
		fi
		systemctl enable -q srv-ipv6
		systemctl restart srv-ipv6 || fail "srv-ipv6 failed: journalctl -u srv-ipv6"
	fi
	check_ipv6
}
