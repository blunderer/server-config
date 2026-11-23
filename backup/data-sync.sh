#!/usr/bin/env bash
# Copy the data folder between hosts (box data push|pull; cron pushes daily
# from the leader). The data folder lands at the same path on both sides.
#
# usage: data-sync.sh push [OPTION...] [HOST...] [-- RSYNC_OPTION...]
#        data-sync.sh pull [OPTION...] [HOST] [-- RSYNC_OPTION...]
#        data-sync.sh pull --from [USER@]ADDRESS[:PORT] [OPTION...]
#
# push: to every other host (remote_hosts), only from the leader, and only
#   to hosts whose inventory still names this host as the leader
#   (leader-guard.sh). --force pushes from any host and skips that check.
#   Named HOSTs (inventory names) limit the push to them.
# pull: from the leader, or from the named HOST. On the leader itself it
#   needs --force (it would overwrite the reference copy).
# pull --from: the first copy of the data folder on a new host, before
#   anything is set up (no inventory, no srv on the PATH, no key the others
#   trust): from any name or address of a host that has it, with your own
#   ssh login (as --login), as USER (default: the account that ran sudo), on
#   PORT (default: 22, else 222, whichever answers). It refuses a data folder
#   that already has files unless --force. Then: box link, box setup.
#
# OPTION:
#   --force              see above
#   -n, --dry-run        copy nothing, list what would change
#   --no-delete          keep files on the receiving side that the sender lacks
#   --exclude-dir DIR    leave DIR (relative to the data folder) alone, on both
#                        sides; repeatable
#   -v, --verbose        list every file copied or deleted
#   --data-dir DIR       with --from: the data folder (default /home/data), at
#                        the same path on both sides
#   --login              log in to the other hosts with your own ssh login (your
#                        key through agent forwarding, or a password asked on
#                        the terminal) instead of this host's key: for a host
#                        that does not trust it yet (a new or old-stack host).
#                        A host without an inventory also needs --force.
# RSYNC_OPTION, after "--": given to rsync as is (-v, --progress, --bwlimit=...).
set -euo pipefail

if command -v flock >/dev/null 2>&1; then
	_lock_dir=${SRV_LOCK_DIR:-/run/lock}
	mkdir -p "$_lock_dir" 2>/dev/null || _lock_dir=/tmp
	exec 9>"$_lock_dir/srv-data-sync.lock"
	flock -n 9 || { echo "data-sync.sh is already running" >&2; exit 1; }
fi

srv=${SRV:-srv}
# shellcheck source=backup/leader-guard.sh
. "$(dirname "$(readlink -f "$0")")/leader-guard.sh"

