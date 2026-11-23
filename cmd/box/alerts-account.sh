# shellcheck shell=bash
# box alerts-account subcommand (sourced by box).

# box alerts-account: create the SMTP AUTH account alerts are sent with,
# in the mail service's user files, and store its password for msmtp. Run it
# on the host holding the master copy of the data folder.
cmd_alerts_account() {
	need_root
	need_env
	load_lib tools
	local user dir
	alerts_configured || die "alerts are not set up on this host: set alert_email (and alert_smtp_user) in $SRV_HOST_ENV"
	user=$(alerts_account)
	dir="$(get data_dir /home/data)/users/postfix"
	# The same as: box mail user add|passwd <alerts> --random.
	if ! grep -q "^$user:" "$dir/shadow" 2>/dev/null; then
		mail_user add "$user" --random
	elif [[ ! -s $(alerts_pw_file) ]]; then
		mail_user passwd "$user" --random
	else
		ok "account $user exists, password in $(alerts_pw_file)"
	fi
}
