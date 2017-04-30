#!/bin/bash

# Debug
if [ -f "$1" ]; then
	exec $*
fi

function reverse_ip() {
	echo $1 | tr "." " " |awk '{print $4 "." $3 "." $2 "." $1}'
}

SERVER_IP=$1
PRIMARY_DNS=$2
SECONDARY_DNS=$3
R_PRIMARY_DNS=$(reverse_ip $PRIMARY_DNS)
R_SECONDARY_DNS=$(reverse_ip $SECONDARY_DNS)

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
sed -i "s/@r_primary@/$R_PRIMARY_DNS/" /etc/bind/*.conf
sed -i "s/@r_secondary@/$R_SECONDARY_DNS/" /etc/bind/*.conf

# Run named
exec /usr/bin/supervisord -n -c /etc/default/supervisord.conf
