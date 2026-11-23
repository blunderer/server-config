# Operations

All commands run as root on the host (`sudo srv ...`). `srv help` lists them.
Step-by-step procedures for common tasks and incidents (forwarding
addresses, SMTP logins, websites, restores, maintenance, a host dying) are in
[runbooks.md](runbooks.md).
Step-by-step procedures (mail addresses, websites, restores, maintenance,
incidents) are in [runbooks.md](runbooks.md).

## Update a service

```
cd /opt/server-config && git pull
srv pending web     # optional: what would change (config diff, images replaced)
srv deploy web
```

`deploy` always pulls the newest image for each tag (`nginx:stable-alpine`,
`mariadb:11.4`...) and rebuilds local images from a refreshed base, so the
same command applies a configuration change and security updates. Then:

- it works: `srv commit web`
- it does not: `srv rollback web`
- you answered no at "Switch web?": `srv` offers to remove the new release
  right away (its containers, the images built for it, its folder). If you
  kept it, or a deploy failed half-way (build, create, a hook), remove the
  leftovers later with `srv discard web` (`srv discard all` for every
  service; or name releases: `srv discard web 20261106-090000`). It never
  touches the current or previous release, and keeps the older release
  folders `srv diff` uses.

`srv deploy all` walks every service of the host in dependency order and asks
before each switch. `srv -y ...` answers yes to everything (useful in cron,
not recommended for major upgrades).

Major versions (MariaDB, PHP, BIND, Debian base) are changed in
`quadlet/*.container`/Dockerfiles. Renovate opens a pull request for them, labelled
`test-on-vega`: deploy that branch on vega first.

## See what runs

```
srv status
SERVICE    CURRENT           PREVIOUS          CONTAINERS
dns        20261104-093000   -                 bind:running/healthy
mail       20261104-101500   20261028-211500   postfix:running/healthy opendkim:running/healthy ...
web        legacy            -                 mylighttpd:running
```

`srv stats [svc...]` shows CPU, memory (against its limit), network, disk
and processes per container of the current releases, live (Ctrl-c to
quit); `--no-stream` prints one sample. It follows the containers running
when it starts: after a deploy, run it again.

## Logs, shells, one-off commands

```
srv logs mail                       # follow all mail containers
srv logs mail postfix --since 1h    # filter one container by time
srv shell mail postfix              # interactive shell
srv exec mail postfix postqueue -p  # one command
srv exec db mariadb mariadb -uroot -p
journalctl CONTAINER_TAG=postfix --since today
```

## On another host: `remote`

`remote <host|all> [sudo] box|srv <arguments...>` runs a box or srv command
on another host of the inventory, over the ssh set up by `box ssh-keys`
(works for root and the admin account), as if typed there:

```
remote orion srv status
remote orion sudo srv deploy dns          # asks its questions here
remote all sudo box -q check              # every other host in turn
remote lyra sudo box mail spam --since -2d | less
```

With a terminal, the remote command gets one too: prompts, sudo's password
and colours work, and output and errors arrive together. In a pipe or a
script, input, output and errors stay separate streams and the exit status
is the remote command's; sudo then must not need a password. `all` skips
this host and returns the last failure. Anything other than box and srv:
`ssh <host>`.

## Configuration changes

Edit the templates in `services/<svc>/config`, commit, `srv deploy <svc>`.
`srv pending <svc>` shows what a deploy would change: the configuration
diff between the running release and what the repository and host values
render now, which images would be replaced (it pulls and builds them,
starting nothing), and which files were changed inside the running
containers: those are lost on deploy, since the new release gets new
containers (volumes and mounted paths are kept). Anything listed there
that matters belongs in the repository or the data folder. After a deploy, `srv diff <svc>` shows what changed
between the previous and the current release, as rendered on this host. `srv render <svc>` renders to a temporary
directory without deploying.

To reload without a new release (e.g. after a certificate renewal or editing `<data>/users/websso/<domain>`):
`srv reload web mail`.

