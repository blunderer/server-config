# shellcheck shell=bash
# Day-to-day tools of box, sourced by it (uses say/ok/warn/fail/die, get,
# need_root, need_env, $SRV): box mail, box dns, box tls, box ban.
# Each one replaces a sequence of commands we typed by hand.
# Also box minecraft: the players of the Minecraft service.

# ============================================================== box mail ===

cmd_mail() {
	local sub=${1:-}
	shift || true
	case $sub in
		trace) mail_trace "$@" ;;
		test) mail_test "$@" ;;
		user | users) mail_user "$@" ;;
		config) mail_config "$@" ;;
		spam) mail_spam "$@" ;;
		*) die "usage: box mail trace <address|queue-id> [--since TIME] | test [ADDRESS] | user add|passwd|del|list | config | spam [--since TIME] [--min SCORE]" ;;
	esac
}

# The mail logs of the last SINCE (journald tags of the mail containers).
mail_journal() {
	journalctl -t postfix -t opendkim -t openarc -t postsrsd -t saslauthd \
		--since "$1" --no-pager -q -o short-iso 2>/dev/null
}

# box mail spam [--since TIME] [--min SCORE]: the messages rspamd scored as
# spam (from 6, X-Spam-Status: Yes, or --min), oldest first: when, score,
# what rspamd did (add header while tagging, reject once spam_reject is set),
# sender, recipients, client address, and the rules that weighed most. From
# rspamd's one log line per message (journald tag rspamd).
mail_spam() {
	need_root
	local since='-7d' min=6
	while (($#)); do
		case $1 in
			--since) since=${2:?--since TIME, e.g. -3d, -12h, yesterday or "2026-11-01"}; shift ;;
			--since=*) since=${1#*=} ;;
			--min) min=${2:?--min SCORE}; shift ;;
			--min=*) min=${1#*=} ;;
			--all) min=-1000 ;;
			*) die "usage: box mail spam [--since TIME] [--min SCORE] [--all]   (default: --since -7d --min 6)" ;;
		esac
		shift
	done
	[[ $min =~ ^-?[0-9]+(\.[0-9]+)?$ ]] || die "--min $min: a score, e.g. 6 or 10.5"
	local log
	log=$(journalctl -t rspamd --since "$since" --no-pager -q -o short-iso 2>/dev/null | grep -F '(default: ' || true)
	if [[ $min == -1000 ]]; then say "every message rspamd scanned since $since"; else say "spam scored by rspamd since $since (score >= $min)"; fi
	if [[ -z $log ]]; then
		warn "no rspamd results since $since (is the mail service, with rspamd, running here?)"
		return 0
	fi
	MIN=$min perl -ne '
		next unless /\(default: [TF] \(([^)]+)\): \[(-?[\d.]+)\/[^\]]*\] \[(.*?)\]\)/;
		my ($action, $score, $syms) = ($1, $2, $3);
		$total++;
		next if $score < $ENV{MIN};
		my ($when) = /^(\S+)/;
		$when =~ s/T/ /; $when = substr($when, 0, 16);
		my ($from) = /\bfrom: <([^>]*)>/;
		my ($rcpt) = /\brcpts?: <([^>]*)>/;
		my ($ip) = /\bip: ([0-9a-fA-F:.]+)/;
		my %w;
		while ($syms =~ /([A-Z0-9_]+)\((-?[\d.]+)\)/g) { $w{$1} = $2 }
		my @top = grep { $w{$_} > 0 } sort { $w{$b} <=> $w{$a} } keys %w;
		splice(@top, 4) if @top > 4;
		printf "  %s  %6.2f  %-10s  %s -> %s  [%s]\n      %s\n",
			$when, $score, $action, ($from // "?") || "<>", $rcpt // "?", $ip // "?",
			join(" ", map { "$_($w{$_})" } @top);
		$shown++;
		END { printf "\n  %d of %d scanned message(s)%s\n", $shown // 0, $total // 0, $ENV{MIN} > -1000 ? " at or above $ENV{MIN}" : "" }
	' <<<"$log"
}

# Postfix queue ids in log lines: "postfix/smtpd[12]: 4Xa9Bc1dEfz: ..." and
# the milters' "opendkim[7]: 4Xa9Bc1dEfz: DKIM-Signature field added". (Short
# ids are hex, long ones 11+ letters and digits; both are 8 to 16 characters.)
QUEUE_ID_RE='\]: [0-9A-Za-z]{8,16}:'

# queue_ids < log lines: the distinct queue ids in them.
queue_ids() {
	grep -oE "$QUEUE_ID_RE" | grep -oE '[0-9A-Za-z]{8,16}' | grep -vxE 'statistics|NOQUEUE' | sort -u | xargs || true
}

# box mail trace <address|queue-id|message-id> [--since TIME]: every log line
# of the messages from or to an address (or one queue id), in order, then a
# verdict per message. Rejections before queueing (NOQUEUE) are included.
mail_trace() {
	need_root
	local what='' since='-24 hours' log ids id
	while (($#)); do
		case $1 in
			--since) since=${2:?--since TIME, e.g. "-2 hours" or "2026-11-05 22:00"}; shift ;;
			*) what=$1 ;;
		esac
		shift
	done
	[[ -n $what ]] || die "usage: box mail trace <address|queue-id|message-id> [--since TIME]"
	log=$(mail_journal "$since")
	[[ -n $log ]] || die "no mail logs since $since (is mail running on this host?)"

	# The queue ids involved: the argument itself, or every message whose log
	# lines mention it (from=, to=, orig_to=, sasl_username=, message-id=).
	if [[ $what =~ ^[0-9A-Za-z]{8,16}$ ]] && grep -qF "]: $what:" <<<"$log"; then
		ids=$what
	else
		ids=$(grep -F -- "$what" <<<"$log" | queue_ids)
	fi

	say "mail trace: $what (since $since)"
	local pattern=''
	for id in $ids; do pattern+="${pattern:+|}\\]: $id:"; done
	# Message lines, plus rejections that never got a queue id.
	{
		[[ -z $pattern ]] || grep -E "$pattern" <<<"$log"
		grep -F -- "$what" <<<"$log" | grep -E 'NOQUEUE|milter-reject|SASL .* authentication failed|lost connection after' || true
	} | awk '!seen[$0]++' | sort -s -k1,1 | sed 's/^/  /'

	if [[ -z $ids ]]; then
		warn "no queued message matches $what since $since"
		return 0
	fi
	say "verdict"
	local line status
	for id in $ids; do
		line=$(grep -E "\\]: $id:.* status=" <<<"$log" | tail -n 1 || true)
		status=$(grep -oE 'status=[a-z]+' <<<"$line" | cut -d= -f2 || true)
		case $status in
			sent) ok "$id sent: $(grep -oE 'to=<[^>]*>|relay=[^,]*|\(250[^)]*\)' <<<"$line" | xargs)" ;;
			deferred) warn "$id deferred (retrying): $(sed -E 's/.*status=deferred //' <<<"$line")" ;;
			bounced | expired) fail "$id $status: $(sed -E 's/.*status=[a-z]+ //' <<<"$line")" ;;
			'')
				if grep -qE "\\]: $id:.*(milter-reject|reject:)" <<<"$log"; then
					fail "$id rejected: $(grep -E "\\]: $id:.*(milter-reject|reject:)" <<<"$log" | tail -n 1 | sed -E 's/.*(milter-reject|reject): //')"
				elif grep -qE "\\]: $id: removed" <<<"$log"; then
					ok "$id removed from the queue (forwarded or delivered locally)"
				else
					warn "$id: no delivery yet (srv exec mail postfix postqueue -p)"
				fi
				;;
			*) warn "$id: status=$status" ;;
		esac
	done
}

