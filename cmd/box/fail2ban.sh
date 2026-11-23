# shellcheck shell=bash
# box fail2ban subcommand (sourced by box).

cmd_fail2ban() {
	need_root
	need_env
	say "fail2ban: sshd, SMTP AUTH, repeat offenders"
	local changed=0
	install_file "$REPO/host/fail2ban/jail.local" /etc/fail2ban/jail.local && changed=1
	install_file "$REPO/host/fail2ban/filter.d/srv-postfix-sasl.conf" \
		/etc/fail2ban/filter.d/srv-postfix-sasl.conf && changed=1
	if [[ -e /etc/fail2ban/jail.d/srv-docker.local ]]; then
		rm -f /etc/fail2ban/jail.d/srv-docker.local
		ok "removed obsolete /etc/fail2ban/jail.d/srv-docker.local"
		changed=1
	fi
	write_fail2ban_ssh && changed=1
	# The inventory's hosts are never banned (and your trusted addresses kept).
	# shellcheck disable=SC2046 # list of addresses
	write_trusted $(trusted_ips)
	systemctl enable fail2ban >/dev/null 2>&1 || true
	if [[ $changed == 1 ]] || ! systemctl is-active -q fail2ban; then
		systemctl restart fail2ban
	fi
	sleep 2
	ok "jails: $(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p')"
}
