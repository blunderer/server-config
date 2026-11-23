# Setting up a host

For a new host, such as vega, the test server. The existing hosts follow
the same steps during the transition (see [transition.md](transition.md)).

## 1. System

- A minimal Debian stable install (no desktop, no extra tasks), with
  `git` to fetch this repository. `box` installs everything else,
  rootless Podman included (from Debian's own repositories).
- An admin user with sudo and an SSH key, uid 1000, named by `unix_role` in
  the inventory (default `blunderer`). The hosts reach each other
  (replication, certificates, takeover: docs/runbooks.md, "A host died")
  with one key pair per host kept in the data folder, set up by
  `box ssh-keys` (below). Root never logs in over ssh.
- In the hosting provider's firewall, if any: TCP 222 for ssh (keep 22 until
  `box ssh-confirm`), plus the service ports (53, 25/465/587, 80/443,
  51413, 51820/udp, 19132/tcp, 19132-19133/udp, 19140-19155/udp for the services the host runs).

## 2. Repository and data

```
sudo apt-get install -y git rsync               # the only manual install: box does the rest
sudo git clone -b srv https://github.com/blunderer/server-config.git /opt/server-config
```

The data folder comes from a host that has it. Nothing is set up on the new
host yet (no inventory, no key the others trust), so the first copy uses
**your own ssh login**. From the new host, logged in with `ssh -A` (your
key, forwarded):

```
cd /opt/server-config
sudo --preserve-env=SSH_AUTH_SOCK ./box data pull --from blunderer.org -n   # dry run
sudo --preserve-env=SSH_AUTH_SOCK ./box data pull --from blunderer.org
sudo ./box link                                 # then section 4
```

`--from [USER@]ADDRESS[:PORT]` takes any name or address of a host with the
data folder. It logs in as the account that ran sudo (the admin account;
else `USER@`), on port 22 or 222, whichever answers (else `:PORT`), with
your agent's key, or a password asked on the terminal if that host's sshd
allows passwords. It copies to `/home/data` (`--data-dir DIR` for another
path, the same on both sides), keeps the owners' numbers, and refuses a
data folder that already has files unless `--force`. It needs neither the
inventory nor `box link`.

The other way round, a push from the leader, once the new host is in the
inventory (section 3) and has `rsync` and its `blunderer` account, logged in
with `ssh -A`:

```
sudo --preserve-env=SSH_AUTH_SOCK box data push <host> --login --force -n   # dry run
sudo --preserve-env=SSH_AUTH_SOCK box data push <host> --login --force
```

