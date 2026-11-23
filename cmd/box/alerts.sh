# shellcheck shell=bash disable=SC2015 # `test && ok || warn` reporting is intended
# box alerts subcommand (sourced by box).

cmd_alerts() {
	need_root
	need_env
	say "email alerts (msmtp through the mail service)"
	if ! alerts_configured; then
		warn "alert_email is not set in $SRV_HOST_ENV: alerts disabled"
		return 0
	fi
	gen_msmtprc | install_text /etc/msmtprc 0600 || true
	gen_msmtp_aliases | install_text /etc/aliases.msmtp || true
	# `sendmail` for cron, fail2ban and anything else that mails root. Not the
	# msmtp-mta package: it also ships a daemon that would want port 25.
	if [[ ! -e /usr/sbin/sendmail || $(readlink -f /usr/sbin/sendmail) == */msmtp ]]; then
		ln -sfn /usr/bin/msmtp /usr/sbin/sendmail
	else
		warn "/usr/sbin/sendmail belongs to another package; alerts use msmtp directly"
	fi
	local pw
	pw="$(get data_dir /home/data)/keys/alerts/smtp_password"
	[[ -s $pw ]] && ok "password file $pw" ||
		warn "missing $pw: box alerts-account (on the leader)"
	ok "alerts go to $(get alert_email)"
	echo "  test with: box alert-test"
}
