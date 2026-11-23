# Adding a service

1. Create `services/<name>/`:

   ```
   quadlet/        # .container (and optional .pod) Quadlet units; ${SRV_DATA},
                   # ${SRV_VOLUMES}, ${SRV_TZ}, ${SRV_RELEASE}, ${SRV_RELEASE_DIR}, @var@
   service.env     # DESCRIPTION, DEPENDS, LEGACY, IMAGES, VOLUMES, NETWORKS,
                   # HEALTH_TIMEOUT, RELOAD, REQUIRES, NEEDS, MANPAGES
   config/         # templates, mounted read-only (${SRV_RELEASE_DIR}/config/... in Quadlets)
   image/          # only if no maintained image fits
   hooks/          # optional: prepare, pre-switch, post-switch, others for `srv hook`
   ```

2. In `quadlet/*.container` (and optional `quadlet/srv-<name>.pod`):
   - `[Unit]`/`[Service]`: `Restart=always`, plus `Pod=srv-<name>.pod` on pod members
     (put `Network=` and `PublishPort=` on the `.pod` file, never on member containers).
   - `[Container]`:
     - `ContainerName=srv-<name>` (or `srv-<name>-<ctr>`) and `UserNS=keep-id`.
     - If reading `0750`/`0640` group-1000 host files as container `0:0`, set `GroupAdd=1000`.
     - Healthcheck: `HealthCmd=...`, `HealthInterval=15s`, `HealthRetries=3`,
       `HealthStartPeriod=90s`, and `HealthOnFailure=restart` (or `HealthOnFailure=none`
       for interactive sandboxes). Podman restarts unhealthy containers itself (`autoheal`
       is retired).
     - Persistent or shared host-local data: a bind mount under `${SRV_DATA}`
       (replicated), or a host volume folder under `${SRV_VOLUMES}/<name>` listed
       in `VOLUMES=` in `service.env` (initialize any non-root ownership via `rt_host_id`
       in `hooks/prepare` so both rootless Podman and rollback to Docker get the right UIDs).
     - Secrets/private keys: register in `lib/keys.sh` and mount via
       `Secret=srv-<name>,type=mount,target=...,mode=0400` (`box keys sync` manages them).
     - Built images: `Image=localhost/srv/<name>:${SRV_RELEASE}` and declare
       `IMAGES="localhost/srv/<name>=./image"` in `service.env`.

3. New host variables: add them, documented, to `examples/example.env`, and to
   the env file of every host running the service. A variable that is
   optional for the hosts but required by this service (like `onion_name`
   for `onion`): give it an empty default in `srv` (`load_host`) and list it
   in `NEEDS=` in `service.env`; rendering the service (deploy, `srv check`,
   `box check`) then fails with "needs <var> in the host file" instead of
   running half-configured.

4. `SRV_HOST_ENV=examples/example.env SRV_HOSTS_ENV=examples/example-hosts.env ./srv check <name>`, commit, add the name
   to `services=` on the host, `srv deploy <name>`.

## Hooks

Executables in `hooks/`, run on the host with: `SRV_DATA`, `SRV_VOLUMES`,
`SRV_SERVICE`, `SRV_ROOT`, `SRV_V_<var>` for every host variable, and:

| Hook          | When                                    | Extra variables                                  |
|---------------|-----------------------------------------|--------------------------------------------------|
| `prepare`     | before containers are created           | `SRV_RELEASE_DIR`, `SRV_RUNTIME`, `SRV_PREV_RUNTIME` |
| `pre-switch`  | after confirmation, before the old stop | `SRV_NEW_PROJECT`, `SRV_OLD_PROJECT` (`legacy` or a project), `SRV_OLD_CONTAINERS` |
| `post-switch` | once the new release is healthy         | same                                             |
| any other     | `srv hook <svc> <name>`                 | `SRV_CURRENT_RUNTIME`, `SRV_CURRENT_PROJECT` or `SRV_LEGACY_CONTAINERS` |

`srv hook list [svc|all]` shows each service's hooks, when they run and the
first sentence of the comment under their shebang: start every hook with one.

A failing `prepare` aborts the deploy before anything changes; a failing
`pre-switch` aborts before the switch.
