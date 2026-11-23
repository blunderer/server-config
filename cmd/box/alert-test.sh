# shellcheck shell=bash
# box alert-test subcommand (sourced by box).

cmd_alert_test() {
	need_root
	need_env
	alerts_configured || die "set alert_email in $SRV_HOST_ENV, then: box alerts"
	echo "This is a test alert from box on $(get server_name)." | send_alert "test alert"
	echo "sent to $(get alert_email); delivery log: journalctl -t srv-alert"
}
