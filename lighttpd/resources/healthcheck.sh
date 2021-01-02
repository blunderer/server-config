#!/bin/sh

if ! wget localhost --no-check-certificate -O /dev/null; then
	echo "lighttpd unhealthy: reloading"
	exit 1
fi

echo "" | openssl s_client -connect localhost:443 -servername blunderer.org 2> /dev/null | openssl x509 > /tmp/current.pem

if [ "$(wc -c /tmp/current.pem | cut -f1 -d' ')" -eq 0 ]; then
	echo "lighttpd SSL unhealthy: reloading"
	rm /tmp/current.pem
	exit 1
fi

CURRENT=$(date --date="$(openssl x509 -in /tmp/current.pem -text | grep 'Not After' | cut -f2- -d:)" +%s)
SERVER=$(date --date="$(openssl x509 -in /keys/server.pem -text | grep 'Not After' | cut -f2- -d:)" +%s)
rm /tmp/current.pem

if [ $SERVER -gt $CURRENT ]; then
	echo "New certificate available: needs reload"
	killall lighttpd
	exit 1
fi

exit 0
