# blunderer.org server configuration (`srv` branch)

Configuration and tooling for the blunderer.org hosts: every service runs in
rootless Podman (Quadlet systemd user units and pods) from pinned images, and
`srv` deploys each one as a **release** you can switch to, roll back from, or
commit. Legacy Docker releases remain supported side by side until
`box docker-remove`.

```
srv pending mail     # what a deploy would change: config diff, new images
srv build mail       # pull/build the images only (nothing started)
srv deploy mail      # pull/build, render, shift volumes if migrating; switch release
srv status           # what runs where, and is it healthy
srv rollback mail    # something broke: back to the previous release (seconds)
srv commit mail      # all good: remove previous release containers and old images
```

The host itself (packages, Podman, ssh, firewall, backups, alerts, checks) is
managed by `box`, next to `srv`:

```
box setup            # everything a host needs, idempotent
box podman           # configure rootless Podman, /home/podman, networks, secrets
box keys sync --restart  # sync Podman secrets from <data>/keys and restart changed services
box docker-remove    # purge legacy Docker once all services are committed on Podman
box check            # is this host healthy (services, files, mail names...)
box -q check         # the same, only the warnings and failures
box audit            # what differs from the repository, and what to run
box backups pause    # maintenance: stop backups, replication and renewal here
box ssh-trusted      # never let fail2ban ban the address you are connected from
box mail trace jane@example.com   # what became of a message (logs, verdict)
box dns show _dmarc TXT           # every name server's answer, side by side
box tls                           # the certificate clients get on 443/465/587
```

`box link` (part of `box setup`) puts both commands in `/usr/local/bin`;
`box unlink` removes them.

This branch replaces the old layout (one branch per module plus `manage`).
The old branches stay untouched while the hosts migrate; see
[docs/transition.md](docs/transition.md).

## Layout

```
srv                     the service tool (bash, `srv help`)
box                     the host tool: setup, checks, backups, migrations (`box help`)
services/<name>/        one directory per service
  quadlet/              rootless Podman Quadlet .pod / .container units
  service.env           metadata: description, dependencies, images, volumes, legacy containers
  config/               templates rendered per host (@name@ placeholders)
  image/                Containerfile / Dockerfile when no standard image fits
  hooks/                prepare, pre-switch, post-switch and maintenance hooks
examples/               documented examples (real values are not in git):
  example-hosts.env     the inventory shared by all hosts: machines, leader, web
  example.env           one host's own values
host/                   files `box` installs: journald, sshd, fail2ban, tmux, git, vim
backup/                 local incremental backup, replication to other hosts
ssl/                    Let's Encrypt renewal (lego, DNS-01 challenges on our own BIND)
docs/                   documentation
```

## Services

| Service    | What                                      | Image                                  |
|------------|-------------------------------------------|----------------------------------------|
| `dns`      | Authoritative DNS, 4 zones                | `internetsystemsconsortium/bind9:9.20` |
| `db`       | MariaDB                                   | `mariadb:11.4` (LTS)                   |
| `web`      | Websites + Google SSO (`auth.blunderer.org`) | `nginx:stable-alpine`, `php8.4-fpm` (`debian:trixie-slim`), `quay.io/oauth2-proxy/oauth2-proxy` |
| `onion`    | Tor onion service for the website         | built from `debian:trixie-slim`        |
| `mail`     | Forwarding to Gmail + submission          | built from `debian:trixie-slim` + OpenARC |
| `torrent`  | Transmission (`torrent.blunderer.org`, Google SSO) | `lscr.io/linuxserver/transmission` |
| `jellyfin` | Jellyfin media server (`jellyfin.blunderer.org`) | `lscr.io/linuxserver/jellyfin`     |
| `minecraft` | Private Minecraft (Bedrock: Switch, phones) | `itzg/minecraft-bedrock-server`      |
| `vpn`      | WireGuard (replaces the broken OpenVPN)   | `lscr.io/linuxserver/wireguard`        |
| `agy`       | Antigravity CLI agent, driven from antigravity.google.com | built: Debian + Google's installer |

Which services run on a host is set by `services=` in its host file. The
hosts are **orion** (leader: DNS master, replication source, certificates),
**lyra** and **vega**, named in the inventory (`<data>/configs/hosts.env`).

## Documentation

- [docs/architecture.md](docs/architecture.md): releases, templates, data, networking, logs
- [docs/operations.md](docs/operations.md): day-to-day commands, updates, troubleshooting
- [docs/runbooks.md](docs/runbooks.md): step by step for common tasks and incidents
- [docs/host-setup.md](docs/host-setup.md): preparing a new host (e.g. vega)
- [docs/transition.md](docs/transition.md): **the plan** from the old stack to `srv`, host by host
- [docs/migration.md](docs/migration.md): moving each service from the old containers
- [docs/mail.md](docs/mail.md): forwarding to Gmail, SRS, DKIM, ARC, spoofing
- [docs/minecraft.md](docs/minecraft.md): the Minecraft server, accounts, joining from a Switch
- [docs/agy.md](docs/agy.md): the Antigravity agent, Remote Control, syncing its output
- [docs/adding-a-service.md](docs/adding-a-service.md)
