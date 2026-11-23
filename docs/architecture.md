# Architecture

## Goals

- Update a service without fear: the old version stays one command away.
- Standard, maintained images; one daemon per container in rootless Podman
  (`UserNS=keep-id`); systemd restarts what dies and `HealthOnFailure=restart`
  restarts what turns unhealthy (retiring `autoheal`).
- Logs can never fill the disk.
- Configuration in git, host-specific values and secrets out of it.

## Releases

A **service** is `services/<name>/`. Deploying it creates a **release**,
named after the time (`20261104-093000`):

```
/srv/releases/<service>/
  20261104-093000/     a frozen copy of services/<service>/, templates and
                       quadlet/*.container rendered, plus .env and release.info
  current  -> 20261104-093000
  previous -> 20261028-211500      (or the word "legacy", see below)
```

Each Quadlet release is validated statically (`srv check`) and, when active,
installed into the `unix_role` user's systemd unit directory
(`~/.config/containers/systemd/`) so `systemd --user` runs that release. Only
one release runs at a time, while `previous` keeps its rendered Quadlets (or
stopped Docker containers during a migration) and exact image tags for rollback.

`srv deploy <svc>`:

1. renders the release directory and validates `quadlet/` (`validate_quadlets` /
   `podman-system-generator --dryrun`);
2. runs `hooks/prepare` (create missing host files/directories with the right
   rootless UIDs) and syncs Podman secrets (`box keys sync`);
3. pulls external images and builds `IMAGES=` locally under rootless Podman
   (`localhost/srv/<name>:<release>`). Nothing has changed for the running service yet;
4. asks for confirmation, runs `hooks/pre-switch` (e.g. database dump);
5. stops the current release, final-syncs volumes if their location changed,
   shifts UIDs/GIDs in host volumes when migrating between Docker and Podman
   (`UserNS=keep-id`), installs the new Quadlets and starts them;
6. waits until every container is running and, when it has a healthcheck,
   healthy. If not, it offers to roll back at once.

`srv rollback <svc>` swaps `current` and `previous`: it stops one release,
shifts volume UIDs back if `current` and `previous` use different runtimes
(Podman ↔ Docker), and starts the other without rebuilding or re-pulling.
Running it again rolls forward.

`srv commit <svc>` drops the previous release (Docker containers or old Quadlet
state), deletes migrated old Docker/volume folders once unreferenced, prunes
unused `localhost/srv/*` tags and unreferenced images, and keeps the last few
release directories (`SRV_KEEP`, default 3) for `srv diff`.

Deploying again without committing drops the previous release automatically:
only the immediately previous release is a rollback target.

### Legacy containers

`LEGACY=` in `service.env` lists the containers of the old setup that the
service replaces (`mypostfix myopendkim`...). While no release exists, they
count as the current release: the first deploy stops them (and sets their
restart policy to `no`, so a reboot does not bring them back), and
`srv rollback` starts them again with `restart=always`. `srv commit` removes
them. Their data is never touched.

## Templates and host values

Files in `config/` and `quadlet/` are templates. `@name@` is replaced by
a value from the inventory (`<data>/configs/hosts.env`, shared by every
host: machines, their addresses and DNS names, `leader`, `web`), then the
host file (`/etc/srv/host.env`, a symlink to `<data>/configs/<host>.env`),
which overrides it. An unknown name is an error, never an empty string.
Derived values:

| Name          | Value                                            |
|---------------|--------------------------------------------------|
| `zone_serial` | Unix time of the render (DNS zone serials)       |
| `data_dir`    | Defaults to `/home/data`                         |
| `volumes_dir` | Defaults to `/home/volumes`                      |
| `tz`          | Defaults to `Europe/Paris`                       |
| `domain`      | Defaults to `blunderer.org`                      |
| `is_leader`   | `yes` on the host named by `leader`              |
| `dns_role`    | `master` on the leader, `slave` elsewhere        |
| `dns_master`  | The leader's address                             |
| `dns_slaves`, `dns_slaves_list` | Every other host's addresses (list, and as BIND `a; b; `) |
| `web_ip`      | Address of the host named by `web`               |
| `machine_records` | Zone records for every host, `*.<host>` -> `<host>`, and its `<host>_names` (`name:4` A only, `name:6` AAAA only) |
| `host_acme_records` | `_acme-challenge.<host>` CNAMEs in `<domain>.zone` for `*.<host>.<domain>` |
| `host_excluded_names` | `<other_host>.<host>.<domain>` names excluded (`404`) in nginx |
| `ns_records`, `acme_ns_records` | NS records of the zones and of the acme. delegation, from `ns=` (default `ns0 ns1`) |
| `remote_hosts`| On the leader: `unix_role@<address>` of every other host |
| `server_name` | The host's first `mailN` name, else `<host>.<domain>` |

`examples/example-hosts.env` and `examples/example.env` document every variable
with fake values; CI renders all services with them. Real values (IP addresses) stay in the data folder.

