#!/bin/bash

function usage() {
	echo "usage: $0 local=<local path>"
	exit 1
}

# Parse options
echo "$@" | grep "help" && usage

for option in "$@"; do
	eval "$option"
done

if [ -z "$local" ]; then
	echo "Missing local destination."
	usage
fi

mkdir -p "$local"

docker run --rm -t \
	-v users:/src/users:ro \
	-v keys-www:/src/keys/lighttpd:ro \
	-v keys-postfix:/src/keys/postfix:ro \
	-v keys-opendkim:/src/keys/opendkim:ro \
	-v mysql:/src/mysql:ro \
	-v www:/src/www:ro \
	-v "$local/:/backup" \
	jessie:latest /usr/bin/rsync -aP --delete /src/ /backup/
