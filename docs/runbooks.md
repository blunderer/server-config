# Runbooks

Step by step for the common tasks and incidents. Commands run as root on the
host named at each step (`sudo -i`, or prefix `sudo`). The repository is in
`/opt/server-config`; "commit" means commit and push it from your laptop, then
`git pull` there on the hosts that need it.

Hosts: **orion** (leader), **lyra**, **vega**. Wherever this page says
orion or lyra, read "the leader" or "the other host" if the roles changed.

- [Mail](#mail): forwarding address, SMTP login
- [Websites](#websites): add a site or subdomain
- [Restore](#restore): files, database
- [Maintenance](#maintenance): websites to another host, leader handover,
  reboots and upgrades
- [Incidents](#incidents): a host died
- [Updates](#updates): images, Renovate, the first CI run

---

## Mail

### Forwarding addresses and who may send as them

Two tables in the data folder (not in git: they hold private addresses):

- `<data>/configs/mail/virtual`, the **forwarding** table: where mail to our
  addresses goes.
  ```
  contact@blunderer.org   you@gmail.com
  team@lelong.xyz         you@gmail.com, someone@example.com
  ```
- `<data>/configs/mail/senders`, the **senders** table: which SMTP login may
  send with which envelope sender (a whole domain with `@domain`). A
  logged-in client sending as an address its login does not own is refused.
  ```
  contact@blunderer.org   tristan
  @lelong.xyz             tristan
  alerts@blunderer.org    alerts
  ```

On the leader (orion):

```
box mail config
```

It opens the forwarding table in vim, then the senders table. Right after
each edit it checks that file and only then saves it:

- forwarding: each line has a destination; the address is `user@domain` or
  `@domain` in one of the `virtual_alias_domains`; no address twice;
- senders: each line has at least one login; every login exists
  (`box mail user list`); no address twice.

A bad edit is never saved: it shows the errors and offers to edit that file
again or to drop its changes (the other file is not affected). Each saved
change is shown as a diff, then `postfix reload` reads both tables again.
There is no `postmap` step: they are `texthash` maps, read directly by
postfix. Quitting without a change leaves a file as it is.

When you add a login, give it its addresses in the senders table; when you
forward a new address someone will also send as (Gmail's "Send mail as"),
list it there too. `box check` warns about a login that may send as
nothing.

Like the logins, the changes are **local**: the other mail hosts get the
tables with the nightly push and read them at the 06:00 reload; for now:
`box data push`, then `srv reload mail` there.

Test: send a mail to the address from an outside account, and follow it with
`box mail trace <address>`.

A new **domain** needs more: see "Adding a mail domain" in [mail.md](mail.md).

When a table is missing (a new data folder), `srv deploy mail` creates it:
the forwarding table empty, the senders table letting every login send as
any address of our domains. Narrow it to what each login needs.

### MariaDB's data directory belongs to another uid

MariaDB runs as uid 1000 (`User=1000` with `UserNS=keep-id` in `services/db/quadlet/srv-db.container`), the data
folder's owner. A data directory made when it ran as the image's `mysql`
user (999) must change owner once, while the database is stopped:

```
sudo srv stop db
sudo chown -R 1000:1000 /home/data/mariadb-v2
sudo srv deploy db          # the new release starts as 1000
sudo srv status db          # healthy, then:
sudo srv commit db          # the previous release ran as 999: no rollback to it
```

Until then, `srv deploy db` refuses (the prepare hook names the chown) and
`box check` warns that `mariadb-v2` is not owned by 1000. A rollback to a
release from before this change needs `chown -R 999:999` first.

### SMTP logins (sending through the server)

Logins live in the data folder, `<data>/users/postfix/{passwd,shadow,group}`,
read live by the `saslauthd` container. `box mail user` edits them in place
(same file, so the running container sees the change at once: no restart):

```
box mail user list                    # the accounts
box mail user add jane                # asks for the password (12+ characters)
box mail user add jane --random       # generates one and shows it once
box mail user passwd jane [--random]  # change it
box mail user del jane                # remove it
```

The change is **local**: it only edits this host's data folder and pushes
nothing. Do it on the leader (orion): its nightly push gives the other hosts
the same accounts, and replaces any change made directly on them (`box`
warns when you are not on the leader). To have it everywhere now:
`box data push` on the leader.

Then give it its addresses in the senders table (`box mail config`, second
file): without one, it can log in but every message is refused.

Give the login: server `mail0.blunderer.org`, port 587 (STARTTLS) or 465
(TLS), user `jane` (not `jane@...`), the password.

**The alerts and test account** is an ordinary login. `box mail user`
recognizes it from the host config: it is `alert_smtp_user` (default
`alerts`), and only when alerts are set up on this host (`alert_email` set).
For that account, and only for it, it also writes the password to
`<data>/keys/alerts/smtp_password`, the file msmtp reads (alerts,
`box mail test`, `box check`). On a host without `alert_email`, an account
called `alerts` is a login like any other and that file is left alone:

```
box mail user add alerts --random     # create it (what box alerts-account does)
box mail user passwd alerts --random  # rotate it: alerts keep working
```

Deleting it also deletes the password file, so alerts fail until it is added
again.

### An SMTP login is refused

0. **Follow the attempts:** `box mail trace jane --since -1hour` shows the
   SASL failures for the login name, with the client address.
1. **What postfix says:** `srv logs mail postfix | grep -i sasl`
   - `cannot connect to saslauthd server: Permission denied` (or `No such
     file`): postfix cannot reach saslauthd's socket. The `postfix` user must
     be in the `sasl` group in the mail image; check
     `srv exec mail postfix id postfix`, then redeploy.
   - `authentication failed` with no connection error: saslauthd answered
     "wrong credentials", so go to step 2.
2. **Ask saslauthd directly**, bypassing postfix and the mail client:
   ```
   srv exec mail saslauthd testsaslauthd -f /run/saslauthd/mux -u jane -p 'the-password' -s smtp
   ```
   `OK "Success."` means the account and password are right and the problem
   is the client (user name: `jane`, not `jane@...`; TLS required: port 587
   with STARTTLS or 465). `NO "authentication failed"` means the `shadow` line
   or the password is wrong. The password ends up in your shell history:
   prefix the command with a space, or change the password afterwards.
3. **Banned by fail2ban** after a few failed tries (connections refused or
   timing out, not rejected): `box ban why <your-ip>` shows the ban and the
   lines behind it, `box ban unban <your-ip>` lifts it, and
   `box ssh-trusted <your-ip>` keeps it from coming back.

---

## Websites

### Add a website or a subdomain

Example: `photos.blunderer.org` served from `/www/blunderer.org/photos`.

1. **Files**, on the leader:
   `mkdir -p /home/new-data/www/blunderer.org/photos` (owned by uid 1000:
   `chown -R 1000:1000 ...`). They reach the other hosts at night.
2. **DNS**: in `services/dns/config/zones/blunderer.org.zone`, next to the
   other website records:
   ```
   photos				IN A		@web_ip@
   ```
3. **nginx**: in `services/web/config/sites/10-sites.conf`, a server block:
   ```
   server {
   	listen 443 ssl;
   	listen [::]:443 ssl;
   	http2 on;
   	server_name ~^photos\.blunderer\.(org|net|fr)$;
   	root /www/blunderer.org/photos;
   	include /etc/nginx/snippets/site.conf;
   }
   ```
4. **Certificate**: nothing to do, the wildcard `*.blunderer.org` covers it.
   A new **domain** (not a subdomain) needs its zone with an
   `_acme-challenge` CNAME, and the domain and its wildcard in `ACME_DOMAINS`
   (`ssl/acme.conf`).
5. Commit, then on the leader:
   ```
   cd /opt/server-config && git pull
   srv deploy dns && srv commit dns
   dig +short photos.blunderer.org @ns1.blunderer.org     # the slaves have it
   ```
6. On the host serving the websites (`web=` in the inventory):
   `git pull && srv deploy web`, open https://photos.blunderer.org/, then
   `srv commit web`.

To remove a site: the same files in reverse; the certificate shrinks at the
next renewal.

---

## Restore

### Files

Every host keeps daily and weekly copies of its data folder in
`/home/backup` (hard links: cheap, complete trees):

```
/home/backup/new-data.today/       today's 04:00 copy
/home/backup/new-data.yesterday/
/home/backup/.new-data.1 ... .7/   one per weekday (1 = Monday)
/home/backup/.new-data.weekNN/     one per week (Wednesday's copy)
```

1. Find the version: `ls -l /home/backup/.new-data.*/www/blunderer.org/photos/`.
2. Copy it back **on the leader** (another host's restore would be replaced by
   the next night's replication):
   ```
   cp -a /home/backup/.new-data.3/www/blunderer.org/photos/img.jpg \
         /home/new-data/www/blunderer.org/photos/
   ```
3. If the leader lost its copies too, the same tree exists on lyra and vega
   (their copies include the leader's data as of the previous night): copy
   from there with `rsync -a <host>:/home/backup/...`.

### Database

The nightly dumps are in `<data>/backups/mariadb/<date>-nightly/` (and
`-pre-switch/` before every db deploy). To load one into the running
database, see "Backups" in [operations.md](operations.md). To start over from
a dump entirely:

```
srv stop db
mv /home/new-data/mariadb-v2 /home/new-data/mariadb-v2.broken-$(date +%F)
srv deploy db            # empty data directory: imports the newest dump
```

For a specific dump rather than the newest, move the newer ones aside first.

---

## Maintenance

### Move the websites to another host (short maintenance)

Only the website DNS records move. Mail needs nothing (the MX records already
fall back to the other host) and no data is copied: the destination must
already run web, db and onion with recent enough data.

1. Refresh the destination's database (`srv hook db dump --force` on the
   current `web` host, `box data push <dest>` on the leader, then
   `srv hook db import-newest` on `<dest>`), and pause jobs on every host:
   `box backups pause "maintenance on orion"`.
2. On the destination: `srv status` shows web, db, onion healthy.
3. On the leader: `box migrate orion lyra`. It probes lyra over HTTPS,
   asks you to confirm the two points above, sets `web=lyra`, deploys dns
   and waits until every slave serves the new address.
4. Wait 5 minutes (the zone TTL), check the sites, do the maintenance.
5. Back: on the leader `box migrate lyra orion`, then on every host
   `box backups resume`.

While paused, nothing is replicated. Anything written on the destination in
the meantime (database rows, uploads) is overwritten by the next night's
replication: copy it back to orion first if it matters.

If the maintenance is on the leader itself, it can be down: the slaves keep
answering for the zones for two weeks (SOA expire). For longer, hand over the
leader role.

### Hand over the leader role (planned)

The leader is the DNS master, replicates the data folder to the others and
renews the certificate.

1. On every host: `box backups pause`.
2. Make sure lyra has current data: on orion,
   `box data push lyra`.
3. On orion: `box leader lyra`. It sets `leader=lyra` in the inventory
   and copies it to every host.
4. On lyra: `srv deploy dns` (master), `box cron`.
5. On orion and vega: `srv deploy dns` (slaves), `box cron`.
6. On every host: `box audit` (no drift), then `box backups resume`.
7. If the websites should move too: `box migrate orion lyra` on lyra.

### Reboots, kernel and system upgrades

Packages are upgraded every night (`box upgrade`), never rebooting. When
a reboot is needed, the daily watch sends one email.

1. Pick a quiet moment. For the host serving the websites, either accept a
   minute of downtime or move them first (above).
2. `reboot`. Containers come back by themselves (`unless-stopped`); stopped
   rollback releases stay stopped.
3. `srv status` and `box check`.

**Docker upgrades** arrive with the nightly upgrade; `live-restore` keeps the
containers running while the engine restarts.

**Debian major upgrades** (e.g. trixie to the next release): on vega first,
following Debian's release notes. Then `box audit`: it flags the Docker
repository (its codename changes) and anything else to re-run.

---

## Incidents

### A host died

**lyra or vega died** (not the leader): nothing urgent. Mail goes to the
other MX, DNS is answered by the other servers. The leader's nightly
replication to it fails and sends an alert each night. When the host is back
(or replaced: [host-setup.md](host-setup.md)), the next replication brings
its data up to date; check with `srv status` and `box check`.

**orion died** (the leader, and usually the websites):

| What stops               | Effect                                           |
|--------------------------|--------------------------------------------------|
| websites (if `web=orion`)| down until moved                                 |
| DNS master               | slaves keep answering for two weeks              |
| mail0                    | lyra (mail1) receives the mail                   |
| replication, certificate | nothing new is copied; the certificate is valid for 30 days or more |

If orion is back within hours, waiting is often simplest. Otherwise, lyra
takes over from its own copy of the data (as of the last night). This needs
lyra's root ssh key accepted by vega and orion (host-setup.md, step 1): set
that up now, not during the incident.

Every host has the others in `/etc/hosts`, so names like `orion` and `lyra`
work below even with DNS impaired.

1. On lyra: `box leader --force lyra`, and answer yes to moving the
   websites. It sets `leader=lyra web=lyra` and copies the inventory to vega.
2. On lyra, as it prints:
   ```
   srv deploy dns                       # master
   # add web db onion to services= in lyra's host file
   srv deploy db                        # empty data directory: imports the newest dump
   srv deploy web; srv deploy onion
   box cron                        # replication, certificate renewal
   ```
3. On vega: `srv deploy dns`, `box cron`.
4. After 5 minutes, check the sites. Database writes since the last nightly
   dump (02:30) are lost.

**When orion comes back**, it still believes it is the leader, but it can no
longer push anything: lyra's and vega's inventories name lyra, so its
replication and certificate pushes are refused (and alert).

5. From lyra, give orion the current inventory:
   `rsync -a /home/new-data/configs/hosts.env blunderer@<orion-ip>:/home/new-data/configs/hosts.env`
6. On orion:
   ```
   srv stop web; srv stop db; srv stop onion     # lyra serves them now
   srv deploy dns                                # slave of lyra
   box cron
   box audit                                # no drift expected
   ```
   From the next night, lyra replicates its data to orion.
7. Later, to return to orion as leader and website host: after a night of
   replication, use the planned handover and `migrate` above.

---

## Updates

### Image updates

Tags like `nginx:stable-alpine` or `mariadb:11.4` move with security fixes;
every deploy picks up the newest. To refresh everything on a host:

```
srv pending all               # fetch and build, then list what changed per service
srv deploy <svc>              # those with something pending, one at a time; srv commit <svc>
```

### Renovate pull requests

Renovate opens a pull request when a pinned version moves (a major version,
the OpenARC release...). Major upgrades are labelled `test-on-vega`:

1. On vega: `git fetch && git checkout <the PR branch>`, `srv deploy <svc>`,
   test, `srv rollback <svc>` (or keep it), `git checkout srv`.
2. Merge the pull request; deploy on the other hosts as usual.

Renovate only runs once its GitHub app is installed on the repository
(https://github.com/apps/renovate): that is a one-time step in your GitHub
account.

### The first CI run

Pushing the `srv` branch runs `.github/workflows/ci.yml` (Actions tab):

| Job              | Checks                                                      |
|------------------|-------------------------------------------------------------|
| lint             | shellcheck, every service renders with the example host files |
| configs          | each daemon loads its rendered configuration: `named-checkconf`/`named-checkzone`, `nginx -t`, `postconf`, `opendkim`/`openarc -n`, `tor --verify-config`, the fail2ban filter |
| images           | the four local images build; a smoke test runs in each      |
| upstream-images  | the tools the healthchecks use exist in the third-party images |

The images have never been built before this run, so expect a first round of
fixes, most likely a Debian package name in `services/mail/image/mail`. Each
failure names the file and line; fix, commit, push. Before deploying a
service on vega, its jobs should be green.

### Migrating an existing srv Docker host to rootless Podman

1. Set `podman_storage_dir=/home/podman` in `host.env`.
2. Run `sudo box packages podman` (or `sudo box setup`) to install rootless
   Podman (`podman`, `crun`, `catatonit`, `aardvark-dns`, `uidmap`, `slirp4netns`, `passt`, `fuse-overlayfs`,
   `dbus-user-session`), configure subuids/subgids and lingering, sysctl
   (`ip_unprivileged_port_start=25`), `storage.conf`, Quadlet networks, and
   `box keys sync`.
3. Re-deploy each enabled service one at a time with `srv deploy <svc>`.
   Each deploy stops the old Docker Compose release, shifts service volume
   ownership for `UserNS=keep-id`, installs the Quadlet units, and waits for
   health (`srv rollback <svc>` shifts ownership back and restores the Docker
   release if needed).
4. Check `srv status` and `sudo box check`, then run `srv commit all` to drop
   the previous Docker releases and old Docker volumes.
5. Once every service runs cleanly on Podman and is committed, run
   `sudo box docker-remove` to remove the old Docker packages, configuration,
   storage, and networks, then verify with `sudo box audit`.
