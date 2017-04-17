#!/bin/bash

function usage() {
	echo "usage: $0 action=<actions> dns=[primary|secondary]"
	echo "  actions are"
	echo "    - base"
	echo "    - image"
	echo "    - rename"
	echo "    - volume"
	echo "    - populate"
	echo "    - container"
	echo "    - replace"
	echo "    - remove2"
	echo "    - cleanup"
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

# Parse options
echo "$@" | grep "help" && usage

for option in "$@"; do
	eval "$option"
done

cd "$(dirname $0)"
actions=$(echo "$action" | tr "," " ")

if [ "$dns" == "primary" ]; then
	PRIMARY=true
elif [ "$dns" == "secondary" ]; then
	PRIMARY=false
else
	if has_to_run "container"; then
		echo "Missing dns parameter."
		usage
	fi
fi

# Start process
if has_to_run "base"; then
	echo "START CREATING BASE IMAGE"
	mkdir -p base
	[ -d base/debian-jessie ] || debootstrap --include=rsync,openssh-server jessie base/debian-jessie && touch base/.debootstrap
	cp common/* base/debian-jessie/usr/bin/
	chmod +x base/debian-jessie/usr/bin/setuidgid.sh
	(cd base/debian-jessie && tar -c . | docker import - jessie:latest)
fi

if has_to_run "volume"; then
	echo "START CREATING VOLUMES"
	docker volume create keys-transmission &
	docker volume create keys-opendkim &
	docker volume create keys-postfix &
	docker volume create keys-www &
	docker volume create mysql &
	docker volume create users &
	docker volume create www &

	wait
fi

if has_to_run "populate"; then
	echo "START POPULATING VOLUMES"
	docker run --rm -v keys-transmission:/keys -v /home/data/keys/transmission:/backup:ro -t jessie:latest /usr/bin/rsync -aP --delete /backup/ /keys/ &
	docker run --rm -v keys-opendkim:/keys -v /home/data/keys/opendkim:/backup:ro -t jessie:latest /usr/bin/rsync -aP --delete /backup/ /keys/ &
	docker run --rm -v keys-postfix:/keys -v /home/data/keys/postfix:/backup:ro -t jessie:latest /usr/bin/rsync -aP --delete /backup/ /keys/ &
	docker run --rm -v keys-www:/keys -v /home/data/keys/lighttpd:/backup:ro -t jessie:latest /usr/bin/rsync -aP --delete /backup/ /keys/ &
	docker run --rm -v mysql:/mysql/ -v /home/data/mysql/:/backup:ro -t jessie:latest /usr/bin/rsync -aP --delete /backup/ /mysql/ &
	docker run --rm -v users:/users -v /home/data/users/:/backup:ro -t jessie:latest /usr/bin/rsync -aP --delete /backup/ /users/ &
	docker run --rm -v www:/www -v /home/data/www/:/backup:ro -t jessie:latest /usr/bin/rsync -aP --delete /backup/ /www/ &

	wait
fi

if has_to_run "image"; then
	echo "START BUILDING IMAGES"
	(cd bind && docker build -t bind:latest .) &
	(cd lighttpd && docker build -t lighttpd:latest .) &
	(cd mysql && docker build -t mysql:latest .) &
	(cd opendkim && docker build -t opendkim:latest .) &
	(cd postfix && docker build -t postfix:latest .) &
	(cd transmission && docker build -t transmission:latest .) &

	wait
fi

if has_to_run "rename"; then
	echo "START RENAMING CONTAINERS"
	docker rename mymysql mymysql2 &
	docker rename mylighttpd mylighttpd2 &
	docker rename myopendkim myopendkim2 &
	docker rename mypostfix mypostfix2 &
	docker rename mytransmission mytransmission2 &
	docker rename mybind mybind2 &

	wait
fi

if has_to_run "container"; then
	echo "START BUILDING CONTAINERS"
	docker create --name mymysql -v mysql:/var/lib/mysql/ --restart always mysql:latest
	docker create --name mylighttpd -v www:/www -vkeys-www:/keys -p 80:80 -p 443:443 --link mymysql --restart always lighttpd:latest
	docker create --name myopendkim -vkeys-opendkim:/keys --restart always opendkim:latest
	docker create --name mypostfix -v keys-postfix:/keys -v users:/var/lib/etc/ --link=myopendkim -p 25:25 -p 465:465 -p 587:587 --restart always postfix:latest
	docker create --name mytransmission -v/home/torrent/:/data/ -p9091:9091 --restart always transmission:latest
	if $PRIMARY; then
		docker create --name mybind -p53:53 -p53:53/udp --restart always bind:latest 5.135.157.10 5.135.157.10 37.187.111.9
	else
		docker create --name mybind -p53:53 -p53:53/udp --restart always bind:latest 37.187.111.9 5.135.157.10 37.187.111.9
	fi
fi

if has_to_run "replace"; then
	echo "START REPLACING CONTAINERS"
	echo -n "=> replace mysql..."
	read
	docker stop mymysql2
	docker start mymysql
	echo "done"
	echo -n "=> replace lighttpd..."
	read
	docker stop mylighttpd2
	docker start mylighttpd
	echo "done"
	echo -n "=> replace transmission..."
	read
	docker stop mytransmission2
	docker start mytransmission
	echo "done"
	echo -n "=> replace bind..."
	read
	docker stop mybind2
	docker start mybind
	echo "done"
	echo -n "replace opendkim..."
	read
	docker stop myopendkim2
	docker start myopendkim
	echo "done"
	echo -n "replace postfix..."
	read
	docker stop mypostfix2
	docker start mypostfix
	echo "done"
fi

if has_to_run "remove"; then
	echo "START REMOVING EXTRA CONTAINERS"
	docker rm mymysql &
	docker rm mylighttpd &
	docker rm myopendkim &
	docker rm mypostfix &
	docker rm mytransmission &
	docker rm mybind &

	wait
fi

if has_to_run "remove2"; then
	echo "START REMOVING EXTRA CONTAINERS"
	echo "Press any key to continue"
	read
	docker rm mymysql2 &
	docker rm mylighttpd2 &
	docker rm myopendkim2 &
	docker rm mypostfix2 &
	docker rm mytransmission2 &
	docker rm mybind2 &

	wait
fi

if has_to_run "cleanup"; then
	echo "START CLEANUP"
	echo "Press any key to continue"
	read
	unused_images=$(docker images | grep none | awk '{print $3}' | xargs)
	docker rmi $unused_images
fi
