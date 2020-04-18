#!/bin/bash

# Debug
if [ -f "$1" ]; then
	exec $*
fi

source /env

# Tune configuration
if [ "$server_ip" = "$secondary_dns" ]; then
	mv /etc/bind/named.conf.local.slave /etc/bind/named.conf.local
	rm /etc/bind/named.conf.local.master
else
	mv /etc/bind/named.conf.local.master /etc/bind/named.conf.local
	rm /etc/bind/named.conf.local.slave
fi

sed -i "s/@primary@/$primary_dns/" /etc/bind/*.conf /etc/bind/named.conf.local
sed -i "s/@secondary@/$secondary_dns/" /etc/bind/*.conf /etc/bind/named.conf.local
sed -i "s/@r_primary@/$primary_rdns/" /etc/bind/*.conf
sed -i "s/@r_secondary@/$secondary_rdns/" /etc/bind/*.conf
sed -i "s/@primary6@/$primary6_dns/" /etc/bind/*.conf /etc/bind/named.conf.local
sed -i "s/@secondary6@/$secondary6_dns/" /etc/bind/*.conf /etc/bind/named.conf.local
sed -i "s/@r_primary6@/$primary6_rdns/" /etc/bind/*.conf
sed -i "s/@r_secondary6@/$secondary6_rdns/" /etc/bind/*.conf

# Run named
exec /usr/bin/supervisord -n -c /etc/default/supervisord.conf
