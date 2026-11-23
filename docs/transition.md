# Transition plan: old stack → `srv`

Starting point: **orion** (leader, websites, DNS master, mail0) and **lyra**
(DNS slave, mail1, receives orion's data every night) run the old stack.
**vega** is new. Each phase leaves something that works, and every step can
be undone.

| Phase | orion          | lyra           | vega                         |
|-------|----------------|----------------|------------------------------|
| 1     | old            | old            | new: rehearsal, nothing public points to it |
| 2     | old → new      | old            | new: DNS slave, standby      |
| 3     | new (leader)   | old → new      | new                          |
| 4     | new            | new            | new, warm standby (gets the data nightly) |

Rules while both stacks run:

- **Only orion's old cron replicates** (to lyra). vega is never a replication
  source: it is not the leader (`leader=orion`), so `box` gives it no
  replication or certificate jobs.
- **Nothing public points to vega** until phase 2: it is in no NS, MX or
  website record (the old zones do not know it).
- **Old containers keep `/etc/server-config`**; `srv` uses `/etc/srv/host.env`.

## Phase 1: vega (rehearsal)

### 1. System

Minimal Debian and an admin user with an ssh key. Then the only manual
install, since `box` installs everything else later:

```
sudo apt-get install -y git rsync
```

At the hosting provider: reverse DNS of vega's address → `vega.blunderer.org`
(only needed for the mail test), firewall open for 222, 53, 80/443 (and
25/465/587 for the mail test).

### 2. A fresh dump on orion (old stack untouched)

```
# on orion
git clone -b srv https://github.com/blunderer/server-config.git /tmp/srv
sudo SRV_DATA=/home/new-data /tmp/srv/services/db/hooks/dump-legacy
```

It only runs the dump client in `mymysql` and writes
`/home/new-data/backups/mariadb/<date>-legacy/`.

### 3. Copy the data folder to vega

```
# on vega (sudo on orion, as orion's files are not all readable by blunderer)
sudo rsync -aHAX --numeric-ids --exclude=/mysql/ \
    --rsync-path="sudo rsync" blunderer@<orion-ip>:/home/new-data/ /home/new-data/
```

Torrent downloads are not needed for the test; create the folders instead:
`mkdir -p /home/torrent/{downloads,in_progress,torrent} && chown -R 1000:1000 /home/torrent`.

### 4. Inventory and host file

`/home/new-data/configs/hosts.env` (from `examples/example-hosts.env`): real
addresses, `hosts="orion lyra vega"`, `orion_names="ns0 mail0"`,
`lyra_names="ns1 mail1 backup"`, `vega_names=""`, **`leader=orion`**,
**`web=orion`**.

`/home/new-data/configs/vega.env` (from `examples/example.env`):

```
host=vega
services="dns db web torrent"              # mail and onion later, see below
data_dir=/home/new-data
volumes_dir=/home/volumes
podman_storage_dir=/home/podman
onion_name=<the real one>
alert_email=<you>
# alerts go through mail0.blunderer.org (the leader's mail name) by default
```

```
sudo git clone -b srv https://github.com/blunderer/server-config.git /opt/server-config
sudo mkdir -p /etc/srv && sudo ln -sf /home/new-data/configs/vega.env /etc/srv/host.env
```

### 5. Host setup

```
sudo /opt/server-config/box setup     # packages, podman, ssh 222, fail2ban, alerts, cron
# test `ssh -p 222` from another terminal, then:
sudo box ssh-confirm
```

Alerts go through orion's (old) postfix, which needs the alerts account:

```
sudo box alerts-account                     # on vega: adds it to vega's copy
# append the same lines to orion's files (the old postfix reads them live):
grep '^alerts:' /home/new-data/users/postfix/passwd   # -> append to orion's passwd
grep '^alerts:' /home/new-data/users/postfix/shadow   # -> append to orion's shadow
grep '^alerts:' /home/new-data/users/postfix/group    # -> append to orion's group
sudo box alert-test
```

Append (`>>`), do not replace those files on orion: the old container mounts
them file by file.

### 6. Deploy and test

```
srv deploy dns        # slave of orion's old bind (it allows transfers to anyone)
srv deploy db         # empty data directory: imports the dump from step 2
srv deploy web
srv deploy torrent
box check && box audit
```

Tests ([migration.md](migration.md), "Testing a service on vega"):

- **web**: every site with `curl -k --resolve <name>:443:<vega-ip> https://<name>/`,
  PHP 8.3 errors in `srv logs web php`, pages using the database.
- **dns as slave**: `dig @<vega-ip> blunderer.org SOA` matches orion.
- **dns as master** (the new templates): set `dns_role=master` in vega.env,
  `srv deploy dns`, compare `dig @<vega-ip>` and `dig @<orion-ip>` for every
  name of the four zones, then remove the line and `srv deploy dns` again
  (or `srv rollback dns`).
- **rollback drills**: deploy something, `srv rollback`, `srv rollback`,
  `srv commit`. Get used to them here.
- **onion**: not on vega for now. The same onion keys published by two hosts
  compete; test it during phase 2 instead.
- **mail**: later, when you are ready to touch orion's old zone once: add
  `vega IN A <vega-ip>` and `ip4:<vega-ip>` to the SPF record in the `bind`
  branch's blunderer.org zone and redeploy the old bind. Then add `mail` to
  vega's services and follow "Testing" in [mail.md](mail.md).

Nothing in phase 1 changes orion or lyra, except the appended alerts account
and, for the mail test, the old zone.

## Phase 2: orion in place

Once vega has passed its tests.

### 1. Install `srv` next to the old stack

On orion: inventory as on vega (it is the same file), `orion.env` with
`host=orion`, `services` for everything orion runs, `data_dir=/home/new-data`,
`volumes_dir=/home/volumes`, `podman_storage_dir=/home/podman`, then:

```
sudo mkdir -p /etc/srv && sudo ln -sf /home/new-data/configs/orion.env /etc/srv/host.env
sudo /opt/server-config/box backups pause "old cron still active"
sudo /opt/server-config/box setup
```

Pause first: orion is the leader, so `setup` installs replication and
certificate jobs, which must not run next to the old crontabs (`crontab -l`
for root and blunderer). `setup` configures rootless Podman with storage under
`podman_storage_dir`, leaving the old containers untouched.

### 2. Services, one at a time

`srv deploy`, check, `srv commit`, in this order:

1. **dns**: the new bind becomes the master. lyra's old bind keeps
   transferring from orion's address, so nothing changes for it. vega is
   notified too. From now on, the zones come from the new templates
   (the machine records include `vega`).
2. **db**, then **web**, **torrent** and **onion**: `db` dumps `mymysql`,
   imports into `mariadb-v2`, and switches (rolling back restarts `mymysql` on
   its untouched data). Because rootless Podman's `srv-db.network` is isolated
   from Docker, move `db` before `web` so the Podman `web` pod reaches
   `srv-db` as `mymysql` immediately (use `box migrate orion vega` beforehand
   if DB-backed sites must stay live during the switch). Then `web`, `torrent`
   and `onion` replace `mylighttpd`, `mytransmission` and `mydarkhttpd`.
3. **mail**: replaces `mypostfix` and `myopendkim`. Mail arriving during the
   switch is retried by senders, and lyra (mail1) takes it meanwhile.

Optional, for the web and db steps: move the websites to vega for the
duration (`box migrate orion vega`, once orion's dns is the new one).
vega's data must be fresh: repeat phase 1 steps 2 and 3 just before, and
mind that writes made on vega in the meantime are not copied back.

### 3. Hand over the jobs

When everything on orion runs on `srv`:

```
crontab -e -u root; crontab -e -u blunderer   # remove the old jobs
sudo box backups resume
sudo box audit                           # no drift expected
```

From now on orion replicates to **lyra and vega** every night, and renews the
certificate (challenges and certificate pushed to both).

## Phase 3: lyra in place

Its data folder already comes from orion (`hosts.env` included). `lyra.env`
with `host=lyra`, `services="dns web mail"` (web, db and onion make
it a standby for the websites; while the old stack still renews the
certificate, lyra's web also answers the Let's Encrypt challenges for
`mail1`, `ns1` and `backup`), then
`box setup` and, one at a time: **dns** (slave of orion), **web**,
**mail**. Remove lyra's old crontab jobs (`diff-backup`, `apt-get update`).

## Phase 4: cleanup

- `srv commit all` on each host (removes the legacy containers),
  `sudo box docker-remove` once legacy containers are gone (removes old Docker
  packages, storage, and networks), `rm -rf /var/log/docklog`, the old checkout
  and `/etc/server-config`.
- `box audit` on each host: no drift, nothing unexpected listening.
- vega now receives the data nightly: a warm standby for
  `box migrate orion vega` during maintenance, and the first place to
  test every upgrade (Renovate's `test-on-vega` pull requests).
