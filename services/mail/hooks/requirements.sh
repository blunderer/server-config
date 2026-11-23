# shellcheck shell=bash
# Private keys (relative to data_dir) named by OpenDKIM's KeyTable and
# OpenARC's KeyFile under CONFIG_DIR (default: ../config next to hooks/).
service_requirements() {
	local conf=${1:-}
	[[ -n $conf ]] || conf=$(cd "$(dirname "${BASH_SOURCE[0]}")/../config" && pwd)
	{
		awk '!/^[[:space:]]*(#|$)/ { split($2, a, ":"); if (a[3] ~ /^\/keys\//) print "keys/opendkim/" substr(a[3], 7) }' "$conf/opendkim/KeyTable"
		sed -n 's/^[[:space:]]*KeyFile[[:space:]]*\/keys\//keys\/opendkim\//p' "$conf/openarc/openarc.conf"
	} | sort -u
}
