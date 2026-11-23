# shellcheck shell=bash
# Checks for `box check`, sourced by box (uses its ok/warn/fail, get, $SRV and
# $REPO). Each one comes from a real failure; the comment names it.
#
# fail: a definite misconfiguration (box watch emails it every morning).
# warn: depends on something outside this host, or worth a look.

# Domains of the zones in the repository (blunderer.org, lelong.xyz...).
zone_domains() {
	local f
	for f in "$REPO"/services/dns/config/zones/*.zone; do
		basename "$f" .zone
	done
}

have_dig() {
	command -v dig >/dev/null && return 0
	warn "dig is missing, DNS checks skipped (box packages)"
	return 1
}

runs() { [[ " $(get services) " == *" $1 "* ]]; }

# --- Services ---------------------------------------------------------------

# A container can run healthy without the host ports its compose file asks
# for (dns after a start that failed on "address already in use").
check_ports() {
	local id name netmode spec port hport proto mapped ss_flag bad=0
	local -A seen_ids=()
	if command -v podman >/dev/null 2>&1 && declare -F keys_pctl >/dev/null 2>&1; then
		while read -r id name; do
			[[ -n $id && $id != '-' ]] || continue
			[[ -z ${seen_ids[$id]+set} ]] || continue
			seen_ids[$id]=1
			[[ $(keys_pctl inspect -f '{{.State.Running}}' "$id" 2>/dev/null || true) == true ]] || continue
			netmode=$(keys_pctl inspect -f '{{.HostConfig.NetworkMode}}' "$id" 2>/dev/null || true)
			# shellcheck disable=SC2016 # Go template, not shell expansion
			for spec in $(keys_pctl inspect -f '{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{$p}}={{.HostPort}} {{end}}{{end}}' "$id" 2>/dev/null); do
				port=${spec%%=*}
				hport=${spec#*=}
				mapped=$(keys_pctl inspect -f "{{with index .NetworkSettings.Ports \"$port\"}}{{len .}}{{end}}" "$id" 2>/dev/null || true)
				if [[ -n $mapped && $mapped != 0 ]]; then
					continue
				fi
				if [[ $netmode == pasta* && $hport =~ ^[0-9]+$ ]] && command -v ss >/dev/null 2>&1; then
					proto=${port##*/}
					ss_flag=-t
					[[ $proto == udp ]] && ss_flag=-u
					if ss -H "${ss_flag}ln" "( sport = :$hport )" 2>/dev/null | grep -q .; then
						continue
					fi
				fi
				fail "$name: $port is not published on the host (srv deploy that service again)"
				bad=1
			done
		done < <(
			keys_pctl ps --filter 'name=^srv-' --format '{{.ID}} {{.Names}}' 2>/dev/null || true
			keys_pctl pod ps --filter 'name=^srv-' --format '{{.InfraID}} {{.Name}}' 2>/dev/null || true
		)
	fi
	[[ $bad == 1 ]] || ok "every container publishes the host ports it asks for"
}

# --- Mail -------------------------------------------------------------------

# OpenDKIM/OpenARC errors are invisible otherwise: postfix accepts mail when a
# milter fails (milter_default_action), or defers it with a vague 4.7.1.
check_milter_log() {
	local errs rejects
	errs=$(journalctl -t opendkim -t openarc --since -24h --no-pager -q 2>/dev/null |
		grep -cE 'not secure|error loading key|can.t load key|unable to|[Ee]rror' || true)
	rejects=$(journalctl -t postfix --since -24h --no-pager -q 2>/dev/null |
		grep -cE 'milter-reject|milter .*(timeout|unavailable|connect)' || true)
	if [[ ${errs:-0} == 0 && ${rejects:-0} == 0 ]]; then
		ok "milters: no error in the last 24h"
	else
		warn "milters: ${errs:-0} error(s), ${rejects:-0} rejected/unreachable in the last 24h: journalctl -t opendkim -t openarc --since -24h"
	fi
}

