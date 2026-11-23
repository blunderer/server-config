# shellcheck shell=bash
# box keys: the long-lived keys of the services, the ones nothing renews by
# itself on a schedule: list them (each with an id and its age), add a new
# one (rotate), delete an old one by its id. Each command does the key
# operation only and shows what it made and where it goes (the TXT record
# and its zone file, the KeyTable lines): nothing is published or deployed
# here. The procedure around it is box keys help <type>.
#
# Types:
#   dkim    mail signing keys, per domain folder of opendkim's KeyTable; the
#           id is the selector (the file's name: mail, s202611...). rotate
#           adds a key under a new selector, delete removes one the KeyTable
#           no longer signs with. openarc seals with blunderer.org's DKIM key
#           (openarc.conf): it has none of its own.
#   srs     postsrsd's secrets; the id is the start of the secret's hash.
#           rotate adds a new one first (it signs; the others still verify
#           bounces), delete removes an old one once its 21 days are over.
#   acme    the Let's Encrypt account key (lego, keys/acme/lego/accounts):
#           it signs every request to Let's Encrypt. lego cannot roll it
#           over, so rotate sets the account aside and the next renewal
#           registers a new one; delete removes the old account by its id.
#   tsig    the DNS update keys: challenge (writes the _acme-challenge TXT
#           records into acme.blunderer.org, on the leader) and smtp
#           (smtp.blunderer.org, one per host): rotate replaces the secret.
#   ssl     the certificate's key: new with every renewal (ssl/renew.sh).
#   websso  Google SSO (<data>/keys/websso/oauth2.cfg): client (Google OAuth
#           client_id and client_secret) and cookie (signs browser sessions);
#           the id is the start of each secret's hash. new sets up oauth2.cfg,
#           rotate websso cookie|client replaces either secret.
#   dnssec  not yet: the zones are unsigned.
#
# Not here: login passwords (box mail user), ssh keys (box ssh-keys), the
# database password, the onion key (it is the address).

KEYS_ROW='  %-7s %-14s %-9s %-26s %s\n'   # type, name, id, age, state
# Suggested age before rotating, in days (box keys list marks older keys).
declare -gA KEYS_MAX_AGE=([dkim]=365 [srs]=365 [tsig]=365 [websso]=365 [ssl]=90 [acme]=730)
SRS_LIFETIME_DAYS=21
# How long after its last signature an old DKIM key (its DNS record, really)
# is still needed: mail in transit, held in queues or forwarded is verified
# days after it was signed.
DKIM_GRACE_DAYS=7


# keys_age_days FILE
keys_age_days() {
	local m
	m=$(stat -c %Y "$1" 2>/dev/null) || { echo "-"; return; }
	echo $((($(date +%s) - m) / 86400))
}

# keys_age_note TYPE FILE: "<n> days", with "rotate due" past the suggested age.
keys_age_note() {
	local d max=${KEYS_MAX_AGE[$1]:-0}
	d=$(keys_age_days "$2")
	[[ $d == - ]] && { echo "missing"; return; }
	if ((max > 0 && d > max)); then echo "$d days, rotate due (> $max)"; else echo "$d days"; fi
}

# keys_write FILE: stdin to FILE in place (same inode, so containers that
# mount the file see it), keeping its owner, group and mode; a new file gets
# the folder's owner and mode 600.
keys_write() {
	local f=$1 dir
	dir=$(dirname "$f")
	[[ ! -L $f ]] || { die "refusing to write through symlink $f"; return 1; }
	if [[ -e $f ]]; then
		[[ -f $f ]] || { die "refusing to write non-regular file $f"; return 1; }
		cat >"$f"
	else
		(umask 077 && set -C && cat >"$f")
		chown --reference="$dir" "$f"
	fi
}

# keys_pub FILE: the public key of a private key, base64 on one line.
keys_pub() { openssl pkey -in "$1" -pubout 2>/dev/null | grep -v -- ----- | tr -d '\n'; }

# --------------------------------------------------------------------- dkim

DKIM_KEYTABLE=services/mail/config/opendkim/KeyTable
OPENARC_CONF=services/mail/config/openarc/openarc.conf

