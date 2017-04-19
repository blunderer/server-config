#!/bin/bash

function usage() {
	echo "usage: $0 [checkout | status | update | push] <option>"
	echo "  options:"
	echo "    -f force push or force clean checkout"
	exit 1
}

cd "$(dirname $0)"

FORCE=
if [ "$2" = "-f" ]; then
	FORCE=-f
fi

case $1 in
	status)
		(cd workdir && git status)
		for dir in workdir/*/Dockerfile; do
			CONTAINER=$(dirname $dir)
			BRANCH=$(basename $CONTAINER)
			(cd $CONTAINER/config && git status)
		done
	;;
	push)
		DIFF=$(cd workdir && git diff HEAD..origin/docker | wc -l)
		if [ $DIFF -ne 0 ]; then
			(cd workdir && git push $FORCE origin docker:docker)
		fi
		for dir in workdir/*/Dockerfile; do
			CONTAINER=$(dirname $dir)
			BRANCH=$(basename $CONTAINER)
			DIFF=$(cd $CONTAINER/config && git diff HEAD..origin/$BRANCH | wc -l)
			if [ $DIFF -ne 0 ]; then
				(cd $CONTAINER/config && git push $FORCE origin $BRANCH:$BRANCH)
			fi
		done
	;;
	checkout | update)
		REPO=$(git remote get-url origin 2> /dev/null || git remote show origin | grep Fetch | cut -d" " -f5)
		[ -n "$FORCE" -a "$1" = "checkout" ] && rm -rf workdir
		if [ -d workdir ]; then
			(cd workdir && git pull --rebase)
		else
			git clone --branch docker $REPO workdir
		fi
		for dir in workdir/*/Dockerfile; do
			CONTAINER=$(dirname $dir)
			BRANCH=$(basename $CONTAINER)
			if [ -d $CONTAINER/config ]; then
				(cd $CONTAINER/config && git pull --rebase)
			else
				git clone --branch $BRANCH $REPO $CONTAINER/config
			fi
		done
	;;
	help)
		usage
	;;
	*)
		echo "unknown command: $1"
		usage
	;;
esac