# box mail test [ADDRESS]: send a message through submission (587, the
# alerts account) to ADDRESS (default alert_email), then trace it: SMTP AUTH,
# the milters (DKIM, ARC) and delivery, end to end.
mail_test() {
	need_root
	need_env
	local to=${1:-$(get alert_email "")} token msgid id=''
	[[ -n $to ]] || die "usage: box mail test ADDRESS (or set alert_email)"
	[[ -s /etc/msmtprc ]] || die "msmtp is not set up: box alerts"
	token=$(date +%Y%m%d%H%M%S).$RANDOM
	msgid="box-test-$token@$(get server_name)"
	say "mail test: $(get server_name) -> $to"
	if ! {
		echo "To: $to"
		echo "From: box $(hostname -s) <$(get alert_from "alerts@blunderer.org")>"
		echo "Subject: [$(hostname -s)] mail test $token"
		echo "Message-ID: <$msgid>"
		echo "Date: $(date -R)"
		echo "Content-Type: text/plain; charset=UTF-8"
		echo
		echo "Test message from box mail test on $(get server_name)."
		echo "Check its headers: Authentication-Results should show dkim=pass, spf=pass, dmarc=pass."
	} | /usr/bin/msmtp -t; then
		fail "submission refused (msmtp above; SMTP AUTH or TLS on 587)"
		return 0
	fi
	ok "accepted on 587 with SMTP AUTH (message-id $msgid)"
	# Wait for postfix to finish with it (up to a minute).
	for _ in $(seq 30); do
		id=$(mail_journal '-10 minutes' | grep -F "message-id=<$msgid>" | queue_ids | awk '{print $NF}')
		if [[ -n $id ]] && mail_journal '-10 minutes' | grep -qE "\\]: $id:.*(status=|removed|reject)"; then
			break
		fi
		sleep 2
	done
	if [[ -z $id ]]; then
		warn "no trace of $msgid in the logs yet: box mail trace '$msgid'"
		return 0
	fi
	mail_trace "$id" --since '-10 minutes'
	echo "  In the received copy, open the headers: Authentication-Results should"
	echo "  read dkim=pass, spf=pass and dmarc=pass."
}

