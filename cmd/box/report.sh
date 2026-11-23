# shellcheck shell=bash
# box report subcommand (sourced by box).

# box report (cron, weekly): everything, whatever the state.
cmd_report() {
	need_env
	{
		echo "== srv status"; "$SRV" status 2>&1 || true
		echo; echo "== box check"; run_cmd check 2>&1 || true
		echo; echo "== configuration drift"; audit_drift 2>&1 || echo "  none"
		echo; echo "== disk"; df -h / "$(get data_dir /home/data)" 2>/dev/null
		echo; echo "== fail2ban"; fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list://p'
		local j
		for j in sshd srv-postfix-sasl recidive; do
			fail2ban-client status "$j" 2>/dev/null | grep -E 'Currently banned|Total banned' | sed "s/^/  $j: /"
		done
	} | send_alert "weekly report"
}
