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
	echo ""
	echo "Set containers='foo bar' environment variable to only touch containers foo and bar"
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

echo "About to run actions '$actions' on '$containers'. Press enter to proceed."
read y

# Start process
if has_to_run "list"; then
	for c in $containers; do
		echo $c
	done
fi

if has_to_run "base"; then
	DVERS=buster
	echo "START CREATING BASE IMAGE"
	mkdir -p ../base || exit 1
	[ -f ../base/.debootstrap.${DVERS} ] || debootstrap --include=rsync,openssh-server,logrotate ${DVERS} ../base/debian-${DVERS} && touch ../base/.debootstrap.${DVERS}
	cp common/* ../base/debian-${DVERS}/usr/bin/
	chmod +x ../base/debian-${DVERS}/usr/bin/setuidgid.sh
	(cd ../base/debian-${DVERS} && tar -c . | docker import - debian:latest || exit 1)
	[ -f ../base/.debootstrap.${DVERS} ] || exit 1
fi

if has_to_run "image"; then
	echo "START BUILDING IMAGES"
	for c in $containers; do
		target=$c
		. $c/README
		. source
		$build &
	done

	wait || exit 2
fi

if has_to_run "rename"; then
	echo "START RENAMING CONTAINERS"
	for c in $containers; do
		. $c/README
		docker rename my$NAME old_$NAME &
	done

	wait || exit 3
fi

if has_to_run "revert"; then
	echo "START RENAMING CONTAINERS"
	for c in $containers; do
		. $c/README
		docker rename old_$NAME my$NAME &
	done

	wait || exit 4
fi

if has_to_run "container"; then
	echo "START BUILDING CONTAINERS"
	for c in $containers; do
		. $c/README
		. source
		echo -n "$NAME " && $create || exit 5
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
		$start || exit 6
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
		$start || echo "failed to start $c"
	done
fi

if has_to_run "stop"; then
	echo "STOP CONTAINERS"
	echo "Press any key to continue"
	read
	for c in $containers; do
		. $c/README
		. source
		$stop || echo "failed to stop $c"
	done
fi

if has_to_run "cleanup"; then
	unused_containers=$(docker ps -a | grep Exited | awk '{print $NF}' | grep -v -e "^old_" -e "^my")
	echo "START CLEANUP OF OLD CONTAINERS"
	echo "$unused_containers"
	echo "Press any key to continue"
	read
	if [ -n "unused_containers" ]; then
		docker rm $unused_containers
	fi
	unused_images=$(docker images | grep none | awk '{print $3}' | xargs)
	echo "START CLEANUP OF OLD IMAGES"
	echo "$unused_images"
	echo "Press any key to continue"
	read
	if [ -n "unused_images" ]; then
		docker rmi $unused_images
	fi
fi
