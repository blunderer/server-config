#!/usr/bin/env bash
#
# Load every rendered configuration in the daemon that reads it, inside the
# real images, using the example host files (examples/example*.env) with orion
# as the leader and lyra as a slave. Catches what `srv check` cannot: a
# directive BIND, nginx, postfix, OpenDKIM, OpenARC, PostSRSd, rspamd or tor
# rejects.
#
# Needs Docker or Podman (`CONTAINER_ENGINE=podman|docker`) and openssl. Runs in
# CI (.github/workflows/ci.yml) and works on a host or laptop:
#   ci/validate-configs.sh [check...]
# Checks: dns nginx sso postfix opendkim openarc postsrsd rspamd unbound tor fail2ban tmux
set -uo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export SRV_HOSTS_ENV=$ROOT/examples/example-hosts.env
ENGINE=${CONTAINER_ENGINE:-$(command -v docker >/dev/null 2>&1 && echo docker || echo podman)}
FAILED=()

say() { printf '\n==> %s\n' "$*"; }
pass() { printf '    ok: %s\n' "$*"; }
failed() { printf '    FAILED: %s\n' "$*"; FAILED+=("$1"); }

# render HOST SVC: the service as that host would deploy it -> $WORK/HOST-SVC
render() {
	local host=$1 svc=$2
	[[ -d $WORK/$host-$svc ]] && return 0
	sed "s/^host=orion/host=$host/" "$ROOT/examples/example.env" >"$WORK/$host.env"
	SRV_HOST_ENV=$WORK/$host.env "$ROOT/srv" render "$svc" "$WORK/$host-$svc" >/dev/null
}

# local_image NAME DIR: build one of the repository's images once.
local_image() {
	local name=$1 dir=$2
	"$ENGINE" image inspect "$name" >/dev/null 2>&1 ||
		"$ENGINE" build -q -t "$name" "$ROOT/$dir" >/dev/null
}

# Test keys: a self-signed certificate and DKIM keys for every active selector.
keys() {
	[[ -d $WORK/keys ]] && return 0
	local rel
	mkdir -p "$WORK/keys/ssl/blunderer.org" "$WORK/keys/postsrsd"
	openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=blunderer.org \
		-keyout "$WORK/keys/ssl/blunderer.org/blunderer.org.key" \
		-out "$WORK/keys/ssl/blunderer.org/fullchain.crt" 2>/dev/null
	while read -r rel; do
		[[ -n $rel ]] || continue
		mkdir -p "$(dirname "$WORK/$rel")"
		openssl genrsa -out "$WORK/$rel" 2048 2>/dev/null
	done < <(
		# shellcheck source=services/mail/hooks/requirements.sh
		. "$ROOT/services/mail/hooks/requirements.sh"
		# shellcheck disable=SC2119 # no-arg call lists all services
		service_requirements
	)
	head -c 24 /dev/urandom | base64 >"$WORK/keys/postsrsd/postsrsd.secret"
	chmod -R a+rX "$WORK/keys"
	# The milters run as uid 1000 and require "safe" keys: owned by that uid,
	# not readable by anyone else (RequireSafeKeys).
	chown -R 1000:1000 "$WORK/keys/opendkim"
	find "$WORK/keys/opendkim" -name '*.private' -exec chmod 600 {} +
}

