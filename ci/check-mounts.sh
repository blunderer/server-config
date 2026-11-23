#!/usr/bin/env bash
# Fail if any service mounts something inside one of its read-only mounts:
# the runtime cannot create a mount point inside a read-only mount when starting
# the container. Renders every service with the example host files; needs python3.
set -euo pipefail
ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export SRV_HOST_ENV=$ROOT/examples/example.env SRV_HOSTS_ENV=$ROOT/examples/example-hosts.env
bad=0
for dir in "$ROOT"/services/*/; do
	svc=$(basename "$dir")
	"$ROOT/srv" render "$svc" "$WORK/$svc" >/dev/null
	python3 "$ROOT/ci/nested-mounts.py" "$svc" "$WORK/$svc/quadlet" || bad=1
done
cp "$ROOT/examples/example.env" "$WORK/agy.env"
printf '\nagy_instances="site api"\n' >>"$WORK/agy.env"
SRV_HOST_ENV="$WORK/agy.env" "$ROOT/srv" render agy "$WORK/agy-multi" >/dev/null
python3 "$ROOT/ci/nested-mounts.py" "agy(multi)" "$WORK/agy-multi/quadlet" || bad=1
[[ $bad == 0 ]] && echo "no mount inside a read-only mount"
exit "$bad"
