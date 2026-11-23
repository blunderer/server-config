# shellcheck shell=bash
# box alert subcommand (sourced by box).

cmd_alert() { # box alert SUBJECT < body
	need_env
	send_alert "${1:?usage: box alert <subject> < body}"
}
