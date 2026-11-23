#!/usr/bin/env bash
# Renew the Let's Encrypt certificate (cron, daily, on the leader).
#
# lego proves control of each domain with a DNS-01 challenge: it adds a TXT
# record to the dynamic acme.blunderer.org zone of the local DNS master (each
# domain's _acme-challenge is a CNAME into it), signed with the TSIG key in
# <data>/keys/acme/tsig.key, and waits until every name server serves it. No
# web server, port 80 or other host is involved.
#
# lego keeps its account and certificates in <data>/keys/acme/lego and decides
# when to renew (from the certificate's lifetime and Let's Encrypt's renewal
# information, ARI); a daily run is a no-op until then. The certificate is
# then installed in <data>/keys/ssl/blunderer.org/ (what nginx and postfix
# read), copied to the other hosts, and web and mail are reloaded here; the
# other hosts reload daily from cron.
#
# usage: renew.sh [-f]     (-f: renew now, even if not due)
set -euo pipefail

if command -v flock >/dev/null 2>&1; then
	_lock_dir=${SRV_LOCK_DIR:-/run/lock}
	mkdir -p "$_lock_dir" 2>/dev/null || _lock_dir=/tmp
	exec 9>"$_lock_dir/srv-ssl-renew.lock"
	flock -n 9 || { echo "renew.sh is already running" >&2; exit 1; }
fi

here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
srv=${SRV:-srv}
# shellcheck source=ssl/acme.conf
. "$here/acme.conf"
# shellcheck source=lib/runtime.sh
. "$here/../lib/runtime.sh"

data=$("$srv" get data_dir /home/data)
[[ $("$srv" get dns_role slave) == master ]] ||
	{ echo "this host is not the DNS master: renew the certificate on the leader" >&2; exit 1; }

key="$data/keys/acme/tsig.key"
state="$data/keys/acme/lego"
domain=blunderer.org
target="$data/keys/ssl/$domain"
[[ -s $key ]] || { echo "missing $key: srv deploy dns creates it" >&2; exit 1; }
secret=$(sed -n 's/.*secret "\([^"]*\)".*/\1/p' "$key")
[[ -n $secret ]] || { echo "no secret in $key" >&2; exit 1; }
install -d -m 0700 -o 0 -g 0 "$data/keys/acme" "$data/keys/ssl" "$state" "$target"

args=()
for arg in "$@"; do
	case $arg in
		-f) args+=(--renew-force) ;;
		*) args+=("$arg") ;;
	esac
done
# read -a, not an unquoted loop: "*.blunderer.org" must not glob.
read -ra names <<<"$ACME_DOMAINS"
for h in $("$srv" get hosts); do
	[[ " ${names[*]} " == *" *.$h.$domain "* ]] || names+=("*.$h.$domain")
done
domains=()
for d in "${names[@]}"; do domains+=(-d "$d"); done

# Stage $state (which is root:root 0700) into a temporary directory owned by
# unix_role so rootless Podman can run lego without giving unix_role permanent
# access to /home/data/keys/acme.
pu=$("$srv" get unix_role)
stage=''
envfile=''
# shellcheck disable=SC2317,SC2329 # invoked via EXIT trap
cleanup() {
	rm -f "$envfile"
	[[ -z $stage ]] || rm -rf "$stage"
}
trap cleanup EXIT

stage=$(mktemp -d)
cp -a "$state/." "$stage/" 2>/dev/null || true
chown -R "$pu:$(id -gn "$pu")" "$stage"
chmod 0700 "$stage"
envfile=$(mktemp "$stage/.lego-env.XXXXXX")
chown "$pu:$(id -gn "$pu")" "$envfile"
cat >"$envfile" <<-ENV
	DNSUPDATE_NAMESERVER=127.0.0.1:53
	DNSUPDATE_TSIG_KEY=acme-update
	DNSUPDATE_TSIG_ALGORITHM=hmac-sha256.
	DNSUPDATE_TSIG_SECRET=$secret
	DNSUPDATE_PROPAGATION_TIMEOUT=300s
ENV
chmod 600 "$envfile"

# Host network: lego reaches the DNS master on 127.0.0.1 and resolves the
# other name servers like this host does.
SRV_PODMAN_USER="$pu" \
	rt_podman run --rm --network host --env-file "$envfile" -v "$stage:/data" "$LEGO_IMAGE" \
	run --accept-tos --email "$ACME_EMAIL" --path /data \
	--dns dnsupdate --key-type "$ACME_KEY_TYPE" "${domains[@]}" "${args[@]}"
rm -f "$envfile"
rsync -a --delete "$stage/" "$state/"
rm -rf "$stage"
stage=''

# Keep lego state strictly root-only (0700 dirs, 0600 files).
chown -R 0:0 "$state"
find "$state" -type d -exec chmod 0700 {} +
find "$state" -type f -exec chmod 0600 {} +

# Install what lego holds if it differs from what the services read
# (<name>.crt includes the issuer chain).
crt="$state/certificates/$domain.crt"
[[ -s $crt ]] || { echo "lego wrote no certificate at $crt" >&2; exit 1; }
changed=no
if ! cmp -s "$crt" "$target/fullchain.crt" || ! cmp -s "$state/certificates/$domain.key" "$target/$domain.key"; then
	install -m 0600 -o 0 -g 0 "$crt" "$target/fullchain.crt"
	install -m 0600 -o 0 -g 0 "$state/certificates/$domain.key" "$target/$domain.key"
	changed=yes
	echo "installed the new certificate in $target ($(openssl x509 -noout -enddate -in "$target/fullchain.crt" 2>/dev/null || echo 'expiry unknown'))"
fi

# Other hosts receive the renewed certificate via the daily data-push
# replication and pick it up on their daily 06:00 reload cron job.
rc=0
if [[ $changed == yes ]]; then
	"$here/../box" keys sync --restart || rc=1
fi
exit "$rc"
