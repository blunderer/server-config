#!/bin/bash

TOPDIR=$(dirname $0)

data=/home/new-data
target=$1

if [ -d "$1" -a -f "$1/README" ]; then
	. "$1/README"
	. "$TOPDIR/source"

	echo "#"
	echo "# $NAME"
	echo "#"
	echo "# Apps:"
	for a in $DEPENDS; do
		echo "# - $a"
	done
	echo "# Ports:"
	for p in $PORTS; do
		echo "# - $p"
	done
	echo "# Volumes:"
	for v in $VOLUMES; do
		echo "# - $data/$v"
	done
	echo
	echo "# BUILD"
	echo $build
	echo
	echo "# CREATE"
	echo $create
	echo
	echo "# START"
	echo $start
	echo
	echo "# STOP"
	echo $stop
	echo
	echo "# EXEC"
	echo docker exec -i -t my$NAME bash
	echo
	echo "# COPY"
	echo docker cp \$file my$NAME:\$file
	echo docker cp my$NAME:\$file \$file
	echo
	echo "# RM"
	echo $rm
	echo
fi