# dkim_entries [DIR]: the KeyTable lines (of key folder DIR) as
# "NAME DOMAIN SELECTOR DIR FILE".
dkim_entries() {
	local name rest domain sel path
	while read -r name rest; do
		[[ -n $name && $name != \#* ]] || continue
		IFS=: read -r domain sel path <<<"$rest"
		path=${path#/keys/}
		[[ -z ${1:-} || ${path%%/*} == "$1" ]] || continue
		echo "$name $domain $sel ${path%%/*} ${path#*/}"
	done <"$REPO/$DKIM_KEYTABLE"
}

dkim_dirs() { dkim_entries | awk '{print $4}' | sort -u; }

# dkim_zone DOMAIN: the zone file holding DOMAIN (longest matching zone).
dkim_zone() {
	local z best=''
	for z in "$REPO"/services/dns/config/zones/*.zone; do
		z=${z##*/}
		z=${z%.zone}
		[[ $1 == "$z" || $1 == *".$z" ]] && ((${#z} > ${#best})) && best=$z
	done
	echo "$best"
}

# dkim_owner SELECTOR DOMAIN: the record's name, relative to its zone.
dkim_owner() {
	local zone sub
	zone=$(dkim_zone "$2")
	sub=${2%"$zone"}
	sub=${sub%.}
	echo "$1._domainkey${sub:+.$sub}"
}

# dkim_record OWNER PUBKEY: a zone line, the TXT split in 255-character strings.
dkim_record() {
	echo "$1		IN	TXT	( \"v=DKIM1; k=rsa; \" $(fold -w 250 <<<"p=$2" | sed 's/.*/"&"/' | xargs -d '\n') )"
}

# dkim_active_files DIR: the key files the KeyTable uses in folder DIR.
dkim_active_files() { dkim_entries "$1" | awk '{print $5}' | sort -u; }

# dkim_other_files DIR: key files of folder DIR the KeyTable does not use.
dkim_other_files() {
	local f active
	active=$(dkim_active_files "$1")
	for f in "$(keys_data)/keys/opendkim/$1/"*.private; do
		[[ -e $f ]] || continue
		grep -qxF "${f##*/}" <<<"$active" || echo "$f"
	done
}

# dkim_newest_active DIR: the modification time of the newest key signing.
dkim_newest_active() {
	local f m newest=0
	for f in $(dkim_active_files "$1"); do
		m=$(stat -c %Y "$(keys_data)/keys/opendkim/$1/$f" 2>/dev/null || echo 0)
		((m > newest)) && newest=$m
	done
	echo "$newest"
}

# dkim_published DIR FILE: yes when DNS serves FILE's key under its selector
# (the file's name) for every domain using folder DIR, else what is missing.
dkim_published() {
	local sel name domain missing=''
	sel=$(basename "$2" .private)
	while read -r name domain _ _ _; do
		[[ $(dig +short TXT "$sel._domainkey.$domain" 2>/dev/null | tr -d '" \n') == *"p=$(keys_pub "$2")"* ]] ||
			missing+=" $sel._domainkey.$domain"
	done < <(dkim_entries "$1")
	if [[ -z $missing ]]; then echo yes; else echo "no ($(xargs <<<"$missing"))"; fi
}

# dkim_delete_hint DIR ID: when a key that no longer signs can be deleted,
# from opendkim's log on this host (journald: "DKIM-Signature field added
# (s=<id>, d=<domain>)"): $DKIM_GRACE_DAYS days after its last signature.
dkim_delete_hint() {
	local dir=$1 id=$2 log last first now days domains
	domains=$(dkim_entries "$dir" | awk '{print $2}' | sort -u | paste -sd'|' | sed 's/\./\\./g')
	log=$(journalctl -t opendkim --since "-$((DKIM_GRACE_DAYS + 1))d" --no-pager -q -o short-unix 2>/dev/null |
		grep -E 'DKIM-Signature field added \(s=[^,]+, d=('"$domains"')\)' || true)
	if [[ -z $log ]]; then
		echo "no signature of this folder's domains in this host's log: check on a mail host"
		return
	fi
	now=$(date +%s)
	last=$(grep -F "(s=$id, " <<<"$log" | tail -n 1 | cut -d. -f1 | cut -d' ' -f1)
	if [[ -z $last ]]; then
		# Nothing signed with it in the log: safe only if the log covers the
		# whole period.
		first=$(head -n 1 <<<"$log" | cut -d. -f1 | cut -d' ' -f1)
		if ((first <= now - DKIM_GRACE_DAYS * 86400)); then
			echo "no signature here for $DKIM_GRACE_DAYS days: safe to delete (box keys delete dkim $dir $id)"
		else
			echo "no signature here since $(date -d "@$first" +%F), where this host's log starts: keep until $(date -d "@$((first + DKIM_GRACE_DAYS * 86400))" +%F)"
		fi
		return
	fi
	days=$(((now - last) / 86400))
	if ((days >= DKIM_GRACE_DAYS)); then
		echo "last signature here $days days ago: safe to delete (box keys delete dkim $dir $id)"
	else
		echo "last signature here $(date -d "@$last" '+%F %H:%M'): keep until $(date -d "@$((last + DKIM_GRACE_DAYS * 86400))" +%F)"
	fi
}

# dkim_arc_file: the key file openarc seals with, as FOLDER/FILE.
dkim_arc_file() { sed -n 's/^KeyFile *\/keys\///p' "$REPO/$OPENARC_CONF"; }

dkim_list() {
	local dir f state age
	for dir in $(dkim_dirs); do
		for f in "$(keys_data)/keys/opendkim/$dir/"*.private; do
			[[ -e $f ]] || continue
			if dkim_active_files "$dir" | grep -qxF "${f##*/}"; then
				state="signing"
			elif (($(stat -c %Y "$f") > $(dkim_newest_active "$dir"))); then
				state="new, not signing yet (in DNS: $(dkim_published "$dir" "$f"))"
			else
				state="no longer signing; $(dkim_delete_hint "$dir" "$(basename "$f" .private)")"
			fi
			[[ $(dkim_arc_file) == "$dir/${f##*/}" ]] && state+="; ARC seals with it"
			state+=$(keys_secret_status "$(keys_dkim_secret_name "$dir" "$(basename "$f" .private)")" "$f")
			# "rotate due" only makes sense for a key that signs.
			if [[ $state == signing* ]]; then age=$(keys_age_note dkim "$f"); else age="$(keys_age_days "$f") days"; fi
			# shellcheck disable=SC2059 # the row format
			printf "$KEYS_ROW" dkim "$dir" "$(basename "$f" .private)" "$age" "$state"
		done
	done
}

dkim_new_selector() {
	local dir=$1 base s c=''
	base=s$(date +%Y%m)
	for c in '' b c d e f; do
		s=$base$c
		[[ -e $(keys_data)/keys/opendkim/$dir/$s.private ]] || { echo "$s"; return; }
	done
	die "too many keys made this month in $dir"
}

dkim_rotate() {
	local dir=${1:?usage: box keys rotate dkim <folder> (box keys list)} sel file unused key_pem
	dkim_entries "$dir" | grep -q . || die "no KeyTable entry uses keys/opendkim/$dir (box keys list)"
	unused=$(dkim_other_files "$dir" | xargs -rn1 basename | sed 's/\.private$//' | xargs)
	[[ -z $unused ]] || warn "keys/opendkim/$dir already has key(s) the KeyTable does not use: $unused"
	sel=$(dkim_new_selector "$dir")
	file=$(keys_data)/keys/opendkim/$dir/$sel.private
	key_pem=$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null) || { die "openssl genpkey failed"; return 1; }
	[[ -n $key_pem ]] || { die "openssl genpkey produced empty key"; return 1; }
	printf '%s\n' "$key_pem" | keys_write "$file"
	ok "dkim $dir $sel: $file (2048 bits)"
	keys_auto_sync
	echo
	dkim_show "$dir" "$sel"
	echo
	echo "Procedure: box keys help dkim"
}

# dkim_show DIR ID: the records publishing key ID and the lines signing with
# it, each under the file it goes in.
dkim_show() {
	local dir=${1:?usage: box keys show dkim <folder> <id>} sel=${2:?usage: box keys show dkim <folder> <id> (box keys list)} file pub name domain old f
	file=$(keys_data)/keys/opendkim/$dir/$sel.private
	[[ -e $file ]] || die "no key $sel in keys/opendkim/$dir (box keys list)"
	pub=$(keys_pub "$file")
	echo "Records:"
	while read -r name domain _ _ _; do
		echo "  services/dns/config/zones/$(dkim_zone "$domain").zone"
		echo "    $(dkim_record "$(dkim_owner "$sel" "$domain")" "$pub")"
	done < <(dkim_entries "$dir")
	echo
	echo "Lines to sign with it (the first word is a label, the selector is the second field):"
	echo "  $DKIM_KEYTABLE"
	while read -r name domain old _ f; do
		if [[ $old == "$sel" ]]; then
			echo "    $name $domain:$sel:/keys/$dir/$sel.private      (in use)"
		else
			echo "    $name $domain:$sel:/keys/$dir/$sel.private"
			echo "      (now: $domain:$old:/keys/$dir/$f)"
		fi
	done < <(dkim_entries "$dir")
	if [[ $(dkim_arc_file) == "$dir/"* ]]; then
		echo "  $OPENARC_CONF"
		echo "    Selector                $sel"
		echo "    KeyFile                 /keys/$dir/$sel.private"
	fi
}

dkim_delete() {
	local dir=${1:?usage: box keys delete dkim <folder> <id>} id=${2:?usage: box keys delete dkim <folder> <id> (box keys list)} f name domain
	f=$(keys_data)/keys/opendkim/$dir/$id.private
	[[ -e $f ]] || die "no key $id in keys/opendkim/$dir (box keys list)"
	dkim_active_files "$dir" | grep -qxF "$id.private" &&
		die "the KeyTable signs with $id (box keys help dkim)"
	[[ $(dkim_arc_file) == "$dir/$id.private" ]] &&
		die "openarc seals with $id, $OPENARC_CONF (box keys help dkim)"
	echo "To delete: $f ($(keys_age_note dkim "$f"))"
	confirm "Delete this private key?" || die "nothing deleted"
	rm -f "$f"
	ok "dkim $dir $id: deleted"
	keys_auto_sync
	echo
	echo "Records to remove:"
	while read -r name domain _ _ _; do
		echo "  services/dns/config/zones/$(dkim_zone "$domain").zone"
		echo "    $(dkim_owner "$id" "$domain")"
	done < <(dkim_entries "$dir")
	echo
	echo "Procedure: box keys help dkim"
}

dkim_new() {
	local dir=${1:?usage: box keys new dkim <domain>} file key_pem
	file=$(keys_data)/keys/opendkim/$dir/mail.private
	[[ ! -e $file ]] || die "$file exists: box keys rotate dkim $dir"
	install -d -m 0700 "$(dirname "$file")"
	chown --reference="$(keys_data)/keys/opendkim" "$(dirname "$file")"
	key_pem=$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null) || { die "openssl genpkey failed"; return 1; }
	[[ -n $key_pem ]] || { die "openssl genpkey produced empty key"; return 1; }
	printf '%s\n' "$key_pem" | keys_write "$file"
	ok "dkim $dir mail: $file (2048 bits)"
	keys_auto_sync
	echo
	echo "Record to add:"
	echo "  the zone file of $dir (services/dns/config/zones/)"
	echo "    $(dkim_record mail._domainkey "$(keys_pub "$file")")"
	echo
	echo "Lines to add:"
	echo "  $DKIM_KEYTABLE"
	echo "    $dir $dir:mail:/keys/$dir/mail.private"
	echo "  services/mail/config/opendkim/SigningTable"
	echo "    *@$dir $dir"
	echo
	echo "Procedure: box keys help dkim"
}

# ---------------------------------------------------------------------- srs

srs_file() { echo "$(keys_data)/keys/postsrsd/postsrsd.secret"; }

# srs_id SECRET: a short id for a secret (the start of its hash).
srs_id() { printf '%s' "$1" | sha256sum | cut -c1-8; }

# shellcheck disable=SC2094 # keys_age_note only reads the file's time
srs_list() {
	local f line first=1 m hint
	f=$(srs_file)
	[[ -s $f ]] || return 0
	while IFS= read -r line; do
		[[ -n $line ]] || continue
		if ((first)); then
			# shellcheck disable=SC2059 # the row format
			printf "$KEYS_ROW" srs postsrsd "$(srs_id "$line")" "$(keys_age_note srs "$f")" "signing (the newest)$(keys_secret_status srv-srs-secret "$f")"
			first=0
		else
			# The file's time is the last rotation: the older secrets are
			# needed for the $SRS_LIFETIME_DAYS days an address rewritten before it lives.
			m=$(stat -c %Y "$f")
			if (($(keys_age_days "$f") >= SRS_LIFETIME_DAYS)); then
				hint="replaced $(keys_age_days "$f") days ago: safe to delete (box keys delete srs $(srs_id "$line"))"
			else
				hint="replaced $(date -d "@$m" +%F): keep until $(date -d "@$((m + SRS_LIFETIME_DAYS * 86400))" +%F)"
			fi
			# shellcheck disable=SC2059
			printf "$KEYS_ROW" srs postsrsd "$(srs_id "$line")" "older" "verifies only; $hint"
		fi
	done <"$f"
}

srs_rotate() {
	local f old
	f=$(srs_file)
	[[ -s $f ]] || die "no $f (srv deploy mail creates it)"
	old=$(cat "$f")
	{ head -c 24 /dev/urandom | base64; printf '%s\n' "$old"; } | keys_write "$f"
	ok "srs $(srs_id "$(head -n 1 "$f")"): first in $f, signs; $(srs_id "$(sed -n 2p "$f")") still verifies"
	keys_auto_sync
	echo "Procedure: box keys help srs"
}

srs_delete() {
	local id=${1:?usage: box keys delete srs <id> (box keys list)} f line kept='' found=0 n=0 d
	f=$(srs_file)
	[[ -s $f ]] || die "no $f (srv deploy mail creates it)"
	while IFS= read -r line; do
		[[ -n $line ]] || continue
		n=$((n + 1))
		if [[ $(srs_id "$line") == "$id" ]]; then
			((n > 1)) || die "$id is the secret that signs (box keys help srs)"
			found=1
		else
			kept+=$line$'\n'
		fi
	done <"$f"
	((found)) || die "no secret $id in $f (box keys list)"
	d=$(keys_age_days "$f")
	if ((d < SRS_LIFETIME_DAYS)); then
		warn "the newest secret is $d days old: bounces to addresses rewritten with $id, up to $SRS_LIFETIME_DAYS days old, would no longer be recognised"
	fi
	confirm "Delete secret $id?" || die "nothing changed"
	# Keep the file's time: it is when the signing secret came in (its age in
	# the list, and the countdown of any other old secret).
	local m
	m=$(stat -c %Y "$f")
	printf '%s' "$kept" | keys_write "$f"
	touch -d "@$m" "$f"
	ok "srs $id: deleted from $f"
	keys_auto_sync
	echo "Procedure: box keys help srs"
}

# --------------------------------------------------------------------- tsig

tsig_file() {
	case $1 in
		challenge) echo "$(keys_data)/keys/acme/tsig.key" ;;
		smtp) echo "$(keys_data)/keys/dns/smtp-tsig.key" ;;
		xfer) echo "$(keys_data)/keys/dns/xfer-tsig.key" ;;
		*) die "tsig keys: challenge, smtp or xfer" ;;
	esac
}

tsig_list() {
	local k f desc sname
	for k in challenge smtp xfer; do
		f=$(tsig_file "$k")
		[[ -e $f ]] || continue
		case $k in
			challenge) desc="writes the certificate's DNS challenges (acme.blunderer.org; the leader's)"; sname=srv-tsig-acme ;;
			smtp) desc="box smtp-health updates smtp.blunderer.org (this host's own)"; sname=srv-tsig-smtp ;;
			xfer) desc="signs master-to-slave zone transfers and NOTIFY (replicated from the leader)"; sname=srv-tsig-xfer ;;
		esac
		desc+=$(keys_secret_status "$sname" "$f")
		# shellcheck disable=SC2059 # the row format
		printf "$KEYS_ROW" tsig "$k" - "$(keys_age_note tsig "$f")" "$desc"
	done
}

