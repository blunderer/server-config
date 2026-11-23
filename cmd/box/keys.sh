# shellcheck shell=bash
# box keys subcommand (lazy-loads lib/keys.sh).
load_lib secrets
load_lib keys
declare -F cmd_keys >/dev/null
