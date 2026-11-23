# shellcheck shell=bash
# box peer-health: each host checks the others from the outside, the way
# users and other servers reach them, and alerts when a service of a peer
# stops answering (and when it answers again).
#
# What is checked, on each address of the peer (IPv4, and IPv6 when the
# inventory has <host>_ip6), for the services in its host file:
#   always   ssh with this host's key (the replication path)
#   dns      an authoritative answer for the domain's SOA
#   mail     an SMTP greeting (220) on 25 and 587
#   web      HTTPS for the domain (certificate checked), on the web host
# The rest (db, torrent, vpn, minecraft, onion) is not reachable from outside
# or needs more than a probe; the peer's own box watch covers it.
#
# One alert per outage: each peer has one watcher, the first other host of
# hosts= that is reachable over ssh (falling back to the next reachable peer
# when the primary watcher itself is down); it alerts when the set of failures
# changes. Every host still checks every peer, so box peer-health by hand
# shows the whole picture.

# peer_env HOST: the per-host file of HOST in the data folder (the one with
# host=HOST), empty when there is none.
peer_env() {
	local f
	for f in "$(get data_dir /home/data)"/configs/*.env; do
		[[ ${f##*/} == hosts.env ]] && continue
		grep -qE "^host=\"?$1\"?$" "$f" 2>/dev/null && { echo "$f"; return; }
	done
}

peer_services() {
	local f
	f=$(peer_env "$1")
	[[ -n $f ]] || return 0
	SRV_HOST_ENV=$f "$SRV" get services 2>/dev/null || true
}

# peer_watcher HOST REACHABLE: the host that sends the alerts about HOST:
# the first other host of hosts= listed in space-padded REACHABLE.
peer_watcher() {
	local target=$1 up=$2 h
	for h in $(get hosts); do
		[[ $h != "$target" && $up == *" $h "* ]] && { echo "$h"; return; }
	done
}

# smtp_greets ADDR PORT: the server greets with 220 within 10 s.
smtp_greets() {
	local line
	# shellcheck disable=SC2016 # expanded by the inner bash
	line=$(timeout 10 bash -c 'exec 3<>"/dev/tcp/$1/$2" && read -r -t 8 l <&3 && echo "$l"' _ "$1" "$2" 2>/dev/null) || true
	[[ $line == 220* ]]
}

# https_answers ADDR: HTTPS for the domain on ADDR, certificate verified; any
# HTTP status below 500 counts.
https_answers() {
	local domain a=$1 code
	domain=$(get domain blunderer.org)
	[[ $a == *:* ]] && a="[$a]"
	code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 --resolve "$domain:443:$a" "https://$domain/" 2>&1) || true
	[[ $code =~ ^[1-4][0-9][0-9]$ ]] && return 0
	echo "${code:-no answer}"
	return 1
}

# peer_health_alert HOST FAILURES: alert when HOST's failures changed.
peer_health_alert() {
	local h=$1 now=$2 state=$STATE_DIR/peer-health.$1 before
	mkdir -p "$STATE_DIR"
	before=$(cat "$state" 2>/dev/null || true)
	[[ $before != "$now" ]] || return 0
	if [[ -z $now ]]; then
		rm -f "$state"
		printf 'Every check of %s passes again (seen from %s).\n\nBefore:\n%s\n' "$h" "$(get host)" "$before" |
			send_alert "peer-health: $h back"
	else
		printf '%s\n' "$now" >"$state"
		printf 'Seen from %s, on %s:\n\n%s\n\nOn %s: srv status; box check.\n' "$(get host)" "$h" "$now" "$h" |
			send_alert "peer-health: $h: $(wc -l <<<"$now") failure(s)"
	fi
}

cmd_peer_health() {
	need_root
	need_env
	[[ $(get in_inventory yes) == yes ]] || return 0
	local h svcs addrs a p out fails web_host self ssh_up
	local -A peer_fails=()
	self=$(get host)
	web_host=$(get web "")
	ssh_up=" $self "
	for h in $(peers); do
		say "peer $h, seen from $self"
		fails=''
		svcs=" $(peer_services "$h") "
		[[ $svcs != "  " ]] || warn "$h: no per-host file with host=$h in the data folder: only ssh checked"
		addrs=$(get "${h}_ip")
		[[ -z $(get "${h}_ip6" "") ]] || addrs+=" $(get "${h}_ip6")"

		if out=$(ssh -F /etc/ssh/ssh_config -o BatchMode=yes "$h" true 2>&1); then
			ok "ssh"
			ssh_up+="$h "
		else
			fails+="ssh: $(tail -n 1 <<<"$out")"$'\n'
			warn "ssh: $(tail -n 1 <<<"$out")"
		fi
		for a in $addrs; do
			if [[ $svcs == *" dns "* ]]; then
				if { dig +short +norecurse +time=3 +tries=2 @"$a" SOA "$(get domain blunderer.org)" 2>/dev/null || true; } | grep -qv '^;'; then
					ok "dns on $a"
				else
					fails+="dns on $a: no answer"$'\n'
					warn "dns on $a: no answer"
				fi
			fi
			if [[ $svcs == *" mail "* ]]; then
				for p in 25 587; do
					if smtp_greets "$a" "$p"; then
						ok "smtp $p on $a"
					else
						fails+="smtp $p on $a: no 220 greeting"$'\n'
						warn "smtp $p on $a: no 220 greeting"
					fi
				done
			fi
			if [[ $h == "$web_host" && $svcs == *" web "* ]]; then
				if out=$(https_answers "$a"); then
					ok "https on $a"
				else
					fails+="https on $a: $out"$'\n'
					warn "https on $a: $out"
				fi
			fi
		done
		peer_fails[$h]=${fails%$'\n'}
	done
	for h in $(peers); do
		if [[ $(peer_watcher "$h" "$ssh_up") == "$self" ]] ||
			[[ -z ${peer_fails[$h]} && -s $STATE_DIR/peer-health.$h ]]; then
			peer_health_alert "$h" "${peer_fails[$h]}"
		fi
	done
	# Failures are reported by alert (or above), not by the exit status: box
	# run would otherwise send a second mail for the same outage.
	return 0
}
