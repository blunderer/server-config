#!/bin/bash

# Debug
if [ -n "$1" ]; then
	exec $*
fi

# Debug
if [ -n "$1" ]; then
	exec $*
fi

# Set permissions
chown -R www-data.www-data /www
chown -R www-data.www-data /keys

# Run lighttpd
exec /usr/sbin/lighttpd -D -f /etc/lighttpd/lighttpd.conf
