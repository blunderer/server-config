#!/bin/bash

function usage() {
	echo "usage: $0 source=<path> dest=<path>"
	exit 1
}

# Parse options
echo "$@" | grep "help" && usage

for option in "$@"; do
	eval "$option"
done

# Define parameters
SRC=$source
DEST=$dest

if [ ! -d $SRC ]; then
	echo "source parameter is not a valid folder."
	usage
fi

# Calculate dates
TODAY=$(date +%u)
WEEK=$(date +%U)

YESTERDAY=$((TODAY - 1))
[ $YESTERDAY -eq 0 ] && YESTERDAY=7

# Process destinations
NAME=$(basename $SRC)
TODAYLNK=$DEST/$NAME.today
TODAYDIR=$DEST/.$NAME.$TODAY
YESTERDAYLNK=$DEST/$NAME.yesterday
YESTERDAYDIR=$DEST/.$NAME.$YESTERDAY
WEEKLNK=$DEST/$NAME.lastweek

# Does weekly backup on wednesdays.
if [ $TODAY -eq 3 ]; then
	WEEKDIR=$DEST/.$NAME.week$WEEK
	rm -rf $WEEKDIR
	mv $TODAYDIR $WEEKDIR
	rm -f $WEEKLNK
	ln -s $WEEKDIR $WEEKLNK
fi

# Daily backup for a week
mkdir -p $TODAYDIR $YESTERDAYDIR
rsync -aP --delete --link-dest=$YESTERDAYDIR/ $SRC/ $TODAYDIR/

# Update links
rm -rf $TODAYLNK $YESTERDAYLNK
ln -s $TODAYDIR $TODAYLNK
ln -s $YESTERDAYDIR $YESTERDAYLNK
