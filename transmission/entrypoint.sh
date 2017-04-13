#!/bin/bash

# Debug
if [ -n "$1" ]; then
	exec $*
fi

# Set permissions
chown -R debian-transmission.debian-transmission /data

# Update password
source /keys/passwd
sed -i "s/@passwd@/$PASSWD/" /etc/transmission-daemon/settings.json

# Run transmission
exec start-stop-daemon -c debian-transmission:debian-transmission --start --exec \
	/usr/bin/transmission-daemon -- \
		-f --log-error --log-info --config-dir /var/lib/transmission-daemon/info
