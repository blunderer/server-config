# shellcheck shell=bash
# The agy instances (agy_instances): container (compose service) and work
# volume of each. The instance "agy" keeps the first layout's names.

agy_instances() { echo "${SRV_V_agy_instances:-agy}"; }
agy_service() { if [[ $1 == agy ]]; then echo agy; else echo "agy-$1"; fi; }
agy_running_volumes_dir() {
	sed -n 's/^SRV_VOLUMES=//p' "${SRV_STATE:-/srv/releases}/agy/current/.env" 2>/dev/null | tail -n 1
}
agy_work_dir() {
	local base cur_env="${SRV_STATE:-/srv/releases}/agy/current/.env"
	if [[ -f $cur_env ]]; then
		base=$(agy_running_volumes_dir)
		[[ -n $base ]] || return 0
	else
		base=${SRV_VOLUMES:-${SRV_V_volumes_dir:-/home/volumes}}
	fi
	if [[ $1 == agy ]]; then echo "$base/agy-work"; else echo "$base/agy-$1-work"; fi
}

# agy_pick [NAME]: NAME if it is an instance; with no NAME, the only
# instance. Exits with the list otherwise.
agy_pick() {
	local all n
	all=$(agy_instances)
	if [[ -n ${1:-} ]]; then
		[[ " $all " == *" $1 "* ]] && { echo "$1"; return; }
		echo "no agy instance '$1' (agy_instances: $all)" >&2
		exit 2
	fi
	n=$(wc -w <<<"$all")
	if ((n == 1)); then echo "$all"; return; fi
	echo "several agy instances ($all): name one" >&2
	exit 2
}

# Shares (srv hook agy share): per instance, under volumes_dir/agy[-<instance>]-shares:
#   shares             one "NAME FOLDER" line per share
#   shared/NAME        the overlay's mount point, /shared/NAME in the container
#   overlay/NAME/upper what the agent changed (new and modified files)
#   overlay/NAME/work  overlayfs' own working folder
agy_share_vol() { if [[ $1 == agy ]]; then echo agy-shares; else echo "agy-$1-shares"; fi; }
agy_share_base() {
	local v cur_dir="${SRV_STATE:-/srv/releases}/agy/current" base
	v=$(agy_share_vol "$1")
	if [[ -z ${SRV_RELEASE_DIR:-} && -f $cur_dir/.env ]]; then
		base=$(agy_running_volumes_dir)
		if [[ -n $base && -d $cur_dir/quadlet ]] &&
			grep -qE "(^|[=:])$base/$v([:/[:space:]]|\$)" "$cur_dir"/quadlet/*.container 2>/dev/null; then
			echo "$base/$v"
		else
			echo "${SRV_V_agy_share_dir:-/home/srv-agy}/$1"
		fi
		return 0
	fi
	echo "${SRV_VOLUMES:-${SRV_V_volumes_dir:-/home/volumes}}/$v"
}

# agy_check_share FOLDER: exits/returns 1 if FOLDER is a system directory, key
# directory, home directory with .ssh, or an ancestor of <data>/{keys,users}.
agy_check_share() {
	local folder=$1 data keys_dir users_dir vols rvols
	data=$(realpath -m "${SRV_DATA:-/home/data}")
	vols=$(realpath -m "${SRV_VOLUMES:-${SRV_V_volumes_dir:-/home/volumes}}")
	rvols=$(agy_running_volumes_dir)
	keys_dir=$data/keys
	users_dir=$data/users
	case $folder in
		/ | /etc | /etc/* | /root | /root/* | /var | /var/* | /proc | /proc/* | \
		/sys | /sys/* | /dev | /dev/* | /run | /run/* | /boot | /boot/* | \
		*/.ssh | */.ssh/* | */keys | */keys/*)
			echo "$folder: not shared (system, ssh or key folder)" >&2
			return 1
			;;
	esac
	if [[ $folder == "$keys_dir" || $folder == "$keys_dir"/* || $keys_dir == "$folder"/* ||
		$folder == "$users_dir" || $folder == "$users_dir"/* || $users_dir == "$folder"/* ]]; then
		echo "$folder: not shared (contains or is inside $data/{keys,users})" >&2
		return 1
	fi
	if [[ $folder == "$vols" || $folder == "$vols"/* || $vols == "$folder"/* ]]; then
		echo "$folder: not shared (contains or is inside $vols)" >&2
		return 1
	fi
	if [[ -n $rvols ]]; then
		rvols=$(realpath -m "$rvols")
		if [[ $folder == "$rvols" || $folder == "$rvols"/* || $rvols == "$folder"/* ]]; then
			echo "$folder: not shared (contains or is inside $rvols)" >&2
			return 1
		fi
	fi
	if [[ -e $folder/.ssh || -L $folder/.ssh ]] || compgen -G "$folder/*/.ssh" >/dev/null; then
		echo "$folder: not shared (contains a .ssh folder; share a project subfolder instead)" >&2
		return 1
	fi
	return 0
}

# agy_mount INSTANCE NAME FOLDER: the overlay, unless already mounted.
agy_mount() {
	local base merged up wk
	base=$(agy_share_base "$1")
	[[ $base != *[,:]* ]] || { echo "$1: $base: path with , or : cannot hold an overlay" >&2; return 1; }
	merged=$base/shared/$2 up=$base/overlay/$2/upper wk=$base/overlay/$2/work
	if mountpoint -q "$merged"; then
		echo "$1: $2 already shared ($3)"
		return 0
	fi
	[[ -d $3 ]] || { echo "$1: $2: $3 is gone, not shared" >&2; return 1; }
	agy_check_share "$3" || return 1
	rm -rf "$wk"
	mkdir -p "$merged" "$up" "$wk"
	# The agent runs as uid 1000: its changes are written as that user.
	chown 1000:1000 "$up"
	mount -t overlay overlay -o "lowerdir=$3,upperdir=$up,workdir=$wk" "$merged"
	echo "$1: $3 shared as /shared/$2 (read-only original, changes in $up)"
}