# Deferred mail (Gmail refusing it, a milter deferring it) only shows in logs.
check_mail_queue() {
	local json summary
	if ! json=$("$SRV" exec mail postfix postqueue -j 2>/dev/null); then
		warn "cannot read the mail queue (is mail running?)"
		return 0
	fi
	summary=$(python3 -c '
import json, sys, time
deferred = [json.loads(l) for l in sys.stdin if l.strip()]
deferred = [m for m in deferred if m.get("queue_name") == "deferred"]
oldest = max((time.time() - m["arrival_time"] for m in deferred), default=0)
print(len(deferred), int(oldest // 3600))' <<<"$json")
	read -r n hours <<<"$summary"
	if [[ $n == 0 ]]; then
		ok "mail queue: nothing deferred"
	elif ((hours >= 2)); then
		warn "mail queue: $n deferred, the oldest for ${hours}h: srv exec mail postfix postqueue -p"
	else
		ok "mail queue: $n deferred (recent)"
	fi
}

# SMTP AUTH end to end: postfix (as its own user) reaches saslauthd's socket
# and an account logs in. Uses the alerts account, whose password is in the
# data folder. (postfix was not in the sasl group after the move to srv.)
check_smtp_auth() {
	local user pwfile pw
	user=$(get alert_smtp_user alerts)
	pwfile="$(get data_dir /home/data)/keys/alerts/smtp_password"
	if [[ ! -s $pwfile ]]; then
		warn "SMTP AUTH not tested: no $pwfile (box alerts-account)"
		return 0
	fi
	pw=$(<"$pwfile")
	# Through the environment, so any character in the password is safe (su
	# without -l keeps it).
	# shellcheck disable=SC2016 # expanded by the container's shell
	if "$SRV" exec mail postfix env U="$user" P="$pw" su -s /bin/sh postfix -c \
		'testsaslauthd -f /run/saslauthd/mux -u "$U" -p "$P" -s smtp' 2>&1 | grep -q 'OK "Success."'; then
		ok "SMTP AUTH: postfix reaches saslauthd and the $user account logs in"
	else
		fail "SMTP AUTH fails for $user (docs/runbooks.md, \"An SMTP login is refused\")"
	fi
}

# The forwarding and senders tables are valid, and every SMTP login may send
# as at least one address (otherwise it can log in but every message is
# refused: reject_authenticated_sender_login_mismatch).
check_mail_tables() {
	local dir errors login
	dir=$(mail_conf_dir)
	if [[ ! -f $dir/virtual || ! -f $dir/senders ]]; then
		fail "missing $dir/virtual or senders (srv deploy mail creates them)"
		return 0
	fi
	errors=$(check_virtual "$dir/virtual")
	if [[ -n $errors ]]; then fail "forwarding table: $(head -n 1 <<<"$errors") (box mail config)"; else ok "forwarding table valid"; fi
	errors=$(check_senders "$dir/senders")
	if [[ -n $errors ]]; then fail "senders table: $(head -n 1 <<<"$errors") (box mail config)"; else ok "senders table valid"; fi
	for login in $(mail_logins); do
		awk -v l="$login" '!/^[[:space:]]*(#|$)/ {o = $0; sub(/^[^[:space:]]+[[:space:]]+/, "", o); gsub(/,/, " ", o); if (index(" " o " ", " " l " ")) f = 1} END {exit !f}' "$dir/senders" ||
			warn "login $login may not send as any address: its mail is refused (box mail config, senders)"
	done
	return 0
}

# Blocklists answer only resolvers that are not big shared ones; otherwise
# every query returns an error code (all mail was rejected before the codes
# were pinned). 2.0.0.127 is Spamhaus's permanent test listing.
check_blocklists() {
	local answer
	answer=$("$SRV" exec mail postfix getent ahostsv4 2.0.0.127.zen.spamhaus.org 2>/dev/null |
		awk '{print $1}' | sort -u | xargs || true)
	case " $answer " in
		*" 127.0.0.2 "*) ok "Spamhaus answers the mail resolver" ;;
		*127.255.255.*) warn "Spamhaus refuses the mail resolver ($answer): blocklists inactive (docs/mail.md)" ;;
		"  ") warn "no answer from Spamhaus through the mail resolver (is the resolver container healthy?)" ;;
		*) warn "unexpected Spamhaus test answer: $answer" ;;
	esac
}

# dkim_record_line SELECTOR KEY: the zone line publishing KEY, its TXT split
# in strings of at most 255 characters.
dkim_record_line() {
	echo "         $1._domainkey		IN	TXT	( \"v=DKIM1; k=rsa; \" $(fold -w 250 <<<"p=$2" | sed 's/.*/"&"/' | xargs -d '\n') )"
}

