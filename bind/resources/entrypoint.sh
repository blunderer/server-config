#!/bin/bash

# Debug
if [ -f "$1" ]; then
	exec $*
fi

SERVER_IP=$1
PRIMARY_DNS=$2
SECONDARY_DNS=$3

# Tune configuration
if [ "$SERVER_IP" = "$SECONDARY_DNS" ]; then
	mv /etc/bind/named.conf.local.slave /etc/bind/named.conf.local
	rm /etc/bind/named.conf.local.master
else
	mv /etc/bind/named.conf.local.master /etc/bind/named.conf.local
	rm /etc/bind/named.conf.local.slave
fi

sed -i "s/@primary@/$PRIMARY_DNS/" /etc/bind/*.conf /etc/bind/named.conf.local
sed -i "s/@secondary@/$SECONDARY_DNS/" /etc/bind/*.conf /etc/bind/named.conf.local

# Set permissions

# Run named
exec /usr/bin/supervisord -n -c /etc/default/supervisord.conf
