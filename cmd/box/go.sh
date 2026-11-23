# shellcheck shell=bash
# box go subcommand (sourced by box).
# Prints the realpath of the repository; host/shell/bashrc wraps `box go` to cd there.

cmd_go() {
	printf '%s\n' "$REPO"
}
