# shellcheck shell=bash
# box peer-health subcommand (lazy-loads lib/peer_health.sh).
load_lib peer_health
declare -F cmd_peer_health >/dev/null