`srv` also expands `${SRV_DATA}`, `${SRV_VOLUMES}`, `${SRV_RELEASE}`,
`${SRV_RELEASE_DIR}`, and `${SRV_TZ}` inside Quadlet units and records them in
the release's `.env` for hooks and scripts (`SRV_VOLUMES` only for services
that declare volume folders).

## Data, secrets and permissions

Everything persistent is outside the containers:

- **Bind mounts from the data folder** (`data_dir`, replicated to the other
  hosts and backed up): keys, users, `www`, the database, Transmission state,
  database dumps.
- **Podman secrets** (`box keys sync [--restart]`): private keys and credentials
  in `<data>/keys` (SSL certs, DKIM keys, PostSRSd secret, DNS TSIG keys, OAuth
  config, MariaDB root password) are registered into the rootless Podman secret
  store and mounted read-only via `Secret=...,type=mount` (`ssl/renew.sh` and
  `box keys rotate` update or remind to restart services to pick up changes).
- **Host volume folders** (`volumes_dir`, default `/home/volumes`, local to
  each host and shared by all releases of a service): the postfix queue
  (`mail-spool`, so deferred mail survives a switch or a rollback), DMARC
  reports (`mail-reports`), secondary/dynamic DNS zones (`dns-lib`, `dns-cache`),
  Tor state (`onion-state`), agy agent state, writable overlays over read-only
  folders (`jellyfin-overlay`, `agy[-<inst>]-shares`), and shared runtime
  folders inside pods/containers.

Containers run under `UserNS=keep-id`: the `unix_role` host user (UID 1000)
maps 1:1 into container UID 1000 (`GroupAdd=1000` grants read access to `0750`/`0640`
`users/` files), while container UID 0 maps to the first subuid (`100000`). On
a Docker → Podman switch, `srv deploy` shifts non-native volume ownership using
the exact 3-extent bijection (`srv rollback` reverses it if needed).

When upgrading from legacy Docker named volumes (`srv-<name>`), pre-`volumes_dir`
overlay paths (`/home/srv-jellyfin`, `/home/srv-agy`), or when changing `volumes_dir`
in the host file, `box audit` / `srv pending` flag the affected services,
`srv deploy` seeds and final-syncs them into `volumes_dir`, and `srv commit`
offers to delete the old Docker volumes or previous folders.

## Networking and pods

- Services run in isolated Quadlet networks (`srv-web` and internal `srv-db`
  in `~/.config/containers/systemd/`, using `10.89.x.0/24` / `fd5a:7372:7611::/64`
  so they never collide with legacy Docker `172.30.x.0/24` bridges during migration).
- Multi-container stacks needing shared localhost sockets or IPC run in a
  **Pod** (`srv-web.pod` for nginx + php + oauth2-proxy, `srv-mail.pod` for
  postfix + rspamd + saslauthd + resolver + milters), keeping container traffic
  local to the pod without exposing extra bridges.
- Rootless `pasta` / host port forwarding preserves client source addresses on
  IPv4 and IPv6 once `net.ipv4.ip_unprivileged_port_start=25` is set (`box podman`).
- Legacy Docker containers (before `box docker-remove`) can remain on their
  Docker `NETWORKS=` (`srv init-host`) while migrating service by service.

## Health and restarts

- `Restart=always` (managed by systemd user units) restarts a container whose
  process exits; `srv stop` removes the Quadlet unit files from
  `~/.config/containers/systemd/` and reloads systemd so it stays stopped across reboots.
- `HealthCmd=` + `HealthOnFailure=restart` on each Quadlet unit restarts unhealthy
  containers directly in Podman (replacing `autoheal`).

## Logs

Containers log to stdout/stderr via `log_driver = "journald"` (`/etc/containers/containers.conf.d/srv.conf`).
journald caps the total size (`host/journald/srv.conf`, 2 GB), so logs cannot
fill the root partition.

```
srv logs mail                        # follow all containers in srv-mail pod
journalctl --user -u srv-mail-postfix  # inspect unit logs directly
```

## Disk usage

The root partition holds only the OS and the journal (2 GB cap).
With `podman_storage_dir=/home/podman`, rootless Podman's `graphroot` stores
images and container layers on the large partition (`~/.config/containers/storage.conf`),
while persistent volumes live in `volumes_dir`. `srv commit` prunes unused
`localhost/srv/*` tags and unreferenced images, keeping `current` and `previous`.

## Security notes

- DNS: recursion is off and zone transfers are limited to the other hosts of the inventory.
- Mail: see [mail.md](mail.md) (`InternalHosts` no longer trusts everyone,
  spoofed own-domain senders are refused).
- fail2ban bans in `INPUT` by default (`host/fail2ban/jail.local`), which catches
  rootless Podman `pasta` connections; while Docker remains installed, `box fail2ban`
  adds `/etc/fail2ban/jail.d/srv-docker.local` to also ban `DOCKER-USER`.
