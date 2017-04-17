#!/bin/bash

# Debug
if [ -n "$1" ]; then
	exec $*
fi

# Set permissions
chmod -R opendkim.opendkim /keys

# Run supervisor
exec /usr/bin/supervisord -n -c /etc/default/supervisord.conf