# Each DKIM key in KeyTable matches the public key published in DNS.
# Compares, for each KeyTable entry, the public key in DNS (what receivers
# check signatures against) with the one of the private key on disk.
check_dkim_dns() {
	local name rest domain selector path file record dns mine bad=0
	while read -r name rest; do
		[[ -n $name && $name != \#* ]] || continue
		IFS=: read -r domain selector path <<<"$rest"
		record=$selector._domainkey.$domain
		# KeyTable names the container's path: /keys/<domain>/<file> is
		# <data>/keys/opendkim/<domain>/<file> on the host.
		file="$(get data_dir /home/data)/keys/opendkim/${path#/keys/}"
		if [[ ! -s $file ]]; then
			warn "DKIM $domain: no private key $file (KeyTable names it)"
			bad=1
			continue
		fi
		mine=$(openssl pkey -in "$file" -pubout 2>/dev/null | grep -v -- '-----' | tr -d '\n')
		dns=$(dig +short TXT "$record" | tr -d '" \n')
		if [[ -z $dns ]]; then
			warn "DKIM $domain: no TXT record $record in DNS: receivers cannot check its signatures. Publish:"
			dkim_record_line "$selector" "$mine"
			bad=1
		elif [[ $dns != *"p=$mine"* ]]; then
			if [[ $dns =~ p=([^\;]*) && -z ${BASH_REMATCH[1]} ]]; then
				warn "DKIM $domain: $record has an empty p= (key revoked in DNS)"
			else
				warn "DKIM $domain: $record publishes another key than $file (rotated key not published, or an old record). The record for that key, in services/dns/config/zones/$domain.zone (then srv deploy dns on the leader):"
			fi
			dkim_record_line "$selector" "$mine"
			bad=1
		fi
	done <"$REPO/services/mail/config/opendkim/KeyTable"
	[[ $bad == 1 ]] || ok "DKIM: every key matches its DNS record"
}

# The SPF record of every domain allows this host's sending addresses (IPv6
# only when postfix sends over IPv6). A missing AAAA record let IPv6 mail fail.
check_spf() {
	local -a addrs=("$(get host_ip)")
	local ip6 d out
	ip6=$(get "$(get host)_ip6" "")
	[[ -n $ip6 && $(get smtp_address_preference ipv4) == any ]] && addrs+=("$ip6")
	for d in $(mail_domains); do
		if out=$(python3 "$REPO/lib/spf_covers.py" "$d" "${addrs[@]}"); then
			ok "SPF $d allows ${addrs[*]}"
		else
			warn "SPF $d: $(grep -v ' ok ' <<<"$out" | xargs)"
		fi
	done
}

# What clients and other servers actually get on 587/465 (postfix) and 443
# (nginx): a trusted chain for the names they use, not expiring soon, and the
# key on disk matching the certificate. (Gmail dropped "Send mail as" after
# STARTTLS on a certificate without the host's name.)
check_certificates() {
	local dir cert key names name port
	dir="$(get data_dir /home/data)/keys/ssl/$(get domain blunderer.org)"
	cert=$dir/fullchain.crt key=$dir/$(get domain blunderer.org).key
	if [[ ! -s $cert || ! -s $key ]]; then
		fail "no certificate in $dir"
		return 0
	fi
	local end
	end=$(openssl x509 -in "$cert" -noout -enddate | cut -d= -f2)
	if ! openssl x509 -in "$cert" -noout -checkend $((7 * 86400)) >/dev/null; then
		fail "certificate expires in less than 7 days, or has ($end): renewal broken? (journalctl -t srv-ssl-renew)"
	elif ! openssl x509 -in "$cert" -noout -checkend $((21 * 86400)) >/dev/null; then
		warn "certificate expires in less than 21 days ($end)"
	else
		ok "certificate valid until $end"
	fi
	if [[ $(openssl x509 -in "$cert" -noout -pubkey | sha256sum) == "$(openssl pkey -in "$key" -pubout 2>/dev/null | sha256sum)" ]]; then
		ok "certificate and key match"
	else
		fail "the key in $dir does not belong to the certificate"
	fi

	if runs mail; then
		names="$(get server_name) $(get "$(get host)_names" "" | tr ' ' '\n' | grep '^mail' | sed "s/:[46]\$//; s/\$/.$(get domain blunderer.org)/" | xargs)"
		for name in $names; do
			for port in 587 465; do
				tls_verify "$name" "$port"
			done
		done
	fi
	if runs web; then
		tls_verify "$(get domain blunderer.org)" 443
		tls_verify "auth.$(get host).$(get domain blunderer.org)" 443
	fi
}

tls_verify() { # tls_verify NAME PORT: what a client checking NAME sees
	local name=$1 port=$2 opts=() out
	[[ $port == 587 ]] && opts=(-starttls smtp)
	out=$(timeout 15 openssl s_client -connect "127.0.0.1:$port" "${opts[@]}" -servername "$name" \
		-verify_hostname "$name" -verify_return_error </dev/null 2>&1 || true)
	if grep -q 'Verify return code: 0 (ok)' <<<"$out"; then
		ok "TLS on $port valid for $name"
	else
		fail "TLS on $port not valid for $name: $(grep -m1 -oE 'verify error:.*|Verify return code: [1-9].*|Connection refused' <<<"$out" || echo 'no TLS answer')"
	fi
}

# --- DNS (on the leader: once for all hosts) --------------------------------

# Exactly one DMARC record per domain (receivers ignore none or several).
check_dmarc() {
	local d n
	for d in $(zone_domains); do
		n=$(dig +short TXT "_dmarc.$d" | tr -d '"' | grep -ci '^v=DMARC1' || true)
		case $n in
			1) ok "DMARC $d" ;;
			0) warn "no DMARC record for $d (_dmarc.$d)" ;;
			*) fail "$n DMARC records for $d: receivers ignore them all" ;;
		esac
	done
}

