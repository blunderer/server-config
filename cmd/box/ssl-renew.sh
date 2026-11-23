# shellcheck shell=bash
# box ssl-renew subcommand (sourced by box).

# box run NAME CMD...: what cron runs. Output to the journal
# (journalctl -t srv-NAME); an alert with the output tail when CMD fails.
# box ssl-renew [-f]: the certificate renewal by hand, on the leader: what
# cron runs daily (box run ssl-renew ssl/renew.sh), with its output on the
# terminal as well as in the journal (srv-ssl-renew). -f renews even when
# not due (Let's Encrypt allows 5 identical certificates a week).
cmd_ssl_renew() {
	need_root
	need_env
	local rc=0
	"$REPO/ssl/renew.sh" "$@" 2>&1 | tee >(systemd-cat -t srv-ssl-renew 2>/dev/null || cat >/dev/null) || rc=${PIPESTATUS[0]}
	if ((rc == 0)); then
		ok "renewal done (box tls shows what each host serves)"
	else
		fail "renewal failed (exit $rc): the lines above, or journalctl -t srv-ssl-renew"
	fi
	return "$rc"
}
