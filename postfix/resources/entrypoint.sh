#!/bin/bash

# Debug
if [ -n "$1" ]; then
	exec $*
fi

# Copy user accounts
cp /var/lib/etc/* /etc
chown root.root /etc/passwd /etc/group /etc/shadow
chmod 644 /etc/passwd /etc/group
chmod 640 /etc/shadow

# Resolve opendkim address
sed -i "s/@myopendkim@/$MYOPENDKIM_PORT_12301_TCP_ADDR/g" /etc/postfix/main.cf

# Update server name
sed -i "s/@server_name@/$server_name/g" /etc/postfix/main.cf

# Set permissions
chown -R postfix.postfix /keys

# Run supervisor
exec /usr/bin/supervisord -n -c /etc/default/supervisord.conf
