#!/bin/bash

# Debug
if [ -n "$1" ]; then
	exec $*
fi

source /env

# customize tor onion service register
sed -i "s/@onion_name@/$onion_name/" /etc/tor/torrc

# Set permissions
chown -R www-data.www-data /www

# Make sure log directory is created
mkdir -p /var/log/lighttpd
chown -R www-data.www-data /var/log/lighttpd
chmod -R 0750 /var/log/lighttpd

# Run supervisord
exec /usr/bin/supervisord -n -c /etc/default/supervisord.conf