## Certificates

`ssl/renew.sh` (leader, daily at 05:00) runs lego, from its image, for one
certificate covering every domain and its wildcard (`ACME_DOMAINS` in
`ssl/acme.conf`), plus `*.<host>.blunderer.org` for every host in `hosts=`.
lego renews only when due: it follows the certificate's
lifetime and Let's Encrypt's renewal information (ARI), so the daily run is
usually a no-op. The new certificate goes to `<data>/keys/ssl/blunderer.org/`,
then to the other hosts; every host reloads web and mail daily at 06:00.
`box ssl-renew -f` renews now (on the leader; without `-f`, only when due),
with the output on the terminal and in the journal.

Validation is DNS-01 on our own name servers, so it needs no web server and
no other host:

- each domain's zone has `_acme-challenge CNAME <domain>.acme.blunderer.org.`;
- `acme.blunderer.org` is a separate zone on the DNS master, delegated to the
  same name servers, the only one updated dynamically (the rendered zones
  never change behind `srv`'s back). Only TXT records below it can be updated,
  and only with the TSIG key in `<data>/keys/acme/tsig.key`, which
  `srv deploy dns` creates;
- lego adds the TXT record through the local master, waits until every name
  server serves it (NOTIFY makes that seconds), and Let's Encrypt checks it.

It works once `srv`'s dns is the public master (phase 2 of the migration):
until then, the zones on the internet have no `acme` delegation and the old
getssl keeps renewing.

A subdomain needs nothing (the DNS and certificate wildcards cover
`<sub>.blunderer.org` and `<sub>.<host>.blunderer.org`). A new domain:
its zone with the `_acme-challenge` CNAME, and `<domain> *.<domain>` in
`ACME_DOMAINS`, then `box ssl-renew -f`.

Later: Let's Encrypt is working on DNS-PERSIST-01, a validation with one
fixed TXT record (`_validation-persist.<domain>`) and no update at renewal.
It would replace the acme zone and the TSIG key with a line in each zone
template; lego already has `--dns-persist`. Not available yet (late 2026).

Every zone has CAA records allowing only Let's Encrypt, through the DNS
challenge only (`issue` and `issuewild "letsencrypt.org;
validationmethods=dns-01"`): no other authority issues for the domains, and
a compromised web site cannot obtain a certificate with an HTTP challenge.
They do not name the account (`accounturi`): its key sits next to the
challenge key on the leader, so it would add little, and each account
rotation would need the records changed first. A new mail or web domain's
zone needs the same two lines.

## Keys

`box keys` (on the leader, unless said otherwise) handles the long-lived
keys, the ones nothing renews on a schedule. Each command does the key
operation only and shows what it made and where it goes: for a DKIM key,
the TXT records under their zone files and the KeyTable (and
`openarc.conf`) lines; `box keys show dkim <folder> <id>` prints them
again. Nothing is published or deployed by it. The procedure around each
type (what to commit, push and deploy, and when to delete the old key) is
`box keys help <type>`.

| Type | Key | Rotation |
|------|-----|----------|
| `dkim <folder>` | `keys/opendkim/<folder>/<id>.private`; the id is the selector (`mail`, `s202611`) | `rotate` adds a key under a new selector (publish, push, switch the KeyTable, deploy); `delete dkim <folder> <id>` removes one the KeyTable and openarc no longer use, and lists its records to remove. openarc seals with blunderer.org's DKIM key: it has no key of its own |
| `srs` | `keys/postsrsd/postsrsd.secret`, one secret per line; the id is the start of its hash | `rotate` adds a new one first (it signs, the others still verify); `delete srs <id>` an old one, after 21 days |
| `acme` | the Let's Encrypt account key, `keys/acme/lego/accounts/…`; the id is the start of its hash | `rotate` sets the account aside, the forced renewal it prints registers a new one; `delete acme <id>` removes the old account |
| `tsig challenge`, `tsig smtp` | `keys/acme/tsig.key` (writes the certificate's DNS challenges), `keys/dns/smtp-tsig.key` (box smtp-health, per host) | one step, then `box keys sync --restart` |
| `ssl` | `keys/ssl/<domain>/<domain>.key` | new with every renewal (`ssl/renew.sh` runs `box keys sync --restart`); `rotate` prints the forced renewal |
| `websso` | `keys/websso/oauth2.cfg` (`client` and `cookie`); the id is the start of each secret's hash | `new websso` sets Google's `client_id` + `client_secret` and generates `cookie_secret`; `rotate websso cookie|client` replaces either (`box data push`, `box keys sync --restart`) |
| `dnssec` | – | not enabled: the zones are unsigned |

```
box keys                          # each key: type, name, id, age ("rotate due" past a year), state
box keys rotate dkim lelong.xyz   # a new key (s202611), and the steps to put it in use
box keys delete dkim lelong.xyz mail   # once the KeyTable signs with s202611
box keys help dkim                # the whole rotation, step by step
box keys new dkim example.org     # a key for a new mail domain
box keys new websso               # set up Google SSO client credentials + cookie secret
box keys rotate websso cookie     # rotate the Google SSO session cookie secret
box keys sync --restart           # update Podman secrets and restart affected services
```

Not handled here: login passwords (`box mail user`), ssh keys (`box
ssh-keys`), the database password, the onion key (it is
the onion address).

## Backups

| When (cron)  | What                                                         |
|--------------|--------------------------------------------------------------|
| 02:30        | `srv hook db dump`: consistent dump to `<data>/backups/mariadb` |
| 03:00 leader | `box data push`: data folder to the other hosts              |
| 04:00        | `backup/diff-backup.sh`: daily/weekly hard-linked copies to `/home/backup` |

Live database files are excluded from both copies: restore from the dumps
(`10-users.sql`, `20-data.sql.gz`). Per-host state (`transmission/`,
`wireguard/`, `minecraft/`) is not replicated (`backup_exclude`).

Restore a dump into the running database:

```
d=<data>/backups/mariadb/<dump>
srv exec db mariadb sh -c 'exec mariadb -uroot -p"$(cat /run/secrets/root_password)"' < $d/10-users.sql
zcat $d/20-data.sql.gz | srv exec db mariadb sh -c 'exec mariadb -uroot -p"$(cat /run/secrets/root_password)"'
```

## Day-to-day tools

| Command | What it shows or does |
|---------|-----------------------|
| `box mail trace <address\|queue-id\|message-id> [--since TIME]` | Every mail log line (postfix, OpenDKIM, OpenARC, postsrsd, saslauthd) of the matching messages, in order, then what became of each: sent (with the receiving server's answer), deferred, bounced or rejected. Rejections before queueing (`NOQUEUE`) and failed SMTP logins are included. Default: the last 24 hours |
| `box mail test [ADDRESS]` | Sends a message through 587 with the alerts account (SMTP AUTH, STARTTLS) to ADDRESS (default `alert_email`) and traces it to delivery. In the received copy, `Authentication-Results` should read `dkim=pass`, `spf=pass`, `dmarc=pass` |
| `box mail spam [--since TIME] [--min SCORE] [--all]` | The messages rspamd scored as spam, oldest first: time, score, what it did (`add header` while only tagging, `reject` once `spam_reject` is set), sender, recipient, client address and the rules that weighed most. Default: the last 7 days (`--since -7d`; also `-12h`, `yesterday`, a date), from score 6 (`X-Spam-Status: Yes`); `--all` lists every scanned message |
| `box mail config` | Edits the forwarding table, then the senders table, in vim; each is checked right after its edit and saved, then `postfix reload` (docs/runbooks.md) |
| `box mail user list\|add\|passwd\|del` | The SMTP logins, local to this host's data folder (docs/runbooks.md, "SMTP logins") |
| `box dns show NAME [TYPE...]` | Every name server's answer side by side: each host of the inventory asked directly (authoritative only), the zone's NS records, and a public resolver (what the world sees); then the SOA serials. Types default to A, AAAA, MX and TXT; a bare name gets the domain appended (`box dns show _dmarc TXT`) |
| `box tls [HOST[:PORT]]` | The certificate a client gets: subject, names, issuer, expiry, protocol and cipher, and whether it verifies for the name asked. Without an argument: this host on 443, 465 and 587 (STARTTLS), over IPv4 and IPv6 separately. Flags Let's Encrypt staging certificates |
| `box ban list` / `unban ADDR` / `why ADDR` | fail2ban: the bans per jail; lifting one from every jail; the ban history of an address and its failed ssh and SMTP logins of the last week. `box ssh-trusted ADDR` keeps an address from being banned again |

Each one replaces a sequence of commands typed during an incident: `trace` the
`journalctl \| grep` rounds per test message, `dns show` the `dig @...` per
server, `tls` the `openssl s_client` per port and address family.

## How far is a host from a fresh install: `box distdeb`

After years of upgrades (vega went from stretch to trixie), a host collects
files and packages a fresh Debian would not have. `box distdeb` lists them,
leaving out what is normal on any Debian host (generated files, caches,
host identity, enabled-unit links), what `box` installs, and everything in
`/home`:

| Section | What it finds | What to do |
|---------|---------------|------------|
| unowned files | files in `/etc`, `/usr`, `/opt` no package owns: copied configs, scripts in `/usr/local`, leftovers of removed software | move to `/root/cruft/`, delete after a while |
| changed config files | package config files that differ from the package's version (`dpkg --verify`, plus `/etc/ssh/sshd_config` against `/usr/share/openssh/sshd_config`) | keep if intended; `apt install --reinstall -o Dpkg::Options::=--force-confask <pkg>` offers the stock one (for `sshd_config`, copy `/usr/share/openssh/sshd_config` and register with `ucf`) |
| upgrade leftovers | `*.dpkg-old/dist/new`, `*.ucf-*`, `*.bak`, `*.old`, `*.orig`, `*~`, `*.bullseye`… in `/etc` (not box's own `.bak` copies); packages removed with their config left; deprecated or invalid `sshd` settings (`sshd -t`) | merge `.dpkg-dist` if wanted, delete; `dpkg --purge` the packages; reset legacy `sshd_config` / remove obsolete host keys |
| packages | obsolete ones (in no repository), installed from outside Debian (besides Docker), marked manual beyond a minimal install and box's set | `apt-mark auto <pkg>`, then `apt autoremove --purge` |
| kernels and modules | `/lib/modules/<version>` of kernels no longer installed, dkms modules | delete |
| apt sources and keys | an old one-line `sources.list` (trixie: `apt modernize-sources`), extra sources, the apt-key era keyring, extra keys | remove what no longer serves |
| started on their own | cron jobs no package owns, user crontabs, `rc.local` | remove the old ones |

It only reports, and changes nothing. `--all` shows full lists (40 lines
per section otherwise). `box audit` covers the rest: listening ports,
enabled services, accounts.

## Troubleshooting

- **A deploy is unhealthy**: `srv logs <svc>`, then `srv rollback <svc>`. Check
  container output with `srv logs <svc>` (or `podman logs <container>` under
  the Podman user).
- **Port already in use on deploy**: a host process or leftover container
  holds it (`ss -tulpn`, `podman ps` under the Podman user, or `docker ps`
  while migrating). If it is an old Docker container, add it to `LEGACY=` in
  `service.env`.
- **Disk**: `journalctl --disk-usage` (journal, 2 GB cap), `podman system df`
  (under the Podman user; `docker system df` before `box docker-remove`).
  `srv commit` removes unused images and prints the before/after usage.
  Uncommitted services keep their previous images: commit or roll back to
  reclaim them.
- **Host env typo**: every `srv` command reports the missing `@name@` and the
  file it appears in; nothing is deployed.