usage() {
	echo "usage: $0 push|pull [--force] [--login] [-n|--dry-run] [-v|--verbose] [--no-delete] [--exclude-dir DIR]... [HOST...] [-- RSYNC_OPTION...]" >&2
	echo "       $0 pull --from [USER@]ADDRESS[:PORT] [--data-dir DIR] [--force] [-n] [-v] [-- RSYNC_OPTION...]" >&2
	exit 2
}
dir=${1:-}
[[ $dir == push || $dir == pull ]] || usage
shift
force=no delete=yes dry=no login=no verbose=no from='' data_opt=''
excludes=() opts=() hosts=()
# exclude_dir DIR: DIR relative to the data folder, as an anchored rsync rule.
exclude_dir() {
	local d=${1#./}
	d=${d#/} d=${d%/}
	[[ -n $d && /$d/ != */../* ]] || { echo "--exclude-dir: '$1' is not a folder inside the data folder" >&2; exit 2; }
	excludes+=("--exclude=/$d/")
}
while (($#)); do
	case $1 in
		--force) force=yes ;;
		--login) login=yes ;;
		--from) (($# >= 2)) || usage; from=$2; shift ;;
		--from=*) from=${1#*=} ;;
		--data-dir) (($# >= 2)) || usage; data_opt=$2; shift ;;
		--data-dir=*) data_opt=${1#*=} ;;
		-n | --dry-run) dry=yes ;;
		-v | --verbose) verbose=yes ;;
		--no-delete) delete=no ;;
		--exclude-dir) (($# >= 2)) || usage; exclude_dir "$2"; shift ;;
		--exclude-dir=*) exclude_dir "${1#*=}" ;;
		--) shift; opts=("$@"); break ;;
		-*) echo "unknown option $1 (rsync options go after --)" >&2; usage ;;
		*) hosts+=("$1") ;;
	esac
	shift
done

if [[ -n $from ]]; then
	# A new host: nothing to ask srv, no inventory yet.
	[[ $dir == pull && ${#hosts[@]} -eq 0 ]] || { echo "--from goes with pull, without a host name" >&2; usage; }
	login=yes
	data=${data_opt:-/home/data}
	self='' leader=''
	backup_exclude="/transmission/ /wireguard/ /minecraft/ /jellyfin/"
else
	[[ -z $data_opt ]] || { echo "--data-dir goes with --from (elsewhere the host files say where the data folder is)" >&2; exit 2; }
	data=$("$srv" get data_dir /home/data)
	self=$("$srv" get host)
	leader=$("$srv" get leader)
	in_inventory=$("$srv" get in_inventory yes)
	if [[ $login == yes || $in_inventory == no ]]; then
		user=$("$srv" get admin_role)
		login=yes
	else
		user=root
	fi
	backup_exclude=$("$srv" get backup_exclude "/transmission/ /wireguard/ /minecraft/ /jellyfin/")
fi

# remote HOST: <user>@<address> of an inventory host (root for peer sync, admin_role with --login or off-inventory).
remote() {
	local ip
	ip=$("$srv" get "$1_ip" "")
	[[ -n $ip ]] || { echo "$1 is not a host of the inventory ($("$srv" get hosts))" >&2; exit 2; }
	[[ $1 != "$self" ]] || { echo "$1 is this host" >&2; exit 2; }
	echo "$user@$ip"
}

# Live database files are excluded: the dumps in backups/mariadb are copied.
# Per-host state (backup_exclude) must not overwrite the other side's copy.
# Each host's key for its own smtp.blunderer.org zone stays its own.
# Use -rlptgo (archive without -D devices/specials) to satisfy srv-sync-endpoint.
args=(-rlptgo
	--exclude=/mysql/ --exclude=/mariadb-v2/ --exclude='/mariadb-v2.stale-*/' --exclude=/mariadb-v2-init/
	--exclude=/keys/dns/smtp-tsig.key)
# Non-root SSH cannot chgrp files to other GIDs on the receiving host (rsync exit 23);
# on pull, the local rsync runs as root so group preservation works.
[[ -n ${from:-} || ${user:-} == root || $dir == pull ]] || args+=(--no-g)
# Off-inventory hosts (laptops) connect as admin_role and use agent forwarding +
# pam_ssh_agent_auth on the server to read root:root 0700 secrets.
# Use `SUDO_ASKPASS=/bin/false sudo -A` instead of `sudo -n`: `sudo -n` skips
# PAM completely (never invoking pam_ssh_agent_auth), while `-A` with /bin/false
# runs PAM and fails immediately without hanging if agent auth fails.
if [[ -z ${from:-} && ${in_inventory:-yes} == no && $dir == pull ]]; then
	args+=(--rsync-path="SUDO_ASKPASS=/bin/false sudo -A rsync")
fi
read -ra _excl <<<"$backup_exclude"
for e in "${_excl[@]}"; do args+=("--exclude=$e"); done
# Excluded folders are also left alone on the receiving side (no
# --delete-excluded), so --exclude-dir protects them there too.
[[ $delete == yes ]] && args+=(--delete)
[[ $dry == yes ]] && args+=(--dry-run --itemize-changes)
[[ $verbose == yes && $dry == no ]] && args+=(--itemize-changes)
args+=("${excludes[@]}" "${opts[@]}")

# On a terminal (box data, run by hand: SRV_INTERACTIVE), rsync shows one
# progress line for the whole copy (bytes, percentage, speed, time left),
# written to the terminal only, so the journal gets the summary, not the
# updates. The full file list first makes the percentage meaningful.
interactive=no
[[ ${SRV_INTERACTIVE:-} == yes && -w /dev/tty ]] && interactive=yes
if [[ $interactive == yes && $dry == no ]]; then
	args+=(--info=progress2 --human-readable --no-inc-recursive)
fi
run_rsync() {
	if [[ $interactive == yes && $dry == no ]]; then
		rsync "$@" >/dev/tty
	else
		rsync "$@"
	fi
}

# --login: your own ssh login. ssh may use your agent's keys and ask for a
# password on the terminal (/dev/tty, not stdin, so box's output pipeline
# does not get in the way). /etc/ssh/ssh_config.d/srv.conf (box ssh-keys)
# sets IdentitiesOnly for the known hosts, and replication otherwise sets
# BatchMode=yes: these options come first, as ssh keeps the first value.
LOGIN_SSH_OPTS="-o BatchMode=no -o IdentitiesOnly=no -o PasswordAuthentication=yes -o KbdInteractiveAuthentication=yes"
[[ -n ${SSH_AUTH_SOCK:-} ]] && LOGIN_SSH_OPTS="-A $LOGIN_SSH_OPTS"
login_check() { # login_check USER ADDRESS: say how ssh will log in
	if [[ -z ${SSH_AUTH_SOCK:-} ]]; then
		echo "no ssh agent: ssh asks for $1's password on $2 (or log in with ssh -A, and keep" >&2
		echo "the agent through sudo: sudo --preserve-env=SSH_AUTH_SOCK box data ...)" >&2
		[[ -r /dev/tty ]] || { echo "no terminal to ask a password on" >&2; exit 1; }
	fi
}
[[ $login == yes ]] || LOGIN_SSH_OPTS=''

# ssh_port USER@ADDRESS: the port to reach it on. The one ssh is set up for
# (/etc/ssh/ssh_config.d/srv.conf: <host>_ssh_port, else ssh_port), or 22
# when that one is closed and 22 answers: a host being set up still has
# sshd on the default port until box ssh.
port_open() {
	local host=$1 port=$2
	[[ $port =~ ^[0-9]+$ && $host =~ ^[A-Za-z0-9.:_-]+$ ]] || return 1
	# shellcheck disable=SC2016 # expanded by the inner bash
	timeout 5 bash -c ': </dev/tcp/"$1"/"$2"' _ "$host" "$port" 2>/dev/null
}
ssh_port() {
	local addr=${1#*@} port
	port=$(ssh -G "$1" 2>/dev/null | awk '$1 == "port" {print $2; exit}')
	port=${port:-22}
	if [[ $port != 22 ]] && ! port_open "$addr" "$port" && port_open "$addr" 22; then
		echo "$addr: nothing on port $port, using 22 (sshd not moved yet: box ssh there)" >&2
		port=22
	elif [[ $port == 22 ]] && ! port_open "$addr" 22 && port_open "$addr" 222; then
		# No ssh setup here yet (pull --from): the other hosts' sshd is on 222.
		port=222
	fi
	echo "$port"
}

# use_ssh USER@ADDRESS: rsync and the leader check (leader-guard.sh) reach it
# on its port, with --login's options first (ssh keeps the first value).
use_ssh() {
	local port=${2:-}
	[[ -n $port ]] || port=$(ssh_port "$1")
	GUARD_SSH_OPTS="$LOGIN_SSH_OPTS -p $port"
	ssh_args=(-e "ssh -o ConnectTimeout=10 $LOGIN_SSH_OPTS -o BatchMode=yes -p $port")
}
ssh_args=()

if [[ -n $from ]]; then
	# [USER@]ADDRESS[:PORT]; the account that ran sudo is the admin account
	# everywhere, so it is the default user.
	port=''
	if [[ $from == *@* ]]; then user=${from%%@*}; from=${from#*@}; else user=${SUDO_USER:-$(id -un)}; fi
	if [[ $from =~ ^(.+):([0-9]+)$ && ${BASH_REMATCH[1]} != *:* ]]; then from=${BASH_REMATCH[1]} port=${BASH_REMATCH[2]}; fi
	[[ $user != root ]] || { echo "--from: the hosts refuse root over ssh: --from <admin account>@$from" >&2; exit 2; }
	command -v rsync >/dev/null || { echo "rsync is missing: apt-get install -y rsync" >&2; exit 1; }
	if [[ $force == no && -d $data && -n $(ls -A "$data" 2>/dev/null) ]]; then
		echo "$data already has files: pulling would replace them (--force, or -n to see what would change)" >&2
		exit 1
	fi
	src=$user@$from
	login_check "$user" "$from"
	use_ssh "$src" "$port"
	# Owners by number: the accounts of the data folder may not exist here yet.
	# Protected root-only secret/backup dirs cannot be read by non-root admin_role;
	# skip them during initial bootstrap and copy them via `box data push` from the leader.
	args+=(--numeric-ids
		--exclude=/keys/ssh/ --exclude=/keys/acme/ --exclude=/keys/ssl/
		--exclude=/keys/opendkim/ --exclude=/keys/postsrsd/ --exclude=/keys/dns/
		--exclude=/keys/websso/ --exclude=/keys/mariadb/ --exclude=/keys/alerts/
		--exclude=/backups/)
	[[ $dry == yes ]] || mkdir -p "$data"
	echo "pull $src:$data/ -> $data/$([[ $dry == yes ]] && echo " (dry run)")"
	run_rsync "${args[@]}" "${ssh_args[@]}" "$src:$data/" "$data/"
	[[ $dry == yes ]] || echo "next: box link $data, box setup, then on the leader: box data push <this-host> (copies root-only secrets)"
	exit
fi

if [[ $dir == pull ]]; then
	((${#hosts[@]} <= 1)) || { echo "pull takes one host" >&2; exit 2; }
	from=${hosts[0]:-$leader}
	if [[ $self == "$leader" && $force == no ]]; then
		echo "this host is the leader: pulling would overwrite the reference data folder (--force)" >&2
		exit 1
	fi
	src=$(remote "$from")
	[[ $login == no ]] || login_check "${src%@*}" "${src#*@}"
	use_ssh "$src"
	echo "pull $src:$data/ -> $data/$([[ $dry == yes ]] && echo " (dry run)")"
	run_rsync "${args[@]}" "${ssh_args[@]}" "$src:$data/" "$data/"
	exit
fi

# push
if [[ $self != "$leader" && $force == no ]]; then
	echo "this host is not the leader ($leader): push from there, or --force" >&2
	exit 1
fi
targets=()
if ((${#hosts[@]})); then
	for h in "${hosts[@]}"; do targets+=("$(remote "$h")"); done
elif [[ $self == "$leader" && $login == no ]]; then
	read -ra targets <<<"$("$srv" get remote_hosts "")"
else
	for h in $("$srv" get hosts); do
		[[ $h == "$self" ]] || targets+=("$(remote "$h")")
	done
fi
((${#targets[@]})) || { echo "no other host to push to"; exit 0; }

status=0
for t in "${targets[@]}"; do
	[[ $login == no ]] || login_check "${t%@*}" "${t#*@}"
	use_ssh "$t"
	if [[ $force == no ]] && ! remote_accepts_me "$t" "$data"; then
		status=1
		continue
	fi
	echo "push $data/ -> $t:$data/$([[ $dry == yes ]] && echo " (dry run)")"
	if ! run_rsync "${args[@]}" "${ssh_args[@]}" "$data/" "$t:$data/"; then
		echo "push to $t failed" >&2
		status=1
	fi
done
exit $status