# --- box mail user: the SMTP AUTH accounts of this host's data folder ------
#
# <data>/users/postfix/{passwd,shadow,group} are bind-mounted into the
# saslauthd container as its /etc files. They are rewritten in place (same
# inode), so the running container sees the change without a restart.
# Local: the change stays in this host's data folder. The nightly push
# replaces the other hosts' copies with the leader's, so make it on the
# leader, or it is undone at 03:00.

mail_users_dir() { echo "$(get data_dir /home/data)/users/postfix"; }

# write_in_place FILE < content: replace FILE's content, same inode.
write_in_place() {
	local file=$1 tmp
	tmp=$(mktemp)
	cat >"$tmp"
	cat "$tmp" >"$file"
	rm -f "$tmp"
}

# read_password NAME: from the terminal (twice) or one line of stdin.
read_password() {
	local pw pw2
	if [[ -t 0 ]]; then
		read -r -s -p "  password for $1: " pw && echo >&2
		read -r -s -p "  again: " pw2 && echo >&2
		[[ $pw == "$pw2" ]] || die "the passwords differ"
	else
		IFS= read -r pw || true
	fi
	((${#pw} >= 12)) || die "password too short (12 characters at least)"
	printf '%s' "$pw"
}

sha512_crypt() {
	local salt hash
	salt=$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)
	hash=$(perl -e 'print crypt($ARGV[0], q($6$) . $ARGV[1])' "$1" "$salt")
	[[ $hash == \$6\$* ]] || die "could not hash the password"
	echo "$hash"
}

# The account the alerts and box mail test send with, from the host config:
# alert_smtp_user (default alerts), only when alerts are set up on this host
# (alert_email). Its password also goes to <data>/keys/alerts/smtp_password,
# where msmtp reads it (passwordeval in /etc/msmtprc).
alerts_pw_file() { echo "$(get data_dir /home/data)/keys/alerts/smtp_password"; }
alerts_account() {
	if alerts_configured; then get alert_smtp_user alerts; fi
}
is_alerts_account() { [[ -n $1 && $1 == "$(alerts_account)" ]]; }

# set_password NAME RANDOM: read or generate NAME's password, print it on
# stdout; for the alerts account, also store it where msmtp reads it.
new_password() {
	local name=$1 random=$2 pw file
	if [[ $random == yes ]]; then
		pw=$(head -c 18 /dev/urandom | base64)
	else
		pw=$(read_password "$name")
	fi
	if is_alerts_account "$name"; then
		file=$(alerts_pw_file)
		install -d -m 0700 -o 0 -g 0 "$(dirname "$file")"
		(umask 077 && printf '%s\n' "$pw" >"$file")
		chown 0:0 "$file"
		chmod 0600 "$file"
	fi
	printf '%s' "$pw"
}

# tell_password NAME RANDOM PW: where the password is, or show a random one.
tell_password() {
	if is_alerts_account "$1"; then
		ok "$1 is the alerts account (alert_smtp_user): password also stored in $(alerts_pw_file) for msmtp"
	elif [[ $2 == yes ]]; then
		echo "  password (shown once): $3"
	fi
}

mail_user() {
	need_root
	need_env
	local sub=${1:-list} name='' random=no dir uid pw a
	shift || true
	for a in "$@"; do
		case $a in
			--random) random=yes ;;
			*) name=$a ;;
		esac
	done
	dir=$(mail_users_dir)
	[[ -f $dir/passwd && -f $dir/shadow && -f $dir/group ]] ||
		die "missing $dir/{passwd,shadow,group} (the mail service's accounts)"
	if [[ $sub != list ]]; then
		[[ $name =~ ^[a-z][a-z0-9._-]{0,31}$ ]] || die "usage: box mail user $sub <name> [--random] (lowercase letters, digits, . _ -)"
		[[ $(get is_leader no) == yes ]] ||
			warn "this host is not the leader: tonight's push from $(get leader) replaces this change (do it there)"
	fi
	case $sub in
		list)
			say "SMTP accounts ($dir)"
			local u
			while read -r u; do
				if is_alerts_account "$u"; then ok "$u (alerts and box mail test)"; else ok "$u"; fi
			done < <(awk -F: '$2 ~ /^\$/ {print $1}' "$dir/shadow")
			while read -r u; do
				warn "$u has no usable password hash"
			done < <(awk -F: '$2 !~ /^\$/ && $2 !~ /^[*!]/ {print $1}' "$dir/shadow")
			;;
		add)
			grep -q "^$name:" "$dir/passwd" "$dir/shadow" && die "$name already exists (box mail user passwd $name)"
			pw=$(new_password "$name" "$random")
			uid=$(awk -F: '$3 >= 1100 && $3 < 60000 && $3 > m {m = $3} END {print (m ? m + 1 : 1100)}' "$dir/passwd")
			{ cat "$dir/passwd"; echo "$name:x:$uid:$uid:SMTP account:/nonexistent:/usr/sbin/nologin"; } | write_in_place "$dir/passwd"
			{ cat "$dir/shadow"; echo "$name:$(sha512_crypt "$pw"):$(($(date +%s) / 86400)):0:99999:7:::"; } | write_in_place "$dir/shadow"
			grep -q "^$name:" "$dir/group" || { cat "$dir/group"; echo "$name:x:$uid:"; } | write_in_place "$dir/group"
			ok "added $name (uid $uid): it can log in on 587/465 now"
			tell_password "$name" "$random" "$pw"
			;;
		passwd)
			grep -q "^$name:" "$dir/shadow" || die "no account $name (box mail user list)"
			pw=$(new_password "$name" "$random")
			local hash
			hash=$(sha512_crypt "$pw")
			awk -F: -v OFS=: -v n="$name" -v h="$hash" -v d=$(($(date +%s) / 86400)) \
				'$1 == n {$2 = h; $3 = d} {print}' "$dir/shadow" | write_in_place "$dir/shadow"
			ok "password of $name changed (effective now)"
			tell_password "$name" "$random" "$pw"
			;;
		del)
			grep -q "^$name:" "$dir/passwd" "$dir/shadow" || die "no account $name (box mail user list)"
			local f
			for f in passwd shadow group; do
				grep -v "^$name:" "$dir/$f" | write_in_place "$dir/$f" || true
			done
			ok "removed $name"
			if is_alerts_account "$name"; then
				rm -f "$(alerts_pw_file)"
				warn "$name sent the alerts: they fail until box mail user add $name --random"
			fi
			;;
		*) die "usage: box mail user list | add <name> [--random] | passwd <name> [--random] | del <name>" ;;
	esac
}

