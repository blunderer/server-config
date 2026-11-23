# leader-guard.sh: sourced by the scripts that push to other hosts.
# shellcheck shell=bash disable=SC2154 # $srv is set by the sourcing script
#
# remote_accepts_me REMOTE DATA: the remote's inventory still names this host
# as the leader. After `box leader --force` on another host, a returning
# old leader would otherwise push its stale data folder (rsync --delete) and
# certificates over the new leader's. Prints the reason when it refuses.
remote_accepts_me() {
	local remote=$1 data=$2 me theirs qpath
	me=$("$srv" get host)
	printf -v qpath '%q' "$data/configs/hosts.env"
	# GUARD_SSH_OPTS (--login) first: ssh keeps the first value of an option.
	# shellcheck disable=SC2086 # several options
	theirs=$(ssh ${GUARD_SSH_OPTS:-} -o BatchMode=yes -o ConnectTimeout=10 "$remote" \
		"sed -n 's/^leader=//p' $qpath" 2>/dev/null | tr -d "\"'" | tail -1) || true
	if [[ -z $theirs ]]; then
		echo "$remote: cannot read its inventory ($data/configs/hosts.env); not pushing" >&2
		echo "  A new host (no inventory yet, does not trust this host's key): box data push <host> --login --force" >&2
		return 1
	fi
	if [[ $theirs != "$me" ]]; then
		echo "$remote: its inventory names $theirs as the leader, not $me; not pushing." >&2
		echo "  If $theirs took over, this host is no longer the leader: box audit" >&2
		return 1
	fi
}