`--login` makes ssh use your agent's key, or ask for `blunderer`'s password
on the terminal (if the new host's sshd allows passwords), instead of the
leader's own key. `--force` skips the leader check, which needs the new
host's inventory (it has none before this push). The port is the one
`box ssh-keys` wrote for that host (`ssh_port` in `configs/<host>.env` or `<host>_ssh_port` in the inventory,
else 222); when nothing answers there but port 22 does (a fresh install,
before `box ssh` moved sshd), `box data` uses 22 and says so. After `box setup` on the new host
(section 4), the leader's key is trusted and the nightly push needs neither
option. Without the leader (a restore), copy the data folder from a backup.

`git` stays in `box`'s package set (updates, `git pull`), so it is also
reinstalled by `box packages` if it ever goes missing.

The data folder holds what is not in git:

```
configs/hosts.env             inventory shared by all hosts (see examples/example-hosts.env)
configs/<host>.env            this host's values (see examples/example.env)
keys/ssl/blunderer.org/       certificate (installed by ssl/renew.sh)
keys/acme/                    TSIG key for DNS challenges, lego's account and state
keys/ssh/id_ecdsa_<host>(.pub)  each host's key pair, to log in to the others
keys/ssh/clients/<name>.pub     public keys of the extra ssh clients (ssh_clients),
                                or id_ecdsa_<name> for one running box (a laptop)
keys/opendkim/<domain>/       DKIM keys (<selector>.private)
configs/mail/virtual          mail forwarding table (box mail config; example: examples/virtual)
configs/mail/senders          which SMTP login may send as which address (box mail config; examples/senders)
keys/postsrsd/                SRS secret (created on first mail deploy; same on all hosts)
keys/tor/<onion_name>/        onion service keys
keys/mariadb/root_password    created on first db deploy
keys/websso/                  Google SSO secrets (oauth2.cfg, box keys new websso)
users/postfix/                passwd, shadow, group (SMTP AUTH accounts)
users/websso/<domain>         Google accounts allowed through SSO, one file per domain
www/                          websites
mariadb-v2/                   database (srv); mysql/ is the legacy one
backups/mariadb/              dumps
transmission/, wireguard/     per-host state (not replicated)
```

On the current servers the data folder is `/home/new-data`: set
`data_dir=/home/new-data` in their env files.

`srv` and `box` run as root (`sudo`), but what they create in the data
folder (keys, passwords, dumps, the certificate) gets the data folder's own
owner, normally `blunderer`, or `data_owner=` if set. Paths that need another
owner keep it: the BIND group of the TSIG keys. MariaDB runs as uid 1000
too, so its data directory (`mariadb-v2/`) belongs to the data owner like
the rest. `box check` counts files still owned by root (for
example created before this rule) and prints the command that fixes them.

## 3. Inventory and host file

The inventory lists every machine (address, DNS names) and who leads; it is
shared, so on a new host it normally arrives with the data folder. Add the
new machine there (on the leader, which replicates it):

```
hosts="orion lyra vega"
vega_ip=203.0.113.7
vega_names=""            # DNS names for it, e.g. "ns2" if it ever serves NS
```

To make it a name server, give it a name (`vega_names="ns2"`, or `ns9:6` for an
IPv6-only one: `:6` keeps only the AAAA record, `:4` only the A), add that name
to `ns=` in the inventory, deploy dns on the master, and only then add the
glue record (`ns2.blunderer.org` → its address) and the name server at the
registrar. Removing one goes the other way round: registrar first, then `ns=`.
The NS records of the dynamic zones (acme., smtp.), kept by BIND in its
`dns-lib` volume folder, follow `ns=` too: the dns post-switch hook updates them on the master.
`box check` on the leader compares the registrar's delegation with `ns=` and
lists missing glue records (`ns6(AAAA)`).

Then the host's own file:

```
cp /opt/server-config/examples/example.env /home/data/configs/vega.env
editor /home/data/configs/vega.env       # host=vega, services=..., data_dir=...
sudo /opt/server-config/box link         # or: box link /home/new-data
```

`box link` (also the first step of `box setup`) links, when they are
missing, `/etc/srv/hosts.env` to `<data>/configs/hosts.env` and
`/etc/srv/host.env` to the host file you pick among `<data>/configs/*.env`
(the one named after the hostname is the default; without a terminal, only
that one is linked). Existing files in `/etc/srv` are never replaced.
`box unlink` removes these links and the commands' links again.

For vega, start with a short `services=` list (for example
`dns web db onion torrent`), then add `mail` when testing it. See
"Testing a service on vega" in [migration.md](migration.md).

## 4. Set up the host

```
sudo /opt/server-config/box setup
```

`setup` runs these steps in order; each can also run on its own, and all of
them can be re-run at any time (they only change what differs):

| Command              | What it does                                                    |
|----------------------|-----------------------------------------------------------------|
| `box hostname`  | `/etc/hostname` = the inventory name (`orion`), `/etc/hosts` = localhost plus every host of the inventory (`<ip> orion.blunderer.org orion`), cloud-init told not to undo it |
| `box ipv6`      | The inventory's `<host>_ip6` on this host: with `ip6_gw` in the host file, installs `srv-ipv6.service`, which sets the address and the default route at boot (`ip6_intf`, default the IPv4 route's interface; `ip6_prefix`, default 64); without it, expects the provider's setup. Checks the internet answers over IPv6 |
| `box resolver`  | Frees port 53 for the dns service: stops, disables and masks systemd-resolved, and writes a plain `/etc/resolv.conf` (`host_resolvers`, else the provider's servers) |
| `box link`      | Links `srv` and `box` into `/usr/local/bin`, and, if missing, the host env files in `/etc/srv` (see above); first step, so later failures still leave them in place. `box unlink` removes them (only links pointing into this repository or the data folder) |
| `box packages`  | Minimal package set, recommends disabled, rootless Podman from Debian, `/etc/tmux.conf`, `/etc/gitconfig` (vim as git's editor; commits as Tristan Lelong, for every account), `/etc/vim/vimrc.local` (no mouse) |
| `box man`       | The manual pages of the containers' programs (`man postconf`, `man 5 named.conf`, `man nginx`…): the slim images have none, so they come from Debian's packages named by `MANPAGES` in each enabled service's `service.env`, downloaded and only their pages extracted into `/usr/local/share/man` (nothing installed; pages the host already has are kept). Debian's versions may differ slightly from the images' |
| `box shell`     | The same `~/.bashrc` and `~/.profile` (`host/shell/`) for root and the admin account: history with dates (10000 lines, shared between sessions), a prompt with the host in its own colour (by its place in `hosts=`), root in red and `leader` on the leader, vim as editor, `ll`/`la`/`l`, completion. Per-host or personal additions go in `~/.bashrc.local` and `~/.profile.local`, which box leaves alone |
| `box podman`    | Rootless Podman user (`subuid`/`subgid`, linger), sysctl (`ip_unprivileged_port_start=25`), `tun` module, journald 2 GB cap, `storage.conf` (`podman_storage_dir`), `containers.conf.d/srv.conf`, Quadlet networks, `box keys sync` |
| `box ssh-keys`  | One key pair per host, `<data>/keys/ssh/id_ecdsa_<host>` (created on the leader for every host of the inventory); this host's in `~/.ssh` of root and `unix_role`, the others' authorized for `unix_role`; `/etc/ssh/ssh_config.d/srv.conf` tells ssh, rsync and the scripts to use it, as `unix_role`, on each host's port |
| `box ssh`       | sshd drop-in: port `ssh_port` (222), password login disabled unless `ssh_password_auth=yes`, no root login, `AllowUsers` (`unix_role` by default) |
| `box fail2ban`  | jails for sshd (its port), SMTP AUTH, repeat offenders          |
| `box alerts`    | email alerts through the mail service (msmtp, `sendmail` for cron/fail2ban) |
| `box cron`      | `/etc/cron.d/srv`: upgrades, database dump, backups, certificate renewal, reloads, health mails |

Several commands can be given at once (`box podman ssh`). More
subcommands:

| Command              | What it does                                                    |
|----------------------|-----------------------------------------------------------------|
| `box check`          | Is the host ready to run its services? Exit status 1 on failure |
| `box audit`          | What differs from the repository and host env file, with the command that fixes it; then listening ports, enabled services, extra packages, accounts |
| `box keys sync`      | Register or replace Podman secrets from `<data>/keys` (pass `--restart` to restart running services whose secrets changed) |
| `box docker-remove`  | Remove legacy Docker packages, `/etc/docker`, storage, and networks once every service is committed on Podman |

Packages installed, and nothing else: `ca-certificates curl git rsync cron
iproute2 openssh-server fail2ban python3-systemd systemd-timesyncd iptables
msmtp tmux ncurses-term bind9-dnsutils vim` (`dig` for the DNS checks, `vim` as git's editor),
and Podman (`podman crun catatonit aardvark-dns uidmap slirp4netns passt fuse-overlayfs dbus-user-session`).
Certificate renewal needs nothing installed: lego runs from its image. `box audit` lists what
else is installed, listening or enabled, so you can remove it.

### Hostname

`box hostname` names the machine after its inventory entry (`host=` in
its host file) and writes `/etc/hosts` from the inventory: every host by
`<name>.blunderer.org` and `<name>`, so the hosts reach each other (ssh,
rsync) even when DNS is down. `/etc/hosts` is fully generated: put any
addition in the inventory instead, or it is lost on the next run (`audit`
reports the difference). On cloud images it also writes
`/etc/cloud/cloud.cfg.d/99-srv.cfg` so cloud-init keeps both at boot. Adding a
host to the inventory: `box hostname` on every host afterwards.

### Port 53

Debian images often run systemd-resolved, whose local stub listens on
`127.0.0.53:53` and `127.0.0.54:53`. That alone stops Docker from publishing
port 53, and `srv deploy dns` fails with "address already in use".
`box resolver` (part of `setup`) stops, disables and **masks**
systemd-resolved, so nothing starts it again at boot. Turning only its stub
listener off (what it did before) did not survive every reboot. It then
writes a plain `/etc/resolv.conf`:

- the servers in `host_resolvers` (host file), if set;
- else the upstream servers resolved was using (the provider's, read before
  stopping it), or those already in `/etc/resolv.conf`;
- else 1.1.1.1 and 9.9.9.9.

Never a loopback address: the dns service only answers for our zones. A host
whose network setup rewrites `/etc/resolv.conf` (a DHCP client) shows up in
`box audit`; set `host_resolvers` and re-run `box resolver`. `box check`
fails while systemd-resolved is not masked, or anything other than Docker
holds port 53, on a host running dns.

### tmux

`box packages` installs `/etc/tmux.conf` (`host/tmux/tmux.conf`): prefix
**Ctrl+S** (Ctrl+S Ctrl+S sends it through), `tmux-256color` with 24-bit
colour, styled underlines, hyperlinks and clipboard when your terminal has
them, no mouse (the terminal keeps selecting and copying text), a long history, windows numbered from 1. `ncurses-term`
provides the terminfo entries of most modern terminal emulators, so their
`TERM` works over ssh. A personal `~/.tmux.conf` still overrides it.

### Never banning your own address

fail2ban's `recidive` jail bans an address on **every** port for a week, so a
few failed logins from home (a phone mail client with an old password) can
lock you out of ssh too. Mark the addresses you work from as trusted:

```
box ssh-trusted                   # the address of your current ssh session
box ssh-trusted 203.0.113.0/24    # or an address or network given explicitly
box ssh-trusted --list
box ssh-trusted --remove 203.0.113.0/24
```

They go to `/etc/fail2ban/jail.d/srv-trusted.local` (`ignoreip`, for every
jail); adding one also lifts a current ban of it. The file is per host:
run it on each host. `box check` fails when the address you are connected
from is banned in any jail.

### vim

`box packages` installs `/etc/vim/vimrc.local` (`host/vim/vimrc.local`):
Vim's usual defaults, but no mouse, as in tmux, so selecting text with the
mouse copies it in your terminal. A personal `~/.vimrc` still overrides it.

### ssh between hosts

The leader logs in to every other host (replication, certificates,
inventory), and any host may take over as leader, so every host reaches
every other one. Each host has its own key pair,
`<data>/keys/ssh/id_ecdsa_<host>` and `.pub`. They travel with the data
folder, so `box ssh-keys` creates missing ones **on the leader**, for every
host of the inventory (a key created on another host would be deleted by the
next replication). A new host: add it to the inventory, run `box ssh-keys` on
the leader, then on the new host once the data folder is there.

On each host, `box ssh-keys` (part of setup):

- installs the host's own pair as `~/.ssh/id_ecdsa_<host>` for root (the cron
  jobs) and for `unix_role`;
- writes a managed block in `unix_role`'s `authorized_keys` with every
  other host's public key; keys outside the block (yours) are kept, and a host
  removed from the inventory loses its access on the next run;
- adds to that block the extra clients named in the inventory
  (`ssh_clients="laptop phone"`), whose public keys are in
  `<data>/keys/ssh/clients/<name>.pub`, so your own machines are trusted
  everywhere without editing each host. Removing a client from the inventory
  revokes it on each host's next run;
- writes `/etc/ssh/ssh_config.d/srv.conf`: for each other host of the
  inventory (name, address), its port (`ssh_port` in `configs/<host>.env` or `<host>_ssh_port` in the inventory,
  else this host's `ssh_port`), the user and the key.

**A laptop** (a machine of yours running box: `host=laptop` in its host
file, not in `hosts=`, no services): add it to `ssh_clients=` in the
inventory. `box ssh-keys` on the leader then makes its pair,
`<data>/keys/ssh/id_ecdsa_laptop`, and `box data push` plus `box ssh-keys`
on each host authorize it. On the laptop, after `box data pull --login`
(the first time, with your own login), `sudo box ssh-keys` installs the
pair in `~/.ssh` of root and of your account, and writes the same
`/etc/ssh/ssh_config.d/srv.conf`: `ssh orion`, `remote orion …` and
`box data pull` then work with no port, full name or user to give.

Root never logs in over ssh (`PermitRootLogin no`, from `box ssh`): the
hosts log in as `unix_role`. `box check` verifies the pair, its copies
in `~/.ssh`, that every other host's key is authorized, that sshd refuses
root, and that this host logs in to every other one (a failure on the leader
breaks replication).

A host on the old stack is not set up by `box`: append the leader's
`id_ecdsa_<leader>.pub` to its `unix_role`'s `authorized_keys` by hand,
and set `<host>_ssh_port=22` if it still listens there.

### Changing the ssh port safely

`box ssh` first opens `ssh_port` **next to** 22 (fail2ban watches
both). From another terminal, check that `ssh -p 222 user@host` works, and
that your hosting provider's firewall lets 222 through. Then:

```
box ssh-confirm
```

closes 22. The script also comments out `Port` lines in the main
`sshd_config`, adds the `Include` of `sshd_config.d` when an old file lacks
it, and switches off socket activation, any of which would otherwise keep
sshd on 22. Open sessions survive the sshd restart.

### Cron jobs

| When          | Job                                                     | Where             |
|---------------|---------------------------------------------------------|-------------------|
| 01:00 daily   | `box upgrade`: apt upgrade (keeps local config)    | every host        |
| 02:30 daily   | `srv hook db dump`                                      | hosts running db  |
| 02:45 daily   | `srv hook mail prune-reports`: DMARC reports older than 90 days | hosts running mail |
| 03:00 daily   | `box data push`: data folder to every other host        | leader            |
| 04:00 daily   | `backup/diff-backup.sh` to `backup_dir`                 | every host        |
| every 5 min   | `box smtp-health`: smtp.blunderer.org (this host's copy) keeps the mail hosts that work (STARTTLS, login) | hosts running dns, with `smtp=` |
| 05:00 daily   | `ssl/renew.sh` (lego renews only when due)              | leader            |
| 06:00 daily   | `srv reload web mail`                                   | every host        |
| 07:00 daily   | `box watch`: alert on failed checks, needed reboot | every host |
| every 15 min  | `box peer-health`: the other hosts' ssh, dns, smtp (25, 587) and https from outside, on IPv4 and IPv6; an alert when that changes (one per outage: each host has one watcher, the first other host of `hosts=`) | every host with peers |
| 07:30 Monday  | `box report`: weekly status email                  | every host        |

To copy the data folder now instead of waiting for 03:00:

```
box data push               # on the leader: to every other host (that agrees it is the leader)
box data push lyra          # only to lyra
box data push --force       # from any host, skipping the leader checks
box data pull               # here, from the leader
box data pull vega          # here, from vega (on the leader: --force)
box data push -n            # dry run: list what would change, copy nothing
box data push -v            # list every file copied or deleted
box data pull --no-delete   # keep local files the source does not have
box data pull --exclude-dir www/test   # leave <data>/www/test alone, on both sides
box data pull --from blunderer.org     # a new host's first copy (section 2)
box data push -- -v --progress         # after --: options given to rsync as is
```

Run by hand, a progress line shows the whole copy: amount copied,
percentage, speed and time left (it starts after rsync has listed the
files, which takes a moment on a large data folder). The output shows on
the terminal and goes to the journal (without the progress updates):
`journalctl -t srv-data-push` (also the nightly job) or `-t srv-data-pull`.

Jobs run through `box run <name> <command>`: the output goes to the
journal (`journalctl -t srv-backup`, `-t srv-ssl-renew`...) and a failing job
sends an alert with the end of its output. Upgrades never reboot: `watch`
sends one alert when a reboot is needed.

### Email alerts

Alerts go to `alert_email`, sent through your own mail service (port 587,
STARTTLS) as a dedicated SMTP account. Authenticated mail passes the
own-domain sender rule and is DKIM-signed, so it reaches Gmail cleanly, and
it works from hosts that do not run the mail service themselves.

Once, on the leader (the data folder copies it to the other hosts):

```
box alerts-account   # adds the "alerts" account to <data>/users/postfix,
                     # password in <data>/keys/alerts/smtp_password
                     # (the same as: box mail user add alerts --random)
```

Then on each host: `box alerts cron` and `box alert-test`. The same account
is the one `box mail test` sends with; rotate its password with
`box mail user passwd alerts --random` (docs/runbooks.md, "SMTP logins"). The
delivery log is `journalctl -t srv-alert`. msmtp also provides `sendmail`,
so anything that mails root on the host (cron, fail2ban) reaches you too.

What is sent:

- a cron job fails (backup, replication, certificate renewal, dump, upgrade);
- `box check` fails (missing files, unhealthy or stopped containers,
  sshd or fail2ban down...), daily until fixed;
- a reboot is needed after upgrades (once per set of packages);
- every Monday, a report: `srv status`, `check`, drift, disk, fail2ban bans.

A host whose mail service is down cannot send through itself: set
`alert_smtp_host` to the other mail host there if that matters.

### Audit: what to re-run

`box audit` regenerates every managed file in memory and compares it
with the host, then names the command that fixes each difference:

```
==> configuration drift (what to re-run)
  /etc/cron.d/srv differs (services, the inventory or the repository changed)
      -> box cron
  port 22 is still open next to 222: check 'ssh -p 222' from another terminal (and the provider firewall),
        then -> box ssh-confirm

  Run: box cron ssh-confirm
```

It covers missing packages, the apt and Docker repository settings,
`daemon.json` (and a Docker not restarted since), the storage location, the
sshd drop-in, ports actually listening, socket activation, fail2ban files and
ports, the cron file and the alert settings. Run it after `git pull`.

### Checks

`box check` verifies: the host env file renders every enabled service;
the data, backup, volumes and Docker storage folders exist, with the backup folder
on the same filesystem as the data folder (hard links); `data_dir` is the
real data folder (it holds `configs/hosts.env`, `/etc/srv/host.env` points
into it, and no other candidate such as `/home/new-data` holds an inventory);
every file and folder the enabled services expect (`REQUIRES=` in each
`service.env`: certificates, DKIM keys, SMTP users, onion keys, the torrent
folders...); ownership and permissions; Docker runs with journald logs in the
right storage, and every container publishes the host ports it asks for;
sshd listens on its port; fail2ban, cron and time sync are on, and your own
address is not banned; the `unix_role` account exists with uid 1000; this host's ssh key pair is in place, the other
hosts' keys and the extra clients' are authorized, root cannot log in over ssh, and this host logs
in to every other one; disk usage; pending reboot; leftover old cron jobs.

Checks that came out of real mail and DNS incidents:

| Check | Where | Result |
|-------|-------|--------|
| Reverse and forward names of the mail name, IPv4 and IPv6 | mail | warn |
| OpenDKIM/OpenARC errors and milter rejects in the last 24h (`not secure`, `error loading key`, `milter-reject`) | mail | warn |
| Mail deferred in the queue for 2 hours or more | mail | warn |
| SMTP AUTH end to end: postfix, as its own user, reaches saslauthd's socket and the alerts account logs in | mail | fail |
| Spamhaus answers the mail resolver (`127.0.0.2` for its test entry; `127.255.255.x` means refused) | mail | warn |
| Each DKIM key in `KeyTable` matches its DNS record (`opendkim-testkey`) | mail | warn |
| The SPF record of every zone allows this host's sending addresses (IPv6 when postfix uses it) | mail | warn |
| Certificate: expires in more than 21 days (warn) or 7 (fail), key matches; TLS on 587/465 valid for the mail names, on 443 for the domain | mail, web | fail |
| Exactly one DMARC record per zone | leader | warn if none, fail if several |
| Every name server of every zone answers the same (SOA serial, MX, SPF, DMARC, DKIM) | leader | fail |
| The registrar's NS records of every zone are `ns=`, with a glue record for each address (A, AAAA) of each name server | leader | warn |

A failure is a definite misconfiguration of this host, and `box watch` emails
it every morning until fixed; a warning depends on something outside the host
(a DNS record, a blocklist, the hosting provider) or is worth a look. The DNS
checks need `dig`; the zone-wide ones run on the leader only, once for all
hosts.

### Rootless Podman and storage location

`box podman` prepares the host for rootless Quadlets:

- enables lingering and `subuid`/`subgid` ranges for the rootless Podman user;
- sets `net.ipv4.ip_unprivileged_port_start = 25` and loads the `tun` kernel
  module (`/etc/sysctl.d/99-srv-podman.conf` and `/etc/modules-load.d/srv-podman.conf`);
- writes user `storage.conf` (pointing `graphroot` to `podman_storage_dir`
  when set, keeping container images and writable layers off the root
  partition) and `containers.conf.d/srv.conf`;
- creates the `srv-*` Quadlet network units and registers keys as Podman secrets
  via `box keys sync`.

If a host is still transitioning from an earlier `srv` Docker Compose setup
(`docker_storage_dir` set while Docker still exists), see the migration runbook
in [runbooks.md](runbooks.md) and run `box docker-remove` once every service is
committed on Podman.

## 5. Deploy

```
srv services          # what this host runs, in order
srv deploy all        # or one by one
srv status
```