tsig_rotate() {
	local k=${1:?usage: box keys rotate tsig challenge|smtp|xfer} f name staged
	f=$(tsig_file "$k")
	[[ -s $f ]] || die "no $f (srv deploy dns creates it)"
	name=$(sed -n 's/^key "\([^"]*\)".*/\1/p' "$f")
	printf 'key "%s" {\n\talgorithm hmac-sha256;\n\tsecret "%s";\n};\n' "$name" "$(head -c 32 /dev/urandom | base64)" | keys_write "$f"
	case $k in
		challenge) staged=/etc/srv/dns-keys/acme-tsig.key ;;
		smtp) staged=/etc/srv/dns-keys/smtp-tsig.key ;;
		xfer) staged=/etc/srv/dns-keys/xfer-tsig.key ;;
	esac
	if [[ -f ${SRV_STATE:-/srv/releases}/dns/current/compose.yml || -f ${SRV_STATE:-/srv/releases}/dns/previous/compose.yml ]]; then
		[[ ! -L $staged ]] || { die "refusing to write through symlink $staged"; return 1; }
		[[ ! -f $staged ]] || cat "$f" >"$staged"
	fi
	ok "tsig $k: new secret in $f"
	keys_auto_sync
	echo "Procedure: box keys help tsig"
}

