# shellcheck shell=bash
# box watch subcommand (sourced by box).

# box watch (cron, daily): alert when `check` fails, or when a reboot is
# needed (once per set of packages). Configuration drift is in the weekly
# report only: there is nearly always something to re-run, not worth a mail
# a day per host.
cmd_watch() {
	need_env
	local out state=/var/lib/srv-host
	mkdir -p "$state"
	out=$(mktemp)
	if ! run_cmd check >"$out" 2>&1; then
		{ echo "box check failed:"; echo; grep -E 'FAIL|warn|failure' "$out"; echo; echo "Full output:"; cat "$out"; } |
			send_alert "check failed"
	fi
	if [[ -f /var/run/reboot-required ]]; then
		local pkgs
		pkgs=$(sort -u /var/run/reboot-required.pkgs 2>/dev/null | xargs)
		if [[ $(cat "$state/reboot-alerted" 2>/dev/null) != "$pkgs" ]]; then
			echo "A reboot is required after upgrading: ${pkgs:-unknown packages}." | send_alert "reboot required"
			echo "$pkgs" >"$state/reboot-alerted"
		fi
	fi
	rm -f "$out"
}
