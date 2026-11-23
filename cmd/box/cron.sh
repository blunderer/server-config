# shellcheck shell=bash
# box cron subcommand (sourced by box).

cmd_cron() {
	need_root
	need_env
	say "cron jobs (/etc/cron.d/srv): output in the journal, alerts on failure"
	install -d -m 0700 -o 0 -g 0 "$(get backup_dir /home/backup)"
	gen_cron | install_text /etc/cron.d/srv || true
	systemctl enable --now cron >/dev/null 2>&1 || warn "could not enable cron"
	ok "$(grep -cE '^[0-9]' /etc/cron.d/srv) jobs"
}
