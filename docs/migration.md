# Migration from the old setup

How each service moves from the old containers to srv. The order of
operations across hosts (vega, then orion, then lyra) is in
[transition.md](transition.md); follow that, and use this page for the
per-service details.

The old setup (branches `docker`, `postfix`, `bind`... and the `manage`
script) keeps working while this happens: nothing here modifies it. Each
service moves on its own, and until `srv commit` the old containers are one
`srv rollback` away.

## What changes for a host

| Before                                  | After                                           |
|-----------------------------------------|-------------------------------------------------|
| `<data>/config` env file (containers)   | `<data>/configs/<host>.env` → `/etc/srv/host.env` (`srv` only) |
| custom debootstrap buster base          | official images / `debian:trixie-slim`          |
| supervisord + rsyslog per container     | one daemon per container, logs to journald      |
| `/var/log/docklog/*` (never rotated)    | journald, capped at 2 GB                        |
| `--link`                                | `srv-*` networks, names and aliases             |
| config baked into images, `sed` at start| rendered per release, mounted read-only         |

The old server-config file (`primary_dns`, `secondary_dns`, `*_rdns`...)
becomes two files: the inventory, shared by all hosts (machines, their
addresses and DNS names, `leader`, `web`), and one small file per host
(`host`, `services`, `data_dir`, `onion_name`...). Roles such as the DNS
master/slave, the replication targets and certificate renewal are derived
from `leader`.

## Testing a service on vega

**web**: `curl -k --resolve www.blunderer.org:443:<vega-ip> https://www.blunderer.org/`
and likewise for every site (download.libroxml.net/pool/..., 1000at8...). PHP
moves from 7.3 to 8.3: look for errors with `srv logs web php`. The PHP
extensions installed are in `services/web/image/php/Dockerfile`; the old image
also had imap, ldap, pgsql and mcrypt: add any a site needs.

**db**: vega has no legacy database, so its first deploy imports the newest
dump in `<data>/backups/mariadb` (made on orion by `dump-legacy`, see
transition.md). Check the sites that use the database.

**onion**: `srv logs onion`; the hostname in `<data>/keys/tor/<onion_name>/hostname`
must not change. Test with Tor Browser, and only on one host at a time.

**mail**: see "Testing" in [mail.md](mail.md): direct SMTP to vega,
then the headers in Gmail. vega must be in SPF and have an A record first
(transition.md, phase 1).

**dns**: vega is a slave of the leader: `dig @<vega-ip> blunderer.org SOA`,
`... MX`, `... TXT` must match orion's answers, and recursion is refused:
`dig @<vega-ip> example.com` → `REFUSED`.

**torrent**: run `sudo box keys new websso` on the leader (Google OAuth 2.0
Web client with redirect URI `https://auth.blunderer.org/oauth2/callback`), set
allowed Google account emails in `<data>/users/websso/torrent.blunderer.org`
(or `sso_emails` in `host.env`, seeded on `torrent` deploy), deploy `web` and
`torrent`, then open `https://torrent.blunderer.org` (or test with
`--resolve` against `<vega-ip>`).

## Each service's switch from the legacy containers

On a host still running the old stack, `srv deploy <svc>` stops the legacy
containers (`LEGACY=` in `service.env`), starts the new release, and
`srv rollback <svc>` starts the legacy ones again; `srv commit <svc>`
deletes them. Recommended order and what to know:

1. **dns**: replaces `mybind`. Check with dig from outside. The old lyra
   slave keeps transferring from the same address.
2. **db**: replaces `mymysql`. Deploy before **web** (rootless Podman's internal
   `srv-db.network` is isolated from Docker's networks, so the Podman `web` pod
   reaches Podman `srv-db` via `AddHost=mymysql`, not legacy Docker `mymysql`).
   Dumps it, imports into `mariadb-v2` (empty the first time), switches. Rolling
   back restarts `mymysql` on its untouched `<data>/mysql`. A later deploy from
   legacy moves an outdated `mariadb-v2` aside first.
3. **web**: replaces `mylighttpd` (once `db` is on Podman, `web` reaches
   `mymysql` over `srv-db.network`).
   Every lighttpd rule is carried over (`services/web/config/sites/` and
   `snippets/site.conf`): the HTTPS redirect, the per-host document roots,
   the `/pool` rewrites of the download sites, the Onion-Location headers,
   denied `~`/`.inc`/hidden files, `.pl`/`.fcgi` never sent as files, directory
   listings on the download/debian sites only, PHP with paths after the script (`/index.php/page`). Small
   differences: unmatched names (`mariage`, `cloud`...) also send the
   Onion-Location header; a query string on a `/pool` URL is passed as its own
   parameters instead of inside `path`; uploads are capped at 100 MB
   (`client_max_body_size` in `nginx.conf`). PHP goes from 7.3 to 8.3 with
   the extensions in `services/web/image/php/Dockerfile`: the old image also
   had imap, ldap, pgsql and mcrypt; add them there if a site needs one.
4. **torrent**: replaces `mytransmission`. Peer port 51413 is published; the
   Web UI is served over HTTPS at `https://torrent.blunderer.org` behind
   `web`'s Google SSO (`snippets/sso.conf`), never on host port 9091.
5. **onion**: replaces `mydarkhttpd`.
6. **mail**: replaces `mypostfix` and `myopendkim`. Mail arriving during the
   switch (seconds) is retried by the sender, or taken by the other MX.

`box setup` installs rootless Podman and does not disturb the old
containers; they keep running until `srv deploy <svc>` switches each service.
The old cron jobs (`crontab -l` for root and blunderer) are
replaced by `/etc/cron.d/srv`: remove them once every service is migrated
(transition.md says when). `/var/log/docklog` can be deleted then too.

## Files to check in the data folder

- `keys/ssl/blunderer.org/`: the certificate (`fullchain.crt`,
  `blunderer.org.key`), written by the old getssl until the leader runs `srv`,
  then by `ssl/renew.sh` (lego). The old per-service copies (`keys/postfix/ssl`,
  `keys/lighttpd/server.pem`) are no longer used.
- `keys/opendkim/<domain>/<selector>.private`: the keys named in `KeyTable` and
  `openarc.conf`, owned by uid 1000, mode 600.
- `users/postfix/{passwd,shadow,group}`: unchanged.
- `keys/websso/oauth2.cfg` (created with `box keys new websso`) and
  `users/websso/<domain>` (one allowlist per domain, e.g.
  `users/websso/torrent.blunderer.org` seeded on first `torrent` deploy).

## Not carried over

- `share.blunderer.org`: proxied to a port nothing listened on.
- OpenVPN: replaced by WireGuard (`vpn`, not enabled by default). Clients
  need the new configs from `<data>/wireguard/peer_<name>/`.
- The PTR lines of the blunderer.org zone: reverse DNS is served by your
  hosting provider, they had no effect in that zone. Set it there.
- `backup.lelong.xyz` is now a CNAME to `backup.blunderer.org` (same address).
