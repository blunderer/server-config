# agy: the Antigravity CLI agent, headless

The `agy` service runs Google's Antigravity CLI (`agy`) in containers, as
agents you drive from anywhere through **Remote Control**, the dashboard at
<https://antigravity.google.com>. Each **instance** is an isolated sandbox:
its own container, sign-in and workspace. What an agent produces stays in
its workspace on the server; `srv hook agy sync` copies it to a folder of
your choice.

## Instances

`agy_instances` in the host file names them (default: one, `agy`):

```
agy_instances="site api"      # two sandboxes: agy-site and agy-api
agy_mem=2g                    # memory of each (default 2g)
```

| Instance | Container and dashboard name | Volume folders (`volumes_dir`, default `/home/volumes`) |
|----------|------------------------------|---------------------------------------------------------|
| `agy` (the default) | `agy` | `agy-home`, `agy-work`, `agy-shares` |
| `<name>` | `agy-<name>` | `agy-<name>-home`, `agy-<name>-work`, `agy-<name>-shares` |

One cannot see another's files, sign-in or processes. Each signs in on its
own (`srv hook agy register <name>`) and appears on the dashboard under its
container name. Adding a name and deploying creates its volume folders; removing
a name stops its container but keeps its volume folders, so adding it back finds
its sign-in and workspace (delete them from `volumes_dir` when done).

## Who can reach it

Only you:

- **Nothing listens on the server.** agy opens an outgoing tunnel to
  Google; the service publishes no port and needs no firewall rule.
- **The dashboard is your Google account's.** A session appears there only
  for the account signed in to agy in the container. Sign in with yours,
  and do not share that account.
- **Locally, only root.** The session runs in tmux in the container:
  `srv hook agy register` needs root on the host.

The agent runs commands of its choosing inside its container, and can
become root there: `sudo` works without a password (to install packages,
change system files of its sandbox). It stays a rootless container: Podman's default
capabilities, minus raw sockets and device files (`DropCapability=CAP_NET_RAW CAP_MKNOD`,
none of `SYS_ADMIN`, `NET_ADMIN`, module loading), not privileged, `agy_mem` of
memory, no container runtime socket, and nothing of the host or of the other
instances except its three volume folders. Under `UserNS=keep-id`, uid 1000 is
`unix_role` and container root maps to an unprivileged host subuid, though a
user-namespace kernel flaw would still matter: keep the hosts updated (`box
upgrade`, nightly). What it installs with apt
is lost at the next deploy (a new image); put lasting tools in the
Dockerfile. It does have
the internet, which it needs.

## Setting it up

The CPU needs AES-NI (`grep -w aes /proc/cpuinfo`); the prepare hook stops
the deploy otherwise.

1. Add `agy` to `services=` in the host file, then:
   ```
   srv deploy agy        # builds the image: Google's installer, the current agy
   ```
2. Sign in, once per instance, in its session:
   ```
   srv hook agy register            # the only instance
   srv hook agy register site       # with several: name one
   ```
   agy prints an authorization URL: open it on any device, sign in with
   your Google account, paste the code back. Remote Control then starts.
   Leave with **Ctrl-b d** (the session keeps running; Ctrl-c would stop
   agy, which starts again 10 s later).
3. On <https://antigravity.google.com>, signed in with the same account,
   pick the machine in the instance switcher and start working. If it says
   "Remote control is not enabled for your account", the feature is not
   enabled for that account yet.

The sign-in lives in the instance's home volume folder (`/home/agy`, with agy's
`~/.gemini/antigravity-cli/settings.json`): it survives deploys and
rollbacks, stays on this host and is not in the replicated data folder.

## The workspace and the sync hook

An agent works in `/work`, its instance's work volume folder. To get its output:

```
srv hook agy sync /home/blunderer/agy                # the only instance, all of /work
srv hook agy sync site /home/blunderer/site          # instance site, all of its /work
srv hook agy sync api /home/blunderer/api backend    # only /work/backend of api
srv hook agy sync site                               # to agy_sync_dir/site (host file)
SRV_SYNC_DELETE=1 srv hook agy sync site /home/blunderer/site   # mirror: also remove what is gone
```

The instance may be left out when there is only one.

It copies with rsync (`--safe-links`, `--no-devices`, `--no-specials`, stripping
setuid/setgid bits and refusing top-level symlinks), keeping dates and setting
the owner to `data_owner` (uid 1000). Without `SRV_SYNC_DELETE=1`, nothing is
ever removed from the target. To pull it to a laptop: `remote vega sudo srv
hook agy sync …` then rsync from there, or sync into a folder you already
replicate.

## Sharing a folder, read-only, with a writable overlay

To let an agent work on files that live elsewhere on the host, without
risking them:

```
srv hook agy share site /home/blunderer/projects/blog          # /shared/blog in agy-site
srv hook agy share site /home/blunderer/projects/blog notes    # the same, as /shared/notes
srv hook agy share                                              # list (and mount again what is missing)
srv hook agy unshare site blog                                  # stop; the changes are kept
srv hook agy unshare site blog discard                          # stop and delete the changes
```

The agent sees the folder as `/shared/<name>` and can change anything in
it, but the original is never written: an overlay (overlayfs, mounted on the
host) puts every change, new and modified files, in
`<volumes_dir>/agy[-<instance>]-shares/overlay/<name>/upper`. Look at what it did there, or copy it
back yourself. A file the agent deleted shows there as a character device
0/0 (overlayfs' whiteout).

- **Writing:** the agent runs as uid 1000. It can change what your account
  (uid 1000) could change; root-owned files stay read-only for it.
- **Changing the original meanwhile:** changes to the shared folder while it
  is shared may or may not show in `/shared` (overlayfs leaves that
  undefined). Unshare and share again to be sure.
- **After a reboot:** host mounts do not survive it; a cron line
  (`@reboot`, from `box cron` on hosts running agy) mounts the recorded
  shares again.
- **Not shared:** `/`, `/etc`, `/root`, `/var` (and other system trees), `.ssh`
  and key/user folders, and any parent folder containing `<data>/{keys,users}`
  or `.ssh` are refused.

The instance's container sees `/shared` through a bind mount with `rslave`
propagation, so shares made while it runs appear without a restart.

## Day to day

| What | Command |
|------|---------|
| A session | `srv hook agy register [instance]` (Ctrl-b d to leave) |
| Its log | `journalctl -t agy` (instance `agy`), `journalctl -t agy-<name>` |
| What runs | `srv status agy` |
| agy's own settings | `~/.gemini/antigravity-cli/settings.json` in the container (`srv exec agy agy agy --help` for its options) |
| Update agy | `srv deploy agy` (each build installs the current release), then `srv commit agy` |
| Back to the previous build | `srv rollback agy` |

Because each build installs Google's current release, two deploys can give
different agy versions; a rollback goes back to the image of the previous
release.
