# Shared helpers for the db hooks (sourced, not executed).
# shellcheck shell=bash disable=SC2034

BACKUP_DIR="$SRV_DATA/backups/mariadb"
PASSWORD_FILE="$SRV_DATA/keys/mariadb/root_password"

# Files created here belong to the data folder's owner, not root. The path
# works from srv (SRV_ROOT) and when a hook is run by hand (dump-legacy).
# shellcheck source=lib/data-owner.sh
. "${SRV_ROOT:-$(dirname "${BASH_SOURCE[0]}")/../../..}/lib/data-owner.sh"
data_owner_init "$SRV_DATA"

# ensure_password: the official image needs a root password file; create a
# random one the first time (the legacy container keeps its own credentials).
ensure_password() {
	if [[ ! -s $PASSWORD_FILE ]]; then
		install -d -m 0700 -o 0 -g 0 "$(dirname "$PASSWORD_FILE")"
		(umask 077 && head -c 24 /dev/urandom | base64 >"$PASSWORD_FILE")
		chown 0:0 "$PASSWORD_FILE"
		chmod 0600 "$PASSWORD_FILE"
		echo "created $PASSWORD_FILE"
	fi
}

# shellcheck source=lib/runtime.sh
. "${SRV_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}/lib/runtime.sh"

# find_container -> running mariadb handle
find_container() {
	rt_find_container db mariadb srv-db
}

_db_run() {
	local mode=$1 exec_name=$2 cmds=$3 cid=$4
	shift 4
	local -a eopts=()
	[[ -z $mode ]] || eopts+=("$mode")
	# shellcheck disable=SC2016 # expanded inside the container
	if rt_exec -- "$cid" sh -c 'exec "$(command -v mariadb || command -v mysql)" -uroot -e "SELECT 1"' >/dev/null 2>&1; then
		rt_exec "${eopts[@]}" -- "$cid" sh -c "$cmds" "$exec_name" "$@"
	else
		(
			MYSQL_PWD=$(cat "$PASSWORD_FILE")
			export MYSQL_PWD
			rt_exec "${eopts[@]}" -- "$cid" sh -c "$cmds" "$exec_name" "$@"
		)
	fi
}

# sql CID ARGS...: run the mysql client in the container as root. Tries
# unix-socket auth first (legacy Debian container), then the password file.
sql() {
	# shellcheck disable=SC2016 # expanded inside the container
	_db_run -i sql 'exec "$(command -v mariadb || command -v mysql)" -uroot "$@"' "$@"
}

dump_tool() {
	# shellcheck disable=SC2016 # expanded inside the container
	_db_run "" dump 'exec "$(command -v mariadb-dump || command -v mysqldump)" -uroot "$@"' "$@"
}

# Clean up any partial dump or legacy read_only lock if a hook exits early.
_DB_CLEANUP_TMP=''
_DB_READONLY_CID=''
_db_cleanup() {
	[[ -z $_DB_CLEANUP_TMP ]] || rm -rf "$_DB_CLEANUP_TMP"
	if [[ -n $_DB_READONLY_CID ]]; then
		sql "$_DB_READONLY_CID" -e "SET GLOBAL read_only = OFF" >/dev/null 2>&1 || true
	fi
}
trap _db_cleanup EXIT

# dump CID OUTDIR: users and grants (10-users.sql, portable across MariaDB
# versions, unlike the mysql system schema) then the data (20-data.sql.gz),
# written to a temporary folder and renamed atomically into place.
dump() {
	local cid=$1 out=$2 tmp user
	local -a dbs=()
	tmp="$out.tmp.$$"
	_DB_CLEANUP_TMP=$tmp
	install -d -m 0700 -o 0 -g 0 "$SRV_DATA/backups" "$(dirname "$out")"
	(
		umask 077
		mkdir -p "$tmp"
		chmod 0700 "$tmp"
		{
			echo "-- users and grants exported by srv from $cid on $(date -Is)"
			sql "$cid" -N -B -e "SELECT CONCAT(QUOTE(user),'@',QUOTE(host)) FROM mysql.user
				WHERE user NOT IN ('', 'root', 'mysql', 'mariadb.sys', 'healthcheck')" |
				while read -r user; do
					sql "$cid" -N -B -e "SHOW CREATE USER $user" </dev/null | sed 's/^CREATE USER /CREATE USER IF NOT EXISTS /; s/$/;/'
					sql "$cid" -N -B -e "SHOW GRANTS FOR $user" </dev/null | sed 's/$/;/'
				done
		} >"$tmp/10-users.sql"
		# No database of our own is not an error (grep finds nothing): users and
		# grants are still dumped.
		mapfile -t dbs < <(sql "$cid" -N -B -e "SHOW DATABASES" |
			{ grep -vxE 'information_schema|performance_schema|mysql|sys' || true; })
		if ((${#dbs[@]} > 0)); then
			dump_tool "$cid" --single-transaction --routines --events --triggers --databases "${dbs[@]}" |
				gzip >"$tmp/20-data.sql.gz"
			gzip -t "$tmp/20-data.sql.gz"
		fi
		chmod 0600 "$tmp"/*
		chown -R 0:0 "$tmp"
		mv "$tmp" "$out"
		echo "dumped databases (${dbs[*]:-none}) to $out"
	)
	_DB_CLEANUP_TMP=''
}

prune() { # prune DIR KEEP: keep the newest KEEP completed entries
	local dir=$1 keep=$2
	find "$dir" -mindepth 1 -maxdepth 1 ! -name '*.tmp.*' -printf '%f\n' | sort -r | tail -n +"$((keep + 1))" |
		while read -r entry; do rm -rf "${dir:?}/$entry"; done
}