check_dns() {
	say "dns: named-checkconf, zones loaded (master: orion, slave: lyra)"
	render orion dns && render lyra dns
	local image
	image=$(sed -n 's/^[[:space:]]*Image=//p' "$WORK/orion-dns/quadlet/srv-dns.container" | head -n 1)
	# What hooks/prepare provides on a host: the TSIG keys and the initial
	# dynamic zones in /var/lib/bind (acme. on the master, smtp.blunderer.org
	# on every host).
	mkdir -p "$WORK/dns-lib"
	local k
	for k in acme smtp; do
		printf 'key "%s-update" {\n\talgorithm hmac-sha256;\n\tsecret "%s";\n};\n' \
			"$k" "$(head -c 32 /dev/urandom | base64)" >"$WORK/$k-tsig.key"
	done
	printf 'key "xfer-tsig" {\n\talgorithm hmac-sha256;\n\tsecret "%s";\n};\n' \
		"$(head -c 32 /dev/urandom | base64)" >"$WORK/xfer-tsig.key"
	cp "$WORK/orion-dns/config/acme.blunderer.org.zone" "$WORK/orion-dns/config/smtp.blunderer.org.zone" "$WORK/dns-lib/"
	chmod -R a+rX "$WORK/dns-lib" "$WORK/acme-tsig.key" "$WORK/smtp-tsig.key" "$WORK/xfer-tsig.key"
	if "$ENGINE" run --rm -v "$WORK/orion-dns/config:/etc/bind:ro" \
		-v "$WORK/acme-tsig.key:/etc/srv/acme-tsig.key:ro" -v "$WORK/smtp-tsig.key:/etc/srv/smtp-tsig.key:ro" \
		-v "$WORK/xfer-tsig.key:/etc/srv/xfer-tsig.key:ro" \
		-v "$WORK/dns-lib:/var/lib/bind:ro" \
		--entrypoint named-checkconf "$image" -z /etc/bind/named.conf; then
		pass "master configuration, the four zones, acme. and smtp.blunderer.org"
	else
		failed dns-master
	fi
	if "$ENGINE" run --rm -v "$WORK/lyra-dns/config:/etc/bind:ro" \
		-v "$WORK/acme-tsig.key:/etc/srv/acme-tsig.key:ro" -v "$WORK/smtp-tsig.key:/etc/srv/smtp-tsig.key:ro" \
		-v "$WORK/xfer-tsig.key:/etc/srv/xfer-tsig.key:ro" \
		-v "$WORK/dns-lib:/var/lib/bind:ro" \
		--entrypoint named-checkconf "$image" -z /etc/bind/named.conf; then
		pass "slave configuration, its own smtp.blunderer.org"
	else
		failed dns-slave
	fi
}

check_nginx() {
	say "web: nginx -t"
	render orion web && keys
	local image
	image=$(sed -n 's/^[[:space:]]*Image=//p' "$WORK/orion-web/quadlet/srv-web-nginx.container" | head -n 1)
	mkdir -p "$WORK/websso-users"
	printf '# comment\ntristan@blunderer.org\ntristan+tag@gmail.com\n' >"$WORK/websso-users/torrent.blunderer.org"
	printf 'friend@gmail.com\n' >"$WORK/websso-users/jellyfin.blunderer.org"
	chmod -R a+rX "$WORK/websso-users"
	if "$ENGINE" run --rm \
		-v "$WORK/orion-web/config/nginx.conf:/etc/nginx/nginx.conf:ro" \
		-v "$WORK/orion-web/config/sites:/etc/nginx/sites:ro" \
		-v "$WORK/orion-web/config/snippets:/etc/nginx/snippets:ro" \
		-v "$WORK/orion-web/config/entrypoint.d/60-srv-websso-map.sh:/docker-entrypoint.d/60-srv-websso-map.sh:ro" \
		-v "$WORK/websso-users:/users/websso:ro" \
		-v "$WORK/keys/ssl:/keys/ssl:ro" --tmpfs /run/onion \
		--entrypoint sh "$image" -c '/docker-entrypoint.d/60-srv-websso-map.sh && nginx -t'; then
		pass "nginx configuration"
	else
		failed nginx
	fi
}

