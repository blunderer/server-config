#!/usr/bin/env bash
# Local incremental backup of the data folder (cron, daily).
#
#   <dest>/<name>.today      -> .<name>.<weekday>   (7 rotating daily copies)
#   <dest>/<name>.yesterday  -> previous day
#   <dest>/<name>.lastweek   -> .<name>.week<NN>    (Wednesday's copy each week)
#
# Unchanged files are hard links to the previous copy (rsync --link-dest), so
# each copy only costs the changed files.
#
# usage: diff-backup.sh <source dir> <dest dir>
set -euo pipefail

if command -v flock >/dev/null 2>&1; then
	_lock_dir=${SRV_LOCK_DIR:-/run/lock}
	mkdir -p "$_lock_dir" 2>/dev/null || _lock_dir=/tmp
	exec 9>"$_lock_dir/srv-diff-backup.lock"
	flock -n 9 || { echo "diff-backup.sh is already running" >&2; exit 1; }
fi

src=${1:?usage: $0 <source> <dest>}
dest=${2:?usage: $0 <source> <dest>}
[[ -d $src ]] || { echo "$src is not a directory" >&2; exit 1; }
mkdir -p "$dest"
chown 0:0 "$dest" 2>/dev/null || true
chmod 0700 "$dest" 2>/dev/null || true
# Hard links only work within one filesystem: elsewhere, rsync would silently
# write a full copy every day and fill the disk.
if [[ $(stat -c %d "$src") != "$(stat -c %d "$dest")" ]]; then
	echo "$dest is not on the same filesystem as $src: refusing (hard links impossible)" >&2
	exit 1
fi

name=$(basename "$src")
today=$(date +%u)        # 1..7
week=$(date +%U)
yesterday=$((today - 1))
[[ $yesterday -eq 0 ]] && yesterday=7

today_dir="$dest/.$name.$today"
yesterday_dir="$dest/.$name.$yesterday"

# On Wednesdays, last week's Wednesday copy becomes the weekly copy (at most once).
week_dir="$dest/.$name.week$week"
if [[ $today -eq 3 && -d $today_dir && ! -d $week_dir ]]; then
	mv "$today_dir" "$week_dir"
	ln -sfn "$week_dir" "$dest/$name.lastweek"
fi

mkdir -p "$today_dir" "$yesterday_dir"
# Live database files are not a usable backup (the nightly dumps in
# backups/mariadb are); skip them.
rsync -a --delete --link-dest="$yesterday_dir/" \
	--exclude=/mysql/ --exclude=/mariadb-v2/ --exclude='/mariadb-v2.stale-*/' --exclude=/mariadb-v2-init/ \
	"$src/" "$today_dir/"

ln -sfn "$today_dir" "$dest/$name.today"
ln -sfn "$yesterday_dir" "$dest/$name.yesterday"