# check_delegation: the registrar's NS records (asked of the parent zone's
# servers) are ns= from the inventory, and each one in our domain has a glue
# record for every address its name has in our zone (A and/or AAAA).
check_delegation() {
	local d parent pns deleg want domain n fam rec glue missing
	domain=$(get domain blunderer.org)
	want=$(for n in $(get ns "ns0 ns1"); do echo "$n.$domain."; done | sort)
	for d in $(zone_domains); do
		parent=${d#*.}
		pns=$(dig +short NS "$parent." | head -n 1)
		[[ -n $pns ]] || { warn "$d: no name server for $parent (dig NS $parent)"; continue; }
		rec=$(dig +norecurse +noall +authority +additional +time=3 +tries=2 NS "$d" @"$pns" || true)
		deleg=$(awk '$4 == "NS" {print tolower($5)}' <<<"$rec" | sort -u)
		if [[ -z $deleg ]]; then
			warn "$d: $pns gives no delegation"
			continue
		elif [[ $deleg != "$want" ]]; then
			warn "$d: the registrar lists $(xargs <<<"$deleg"), the inventory ns= $(xargs <<<"$want")"
			continue
		fi
		missing=''
		[[ $d == "$domain" ]] && for n in $deleg; do
			for fam in A AAAA; do
				[[ -n $(dig +short +norecurse +time=3 +tries=2 "$n" "$fam" @127.0.0.1 2>/dev/null) ]] || continue
				glue=$(awk -v n="$n" -v t="$fam" 'tolower($1) == n && $4 == t' <<<"$rec")
				[[ -n $glue ]] || missing+=" ${n%."$domain."}($fam)"
			done
		done
		if [[ -n $missing ]]; then
			warn "$d: glue records missing at the registrar:$missing"
		else
			ok "$d: delegated to $(xargs <<<"$deleg" | sed "s/\.$domain\.//g")"
		fi
	done
}

# Every name server of every zone serves the same zone: same SOA serial and
# the same mail records (a hand edit, or a slave that missed a notification).
check_nameservers() {
	local d ns sig ref bad
	for d in $(zone_domains); do
		ref='' bad=0
		for ns in $(dig +short NS "$d" | sort); do
			sig=$(for q in "$d SOA" "$d MX" "$d TXT" "_dmarc.$d TXT" "mail._domainkey.$d TXT"; do
				# shellcheck disable=SC2086 # name and type
				dig +short +norecurse +time=3 +tries=2 @"$ns" $q | sort
			done | sha256sum | cut -c1-12)
			if [[ -z $ref ]]; then
				ref=$sig
			elif [[ $sig != "$ref" ]]; then
				bad=1
			fi
		done
		if [[ -z $ref ]]; then
			warn "$d: no name server found (dig NS $d)"
		elif [[ $bad == 1 ]]; then
			fail "$d: its name servers answer differently (compare: dig @<ns> SOA $d, for each NS)"
		else
			ok "$d: every name server serves the same zone"
		fi
	done
}

# --- Access -----------------------------------------------------------------

# Banned by fail2ban yourself (recidive bans every port for a week).
check_own_ban() {
	local ip jail banned=''
	ip=$(client_ip)
	[[ -n $ip ]] || return 0
	systemctl is-active -q fail2ban 2>/dev/null || return 0
	for jail in $(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr -d ','); do
		fail2ban-client status "$jail" 2>/dev/null | grep -q "Banned IP list:.*\b$ip\b" && banned+=" $jail"
	done
	if [[ -n $banned ]]; then
		fail "your address $ip is banned in:$banned (box ssh-trusted $ip lifts and prevents it)"
	elif trusted_ips | grep -qxF "$ip"; then
		ok "your address $ip is trusted (never banned)"
	else
		ok "your address $ip is not banned (box ssh-trusted makes it permanent)"
	fi
}

# --- Data folder ------------------------------------------------------------

# data_dir is the real data folder (/home/data was set while the data was in
# /home/new-data: alerts and keys were looked for in the wrong place).
check_data_folder() {
	local data env d
	data=$(get data_dir /home/data)
	if [[ -f $data/configs/hosts.env ]]; then
		ok "$data holds the inventory (configs/hosts.env)"
	else
		fail "$data has no configs/hosts.env: is data_dir right?"
	fi
	env=$(readlink -f /etc/srv/host.env 2>/dev/null || true)
	[[ $env == "$data"/configs/* ]] ||
		warn "/etc/srv/host.env is $env, not a file in $data/configs"
	for d in /home/data /home/new-data /srv/data; do
		[[ $d != "$data" && -f $d/configs/hosts.env ]] &&
			warn "another data folder in $d (data_dir is $data): which one is current?"
	done
	return 0
}
