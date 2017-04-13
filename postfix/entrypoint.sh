#!/bin/bash

# Debug
if [ -n "$1" ]; then
	exec $*
fi

# Copy user accounts
cp /var/lib/etc/* /etc

# Resolve opendkim address
sed -i "s/@myopendkim@/$MYOPENDKIM_PORT_12301_TCP_ADDR/" /etc/postfix/main.cf

# Set permissions
chown -R postfix.postfix /keys

# Run supervisor
exec /usr/bin/supervisord -n -c /etc/default/supervisord.conf
