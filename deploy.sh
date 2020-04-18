#!/bin/bash

data=/home/new-data

function usage() {
	echo "usage: $0 action=<actions> dns=[primary|secondary]"
	echo "  actions are"
	echo "    - list: list sorted containers by dependency"
	echo "    - base: create the base debian image"
	echo "    - image: create per application images"
	echo "    - rename: rename running container before recreating them"
	echo "    - revert: rename running container back to myname"
	echo "    - container: create per application container"
	echo "    - replace: stop old / start new container one at a time"
	echo "    - start: start containers"
	echo "    - stop: start containers"
	echo "    - remove: remove containers"
	echo "    - removeold: remove old containers"
	echo "    - cleanup: remove unused images"
	exit 1
}

function has_to_run() {
	for action in $actions; do
		if [ "$1" == "$action" ]; then
			return 0
		fi
	done

	return 1
}

function add_to_containers() {
	containers=$1
	new_container=$2

	if echo $containers | grep $new_container > /dev/null; then
		echo $containers
	else
		echo $containers $new_container
	fi
}

# Parse options
echo "$@" | grep "help" && usage

for option in "$@"; do
	eval "$option"
done

cd "$(dirname $0)"
actions=$(echo "$action" | tr "," " ")

# Generate ordered containers list (based on dependencies)
if [ -z "$containers" ]; then
	for c in */README; do
		. $c
		for d in $DEPENDS; do
			if [ -f "$d/README" ]; then
				containers=$(add_to_containers "$containers" "$d")
			fi
		done
		containers=$(add_to_containers "$containers" "$NAME")
	done
fi

# Start process
if has_to_run "list"; then
	for c in $containers; do
		echo $c
	done
fi

if has_to_run "base"; then
	echo "START CREATING BASE IMAGE"
	mkdir -p ../base
	[ -d ../base/debian-jessie ] || debootstrap --include=rsync,openssh-server jessie ../base/debian-jessie && touch ../base/.debootstrap
	cp common/* ../base/debian-jessie/usr/bin/
	chmod +x ../base/debian-jessie/usr/bin/setuidgid.sh
	(cd ../base/debian-jessie && tar -c . | docker import - jessie:latest)
fi

if has_to_run "image"; then
	echo "START BUILDING IMAGES"
	for c in $containers; do
		target=$c
		. $c/README
		. source
		$build &
	done

	wait
fi

if has_to_run "rename"; then
	echo "START RENAMING CONTAINERS"
	for c in $containers; do
		. $c/README
		docker rename my$NAME old_$NAME &
	done

	wait
fi

if has_to_run "revert"; then
	echo "START RENAMING CONTAINERS"
	for c in $containers; do
		. $c/README
		docker rename old_$NAME my$NAME &
	done

	wait
fi

if has_to_run "container"; then
	echo "START BUILDING CONTAINERS"
	for c in $containers; do
		. $c/README
		. source
		echo -n "$NAME " && $create
	done
fi

if has_to_run "replace"; then
	echo "START REPLACING CONTAINERS"
	for c in $containers; do
		. $c/README
		. source
		echo -n "=> replace $NAME"
		read
		docker stop old_$NAME
		$start
	done
fi

if has_to_run "remove"; then
	echo "START REMOVING CONTAINERS"
	for c in $containers; do
		. $c/README
		. source
		$rm
	done
fi

if has_to_run "removeold"; then
	echo "START REMOVING OLD CONTAINERS"
	echo "Press any key to continue"
	read
	for c in $containers; do
		. $c/README
		docker rm old_$NAME
	done
fi

if has_to_run "start"; then
	echo "START CONTAINERS"
	echo "Press any key to continue"
	read
	for c in $containers; do
		. $c/README
		. source
		$start
	done
fi

if has_to_run "stop"; then
	echo "STOP CONTAINERS"
	echo "Press any key to continue"
	read
	for c in $containers; do
		. $c/README
		. source
		$stop
	done
fi

if has_to_run "cleanup"; then
	echo "START CLEANUP"
	echo "Press any key to continue"
	read
	unused_images=$(docker images | grep none | awk '{print $3}' | xargs)
	docker rmi $unused_images
fi
