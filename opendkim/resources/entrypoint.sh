#!/bin/bash

# Debug
if [ -n "$1" ]; then
	exec $*
fi

# Set permissions
chmod -R opendkim.opendkim /keys

# Update server name
sed -i "s/@server_name@/$server_name/g" /etc/opendkim/openarc.conf

# Run supervisor
exec /usr/bin/supervisord -n -c /etc/default/supervisord.conf