# --- box mail config: the forwarding table and the senders table ----------
#
# Both in <data>/configs/mail/, texthash tables (no postmap: postfix reload
# reads them again):
#   virtual  "<address> <destination>[, <destination>...]": where mail to
#            our addresses goes (virtual_alias_maps).
#   senders  "<address|@domain> <login>[, <login>...]": which SMTP logins may
#            use an envelope sender (smtpd_sender_login_maps). A logged-in
#            client sending as an address it does not own is refused.
# box mail config edits one after the other, each on a copy checked right
# after the edit; a bad edit is never saved. Local like the logins: do it on
# the leader, whose push gives the others the tables (and the 06:00 srv
# reload makes their postfix read them).

mail_conf_dir() { echo "$(get data_dir /home/data)/configs/mail"; }

# Our domains: virtual_alias_domains in main.cf.
mail_domains() {
	sed -n 's/^virtual_alias_domains *= *//p' "$REPO/services/mail/config/postfix/main.cf"
}

# The SMTP logins: accounts with a password hash.
mail_logins() {
	awk -F: '$2 ~ /^\$/ {print $1}' "$(mail_users_dir)/shadow" 2>/dev/null
}

# check_virtual FILE: the errors of a forwarding table, one per line.
check_virtual() {
	awk -v domains=" $(mail_domains | xargs) " '
		/^[[:space:]]*(#|$)/ {next}
		/^[[:space:]]/ {next}   # continuation of the previous line
		{
			if (NF < 2) {print "line " NR ": no destination for " $1; next}
			if ($1 !~ /^[^@[:space:]]*@[^@[:space:]]+$/) {print "line " NR ": \"" $1 "\" is not an address (user@domain or @domain)"; next}
			d = $1; sub(/^[^@]*@/, "", d)
			if (index(domains, " " d " ") == 0) print "line " NR ": " d " is not in virtual_alias_domains: mail to it is refused"
			if (seen[$1]++) print "line " NR ": " $1 " appears twice (the first line wins)"
		}' "$1"
}

# check_senders FILE: the errors of a senders table, one per line.
check_senders() {
	awk -v logins=" $(mail_logins | xargs) " '
		/^[[:space:]]*(#|$)/ {next}
		/^[[:space:]]/ {next}
		{
			if (NF < 2) {print "line " NR ": no login for " $1; next}
			if ($1 !~ /^[^@[:space:]]*@[^@[:space:]]+$/) {print "line " NR ": \"" $1 "\" is not an address (user@domain or @domain)"; next}
			if (seen[$1]++) print "line " NR ": " $1 " appears twice (the first line wins)"
			owners = $0; sub(/^[^[:space:]]+[[:space:]]+/, "", owners); gsub(/,/, " ", owners)
			n = split(owners, o, /[[:space:]]+/)
			for (i = 1; i <= n; i++)
				if (o[i] != "" && index(logins, " " o[i] " ") == 0)
					print "line " NR ": " o[i] " is not an SMTP login (box mail user list)"
		}' "$1"
}

# edit_table FILE LABEL CHECK: edit a copy of FILE in vim, run CHECK on it
# after each edit, then save it in place. Returns 0 when FILE changed.
edit_table() {
	local file=$1 label=$2 check=$3 tmp editor errors a
	editor=vim
	command -v vim >/dev/null || editor=${VISUAL:-${EDITOR:-vi}}
	say "$label ($file)"
	tmp=$(mktemp --suffix=".$(basename "$file")")
	cp "$file" "$tmp"
	while true; do
		"$editor" "$tmp" </dev/tty >/dev/tty
		if cmp -s "$file" "$tmp"; then
			rm -f "$tmp"
			ok "no change"
			return 1
		fi
		errors=$("$check" "$tmp")
		[[ -n $errors ]] || break
		printf '  %s\n' "${errors//$'\n'/$'\n'  }"
		if [[ -t 0 ]] && read -r -p "  Edit again? [Y/n] (n drops the changes to this file) " a && [[ ${a:-y} != [nN]* ]]; then
			continue
		fi
		rm -f "$tmp"
		warn "$file unchanged"
		return 1
	done
	diff -u --label before --label after "$file" "$tmp" | tail -n +3 | grep -E '^[-+]' | sed 's/^/  /' || true
	cat "$tmp" >"$file"   # same inode
	rm -f "$tmp"
	ok "saved"
	return 0
}

mail_config() {
	need_root
	need_env
	local dir changed=no
	dir=$(mail_conf_dir)
	if [[ ! -f $dir/virtual || ! -f $dir/senders ]]; then
		"$SRV" hook mail prepare >/dev/null || true
		[[ -f $dir/virtual && -f $dir/senders ]] || die "no $dir/virtual or senders (srv hook mail prepare creates them)"
	fi
	[[ $(get is_leader no) == yes ]] ||
		warn "this host is not the leader: tonight's push from $(get leader) replaces this change (do it there)"
	edit_table "$dir/virtual" "forwarding: where mail to our addresses goes" check_virtual && changed=yes
	edit_table "$dir/senders" "senders: which login may send as which address" check_senders && changed=yes
	[[ $changed == yes ]] || return 0
	if "$SRV" status mail 2>/dev/null | awk 'NR == 2 && $2 ~ /^[0-9]/ {f = 1} END {exit !f}'; then
		if "$SRV" reload mail >/dev/null 2>&1; then
			ok "postfix reloaded: the tables are in use"
		else
			fail "postfix reload failed: srv status mail, srv logs mail postfix"
		fi
	else
		ok "mail does not run here: the mail hosts read them after the next push (06:00 reload)"
	fi
}

# =============================================================== box dns ===

# box dns show NAME [TYPE...]: the answer of every name server for NAME,
# side by side: each host of the inventory (asked directly, authoritative
# only), the zone's NS records, and a public resolver (what the world sees).
cmd_dns() {
	local sub=${1:-}
	shift || true
	[[ $sub == show ]] || die "usage: box dns show NAME [TYPE...]   (types default to A AAAA MX TXT)"
	need_env
	command -v dig >/dev/null || die "dig is missing: box packages"
	local name=${1:-} zone types=() h ip srv label t ans
	[[ -n $name ]] || die "usage: box dns show NAME [TYPE...]"
	shift
	types=("$@")
	((${#types[@]})) || types=(A AAAA MX TXT)
	[[ $name == *.* ]] || name=$name.$(get domain blunderer.org)
	name=${name%.}

	# Servers: label=address, inventory hosts first, then extra NS, then public.
	local -a servers=()
	local seen=' '
	for h in $(get hosts); do
		ip=$(get "${h}_ip")
		servers+=("$h=$ip")
		seen+="$ip "
	done
	zone=$(dns_zone_of "$name")
	for srv in $(dig +short NS "$zone" 2>/dev/null); do
		ip=$(dig +short A "$srv" | head -n 1)
		[[ -n $ip && $seen != *" $ip "* ]] || continue
		servers+=("${srv%.}=$ip")
		seen+="$ip "
	done
	servers+=("public (1.1.1.1)=1.1.1.1")

	say "$name (zone $zone)"
	for t in "${types[@]}"; do
		echo "  $t"
		for srv in "${servers[@]}"; do
			label=${srv%=*} ip=${srv##*=}
			if [[ $ip == 1.1.1.1 ]]; then
				ans=$(dig +short +time=3 +tries=1 @"$ip" "$name" "$t" 2>&1)
			else
				ans=$(dig +short +norecurse +time=3 +tries=1 @"$ip" "$name" "$t" 2>&1)
			fi
			[[ -n $ans ]] || ans='(none)'
			grep -q 'timed out\|refused\|no servers' <<<"$ans" && ans='(no answer: down or refused)'
			printf '    %-24s %s\n' "$label" "$(head -n 1 <<<"$ans")"
			tail -n +2 <<<"$ans" | sed 's/^/                             /'
		done
	done
	echo
	echo "  SOA serials: $(for srv in "${servers[@]}"; do
		ip=${srv##*=}
		[[ $ip == 1.1.1.1 ]] && continue
		printf '%s=%s ' "${srv%=*}" "$(dig +short +norecurse +time=3 +tries=1 @"$ip" SOA "$zone" | awk '{print $3}')"
	done)"
}

# dns_zone_of NAME: the zone of the repository that NAME belongs to.
dns_zone_of() {
	local name=$1 f z best=''
	for f in "$REPO"/services/dns/config/zones/*.zone; do
		z=$(basename "$f" .zone)
		[[ $name == "$z" || $name == *".$z" ]] && ((${#z} > ${#best})) && best=$z
	done
	echo "${best:-$(get domain blunderer.org)}"
}

# =============================================================== box tls ===

# box tls [HOST[:PORT]]: what a client gets: names, issuer, expiry, whether
# it verifies for the name asked, protocol and cipher. Without an argument,
# this host on 443, 465 and 587, over IPv4 and IPv6 separately (a different
# answer on one of them was the cause more than once).
cmd_tls() {
	need_env
	local target=${1:-} name port addr ip6
	if [[ -n $target ]]; then
		name=${target%:*} port=443
		[[ $target == *:* ]] && port=${target##*:}
		tls_show "$name" "$port" "$name"
		return 0
	fi
	name=$(get server_name)
	ip6=$(get "$(get host)_ip6" "")
	for port in 443 465 587; do
		for addr in "$(get host_ip)" ${ip6:+"[$ip6]"}; do
			tls_show "$name" "$port" "$addr"
		done
	done
}

# tls_show NAME PORT ADDRESS: connect to ADDRESS:PORT asking for NAME.
tls_show() {
	local name=$1 port=$2 addr=$3 opts=() out cert days end
	[[ $port == 587 || $port == 25 ]] && opts=(-starttls smtp)
	say "$name on $addr:$port"
	out=$(timeout 15 openssl s_client -connect "$addr:$port" "${opts[@]}" -servername "$name" \
		-verify_hostname "$name" -showcerts </dev/null 2>&1 || true)
	cert=$(sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/{p;/-----END/q}' <<<"$out")
	if [[ -z $cert ]]; then
		fail "no TLS answer: $(grep -m1 -iE 'refused|timed out|unreachable|errno|error' <<<"$out" || echo 'nothing')"
		return 0
	fi
	end=$(openssl x509 -noout -enddate <<<"$cert" | cut -d= -f2)
	days=$((($(date -d "$end" +%s) - $(date +%s)) / 86400))
	echo "  subject  $(openssl x509 -noout -subject -nameopt oneline <<<"$cert" | sed 's/^subject= *//')"
	echo "  names    $(openssl x509 -noout -ext subjectAltName <<<"$cert" 2>/dev/null | tail -n +2 | sed 's/DNS://g; s/^ *//' | xargs)"
	echo "  issuer   $(openssl x509 -noout -issuer -nameopt oneline <<<"$cert" | sed 's/^issuer= *//')"
	echo "  expires  $end ($days days)"
	echo "  session  $(grep -m1 -oE 'Protocol *: *[^ ]+|New, [^,]+, Cipher is [^ ]+' <<<"$out" | xargs)"
	if grep -q 'Verify return code: 0 (ok)' <<<"$out"; then
		ok "valid for $name"
	else
		fail "not valid for $name: $(grep -m1 -oE 'Verify return code: .*' <<<"$out")"
	fi
	grep -qi 'staging' <<<"$(openssl x509 -noout -issuer <<<"$cert")" &&
		fail "issued by Let's Encrypt staging: browsers do not trust it"
	return 0
}

# =============================================================== box ban ===

# box ban list | unban ADDR | why ADDR: fail2ban's bans, lifting one, and the
# log lines behind it. (box ssh-trusted prevents bans of your own address.)
cmd_ban() {
	need_root
	local sub=${1:-list} ip=${2:-} jail
	systemctl is-active -q fail2ban 2>/dev/null || die "fail2ban is not running"
	case $sub in
		list)
			for jail in $(fail2ban_jails); do
				say "$jail"
				fail2ban-client get "$jail" banip --with-time 2>/dev/null | sed '/^$/d; s/^/  /' ||
					fail2ban-client status "$jail" | sed -n 's/.*Banned IP list:[[:space:]]*//p' | tr ' ' '\n' | sed '/^$/d; s/^/  /'
			done
			;;
		unban)
			[[ -n $ip ]] || die "usage: box ban unban ADDR"
			if fail2ban-client unban "$ip" >/dev/null; then
				ok "$ip unbanned from every jail (box ssh-trusted $ip keeps it from coming back)"
			else
				fail "fail2ban could not unban $ip"
			fi
			;;
		why)
			[[ -n $ip ]] || die "usage: box ban why ADDR"
			say "bans of $ip"
			for jail in $(fail2ban_jails); do
				fail2ban-client status "$jail" | grep -q "Banned IP list:.*\b$ip\b" && echo "  banned now in $jail"
			done
			journalctl -u fail2ban --since '-8 days' --no-pager -q -o short-iso 2>/dev/null |
				grep -F " $ip" | grep -E 'Ban|Unban|Found' | tail -n 20 | sed 's/^/  /' || true
			say "what it did (last 7 days: ssh and SMTP AUTH)"
			journalctl -t sshd -t sshd-session -t postfix --since '-7 days' --no-pager -q -o short-iso 2>/dev/null |
				grep -F "$ip" | grep -iE 'fail|invalid|refused|authentication' | tail -n 20 | sed 's/^/  /' || true
			;;
		*) die "usage: box ban list | unban ADDR | why ADDR" ;;
	esac
}

fail2ban_jails() {
	fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr -d ','
}

# ========================================================= box minecraft ===

# box minecraft allow|deny <gamertag> | list | op|deop <gamertag> | cmd ...:
# the players of the Minecraft service. Bedrock has no server password: only
# the Microsoft (Xbox) accounts on its allow list can join.
cmd_minecraft() {
	need_root
	need_env
	local sub=${1:-list} file
	shift || true
	file="$(get data_dir /home/data)/minecraft/allowlist.json"
	case $sub in
		list)
			say "Minecraft allow list ($file)"
			if [[ ! -s $file ]]; then
				warn "nobody yet: box minecraft allow <gamertag>"
				return 0
			fi
			python3 -c '
import json, sys
for p in json.load(open(sys.argv[1])):
    print("  " + p.get("name", "?") + ("  (xuid " + p["xuid"] + ")" if p.get("xuid") else "  (not joined yet)"))' "$file"
			;;
		allow | deny)
			[[ -n ${1:-} ]] || die "usage: box minecraft $sub <gamertag>"
			minecraft_send "allowlist $([[ $sub == allow ]] && echo add || echo remove) \"$*\""
			if [[ $sub == allow ]]; then
				ok "$* may join (the account's gamertag, as shown in its Xbox profile)"
			else
				ok "$* may no longer join (box minecraft cmd kick \"$*\" to remove them now)"
			fi
			;;
		op | deop)
			[[ -n ${1:-} ]] || die "usage: box minecraft $sub <gamertag>"
			minecraft_send "$sub \"$*\""
			ok "$sub $* (operators may change game rules, teleport, give items)"
			;;
		cmd)
			[[ $# -gt 0 ]] || die "usage: box minecraft cmd <server command>  (e.g. say Dinner time!)"
			minecraft_send "$*"
			;;
		*) die "usage: box minecraft list | allow|deny <gamertag> | op|deop <gamertag> | cmd <command>" ;;
	esac
}

# minecraft_send COMMAND: type a command into the running server, then show
# what it answered (its output only goes to the server log).
minecraft_send() {
	local since
	since=$(date +%s)
	"$SRV" exec minecraft bedrock send-command "$1" >/dev/null ||
		die "the Minecraft server is not running here (srv status minecraft)"
	sleep 2
	journalctl -t minecraft --since "@$since" --no-pager -q -o cat 2>/dev/null |
		grep -v '^\s*$' | tail -n 5 | sed 's/^/  /' || true
}
