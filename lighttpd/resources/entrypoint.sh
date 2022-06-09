#!/bin/bash

# Debug
if [ -n "$1" ]; then
	exec $*
fi

# Debug
if [ -n "$1" ]; then
	exec $*
fi

source /env

# Customize lighttpd config
sed -i "s/@onion_name@/$onion_name/" /etc/lighttpd/lighttpd.conf

# Set permissions
chown -R www-data.www-data /www

# Make sure log directory is created
mkdir -p /var/log/lighttpd
chown -R www-data.www-data /var/log/lighttpd
chmod -R 0750 /var/log/lighttpd


# Make sure acme directory is created
mkdir -p /www/acme/.well-known/acme-challenge/

# Run lighttpd
exec /usr/sbin/lighttpd -D -f /etc/lighttpd/lighttpd.conf