check_sso() {
	say "web: oauth2-proxy --config-test"
	render orion web
	local image secret
	image=$(sed -n 's/^[[:space:]]*Image=//p' "$WORK/orion-web/quadlet/srv-web-oauth2-proxy.container" | head -n 1)
	secret=$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')
	mkdir -p "$WORK/sso-keys"
	cat >"$WORK/sso-keys/oauth2.cfg" <<-EOF
		client_id = "ci-client.apps.googleusercontent.com"
		client_secret = "ci-secret"
		cookie_secret = "$secret"
	EOF
	chown -R 1000:1000 "$WORK/sso-keys"
	chmod 700 "$WORK/sso-keys"
	chmod 600 "$WORK/sso-keys/oauth2.cfg"
	local -a args=()
	read -ra args < <(sed -n 's/^[[:space:]]*Exec=//p' "$WORK/orion-web/quadlet/srv-web-oauth2-proxy.container" | head -n 1)
	if "$ENGINE" run --rm --user 1000:1000 \
		-v "$WORK/sso-keys:/etc/oauth2-proxy:ro" \
		"$image" "${args[@]}" --config-test; then
		pass "oauth2-proxy configuration"
	else
		failed sso
	fi
}

check_postfix() {
	say "mail: postconf (no unknown or unused parameters), postfix check"
	render orion mail && keys && local_image srv-ci/mail services/mail/image/mail
	if "$ENGINE" run --rm \
		-v "$WORK/orion-mail/config/postfix:/etc/srv/postfix:ro" \
		-v "$WORK/keys/ssl:/keys/ssl:ro" \
		-v "$ROOT/examples/virtual:/etc/srv/mail/virtual:ro" \
		-v "$ROOT/examples/senders:/etc/srv/mail/senders:ro" \
		--entrypoint sh srv-ci/mail -c '
			set -e
			cp -R /etc/srv/postfix/. /etc/postfix/
			postconf -n >/dev/null 2>/tmp/warn
			postconf -M >/dev/null 2>>/tmp/warn
			if [ -s /tmp/warn ]; then cat /tmp/warn; exit 1; fi
			postmap -s texthash:/etc/srv/mail/virtual >/dev/null
			postmap -s texthash:/etc/srv/mail/senders >/dev/null
			postfix check'; then
		pass "main.cf and master.cf"
	else
		failed postfix
	fi
}

check_opendkim() {
	say "mail: opendkim -n"
	render orion mail && keys && local_image srv-ci/mail services/mail/image/mail
	if "$ENGINE" run --rm --user 1000:1000 \
		-v "$WORK/orion-mail/config/opendkim:/etc/srv/opendkim:ro" \
		-v "$WORK/keys/opendkim:/keys:ro" \
		--entrypoint opendkim srv-ci/mail -n -x /etc/srv/opendkim/opendkim.conf; then
		pass "opendkim.conf"
	else
		failed opendkim
	fi
}

check_openarc() {
	say "mail: openarc -n"
	render orion mail && keys && local_image srv-ci/openarc services/mail/image/openarc
	if "$ENGINE" run --rm --user 1000:1000 \
		-v "$WORK/orion-mail/config/openarc:/etc/srv/openarc:ro" \
		-v "$WORK/keys/opendkim:/keys:ro" \
		--entrypoint openarc srv-ci/openarc -n -c /etc/srv/openarc/openarc.conf; then
		pass "openarc.conf"
	else
		failed openarc
	fi
}

check_postsrsd() {
	say "mail: postsrsd starts with its configuration (and is version 2.x)"
	render orion mail && keys && local_image srv-ci/mail services/mail/image/mail
	local rc=0
	"$ENGINE" run --rm \
		-v "$WORK/orion-mail/config/postsrsd.conf:/etc/srv/postsrsd.conf:ro" \
		-v "$WORK/keys/postsrsd/postsrsd.secret:/etc/srv/postsrsd.secret:ro" \
		--entrypoint timeout srv-ci/mail 5 postsrsd -C /etc/srv/postsrsd.conf || rc=$?
	# 124: still running when the timeout stopped it, i.e. it started fine.
	if [[ $rc == 124 ]]; then
		pass "postsrsd.conf"
	else
		failed postsrsd
	fi
}