# --------------------------------------------------------------------- acme

# acme_dir: lego's accounts for Let's Encrypt (<server>/<email>/, the key in
# keys/<email>.key, the account in account.json).
acme_dir() { echo "$(keys_data)/keys/acme/lego/accounts"; }

# acme_accounts: "DIR ID STATE" for each account folder: the one in use
# (<server>/<email>) and the ones set aside (<email>.retired-<id>).
acme_accounts() {
	local d key id
	for d in "$(acme_dir)"/*/*/; do
		[[ -d $d ]] || continue
		d=${d%/}
		key=$(find "$d/keys" -name '*.key' 2>/dev/null | head -n 1)
		[[ -n $key ]] || continue
		id=$(keys_pub "$key" | sha256sum | cut -c1-8)
		if [[ ${d##*/} == *.retired-* ]]; then echo "$d $id retired"; else echo "$d $id active"; fi
	done
}

# acme_uri DIR: the account's URL at Let's Encrypt (for a CAA accounturi).
acme_uri() { sed -n 's/.*"uri": *"\([^"]*\)".*/\1/p' "$1/account.json" 2>/dev/null | head -n 1; }

acme_list() {
	local d id st key
	while read -r d id st; do
		key=$(find "$d/keys" -name '*.key' | head -n 1)
		if [[ $st == active ]]; then
			# shellcheck disable=SC2059 # the row format
			printf "$KEYS_ROW" acme account "$id" "$(keys_age_note acme "$key")" "Let's Encrypt account in use ($(acme_uri "$d"))"
		else
			# shellcheck disable=SC2059
			printf "$KEYS_ROW" acme account "$id" "$(keys_age_note acme "$key")" "set aside (box keys delete acme $id, once a renewal worked)"
		fi
	done < <(acme_accounts)
}

acme_rotate() {
	local d id
	read -r d id _ < <(acme_accounts | awk '$3 == "active"')
	[[ -n ${d:-} ]] || die "no Let's Encrypt account in $(acme_dir): the first renewal creates one"
	mv "$d" "$d.retired-$id"
	ok "acme $id: set aside, $d.retired-$id"
	if grep -qs 'accounturi' "$REPO"/services/dns/config/zones/*.zone; then
		warn "the zones' CAA records name the account (accounturi): box keys help acme"
	fi
	echo "Procedure: box keys help acme"
}

acme_delete() {
	local id=${1:?usage: box keys delete acme <id> (box keys list)} d st
	read -r d _ st < <(acme_accounts | awk -v i="$id" '$2 == i')
	[[ -n ${d:-} ]] || die "no account $id (box keys list)"
	[[ $st == retired ]] || die "account $id is the one in use (box keys help acme)"
	acme_accounts | awk '$3 == "active"' | grep -q . ||
		die "no account in use yet: renew first (box keys help acme)"
	echo "To delete: $d"
	confirm "Delete this Let's Encrypt account's key?" || die "nothing deleted"
	rm -rf "$d"
	ok "acme $id: deleted"
	if grep -qs 'accounturi' "$REPO"/services/dns/config/zones/*.zone; then
		warn "the zones' CAA records may still name it (accounturi): box keys help acme"
	fi
	echo "Procedure: box keys help acme"
}

# ---------------------------------------------------------------------- ssl

ssl_list() {
	local d f crt end st
	d=$(get domain blunderer.org)
	f=$(keys_data)/keys/ssl/$d/$d.key
	crt=$(keys_data)/keys/ssl/$d/fullchain.crt
	end=$({ openssl x509 -noout -enddate -in "$crt" 2>/dev/null || true; } | cut -d= -f2)
	st=$(keys_secret_status srv-ssl-key "$f")
	[[ $st == "; podman secret ok" ]] && st=$(keys_secret_status srv-ssl-cert "$crt")
	# shellcheck disable=SC2059 # the row format
	printf "$KEYS_ROW" ssl "$d" - "$(keys_age_note ssl "$f")" "new key with each renewal; certificate until ${end:-?}${st}"
}

ssl_rotate() {
	echo "The certificate's key is not rotated here: every renewal makes a new one (box ssl-renew -f)."
	echo "Procedure: box keys help ssl"
}

# ------------------------------------------------------------------- websso

websso_file() { echo "$(keys_data)/keys/websso/oauth2.cfg"; }


websso_id() {
	if [[ -n $1 ]]; then srs_id "$1"; else printf '%s\n' "${2:--}"; fi
}

websso_gen_cookie() {
	head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n'
}

websso_trim() {
	local s=${1//$'\r'/}
	s=${s#"${s%%[![:space:]]*}"}
	s=${s%"${s##*[![:space:]]}"}
	printf '%s' "$s"
}

# websso_redirect_uris DOMAIN: print the primary and per-host OAuth callbacks.
websso_redirect_uris() {
	local domain=$1 h
	echo "https://auth.$domain/oauth2/callback"
	for h in $(get hosts ""); do
		echo "https://auth.$h.$domain/oauth2/callback"
	done
}

# websso_read_client [ARG_CLIENT_ID] [DEFAULT_CLIENT_ID]: sets WEBSSO_CID and
# WEBSSO_CSEC from the terminal (silent secret prompt, twice) or stdin.
websso_read_client() {
	local arg_cid=${1:-} def_cid=${2:-} domain uri cid='' csec='' csec2=''
	domain=$(get domain blunderer.org)
	if [[ -t 0 ]]; then
		echo "Google OAuth 2.0 Web application (https://console.cloud.google.com/apis/credentials):"
		echo "  Authorized redirect URIs:"
		while IFS= read -r uri; do echo "    $uri"; done < <(websso_redirect_uris "$domain")
		if [[ -n $arg_cid ]]; then
			cid=$arg_cid
		elif [[ -n $def_cid ]]; then
			read -r -p "  client_id [$def_cid]: " cid
			cid=${cid:-$def_cid}
		else
			read -r -p "  client_id: " cid
		fi
		read -r -s -p "  client_secret: " csec && echo
		read -r -s -p "  again: " csec2 && echo
		[[ $csec == "$csec2" ]] || die "the client secrets differ"
	else
		if [[ -n $arg_cid ]]; then
			cid=$arg_cid
		else
			IFS= read -r cid || true
			cid=${cid:-$def_cid}
		fi
		IFS= read -r csec || true
	fi
	WEBSSO_CID=$(websso_trim "$cid")
	WEBSSO_CSEC=$(websso_trim "$csec")
	[[ -n $WEBSSO_CID ]] || die "client_id cannot be empty"
	[[ -n $WEBSSO_CSEC ]] || die "client_secret cannot be empty"
	[[ $WEBSSO_CID != *[\"\\$'\n']* && $WEBSSO_CSEC != *[\"\\$'\n']* ]] ||
		die "client_id and client_secret must not contain quotes or backslashes"
}

websso_write_cfg() {
	local cid=$1 csec=$2 cookie=$3 f keys_dir users_dir domain
	domain=$(get domain blunderer.org)
	f=$(websso_file)
	keys_dir=$(dirname "$f")
	users_dir="$(keys_data)/users/websso"
	data_owner_init "$(keys_data)" "$(get data_owner "")"
	install -d -m 0700 -o 0 -g 0 "$keys_dir"
	mkdir_own "$users_dir"
	chmod 750 "$users_dir"
	cat <<-EOF | keys_write "$f"
		# Google OAuth 2.0 Web application credentials for https://auth.$domain
		# Managed by: box keys (see: box keys help websso)
		client_id = "$cid"
		client_secret = "$csec"
		cookie_secret = "$cookie"
	EOF
	chown 0:0 "$f"
	chmod 600 "$f"
}

websso_list() {
	local f cid csec cookie age cstate kstate
	f=$(websso_file)
	if [[ ! -e $f ]]; then
		[[ " $(get services '') " == *" web "* ]] || return 0
		# shellcheck disable=SC2059 # the row format
		printf "$KEYS_ROW" websso oauth2.cfg - missing "not set up yet (box keys new websso)"
		return 0
	fi
	age=$(keys_age_note websso "$f")
	cid=$(websso_val client_id "$f")
	csec=$(websso_val client_secret "$f")
	cookie=$(websso_val cookie_secret "$f")
	if [[ -n $cid && -n $csec ]]; then
		cstate="Google OAuth client (${cid%.apps.googleusercontent.com})$(keys_secret_status srv-websso-cfg "$f")"
	else
		cstate="incomplete: run box keys new websso"
	fi
	if [[ -n $cookie ]]; then
		kstate="signs browser sessions on .$(get domain blunderer.org)"
	else
		kstate="missing: run box keys rotate websso cookie"
	fi
	# shellcheck disable=SC2059 # the row format
	printf "$KEYS_ROW" websso client "$(websso_id "$csec" -)" "$age" "$cstate"
	# shellcheck disable=SC2059
	printf "$KEYS_ROW" websso cookie "$(websso_id "$cookie" -)" "$age" "$kstate"
}

websso_new() {
	local f cookie
	f=$(websso_file)
	if [[ -e $f && -n $(websso_val client_id "$f") && -n $(websso_val client_secret "$f") ]]; then
		die "$f is already configured: box keys rotate websso cookie|client"
	fi
	cookie=$(websso_val cookie_secret "$f")
	[[ -n $cookie ]] || cookie=$(websso_gen_cookie)
	websso_read_client "${1:-}" "$(websso_val client_id "$f")"
	websso_write_cfg "$WEBSSO_CID" "$WEBSSO_CSEC" "$cookie"
	ok "websso: $f (client $(srs_id "$WEBSSO_CSEC"), cookie $(srs_id "$cookie"))"
	keys_auto_sync
	echo "Procedure: box keys help websso"
}

websso_rotate() {
	local part=${1:?usage: box keys rotate websso cookie|client [<client_id>]} f cid csec cookie
	shift
	f=$(websso_file)
	cid=$(websso_val client_id "$f")
	csec=$(websso_val client_secret "$f")
	cookie=$(websso_val cookie_secret "$f")
	case $part in
		cookie)
			[[ -n $cid && -n $csec ]] || die "no Google OAuth client in $f yet: box keys new websso"
			cookie=$(websso_gen_cookie)
			websso_write_cfg "$cid" "$csec" "$cookie"
			ok "websso cookie $(srs_id "$cookie"): new cookie_secret in $f"
			keys_auto_sync
			echo "Procedure: box keys help websso"
			;;
		client)
			[[ -n $cookie ]] || cookie=$(websso_gen_cookie)
			websso_read_client "${1:-}" "$cid"
			websso_write_cfg "$WEBSSO_CID" "$WEBSSO_CSEC" "$cookie"
			ok "websso client $(srs_id "$WEBSSO_CSEC"): updated in $f"
			keys_auto_sync
			echo "Procedure: box keys help websso"
			;;
		*) die "websso keys: cookie or client (box keys help websso)" ;;
	esac
}

websso_show() {
	local domain f cid csec cookie users_dir u uri n found=0
	domain=$(get domain blunderer.org)
	f=$(websso_file)
	cid=$(websso_val client_id "$f")
	csec=$(websso_val client_secret "$f")
	cookie=$(websso_val cookie_secret "$f")
	users_dir="$(keys_data)/users/websso"
	echo "Credentials file:        $f"
	echo "Authorized redirect URIs:"
	while IFS= read -r uri; do echo "  $uri"; done < <(websso_redirect_uris "$domain")
	echo "client_id:               ${cid:-(not set)}"
	echo "client_secret id:        $(websso_id "$csec" "(not set)")"
	echo "cookie_secret id:        $(websso_id "$cookie" "(not set)")"
	echo "Per-domain allowlists:   $users_dir/<domain>"
	if [[ -d $users_dir ]]; then
		for u in "$users_dir"/*; do
			[[ -f $u ]] || continue
			case ${u##*/} in '' | .* | *~ | *.bak | *.old | *.orig | *.tmp | *.swp | *[!A-Za-z0-9.-]*) continue ;; esac
			n=$(grep -cE '^[[:space:]]*[^#[:space:]]' "$u" || true)
			echo "  ${u##*/}: $n account(s)"
			found=1
		done
	fi
	((found)) || echo "  (none yet)"
}

# ------------------------------------------------------------------ command

keys_usage() {
	cat <<-EOF
		usage: box keys [list]                      every key: type, name, id, age, state
		       box keys new dkim <domain> | websso [<client_id>]
		                                            a key for a new mail domain, or set up Google SSO
		       box keys rotate dkim <folder> | srs | acme | tsig challenge|smtp|xfer | websso cookie|client
		                                            add/replace a key (tsig/websso: replace it)
		       box keys delete dkim <folder> <id> | srs <id> | acme <id>
		                                            remove an old key, by its id
		       box keys show dkim <folder> <id> | websso
		                                            show a key's records/lines or Google SSO settings
		       box keys sync [--restart]            sync <data>/keys/* into Podman secrets
		                                            (--restart restarts running quadlets whose secret changed)
		       box keys help <type>                 the procedure: dkim srs acme tsig websso ssl dnssec
		new/rotate/delete automatically register or replace Podman secrets on
		this host when Podman is set up, and remind you which quadlet to restart.
		The steps around key operations are in the help.
	EOF
}

# keys_help TYPE: the procedure around the key operations of TYPE.
keys_help() {
	case ${1:-} in
		dkim)
			cat <<-EOF
				dkim: mail signing keys, in <data>/keys/opendkim/<folder>/<id>.private.
				The id is the selector: the name of the DNS record (<id>._domainkey.<domain>)
				and of the file. opendkim signs with the keys of its KeyTable; openarc seals
				with blunderer.org's key (openarc.conf): it has no key of its own.

				Rotating (on the leader):
				  1. box keys rotate dkim <folder>      a new key, a new id (sYYYYMM), and auto-synced secret
				  2. Add the records it shows to the zone files; commit; srv deploy dns.
				  3. box data push                      the key reaches the other mail hosts
				  4. When DNS serves it (box keys list: "in DNS: yes"), put the lines it
				     showed in the KeyTable (and openarc.conf for blunderer.org); commit;
				     srv deploy mail on every mail host (syncs Podman secrets and reloads/restarts
				     mail so the new secret is mounted in the quadlets). Mail is now signed with the new key.
				  5. $DKIM_GRACE_DAYS days later (mail signed with the old key is still being checked):
				     box keys delete dkim <folder> <old id>
				     box keys list says when: it reads opendkim's log on the host it runs
				     on ("keep until <date>", then "safe to delete"), counting from the old
				     key's last signature there. Every mail host signs: look on each
				     (remote all sudo box keys list) and go by the latest date.
				  6. Remove the records it shows from the zone files; commit; srv deploy
				     dns; box data push; srv deploy mail (drops the deleted secret on mail hosts).
				box keys show dkim <folder> <id> prints a key's records and lines again.

				A new mail domain: box keys new dkim <domain>, add the record and the
				lines it shows, then docs/mail.md, "Adding a mail domain".
			EOF
			;;
		srs)
			cat <<-EOF
				srs: postsrsd's secrets, one per line in <data>/keys/postsrsd/postsrsd.secret.
				The first signs the rewritten sender addresses; every line verifies the
				bounces coming back. The id is the start of the secret's hash.

				Rotating (on the leader):
				  1. box keys rotate srs                a new secret, first; auto-replaces Podman secret srv-srs-secret
				  2. srv restart mail                   restarts the mail quadlet here to mount the updated secret
				  3. box data push                      every mail host must share the file
				  4. On every other mail host: box keys sync --restart
				     (syncs srv-srs-secret and restarts mail so its quadlet sees the new secret)
				  5. $SRS_LIFETIME_DAYS days later (an SRS address lives that long):
				     box keys delete srs <old id>, then steps 2-4 again.
			EOF
			;;
		acme)
			cat <<-EOF
				acme: the Let's Encrypt account key, in <data>/keys/acme/lego/accounts/. It
				signs every request to Let's Encrypt (not the DNS challenge: that is
				"tsig challenge"). lego cannot change an account's key, so rotating means
				a new account.

				Rotating (on the leader):
				  1. box keys rotate acme               the account is set aside (.retired-<id>)
				  2. box ssl-renew -f                   lego registers a new account, with a
				     new key, and gets the certificate with it.
				     If it fails: rename the .retired-<id> folder back to put the old one in use.
				  3. box keys delete acme <old id>, then box data push.
				With a CAA accounturi in the zones (none today): add the new account's URL
				(box keys list, after step 2) next to the old one and srv deploy dns before
				step 2 can pass; remove the old URL after step 3.
			EOF
			;;
		tsig)
			cat <<-EOF
				tsig: the keys BIND authenticates DNS updates and zone transfers with.
				  challenge  <data>/keys/acme/tsig.key: the renewal writes the certificate's
				             _acme-challenge records into acme.blunderer.org. The leader's.
				  smtp       <data>/keys/dns/smtp-tsig.key: box smtp-health updates
				             smtp.blunderer.org. One per host, not replicated.
				  xfer       <data>/keys/dns/xfer-tsig.key: signs master-to-slave AXFR/IXFR
				             and NOTIFY packets. Created on the leader and replicated.

				Rotating: box keys rotate tsig challenge|smtp|xfer replaces the secret in the
				file, updates Podman secret srv-tsig-{acme|smtp|xfer} (and /etc/srv/dns-keys
				when present on this host). For challenge or smtp, restart dns so the
				quadlet mounts the new secret: srv restart dns. For xfer (on the leader):
				box data push, srv restart dns on the leader, then on every slave run
				box keys sync --restart (and srv deploy dns if zones/config changed).
			EOF
			;;
		ssl)
			cat <<-EOF
				ssl: the certificate's private key, <data>/keys/ssl/<domain>/<domain>.key.
				Every renewal makes a new one (cron, daily, when due: about every two
				months), installs it, runs box keys sync --restart to replace Podman secrets
				srv-ssl-cert/srv-ssl-key and restart web and mail (or reloads them on Docker),
				and pushes the certificate to peers (each peer runs box keys sync --restart).
				For a new key now, on the leader: box ssl-renew -f (Let's Encrypt allows 5
				identical certificates a week). Nothing to delete.
			EOF
			;;
		websso | sso)
			local d uri
			d=$(get domain blunderer.org)
			cat <<-EOF
				websso: Google SSO secrets for oauth2-proxy on auth.$d (and auth.<host>.$d),
				stored in <data>/keys/websso/oauth2.cfg (mode 0600, uid 1000).
				Per-domain user allowlists live in <data>/users/websso/<fqdn>; run
				srv reload web after editing one. Each <sub>.$d file also covers
				<sub>.<host>.$d unless a per-host <sub>.<host>.$d file exists.

				Setting up (on the leader):
				  1. Google Cloud Console -> APIs & Services -> Credentials -> Create OAuth client ID:
				     Application type: Web application
				     Authorized redirect URIs:
			EOF
			while IFS= read -r uri; do echo "       $uri"; done < <(websso_redirect_uris "$d")
			cat <<-EOF
				  2. box keys new websso [<client_id>]  prompts for client_id and client_secret,
				                                        generates cookie_secret, and registers srv-websso-cfg
				  3. box data push                      copies oauth2.cfg to the other hosts
				  4. srv deploy web                     syncs secrets and starts oauth2-proxy on auth.$d

				Rotating cookie_secret (logs users out on .${d}):
				  1. box keys rotate websso cookie      updates oauth2.cfg and replaces Podman secret srv-websso-cfg
				  2. srv restart web                    restarts the web quadlet here to mount the updated secret
				  3. box data push                      pushes oauth2.cfg to the other hosts
				  4. box keys sync --restart            on every other host running web

				Rotating the Google OAuth client_secret:
				  1. In Google Cloud Console, add a new client secret (keep the old one active)
				  2. box keys rotate websso client      updates oauth2.cfg and replaces Podman secret srv-websso-cfg
				  3. srv restart web                    restarts the web quadlet here
				  4. box data push, then box keys sync --restart on every other host running web
				  5. Disable and delete the old client secret in Google Cloud Console
			EOF
			;;
		dnssec)
			echo "dnssec: not enabled, the zones are unsigned. Signing keys would rotate the same way: rotate (new key, DS at the registrar), delete <id>."
			;;
		*) keys_usage ;;
	esac
}

cmd_keys() {
	need_root
	need_env
	local action=${1:-list} type=${2:-}
	shift 2 2>/dev/null || shift $#
	case $action in
		list)
			local KEYS_EXISTING_SECRETS=""
			# shellcheck disable=SC2034 # read by keys_secret_status in lib/secrets.sh
			keys_has_podman && KEYS_EXISTING_SECRETS=$(keys_podman_existing)
			say "keys (suggested ages: dkim, srs, tsig, websso ${KEYS_MAX_AGE[dkim]} days; ssl renews itself)"
			# shellcheck disable=SC2059 # the row format
			printf "$KEYS_ROW" TYPE NAME ID AGE STATE
			dkim_list
			srs_list
			acme_list
			tsig_list
			websso_list
			ssl_list
			# shellcheck disable=SC2059
			printf "$KEYS_ROW" dnssec - - - "not enabled: the zones are unsigned"
			;;
		new)
			case $type in
				dkim) dkim_new "$@" ;;
				websso | sso) websso_new "$@" ;;
				*) die "box keys new: dkim <domain> or websso [<client_id>]" ;;
			esac
			;;
		rotate)
			case $type in
				dkim) dkim_rotate "$@" ;;
				srs) srs_rotate ;;
				acme) acme_rotate ;;
				tsig) tsig_rotate "$@" ;;
				websso | sso) websso_rotate "$@" ;;
				ssl) ssl_rotate ;;
				dnssec) die "DNSSEC is not enabled (the zones are unsigned)" ;;
				*) keys_usage; return 1 ;;
			esac
			;;
		show)
			case $type in
				dkim) dkim_show "$@" ;;
				websso | sso) websso_show ;;
				*) die "box keys show: dkim <folder> <id> or websso" ;;
			esac
			;;
		delete)
			case $type in
				dkim) dkim_delete "$@" ;;
				srs) srs_delete "$@" ;;
				acme) acme_delete "$@" ;;
				tsig | ssl | websso | sso) die "$type keys are replaced by rotate: nothing to delete" ;;
				*) keys_usage; return 1 ;;
			esac
			;;
		sync)
			local sync_args=()
			[[ -n $type ]] && sync_args+=("$type")
			sync_args+=("$@")
			keys_podman_sync "${sync_args[@]}"
			;;
		help | -h | --help) keys_help "$type" ;;
		*) keys_usage; return 1 ;;
	esac
}
