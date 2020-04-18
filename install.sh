#!/bin/bash

DATA_FOLDER="/home/data/keys/ssl/"
CRONFILE="/tmp/cronfile"

function usage() {
	echo "usage: $0 server=[primary|secondary]"
	exit 1
}

function install_cron() {
	crontab -u $1 $CRONFILE
}

# Parse options
echo "$@" | grep "help" && usage

for option in "$@"; do
	eval "$option"
done

cd "$(dirname $0)"

if [ "$(whoami)" != "blunderer" ]; then
	echo "Must run as blunderer"
	exit 1
fi

if [ -z "$server" ]; then
	echo "Missing server parameter"
	usage
	exit 1
elif [ "$server" = "primary" ]; then
	SERVER=master
elif [ "$server" = "secondary" ]; then
	echo "Only install on primary server" 
	exit 1
else
	echo "Unknown server parameter"
	usage
	exit 1
fi

mkdir -p $DATA_FOLDER
cp scripts/* $DATA_FOLDER/
rsync -aP config/ $DATA_FOLDER/

# Prepare user cronfile
sed "s,@ssl@,$DATA_FOLDER," cron/renew-ssl.cron > $CRONFILE

install_cron blunderer
