#!/bin/bash

BACKUP_FOLDER="/home/backup"
DOCKER_FOLDER="/home/data"
DATA_FOLDERS="$DOCKER_FOLDER"
REMOTE_SERVERS="blunderer@backup.blunderer.org:"
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

if [ "$(whoami)" != "root" ]; then
	echo "Must run as root"
	exit 1
fi

if [ -z "$server" ]; then
	echo "Missing server parameter"
	usage
	exit 1
elif [ "$server" = "primary" ]; then
	SERVER=master
elif [ "$server" = "secondary" ]; then
	SERVER=slave
else
	echo "Unknown server parameter"
	usage
	exit 1
fi

mkdir -p $BACKUP_FOLDER
chown -R blunderer.blunderer $BACKUP_FOLDER
cp scripts/* $BACKUP_FOLDER/

# Prepare root cronfile
cp cron/update.cron $CRONFILE
install_cron root

# Prepare user cronfile
echo -n "" > $CRONFILE
if [ "$SERVER" = "master" ]; then
	for REMOTE_SERVER in $REMOTE_SERVERS; do
		for DATA_FOLDER in $DATA_FOLDERS; do
			DEST=$REMOTE_SERVER/$DATA_FOLDER
			sed "s,@source@,$DATA_FOLDER,; s,@dest@,$DEST," cron/remote-backup.cron >> $CRONFILE
		done
	done
fi

for DATA_FOLDER in $DATA_FOLDERS; do
	sed "s,@backup@,$BACKUP_FOLDER,; s,@source@,$DATA_FOLDER,; s,@dest@,$BACKUP_FOLDER," cron/diff-backup.cron >> $CRONFILE
done

install_cron blunderer