check_rspamd() {
	say "mail: rspamadm configtest (tag only, and with spam_reject set)"
	render orion mail && local_image srv-ci/mail services/mail/image/mail
	local tagged=$WORK/orion-mail/config/rspamd rejecting=$WORK/rspamd-reject
	cp -R "$tagged" "$rejecting"
	sed -i 's/^reject = null;/reject = 15;/' "$rejecting/actions.conf"
	local d ok=1
	for d in "$tagged" "$rejecting"; do
		"$ENGINE" run --rm -v "$d:/etc/rspamd/local.d:ro" --entrypoint rspamadm srv-ci/mail configtest || ok=0
	done
	if [[ $ok == 1 ]]; then
		pass "rspamd local.d"
	else
		failed rspamd
	fi
}

check_unbound() {
	say "mail: unbound-checkconf (the mail containers' resolver)"
	render orion mail && local_image srv-ci/resolver services/mail/image/resolver
	if "$ENGINE" run --rm \
		-v "$WORK/orion-mail/config/unbound.conf:/etc/srv/unbound.conf:ro" \
		--entrypoint sh srv-ci/resolver -c '
			cp /usr/share/dns/root.key /var/lib/unbound/root.key &&
			unbound-checkconf /etc/srv/unbound.conf'; then
		pass "unbound.conf"
	else
		failed unbound
	fi
}

check_tor() {
	say "onion: tor --verify-config"
	render orion onion && local_image srv-ci/onion services/onion/image
	if "$ENGINE" run --rm \
		-v "$WORK/orion-onion/config/torrc:/etc/tor/torrc:ro" \
		--entrypoint tor srv-ci/onion --verify-config -f /etc/tor/torrc; then
		pass "torrc"
	else
		failed tor
	fi
}

check_fail2ban() {
	say "host: fail2ban filter and jails"
	command -v fail2ban-regex >/dev/null || { echo "    skipped: fail2ban is not installed here"; return 0; }
	local line out
	line='Nov  4 10:00:00 mail0 postfix/submission/smtpd[123]: warning: unknown[203.0.113.5]: SASL LOGIN authentication failed: UGFzc3dvcmQ6'
	out=$(fail2ban-regex "$line" "$ROOT/host/fail2ban/filter.d/srv-postfix-sasl.conf" 2>&1)
	if grep -qE 'Lines: 1 lines, 0 ignored, 1 matched' <<<"$out"; then
		pass "srv-postfix-sasl matches a failed SMTP AUTH"
	else
		echo "$out"
		failed fail2ban-filter
	fi
	if command -v fail2ban-client >/dev/null && [[ -d /etc/fail2ban ]]; then
		local f2b="$WORK/fail2ban"
		cp -a /etc/fail2ban "$f2b"
		mkdir -p "$f2b/filter.d" "$f2b/jail.d"
		cp "$ROOT/host/fail2ban/jail.local" "$f2b/jail.local"
		cp "$ROOT/host/fail2ban/filter.d/srv-postfix-sasl.conf" "$f2b/filter.d/"
		printf '[sshd]\nport = 22,222\n' >"$f2b/jail.d/srv-sshd.local"
		if fail2ban-client -c "$f2b" -t; then pass "jail.local"; else failed fail2ban-jails; fi
	fi
}

check_tmux() {
	say "host: /etc/tmux.conf loads"
	command -v tmux >/dev/null || { echo "    skipped: tmux is not installed here"; return 0; }
	local out
	if out=$(tmux -f "$ROOT/host/tmux/tmux.conf" -L srv-ci new-session -d \; show -g prefix \; kill-server 2>&1) &&
		[[ $out == "prefix C-s" ]]; then
		pass "tmux.conf (prefix C-s)"
	else
		echo "$out"
		failed tmux
	fi
}

ALL=(dns nginx sso postfix opendkim openarc postsrsd rspamd unbound tor fail2ban tmux)
[[ $# -gt 0 ]] || set -- "${ALL[@]}"
for c in "$@"; do
	[[ " ${ALL[*]} " == *" $c "* ]] || { echo "unknown check '$c' (${ALL[*]})"; exit 2; }
	"check_$c"
done

echo
if [[ ${#FAILED[@]} -gt 0 ]]; then
	echo "FAILED: ${FAILED[*]}"
	exit 1
fi
echo "all configurations load"
