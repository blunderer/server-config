# shellcheck shell=bash
# What srv's hooks, box and ssl/renew.sh create in the data folder gets
# the data folder's owner (normally blunderer), not root, who runs them.
# Sourced; call data_owner_init first.
#
# Paths that need another group are left alone by their callers: the TSIG
# keys' group (BIND's). Everything else, MariaDB's data directory included,
# belongs to the data folder's owner.

# data_owner_init DATA_DIR [OWNER]: DATA_OWNER = OWNER, else srv's data_owner
# (SRV_V_data_owner in hooks), else the owner of DATA_DIR, as uid:gid.
data_owner_init() {
	DATA_OWNER=${2:-${SRV_V_data_owner:-}}
	[[ -n $DATA_OWNER ]] || DATA_OWNER=$(stat -c %u:%g "$1" 2>/dev/null || true)
}

# own PATH...: give the paths to DATA_OWNER.
own() {
	[[ -n ${DATA_OWNER:-} && $# -gt 0 ]] || return 0
	chown "$DATA_OWNER" "$@"
}

# own_tree DIR...: the same, recursively.
own_tree() {
	[[ -n ${DATA_OWNER:-} && $# -gt 0 ]] || return 0
	chown -R "$DATA_OWNER" "$@"
}

# mkdir_own DIR: mkdir -p, giving DATA_OWNER every directory it creates (not
# the ones that already existed).
mkdir_own() {
	local d=$1
	local -a created=()
	while [[ ! -e $d ]]; do
		created=("$d" "${created[@]}")
		d=$(dirname "$d")
	done
	mkdir -p "$1"
	own "${created[@]}"
}
